-- Fix hire permission check: use JWT global_role (not my_role_in) and
-- COALESCE so NULL membership cannot bypass the IF NOT (...) gate.
CREATE OR REPLACE FUNCTION api.hire_application(
  p_application_id uuid,
  p_site_id uuid DEFAULT NULL,
  p_department_id uuid DEFAULT NULL,
  p_starts_on date DEFAULT NULL,
  p_job_title text DEFAULT NULL
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
  v_title text;
  v_role text;
  v_lifecycle text;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  v_role := data.jwt_user_tenants() -> v_tenant::text ->> 'global_role';

  IF NOT (
    data.jwt_has_recruitment_permission(v_tenant, 'recruitment.manage')
    AND (
      data.jwt_has_permission(v_tenant, 'employees.manage')
      OR COALESCE(v_role, '') IN ('owner', 'manager')
    )
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501',
      HINT = 'Cal recruitment.manage i employees.manage (o owner/manager)';
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
  v_title := COALESCE(
    nullif(trim(p_job_title), ''),
    nullif(trim(v_posting.title), ''),
    'Empleat'
  );

  INSERT INTO data.employees (
    tenant_id, site_id, department_id, full_name, email, phone,
    job_title, status, starts_on, metadata
  ) VALUES (
    v_tenant, v_site, v_dept, v_applicant.full_name, v_applicant.email, v_applicant.phone,
    v_title, 'active', COALESCE(p_starts_on, CURRENT_DATE),
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
    COALESCE(p_starts_on, CURRENT_DATE), auth.uid(), 'manual',
    jsonb_build_object(
      'application_id', v_app.id,
      'applicant_id', v_applicant.id,
      'job_posting_id', v_posting.id
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

GRANT EXECUTE ON FUNCTION api.hire_application(uuid, uuid, uuid, date, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
