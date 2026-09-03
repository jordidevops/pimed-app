-- M-EC-06 employment contract attendance driver tests
BEGIN;
SET client_min_messages TO WARNING;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text PRIMARY KEY,
  status text NOT NULL,
  details text
) ON COMMIT DROP;

CREATE TEMP TABLE test_ids (
  contract_id uuid,
  group_id uuid,
  alice_prev_hours numeric,
  alice_prev_group uuid
) ON COMMIT DROP;

INSERT INTO test_ids DEFAULT VALUES;

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

-- Setup group + snapshot Alice
RESET ROLE;
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_alice  uuid := '40000000-0000-0000-0000-000000000001';
  v_gid uuid;
  v_hours numeric;
  v_group uuid;
BEGIN
  INSERT INTO data.calendar_groups (tenant_id, site_id, name, color, is_active, sort_order)
  VALUES (v_tenant, NULL, 'EC6-TEST-GROUP', '#336699', true, 99)
  RETURNING id INTO v_gid;

  SELECT weekly_hours, calendar_group_id INTO v_hours, v_group
  FROM data.employees WHERE id = v_alice;

  UPDATE test_ids SET
    group_id = v_gid,
    alice_prev_hours = v_hours,
    alice_prev_group = v_group;

  -- Clear Alice driver fields so projection is visible
  UPDATE data.employees
  SET weekly_hours = 20, calendar_group_id = NULL
  WHERE id = v_alice;
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

-- T1: activate projects hours + calendar group
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_alice  uuid := '40000000-0000-0000-0000-000000000001';
  v_gid uuid;
  v_id uuid;
  v_hours numeric;
  v_group uuid;
