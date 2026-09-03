-- =============================================================================
-- CP-A1: customer intervention reports (immutable aggregate + drafts + versions)
-- + require_fresh_tenant_permission + field_service.reports.* defaults
-- + private storage bucket customer-report-media (no authenticated write)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Permissions: extend get_role_permissions defaults
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.get_role_permissions(
  p_role              text,
  p_custom_perms      jsonb DEFAULT NULL
)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_viewer_base  text[] := ARRAY[
    'storage.view', 'calendar.view', 'email.view', 'invoices.view',
    'members.view', 'sites.view', 'settings.view',
    'attendance.view_own', 'labor_calendar.view',
    'employees.directory.view',
    'assets.view',
    'recruitment.view'
  ];
  v_member_base  text[] := ARRAY[
    'storage.upload', 'calendar.edit', 'email.send', 'invoices.edit',
    'attendance.punch_own', 'absences.request',
    'ai.use',
    'employees.directory.view', 'employees.view',
    'assets.view',
    'recruitment.view',
    'field_service.reports.publish',
    'field_service.reports.regenerate',
    'field_service.reports.share',
    'field_service.reports.preview_as_customer',
    'contacts.portal.manage'
  ];
  v_manager_base text[] := ARRAY[
    'storage.delete', 'calendar.manage', 'email.manage', 'invoices.manage',
    'members.invite', 'sites.create', 'settings.manage', 'permissions.manage',
    'attendance.view_all', 'attendance.adjust', 'attendance.approve',
    'attendance.export', 'attendance.devices.manage',
    'labor_calendar.manage', 'absences.approve',
    'ai.configure', 'ai.tools.write',
    'employees.directory.view', 'employees.view', 'employees.manage',
    'employees.private.view', 'employees.private.manage', 'employees.private.reveal',
    'employees.skills.manage',
    'employees.lifecycle.view', 'employees.lifecycle.manage',
    'employees.contracts.view', 'employees.contracts.manage',
    'compliance.requirements.manage',
    'compliance.certifications.view', 'compliance.certifications.manage',
    'assets.view', 'assets.manage',
    'assets.employee_assignments.view', 'assets.employee_assignments.manage',
    'recruitment.view', 'recruitment.manage', 'recruitment.interview',
    'field_service.reports.publish',
    'field_service.reports.regenerate',
    'field_service.reports.share',
    'field_service.reports.revoke',
    'field_service.reports.preview_as_customer',
    'contacts.portal.manage'
  ];
  v_accumulated  text[] := '{}';
BEGIN
  IF p_role = 'owner' THEN
    RETURN ARRAY['*'];
  END IF;

  IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'viewer' THEN
    v_accumulated := v_accumulated ||
      ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'viewer'));
  ELSE
    v_accumulated := v_accumulated || v_viewer_base;
  END IF;

  IF p_role IN ('member', 'manager') THEN
    IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'member' THEN
      v_accumulated := v_accumulated ||
        ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'member'));
    ELSE
      v_accumulated := v_accumulated || v_member_base;
    END IF;
  END IF;

  IF p_role = 'manager' THEN
    IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'manager' THEN
      v_accumulated := v_accumulated ||
        ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'manager'));
    ELSE
      v_accumulated := v_accumulated || v_manager_base;
    END IF;
  END IF;

  RETURN ARRAY(SELECT DISTINCT unnest(v_accumulated));
END;
$$;

GRANT EXECUTE ON FUNCTION data.get_role_permissions(text, jsonb)
  TO authenticated, supabase_auth_admin;

