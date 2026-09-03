-- =============================================================================
-- Customer Portal P1: authz hardening
-- - contacts.portal.manage on verify / mark_verified / delivery rules
-- - REVOKE direct writes on delivery channels/rules (DEFINER RPCs only)
-- - CIR drafts/versions/events SELECT-only for authenticated (no forge)
-- - upsert allows preparing_media retry; Edge can mark prepare failed
-- - legacy upsert rejects missing customer account; cleanup NULL ghosts
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Delivery channels/rules: revoke client writes + defense triggers
-- ---------------------------------------------------------------------------
REVOKE INSERT, UPDATE, DELETE ON data.contact_delivery_channels FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON data.contact_delivery_rules FROM authenticated;
GRANT SELECT ON data.contact_delivery_channels TO authenticated;
GRANT SELECT ON data.contact_delivery_rules TO authenticated;

DROP POLICY IF EXISTS "contact_delivery_channels: insert" ON data.contact_delivery_channels;
DROP POLICY IF EXISTS "contact_delivery_channels: update" ON data.contact_delivery_channels;
DROP POLICY IF EXISTS "contact_delivery_rules: insert" ON data.contact_delivery_rules;
DROP POLICY IF EXISTS "contact_delivery_rules: update" ON data.contact_delivery_rules;

