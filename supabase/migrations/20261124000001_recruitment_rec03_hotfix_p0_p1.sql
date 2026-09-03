-- =============================================================================
-- REC-0…3 hotfix P0+P1
-- P0: revoke anon/authenticated on submit_job_application (Next service_role only)
-- P1: template_variables; orphan CV cleanup; site-scoped RLS; verify URL is app concern
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Helper: posting → site_id for RLS
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.job_posting_site_id(p_job_posting_id uuid)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT site_id FROM data.job_postings WHERE id = p_job_posting_id;
$$;

GRANT EXECUTE ON FUNCTION data.job_posting_site_id(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION data.recruitment_cv_path_job_posting(p_name text)
RETURNS uuid
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT NULLIF(SPLIT_PART(p_name, '/', 2), '')::uuid;
$$;

-- ---------------------------------------------------------------------------
-- 2. Site-scoped RLS: applications / applicants / consent / CV storage
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS applications_select ON data.applications;
CREATE POLICY applications_select ON data.applications
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_recruitment_permission(
      tenant_id,
      'recruitment.view',
      data.job_posting_site_id(job_posting_id)
    )
  );

DROP POLICY IF EXISTS applications_write ON data.applications;
CREATE POLICY applications_write ON data.applications
  FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_recruitment_permission(
      tenant_id,
      'recruitment.manage',
      data.job_posting_site_id(job_posting_id)
    )
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_recruitment_permission(
      tenant_id,
      'recruitment.manage',
      data.job_posting_site_id(job_posting_id)
    )
  );

DROP POLICY IF EXISTS applicants_select ON data.applicants;
CREATE POLICY applicants_select ON data.applicants
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND EXISTS (
      SELECT 1
      FROM data.applications a
      WHERE a.applicant_id = applicants.id
        AND a.tenant_id = applicants.tenant_id
        AND data.jwt_has_recruitment_permission(
          a.tenant_id,
          'recruitment.view',
          data.job_posting_site_id(a.job_posting_id)
        )
    )
  );

DROP POLICY IF EXISTS applicants_write ON data.applicants;
CREATE POLICY applicants_write ON data.applicants
  FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      data.jwt_has_recruitment_permission(tenant_id, 'recruitment.manage')
      OR EXISTS (
        SELECT 1
        FROM data.applications a
        WHERE a.applicant_id = applicants.id
          AND a.tenant_id = applicants.tenant_id
          AND data.jwt_has_recruitment_permission(
            a.tenant_id,
            'recruitment.manage',
            data.job_posting_site_id(a.job_posting_id)
          )
      )
    )
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      data.jwt_has_recruitment_permission(tenant_id, 'recruitment.manage')
      OR EXISTS (
        SELECT 1
        FROM data.applications a
        WHERE a.applicant_id = applicants.id
          AND a.tenant_id = applicants.tenant_id
          AND data.jwt_has_recruitment_permission(
            a.tenant_id,
            'recruitment.manage',
            data.job_posting_site_id(a.job_posting_id)
          )
      )
    )
  );

DROP POLICY IF EXISTS applicant_consent_events_select ON data.applicant_consent_events;
CREATE POLICY applicant_consent_events_select ON data.applicant_consent_events
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      data.jwt_has_recruitment_permission(tenant_id, 'recruitment.rights')
      OR (
        application_id IS NOT NULL
        AND data.jwt_has_recruitment_permission(
          tenant_id,
          'recruitment.view',
          data.job_posting_site_id((
            SELECT a.job_posting_id FROM data.applications a WHERE a.id = application_id
          ))
        )
      )
    )
  );

DROP POLICY IF EXISTS "recruitment-cvs: lectura HR" ON storage.objects;
CREATE POLICY "recruitment-cvs: lectura HR"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'recruitment-cvs'
    AND EXISTS (
      SELECT 1
      FROM data.job_postings jp
      JOIN data.public_sites ps
        ON ps.id = data.recruitment_cv_path_public_site(name)
       AND ps.tenant_id = jp.tenant_id
      WHERE jp.id = data.recruitment_cv_path_job_posting(name)
        AND data.jwt_has_recruitment_permission(
          jp.tenant_id,
          'recruitment.view',
          jp.site_id
        )
    )
  );