-- ---------------------------------------------------------------------------
-- 2. require_fresh_tenant_permission (live membership + live capability)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.member_has_live_permission(
  p_tenant_id uuid,
  p_user_id uuid,
  p_permission text,
  p_site_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_role text;
  v_custom jsonb;
  v_perms text[];
BEGIN
  SELECT tm.role INTO v_role
  FROM data.tenant_members tm
  WHERE tm.tenant_id = p_tenant_id
    AND tm.user_id = p_user_id
    AND tm.site_id IS NULL
  LIMIT 1;

  IF v_role IS NULL AND p_site_id IS NOT NULL THEN
    SELECT tm.role INTO v_role
    FROM data.tenant_members tm
    WHERE tm.tenant_id = p_tenant_id
      AND tm.user_id = p_user_id
      AND tm.site_id = p_site_id
    LIMIT 1;
  END IF;

  IF v_role IS NULL THEN
    RETURN false;
  END IF;

  SELECT t.metadata -> 'role_permissions' INTO v_custom
  FROM data.tenants t WHERE t.id = p_tenant_id;

  v_perms := data.get_role_permissions(v_role, v_custom);
  RETURN v_perms @> ARRAY['*'] OR v_perms @> ARRAY[p_permission];
END;
$$;

REVOKE ALL ON FUNCTION data.member_has_live_permission(uuid, uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.member_has_live_permission(uuid, uuid, text, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.require_fresh_tenant_permission(
  p_tenant_id uuid,
  p_permission text,
  p_site_id uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_live boolean;
  v_jwt boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.tenant_members tm
    WHERE tm.tenant_id = p_tenant_id
      AND tm.user_id = v_uid
      AND (tm.site_id IS NULL OR (p_site_id IS NOT NULL AND tm.site_id = p_site_id))
  ) THEN
    RAISE EXCEPTION 'not_tenant_member' USING ERRCODE = 'P0001';
  END IF;

  v_live := data.member_has_live_permission(p_tenant_id, v_uid, p_permission, p_site_id);
  IF NOT v_live THEN
    RAISE EXCEPTION 'permission_denied:%', p_permission USING ERRCODE = 'P0001';
  END IF;

  v_jwt := COALESCE(data.jwt_has_permission(p_tenant_id, p_permission, p_site_id), false);
  IF NOT v_jwt THEN
    -- Live membership/capability OK but JWT claims stale
    RAISE EXCEPTION 'session_refresh_required' USING ERRCODE = 'P0001';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION data.require_fresh_tenant_permission(uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.require_fresh_tenant_permission(uuid, text, uuid)
  TO authenticated, service_role;

-- Fail-closed audit (raises if insert fails)
CREATE OR REPLACE FUNCTION data.log_audit_event_strict(
  p_tenant_id uuid,
  p_user_id uuid,
  p_site_id uuid,
  p_action text,
  p_entity_type text,
  p_entity_id uuid,
  p_payload jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  INSERT INTO data.audit_logs (tenant_id, user_id, site_id, action, entity_type, entity_id, payload)
  VALUES (p_tenant_id, p_user_id, p_site_id, p_action, p_entity_type, p_entity_id, COALESCE(p_payload, '{}'::jsonb));
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'audit_persist_failed:%', SQLERRM USING ERRCODE = 'P0001';
END;
$$;

REVOKE ALL ON FUNCTION data.log_audit_event_strict(uuid, uuid, uuid, text, text, uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.log_audit_event_strict(uuid, uuid, uuid, text, text, uuid, jsonb)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. DDL: aggregate / drafts / versions / events
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.customer_intervention_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  project_id uuid NOT NULL REFERENCES data.projects(id) ON DELETE RESTRICT,
  report_type text NOT NULL DEFAULT 'intervention'
    CHECK (report_type IN ('intervention')),
  current_published_version_id uuid,
  legacy_unresolved boolean NOT NULL DEFAULT false,
  created_by uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, project_id, report_type)
);

CREATE INDEX IF NOT EXISTS idx_cir_tenant_project
  ON data.customer_intervention_reports (tenant_id, project_id);

CREATE TABLE IF NOT EXISTS data.customer_intervention_report_drafts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  report_id uuid NOT NULL REFERENCES data.customer_intervention_reports(id) ON DELETE CASCADE,
  project_id uuid NOT NULL REFERENCES data.projects(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'preparing_media', 'ready', 'failed', 'superseded')),
  customer_account_contact_id uuid REFERENCES data.contacts(id) ON DELETE SET NULL,
  contact_site_id uuid REFERENCES data.contact_sites(id) ON DELETE SET NULL,
  locale text NOT NULL DEFAULT 'ca',
  client_summary_html text,
  projection jsonb NOT NULL DEFAULT '{}'::jsonb,
  selected_media jsonb NOT NULL DEFAULT '[]'::jsonb,
  media_manifest jsonb NOT NULL DEFAULT '[]'::jsonb,
  schema_version text NOT NULL DEFAULT '1.0',
  template_version text NOT NULL DEFAULT '1.0',
  failure_reason text,
  created_by uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  updated_by uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_cird_report
  ON data.customer_intervention_report_drafts (report_id, status);

CREATE TABLE IF NOT EXISTS data.customer_intervention_report_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  report_id uuid NOT NULL REFERENCES data.customer_intervention_reports(id) ON DELETE RESTRICT,
  project_id uuid NOT NULL REFERENCES data.projects(id) ON DELETE RESTRICT,
  version_number integer NOT NULL CHECK (version_number >= 1),
  draft_id uuid REFERENCES data.customer_intervention_report_drafts(id) ON DELETE SET NULL,
  customer_account_contact_id uuid REFERENCES data.contacts(id) ON DELETE RESTRICT,
  contact_site_id uuid REFERENCES data.contact_sites(id) ON DELETE SET NULL,
  locale text NOT NULL DEFAULT 'ca',
  schema_version text NOT NULL DEFAULT '1.0',
  template_version text NOT NULL DEFAULT '1.0',
  content_digest text NOT NULL,
  projection jsonb NOT NULL,
  media_manifest jsonb NOT NULL DEFAULT '[]'::jsonb,
  snapshots jsonb NOT NULL DEFAULT '{}'::jsonb,
  published_at timestamptz NOT NULL DEFAULT now(),
  published_by uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (report_id, version_number)
);

ALTER TABLE data.customer_intervention_report_drafts
  ADD COLUMN IF NOT EXISTS based_on_version_id uuid
  REFERENCES data.customer_intervention_report_versions(id) ON DELETE SET NULL;

-- Private, server-authored copy ledger. The browser never receives source
-- bucket/object keys and authenticated users have no table privileges.
CREATE TABLE IF NOT EXISTS data.customer_intervention_report_media_copy_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  report_id uuid NOT NULL REFERENCES data.customer_intervention_reports(id) ON DELETE CASCADE,
  draft_id uuid NOT NULL REFERENCES data.customer_intervention_report_drafts(id) ON DELETE CASCADE,
  project_id uuid NOT NULL REFERENCES data.projects(id) ON DELETE RESTRICT,
  item_index integer NOT NULL CHECK (item_index >= 0),
  file_node_id uuid NOT NULL REFERENCES data.file_nodes(id) ON DELETE RESTRICT,
  source_bucket text NOT NULL CHECK (source_bucket = 'tenant-files'),
  source_object_key text NOT NULL,
  destination_bucket text NOT NULL DEFAULT 'customer-report-media'
    CHECK (destination_bucket = 'customer-report-media'),
  destination_object_key text NOT NULL,
  content_type text NOT NULL DEFAULT 'application/octet-stream',
  expected_size_bytes bigint NOT NULL DEFAULT 0 CHECK (expected_size_bytes >= 0),
  source_checksum text,
  copied_size_bytes bigint CHECK (copied_size_bytes >= 0),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'processing', 'ok', 'failed')),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  failure_reason text,
  claimed_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (draft_id, item_index),
  UNIQUE (destination_bucket, destination_object_key)
);

CREATE INDEX IF NOT EXISTS idx_cirmcj_draft_status
  ON data.customer_intervention_report_media_copy_jobs (draft_id, status, item_index);

REVOKE ALL ON data.customer_intervention_report_media_copy_jobs
  FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON data.customer_intervention_report_media_copy_jobs TO service_role;

CREATE INDEX IF NOT EXISTS idx_cirv_tenant_project
  ON data.customer_intervention_report_versions (tenant_id, project_id);

ALTER TABLE data.customer_intervention_reports
  DROP CONSTRAINT IF EXISTS fk_cir_current_version;
