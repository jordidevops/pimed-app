-- =============================================================================
-- ES-2b scheduled lifecycle reconciler tests
-- =============================================================================
BEGIN;
SET client_min_messages TO WARNING;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text PRIMARY KEY,
  status text NOT NULL,
  details text
) ON COMMIT DROP;

CREATE TEMP TABLE test_ids (
  employee_id uuid,
  scheduled_event_id uuid,
  effective_on date
) ON COMMIT DROP;

INSERT INTO test_ids DEFAULT VALUES;

RESET ROLE;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_site uuid := '30000000-0000-0000-0000-000000000001';
  v_emp uuid;
BEGIN
  DELETE FROM data.employee_lifecycle_events
  WHERE employee_id IN (
    SELECT id FROM data.employees WHERE full_name = 'ES2b Sched Emp'
  );
  DELETE FROM data.employees WHERE tenant_id = v_tenant AND full_name = 'ES2b Sched Emp';

  INSERT INTO data.employees (
    tenant_id, full_name, status, weekly_hours, site_id, lifecycle_state
  ) VALUES (
    v_tenant, 'ES2b Sched Emp', 'active', 40, v_site, 'active'
  )
  RETURNING id INTO v_emp;

  -- Allow write for seed lifecycle_state if trigger blocks — set via flag
  PERFORM set_config('data.lifecycle_state_write', '1', true);
  UPDATE data.employees SET lifecycle_state = 'active' WHERE id = v_emp;

  UPDATE test_ids SET employee_id = v_emp, effective_on = CURRENT_DATE + 7;
END $$;

SET LOCAL ROLE authenticated;
DO $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
END $$;

-- T1: schedule future departure — state unchanged
DO $$
DECLARE
  v_emp uuid;
  v_on date;
  v_ev api.employee_lifecycle_events;
  v_state text;