BEGIN
  SELECT group_id INTO v_gid FROM test_ids;

  INSERT INTO api.employment_contracts (
    tenant_id, employee_id, contract_number, starts_on, weekly_hours, calendar_group_id,
    lifecycle_status, is_primary, signature_requirement, signature_status
  ) VALUES (
    v_tenant, v_alice, 'EC6-TEST-1', CURRENT_DATE, 37.5, v_gid,
    'draft', true, 'none', 'not_required'
  ) RETURNING id INTO v_id;

  UPDATE test_ids SET contract_id = v_id;

  PERFORM api.transition_employment_contract(v_id, 'active', NULL);

  SELECT weekly_hours, calendar_group_id INTO v_hours, v_group
  FROM data.employees WHERE id = v_alice;

  IF v_hours = 37.5 AND v_group = v_gid THEN
    INSERT INTO test_results VALUES ('T1 activate projects driver', 'PASS', format('hours=%s group=%s', v_hours, v_group));
  ELSE
    INSERT INTO test_results VALUES (
      'T1 activate projects driver',
      'FAIL',
      format('hours=%s group=%s expected=37.5/%s', v_hours, v_group, v_gid)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T1 activate projects driver', 'FAIL', SQLERRM);
END $$;

-- T2: null contract fields do not wipe employee
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_alice  uuid := '40000000-0000-0000-0000-000000000001';
  v_gid uuid;
  v_id uuid;
  v_hours numeric;
  v_group uuid;
BEGIN
  SELECT group_id INTO v_gid FROM test_ids;

  -- Cancel previous to free overlap EXCLUDE (ended still participates)
  UPDATE data.employment_contracts
  SET lifecycle_status = 'cancelled', cancelled_at = now(), cancellation_reason = 'ec6-test'
  WHERE id = (SELECT contract_id FROM test_ids);

  UPDATE data.employees SET weekly_hours = 32, calendar_group_id = v_gid WHERE id = v_alice;

  INSERT INTO api.employment_contracts (
    tenant_id, employee_id, contract_number, starts_on, weekly_hours, calendar_group_id,
    lifecycle_status, is_primary, signature_requirement, signature_status
  ) VALUES (
    v_tenant, v_alice, 'EC6-TEST-2', CURRENT_DATE, NULL, NULL,
    'draft', true, 'none', 'not_required'
  ) RETURNING id INTO v_id;

  PERFORM api.transition_employment_contract(v_id, 'active', NULL);

  SELECT weekly_hours, calendar_group_id INTO v_hours, v_group
  FROM data.employees WHERE id = v_alice;

  IF v_hours = 32 AND v_group = v_gid THEN
    INSERT INTO test_results VALUES ('T2 null fields keep employee', 'PASS', format('hours=%s', v_hours));
  ELSE
    INSERT INTO test_results VALUES (
      'T2 null fields keep employee',
      'FAIL',
      format('hours=%s group=%s', v_hours, v_group)
    );
  END IF;

  UPDATE data.employment_contracts
  SET lifecycle_status = 'cancelled', cancelled_at = now(), cancellation_reason = 'ec6-test'
  WHERE id = v_id;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 null fields keep employee', 'FAIL', SQLERRM);
END $$;

-- T3: reconcile scheduled→active also projects
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_alice  uuid := '40000000-0000-0000-0000-000000000001';
  v_gid uuid;
  v_id uuid;
  v_n int;
  v_hours numeric;
BEGIN
  SELECT group_id INTO v_gid FROM test_ids;
  UPDATE data.employees SET weekly_hours = 10 WHERE id = v_alice;

  -- Ensure no overlapping primary remains
  UPDATE data.employment_contracts
  SET lifecycle_status = 'cancelled', cancelled_at = now(), cancellation_reason = 'ec6-test'
  WHERE employee_id = v_alice AND contract_number LIKE 'EC6-TEST-%'
    AND lifecycle_status IN ('scheduled', 'active', 'ended');

  INSERT INTO api.employment_contracts (
    tenant_id, employee_id, contract_number, starts_on, weekly_hours, calendar_group_id,
    lifecycle_status, is_primary, signature_requirement, signature_status
  ) VALUES (
    v_tenant, v_alice, 'EC6-TEST-3', CURRENT_DATE, 40, v_gid,
    'scheduled', true, 'none', 'not_required'
  ) RETURNING id INTO v_id;

  v_n := api.reconcile_employment_contracts(v_alice, CURRENT_DATE);

  SELECT weekly_hours INTO v_hours FROM data.employees WHERE id = v_alice;

  IF v_n >= 1 AND v_hours = 40 THEN
    INSERT INTO test_results VALUES ('T3 reconcile projects', 'PASS', format('n=%s hours=%s', v_n, v_hours));
  ELSE
    INSERT INTO test_results VALUES (
      'T3 reconcile projects',
      'FAIL',
      format('n=%s hours=%s', v_n, v_hours)
    );
  END IF;

  UPDATE test_ids SET contract_id = v_id;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 reconcile projects', 'FAIL', SQLERRM);
END $$;

-- T4: resolve_employee_contract_terms from contract
DO $$
DECLARE
  v_alice uuid := '40000000-0000-0000-0000-000000000001';
  v_terms jsonb;
BEGIN
  v_terms := api.resolve_employee_contract_terms(v_alice, CURRENT_DATE);
  IF v_terms ->> 'source' = 'employment_contract'
     AND (v_terms ->> 'weekly_hours')::numeric = 40
     AND v_terms ? 'contract_id' THEN
    INSERT INTO test_results VALUES ('T4 terms from contract', 'PASS', v_terms ->> 'source');
  ELSE
    INSERT INTO test_results VALUES ('T4 terms from contract', 'FAIL', coalesce(v_terms::text, 'null'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T4 terms from contract', 'FAIL', SQLERRM);
END $$;

-- T5: fallback when no covering contract
DO $$
DECLARE
  v_alice uuid := '40000000-0000-0000-0000-000000000001';
  v_terms jsonb;
BEGIN
  UPDATE data.employment_contracts
  SET lifecycle_status = 'cancelled', cancelled_at = now(), cancellation_reason = 'ec6-test'
  WHERE contract_number LIKE 'EC6-TEST-%';

  UPDATE data.employees SET weekly_hours = 22 WHERE id = v_alice;

  v_terms := api.resolve_employee_contract_terms(v_alice, CURRENT_DATE - 200);
  IF v_terms ->> 'source' = 'employee_fallback'
     AND (v_terms ->> 'weekly_hours')::numeric = 22 THEN
    INSERT INTO test_results VALUES ('T5 terms employee fallback', 'PASS', v_terms ->> 'source');
  ELSE
    INSERT INTO test_results VALUES ('T5 terms employee fallback', 'FAIL', coalesce(v_terms::text, 'null'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 terms employee fallback', 'FAIL', SQLERRM);
END $$;

-- Cleanup + restore Alice
RESET ROLE;
DO $$
DECLARE
  v_alice uuid := '40000000-0000-0000-0000-000000000001';
  v_prev_h numeric;
  v_prev_g uuid;
  v_gid uuid;
BEGIN
  SELECT alice_prev_hours, alice_prev_group, group_id
  INTO v_prev_h, v_prev_g, v_gid
  FROM test_ids;

  DELETE FROM data.employment_contracts WHERE contract_number LIKE 'EC6-TEST-%';
  DELETE FROM data.calendar_groups WHERE id = v_gid OR name = 'EC6-TEST-GROUP';

  UPDATE data.employees
  SET weekly_hours = v_prev_h, calendar_group_id = v_prev_g
  WHERE id = v_alice;

  INSERT INTO test_results VALUES ('T6 cleanup restore', 'PASS', 'ok');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 cleanup restore', 'FAIL', SQLERRM);
END $$;

SELECT * FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  RAISE NOTICE 'M-EC-06 attendance driver: % PASS, % FAIL',
    (SELECT count(*) FROM test_results WHERE status = 'PASS'),
    v_fail;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'M-EC-06 attendance driver tests failed';
  END IF;
END $$;

ROLLBACK;