ALTER TABLE data.customer_intervention_reports
  ADD CONSTRAINT fk_cir_current_version
  FOREIGN KEY (current_published_version_id)
  REFERENCES data.customer_intervention_report_versions(id)
  ON DELETE SET NULL;

CREATE TABLE IF NOT EXISTS data.customer_intervention_report_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  report_id uuid NOT NULL REFERENCES data.customer_intervention_reports(id) ON DELETE CASCADE,
  project_id uuid NOT NULL,
  event_type text NOT NULL,
  version_id uuid REFERENCES data.customer_intervention_report_versions(id) ON DELETE SET NULL,
  draft_id uuid REFERENCES data.customer_intervention_report_drafts(id) ON DELETE SET NULL,
  actor_id uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_cire_report_created
  ON data.customer_intervention_report_events (report_id, created_at DESC);

CREATE TRIGGER trg_cir_updated_at
  BEFORE UPDATE ON data.customer_intervention_reports
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

CREATE TRIGGER trg_cird_updated_at
  BEFORE UPDATE ON data.customer_intervention_report_drafts
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

CREATE TRIGGER trg_cirmcj_updated_at
  BEFORE UPDATE ON data.customer_intervention_report_media_copy_jobs
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

-- Append-only versions
CREATE OR REPLACE FUNCTION data.trg_cir_versions_append_only()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    RAISE EXCEPTION 'customer_intervention_report_versions_immutable'
      USING ERRCODE = 'P0001';
  ELSIF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'customer_intervention_report_versions_no_delete'
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cir_versions_append_only ON data.customer_intervention_report_versions;
CREATE TRIGGER trg_cir_versions_append_only
  BEFORE UPDATE OR DELETE ON data.customer_intervention_report_versions
  FOR EACH ROW EXECUTE FUNCTION data.trg_cir_versions_append_only();

-- ---------------------------------------------------------------------------
-- 4. Project publish columns: projection from aggregate + block direct writes
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_cir_sync_project_published()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_pub_at timestamptz;
  v_pub_by uuid;
BEGIN
  IF NEW.current_published_version_id IS NOT NULL THEN
    SELECT v.published_at, v.published_by
      INTO v_pub_at, v_pub_by
    FROM data.customer_intervention_report_versions v
    WHERE v.id = NEW.current_published_version_id;

    PERFORM set_config('data.allow_client_report_projection', 'true', true);
    UPDATE data.projects
    SET
      client_report_published_at = v_pub_at,
      client_report_published_by = v_pub_by
    WHERE id = NEW.project_id;
    PERFORM set_config('data.allow_client_report_projection', 'false', true);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cir_sync_project_published ON data.customer_intervention_reports;
CREATE TRIGGER trg_cir_sync_project_published
  AFTER INSERT OR UPDATE OF current_published_version_id
  ON data.customer_intervention_reports
  FOR EACH ROW EXECUTE FUNCTION data.trg_cir_sync_project_published();

CREATE OR REPLACE FUNCTION data.trg_block_direct_client_report_published()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF COALESCE(current_setting('data.allow_client_report_projection', true), 'false') = 'true' THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE'
     AND (
       OLD.client_report_published_at IS DISTINCT FROM NEW.client_report_published_at
       OR OLD.client_report_published_by IS DISTINCT FROM NEW.client_report_published_by
     ) THEN
    -- Legacy publish RPC may still set these until dual-read retired (CP-A0.3–7).
    -- Allow when NEW matches an aggregate pointer for this project.
    IF EXISTS (
      SELECT 1
      FROM data.customer_intervention_reports r
      JOIN data.customer_intervention_report_versions v
        ON v.id = r.current_published_version_id
      WHERE r.project_id = NEW.id
        AND v.published_at IS NOT DISTINCT FROM NEW.client_report_published_at
    ) THEN
      RETURN NEW;
    END IF;
    -- Allow legacy path while no aggregate exists yet
    IF NOT EXISTS (
      SELECT 1 FROM data.customer_intervention_reports r WHERE r.project_id = NEW.id
    ) THEN
      RETURN NEW;
    END IF;
    RAISE EXCEPTION 'client_report_published_projection_only'
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_block_direct_client_report_published ON data.projects;
CREATE TRIGGER trg_block_direct_client_report_published
  BEFORE UPDATE OF client_report_published_at, client_report_published_by
  ON data.projects
  FOR EACH ROW EXECUTE FUNCTION data.trg_block_direct_client_report_published();

-- ---------------------------------------------------------------------------
-- 5. RLS
-- ---------------------------------------------------------------------------
ALTER TABLE data.customer_intervention_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.customer_intervention_report_drafts ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.customer_intervention_report_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.customer_intervention_report_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY cir_select ON data.customer_intervention_reports FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id()));

CREATE POLICY cird_select ON data.customer_intervention_report_drafts FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id()));

CREATE POLICY cirv_select ON data.customer_intervention_report_versions FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id()));

CREATE POLICY cire_select ON data.customer_intervention_report_events FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id()));

-- Mutations only via SECURITY DEFINER RPCs (P1/P2: no client forge path).
GRANT SELECT ON data.customer_intervention_reports TO authenticated;
GRANT SELECT ON data.customer_intervention_report_drafts TO authenticated;
GRANT SELECT ON data.customer_intervention_report_versions TO authenticated;
GRANT SELECT ON data.customer_intervention_report_events TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.customer_intervention_reports TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.customer_intervention_report_drafts TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.customer_intervention_report_versions TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.customer_intervention_report_events TO service_role;

-- ---------------------------------------------------------------------------
-- 6. Storage bucket (private; no authenticated write)
-- ---------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'customer-report-media',
  'customer-report-media',
  false,
  52428800,
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
)
ON CONFLICT (id) DO UPDATE SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Staff may read objects for their tenant prefix: {tenant_id}/...
DROP POLICY IF EXISTS "customer-report-media: tenant read" ON storage.objects;
CREATE POLICY "customer-report-media: tenant read"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'customer-report-media'
    AND data.jwt_user_tenants() ? SPLIT_PART(name, '/', 1)
  );

