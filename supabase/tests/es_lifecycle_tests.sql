-- =============================================================================
-- ES-0 Lifecycle tests
-- =============================================================================

BEGIN;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

-- T1: cap empleat sense lifecycle_state
DO $$
DECLARE v_missing int;
BEGIN
  SELECT count(*) INTO v_missing FROM data.employees WHERE lifecycle_state IS NULL;
  IF v_missing = 0 THEN
    INSERT INTO test_results VALUES ('T1 all employees have lifecycle_state', 'PASS', 'count=0');
  ELSE
    INSERT INTO test_results VALUES ('T1 all employees have lifecycle_state', 'FAIL', format('missing=%s', v_missing));
  END IF;
END $$;

-- T2: terminated status -> terminated lifecycle
DO $$
DECLARE v_bad int;
BEGIN
  SELECT count(*) INTO v_bad
  FROM data.employees
  WHERE status = 'terminated' AND lifecycle_state <> 'terminated';
  IF v_bad = 0 THEN
    INSERT INTO test_results VALUES ('T2 terminated status maps to lifecycle', 'PASS', 'ok');
  ELSE
    INSERT INTO test_results VALUES ('T2 terminated status maps to lifecycle', 'FAIL', format('bad=%s', v_bad));
  END IF;
END $$;

-- T3: no candidate transitions seeded
DO $$
DECLARE v_count int;
BEGIN
  SELECT count(*) INTO v_count
  FROM data.employee_lifecycle_transition_rules
  WHERE from_state = 'candidate' OR to_state = 'candidate';
  IF v_count = 0 THEN
    INSERT INTO test_results VALUES ('T3 no candidate transitions', 'PASS', 'count=0');
  ELSE
    INSERT INTO test_results VALUES ('T3 no candidate transitions', 'FAIL', format('count=%s', v_count));
  END IF;
END $$;

-- T4: authenticated cannot UPDATE lifecycle_state directly
DO $$
DECLARE v_denied boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  BEGIN
    UPDATE data.employees e
    SET lifecycle_state = 'on_leave'
    FROM (
      SELECT id FROM data.employees
      WHERE tenant_id = '10000000-0000-0000-0000-000000000001'::uuid
        AND status <> 'terminated'
      LIMIT 1
    ) pick
    WHERE e.id = pick.id;
  EXCEPTION WHEN check_violation THEN
    v_denied := true;
  END;

  IF v_denied THEN
    INSERT INTO test_results VALUES ('T4 direct lifecycle_state update blocked', 'PASS', 'check_violation');
  ELSE
    INSERT INTO test_results VALUES ('T4 direct lifecycle_state update blocked', 'FAIL', 'update succeeded');
  END IF;
END $$;

-- T5: backfill events exist (idempotent baseline)
DO $$
DECLARE v_employees int;
DECLARE v_events int;
BEGIN
  SELECT count(*) INTO v_employees FROM data.employees;
  SELECT count(DISTINCT employee_id) INTO v_events FROM data.employee_lifecycle_events;
  IF v_events >= v_employees THEN
    INSERT INTO test_results VALUES ('T5 lifecycle events backfilled', 'PASS', format('employees=%s events=%s', v_employees, v_events));
  ELSE
    INSERT INTO test_results VALUES ('T5 lifecycle events backfilled', 'FAIL', format('employees=%s distinct_events=%s', v_employees, v_events));
  END IF;
END $$;

-- T6: api.employees exposes lifecycle_state
DO $$
DECLARE v_has boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'api' AND table_name = 'employees' AND column_name = 'lifecycle_state'
  ) INTO v_has;
  IF v_has THEN
    INSERT INTO test_results VALUES ('T6 api.employees exposes lifecycle_state', 'PASS', 'column exists');
  ELSE
    INSERT INTO test_results VALUES ('T6 api.employees exposes lifecycle_state', 'FAIL', 'missing column');
  END IF;
END $$;

DO $$
DECLARE v_pass int; v_fail int;
BEGIN
  SELECT count(*) FILTER (WHERE status = 'PASS'), count(*) FILTER (WHERE status = 'FAIL')
  INTO v_pass, v_fail FROM test_results;
  RAISE NOTICE 'ES lifecycle tests: % PASS, % FAIL', v_pass, v_fail;
END $$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN RAISE EXCEPTION 'ES lifecycle tests failed: % failure(s)', v_fail; END IF;
END $$;

ROLLBACK;
