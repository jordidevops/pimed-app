-- =============================================================================
-- REC-6 hotfix P1
-- 1) communicate: reject hired_next_steps (hire has its own RPC)
-- 2) hire: site-scoped permissions + tenant FK validation
-- 3) hire: onboarding effective today (starts_on may be future)
-- 4) purge: never delete applications with hired_employee_id
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. communicate_application_outcome — hire only via hire_application
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
      'locale', 'ca',
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
      'prefs_link', (v_prefs_url <> '')
    )
  );

  RETURN jsonb_build_object(
    'application_id', v_app.id,
    'already_communicated', false,
    'outcome_kind', v_kind,
    'candidate_visible_status', 'closed',
    'prefs_link', (v_prefs_url <> '')
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.communicate_application_outcome(uuid, text, text)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. hire_application — site scope, FK validation, onboarding effective today
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
  v_role text;
  v_lifecycle text;
  v_starts date;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT data.is_feature_enabled(v_tenant, 'recruitment_enabled') THEN
    RAISE EXCEPTION 'module_not_enabled';
  END IF;

  v_role := data.jwt_user_tenants() -> v_tenant::text ->> 'global_role';

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

  -- Scope: recruitment.manage on posting site; employees.manage on resolved site
  IF NOT (
    data.jwt_has_recruitment_permission(
      v_tenant, 'recruitment.manage', v_posting.site_id
    )
    AND (
      data.jwt_has_permission(v_tenant, 'employees.manage', v_site)
      OR COALESCE(v_role, '') IN ('owner', 'manager')
    )
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501',
      HINT = 'Cal recruitment.manage i employees.manage (o owner/manager) al site';
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

  -- Onboarding transition takes effect today so lifecycle sync always applies;
  -- planned start remains on employees.starts_on (may be future).
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
      'employee_id', v_employee_id
    )
  );

  BEGIN
    PERFORM api.enqueue_email(jsonb_build_object(
      'tenant_id', v_tenant,
      'idempotency_key', 'recruitment-hired-' || v_app.id::text,
      'to', jsonb_build_array(v_applicant.email),
      'event_type', 'recruitment.application_hired_next_steps',
      'locale', 'ca',
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
      'applicant_id', v_applicant.id
    )
  );

  SELECT lifecycle_state INTO v_lifecycle
  FROM data.employees WHERE id = v_employee_id;

  RETURN jsonb_build_object(
    'application_id', v_app.id,
    'employee_id', v_employee_id,
    'lifecycle_state', COALESCE(v_lifecycle, 'onboarding'),
    'already_hired', false
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.hire_application(uuid, uuid, uuid, date, uuid)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Purge: never erase hired applications (provenance / CV)
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
        AND a.hired_employee_id IS NULL
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
