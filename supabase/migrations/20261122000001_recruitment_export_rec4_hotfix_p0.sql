-- =============================================================================
-- REC-4 hotfix P0
-- - Export: no csv_text to client; package held server-side; Edge uploads + signs
-- - Exclude Art.18 / Art.21 applicants from CSV
-- - Purge expired recruitment-exports objects + packages
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Internal packages (no api view / no grants to authenticated)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.recruitment_export_packages (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  job_posting_id  uuid NOT NULL REFERENCES data.job_postings(id) ON DELETE CASCADE,
  storage_path    text NOT NULL,
  filename        text NOT NULL,
  csv_text        text,
  row_count       int NOT NULL DEFAULT 0,
  excluded_count  int NOT NULL DEFAULT 0,
  created_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  expires_at      timestamptz NOT NULL DEFAULT (now() + interval '1 hour'),
  claimed_at      timestamptz,
  uploaded_at     timestamptz,
  UNIQUE (tenant_id, storage_path)
);

CREATE INDEX IF NOT EXISTS idx_recruitment_export_packages_expires
  ON data.recruitment_export_packages (expires_at)
  WHERE csv_text IS NOT NULL OR uploaded_at IS NOT NULL;

ALTER TABLE data.recruitment_export_packages ENABLE ROW LEVEL SECURITY;
-- No policies for authenticated — only SECURITY DEFINER / service_role

REVOKE ALL ON data.recruitment_export_packages FROM PUBLIC, authenticated, anon;
GRANT ALL ON data.recruitment_export_packages TO service_role;

COMMENT ON TABLE data.recruitment_export_packages IS
  'REC-4 P0: ephemeral CSV payloads for export. Never expose via api.* views.';

-- ---------------------------------------------------------------------------
-- 2. CSV builder (excludes restricted / objected)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.build_job_posting_applications_csv(
  p_tenant_id uuid,
  p_job_posting_id uuid,
  OUT p_csv text,
  OUT p_row_count int,
  OUT p_excluded_count int
)
RETURNS record
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  SELECT count(*)::int INTO p_excluded_count
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE a.job_posting_id = p_job_posting_id
    AND a.tenant_id = p_tenant_id
    AND (
      ap.processing_restricted_at IS NOT NULL
      OR ap.objection_at IS NOT NULL
    );

  SELECT
    E'full_name,email,phone,source,stage,candidate_visible_status,purge_at,retention_preference,retention_months,created_at\n'
    || COALESCE(string_agg(line, E'\n' ORDER BY ord), ''),
    count(*)::int
  INTO p_csv, p_row_count
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
      AND a.tenant_id = p_tenant_id
      AND ap.processing_restricted_at IS NULL
      AND ap.objection_at IS NULL
  ) s;
END;
$$;

