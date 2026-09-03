-- =============================================================================
-- REC-7 — Recruitment inbound email inbox (MVP stub + RPCs)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Settings
-- ---------------------------------------------------------------------------
ALTER TABLE data.recruitment_settings
  ADD COLUMN IF NOT EXISTS inbound_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS inbound_address_hint text;

COMMENT ON COLUMN data.recruitment_settings.inbound_enabled IS
  'REC-7: when true, Resend Inbound Edge may ingest for this tenant. Stub ingest (service_role) may still run for tests.';
COMMENT ON COLUMN data.recruitment_settings.inbound_address_hint IS
  'Documental: adreça publicada als candidats (ex. feina@empresa.com). No resol MX.';

DROP VIEW IF EXISTS api.recruitment_settings;
CREATE VIEW api.recruitment_settings
WITH (security_invoker = true) AS
SELECT
  tenant_id,
  default_max_retention_months,
  expire_closes_process,
  rights_sla_days,
  rejection_notify_policy,
  privacy_policy_url,
  import_legal_basis,
  import_legal_basis_note,
  enforce_department_scope,
  analytics_min_cohort,
  candidate_portal_base_url,
  rights_sla_notify_emails,
  inbound_enabled,
  inbound_address_hint,
  created_at,
  updated_at
FROM data.recruitment_settings;

GRANT SELECT, UPDATE ON api.recruitment_settings TO authenticated;

REVOKE ALL ON data.recruitment_settings FROM authenticated;

GRANT SELECT (
  tenant_id,
  default_max_retention_months,
  expire_closes_process,
  rights_sla_days,
  rejection_notify_policy,
  privacy_policy_url,
  import_legal_basis,
  import_legal_basis_note,
  enforce_department_scope,
  analytics_min_cohort,
  candidate_portal_base_url,
  rights_sla_notify_emails,
  inbound_enabled,
  inbound_address_hint,
  created_at,
  updated_at
) ON data.recruitment_settings TO authenticated;

GRANT UPDATE (
  default_max_retention_months,
  expire_closes_process,
  rights_sla_days,
  rejection_notify_policy,
  privacy_policy_url,
  import_legal_basis,
  import_legal_basis_note,
  enforce_department_scope,
  analytics_min_cohort,
  candidate_portal_base_url,
  rights_sla_notify_emails,
  inbound_enabled,
  inbound_address_hint,
  updated_at
) ON data.recruitment_settings TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Inbox table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.recruitment_email_inbox (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  status                   text NOT NULL DEFAULT 'unassigned'
    CHECK (status IN ('unassigned', 'assigned', 'discarded')),
  from_email               text NOT NULL,
  from_name                text,
  subject                  text,
  body_text                text,
  body_html                text,
  received_at              timestamptz NOT NULL DEFAULT now(),
  resend_email_id          text,
  detected_posting_id      uuid REFERENCES data.job_postings(id) ON DELETE SET NULL,
  assigned_application_id  uuid REFERENCES data.applications(id) ON DELETE SET NULL,
  assigned_posting_id      uuid REFERENCES data.job_postings(id) ON DELETE SET NULL,
  assigned_at              timestamptz,
  assigned_by              uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  discarded_at             timestamptz,
  discarded_by             uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  discard_reason           text,
  raw_payload              jsonb,
  attachment_paths         text[] NOT NULL DEFAULT '{}',
  dedupe_key               text,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_recruitment_email_inbox_resend
  ON data.recruitment_email_inbox (tenant_id, resend_email_id)
  WHERE resend_email_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_recruitment_email_inbox_dedupe
  ON data.recruitment_email_inbox (tenant_id, dedupe_key)
  WHERE dedupe_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_recruitment_email_inbox_tenant_status
  ON data.recruitment_email_inbox (tenant_id, status, received_at DESC);

COMMENT ON TABLE data.recruitment_email_inbox IS
  'REC-7: inbound recruitment emails. Majority case = unassigned until RRHH assigns.';

ALTER TABLE data.recruitment_email_inbox ENABLE ROW LEVEL SECURITY;

CREATE POLICY recruitment_email_inbox_select ON data.recruitment_email_inbox
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_recruitment_permission(tenant_id, 'recruitment.view')
  );