-- ---------------------------------------------------------------------------
-- 3. Delete CV on application DELETE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_applications_delete_cv()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, storage, public
AS $$
BEGIN
  IF OLD.cv_storage_path IS NOT NULL AND btrim(OLD.cv_storage_path) <> '' THEN
    PERFORM data.delete_recruitment_cv_storage(OLD.cv_storage_path);
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS applications_after_delete_cv ON data.applications;
CREATE TRIGGER applications_after_delete_cv
  AFTER DELETE ON data.applications
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_applications_delete_cv();

-- Allow definer triggers / purge to call storage delete
GRANT EXECUTE ON FUNCTION data.delete_recruitment_cv_storage(text) TO postgres;

-- ---------------------------------------------------------------------------
-- 4. submit_job_application: template_variables + orphan CV on duplicate
--    + retention options honesty (get_public) + revoke anon execute
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.submit_job_application(
  p_public_site_id uuid,
  p_job_posting_id uuid,
  p_idempotency_key text,
  p_full_name text,
  p_email text,
  p_phone text DEFAULT NULL,
  p_cover_message text DEFAULT NULL,
  p_source text DEFAULT 'web',
  p_retention_preference text DEFAULT 'delete_after_months',
  p_retention_months int DEFAULT 12,
  p_cv_storage_path text DEFAULT NULL,
  p_legal_notice_version text DEFAULT 'v1',
  p_privacy_accepted boolean DEFAULT false,
  p_locale text DEFAULT 'ca',
  p_verify_base_url text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_tenant uuid;
  v_site_status text;
  v_enabled boolean;
  v_posting data.job_postings%ROWTYPE;
  v_applicant_id uuid;
  v_application_id uuid;
  v_existing_cv text;
  v_stage_id uuid;
  v_email text;
  v_token text;
  v_token_hash text;
  v_settings data.recruitment_settings%ROWTYPE;
  v_verify_url text;
  v_max int;
BEGIN
  -- Public capture must go through Next (service_role). Superuser/tests OK.
  IF auth.role() IS DISTINCT FROM 'service_role'
     AND current_user NOT IN ('postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden'
      USING ERRCODE = '42501',
            HINT = 'submit_job_application només via portal (service_role)';
  END IF;

  IF NOT COALESCE(p_privacy_accepted, false) THEN
    RAISE EXCEPTION 'privacy_not_accepted'
      USING HINT = 'Cal acceptar la informació de protecció de dades.';
  END IF;

  IF COALESCE(trim(p_full_name), '') = '' OR COALESCE(trim(p_email), '') = '' THEN
    RAISE EXCEPTION 'invalid_input'
      USING HINT = 'Nom i email són obligatoris.';
  END IF;

  v_email := lower(trim(p_email));

  IF p_source IS NULL OR p_source NOT IN ('web', 'qr', 'whatsapp', 'email', 'manual', 'csv_import') THEN
    p_source := 'web';
  END IF;

  SELECT ps.tenant_id, ps.status, COALESCE(t.public_portal_enabled, false)
  INTO v_tenant, v_site_status, v_enabled
  FROM data.public_sites ps
  JOIN data.tenants t ON t.id = ps.tenant_id
  WHERE ps.id = p_public_site_id;

  IF NOT FOUND OR v_site_status <> 'published' OR NOT v_enabled THEN
    RAISE EXCEPTION 'site_not_published';
  END IF;

  IF NOT data.is_feature_enabled(v_tenant, 'recruitment_enabled') THEN
    RAISE EXCEPTION 'module_not_enabled';
  END IF;

  SELECT * INTO v_posting
  FROM data.job_postings
  WHERE id = p_job_posting_id AND tenant_id = v_tenant;

  IF NOT FOUND OR v_posting.status <> 'published' THEN
    RAISE EXCEPTION 'posting_not_available';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.job_posting_public_sites
    WHERE job_posting_id = p_job_posting_id AND public_site_id = p_public_site_id
  ) THEN
    RAISE EXCEPTION 'posting_not_on_site';
  END IF;

  SELECT * INTO v_settings FROM data.recruitment_settings WHERE tenant_id = v_tenant;
  v_max := COALESCE(v_settings.default_max_retention_months, 12);

  IF p_retention_preference = 'delete_after_months' THEN
    IF p_retention_months IS NULL OR p_retention_months < 1 THEN
      p_retention_months := v_max;
    END IF;
    p_retention_months := LEAST(p_retention_months, v_max);
  ELSE
    p_retention_preference := 'delete_on_process_end';
    p_retention_months := NULL;
  END IF;

  SELECT id INTO v_stage_id
  FROM data.pipeline_stages
  WHERE tenant_id = v_tenant AND job_posting_id IS NULL
  ORDER BY position
  LIMIT 1;

  v_token := encode(gen_random_bytes(24), 'hex');
  v_token_hash := encode(digest(v_token, 'sha256'), 'hex');

  INSERT INTO data.applicants (
    tenant_id, email, full_name, phone,
    email_verify_token_hash, email_verify_expires_at
  ) VALUES (
    v_tenant, v_email, trim(p_full_name), nullif(trim(p_phone), ''),
    v_token_hash, now() + interval '7 days'
  )
  ON CONFLICT (tenant_id, email) DO UPDATE SET
    full_name = EXCLUDED.full_name,
    phone = COALESCE(EXCLUDED.phone, data.applicants.phone),
    email_verify_token_hash = CASE
      WHEN data.applicants.email_verified_at IS NULL THEN EXCLUDED.email_verify_token_hash
      ELSE data.applicants.email_verify_token_hash
    END,
    email_verify_expires_at = CASE
      WHEN data.applicants.email_verified_at IS NULL THEN EXCLUDED.email_verify_expires_at
      ELSE data.applicants.email_verify_expires_at
    END,
    updated_at = now()
  RETURNING id INTO v_applicant_id;

  INSERT INTO data.applications (
    tenant_id, job_posting_id, applicant_id, stage_id,
    cv_storage_path, retention_preference, retention_months,
    source, cover_message, legal_notice_version,
    purge_at
  ) VALUES (
    v_tenant, p_job_posting_id, v_applicant_id, v_stage_id,
    p_cv_storage_path, p_retention_preference, p_retention_months,
    p_source, nullif(trim(p_cover_message), ''), p_legal_notice_version,
    data.compute_application_purge_at(
      v_tenant, now(), p_retention_preference, p_retention_months, NULL
    )
  )
  ON CONFLICT (job_posting_id, applicant_id) DO NOTHING
  RETURNING id INTO v_application_id;

  IF v_application_id IS NULL THEN
    SELECT id, cv_storage_path INTO v_application_id, v_existing_cv
    FROM data.applications
    WHERE job_posting_id = p_job_posting_id AND applicant_id = v_applicant_id;

    -- Orphan CV uploaded before duplicate RPC response
    IF p_cv_storage_path IS NOT NULL
       AND btrim(p_cv_storage_path) <> ''
       AND p_cv_storage_path IS DISTINCT FROM v_existing_cv THEN
      PERFORM data.delete_recruitment_cv_storage(p_cv_storage_path);
    END IF;

    RETURN jsonb_build_object(
      'application_id', v_application_id,
      'applicant_id', v_applicant_id,
      'duplicate', true
    );
  END IF;

  INSERT INTO data.applicant_consent_events (
    tenant_id, applicant_id, application_id, event_type, legal_text_version, payload
  ) VALUES (
    v_tenant, v_applicant_id, v_application_id, 'apply_consent', p_legal_notice_version,
    jsonb_build_object(
      'privacy_accepted', true,
      'retention_preference', p_retention_preference,
      'retention_months', p_retention_months,
      'idempotency_key', p_idempotency_key,
      'source', p_source
    )
  );

  IF COALESCE(trim(p_verify_base_url), '') <> '' THEN
    v_verify_url := rtrim(trim(p_verify_base_url), '/') || '/recruitment/verify?token=' || v_token;
    BEGIN
      PERFORM api.enqueue_email(jsonb_build_object(
        'tenant_id', v_tenant,
        'idempotency_key', 'recruitment-verify-' || v_application_id::text,
        'to', jsonb_build_array(v_email),
        'event_type', 'recruitment.email_verify',
        'locale', COALESCE(p_locale, 'ca'),
        'template_variables', jsonb_build_object(
          'applicant_name', trim(p_full_name),
          'job_title', v_posting.title,
          'verify_url', v_verify_url
        )
      ));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'submit_job_application: verify email enqueue failed: %', SQLERRM;
    END;
  END IF;

  BEGIN
    PERFORM api.enqueue_email(jsonb_build_object(
      'tenant_id', v_tenant,
      'idempotency_key', 'recruitment-received-' || v_application_id::text,
      'to', jsonb_build_array(v_email),
      'event_type', 'recruitment.application_received',
      'locale', COALESCE(p_locale, 'ca'),
      'template_variables', jsonb_build_object(
        'applicant_name', trim(p_full_name),
        'job_title', v_posting.title,
        'applied_at', to_char(now() AT TIME ZONE 'Europe/Madrid', 'YYYY-MM-DD HH24:MI')
      )
    ));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'submit_job_application: received email enqueue failed: %', SQLERRM;
  END;

  RETURN jsonb_build_object(
    'application_id', v_application_id,
    'applicant_id', v_applicant_id,
    'duplicate', false
  );
END;
$$;

REVOKE ALL ON FUNCTION api.submit_job_application(
  uuid, uuid, text, text, text, text, text, text, text, int, text, text, boolean, text, text
) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.submit_job_application(
  uuid, uuid, text, text, text, text, text, text, text, int, text, text, boolean, text, text
) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION api.submit_job_application(
  uuid, uuid, text, text, text, text, text, text, text, int, text, text, boolean, text, text
) TO service_role;

-- Honest retention options ≤ tenant ceiling (consent transparency)
CREATE OR REPLACE FUNCTION api.get_public_job_posting(
  p_public_site_id uuid,
  p_slug text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid;
  v_status text;
  v_enabled boolean;
  v_row record;
  v_privacy text;
  v_max_ret int;
  v_opts jsonb;
BEGIN
  SELECT ps.tenant_id, ps.status, COALESCE(t.public_portal_enabled, false)
  INTO v_tenant, v_status, v_enabled
  FROM data.public_sites ps
  JOIN data.tenants t ON t.id = ps.tenant_id
  WHERE ps.id = p_public_site_id;

  IF NOT FOUND OR v_status <> 'published' OR NOT v_enabled THEN
    RETURN NULL;
  END IF;

  IF NOT data.is_feature_enabled(v_tenant, 'recruitment_enabled') THEN
    RETURN NULL;
  END IF;

  SELECT jp.* INTO v_row
  FROM data.job_postings jp
  JOIN data.job_posting_public_sites jps
    ON jps.job_posting_id = jp.id AND jps.public_site_id = p_public_site_id
  WHERE jp.tenant_id = v_tenant
    AND jp.public_slug = p_slug
    AND jp.status = 'published'
    AND (jp.opens_at IS NULL OR jp.opens_at <= now())
    AND (jp.closes_at IS NULL OR jp.closes_at > now());

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT privacy_policy_url, default_max_retention_months
  INTO v_privacy, v_max_ret
  FROM data.recruitment_settings
  WHERE tenant_id = v_tenant;

  SELECT COALESCE(jsonb_agg(m ORDER BY m), '[]'::jsonb)
  INTO v_opts
  FROM unnest(ARRAY[3, 6, 12]) AS m
  WHERE m <= COALESCE(v_max_ret, 12);

  IF v_opts = '[]'::jsonb THEN
    v_opts := jsonb_build_array(GREATEST(1, LEAST(12, COALESCE(v_max_ret, 12))));
  END IF;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'title', v_row.title,
    'public_slug', v_row.public_slug,
    'description', v_row.description,
    'opens_at', v_row.opens_at,
    'closes_at', v_row.closes_at,
    'privacy_policy_url', v_privacy,
    'default_max_retention_months', COALESCE(v_max_ret, 12),
    'retention_options_months', v_opts
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_public_job_posting(uuid, text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