REVOKE ALL ON FUNCTION data.build_job_posting_applications_csv(uuid, uuid) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- 3. prepare export (authenticated) — NO csv_text in response
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
  v_excluded int := 0;
  v_path text;
  v_filename text;
  v_pkg_id uuid;
  v_expires timestamptz := now() + interval '1 hour';
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

  SELECT b.p_csv, b.p_row_count, b.p_excluded_count
  INTO v_csv, v_count, v_excluded
  FROM data.build_job_posting_applications_csv(v_tenant, p_job_posting_id) AS b;

  v_filename := 'applications-' || p_job_posting_id::text || '-' || to_char(now(), 'YYYYMMDDHH24MISS') || '.csv';
  v_path := v_tenant::text || '/' || p_job_posting_id::text || '/' || gen_random_uuid()::text || '.csv';

  INSERT INTO data.recruitment_export_packages (
    tenant_id, job_posting_id, storage_path, filename, csv_text,
    row_count, excluded_count, created_by, expires_at
  ) VALUES (
    v_tenant, p_job_posting_id, v_path, v_filename,
    COALESCE(
      v_csv,
      E'full_name,email,phone,source,stage,candidate_visible_status,purge_at,retention_preference,retention_months,created_at\n'
    ),
    COALESCE(v_count, 0),
    COALESCE(v_excluded, 0),
    auth.uid(),
    v_expires
  )
  RETURNING id INTO v_pkg_id;

  -- Metadata only — never return csv_text to the browser/RPC client
  RETURN jsonb_build_object(
    'package_id', v_pkg_id,
    'storage_path', v_path,
    'filename', v_filename,
    'row_count', COALESCE(v_count, 0),
    'excluded_count', COALESCE(v_excluded, 0),
    'expires_at', v_expires,
    'signed_url_ttl_seconds', 900
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.export_job_posting_applications_csv(uuid, boolean)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. claim package (service_role / Edge) — one-shot CSV handoff
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.claim_recruitment_export_package(p_package_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_pkg data.recruitment_export_packages%ROWTYPE;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501',
      HINT = 'Només service_role (Edge Function)';
  END IF;

  SELECT * INTO v_pkg
  FROM data.recruitment_export_packages
  WHERE id = p_package_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;

  IF v_pkg.expires_at <= now() THEN
    RAISE EXCEPTION 'expired';
  END IF;

  IF v_pkg.csv_text IS NULL THEN
    RAISE EXCEPTION 'already_claimed';
  END IF;

  UPDATE data.recruitment_export_packages SET
    claimed_at = now()
  WHERE id = v_pkg.id;

  RETURN jsonb_build_object(
    'package_id', v_pkg.id,
    'tenant_id', v_pkg.tenant_id,
    'job_posting_id', v_pkg.job_posting_id,
    'storage_path', v_pkg.storage_path,
    'filename', v_pkg.filename,
    'csv_text', v_pkg.csv_text,
    'row_count', v_pkg.row_count,
    'excluded_count', v_pkg.excluded_count,
    'created_by', v_pkg.created_by
  );
END;
$$;

REVOKE ALL ON FUNCTION api.claim_recruitment_export_package(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.claim_recruitment_export_package(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. finalize after upload — clear PII blob + audit
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.finalize_recruitment_export(
  p_package_id uuid,
  p_uploaded boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_pkg data.recruitment_export_packages%ROWTYPE;
  v_site uuid;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_pkg
  FROM data.recruitment_export_packages
  WHERE id = p_package_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;

  UPDATE data.recruitment_export_packages SET
    csv_text = NULL,
    uploaded_at = CASE WHEN p_uploaded THEN now() ELSE uploaded_at END
  WHERE id = v_pkg.id;

  SELECT site_id INTO v_site
  FROM data.job_postings
  WHERE id = v_pkg.job_posting_id;

  IF p_uploaded THEN
    PERFORM data.log_audit_event(
      v_pkg.tenant_id,
      v_pkg.created_by,
      v_site,
      'recruitment.export_applications',
      'job_posting',
      v_pkg.job_posting_id,
      jsonb_build_object(
        'package_id', v_pkg.id,
        'row_count', v_pkg.row_count,
        'excluded_count', v_pkg.excluded_count,
        'storage_path', v_pkg.storage_path,
        'filename', v_pkg.filename,
        'ack_warning', true,
        'uploaded', true
      )
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'package_id', v_pkg.id);
END;
$$;

REVOKE ALL ON FUNCTION api.finalize_recruitment_export(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.finalize_recruitment_export(uuid, boolean) TO service_role;

-- ---------------------------------------------------------------------------
-- 6. Storage DELETE policy + purge
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "recruitment-exports: delete manage" ON storage.objects;
CREATE POLICY "recruitment-exports: delete manage"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'recruitment-exports'
    AND data.jwt_has_recruitment_permission(
      data.recruitment_export_path_tenant(name),
      'recruitment.manage'
    )
  );

CREATE OR REPLACE FUNCTION data.purge_expired_recruitment_exports()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, storage, public
AS $$
DECLARE
  r record;
  v_count int := 0;
BEGIN
  PERFORM set_config('storage.allow_delete_query', 'true', true);

  FOR r IN
    SELECT id, storage_path
    FROM data.recruitment_export_packages
    WHERE expires_at <= now()
    ORDER BY expires_at
    LIMIT 500
  LOOP
    DELETE FROM storage.objects
    WHERE bucket_id = 'recruitment-exports'
      AND name = r.storage_path;

    DELETE FROM data.recruitment_export_packages WHERE id = r.id;
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION data.purge_expired_recruitment_exports() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.purge_expired_recruitment_exports() TO service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('recruitment-purge-expired-exports');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    PERFORM cron.schedule(
      'recruitment-purge-expired-exports',
      '30 3 * * *',
      $cron$SELECT data.purge_expired_recruitment_exports()$cron$
    );
  END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';