CREATE POLICY recruitment_email_inbox_write ON data.recruitment_email_inbox
  FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_recruitment_permission(tenant_id, 'recruitment.manage')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

DROP POLICY IF EXISTS recruitment_module_enabled ON data.recruitment_email_inbox;
CREATE POLICY recruitment_module_enabled ON data.recruitment_email_inbox
  AS RESTRICTIVE
  FOR ALL
  TO authenticated
  USING (data.recruitment_module_enabled(tenant_id))
  WITH CHECK (data.recruitment_module_enabled(tenant_id));

CREATE OR REPLACE VIEW api.recruitment_email_inbox
WITH (security_invoker = true) AS
SELECT
  id, tenant_id, status,
  from_email, from_name, subject, body_text, body_html,
  received_at, resend_email_id,
  detected_posting_id, assigned_application_id, assigned_posting_id,
  assigned_at, assigned_by, discarded_at, discarded_by, discard_reason,
  attachment_paths, created_at, updated_at
FROM data.recruitment_email_inbox;

GRANT SELECT ON api.recruitment_email_inbox TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.parse_posting_id_from_subject(p_subject text)
RETURNS uuid
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_m text[];
BEGIN
  IF p_subject IS NULL OR btrim(p_subject) = '' THEN
    RETURN NULL;
  END IF;
  v_m := regexp_match(
    p_subject,
    '\[posting:([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\]',
    'i'
  );
  IF v_m IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN v_m[1]::uuid;
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION data.parse_posting_id_from_subject(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.parse_posting_id_from_subject(text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.create_application_from_inbound_email(
  p_tenant_id uuid,
  p_job_posting_id uuid,
  p_from_email text,
  p_from_name text,
  p_cover text DEFAULT NULL,
  p_locale text DEFAULT NULL,
  p_cv_storage_path text DEFAULT NULL,
  p_data_source_label text DEFAULT 'email inbound'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_posting data.job_postings%ROWTYPE;
  v_settings data.recruitment_settings%ROWTYPE;
  v_stage_id uuid;
  v_email text := lower(NULLIF(btrim(COALESCE(p_from_email, '')), ''));
  v_name text := NULLIF(btrim(COALESCE(p_from_name, '')), '');
  v_locale text;
  v_applicant_id uuid;
  v_application_id uuid;
  v_existing uuid;
  v_verified timestamptz;
  v_art14_sent timestamptz;
  v_suppressed boolean;
  v_basis text;
  v_basis_label text;
  v_retention_pref text := 'delete_after_months';
  v_retention_months int;
  v_rights_url text := '';
  v_base text;
  v_art14 boolean := false;
BEGIN
  IF v_email IS NULL OR v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'invalid_email';
  END IF;

  IF v_name IS NULL THEN
    v_name := split_part(v_email, '@', 1);
  END IF;

  SELECT * INTO v_posting
  FROM data.job_postings
  WHERE id = p_job_posting_id AND tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'posting_not_found';
  END IF;

  SELECT * INTO v_settings
  FROM data.recruitment_settings
  WHERE tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'recruitment_settings_missing';
  END IF;

  v_basis := COALESCE(v_settings.import_legal_basis, 'legitimate_interest');
  IF v_basis = 'other'
     AND NULLIF(btrim(COALESCE(v_settings.import_legal_basis_note, '')), '') IS NULL THEN
    RAISE EXCEPTION 'legal_basis_note_required';
  END IF;

  v_basis_label := CASE v_basis
    WHEN 'legitimate_interest' THEN 'Interès legítim (selecció)'
    WHEN 'consent' THEN 'Consentiment'
    ELSE COALESCE(NULLIF(btrim(v_settings.import_legal_basis_note), ''), 'Altra base legal')
  END;

  v_retention_months := COALESCE(v_settings.default_max_retention_months, 12);
  v_locale := data.normalize_recruitment_locale(p_locale);

  SELECT id INTO v_stage_id
  FROM data.pipeline_stages
  WHERE tenant_id = p_tenant_id
    AND (job_posting_id = v_posting.id OR job_posting_id IS NULL)
  ORDER BY job_posting_id NULLS LAST, position
  LIMIT 1;

  v_base := data.resolve_candidate_portal_base_url(p_tenant_id);
  IF v_base IS NOT NULL THEN
    v_rights_url := rtrim(v_base, '/') || '/recruitment/rights';
  END IF;

  INSERT INTO data.applicants (
    tenant_id, email, full_name, preferred_locale
  ) VALUES (
    p_tenant_id, v_email, v_name, v_locale
  )
  ON CONFLICT (tenant_id, email) DO UPDATE SET
    full_name = COALESCE(EXCLUDED.full_name, data.applicants.full_name),
    preferred_locale = COALESCE(EXCLUDED.preferred_locale, data.applicants.preferred_locale),
    updated_at = now()
  RETURNING id, email_verified_at, art14_notice_sent_at, art14_suppressed
  INTO v_applicant_id, v_verified, v_art14_sent, v_suppressed;

  SELECT id INTO v_existing
  FROM data.applications
  WHERE job_posting_id = v_posting.id AND applicant_id = v_applicant_id;

  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object(
      'application_id', v_existing,
      'applicant_id', v_applicant_id,
      'already_exists', true,
      'art14_queued', false
    );
  END IF;

  INSERT INTO data.applications (
    tenant_id, job_posting_id, applicant_id, stage_id,
    retention_preference, retention_months,
    source, import_source_label, cover_message, legal_notice_version,
    cv_storage_path, purge_at
  ) VALUES (
    p_tenant_id, v_posting.id, v_applicant_id, v_stage_id,
    v_retention_pref, v_retention_months,
    'email', NULLIF(btrim(COALESCE(p_data_source_label, '')), ''),
    p_cover, 'v1-email-inbound',
    p_cv_storage_path,
    data.compute_application_purge_at(
      p_tenant_id, now(), v_retention_pref, v_retention_months, NULL
    )
  )
  RETURNING id INTO v_application_id;

  INSERT INTO data.applicant_consent_events (
    tenant_id, applicant_id, application_id, event_type, legal_text_version, payload
  ) VALUES (
    p_tenant_id, v_applicant_id, v_application_id, 'import_consent', 'v1-email-inbound',
    jsonb_build_object(
      'legal_basis', v_basis,
      'legal_basis_note', v_settings.import_legal_basis_note,
      'source', 'email',
      'data_source', COALESCE(NULLIF(btrim(p_data_source_label), ''), 'email inbound'),
      'locale', v_locale
    )
  );

  IF v_verified IS NULL
     AND v_art14_sent IS NULL
     AND NOT COALESCE(v_suppressed, false)
  THEN
    BEGIN
      PERFORM api.enqueue_email(jsonb_build_object(
        'tenant_id', p_tenant_id,
        'idempotency_key', 'recruitment-art14-' || v_applicant_id::text,
        'to', jsonb_build_array(v_email),
        'event_type', 'recruitment.art14_notice',
        'locale', v_locale,
        'template_variables', jsonb_build_object(
          'applicant_name', v_name,
          'job_title', v_posting.title,
          'data_source', COALESCE(NULLIF(btrim(p_data_source_label), ''), 'email inbound'),
          'legal_basis_label', v_basis_label,
          'rights_url', v_rights_url
        )
      ));
      UPDATE data.applicants
      SET art14_notice_sent_at = now(), updated_at = now()
      WHERE id = v_applicant_id;
      v_art14 := true;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'create_application_from_inbound_email: art14 failed: %', SQLERRM;
    END;
  END IF;

  RETURN jsonb_build_object(
    'application_id', v_application_id,
    'applicant_id', v_applicant_id,
    'already_exists', false,
    'art14_queued', v_art14
  );
END;
$$;

REVOKE ALL ON FUNCTION data.create_application_from_inbound_email(uuid, uuid, text, text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.create_application_from_inbound_email(uuid, uuid, text, text, text, text, text, text)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 4. ingest (service_role / stub)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.ingest_recruitment_inbound_email(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_tenant uuid;
  v_from_email text;
  v_from_name text;
  v_subject text;
  v_body_text text;
  v_body_html text;
  v_received_at timestamptz;
  v_resend_id text;
  v_posting_id uuid;
  v_detected uuid;
  v_paths text[];
  v_dedupe text;
  v_inbox_id uuid;
  v_existing uuid;
  v_created jsonb;
  v_cv text;
  v_status text := 'unassigned';
  v_app_id uuid;
BEGIN
  IF coalesce(auth.role(), '') IS DISTINCT FROM 'service_role'
     AND current_user IS DISTINCT FROM 'postgres' THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501',
      HINT = 'ingest_recruitment_inbound_email requires service_role';
  END IF;

  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'invalid_payload';
  END IF;

  v_tenant := NULLIF(p_payload->>'tenant_id', '')::uuid;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_id_required'
      USING HINT = 'MVP stub: pass tenant_id. Mailbox→tenant map is post-MVP (see rec7-inbound-activation.md)';
  END IF;

  IF NOT data.is_feature_enabled(v_tenant, 'recruitment_enabled') THEN
    RAISE EXCEPTION 'module_not_enabled';
  END IF;

  v_from_email := lower(NULLIF(btrim(COALESCE(p_payload->>'from_email', '')), ''));
  v_from_name := NULLIF(btrim(COALESCE(p_payload->>'from_name', '')), '');
  v_subject := NULLIF(btrim(COALESCE(p_payload->>'subject', '')), '');
  v_body_text := p_payload->>'body_text';
  v_body_html := p_payload->>'body_html';
  v_received_at := COALESCE((p_payload->>'received_at')::timestamptz, now());
  v_resend_id := NULLIF(btrim(COALESCE(p_payload->>'resend_email_id', '')), '');
  v_posting_id := NULLIF(p_payload->>'posting_id', '')::uuid;
  v_cv := NULLIF(btrim(COALESCE(p_payload->>'cv_storage_path', '')), '');

  IF p_payload ? 'attachment_paths'
     AND jsonb_typeof(p_payload->'attachment_paths') = 'array' THEN
    SELECT coalesce(array_agg(x), '{}')
    INTO v_paths
    FROM jsonb_array_elements_text(p_payload->'attachment_paths') AS t(x);
  ELSE
    v_paths := '{}';
  END IF;

  IF v_cv IS NOT NULL AND NOT (v_cv = ANY (v_paths)) THEN
    v_paths := array_append(v_paths, v_cv);
  END IF;

  IF v_from_email IS NULL THEN
    RAISE EXCEPTION 'from_email_required';
  END IF;

  v_detected := COALESCE(v_posting_id, data.parse_posting_id_from_subject(v_subject));

  IF v_detected IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.job_postings
      WHERE id = v_detected AND tenant_id = v_tenant
    ) THEN
      v_detected := NULL;
    END IF;
  END IF;

  v_dedupe := COALESCE(
    v_resend_id,
    encode(
      extensions.digest(
        convert_to(
          v_tenant::text || '|' || v_from_email || '|' || coalesce(v_subject, '') || '|' || v_received_at::text,
          'UTF8'
        ),
        'sha256'
      ),
      'hex'
    )
  );

  SELECT id INTO v_existing
  FROM data.recruitment_email_inbox
  WHERE tenant_id = v_tenant
    AND (
      (v_resend_id IS NOT NULL AND resend_email_id = v_resend_id)
      OR dedupe_key = v_dedupe
    )
  LIMIT 1;

  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object(
      'inbox_id', v_existing,
      'duplicate', true,
      'status', (SELECT status FROM data.recruitment_email_inbox WHERE id = v_existing)
    );
  END IF;

  INSERT INTO data.recruitment_email_inbox (
    tenant_id, status, from_email, from_name, subject, body_text, body_html,
    received_at, resend_email_id, detected_posting_id,
    raw_payload, attachment_paths, dedupe_key
  ) VALUES (
    v_tenant, 'unassigned', v_from_email, v_from_name, v_subject, v_body_text, v_body_html,
    v_received_at, v_resend_id, v_detected,
    p_payload - 'cv_bytes_base64', v_paths, v_dedupe
  )
  RETURNING id INTO v_inbox_id;

  IF v_detected IS NOT NULL THEN
    v_created := data.create_application_from_inbound_email(
      v_tenant,
      v_detected,
      v_from_email,
      v_from_name,
      left(COALESCE(v_body_text, ''), 2000),
      p_payload->>'locale',
      COALESCE(v_cv, CASE WHEN cardinality(v_paths) > 0 THEN v_paths[1] ELSE NULL END),
      COALESCE(NULLIF(btrim(p_payload->>'data_source_label'), ''), 'email inbound')
    );
    v_app_id := (v_created->>'application_id')::uuid;
    UPDATE data.recruitment_email_inbox
    SET status = 'assigned',
        assigned_application_id = v_app_id,
        assigned_posting_id = v_detected,
        assigned_at = now(),
        updated_at = now()
    WHERE id = v_inbox_id;
    v_status := 'assigned';
  END IF;

  RETURN jsonb_build_object(
    'inbox_id', v_inbox_id,
    'duplicate', false,
    'status', v_status,
    'detected_posting_id', v_detected,
    'application', v_created
  );
END;
$$;

REVOKE ALL ON FUNCTION api.ingest_recruitment_inbound_email(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.ingest_recruitment_inbound_email(jsonb) TO service_role;

COMMENT ON FUNCTION api.ingest_recruitment_inbound_email(jsonb) IS
  'REC-7: ingest inbound email (service_role / stub). Auto-assigns when posting tag or posting_id present.';

-- ---------------------------------------------------------------------------
-- 5. assign / discard / list
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.assign_recruitment_inbox_item(
  p_id uuid,
  p_job_posting_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_row data.recruitment_email_inbox%ROWTYPE;
  v_posting data.job_postings%ROWTYPE;
  v_created jsonb;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT data.is_feature_enabled(v_tenant, 'recruitment_enabled') THEN
    RAISE EXCEPTION 'module_not_enabled';
  END IF;

  SELECT * INTO v_row
  FROM data.recruitment_email_inbox
  WHERE id = p_id AND tenant_id = v_tenant
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;

  IF v_row.status = 'discarded' THEN
    RAISE EXCEPTION 'already_discarded';
  END IF;

  IF v_row.status = 'assigned' AND v_row.assigned_application_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'inbox_id', v_row.id,
      'already_assigned', true,
      'application_id', v_row.assigned_application_id,
      'posting_id', v_row.assigned_posting_id
    );
  END IF;

  SELECT * INTO v_posting
  FROM data.job_postings
  WHERE id = p_job_posting_id AND tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'posting_not_found';
  END IF;

  IF NOT data.jwt_has_recruitment_permission(
    v_tenant, 'recruitment.manage', v_posting.site_id
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  v_created := data.create_application_from_inbound_email(
    v_tenant,
    p_job_posting_id,
    v_row.from_email,
    v_row.from_name,
    left(COALESCE(v_row.body_text, ''), 2000),
    NULL,
    CASE WHEN cardinality(v_row.attachment_paths) > 0 THEN v_row.attachment_paths[1] ELSE NULL END,
    'email inbound'
  );

  UPDATE data.recruitment_email_inbox
  SET status = 'assigned',
      assigned_application_id = (v_created->>'application_id')::uuid,
      assigned_posting_id = p_job_posting_id,
      assigned_at = now(),
      assigned_by = auth.uid(),
      detected_posting_id = COALESCE(detected_posting_id, p_job_posting_id),
      updated_at = now()
  WHERE id = p_id;

  PERFORM data.log_audit_event(
    v_tenant,
    auth.uid(),
    v_posting.site_id,
    'recruitment.inbound_assign',
    'recruitment_email_inbox',
    p_id,
    jsonb_build_object(
      'posting_id', p_job_posting_id,
      'application_id', v_created->>'application_id',
      'already_exists', v_created->>'already_exists'
    )
  );

  RETURN jsonb_build_object(
    'inbox_id', p_id,
    'already_assigned', false,
    'application', v_created,
    'posting_id', p_job_posting_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.discard_recruitment_inbox_item(
  p_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_row data.recruitment_email_inbox%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT data.is_feature_enabled(v_tenant, 'recruitment_enabled') THEN
    RAISE EXCEPTION 'module_not_enabled';
  END IF;

  IF NOT data.jwt_has_recruitment_permission(v_tenant, 'recruitment.manage') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row
  FROM data.recruitment_email_inbox
  WHERE id = p_id AND tenant_id = v_tenant
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;

  IF v_row.status = 'discarded' THEN
    RETURN jsonb_build_object('inbox_id', p_id, 'already_discarded', true);
  END IF;

  UPDATE data.recruitment_email_inbox
  SET status = 'discarded',
      discarded_at = now(),
      discarded_by = auth.uid(),
      discard_reason = NULLIF(btrim(COALESCE(p_reason, '')), ''),
      updated_at = now()
  WHERE id = p_id;

  PERFORM data.log_audit_event(
    v_tenant,
    auth.uid(),
    NULL,
    'recruitment.inbound_discard',
    'recruitment_email_inbox',
    p_id,
    jsonb_build_object('reason', p_reason)
  );

  RETURN jsonb_build_object('inbox_id', p_id, 'already_discarded', false);
END;
$$;

CREATE OR REPLACE FUNCTION api.list_recruitment_email_inbox(
  p_status text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_out jsonb;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT data.is_feature_enabled(v_tenant, 'recruitment_enabled') THEN
    RAISE EXCEPTION 'module_not_enabled';
  END IF;

  IF NOT data.jwt_has_recruitment_permission(v_tenant, 'recruitment.view') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_status IS NOT NULL
     AND p_status NOT IN ('unassigned', 'assigned', 'discarded') THEN
    RAISE EXCEPTION 'invalid_status';
  END IF;

  SELECT coalesce(jsonb_agg(row_to_json(x)::jsonb ORDER BY x.received_at DESC), '[]'::jsonb)
  INTO v_out
  FROM (
    SELECT
      i.id,
      i.status,
      i.from_email,
      i.from_name,
      i.subject,
      i.body_text,
      i.received_at,
      i.detected_posting_id,
      i.assigned_application_id,
      i.assigned_posting_id,
      i.assigned_at,
      i.discarded_at,
      i.discard_reason,
      i.attachment_paths,
      i.created_at
    FROM data.recruitment_email_inbox i
    WHERE i.tenant_id = v_tenant
      AND (p_status IS NULL OR i.status = p_status)
    ORDER BY i.received_at DESC
    LIMIT 200
  ) x;

  RETURN v_out;
END;
$$;

REVOKE ALL ON FUNCTION api.assign_recruitment_inbox_item(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.discard_recruitment_inbox_item(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.list_recruitment_email_inbox(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.assign_recruitment_inbox_item(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.discard_recruitment_inbox_item(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION api.list_recruitment_email_inbox(text) TO authenticated;

COMMENT ON FUNCTION api.assign_recruitment_inbox_item(uuid, uuid) IS
  'REC-7: assign unassigned inbound email to a job posting (source=email + Art.14).';
COMMENT ON FUNCTION api.discard_recruitment_inbox_item(uuid, text) IS
  'REC-7: discard inbound email from inbox.';
COMMENT ON FUNCTION api.list_recruitment_email_inbox(text) IS
  'REC-7: list inbound inbox items (optional status filter).';

NOTIFY pgrst, 'reload schema';
