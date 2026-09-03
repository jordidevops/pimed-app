-- =============================================================================
-- ES-1 dispatch eligibility + start_work_log gate tests
-- =============================================================================

BEGIN;

SET LOCAL ROLE authenticated;

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
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}},"10000000-0000-0000-0000-000000000002":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.set_charlie_jwt() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000004', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000004","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{"30000000-0000-0000-0000-000000000001":"manager"}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
END;
$$;

SELECT pg_temp.set_owner_jwt();

-- T1: active + ready → eligible
DO $$
DECLARE
  v_emp uuid := '40000000-0000-0000-0000-000000000001';
  v_result jsonb;
  v_state text;
BEGIN
  SELECT lifecycle_state INTO v_state FROM data.employees WHERE id = v_emp;
  IF v_state = 'on_leave' THEN
    PERFORM api.transition_employee_lifecycle(v_emp, 'active', 'leave_ended', CURRENT_DATE, '{}'::jsonb);
  END IF;

  v_result := data.compute_employee_dispatch_eligibility(v_emp, CURRENT_DATE);
  IF (v_result->>'is_eligible')::boolean = true
     AND v_result->>'lifecycle_state' = 'active' THEN
    INSERT INTO test_results VALUES ('T1 active+ready eligible', 'PASS', v_result::text);
  ELSE
    INSERT INTO test_results VALUES ('T1 active+ready eligible', 'FAIL', v_result::text);
  END IF;
END $$;

-- T2: on_leave → not eligible
DO $$
DECLARE
  v_emp uuid := '40000000-0000-0000-0000-000000000001';
  v_result jsonb;
BEGIN
  PERFORM api.transition_employee_lifecycle(v_emp, 'on_leave', 'leave_started', CURRENT_DATE, '{}'::jsonb);
  v_result := data.compute_employee_dispatch_eligibility(v_emp, CURRENT_DATE);

  IF (v_result->>'is_eligible')::boolean = false
     AND v_result->'blocking_reasons' ?| array['LIFECYCLE_STATE_ON_LEAVE'] THEN
    INSERT INTO test_results VALUES ('T2 on_leave not eligible', 'PASS', v_result::text);
  ELSE
    INSERT INTO test_results VALUES ('T2 on_leave not eligible', 'FAIL', v_result::text);
  END IF;

  PERFORM api.transition_employee_lifecycle(v_emp, 'active', 'leave_ended', CURRENT_DATE, '{}'::jsonb);
END $$;

-- T3: active + blocking readiness → not eligible
DO $$
DECLARE
  v_emp uuid := '40000000-0000-0000-0000-000000000001';
  v_type uuid;
  v_rule uuid;
  v_result jsonb;
  v_cert record;
BEGIN
  SELECT id INTO v_type FROM data.compliance_requirement_types
  WHERE tenant_id IS NULL AND code = 'PRL_BASIC' LIMIT 1;

  FOR v_cert IN
    SELECT id FROM data.employee_certifications
    WHERE employee_id = v_emp AND requirement_type_id = v_type AND revoked_at IS NULL
  LOOP
    PERFORM api.revoke_employee_certification(v_cert.id, 'es1_cleanup');
  END LOOP;

  SELECT (api.upsert_compliance_requirement_rule(
    NULL, v_type, 'tenant', NULL, true, 0, true
  )).id INTO v_rule;

  v_result := data.compute_employee_dispatch_eligibility(v_emp, CURRENT_DATE);

  IF (v_result->>'is_eligible')::boolean = false
     AND v_result->'blocking_reasons' ?| array['MISSING_OR_EXPIRED:PRL_BASIC'] THEN
    INSERT INTO test_results VALUES ('T3 active+not-ready not eligible', 'PASS', v_result::text);
  ELSE
    INSERT INTO test_results VALUES ('T3 active+not-ready not eligible', 'FAIL', v_result::text);
  END IF;

  PERFORM api.upsert_compliance_requirement_rule(v_rule, NULL, NULL, NULL, NULL, NULL, false);
END $$;

-- T4: multi-tenant guard
DO $$
DECLARE
  v_emp uuid := '40000000-0000-0000-0000-000000000001';
  v_ok boolean := false;
BEGIN
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000002"}', true);
  BEGIN
    PERFORM data.compute_employee_dispatch_eligibility(v_emp, CURRENT_DATE);
  EXCEPTION WHEN no_data_found THEN
    v_ok := true;
  END;
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T4 multi-tenant guard', 'PASS', 'employee_not_found');
  ELSE
    INSERT INTO test_results VALUES ('T4 multi-tenant guard', 'FAIL', 'expected no_data_found');
  END IF;