-- No INSERT/UPDATE/DELETE for authenticated — privileged writers only (service_role).

-- ---------------------------------------------------------------------------
-- 7. API views
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.customer_intervention_reports
  WITH (security_invoker = true) AS
SELECT r.*
FROM data.customer_intervention_reports r
WHERE r.tenant_id = data.active_tenant_id();

CREATE OR REPLACE VIEW api.customer_intervention_report_drafts
  WITH (security_invoker = true) AS
SELECT d.*
FROM data.customer_intervention_report_drafts d
WHERE d.tenant_id = data.active_tenant_id();

CREATE OR REPLACE VIEW api.customer_intervention_report_versions
  WITH (security_invoker = true) AS
SELECT v.*
FROM data.customer_intervention_report_versions v
WHERE v.tenant_id = data.active_tenant_id();

CREATE OR REPLACE VIEW api.customer_intervention_report_events
  WITH (security_invoker = true) AS
SELECT e.*
FROM data.customer_intervention_report_events e
WHERE e.tenant_id = data.active_tenant_id();

GRANT SELECT ON api.customer_intervention_reports TO authenticated;
GRANT SELECT ON api.customer_intervention_report_drafts TO authenticated;
GRANT SELECT ON api.customer_intervention_report_versions TO authenticated;
GRANT SELECT ON api.customer_intervention_report_events TO authenticated;

-- ---------------------------------------------------------------------------
-- 8. Helpers: allowlist projection strip
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.build_customer_report_safe_projection(
  p_projection jsonb,
  p_client_summary_html text,
  p_snapshots jsonb
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'schema_version', COALESCE(p_projection->>'schema_version', '1.0'),
    'tenant', p_projection->'tenant',
    'customer_account', p_projection->'customer_account',
    'site', p_projection->'site',
    'intervention', p_projection->'intervention',
    'client_summary_html', p_client_summary_html,
    'checklist_items', COALESCE(p_projection->'checklist_items', '[]'::jsonb),
    'support_contact', p_projection->'support_contact',
    'snapshots', COALESCE(p_snapshots, '{}'::jsonb)
  ))
  -- Explicitly drop known-sensitive / retired keys if present in input
  - 'recipient'
  - 'work_notes_html'
  - 'internal_notes'
  - 'costs'
  - 'margins'
  - 'material_costs'
  - 'bypass_reasons';
$$;

