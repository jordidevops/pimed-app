-- =============================================================================
-- REC-6 tests — hire → employee onboarding
-- =============================================================================

BEGIN;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.set_owner_jwt() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.set_recruitment_only_jwt() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000098', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000098","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["recruitment.view","recruitment.manage"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
END;
$$;

RESET ROLE;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_ps uuid;
  v_posting uuid;
  v_job_pos uuid;
  v_app uuid;
  v_app2 uuid;
  v_result jsonb;
  v_emp uuid;
  v_life text;
  v_visible text;
  v_ok boolean;
  v_err text;
  v_count int;
BEGIN
  INSERT INTO data.tenant_feature_overrides (tenant_id, feature_key, override_status)
  VALUES (v_tenant, 'recruitment_enabled', true)
  ON CONFLICT (tenant_id, feature_key) DO UPDATE SET override_status = true;

  INSERT INTO data.recruitment_settings (tenant_id)
  VALUES (v_tenant) ON CONFLICT DO NOTHING;
  PERFORM data.seed_default_pipeline_stages(v_tenant);

  SELECT id INTO v_ps FROM data.public_sites WHERE tenant_id = v_tenant LIMIT 1;
  IF v_ps IS NULL THEN
    INSERT INTO data.public_sites (tenant_id, slug, name, status, default_locale)
    VALUES (v_tenant, 'rec6-site', 'REC6', 'published', 'ca')
    RETURNING id INTO v_ps;
  ELSE
    UPDATE data.public_sites SET status = 'published' WHERE id = v_ps;
  END IF;
  UPDATE data.tenants SET public_portal_enabled = true WHERE id = v_tenant;

  INSERT INTO data.job_positions (tenant_id, code, name, is_active)
  VALUES (v_tenant, 'REC6-CHEF', 'Chef REC6', true)
  RETURNING id INTO v_job_pos;

  INSERT INTO data.job_postings (tenant_id, title, public_slug, status, created_by, job_position_id)
  VALUES (v_tenant, 'REC6 Job', 'rec6-' || substr(gen_random_uuid()::text, 1, 8), 'draft', v_owner, v_job_pos)
  RETURNING id INTO v_posting;

  INSERT INTO data.job_posting_public_sites (job_posting_id, public_site_id, tenant_id)
  VALUES (v_posting, v_ps, v_tenant) ON CONFLICT DO NOTHING;
  UPDATE data.job_postings SET status = 'published' WHERE id = v_posting;

  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec6-idem-hire',
    'Hire Cand', 'hire.rec6@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );
  SELECT a.id INTO v_app
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE ap.email = 'hire.rec6@example.com' AND a.job_posting_id = v_posting;

  -- Forbidden without employees.manage
  PERFORM pg_temp.set_recruitment_only_jwt();
  v_ok := false;
  BEGIN
    PERFORM api.hire_application(v_app, NULL, NULL, CURRENT_DATE, NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%forbidden%' OR SQLSTATE = '42501' THEN
      v_ok := true;
    ELSE
      v_err := SQLERRM;
    END IF;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('hire_requires_employees_manage', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('hire_requires_employees_manage', 'FAIL', COALESCE(v_err, 'no error'));
  END IF;

  -- Hire OK
  PERFORM pg_temp.set_owner_jwt();
  v_result := api.hire_application(v_app, NULL, NULL, CURRENT_DATE, v_job_pos);
  v_emp := (v_result->>'employee_id')::uuid;

  SELECT lifecycle_state INTO v_life FROM data.employees WHERE id = v_emp;
  SELECT candidate_visible_status INTO v_visible FROM data.applications WHERE id = v_app;

  IF v_emp IS NOT NULL
     AND v_life = 'onboarding'
     AND v_visible = 'closed'
     AND (v_result->>'already_hired')::boolean = false
     AND EXISTS (
       SELECT 1 FROM data.employees
       WHERE id = v_emp AND job_position_id = v_job_pos
     )
     AND EXISTS (
       SELECT 1 FROM data.applications
       WHERE id = v_app AND hired_employee_id = v_emp AND outcome_kind = 'hired_next_steps'
     )
     AND EXISTS (
       SELECT 1 FROM data.employee_lifecycle_events
       WHERE employee_id = v_emp AND to_state = 'onboarding' AND reason_code = 'hire_from_ats'
     )
  THEN
    INSERT INTO test_results VALUES ('hire_creates_onboarding_employee', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'hire_creates_onboarding_employee', 'FAIL',
      format('emp=%s life=%s visible=%s result=%s', v_emp, v_life, v_visible, v_result)
    );
  END IF;

  -- Idempotent
  v_result := api.hire_application(v_app, NULL, NULL, NULL, NULL);
  IF (v_result->>'already_hired')::boolean
     AND (v_result->>'employee_id')::uuid = v_emp
  THEN
    INSERT INTO test_results VALUES ('hire_idempotent', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('hire_idempotent', 'FAIL', v_result::text);
  END IF;

  -- Block after rejection communicated
  PERFORM api.submit_job_application(
    v_ps, v_posting, 'rec6-idem-rej',
    'Reject Then Hire', 'reject-hire.rec6@example.com', NULL, NULL,
    'web', 'delete_after_months', 6, NULL, 'v1', true, 'ca', NULL
  );
  SELECT a.id INTO v_app2
  FROM data.applications a
  JOIN data.applicants ap ON ap.id = a.applicant_id
  WHERE ap.email = 'reject-hire.rec6@example.com';

  PERFORM pg_temp.set_owner_jwt();
  PERFORM api.communicate_application_outcome(v_app2, 'rejected', NULL);

  v_ok := false;
  BEGIN
    PERFORM api.hire_application(v_app2, NULL, NULL, NULL, NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%already_closed_as_rejected%' THEN
      v_ok := true;
    ELSE
      v_err := SQLERRM;
    END IF;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('hire_blocked_after_reject', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('hire_blocked_after_reject', 'FAIL', COALESCE(v_err, 'no error'));
  END IF;

  -- Only one employee from first hire (sanity)
  SELECT count(*)::int INTO v_count
  FROM data.employees
  WHERE tenant_id = v_tenant AND email = 'hire.rec6@example.com';
  IF v_count = 1 THEN
    INSERT INTO test_results VALUES ('hire_single_employee_row', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('hire_single_employee_row', 'FAIL', v_count::text);
  END IF;
END;
$$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'REC-6 tests failed: %', v_fail;
  END IF;
END;
$$;

ROLLBACK;