BEGIN
  SELECT employee_id, effective_on INTO v_emp, v_on FROM test_ids;
  v_ev := api.transition_employee_lifecycle(
    v_emp, 'departure', 'resignation', v_on, '{}'::jsonb
  );

  SELECT lifecycle_state INTO v_state FROM data.employees WHERE id = v_emp;

  IF v_ev.effective_on = v_on
     AND (v_ev.metadata->>'scheduled') = 'true'
     AND v_state = 'active' THEN
    UPDATE test_ids SET scheduled_event_id = v_ev.id;
    INSERT INTO test_results VALUES ('T1 schedule future no mutate', 'PASS', v_ev.id::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T1 schedule future no mutate',
      'FAIL',
      format('state=%s meta=%s', v_state, v_ev.metadata)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T1 schedule future no mutate', 'FAIL', SQLERRM);
END $$;

-- T2: reconcile before date — still active, applied=0
DO $$
DECLARE
  v_emp uuid;
  v_res jsonb;
  v_state text;
BEGIN
  SELECT employee_id INTO v_emp FROM test_ids;
  v_res := api.run_reconcile_scheduled_lifecycle_events(CURRENT_DATE);
  SELECT lifecycle_state INTO v_state FROM data.employees WHERE id = v_emp;

  IF v_state = 'active'
     AND coalesce((v_res->>'applied')::int, -1) = 0 THEN
    INSERT INTO test_results VALUES ('T2 reconcile early noop', 'PASS', v_res::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T2 reconcile early noop',
      'FAIL',
      format('state=%s res=%s', v_state, v_res)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 reconcile early noop', 'FAIL', SQLERRM);
END $$;

-- T3: reconcile on effective_on — applies
DO $$
DECLARE
  v_emp uuid;
  v_on date;
  v_res jsonb;
  v_state text;
  v_sched uuid;
  v_derived int;
BEGIN
  SELECT employee_id, effective_on, scheduled_event_id
  INTO v_emp, v_on, v_sched FROM test_ids;

  v_res := api.run_reconcile_scheduled_lifecycle_events(v_on);
  SELECT lifecycle_state INTO v_state FROM data.employees WHERE id = v_emp;

  SELECT count(*) INTO v_derived
  FROM data.employee_lifecycle_events
  WHERE reason_code = 'scheduled_transition_applied'
    AND metadata->>'scheduled_event_id' = v_sched::text;

  IF v_state = 'departure'
     AND coalesce((v_res->>'applied')::int, 0) = 1
     AND v_derived = 1 THEN
    INSERT INTO test_results VALUES ('T3 apply on date', 'PASS', v_res::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T3 apply on date',
      'FAIL',
      format('state=%s derived=%s res=%s', v_state, v_derived, v_res)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 apply on date', 'FAIL', SQLERRM);
END $$;

-- T4: idempotent re-run
DO $$
DECLARE
  v_on date;
  v_sched uuid;
  v_res jsonb;
  v_derived int;
BEGIN
  SELECT effective_on, scheduled_event_id INTO v_on, v_sched FROM test_ids;
  v_res := api.run_reconcile_scheduled_lifecycle_events(v_on);

  SELECT count(*) INTO v_derived
  FROM data.employee_lifecycle_events
  WHERE reason_code = 'scheduled_transition_applied'
    AND metadata->>'scheduled_event_id' = v_sched::text;

  IF coalesce((v_res->>'applied')::int, -1) = 0 AND v_derived = 1 THEN
    INSERT INTO test_results VALUES ('T4 idempotent', 'PASS', v_res::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T4 idempotent',
      'FAIL',
      format('derived=%s res=%s', v_derived, v_res)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T4 idempotent', 'FAIL', SQLERRM);
END $$;

-- T5: state mismatch skip
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_site uuid := '30000000-0000-0000-0000-000000000001';
  v_emp uuid;
  v_on date := CURRENT_DATE + 3;
  v_ev api.employee_lifecycle_events;
  v_res jsonb;
  v_state text;
BEGIN
  RESET ROLE;
  PERFORM set_config('data.lifecycle_state_write', '1', true);
  INSERT INTO data.employees (
    tenant_id, full_name, status, weekly_hours, site_id, lifecycle_state
  ) VALUES (
    v_tenant, 'ES2b Mismatch Emp', 'active', 40, v_site, 'active'
  )
  RETURNING id INTO v_emp;

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  v_ev := api.transition_employee_lifecycle(v_emp, 'on_leave', 'leave_started', v_on, '{}'::jsonb);

  -- Divert state before reconcile
  PERFORM api.transition_employee_lifecycle(
    v_emp, 'departure', 'resignation', CURRENT_DATE, '{}'::jsonb
  );

  v_res := api.run_reconcile_scheduled_lifecycle_events(v_on);
  SELECT lifecycle_state INTO v_state FROM data.employees WHERE id = v_emp;

  IF v_state = 'departure'
     AND coalesce((v_res->>'skipped_state_mismatch')::int, 0) >= 1
     AND coalesce((v_res->>'applied')::int, -1) = 0 THEN
    INSERT INTO test_results VALUES ('T5 state mismatch skip', 'PASS', v_res::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T5 state mismatch skip',
      'FAIL',
      format('state=%s res=%s', v_state, v_res)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 state mismatch skip', 'FAIL', SQLERRM);
END $$;

-- T6: today effective still applies immediately
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_site uuid := '30000000-0000-0000-0000-000000000001';
  v_emp uuid;
  v_state text;
BEGIN
  RESET ROLE;
  PERFORM set_config('data.lifecycle_state_write', '1', true);
  INSERT INTO data.employees (
    tenant_id, full_name, status, weekly_hours, site_id, lifecycle_state
  ) VALUES (
    v_tenant, 'ES2b Today Emp', 'active', 40, v_site, 'onboarding'
  )
  RETURNING id INTO v_emp;

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  PERFORM api.transition_employee_lifecycle(
    v_emp, 'active', 'onboarding_completed', CURRENT_DATE, '{}'::jsonb
  );
  SELECT lifecycle_state INTO v_state FROM data.employees WHERE id = v_emp;

  IF v_state = 'active' THEN
    INSERT INTO test_results VALUES ('T6 today applies now', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T6 today applies now', 'FAIL', v_state);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 today applies now', 'FAIL', SQLERRM);
END $$;

-- T7: Dave denied reconcile
DO $$
DECLARE
  v_ok boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000005', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000005","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  BEGIN
    PERFORM api.run_reconcile_scheduled_lifecycle_events(CURRENT_DATE);
  EXCEPTION WHEN insufficient_privilege THEN
    v_ok := true;
  WHEN OTHERS THEN
    IF SQLERRM ILIKE '%insufficient_privilege%' THEN
      v_ok := true;
    END IF;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T7 dave denied', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T7 dave denied', 'FAIL', 'expected deny');
  END IF;
END $$;

DO $$
DECLARE
  v_fail int;
  r record;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  RAISE WARNING '=== ES-2b scheduled reconcile ===';
  FOR r IN SELECT test_name, status, details FROM test_results ORDER BY test_name LOOP
    RAISE WARNING '%: % — %', r.test_name, r.status, coalesce(r.details, '');
  END LOOP;
  IF v_fail > 0 THEN
    RAISE EXCEPTION '% failed tests', v_fail;
  END IF;
END $$;

ROLLBACK;