CREATE OR REPLACE FUNCTION data.enforce_contact_delivery_channel_verify_authz()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  -- Seed / service paths without a user JWT skip the portal.manage gate.
  IF auth.uid() IS NULL OR COALESCE(auth.role(), '') = 'service_role' THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' AND NEW.verified_at IS NOT NULL THEN
    PERFORM data.require_fresh_tenant_permission(
      NEW.tenant_id, 'contacts.portal.manage', NULL
    );
  ELSIF TG_OP = 'UPDATE'
        AND OLD.verified_at IS NULL
        AND NEW.verified_at IS NOT NULL THEN
    PERFORM data.require_fresh_tenant_permission(
      NEW.tenant_id, 'contacts.portal.manage', NULL
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cdc_verify_authz ON data.contact_delivery_channels;
CREATE TRIGGER trg_cdc_verify_authz
  BEFORE INSERT OR UPDATE ON data.contact_delivery_channels
  FOR EACH ROW
  EXECUTE FUNCTION data.enforce_contact_delivery_channel_verify_authz();

CREATE OR REPLACE FUNCTION data.enforce_contact_delivery_rule_on_publish_authz()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF auth.uid() IS NULL OR COALESCE(auth.role(), '') = 'service_role' THEN
    RETURN NEW;
  END IF;

  IF NEW.policy = 'on_publish' THEN
    PERFORM data.require_fresh_tenant_permission(
      NEW.tenant_id, 'contacts.portal.manage', NULL
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cdr_on_publish_authz ON data.contact_delivery_rules;
CREATE TRIGGER trg_cdr_on_publish_authz
  BEFORE INSERT OR UPDATE ON data.contact_delivery_rules
  FOR EACH ROW
  EXECUTE FUNCTION data.enforce_contact_delivery_rule_on_publish_authz();

-- ---------------------------------------------------------------------------
-- 2. Delivery RPCs → SECURITY DEFINER + portal.manage where required
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.create_contact_delivery_channel(
  p_contact_id uuid,
  p_channel_type text,
  p_value text,
  p_mark_verified boolean DEFAULT false,
  p_verification_method text DEFAULT 'staff_confirmed'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_id uuid;
  v_tenant uuid := data.active_tenant_id();
BEGIN
  IF v_tenant IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.tenant_members tm
    WHERE tm.tenant_id = v_tenant AND tm.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'not_tenant_member' USING ERRCODE = 'P0001';
  END IF;

  IF p_mark_verified THEN
    PERFORM data.require_fresh_tenant_permission(
      v_tenant, 'contacts.portal.manage', NULL
    );
  END IF;

  IF p_channel_type NOT IN ('email', 'phone') THEN
    RAISE EXCEPTION 'invalid_channel_type' USING ERRCODE = 'P0001';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.contacts c
    WHERE c.id = p_contact_id AND c.tenant_id = v_tenant
  ) THEN
    RAISE EXCEPTION 'contact_not_found' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO data.contact_delivery_channels (
    tenant_id,
    contact_id,
    channel_type,
    value_raw,
    value_normalized,
    verified_at,
    verification_method,
    created_by
  ) VALUES (
    v_tenant,
    p_contact_id,
    p_channel_type,
    p_value,
    p_value,
    CASE WHEN p_mark_verified THEN now() ELSE NULL END,
    CASE WHEN p_mark_verified THEN COALESCE(NULLIF(p_verification_method, ''), 'staff_confirmed') ELSE NULL END,
    auth.uid()
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.verify_contact_delivery_channel(
  p_channel_id uuid,
  p_verification_method text DEFAULT 'staff_confirmed'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
BEGIN
  IF v_tenant IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;

  PERFORM data.require_fresh_tenant_permission(
    v_tenant, 'contacts.portal.manage', NULL
  );

  UPDATE data.contact_delivery_channels
  SET
    verified_at = now(),
    verification_method = COALESCE(NULLIF(p_verification_method, ''), 'staff_confirmed'),
    updated_at = now()
  WHERE id = p_channel_id
    AND tenant_id = v_tenant
    AND disabled_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'contact_delivery_channel_not_found'
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION api.disable_contact_delivery_channel(
  p_channel_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
BEGIN
  IF v_tenant IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.tenant_members tm
    WHERE tm.tenant_id = v_tenant AND tm.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'not_tenant_member' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.contact_delivery_channels
  SET
    disabled_at = now(),
    disabled_by = auth.uid(),
    disable_reason = p_reason,
    updated_at = now()
  WHERE id = p_channel_id
    AND tenant_id = v_tenant
    AND disabled_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'contact_delivery_channel_not_found_or_disabled'
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION api.create_contact_delivery_rule(
  p_client_account_contact_id uuid,
  p_contact_point_id uuid,
  p_purpose text,
  p_policy text DEFAULT 'manual'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_id uuid;
  v_tenant uuid := data.active_tenant_id();
BEGIN
  IF v_tenant IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;

  PERFORM data.require_fresh_tenant_permission(
    v_tenant, 'contacts.portal.manage', NULL
  );

  IF p_purpose NOT IN ('bulletin', 'invoice') THEN
    RAISE EXCEPTION 'invalid_delivery_purpose' USING ERRCODE = 'P0001';
  END IF;

  IF COALESCE(p_policy, 'manual') NOT IN ('manual', 'on_publish') THEN
    RAISE EXCEPTION 'invalid_delivery_policy' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO data.contact_delivery_rules (
    tenant_id,
    client_account_contact_id,
    contact_point_id,
    purpose,
    policy,
    created_by
  ) VALUES (
    v_tenant,
    p_client_account_contact_id,
    p_contact_point_id,
    p_purpose,
    COALESCE(NULLIF(p_policy, ''), 'manual'),
    auth.uid()
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.disable_contact_delivery_rule(
  p_rule_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
BEGIN
  IF v_tenant IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;

  PERFORM data.require_fresh_tenant_permission(
    v_tenant, 'contacts.portal.manage', NULL
  );

  UPDATE data.contact_delivery_rules
  SET
    disabled_at = now(),
    disabled_by = auth.uid(),
    disable_reason = p_reason,
    updated_at = now()
  WHERE id = p_rule_id
    AND tenant_id = v_tenant
    AND disabled_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'contact_delivery_rule_not_found_or_disabled'
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION api.create_contact_delivery_channel(uuid, text, text, boolean, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.verify_contact_delivery_channel(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.disable_contact_delivery_channel(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.create_contact_delivery_rule(uuid, uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.disable_contact_delivery_rule(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.create_contact_delivery_channel(uuid, text, text, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION api.verify_contact_delivery_channel(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION api.disable_contact_delivery_channel(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION api.create_contact_delivery_rule(uuid, uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION api.disable_contact_delivery_rule(uuid, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. CIR: SELECT-only for authenticated; mutate via DEFINER RPCs
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS cird_write ON data.customer_intervention_report_drafts;
DROP POLICY IF EXISTS cirv_insert ON data.customer_intervention_report_versions;
DROP POLICY IF EXISTS cire_insert ON data.customer_intervention_report_events;
DROP POLICY IF EXISTS cir_insert ON data.customer_intervention_reports;
DROP POLICY IF EXISTS cir_update ON data.customer_intervention_reports;

REVOKE INSERT, UPDATE, DELETE ON data.customer_intervention_reports FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON data.customer_intervention_report_drafts FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON data.customer_intervention_report_versions FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON data.customer_intervention_report_events FROM authenticated;

GRANT SELECT ON data.customer_intervention_reports TO authenticated;
GRANT SELECT ON data.customer_intervention_report_drafts TO authenticated;
GRANT SELECT ON data.customer_intervention_report_versions TO authenticated;
GRANT SELECT ON data.customer_intervention_report_events TO authenticated;

ALTER FUNCTION api.ensure_customer_intervention_report(uuid) SECURITY DEFINER;
ALTER FUNCTION api.upsert_customer_intervention_report_draft(uuid, text, text, jsonb, jsonb, uuid) SECURITY DEFINER;
ALTER FUNCTION api.publish_customer_intervention_report(uuid) SECURITY DEFINER;
ALTER FUNCTION api.create_corrected_customer_intervention_report_draft(uuid) SECURITY DEFINER;
ALTER FUNCTION api.preview_customer_intervention_report_draft(uuid) SECURITY DEFINER;
ALTER FUNCTION api.authorize_customer_intervention_report_media_copy(uuid) SECURITY DEFINER;
ALTER FUNCTION api.prepare_customer_intervention_report_media(uuid) SECURITY DEFINER;

-- ---------------------------------------------------------------------------
-- 4. P1.9 — upsert may edit / supersede preparing_media drafts
-- ---------------------------------------------------------------------------
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
SECURITY DEFINER
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

  IF NOT (
    data.member_has_live_permission(v_tenant, auth.uid(), 'field_service.reports.regenerate', v_site)
    OR data.member_has_live_permission(v_tenant, auth.uid(), 'field_service.reports.publish', v_site)
  ) THEN
    RAISE EXCEPTION 'permission_denied:field_service.reports.regenerate|publish' USING ERRCODE = 'P0001';
  END IF;

  -- JWT freshness for whichever permission the member holds
  IF data.member_has_live_permission(v_tenant, auth.uid(), 'field_service.reports.regenerate', v_site) THEN
    PERFORM data.require_fresh_tenant_permission(
      v_tenant, 'field_service.reports.regenerate', v_site
    );
  ELSE
    PERFORM data.require_fresh_tenant_permission(
      v_tenant, 'field_service.reports.publish', v_site
    );
  END IF;

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
      AND status IN ('draft', 'ready', 'failed', 'preparing_media')
    RETURNING id INTO v_draft;

    IF v_draft IS NULL THEN
      RAISE EXCEPTION 'draft_not_found_or_locked' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_draft;
  END IF;

  UPDATE data.customer_intervention_report_drafts
  SET status = 'superseded', updated_at = now()
  WHERE report_id = v_report
    AND status IN ('draft', 'ready', 'failed', 'preparing_media');

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

-- Edge abort / claim failure → leave draft recoverable
CREATE OR REPLACE FUNCTION api.fail_customer_intervention_report_media_prepare(
  p_draft_id uuid,
  p_failure_reason text DEFAULT 'media_prepare_failed'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  UPDATE data.customer_intervention_report_drafts
  SET
    status = 'failed',
    failure_reason = left(COALESCE(NULLIF(p_failure_reason, ''), 'media_prepare_failed'), 500),
    updated_at = now()
  WHERE id = p_draft_id
    AND status = 'preparing_media';

  UPDATE data.customer_intervention_report_media_copy_jobs
  SET
    status = 'failed',
    failure_reason = left(COALESCE(NULLIF(p_failure_reason, ''), 'media_prepare_failed'), 500),
    completed_at = COALESCE(completed_at, now()),
    updated_at = now()
  WHERE draft_id = p_draft_id
    AND status IN ('pending', 'processing');
END;
$$;

REVOKE ALL ON FUNCTION api.fail_customer_intervention_report_media_prepare(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.fail_customer_intervention_report_media_prepare(uuid, text)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 5. P1.10 — legacy upsert: no publishable version without customer account
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.upsert_customer_intervention_report_from_legacy(
  p_project_id uuid,
  p_payload jsonb,
  p_source text,
  p_document_id uuid DEFAULT NULL,
  p_document_version_id uuid DEFAULT NULL,
  p_published_at timestamptz DEFAULT NULL,
  p_published_by uuid DEFAULT NULL,
  p_mark_unresolved boolean DEFAULT false,
  p_unresolved_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public, extensions
AS $$
DECLARE
  v_project data.projects%ROWTYPE;
  v_report data.customer_intervention_reports%ROWTYPE;
  v_safe jsonb;
  v_digest text;
  v_version_id uuid;
  v_locale text;
  v_pub_at timestamptz;
  v_pub_by uuid;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' AND session_user <> 'postgres' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_project FROM data.projects WHERE id = p_project_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'project_not_found' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO data.customer_intervention_reports (
    tenant_id, project_id, created_by, legacy_unresolved
  ) VALUES (
    v_project.tenant_id,
    p_project_id,
    COALESCE(p_published_by, v_project.client_report_published_by),
    COALESCE(p_mark_unresolved, false)
  )
  ON CONFLICT (tenant_id, project_id, report_type) DO UPDATE
    SET
      legacy_unresolved = CASE
        WHEN data.customer_intervention_reports.current_published_version_id IS NOT NULL
          THEN data.customer_intervention_reports.legacy_unresolved
        ELSE EXCLUDED.legacy_unresolved
      END,
      updated_at = now()
  RETURNING * INTO v_report;

  IF v_report.current_published_version_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'status', 'skipped_has_version',
      'report_id', v_report.id,
      'version_id', v_report.current_published_version_id
    );
  END IF;

  -- Missing customer account → unresolved, never orphan published version
  IF v_project.client_id IS NULL THEN
    p_mark_unresolved := true;
    p_unresolved_reason := COALESCE(p_unresolved_reason, 'missing_customer_account');
  END IF;

  IF p_mark_unresolved OR p_payload IS NULL THEN
    UPDATE data.customer_intervention_reports
    SET
      legacy_unresolved = true,
      updated_at = now()
    WHERE id = v_report.id;

    INSERT INTO data.customer_intervention_report_events (
      tenant_id, report_id, project_id, event_type, actor_id, payload
    ) VALUES (
      v_project.tenant_id, v_report.id, p_project_id,
      'LEGACY_UNRESOLVED',
      COALESCE(p_published_by, v_project.client_report_published_by),
      jsonb_build_object(
        'reason', COALESCE(p_unresolved_reason, 'missing_payload'),
        'source', p_source,
        'document_id', p_document_id,
        'document_version_id', p_document_version_id
      )
    );

    RETURN jsonb_build_object(
      'status', 'legacy_unresolved',
      'report_id', v_report.id,
      'reason', COALESCE(p_unresolved_reason, 'missing_payload')
    );
  END IF;

  v_locale := COALESCE(NULLIF(btrim(p_payload->>'locale'), ''), 'ca');
  IF v_locale NOT IN ('ca', 'es', 'en') THEN
    v_locale := 'ca';
  END IF;

  v_safe := data.build_customer_report_safe_projection(
    jsonb_strip_nulls(jsonb_build_object(
      'schema_version', COALESCE(p_payload->>'schema_version', '1.0'),
      'tenant', p_payload->'tenant',
      'customer_account', p_payload->'customer_account',
      'site', p_payload->'site',
      'intervention', COALESCE(
        p_payload->'intervention',
        jsonb_build_object(
          'project_id', p_project_id,
          'generated_at', p_payload->'generated_at'
        )
      ),
      'checklist_items', COALESCE(
        p_payload->'checklist_items',
        p_payload->'items',
        '[]'::jsonb
      ),
      'support_contact', p_payload->'support_contact',
      'legacy', jsonb_build_object(
        'source', p_source,
        'document_id', p_document_id,
        'document_version_id', p_document_version_id,
        'schema_version', p_payload->>'schema_version'
      )
    )),
    NULL,
    jsonb_build_object(
      'legacy_source', p_source,
      'document_id', p_document_id,
      'document_version_id', p_document_version_id
    )
  );

  v_digest := encode(extensions.digest(v_safe::text, 'sha256'), 'hex');
  v_pub_at := COALESCE(p_published_at, v_project.client_report_published_at, now());
  v_pub_by := COALESCE(p_published_by, v_project.client_report_published_by);

  INSERT INTO data.customer_intervention_report_versions (
    tenant_id, report_id, project_id, version_number,
    locale, schema_version, template_version, content_digest,
    projection, media_manifest, snapshots,
    customer_account_contact_id, contact_site_id,
    published_at, published_by
  ) VALUES (
    v_project.tenant_id, v_report.id, p_project_id, 1,
    v_locale,
    COALESCE(v_safe->>'schema_version', '1.0'),
    'legacy-1.0',
    v_digest,
    v_safe,
    '[]'::jsonb,
    jsonb_build_object(
      'legacy_source', p_source,
      'document_id', p_document_id,
      'document_version_id', p_document_version_id
    ),
    v_project.client_id,
    v_project.contact_site_id,
    v_pub_at,
    v_pub_by
  )
  RETURNING id INTO v_version_id;

  UPDATE data.customer_intervention_reports
  SET
    current_published_version_id = v_version_id,
    legacy_unresolved = false,
    updated_at = now()
  WHERE id = v_report.id;

  INSERT INTO data.customer_intervention_report_events (
    tenant_id, report_id, project_id, event_type, version_id, actor_id, payload
  ) VALUES (
    v_project.tenant_id, v_report.id, p_project_id,
    'CLIENT_REPORT_PUBLISHED',
    v_version_id,
    v_pub_by,
    jsonb_build_object(
      'version_number', 1,
      'content_digest', v_digest,
      'legacy_source', p_source,
      'backfill', true
    )
  );

  RETURN jsonb_build_object(
    'status', 'backfilled',
    'report_id', v_report.id,
    'version_id', v_version_id,
    'source', p_source,
    'content_digest', v_digest
  );
END;
$$;

-- Cleanup residual current versions with NULL account (invisible ghosts)
DO $$
BEGIN
  UPDATE data.customer_intervention_reports r
  SET
    current_published_version_id = NULL,
    legacy_unresolved = true,
    updated_at = now()
  FROM data.customer_intervention_report_versions v
  WHERE r.current_published_version_id = v.id
    AND v.customer_account_contact_id IS NULL;

  INSERT INTO data.customer_intervention_report_events (
    tenant_id, report_id, project_id, event_type, version_id, payload
  )
  SELECT
    r.tenant_id,
    r.id,
    r.project_id,
    'LEGACY_UNRESOLVED',
    v.id,
    jsonb_build_object('reason', 'missing_customer_account', 'cleanup', 'p1_null_account')
  FROM data.customer_intervention_reports r
  JOIN data.customer_intervention_report_versions v ON v.report_id = r.id
  WHERE v.customer_account_contact_id IS NULL
    AND r.legacy_unresolved = true
    AND NOT EXISTS (
      SELECT 1 FROM data.customer_intervention_report_events e
      WHERE e.report_id = r.id
        AND e.event_type = 'LEGACY_UNRESOLVED'
        AND e.payload->>'cleanup' = 'p1_null_account'
    );
END $$;
