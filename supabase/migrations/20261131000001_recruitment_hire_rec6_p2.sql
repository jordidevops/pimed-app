-- =============================================================================
-- REC-6 P2 — locale candidat + alinear gate hire (employees.manage)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Persist apply locale on applicant
-- ---------------------------------------------------------------------------
ALTER TABLE data.applicants
  ADD COLUMN IF NOT EXISTS preferred_locale text;

ALTER TABLE data.applicants
  DROP CONSTRAINT IF EXISTS applicants_preferred_locale_chk;

ALTER TABLE data.applicants
  ADD CONSTRAINT applicants_preferred_locale_chk
  CHECK (
    preferred_locale IS NULL
    OR preferred_locale IN ('ca', 'es', 'en')
  );

COMMENT ON COLUMN data.applicants.preferred_locale IS
  'Locale del formulari d''apply (ca|es|en); usat als correus de selecció/hire.';

CREATE OR REPLACE FUNCTION data.normalize_recruitment_locale(p_locale text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN lower(nullif(btrim(COALESCE(p_locale, '')), '')) IN ('ca', 'es', 'en')
      THEN lower(btrim(p_locale))
    ELSE 'ca'
  END;
$$;

CREATE OR REPLACE FUNCTION data.resolve_applicant_email_locale(
  p_applicant_id uuid,
  p_job_posting_id uuid DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_stored text;
  v_locale text;
BEGIN
  SELECT preferred_locale INTO v_stored
  FROM data.applicants
  WHERE id = p_applicant_id;

  IF nullif(btrim(COALESCE(v_stored, '')), '') IS NOT NULL THEN
    RETURN data.normalize_recruitment_locale(v_stored);
  END IF;

  -- Fallback: default_locale del primer public_site de l'oferta
  IF p_job_posting_id IS NOT NULL THEN
    SELECT ps.default_locale
    INTO v_locale
    FROM data.job_posting_public_sites jps
    JOIN data.public_sites ps ON ps.id = jps.public_site_id
    WHERE jps.job_posting_id = p_job_posting_id
    ORDER BY ps.created_at NULLS LAST, ps.id
    LIMIT 1;

    IF nullif(btrim(COALESCE(v_locale, '')), '') IS NOT NULL THEN
      RETURN data.normalize_recruitment_locale(v_locale);
    END IF;
  END IF;

  RETURN 'ca';
END;
$$;

GRANT EXECUTE ON FUNCTION data.normalize_recruitment_locale(text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION data.resolve_applicant_email_locale(uuid, uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. submit_job_application — desa preferred_locale
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
  v_idem text := NULLIF(btrim(COALESCE(p_idempotency_key, '')), '');
  v_locale text := data.normalize_recruitment_locale(p_locale);
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
    tenant_id, email, full_name, phone, preferred_locale,
    email_verify_token_hash, email_verify_expires_at
  ) VALUES (
    v_tenant, v_email, trim(p_full_name), nullif(trim(p_phone), ''), v_locale,
    v_token_hash, now() + interval '7 days'
  )
  ON CONFLICT (tenant_id, email) DO UPDATE SET
    full_name = EXCLUDED.full_name,
    phone = COALESCE(EXCLUDED.phone, data.applicants.phone),
    preferred_locale = COALESCE(EXCLUDED.preferred_locale, data.applicants.preferred_locale),
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
      'source', p_source,
      'locale', v_locale
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
        'locale', v_locale,
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
      'locale', v_locale,
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
-- 3. communicate — locale del candidat
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.communicate_application_outcome(
  p_application_id uuid,
  p_outcome_kind text DEFAULT 'rejected',
  p_prefs_base_url text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_app data.applications%ROWTYPE;
  v_applicant data.applicants%ROWTYPE;
  v_posting data.job_postings%ROWTYPE;
  v_token text;
  v_token_hash text;
  v_prefs_url text := '';
  v_expires timestamptz;
  v_kind text;
  v_base text;
  v_locale text;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  v_kind := COALESCE(nullif(trim(p_outcome_kind), ''), 'rejected');
  IF v_kind = 'hired_next_steps' THEN
    RAISE EXCEPTION 'use_hire_application'
      USING HINT = 'El contracte (hire) només via api.hire_application';
  END IF;
  IF v_kind NOT IN ('rejected', 'withdrawn') THEN
    RAISE EXCEPTION 'invalid_outcome_kind';
  END IF;

  SELECT * INTO v_app
  FROM data.applications
  WHERE id = p_application_id AND tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;

  IF v_app.outcome_communicated_at IS NOT NULL THEN
    RETURN jsonb_build_object(
      'application_id', v_app.id,
      'already_communicated', true,
      'candidate_visible_status', v_app.candidate_visible_status
    );
  END IF;

  SELECT * INTO v_applicant FROM data.applicants WHERE id = v_app.applicant_id;
  SELECT * INTO v_posting FROM data.job_postings WHERE id = v_app.job_posting_id;

  IF NOT data.jwt_has_recruitment_permission(
    v_tenant, 'recruitment.manage', v_posting.site_id
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501',
      HINT = 'Cal recruitment.manage (tenant o site de l''oferta)';
  END IF;

  PERFORM data.assert_applicant_processing_allowed(v_app.applicant_id);

  v_locale := data.resolve_applicant_email_locale(v_app.applicant_id, v_app.job_posting_id);

  v_base := NULLIF(btrim(COALESCE(p_prefs_base_url, '')), '');
  IF v_base IS NULL THEN
    v_base := data.resolve_candidate_portal_base_url(v_tenant);
  ELSE
    v_base := rtrim(v_base, '/');
  END IF;

  IF v_base IS NOT NULL THEN
    v_token := encode(extensions.gen_random_bytes(24), 'hex');
    v_token_hash := encode(extensions.digest(v_token, 'sha256'), 'hex');
    v_expires := now() + interval '30 days';
    v_prefs_url := v_base || '/recruitment/preferences?token=' || v_token;
  END IF;

  UPDATE data.applications SET
    outcome_communicated_at = now(),
    outcome_kind = v_kind,
    process_closed_at = COALESCE(process_closed_at, now()),
    post_rejection_token_hash = v_token_hash,
    post_rejection_token_expires_at = v_expires,
    updated_at = now()
  WHERE id = v_app.id;

  BEGIN
    PERFORM api.enqueue_email(jsonb_build_object(
      'tenant_id', v_tenant,
      'idempotency_key', 'recruitment-rejected-' || v_app.id::text,
      'to', jsonb_build_array(v_applicant.email),
      'event_type', 'recruitment.application_rejected',
      'locale', v_locale,
      'template_variables', jsonb_build_object(
        'applicant_name', v_applicant.full_name,
        'job_title', v_posting.title,
        'preferences_url', v_prefs_url,
        'prefs_expires_at', CASE
          WHEN v_expires IS NULL THEN ''
          ELSE to_char(v_expires AT TIME ZONE 'Europe/Madrid', 'YYYY-MM-DD')
        END
      )
    ));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'communicate_application_outcome: email failed: %', SQLERRM;
  END;

  INSERT INTO data.applicant_consent_events (
    tenant_id, applicant_id, application_id, event_type, legal_text_version, payload
  ) VALUES (
    v_tenant, v_app.applicant_id, v_app.id, 'outcome_communicated', 'v1',
    jsonb_build_object(
      'outcome_kind', v_kind,
      'prefs_link', (v_prefs_url <> ''),
      'locale', v_locale
    )
  );

  RETURN jsonb_build_object(
    'application_id', v_app.id,
    'already_communicated', false,
    'outcome_kind', v_kind,
    'candidate_visible_status', 'closed',
    'prefs_link', (v_prefs_url <> ''),
    'email_locale', v_locale
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.communicate_application_outcome(uuid, text, text)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. hire — locale + gate estricte (employees.manage, sense bypass de rol)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.hire_application(
  p_application_id uuid,
  p_site_id uuid DEFAULT NULL,
  p_department_id uuid DEFAULT NULL,
  p_starts_on date DEFAULT NULL,
  p_job_position_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_app data.applications%ROWTYPE;
  v_applicant data.applicants%ROWTYPE;
  v_posting data.job_postings%ROWTYPE;
  v_employee_id uuid;
  v_stage_hire uuid;
  v_site uuid;
  v_dept uuid;
  v_job_position_id uuid;
  v_title text;
  v_lifecycle text;
  v_starts date;
  v_locale text;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT data.is_feature_enabled(v_tenant, 'recruitment_enabled') THEN
    RAISE EXCEPTION 'module_not_enabled';
  END IF;

  SELECT * INTO v_app
  FROM data.applications
  WHERE id = p_application_id AND tenant_id = v_tenant
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;

  IF v_app.hired_employee_id IS NOT NULL THEN
    SELECT lifecycle_state INTO v_lifecycle
    FROM data.employees WHERE id = v_app.hired_employee_id;
    RETURN jsonb_build_object(
      'application_id', v_app.id,
      'employee_id', v_app.hired_employee_id,
      'lifecycle_state', v_lifecycle,
      'already_hired', true
    );
  END IF;

  IF v_app.outcome_kind IN ('rejected', 'withdrawn') THEN
    RAISE EXCEPTION 'already_closed_as_rejected'
      USING HINT = 'La candidatura ja s''ha comunicat com a rebuig/retirada.';
  END IF;

  SELECT * INTO v_applicant FROM data.applicants WHERE id = v_app.applicant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'applicant_missing';
  END IF;

  PERFORM data.assert_applicant_processing_allowed(v_app.applicant_id);

  SELECT * INTO v_posting FROM data.job_postings WHERE id = v_app.job_posting_id;

  v_site := COALESCE(p_site_id, v_posting.site_id);
  v_dept := COALESCE(p_department_id, v_posting.department_id);
  v_job_position_id := COALESCE(p_job_position_id, v_posting.job_position_id);
  v_starts := COALESCE(p_starts_on, CURRENT_DATE);
  v_locale := data.resolve_applicant_email_locale(v_app.applicant_id, v_app.job_posting_id);

  IF v_site IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM data.sites s WHERE s.id = v_site AND s.tenant_id = v_tenant
  ) THEN
    RAISE EXCEPTION 'invalid_site'
      USING HINT = 'site_id no pertany al tenant';
  END IF;

  IF v_dept IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM data.departments d WHERE d.id = v_dept AND d.tenant_id = v_tenant
  ) THEN
    RAISE EXCEPTION 'invalid_department'
      USING HINT = 'department_id no pertany al tenant';
  END IF;

  IF v_job_position_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM data.job_positions jp
    WHERE jp.id = v_job_position_id AND jp.tenant_id = v_tenant
  ) THEN
    RAISE EXCEPTION 'invalid_job_position'
      USING HINT = 'job_position_id no pertany al tenant';
  END IF;

  -- Mateix criteri que la UI: recruitment.manage + employees.manage (sense bypass de rol)
  IF NOT (
    data.jwt_has_recruitment_permission(
      v_tenant, 'recruitment.manage', v_posting.site_id
    )
    AND data.jwt_has_permission(v_tenant, 'employees.manage', v_site)
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501',
      HINT = 'Cal recruitment.manage i employees.manage al site';
  END IF;

  v_title := COALESCE(
    (
      SELECT jp.name FROM data.job_positions jp
      WHERE jp.id = v_job_position_id AND jp.tenant_id = v_tenant
    ),
    nullif(trim(v_posting.title), ''),
    'Empleat'
  );

  INSERT INTO data.employees (
    tenant_id, site_id, department_id, full_name, email, phone,
    job_position_id, status, starts_on, metadata
  ) VALUES (
    v_tenant, v_site, v_dept, v_applicant.full_name, v_applicant.email, v_applicant.phone,
    v_job_position_id, 'active', v_starts,
    jsonb_build_object(
      'source', 'recruitment_hire',
      'application_id', v_app.id,
      'applicant_id', v_applicant.id,
      'job_posting_id', v_posting.id
    )
  )
  RETURNING id INTO v_employee_id;

  INSERT INTO data.employee_lifecycle_events (
    tenant_id, employee_id, from_state, to_state, reason_code,
    effective_on, triggered_by, source, metadata
  ) VALUES (
    v_tenant, v_employee_id, NULL, 'onboarding', 'hire_from_ats',
    CURRENT_DATE, auth.uid(), 'manual',
    jsonb_build_object(
      'application_id', v_app.id,
      'applicant_id', v_applicant.id,
      'job_posting_id', v_posting.id,
      'planned_starts_on', v_starts
    )
  );

  SELECT id INTO v_stage_hire
  FROM data.pipeline_stages
  WHERE tenant_id = v_tenant
    AND is_terminal_hire
    AND (job_posting_id = v_app.job_posting_id OR job_posting_id IS NULL)
  ORDER BY job_posting_id NULLS LAST, position
  LIMIT 1;

  UPDATE data.applications SET
    hired_employee_id = v_employee_id,
    hired_at = now(),
    stage_id = COALESCE(v_stage_hire, stage_id),
    outcome_communicated_at = COALESCE(outcome_communicated_at, now()),
    outcome_kind = 'hired_next_steps',
    process_closed_at = COALESCE(process_closed_at, now()),
    updated_at = now()
  WHERE id = v_app.id;

  INSERT INTO data.applicant_consent_events (
    tenant_id, applicant_id, application_id, event_type, legal_text_version, payload
  ) VALUES (
    v_tenant, v_app.applicant_id, v_app.id, 'outcome_communicated', 'v1',
    jsonb_build_object(
      'outcome_kind', 'hired_next_steps',
      'employee_id', v_employee_id,
      'locale', v_locale
    )
  );

  BEGIN
    PERFORM api.enqueue_email(jsonb_build_object(
      'tenant_id', v_tenant,
      'idempotency_key', 'recruitment-hired-' || v_app.id::text,
      'to', jsonb_build_array(v_applicant.email),
      'event_type', 'recruitment.application_hired_next_steps',
      'locale', v_locale,
      'template_variables', jsonb_build_object(
        'applicant_name', v_applicant.full_name,
        'job_title', v_title
      )
    ));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'hire_application: email failed: %', SQLERRM;
  END;

  PERFORM data.log_audit_event(
    v_tenant,
    auth.uid(),
    v_site,
    'recruitment.hire_application',
    'application',
    v_app.id,
    jsonb_build_object(
      'employee_id', v_employee_id,
      'job_posting_id', v_posting.id,
      'applicant_id', v_applicant.id,
      'email_locale', v_locale
    )
  );

  SELECT lifecycle_state INTO v_lifecycle
  FROM data.employees WHERE id = v_employee_id;

  RETURN jsonb_build_object(
    'application_id', v_app.id,
    'employee_id', v_employee_id,
    'lifecycle_state', COALESCE(v_lifecycle, 'onboarding'),
    'already_hired', false,
    'email_locale', v_locale
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.hire_application(uuid, uuid, uuid, date, uuid)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
