-- =============================================================================
-- REC-4 — Pipeline Kanban + export CSV (TTL / advertència / audit)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. move_application_stage
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.move_application_stage(
  p_application_id uuid,
  p_stage_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_app data.applications%ROWTYPE;
  v_stage data.pipeline_stages%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT data.jwt_has_recruitment_permission(v_tenant, 'recruitment.manage') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501',
      HINT = 'Cal recruitment.manage';
  END IF;

  SELECT * INTO v_app
  FROM data.applications
  WHERE id = p_application_id AND tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found' USING HINT = 'Candidatura no trobada';
  END IF;

  SELECT * INTO v_stage
  FROM data.pipeline_stages
  WHERE id = p_stage_id AND tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid_stage' USING HINT = 'Etapa no vàlida';
  END IF;

  -- Stage must be tenant template OR override for this posting
  IF v_stage.job_posting_id IS NOT NULL AND v_stage.job_posting_id <> v_app.job_posting_id THEN
    RAISE EXCEPTION 'invalid_stage' USING HINT = 'Etapa no pertany a aquesta oferta';
  END IF;

  UPDATE data.applications SET
    stage_id = p_stage_id,
    updated_at = now()
  WHERE id = v_app.id;

  RETURN jsonb_build_object(
    'application_id', v_app.id,
    'stage_id', p_stage_id,
    'candidate_visible_status', (
      SELECT candidate_visible_status FROM data.applications WHERE id = v_app.id
    ),
    'outcome_communicated_at', (
      SELECT outcome_communicated_at FROM data.applications WHERE id = v_app.id
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.move_application_stage(uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. export CSV (ack required) — returns csv_text + storage_path; client uploads
--    then createSignedUrl(900). Audit always written when ack=true.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.export_job_posting_applications_csv(
  p_job_posting_id uuid,
  p_ack_warning boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_posting data.job_postings%ROWTYPE;
  v_csv text;
  v_count int := 0;
  v_path text;
  v_filename text;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT data.jwt_has_recruitment_permission(v_tenant, 'recruitment.manage') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501',
      HINT = 'Cal recruitment.manage';
  END IF;

  IF NOT COALESCE(p_ack_warning, false) THEN
    RAISE EXCEPTION 'ack_required'
      USING HINT = 'Cal acceptar l''advertència d''exportació RGPD';
  END IF;

  SELECT * INTO v_posting
  FROM data.job_postings
  WHERE id = p_job_posting_id AND tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found' USING HINT = 'Oferta no trobada';
  END IF;

  SELECT
    E'full_name,email,phone,source,stage,candidate_visible_status,purge_at,retention_preference,retention_months,created_at\n'
    || COALESCE(string_agg(line, E'\n' ORDER BY ord), '')
  INTO v_csv
  FROM (
    SELECT
      a.created_at AS ord,
      concat_ws(',',
        '"' || replace(COALESCE(ap.full_name, ''), '"', '""') || '"',
        '"' || replace(COALESCE(ap.email, ''), '"', '""') || '"',
        '"' || replace(COALESCE(ap.phone, ''), '"', '""') || '"',
        '"' || replace(COALESCE(a.source, ''), '"', '""') || '"',
        '"' || replace(COALESCE(ps.name, ''), '"', '""') || '"',
        '"' || replace(COALESCE(a.candidate_visible_status, ''), '"', '""') || '"',
        '"' || COALESCE(to_char(a.purge_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), '') || '"',
        '"' || replace(COALESCE(a.retention_preference, ''), '"', '""') || '"',
        COALESCE(a.retention_months::text, ''),
        '"' || COALESCE(to_char(a.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), '') || '"'
      ) AS line
    FROM data.applications a
    JOIN data.applicants ap ON ap.id = a.applicant_id
    LEFT JOIN data.pipeline_stages ps ON ps.id = a.stage_id
    WHERE a.job_posting_id = p_job_posting_id
      AND a.tenant_id = v_tenant
  ) s;

  SELECT count(*)::int INTO v_count
  FROM data.applications
  WHERE job_posting_id = p_job_posting_id AND tenant_id = v_tenant;

  v_filename := 'applications-' || p_job_posting_id::text || '-' || to_char(now(), 'YYYYMMDDHH24MISS') || '.csv';
  v_path := v_tenant::text || '/' || p_job_posting_id::text || '/' || gen_random_uuid()::text || '.csv';

  PERFORM data.log_audit_event(
    v_tenant,
    auth.uid(),
    v_posting.site_id,
    'recruitment.export_applications',
    'job_posting',
    p_job_posting_id,
    jsonb_build_object(
      'row_count', v_count,
      'storage_path', v_path,
      'filename', v_filename,
      'ack_warning', true
    )
  );

  RETURN jsonb_build_object(
    'storage_path', v_path,
    'filename', v_filename,
    'row_count', v_count,
    'csv_text', COALESCE(v_csv, E'full_name,email,phone,source,stage,candidate_visible_status,purge_at,retention_preference,retention_months,created_at\n'),
    'signed_url_ttl_seconds', 900
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.export_job_posting_applications_csv(uuid, boolean)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Storage bucket recruitment-exports
-- Path: {tenant_id}/{job_posting_id}/{uuid}.csv
-- ---------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'recruitment-exports',
  'recruitment-exports',
  false,
  52428800,
  ARRAY['text/csv', 'text/plain', 'application/csv']::text[]
)
ON CONFLICT (id) DO UPDATE SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

CREATE OR REPLACE FUNCTION data.recruitment_export_path_tenant(p_name text)
RETURNS uuid
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT NULLIF(SPLIT_PART(p_name, '/', 1), '')::uuid;
$$;

DROP POLICY IF EXISTS "recruitment-exports: lectura manage" ON storage.objects;
CREATE POLICY "recruitment-exports: lectura manage"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'recruitment-exports'
    AND data.jwt_has_recruitment_permission(
      data.recruitment_export_path_tenant(name),
      'recruitment.manage'
    )
  );

DROP POLICY IF EXISTS "recruitment-exports: upload manage" ON storage.objects;
CREATE POLICY "recruitment-exports: upload manage"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'recruitment-exports'
    AND data.jwt_has_recruitment_permission(
      data.recruitment_export_path_tenant(name),
      'recruitment.manage'
    )
  );

NOTIFY pgrst, 'reload schema';
