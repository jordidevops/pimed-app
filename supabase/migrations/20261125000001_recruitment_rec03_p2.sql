-- =============================================================================
-- REC-0…3 P2
-- - Restrictive RLS: recruitment_enabled required
-- - Column grants: hide erasure_hmac_key from authenticated
-- - Schema-qualify pgcrypto
-- - published requires ≥1 public site
-- - Real submit idempotency key
-- - Purge drains backlog (batched)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Feature flag helper + RESTRICTIVE policies
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.recruitment_module_enabled(p_tenant_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT COALESCE(data.is_feature_enabled(p_tenant_id, 'recruitment_enabled'), false);
$$;

GRANT EXECUTE ON FUNCTION data.recruitment_module_enabled(uuid) TO authenticated, anon, service_role;

DO $$
DECLARE
  t text;
  tables text[] := ARRAY[
    'recruitment_settings',
    'job_postings',
    'job_posting_public_sites',
    'job_posting_templates',
    'pipeline_stages',
    'applicants',
    'applications',
    'applicant_consent_events',
    'applicant_erasure_log',
    'interviews',
    'applicant_data_requests',
    'recruitment_export_packages'
  ];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    IF to_regclass('data.' || t) IS NULL THEN
      CONTINUE;
    END IF;
    EXECUTE format('DROP POLICY IF EXISTS recruitment_module_enabled ON data.%I', t);
    EXECUTE format(
      $p$
      CREATE POLICY recruitment_module_enabled ON data.%I
        AS RESTRICTIVE
        FOR ALL
        TO authenticated
        USING (data.recruitment_module_enabled(tenant_id))
        WITH CHECK (data.recruitment_module_enabled(tenant_id))
      $p$,
      t
    );
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. Column-level grants: never expose erasure_hmac_key
-- ---------------------------------------------------------------------------
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
  updated_at
) ON data.recruitment_settings TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Schema-qualify pgcrypto
-- ---------------------------------------------------------------------------
ALTER TABLE data.recruitment_settings
  ALTER COLUMN erasure_hmac_key SET DEFAULT extensions.gen_random_bytes(32);

