-- =============================================================================
-- REC-4 P1–P2
-- P1: interview notes SELECT = interview|manage; RLS/neg tests (separate file)
-- P2: CSV formula escape; interviews UPDATE WITH CHECK; site scope move/export;
--     pipeline_stages write WITH CHECK includes manage
-- Also: jwt_has_permission must never return NULL (IF NOT NULL skips deny)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. Boolean-safe permission check (NULL OR false → false)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.jwt_has_permission(
  p_tenant_id  uuid,
  p_permission text,
  p_site_id    uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT COALESCE(
    CASE
      WHEN (data.jwt_user_permissions() -> p_tenant_id::text -> 'global_permissions') @> '["*"]'::jsonb
        THEN true
      WHEN p_site_id IS NULL THEN
        (data.jwt_user_permissions() -> p_tenant_id::text -> 'global_permissions') ? p_permission
      ELSE
        (data.jwt_user_permissions() -> p_tenant_id::text -> 'global_permissions') ? p_permission
        OR
        (data.jwt_user_permissions() -> p_tenant_id::text -> 'sites' -> p_site_id::text -> 'permissions') @> '["*"]'::jsonb
        OR
        (data.jwt_user_permissions() -> p_tenant_id::text -> 'sites' -> p_site_id::text -> 'permissions') ? p_permission
    END,
    false
  );
$$;

-- ---------------------------------------------------------------------------
-- 1. Interview notes: no longer readable with recruitment.view alone
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS interviews_select ON data.interviews;
CREATE POLICY interviews_select ON data.interviews
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      data.jwt_has_recruitment_permission(tenant_id, 'recruitment.interview')
      OR data.jwt_has_recruitment_permission(tenant_id, 'recruitment.manage')
    )
  );

DROP POLICY IF EXISTS interviews_update ON data.interviews;
CREATE POLICY interviews_update ON data.interviews
  FOR UPDATE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      data.jwt_has_recruitment_permission(tenant_id, 'recruitment.interview')
      OR data.jwt_has_recruitment_permission(tenant_id, 'recruitment.manage')
    )
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      data.jwt_has_recruitment_permission(tenant_id, 'recruitment.interview')
      OR data.jwt_has_recruitment_permission(tenant_id, 'recruitment.manage')
    )
  );

-- Align pipeline_stages write WITH CHECK with manage
DROP POLICY IF EXISTS pipeline_stages_write ON data.pipeline_stages;
CREATE POLICY pipeline_stages_write ON data.pipeline_stages
  FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_recruitment_permission(tenant_id, 'recruitment.manage')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_recruitment_permission(tenant_id, 'recruitment.manage')
  );

-- ---------------------------------------------------------------------------
-- 2. CSV formula-injection escape
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.csv_escape_cell(p_value text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v text := COALESCE(p_value, '');
BEGIN
  -- Neutralize spreadsheet formula injection (Excel/LibreOffice)
  IF v <> '' AND left(v, 1) IN ('=', '+', '-', '@', E'\t', E'\r') THEN
    v := '''' || v;
  END IF;
  RETURN '"' || replace(v, '"', '""') || '"';
END;
$$;

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
        data.csv_escape_cell(ap.full_name),
        data.csv_escape_cell(ap.email),
        data.csv_escape_cell(ap.phone),
        data.csv_escape_cell(a.source),
        data.csv_escape_cell(ps.name),
        data.csv_escape_cell(a.candidate_visible_status),
        data.csv_escape_cell(
          to_char(a.purge_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        ),
        data.csv_escape_cell(a.retention_preference),
        COALESCE(a.retention_months::text, ''),
        data.csv_escape_cell(
          to_char(a.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        )
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

-- ---------------------------------------------------------------------------
-- 3. Site-scoped permission on move + export
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
  v_posting_site uuid;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_app
  FROM data.applications
  WHERE id = p_application_id AND tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found' USING HINT = 'Candidatura no trobada';
  END IF;

  SELECT site_id INTO v_posting_site
  FROM data.job_postings
  WHERE id = v_app.job_posting_id AND tenant_id = v_tenant;

  IF NOT data.jwt_has_recruitment_permission(
    v_tenant, 'recruitment.manage', v_posting_site
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501',
      HINT = 'Cal recruitment.manage (tenant o site de l''oferta)';
  END IF;

  PERFORM data.assert_applicant_processing_allowed(v_app.applicant_id);

  SELECT * INTO v_stage
  FROM data.pipeline_stages
  WHERE id = p_stage_id AND tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid_stage' USING HINT = 'Etapa no vàlida';
  END IF;

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

  IF NOT data.jwt_has_recruitment_permission(
    v_tenant, 'recruitment.manage', v_posting.site_id
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501',
      HINT = 'Cal recruitment.manage (tenant o site de l''oferta)';
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
-- 4. Clone tenant stages → posting override (helper for UI)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.clone_pipeline_stages_to_posting(p_job_posting_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_posting data.job_postings%ROWTYPE;
  v_count int := 0;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_posting
  FROM data.job_postings
  WHERE id = p_job_posting_id AND tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;

  IF NOT data.jwt_has_recruitment_permission(
    v_tenant, 'recruitment.manage', v_posting.site_id
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF EXISTS (
    SELECT 1 FROM data.pipeline_stages
    WHERE tenant_id = v_tenant AND job_posting_id = p_job_posting_id
  ) THEN
    RAISE EXCEPTION 'override_already_exists'
      USING HINT = 'Aquesta oferta ja té etapes pròpies';
  END IF;

  INSERT INTO data.pipeline_stages (
    tenant_id, job_posting_id, name, position, is_terminal_hire, is_terminal_reject
  )
  SELECT
    v_tenant, p_job_posting_id, name, position, is_terminal_hire, is_terminal_reject
  FROM data.pipeline_stages
  WHERE tenant_id = v_tenant AND job_posting_id IS NULL
  ORDER BY position;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  RETURN jsonb_build_object(
    'job_posting_id', p_job_posting_id,
    'cloned', v_count
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.clone_pipeline_stages_to_posting(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION api.delete_pipeline_stage_override(p_job_posting_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_posting data.job_postings%ROWTYPE;
  v_deleted int;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_posting
  FROM data.job_postings
  WHERE id = p_job_posting_id AND tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;

  IF NOT data.jwt_has_recruitment_permission(
    v_tenant, 'recruitment.manage', v_posting.site_id
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  -- Clear application stage refs that point at override stages
  UPDATE data.applications a SET
    stage_id = NULL,
    updated_at = now()
  WHERE a.job_posting_id = p_job_posting_id
    AND a.tenant_id = v_tenant
    AND a.stage_id IN (
      SELECT id FROM data.pipeline_stages
      WHERE job_posting_id = p_job_posting_id AND tenant_id = v_tenant
    );

  DELETE FROM data.pipeline_stages
  WHERE tenant_id = v_tenant AND job_posting_id = p_job_posting_id;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RETURN jsonb_build_object(
    'job_posting_id', p_job_posting_id,
    'deleted', v_deleted
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.delete_pipeline_stage_override(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