-- ---------------------------------------------------------------------------
-- 9. RPCs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.ensure_customer_intervention_report(p_project_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid;
  v_site uuid;
  v_id uuid;
  v_status text;
BEGIN
  SELECT p.tenant_id, p.site_id, p.status
    INTO v_tenant, v_site, v_status
  FROM data.projects p WHERE p.id = p_project_id;

  IF v_tenant IS NULL OR v_tenant IS DISTINCT FROM data.active_tenant_id() THEN
    RAISE EXCEPTION 'project_not_found' USING ERRCODE = 'P0001';
  END IF;

  PERFORM data.require_fresh_tenant_permission(
    v_tenant, 'field_service.reports.publish', v_site
  );

  IF NOT data.can_access_project(p_project_id) THEN
    RAISE EXCEPTION 'project_access_denied' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO data.customer_intervention_reports (tenant_id, project_id, created_by)
  VALUES (v_tenant, p_project_id, auth.uid())
  ON CONFLICT (tenant_id, project_id, report_type) DO UPDATE
    SET updated_at = now()
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.upsert_customer_intervention_report_draft(
  p_project_id uuid,
  p_locale text DEFAULT 'ca',
  p_client_summary_html text DEFAULT NULL,
  p_projection jsonb DEFAULT '{}'::jsonb,
  p_selected_media jsonb DEFAULT NULL,
  p_draft_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_site uuid;
  v_client uuid;
  v_csite uuid;
  v_report uuid;
  v_draft uuid;
BEGIN
  SELECT p.site_id, p.client_id, p.contact_site_id
    INTO v_site, v_client, v_csite
  FROM data.projects p
  WHERE p.id = p_project_id AND p.tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'project_not_found' USING ERRCODE = 'P0001';
  END IF;

  -- Draft allowed while project is open; publish gates on completed/on_hold.
  PERFORM data.require_fresh_tenant_permission(
    v_tenant, 'field_service.reports.regenerate', v_site
  );

  v_report := api.ensure_customer_intervention_report(p_project_id);

  IF p_draft_id IS NOT NULL THEN
    UPDATE data.customer_intervention_report_drafts
    SET
      locale = COALESCE(NULLIF(p_locale, ''), locale),
      client_summary_html = p_client_summary_html,
      projection = COALESCE(p_projection, '{}'::jsonb),
      selected_media = COALESCE(p_selected_media, selected_media),
      customer_account_contact_id = COALESCE(customer_account_contact_id, v_client),
      contact_site_id = COALESCE(contact_site_id, v_csite),
      status = 'draft',
      failure_reason = NULL,
      updated_by = auth.uid(),
      updated_at = now()
    WHERE id = p_draft_id
      AND report_id = v_report
      AND tenant_id = v_tenant
      AND status IN ('draft', 'ready', 'failed')
    RETURNING id INTO v_draft;

    IF v_draft IS NULL THEN
      RAISE EXCEPTION 'draft_not_found_or_locked' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_draft;
  END IF;

  -- Supersede previous open drafts
  UPDATE data.customer_intervention_report_drafts
  SET status = 'superseded', updated_at = now()
  WHERE report_id = v_report
    AND status IN ('draft', 'ready', 'failed');

  INSERT INTO data.customer_intervention_report_drafts (
    tenant_id, report_id, project_id, status,
    customer_account_contact_id, contact_site_id,
    locale, client_summary_html, projection, selected_media,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_report, p_project_id, 'draft',
    v_client, v_csite,
    COALESCE(NULLIF(p_locale, ''), 'ca'),
    p_client_summary_html,
    COALESCE(p_projection, '{}'::jsonb),
    COALESCE(p_selected_media, '[]'::jsonb),
    auth.uid(), auth.uid()
  )
  RETURNING id INTO v_draft;

  RETURN v_draft;
END;
$$;

CREATE OR REPLACE FUNCTION api.preview_customer_intervention_report_draft(p_draft_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_draft data.customer_intervention_report_drafts%ROWTYPE;
  v_site uuid;
BEGIN
  SELECT * INTO v_draft
  FROM data.customer_intervention_report_drafts
  WHERE id = p_draft_id AND tenant_id = data.active_tenant_id();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'draft_not_found' USING ERRCODE = 'P0001';
  END IF;

  SELECT p.site_id INTO v_site FROM data.projects p WHERE p.id = v_draft.project_id;
  PERFORM data.require_fresh_tenant_permission(
    v_draft.tenant_id, 'field_service.reports.preview_as_customer', v_site
  );

  RETURN data.build_customer_report_safe_projection(
    v_draft.projection,
    v_draft.client_summary_html,
    jsonb_build_object(
      'customer_account_contact_id', v_draft.customer_account_contact_id,
      'contact_site_id', v_draft.contact_site_id
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.prepare_customer_intervention_report_media(p_draft_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_draft data.customer_intervention_report_drafts%ROWTYPE;
  v_site uuid;
  v_manifest jsonb := '[]'::jsonb;
  v_item jsonb;
  v_node data.file_nodes%ROWTYPE;
  v_file_node_id uuid;
  v_i int;
  v_key text;
  v_pending int := 0;
  v_status text;
  v_base_manifest jsonb;
BEGIN
  SELECT * INTO v_draft
  FROM data.customer_intervention_report_drafts
  WHERE id = p_draft_id AND tenant_id = data.active_tenant_id()
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'draft_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF v_draft.status = 'superseded' THEN
    RAISE EXCEPTION 'draft_not_preparable' USING ERRCODE = 'P0001';
  END IF;

  SELECT p.site_id INTO v_site FROM data.projects p WHERE p.id = v_draft.project_id;
  PERFORM data.require_fresh_tenant_permission(
    v_draft.tenant_id, 'field_service.reports.publish', v_site
  );

  IF jsonb_typeof(COALESCE(v_draft.selected_media, '[]'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'selected_media_must_be_array' USING ERRCODE = 'P0001';
  END IF;

  -- A corrected draft may reuse the immutable media manifest of its base
  -- version without reading any original source object again.
  IF jsonb_array_length(COALESCE(v_draft.selected_media, '[]'::jsonb)) = 0
     AND v_draft.based_on_version_id IS NOT NULL THEN
    SELECT media_manifest INTO v_base_manifest
    FROM data.customer_intervention_report_versions
    WHERE id = v_draft.based_on_version_id
      AND report_id = v_draft.report_id
      AND tenant_id = v_draft.tenant_id;

    IF NOT FOUND OR v_base_manifest IS DISTINCT FROM v_draft.media_manifest THEN
      RAISE EXCEPTION 'correction_media_manifest_mismatch' USING ERRCODE = 'P0001';
    END IF;

    UPDATE data.customer_intervention_report_drafts
    SET status = 'ready', failure_reason = NULL, updated_at = now(), updated_by = auth.uid()
    WHERE id = v_draft.id;

    RETURN jsonb_build_object(
      'draft_id', v_draft.id,
      'status', 'ready',
      'media_manifest', v_base_manifest,
      'pending_count', 0,
      'reused_from_version_id', v_draft.based_on_version_id
    );
  END IF;

  UPDATE data.customer_intervention_report_drafts
  SET status = 'preparing_media', updated_at = now(), updated_by = auth.uid()
  WHERE id = v_draft.id;

  DELETE FROM data.customer_intervention_report_media_copy_jobs
  WHERE draft_id = v_draft.id;

  -- Only file_node_id is caller-controlled. All storage coordinates and
  -- metadata are resolved from file_nodes after tenant/project/read checks.
  FOR v_i IN 0 .. GREATEST(jsonb_array_length(COALESCE(v_draft.selected_media, '[]'::jsonb)) - 1, -1)
  LOOP
    v_item := v_draft.selected_media -> v_i;
    IF v_item IS NULL OR v_item = 'null'::jsonb THEN
      RAISE EXCEPTION 'media_item_required' USING ERRCODE = 'P0001';
    END IF;
    IF jsonb_typeof(v_item) <> 'object' THEN
      RAISE EXCEPTION 'media_item_must_be_object' USING ERRCODE = 'P0001';
    END IF;
    IF (v_item->>'include') = 'false' THEN
      CONTINUE;
    END IF;

    IF v_item ?| ARRAY['bucket', 'source_bucket', 'storage_key', 'object_key', 'source'] THEN
      RAISE EXCEPTION 'media_storage_coordinates_forbidden' USING ERRCODE = 'P0001';
    END IF;
    IF NULLIF(btrim(v_item->>'file_node_id'), '') IS NULL THEN
      RAISE EXCEPTION 'file_node_id_required' USING ERRCODE = 'P0001';
    END IF;

    BEGIN
      v_file_node_id := (v_item->>'file_node_id')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'invalid_file_node_id' USING ERRCODE = 'P0001';
    END;

    SELECT * INTO v_node
    FROM data.file_nodes fn
    WHERE fn.id = v_file_node_id
      AND fn.tenant_id = v_draft.tenant_id
      AND fn.node_type = 'file'
      AND fn.is_deleted = false
      AND fn.processing_status = 'done'
      AND fn.storage_provider_id IS NULL
      AND fn.storage_key IS NOT NULL
      AND (
        (fn.entity_type = 'project' AND fn.entity_id = v_draft.project_id)
        OR fn.metadata->>'project_id' = v_draft.project_id::text
      );

    IF NOT FOUND THEN
      RAISE EXCEPTION 'media_file_node_not_available' USING ERRCODE = 'P0001';
    END IF;

    IF NOT data.can_access_via_permissions(
      v_node.id,
      v_node.is_restricted,
      v_node.created_by,
      v_node.ancestor_paths,
      v_node.tenant_id
    ) THEN
      RAISE EXCEPTION 'media_file_node_access_denied' USING ERRCODE = 'P0001';
    END IF;

    IF v_node.storage_key NOT LIKE
       v_draft.tenant_id::text || '/' || v_node.id::text || '/%' THEN
      RAISE EXCEPTION 'media_storage_key_out_of_scope' USING ERRCODE = 'P0001';
    END IF;

    v_key := format(
      '%s/%s/%s/%s',
      v_draft.tenant_id,
      v_draft.report_id,
      v_draft.id,
      v_i::text || '-' || v_node.id::text || '-' ||
        regexp_replace(v_node.name, '[^a-zA-Z0-9._-]+', '_', 'g')
    );
    IF length(v_key) > 500 THEN
      v_key := format(
        '%s/%s/%s/%s',
        v_draft.tenant_id, v_draft.report_id, v_draft.id,
        v_i::text || '-' || v_node.id::text
      );
    END IF;

    INSERT INTO data.customer_intervention_report_media_copy_jobs (
      tenant_id, report_id, draft_id, project_id, item_index, file_node_id,
      source_bucket, source_object_key,
      destination_bucket, destination_object_key,
      content_type, expected_size_bytes, source_checksum
    ) VALUES (
      v_draft.tenant_id, v_draft.report_id, v_draft.id, v_draft.project_id,
      v_i, v_node.id, 'tenant-files', v_node.storage_key,
      'customer-report-media', v_key,
      COALESCE(NULLIF(v_node.mime_type, ''), 'application/octet-stream'),
      v_node.size_bytes, v_node.checksum
    );

    v_manifest := v_manifest || jsonb_build_array(jsonb_build_object(
      'file_node_id', v_node.id,
      'bucket', 'customer-report-media',
      'object_key', v_key,
      'content_type', COALESCE(NULLIF(v_node.mime_type, ''), 'application/octet-stream'),
      'size_bytes', v_node.size_bytes,
      'copy_status', 'pending'
    ));
    v_pending := v_pending + 1;
  END LOOP;

  v_status := CASE WHEN v_pending = 0 THEN 'ready' ELSE 'preparing_media' END;

  UPDATE data.customer_intervention_report_drafts
  SET
    media_manifest = v_manifest,
    status = v_status,
    failure_reason = NULL,
    updated_at = now(),
    updated_by = auth.uid()
  WHERE id = v_draft.id;

  INSERT INTO data.customer_intervention_report_events (
    tenant_id, report_id, project_id, event_type, draft_id, actor_id, payload
  ) VALUES (
    v_draft.tenant_id, v_draft.report_id, v_draft.project_id,
    'MEDIA_PREPARED', v_draft.id, auth.uid(),
    jsonb_build_object(
      'media_count', jsonb_array_length(v_manifest),
      'pending_count', v_pending,
      'status', v_status
    )
  );

  RETURN jsonb_build_object(
    'draft_id', v_draft.id,
    'status', v_status,
    'media_manifest', v_manifest,
    'pending_count', v_pending
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.authorize_customer_intervention_report_media_copy(
  p_draft_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_draft data.customer_intervention_report_drafts%ROWTYPE;
  v_site uuid;
BEGIN
  SELECT * INTO v_draft
  FROM data.customer_intervention_report_drafts
  WHERE id = p_draft_id AND tenant_id = data.active_tenant_id()
  ;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'draft_not_found' USING ERRCODE = 'P0001';
  END IF;

  SELECT p.site_id INTO v_site FROM data.projects p WHERE p.id = v_draft.project_id;
  PERFORM data.require_fresh_tenant_permission(
    v_draft.tenant_id, 'field_service.reports.publish', v_site
  );

  IF v_draft.status <> 'preparing_media' THEN
    RAISE EXCEPTION 'draft_not_copyable:%', v_draft.status USING ERRCODE = 'P0001';
  END IF;

  RETURN jsonb_build_object(
    'draft_id', v_draft.id,
    'tenant_id', v_draft.tenant_id,
    'status', v_draft.status
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.claim_customer_intervention_report_media_copy_jobs(
  p_draft_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_manifest jsonb;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.customer_intervention_report_drafts
    WHERE id = p_draft_id AND status IN ('preparing_media', 'ready')
  ) THEN
    RAISE EXCEPTION 'draft_not_copyable' USING ERRCODE = 'P0001';
  END IF;

  WITH claimed AS (
    UPDATE data.customer_intervention_report_media_copy_jobs
    SET
      status = 'processing',
      attempt_count = attempt_count + 1,
      failure_reason = NULL,
      claimed_at = now(),
      updated_at = now()
    WHERE draft_id = p_draft_id
      AND (
        status IN ('pending', 'failed')
        OR (status = 'processing' AND claimed_at < now() - interval '15 minutes')
      )
    RETURNING *
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'job_id', j.id,
    'tenant_id', j.tenant_id,
    'source_bucket', j.source_bucket,
    'source_object_key', j.source_object_key,
    'destination_bucket', j.destination_bucket,
    'destination_object_key', j.destination_object_key,
    'content_type', j.content_type,
    'expected_size_bytes', j.expected_size_bytes,
    'status', j.status
  ) ORDER BY j.item_index), '[]'::jsonb)
  INTO v_manifest
  FROM claimed j;

  RETURN v_manifest;
END;
$$;

CREATE OR REPLACE FUNCTION api.mark_customer_intervention_report_media_copy_job(
  p_job_id uuid,
  p_succeeded boolean,
  p_copied_size_bytes bigint DEFAULT NULL,
  p_failure_reason text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_job data.customer_intervention_report_media_copy_jobs%ROWTYPE;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_job
  FROM data.customer_intervention_report_media_copy_jobs
  WHERE id = p_job_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'copy_job_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF v_job.status = 'ok' AND p_succeeded THEN
    RETURN;
  END IF;
  IF v_job.status <> 'processing' THEN
    RAISE EXCEPTION 'copy_job_not_claimed' USING ERRCODE = 'P0001';
  END IF;

  IF p_succeeded
     AND v_job.expected_size_bytes > 0
     AND p_copied_size_bytes IS DISTINCT FROM v_job.expected_size_bytes THEN
    p_succeeded := false;
    p_failure_reason := 'copied_size_mismatch';
  END IF;

  UPDATE data.customer_intervention_report_media_copy_jobs
  SET
    status = CASE WHEN p_succeeded THEN 'ok' ELSE 'failed' END,
    copied_size_bytes = p_copied_size_bytes,
    failure_reason = CASE WHEN p_succeeded THEN NULL
      ELSE left(COALESCE(NULLIF(p_failure_reason, ''), 'media_copy_failed'), 500) END,
    completed_at = now(),
    updated_at = now()
  WHERE id = v_job.id;

  IF NOT p_succeeded THEN
    UPDATE data.customer_intervention_report_drafts
    SET
      status = 'failed',
      failure_reason = left(COALESCE(NULLIF(p_failure_reason, ''), 'media_copy_failed'), 500),
      updated_at = now()
    WHERE id = v_job.draft_id;
  END IF;
END;
$$;

-- Called only by the service-role worker after every object has landed.
-- The public manifest is rebuilt from the private ledger; callers cannot
-- supply or alter completion state.
CREATE OR REPLACE FUNCTION api.complete_customer_intervention_report_media_prepare(
  p_draft_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_draft data.customer_intervention_report_drafts%ROWTYPE;
  v_manifest jsonb;
  v_incomplete int;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_draft
  FROM data.customer_intervention_report_drafts
  WHERE id = p_draft_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'draft_not_found' USING ERRCODE = 'P0001';
  END IF;

  SELECT COUNT(*)::int INTO v_incomplete
  FROM data.customer_intervention_report_media_copy_jobs
  WHERE draft_id = p_draft_id
    AND status <> 'ok';

  IF v_incomplete > 0 THEN
    RAISE EXCEPTION 'media_copy_incomplete' USING ERRCODE = 'P0001';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'file_node_id', j.file_node_id,
    'bucket', j.destination_bucket,
    'object_key', j.destination_object_key,
    'content_type', j.content_type,
    'size_bytes', COALESCE(j.copied_size_bytes, j.expected_size_bytes),
    'copy_status', 'ok'
  ) ORDER BY j.item_index), '[]'::jsonb)
  INTO v_manifest
  FROM data.customer_intervention_report_media_copy_jobs j
  WHERE j.draft_id = p_draft_id;

  UPDATE data.customer_intervention_report_drafts
  SET
    media_manifest = v_manifest,
    status = 'ready',
    failure_reason = NULL,
    updated_at = now()
  WHERE id = v_draft.id;

  INSERT INTO data.customer_intervention_report_events (
    tenant_id, report_id, project_id, event_type, draft_id, actor_id, payload
  ) VALUES (
    v_draft.tenant_id, v_draft.report_id, v_draft.project_id,
    'MEDIA_COPY_COMPLETED', v_draft.id, NULL,
    jsonb_build_object('media_count', jsonb_array_length(v_manifest))
  );

  RETURN jsonb_build_object(
    'draft_id', v_draft.id,
    'status', 'ready',
    'media_manifest', v_manifest
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.publish_customer_intervention_report(p_draft_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_draft data.customer_intervention_report_drafts%ROWTYPE;
  v_report data.customer_intervention_reports%ROWTYPE;
  v_site uuid;
  v_project data.projects%ROWTYPE;
  v_version_no int;
  v_version_id uuid;
  v_safe jsonb;
  v_digest text;
  v_prev uuid;
BEGIN
  SELECT * INTO v_draft
  FROM data.customer_intervention_report_drafts
  WHERE id = p_draft_id AND tenant_id = data.active_tenant_id()
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'draft_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF v_draft.status IS DISTINCT FROM 'ready' THEN
    RAISE EXCEPTION 'draft_not_ready:%', v_draft.status USING ERRCODE = 'P0001';
  END IF;

  -- Block publish while any media item is still pending copy
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(COALESCE(v_draft.media_manifest, '[]'::jsonb)) m
    WHERE COALESCE(m->>'copy_status', 'pending') = 'pending'
  ) THEN
    RAISE EXCEPTION 'media_copy_pending' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_report
  FROM data.customer_intervention_reports
  WHERE id = v_draft.report_id
  FOR UPDATE;

  SELECT * INTO v_project FROM data.projects WHERE id = v_draft.project_id FOR UPDATE;
  v_site := v_project.site_id;

  PERFORM data.require_fresh_tenant_permission(
    v_draft.tenant_id, 'field_service.reports.publish', v_site
  );

  IF NOT data.can_access_project(v_draft.project_id) THEN
    RAISE EXCEPTION 'project_access_denied' USING ERRCODE = 'P0001';
  END IF;

  IF v_project.status NOT IN ('completed', 'on_hold') THEN
    RAISE EXCEPTION 'project_not_closed' USING ERRCODE = 'P0001';
  END IF;

  IF v_report.legacy_unresolved THEN
    RAISE EXCEPTION 'legacy_unresolved' USING ERRCODE = 'P0001';
  END IF;

  -- Account identity from project.client_id (publish does not require a recipient)
  v_draft.customer_account_contact_id := COALESCE(
    v_draft.customer_account_contact_id, v_project.client_id
  );
  IF v_draft.customer_account_contact_id IS NULL THEN
    RAISE EXCEPTION 'customer_account_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT COALESCE(MAX(version_number), 0) + 1 INTO v_version_no
  FROM data.customer_intervention_report_versions
  WHERE report_id = v_report.id;

  v_safe := data.build_customer_report_safe_projection(
    v_draft.projection,
    v_draft.client_summary_html,
    jsonb_build_object(
      'customer_account_contact_id', v_draft.customer_account_contact_id,
      'contact_site_id', COALESCE(v_draft.contact_site_id, v_project.contact_site_id)
    )
  );
  v_digest := encode(extensions.digest(v_safe::text, 'sha256'), 'hex');

  v_prev := v_report.current_published_version_id;

  INSERT INTO data.customer_intervention_report_versions (
    tenant_id, report_id, project_id, version_number, draft_id,
    customer_account_contact_id, contact_site_id,
    locale, schema_version, template_version, content_digest,
    projection, media_manifest, snapshots, published_by
  ) VALUES (
    v_draft.tenant_id, v_report.id, v_draft.project_id, v_version_no, v_draft.id,
    v_draft.customer_account_contact_id,
    COALESCE(v_draft.contact_site_id, v_project.contact_site_id),
    v_draft.locale, v_draft.schema_version, v_draft.template_version, v_digest,
    v_safe, v_draft.media_manifest,
    jsonb_build_object(
      'customer_account_contact_id', v_draft.customer_account_contact_id,
      'contact_site_id', COALESCE(v_draft.contact_site_id, v_project.contact_site_id)
    ),
    auth.uid()
  )
  RETURNING id INTO v_version_id;

  UPDATE data.customer_intervention_reports
  SET current_published_version_id = v_version_id, updated_at = now()
  WHERE id = v_report.id;

  UPDATE data.customer_intervention_report_drafts
  SET status = 'superseded', updated_at = now()
  WHERE id = v_draft.id;

  INSERT INTO data.customer_intervention_report_events (
    tenant_id, report_id, project_id, event_type, version_id, draft_id, actor_id, payload
  ) VALUES (
    v_draft.tenant_id, v_report.id, v_draft.project_id,
    CASE WHEN v_prev IS NULL THEN 'CLIENT_REPORT_PUBLISHED' ELSE 'CLIENT_REPORT_VERSION_CREATED' END,
    v_version_id, v_draft.id, auth.uid(),
    jsonb_build_object(
      'version_number', v_version_no,
      'previous_version_id', v_prev,
      'content_digest', v_digest
    )
  );

  PERFORM data.log_audit_event_strict(
    v_draft.tenant_id, auth.uid(), v_site,
    CASE WHEN v_prev IS NULL THEN 'CLIENT_REPORT_PUBLISHED' ELSE 'CLIENT_REPORT_VERSION_CREATED' END,
    'customer_intervention_report_version', v_version_id,
    jsonb_build_object('project_id', v_draft.project_id, 'version_number', v_version_no)
  );

  RETURN v_version_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.create_corrected_customer_intervention_report_draft(p_report_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_report data.customer_intervention_reports%ROWTYPE;
  v_ver data.customer_intervention_report_versions%ROWTYPE;
  v_site uuid;
  v_draft uuid;
BEGIN
  SELECT * INTO v_report
  FROM data.customer_intervention_reports
  WHERE id = p_report_id AND tenant_id = data.active_tenant_id();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'report_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF v_report.current_published_version_id IS NULL THEN
    RAISE EXCEPTION 'no_published_version' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_ver
  FROM data.customer_intervention_report_versions
  WHERE id = v_report.current_published_version_id;

  SELECT p.site_id INTO v_site FROM data.projects p WHERE p.id = v_report.project_id;
  PERFORM data.require_fresh_tenant_permission(
    v_report.tenant_id, 'field_service.reports.regenerate', v_site
  );

  UPDATE data.customer_intervention_report_drafts
  SET status = 'superseded', updated_at = now()
  WHERE report_id = v_report.id
    AND status IN ('draft', 'preparing_media', 'ready', 'failed');

  INSERT INTO data.customer_intervention_report_drafts (
    tenant_id, report_id, project_id, status,
    customer_account_contact_id, contact_site_id,
    locale, client_summary_html, projection, selected_media, media_manifest,
    based_on_version_id, schema_version, template_version, created_by, updated_by
  ) VALUES (
    v_report.tenant_id, v_report.id, v_report.project_id, 'draft',
    v_ver.customer_account_contact_id, v_ver.contact_site_id,
    v_ver.locale,
    v_ver.projection->>'client_summary_html',
    v_ver.projection,
    '[]'::jsonb,
    v_ver.media_manifest,
    v_ver.id,
    v_ver.schema_version, v_ver.template_version,
    auth.uid(), auth.uid()
  )
  RETURNING id INTO v_draft;

  INSERT INTO data.customer_intervention_report_events (
    tenant_id, report_id, project_id, event_type, draft_id, version_id, actor_id, payload
  ) VALUES (
    v_report.tenant_id, v_report.id, v_report.project_id,
    'CORRECTION_DRAFT_CREATED', v_draft, v_ver.id, auth.uid(),
    jsonb_build_object('from_version', v_ver.version_number)
  );

  RETURN v_draft;
END;
$$;

GRANT EXECUTE ON FUNCTION api.ensure_customer_intervention_report(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.upsert_customer_intervention_report_draft(uuid, text, text, jsonb, jsonb, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.preview_customer_intervention_report_draft(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.prepare_customer_intervention_report_media(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.authorize_customer_intervention_report_media_copy(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.claim_customer_intervention_report_media_copy_jobs(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION api.mark_customer_intervention_report_media_copy_job(uuid, boolean, bigint, text) TO service_role;
GRANT EXECUTE ON FUNCTION api.complete_customer_intervention_report_media_prepare(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION api.publish_customer_intervention_report(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.create_corrected_customer_intervention_report_draft(uuid) TO authenticated;

REVOKE ALL ON FUNCTION api.ensure_customer_intervention_report(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.upsert_customer_intervention_report_draft(uuid, text, text, jsonb, jsonb, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.preview_customer_intervention_report_draft(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.prepare_customer_intervention_report_media(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.authorize_customer_intervention_report_media_copy(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.claim_customer_intervention_report_media_copy_jobs(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION api.mark_customer_intervention_report_media_copy_job(uuid, boolean, bigint, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION api.complete_customer_intervention_report_media_prepare(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION api.publish_customer_intervention_report(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.create_corrected_customer_intervention_report_draft(uuid) FROM PUBLIC;