CREATE OR REPLACE FUNCTION data.applicant_email_hmac(p_tenant_id uuid, p_email text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = extensions, data, public
AS $$
DECLARE
  v_key bytea;
BEGIN
  SELECT erasure_hmac_key INTO v_key
  FROM data.recruitment_settings
  WHERE tenant_id = p_tenant_id;

  IF v_key IS NULL THEN
    RAISE EXCEPTION 'recruitment_settings_missing';
  END IF;

  RETURN encode(
    extensions.hmac(convert_to(lower(trim(p_email)), 'UTF8'), v_key, 'sha256'),
    'hex'
  );
END;
$$;

CREATE OR REPLACE FUNCTION data.ensure_recruitment_settings()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, extensions, public
AS $$
BEGIN
  INSERT INTO data.recruitment_settings (tenant_id)
  VALUES (NEW.id)
  ON CONFLICT (tenant_id) DO NOTHING;
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. published requires ≥1 public site
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_job_postings_require_public_site()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  -- Insert must not start as published (sites are linked afterwards)
  IF TG_OP = 'INSERT' AND NEW.status = 'published' THEN
    RAISE EXCEPTION 'public_site_required'
      USING ERRCODE = '23514',
            HINT = 'Crea l''oferta en esborrany, vincula un web públic i després publica';
  END IF;

  IF TG_OP = 'UPDATE'
     AND NEW.status = 'published'
     AND OLD.status IS DISTINCT FROM 'published' THEN
    IF NOT EXISTS (
      SELECT 1
      FROM data.job_posting_public_sites jps
      WHERE jps.job_posting_id = NEW.id
    ) THEN
      RAISE EXCEPTION 'public_site_required'
        USING ERRCODE = '23514',
              HINT = 'Cal vincular almenys un web públic abans de publicar l''oferta';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_job_postings_require_public_site ON data.job_postings;
CREATE TRIGGER trg_job_postings_require_public_site
  BEFORE INSERT OR UPDATE OF status
  ON data.job_postings
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_job_postings_require_public_site();

-- Prevent unlinking the last public site while published
CREATE OR REPLACE FUNCTION data.trg_job_posting_public_sites_keep_published()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_posting_id uuid := COALESCE(OLD.job_posting_id, NEW.job_posting_id);
  v_status text;
  v_remain int;
BEGIN
  SELECT status INTO v_status FROM data.job_postings WHERE id = v_posting_id;
  IF v_status IS DISTINCT FROM 'published' THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  IF TG_OP = 'DELETE' THEN
    SELECT count(*) INTO v_remain
    FROM data.job_posting_public_sites
    WHERE job_posting_id = v_posting_id AND public_site_id IS DISTINCT FROM OLD.public_site_id;
    IF v_remain < 1 THEN
      RAISE EXCEPTION 'public_site_required'
        USING ERRCODE = '23514',
              HINT = 'No es pot desemparellar l''últim web públic d''una oferta publicada';
    END IF;
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_job_posting_public_sites_keep_published ON data.job_posting_public_sites;
CREATE TRIGGER trg_job_posting_public_sites_keep_published
  BEFORE DELETE ON data.job_posting_public_sites
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_job_posting_public_sites_keep_published();

-- ---------------------------------------------------------------------------
-- 5. Submit idempotency + pgcrypto qualify in submit
-- ---------------------------------------------------------------------------
ALTER TABLE data.applications
  ADD COLUMN IF NOT EXISTS submit_idempotency_key text;

CREATE UNIQUE INDEX IF NOT EXISTS uq_applications_tenant_submit_idempotency
  ON data.applications (tenant_id, submit_idempotency_key)
  WHERE submit_idempotency_key IS NOT NULL AND length(btrim(submit_idempotency_key)) > 0;

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
  v_idem text := NULLIF(btrim(COALESCE(p_idempotency_key, '')), '');
BEGIN
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

  -- Real idempotency (same key → same application, no second insert)
  IF v_idem IS NOT NULL THEN
    SELECT id, applicant_id, cv_storage_path
    INTO v_application_id, v_applicant_id, v_existing_cv
    FROM data.applications
    WHERE tenant_id = v_tenant AND submit_idempotency_key = v_idem;

    IF FOUND THEN
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

  v_token := encode(extensions.gen_random_bytes(24), 'hex');
  v_token_hash := encode(extensions.digest(v_token, 'sha256'), 'hex');

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
    submit_idempotency_key,
    purge_at
  ) VALUES (
    v_tenant, p_job_posting_id, v_applicant_id, v_stage_id,
    p_cv_storage_path, p_retention_preference, p_retention_months,
    p_source, nullif(trim(p_cover_message), ''), p_legal_notice_version,
    v_idem,
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
      'idempotency_key', v_idem,
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

-- ---------------------------------------------------------------------------
-- 6. Purge: drain backlog in batches (cap 10k / invocation)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.purge_expired_applications()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, extensions, public
AS $$
DECLARE
  r record;
  v_count int := 0;
  v_batch int;
  v_email text;
  v_hmac text;
  v_remain int;
  v_max_total int := 10000;
  v_batch_size int := 500;
BEGIN
  LOOP
    v_batch := 0;
    FOR r IN
      SELECT a.id, a.tenant_id, a.applicant_id, a.cv_storage_path
      FROM data.applications a
      WHERE a.purge_at <= now()
      ORDER BY a.purge_at
      LIMIT v_batch_size
    LOOP
      SELECT email INTO v_email FROM data.applicants WHERE id = r.applicant_id;
      v_hmac := data.applicant_email_hmac(r.tenant_id, v_email);

      PERFORM data.delete_recruitment_cv_storage(r.cv_storage_path);

      DELETE FROM data.applicant_consent_events WHERE application_id = r.id;
      DELETE FROM data.applications WHERE id = r.id;

      INSERT INTO data.applicant_erasure_log (
        tenant_id, email_hmac, reason, scope, applications_count
      ) VALUES (
        r.tenant_id, v_hmac, 'retention_policy', 'application', 1
      );

      SELECT count(*) INTO v_remain
      FROM data.applications
      WHERE applicant_id = r.applicant_id;

      IF v_remain = 0 THEN
        IF NOT EXISTS (
          SELECT 1 FROM data.applicants ap
          WHERE ap.id = r.applicant_id
            AND ap.talent_pool_until IS NOT NULL
            AND ap.talent_pool_until > now()
        ) THEN
          DELETE FROM data.applicant_consent_events WHERE applicant_id = r.applicant_id;
          DELETE FROM data.applicants WHERE id = r.applicant_id;
          INSERT INTO data.applicant_erasure_log (
            tenant_id, email_hmac, reason, scope, applications_count
          ) VALUES (
            r.tenant_id, v_hmac, 'retention_policy', 'applicant', 0
          );
        END IF;
      END IF;

      v_batch := v_batch + 1;
      v_count := v_count + 1;
    END LOOP;

    EXIT WHEN v_batch < v_batch_size OR v_count >= v_max_total;
  END LOOP;

  RETURN v_count;
END;
$$;

NOTIFY pgrst, 'reload schema';
