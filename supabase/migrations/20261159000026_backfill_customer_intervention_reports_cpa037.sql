-- =============================================================================
-- CP-A0.3–7 — Backfill legacy client reports → customer_intervention_reports
--
-- 3. Inventari projectes publicats / DMS / payloads
-- 4. Backfill agregat + versió v1 (preserva published_at/by)
-- 5. legacy_unresolved quan falta payload o és ambigu
-- 6. Reforç bloqueig escriptura directa quan hi ha agregat
-- 7. Retirada definitiva de l'RPC legacy de publicació
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Decode DMS data-URI JSON
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.decode_dms_json_data_uri(p_url text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_prefix text := 'data:application/json;base64,';
  v_b64 text;
BEGIN
  IF p_url IS NULL OR btrim(p_url) = '' THEN
    RETURN NULL;
  END IF;
  IF left(p_url, length(v_prefix)) IS DISTINCT FROM v_prefix THEN
    RETURN NULL;
  END IF;
  v_b64 := substring(p_url FROM length(v_prefix) + 1);
  BEGIN
    RETURN convert_from(decode(v_b64, 'base64'), 'UTF8')::jsonb;
  EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
  END;
END;
$$;

COMMENT ON FUNCTION data.decode_dms_json_data_uri(text) IS
  'CP-A0.3–7: decodifica document_versions.file_path_or_url data:application/json;base64,…';

REVOKE ALL ON FUNCTION data.decode_dms_json_data_uri(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.decode_dms_json_data_uri(text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Resolve candidate legacy payloads for a project
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS data.resolve_legacy_client_report_payload(uuid);
CREATE OR REPLACE FUNCTION data.resolve_legacy_client_report_payload(p_project_id uuid)
RETURNS TABLE (
  resolved_payload jsonb,
  resolved_source text,
  resolved_document_id uuid,
  resolved_document_version_id uuid,
  is_ambiguous boolean,
  unresolved_reason text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_dms_count int;
  v_distinct int;
  v_payload jsonb;
  v_doc_id uuid;
  v_ver_id uuid;
  v_run_count int;
  v_run_distinct int;
BEGIN
  WITH latest_per_doc AS (
    SELECT DISTINCT ON (d.id)
      d.id AS doc_id,
      dv.id AS ver_id,
      data.decode_dms_json_data_uri(dv.file_path_or_url) AS doc_payload
    FROM data.documents d
    JOIN data.document_versions dv ON dv.document_id = d.id
    WHERE d.entity_type = 'project'
      AND d.entity_id = p_project_id
      AND d.category = 'field_service_intervention_report'
    ORDER BY d.id, dv.version_number DESC, dv.created_at DESC
  ),
  usable AS (
    SELECT * FROM latest_per_doc WHERE doc_payload IS NOT NULL
  )
  SELECT
    COUNT(*),
    COUNT(DISTINCT doc_payload)
  INTO v_dms_count, v_distinct
  FROM usable;

  IF v_dms_count = 1 OR (v_dms_count > 1 AND v_distinct = 1) THEN
    SELECT u.doc_payload, u.doc_id, u.ver_id
      INTO v_payload, v_doc_id, v_ver_id
    FROM (
      SELECT DISTINCT ON (d.id)
        d.id AS doc_id,
        dv.id AS ver_id,
        data.decode_dms_json_data_uri(dv.file_path_or_url) AS doc_payload,
        dv.version_number,
        dv.created_at
      FROM data.documents d
      JOIN data.document_versions dv ON dv.document_id = d.id
      WHERE d.entity_type = 'project'
        AND d.entity_id = p_project_id
        AND d.category = 'field_service_intervention_report'
      ORDER BY d.id, dv.version_number DESC, dv.created_at DESC
    ) u
    WHERE u.doc_payload IS NOT NULL
    ORDER BY u.created_at DESC, u.version_number DESC
    LIMIT 1;

    resolved_payload := v_payload;
    resolved_source := 'dms';
    resolved_document_id := v_doc_id;
    resolved_document_version_id := v_ver_id;
    is_ambiguous := false;
    unresolved_reason := NULL;
    RETURN NEXT;
    RETURN;
  END IF;

  IF v_dms_count > 1 AND v_distinct > 1 THEN
    resolved_payload := NULL;
    resolved_source := 'dms';
    resolved_document_id := NULL;
    resolved_document_version_id := NULL;
    is_ambiguous := true;
    unresolved_reason := 'ambiguous_dms_payloads';
    RETURN NEXT;
    RETURN;
  END IF;

  SELECT
    COUNT(*) FILTER (WHERE cr.public_report_payload IS NOT NULL),
    COUNT(DISTINCT cr.public_report_payload) FILTER (WHERE cr.public_report_payload IS NOT NULL)
  INTO v_run_count, v_run_distinct
  FROM data.checklist_runs cr
  WHERE cr.project_id = p_project_id;

  IF v_run_count = 1 OR (v_run_count > 1 AND v_run_distinct = 1) THEN
    SELECT cr.public_report_payload
      INTO v_payload
    FROM data.checklist_runs cr
    WHERE cr.project_id = p_project_id
      AND cr.public_report_payload IS NOT NULL
    ORDER BY cr.updated_at DESC NULLS LAST, cr.created_at DESC
    LIMIT 1;

    resolved_payload := v_payload;
    resolved_source := 'checklist_run';
    resolved_document_id := NULL;
    resolved_document_version_id := NULL;
    is_ambiguous := false;
    unresolved_reason := NULL;
    RETURN NEXT;
    RETURN;
  END IF;

  IF v_run_count > 1 AND v_run_distinct > 1 THEN
    resolved_payload := NULL;
    resolved_source := 'checklist_run';
    resolved_document_id := NULL;
    resolved_document_version_id := NULL;
    is_ambiguous := true;
    unresolved_reason := 'ambiguous_run_payloads';
    RETURN NEXT;
    RETURN;
  END IF;

  resolved_payload := NULL;
  resolved_source := NULL;
  resolved_document_id := NULL;
  resolved_document_version_id := NULL;
  is_ambiguous := false;
  unresolved_reason := 'missing_payload';
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION data.resolve_legacy_client_report_payload(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.resolve_legacy_client_report_payload(uuid)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Upsert CIR from a known legacy payload (backfill + dual-write)
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

  -- Already has an authoritative published version → leave as-is
  IF v_report.current_published_version_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'status', 'skipped_has_version',
      'report_id', v_report.id,
      'version_id', v_report.current_published_version_id
    );
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

  -- Map legacy checklist payload into safe projection shape
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

REVOKE ALL ON FUNCTION data.upsert_customer_intervention_report_from_legacy(
  uuid, jsonb, text, uuid, uuid, timestamptz, uuid, boolean, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.upsert_customer_intervention_report_from_legacy(
  uuid, jsonb, text, uuid, uuid, timestamptz, uuid, boolean, text
) TO service_role;
REVOKE ALL ON FUNCTION data.upsert_customer_intervention_report_from_legacy(
  uuid, jsonb, text, uuid, uuid, timestamptz, uuid, boolean, text
) FROM authenticated, anon;

-- ---------------------------------------------------------------------------
-- 4. Backfill one project (resolve + upsert)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.backfill_customer_intervention_report_for_project(
  p_project_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_project data.projects%ROWTYPE;
  v_resolved record;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' AND session_user <> 'postgres' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_project FROM data.projects WHERE id = p_project_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'project_not_found');
  END IF;

  IF auth.uid() IS NOT NULL AND NOT data.can_access_project(p_project_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_project.client_report_published_at IS NULL THEN
    RETURN jsonb_build_object('status', 'not_published');
  END IF;

  -- Skip if already has published CIR version
  IF EXISTS (
    SELECT 1
    FROM data.customer_intervention_reports r
    WHERE r.project_id = p_project_id
      AND r.current_published_version_id IS NOT NULL
  ) THEN
    RETURN jsonb_build_object('status', 'skipped_has_version', 'project_id', p_project_id);
  END IF;

  -- Skip if already marked unresolved (idempotent)
  IF EXISTS (
    SELECT 1
    FROM data.customer_intervention_reports r
    WHERE r.project_id = p_project_id
      AND r.legacy_unresolved
      AND r.current_published_version_id IS NULL
  ) THEN
    RETURN jsonb_build_object('status', 'skipped_unresolved', 'project_id', p_project_id);
  END IF;

  SELECT * INTO v_resolved
  FROM data.resolve_legacy_client_report_payload(p_project_id);

  IF v_resolved.is_ambiguous OR v_resolved.resolved_payload IS NULL THEN
    RETURN data.upsert_customer_intervention_report_from_legacy(
      p_project_id,
      NULL,
      v_resolved.resolved_source,
      v_resolved.resolved_document_id,
      v_resolved.resolved_document_version_id,
      v_project.client_report_published_at,
      v_project.client_report_published_by,
      true,
      COALESCE(v_resolved.unresolved_reason, 'missing_payload')
    );
  END IF;

  RETURN data.upsert_customer_intervention_report_from_legacy(
    p_project_id,
    v_resolved.resolved_payload,
    v_resolved.resolved_source,
    v_resolved.resolved_document_id,
    v_resolved.resolved_document_version_id,
    v_project.client_report_published_at,
    v_project.client_report_published_by,
    false,
    NULL
  );
END;
$$;

REVOKE ALL ON FUNCTION data.backfill_customer_intervention_report_for_project(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.backfill_customer_intervention_report_for_project(uuid)
  TO service_role;
REVOKE ALL ON FUNCTION data.backfill_customer_intervention_report_for_project(uuid)
  FROM authenticated, anon;

-- ---------------------------------------------------------------------------
-- 5. Batch backfill all published projects
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.backfill_all_customer_intervention_reports()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  r record;
  v_result jsonb;
  v_ok int := 0;
  v_unresolved int := 0;
  v_skipped int := 0;
  v_other int := 0;
  v_details jsonb := '[]'::jsonb;
BEGIN
  FOR r IN
    SELECT id
    FROM data.projects
    WHERE client_report_published_at IS NOT NULL
    ORDER BY client_report_published_at, id
  LOOP
    v_result := data.backfill_customer_intervention_report_for_project(r.id);
    v_details := v_details || jsonb_build_array(
      jsonb_build_object('project_id', r.id) || v_result
    );
    CASE v_result->>'status'
      WHEN 'backfilled' THEN v_ok := v_ok + 1;
      WHEN 'legacy_unresolved' THEN v_unresolved := v_unresolved + 1;
      WHEN 'skipped_has_version' THEN v_skipped := v_skipped + 1;
      WHEN 'skipped_unresolved' THEN v_skipped := v_skipped + 1;
      ELSE v_other := v_other + 1;
    END CASE;
  END LOOP;

  RETURN jsonb_build_object(
    'backfilled', v_ok,
    'legacy_unresolved', v_unresolved,
    'skipped', v_skipped,
    'other', v_other,
    'details', v_details
  );
END;
$$;

REVOKE ALL ON FUNCTION data.backfill_all_customer_intervention_reports() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.backfill_all_customer_intervention_reports()
  TO service_role;

-- ---------------------------------------------------------------------------
-- 6. Inventory view (ops / reconciliació)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.legacy_client_report_inventory
WITH (security_invoker = true) AS
SELECT
  p.tenant_id,
  p.id AS project_id,
  p.name AS project_name,
  p.status AS project_status,
  p.client_report_published_at,
  p.client_report_published_by,
  (
    SELECT COUNT(*)
    FROM data.documents d
    WHERE d.entity_type = 'project'
      AND d.entity_id = p.id
      AND d.category = 'field_service_intervention_report'
  ) AS dms_document_count,
  (
    SELECT COUNT(*)
    FROM data.checklist_runs cr
    WHERE cr.project_id = p.id
      AND cr.public_report_payload IS NOT NULL
  ) AS run_payload_count,
  r.id AS report_id,
  r.legacy_unresolved,
  r.current_published_version_id,
  v.version_number AS current_version_number,
  v.published_at AS version_published_at,
  v.snapshots->>'legacy_source' AS legacy_source,
  CASE
    WHEN p.client_report_published_at IS NULL THEN 'not_published'
    WHEN r.id IS NULL THEN 'needs_backfill'
    WHEN r.legacy_unresolved THEN 'legacy_unresolved'
    WHEN r.current_published_version_id IS NOT NULL THEN 'ok'
    ELSE 'incomplete'
  END AS reconciliation_status
FROM data.projects p
LEFT JOIN data.customer_intervention_reports r
  ON r.project_id = p.id AND r.report_type = 'intervention'
LEFT JOIN data.customer_intervention_report_versions v
  ON v.id = r.current_published_version_id
WHERE p.client_report_published_at IS NOT NULL
   OR r.id IS NOT NULL;

GRANT SELECT ON api.legacy_client_report_inventory TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.inventory_legacy_client_reports()
RETURNS SETOF api.legacy_client_report_inventory
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = data, public, api
AS $$
  SELECT * FROM api.legacy_client_report_inventory
  ORDER BY client_report_published_at NULLS LAST, project_id;
$$;

REVOKE ALL ON FUNCTION api.inventory_legacy_client_reports() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.inventory_legacy_client_reports()
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. Strengthen block: no direct writes when aggregate exists (except projection GUC /
--    matching current version timestamp). Remove "no aggregate yet" escape for
--    published columns once dual-write is active — dual-write creates CIR first.
-- ---------------------------------------------------------------------------
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
    -- Allow only when NEW matches the aggregate's current published version
    IF EXISTS (
      SELECT 1
      FROM data.customer_intervention_reports r
      JOIN data.customer_intervention_report_versions v
        ON v.id = r.current_published_version_id
      WHERE r.project_id = NEW.id
        AND v.published_at IS NOT DISTINCT FROM NEW.client_report_published_at
        AND v.published_by IS NOT DISTINCT FROM NEW.client_report_published_by
    ) THEN
      RETURN NEW;
    END IF;

    RAISE EXCEPTION 'client_report_published_projection_only'
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 8. CIR is the only publication authority. The legacy RPC existed in the
-- previous source migration only to support pre-CIR deployments and must not
-- remain callable after this migration.
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION api.publish_project_client_report(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.publish_project_client_report(uuid, text, text)
  FROM authenticated, anon, service_role;
DROP FUNCTION IF EXISTS api.publish_project_client_report(uuid, text, text);

-- ---------------------------------------------------------------------------
-- 9. Run backfill now (idempotent)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_summary jsonb;
BEGIN
  v_summary := data.backfill_all_customer_intervention_reports();
  RAISE NOTICE 'CP-A0.3–7 backfill summary: %', v_summary;
END $$;

-- CP-C: repair any versions missing account id (portal catalog joins on this)
UPDATE data.customer_intervention_report_versions v
SET customer_account_contact_id = p.client_id
FROM data.projects p
WHERE v.project_id = p.id
  AND v.customer_account_contact_id IS NULL
  AND p.client_id IS NOT NULL;

UPDATE data.customer_intervention_report_drafts d
SET customer_account_contact_id = p.client_id
FROM data.projects p
WHERE d.project_id = p.id
  AND d.customer_account_contact_id IS NULL
  AND p.client_id IS NOT NULL;