END $$;

-- T5: assert not granted to authenticated (only internal RPCs)
DO $$
DECLARE
  v_emp uuid := '40000000-0000-0000-0000-000000000001';
  v_ok boolean := false;
BEGIN
  BEGIN
    PERFORM data.assert_employee_dispatch_eligible(v_emp, CURRENT_DATE);
  EXCEPTION
    WHEN insufficient_privilege THEN
      v_ok := true;
    WHEN OTHERS THEN
      IF SQLSTATE = '42501' THEN
        v_ok := true;
      END IF;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T5 assert not callable by authenticated', 'PASS', 'insufficient_privilege');
  ELSE
    INSERT INTO test_results VALUES ('T5 assert not callable by authenticated', 'FAIL', 'expected privilege error');
  END IF;
END $$;

RESET ROLE;

-- Close Charlie open logs + ensure Charlie can be put on leave (as postgres helper)
UPDATE data.work_logs
SET status = 'closed', check_out = coalesce(check_out, now())
WHERE worker_id = '20000000-0000-0000-0000-000000000004'
  AND status = 'open';

SET LOCAL ROLE authenticated;
SELECT pg_temp.set_owner_jwt();

-- Put Charlie on leave for flag-off test
DO $$
BEGIN
  PERFORM api.transition_employee_lifecycle(
    '40000000-0000-0000-0000-000000000002'::uuid,
    'on_leave', 'leave_started', CURRENT_DATE, '{}'::jsonb
  );
END $$;

SELECT pg_temp.set_charlie_jwt();

-- T6: flag OFF (default) → start succeeds despite on_leave
DO $$
DECLARE
  v_project uuid := '51000000-0000-0000-0000-000000000001';
  v_result jsonb;
BEGIN
  BEGIN
    v_result := api.start_work_log(
      gen_random_uuid(), v_project, NULL, now(), NULL, 'notrequired', 'es1_flag_off'
    );
    IF (v_result->>'status') IN ('created', 'duplicate') THEN
      INSERT INTO test_results VALUES ('T6 flag off ignores eligibility', 'PASS', v_result::text);
    ELSE
      INSERT INTO test_results VALUES ('T6 flag off ignores eligibility', 'FAIL', v_result::text);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO test_results VALUES ('T6 flag off ignores eligibility', 'FAIL', SQLERRM);
  END;
END $$;

RESET ROLE;

-- Enable gate for tenant
INSERT INTO data.tenant_feature_overrides (tenant_id, feature_key, override_status)
VALUES (
  '10000000-0000-0000-0000-000000000001',
  'employee_readiness_gate_enabled',
  true
)
ON CONFLICT (tenant_id, feature_key) DO UPDATE SET override_status = true;

UPDATE data.work_logs
SET status = 'closed', check_out = coalesce(check_out, now())
WHERE worker_id = '20000000-0000-0000-0000-000000000004'
  AND status = 'open';

SET LOCAL ROLE authenticated;
SELECT pg_temp.set_charlie_jwt();

-- T7: flag ON → blocked
DO $$
DECLARE
  v_project uuid := '51000000-0000-0000-0000-000000000001';
  v_ok boolean := false;
BEGIN
  BEGIN
    PERFORM api.start_work_log(
      gen_random_uuid(), v_project, NULL, now(), NULL, 'notrequired', 'es1_flag_on'
    );
  EXCEPTION WHEN check_violation THEN
    v_ok := true;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T7 flag on blocks not eligible', 'PASS', 'check_violation');
  ELSE
    INSERT INTO test_results VALUES ('T7 flag on blocks not eligible', 'FAIL', 'expected check_violation');
  END IF;
END $$;

-- Restore Charlie active
SELECT pg_temp.set_owner_jwt();
DO $$
BEGIN
  PERFORM api.transition_employee_lifecycle(
    '40000000-0000-0000-0000-000000000002'::uuid,
    'active', 'leave_ended', CURRENT_DATE, '{}'::jsonb
  );
END $$;

SELECT * FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_pass int;
  v_fail int;
BEGIN
  SELECT count(*) FILTER (WHERE status = 'PASS'), count(*) FILTER (WHERE status = 'FAIL')
  INTO v_pass, v_fail FROM test_results;
  RAISE NOTICE 'ES dispatch tests: % PASS, % FAIL', v_pass, v_fail;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'ES dispatch tests failed';
  END IF;
END $$;

ROLLBACK;
