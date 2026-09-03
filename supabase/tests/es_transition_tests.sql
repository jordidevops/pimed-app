-- =============================================================================
-- ES-2 transition_employee_lifecycle tests
-- =============================================================================

BEGIN;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

-- T1: valid transition active -> on_leave
DO $$
DECLARE
  v_emp_id uuid;
  v_event_id uuid;
  v_state text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  -- Pick an active employee and ensure lifecycle is active via event if needed
  SELECT id INTO v_emp_id FROM data.employees
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'::uuid
    AND lifecycle_state = 'active'
    AND status <> 'terminated'
  LIMIT 1;

  SELECT (api.transition_employee_lifecycle(
    v_emp_id, 'on_leave', 'leave_started', CURRENT_DATE, '{}'::jsonb
  )).id INTO v_event_id;

  SELECT lifecycle_state INTO v_state FROM data.employees WHERE id = v_emp_id;

  IF v_event_id IS NOT NULL AND v_state = 'on_leave' THEN
    INSERT INTO test_results VALUES ('T1 valid transition to on_leave', 'PASS', format('emp=%s', v_emp_id));
  ELSE
    INSERT INTO test_results VALUES ('T1 valid transition to on_leave', 'FAIL', format('event=%s state=%s', v_event_id, v_state));
  END IF;

  -- restore to active for cleanliness within transaction
  PERFORM api.transition_employee_lifecycle(v_emp_id, 'active', 'leave_ended', CURRENT_DATE, '{}'::jsonb);
END $$;

-- T2: invalid transition rejected
DO $$
DECLARE
  v_emp_id uuid;
  v_ok boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT id INTO v_emp_id FROM data.employees
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'::uuid
    AND lifecycle_state = 'active'
  LIMIT 1;

  BEGIN
    PERFORM api.transition_employee_lifecycle(
      v_emp_id, 'terminated', 'skip', CURRENT_DATE, '{}'::jsonb
    );
  EXCEPTION WHEN check_violation THEN
    v_ok := true;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T2 invalid transition rejected', 'PASS', 'check_violation');
  ELSE
    INSERT INTO test_results VALUES ('T2 invalid transition rejected', 'FAIL', 'expected check_violation');
  END IF;
END $$;

-- T3: future effective_on rejected
DO $$
DECLARE
  v_emp_id uuid;
  v_ok boolean := false;
  v_sqlstate text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT id INTO v_emp_id FROM data.employees
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'::uuid
    AND lifecycle_state = 'active'
  LIMIT 1;

  BEGIN
    PERFORM api.transition_employee_lifecycle(
      v_emp_id, 'on_leave', 'leave_started', CURRENT_DATE + 7, '{}'::jsonb
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    IF v_sqlstate = '0A000' OR SQLERRM LIKE '%future_effective_on_not_supported%' THEN
      v_ok := true;
    END IF;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T3 future effective_on rejected', 'PASS', 'future_effective_on_not_supported');
  ELSE
    INSERT INTO test_results VALUES ('T3 future effective_on rejected', 'FAIL', COALESCE(v_sqlstate, 'no error'));
  END IF;
END $$;

-- T4: member cannot transition
DO $$
DECLARE
  v_emp_id uuid;
  v_ok boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000005', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000005","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT id INTO v_emp_id FROM data.employees
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'::uuid
    AND lifecycle_state = 'active'
  LIMIT 1;

  BEGIN
    PERFORM api.transition_employee_lifecycle(
      v_emp_id, 'on_leave', 'leave_started', CURRENT_DATE, '{}'::jsonb
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_ok := true;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T4 member cannot transition', 'PASS', 'insufficient_privilege');
  ELSE
    INSERT INTO test_results VALUES ('T4 member cannot transition', 'FAIL', 'expected insufficient_privilege');
  END IF;
END $$;

-- T5: reason_code required
DO $$
DECLARE
  v_emp_id uuid;
  v_ok boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT id INTO v_emp_id FROM data.employees
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'::uuid
    AND lifecycle_state = 'active'
  LIMIT 1;

  BEGIN
    PERFORM api.transition_employee_lifecycle(
      v_emp_id, 'on_leave', NULL, CURRENT_DATE, '{}'::jsonb
    );
  EXCEPTION WHEN invalid_parameter_value THEN
    v_ok := true;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T5 reason_code required', 'PASS', 'invalid_parameter_value');
  ELSE
    INSERT INTO test_results VALUES ('T5 reason_code required', 'FAIL', 'expected invalid_parameter_value');
  END IF;
END $$;

SELECT * FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_pass int;
  v_fail int;
BEGIN
  SELECT count(*) FILTER (WHERE status = 'PASS'), count(*) FILTER (WHERE status = 'FAIL')
  INTO v_pass, v_fail FROM test_results;
  RAISE NOTICE 'ES transition tests: % PASS, % FAIL', v_pass, v_fail;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'ES transition tests failed';
  END IF;
END $$;

ROLLBACK;
