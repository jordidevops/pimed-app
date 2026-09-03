-- M-EC-07 employment contracts backfill tests
BEGIN;
SET client_min_messages TO WARNING;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text PRIMARY KEY,
  status text NOT NULL,
  details text
) ON COMMIT DROP;

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

-- Ensure clean slate for Acme legacy backfill rows from prior failed runs
RESET ROLE;
DELETE FROM data.employment_contracts
WHERE tenant_id = '10000000-0000-0000-0000-000000000001'
  AND source = 'legacy_backfill';

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

-- T1: preflight
DO $$
DECLARE
  v_rep jsonb;
  v_total int;
  v_needs int;
BEGIN
  v_rep := api.preflight_employment_contracts_backfill(NULL);
  v_total := (v_rep ->> 'total_employees')::int;
  v_needs := (v_rep ->> 'needs_contract')::int;

  IF v_total > 0 AND v_needs > 0 AND (v_rep ->> 'already_have_contract')::int >= 0 THEN
    INSERT INTO test_results VALUES (
      'T1 preflight counts',
      'PASS',
      format('total=%s needs=%s', v_total, v_needs)
    );
  ELSE
    INSERT INTO test_results VALUES ('T1 preflight counts', 'FAIL', coalesce(v_rep::text, 'null'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T1 preflight counts', 'FAIL', SQLERRM);
END $$;

-- T2: dry-run does not insert
DO $$
DECLARE
  v_before int;
  v_after int;
  v_res jsonb;
BEGIN
  SELECT count(*) INTO v_before
  FROM data.employment_contracts
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'
    AND source = 'legacy_backfill';

  v_res := api.backfill_employment_contracts(NULL, true, NULL);

  SELECT count(*) INTO v_after
  FROM data.employment_contracts
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'
    AND source = 'legacy_backfill';

  IF v_before = v_after AND (v_res ->> 'dry_run')::boolean = true AND (v_res ->> 'created')::int > 0 THEN
    INSERT INTO test_results VALUES (
      'T2 dry-run no insert',
      'PASS',
      format('would_create=%s', v_res ->> 'created')
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T2 dry-run no insert',
      'FAIL',
      format('before=%s after=%s res=%s', v_before, v_after, v_res)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 dry-run no insert', 'FAIL', SQLERRM);
END $$;

-- T3: real backfill creates Alice active (+ bulk for all without contract)
DO $$
DECLARE
  v_res jsonb;
  v_alice uuid := '40000000-0000-0000-0000-000000000001';
  v_st text;
  v_src text;
  v_hours numeric;
  v_created int;
  v_conflicts int;
BEGIN
  v_res := api.backfill_employment_contracts(NULL, false, NULL);
  v_created := (v_res ->> 'created')::int;
  v_conflicts := (v_res ->> 'skipped_conflict')::int;

  SELECT lifecycle_status, source, weekly_hours
  INTO v_st, v_src, v_hours
  FROM data.employment_contracts
  WHERE employee_id = v_alice
    AND is_primary
    AND lifecycle_status IN ('scheduled', 'active', 'ended')
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_created >= 50
     AND v_conflicts = 0
     AND v_src = 'legacy_backfill'
     AND v_st = 'active'
     AND v_hours = 40 THEN
    INSERT INTO test_results VALUES (
      'T3 backfill Alice active',
      'PASS',
      format('created=%s status=%s', v_created, v_st)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T3 backfill Alice active',
      'FAIL',
      format('res=%s st=%s src=%s hours=%s', v_res, v_st, v_src, v_hours)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 backfill Alice active', 'FAIL', SQLERRM);
END $$;

-- T4: idempotent
DO $$
DECLARE
  v_res jsonb;
  v_skipped int;
BEGIN
  v_res := api.backfill_employment_contracts(NULL, false, NULL);
  v_skipped := (v_res ->> 'skipped_existing')::int;
  IF (v_res ->> 'created')::int = 0 AND v_skipped >= 50 THEN
    INSERT INTO test_results VALUES (
      'T4 idempotent re-run',
      'PASS',
      format('skipped=%s', v_skipped)
    );
  ELSE
    INSERT INTO test_results VALUES ('T4 idempotent re-run', 'FAIL', coalesce(v_res::text, 'null'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T4 idempotent re-run', 'FAIL', SQLERRM);
END $$;

-- T5: terms from contract after backfill
DO $$
DECLARE
  v_alice uuid := '40000000-0000-0000-0000-000000000001';
  v_terms jsonb;
BEGIN
  v_terms := api.resolve_employee_contract_terms(v_alice, CURRENT_DATE);
  IF v_terms ->> 'source' = 'employment_contract' THEN
    INSERT INTO test_results VALUES ('T5 terms employment_contract', 'PASS', v_terms ->> 'source');
  ELSE
    INSERT INTO test_results VALUES ('T5 terms employment_contract', 'FAIL', coalesce(v_terms::text, 'null'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 terms employment_contract', 'FAIL', SQLERRM);
END $$;

-- T6: conflict employee skipped
RESET ROLE;
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_emp uuid;
  v_res jsonb;
  v_cnt int;
BEGIN
  INSERT INTO data.employees (
    id, tenant_id, full_name, status, starts_on, ends_on, weekly_hours
  ) VALUES (
    gen_random_uuid(), v_tenant, 'EC7 Conflict Emp', 'active',
    CURRENT_DATE, CURRENT_DATE - 10, 40
  ) RETURNING id INTO v_emp;

  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('role', 'authenticated', true);

  -- Call as SECURITY DEFINER still works with JWT claims
  v_res := api.backfill_employment_contracts(v_tenant, false, v_emp);

  SELECT count(*) INTO v_cnt
  FROM data.employment_contracts
  WHERE employee_id = v_emp;

  IF v_cnt = 0 AND (v_res ->> 'skipped_conflict')::int >= 1 THEN
    INSERT INTO test_results VALUES ('T6 conflict skipped', 'PASS', v_res::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T6 conflict skipped',
      'FAIL',
      format('cnt=%s res=%s', v_cnt, v_res)
    );
  END IF;

  DELETE FROM data.employees WHERE id = v_emp;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 conflict skipped', 'FAIL', SQLERRM);
  DELETE FROM data.employees WHERE full_name = 'EC7 Conflict Emp';
END $$;

-- Cleanup backfill rows (keep DB clean for other suites)
RESET ROLE;
DO $$
DECLARE
  v_deleted int;
BEGIN
  DELETE FROM data.employment_contracts
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'
    AND source = 'legacy_backfill';
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  INSERT INTO test_results VALUES ('T7 cleanup legacy_backfill', 'PASS', format('deleted=%s', v_deleted));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T7 cleanup legacy_backfill', 'FAIL', SQLERRM);
END $$;

SELECT * FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  RAISE NOTICE 'M-EC-07 employment contracts backfill: % PASS, % FAIL',
    (SELECT count(*) FROM test_results WHERE status = 'PASS'),
    v_fail;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'M-EC-07 employment contracts backfill tests failed';
  END IF;
END $$;

ROLLBACK;
