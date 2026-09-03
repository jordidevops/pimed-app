-- EHR employee organization: job positions, tags, manager hierarchy
BEGIN;
SET client_min_messages TO WARNING;

CREATE TEMP TABLE test_results (
  test_name text PRIMARY KEY,
  status text NOT NULL,
  details text
) ON COMMIT DROP;

DO $$
DECLARE
  v_tenant   uuid := '10000000-0000-0000-0000-000000000001';
  v_tenant2  uuid := '10000000-0000-0000-0000-000000000002';
  v_alice    uuid := '40000000-0000-0000-0000-000000000001';
  v_bob      uuid := '40000000-0000-0000-0000-000000000002';
  v_other    uuid := '40000000-0000-0000-0000-000000000004';
  v_tag_id   uuid;
  v_ok       boolean;
  v_report_count int;
BEGIN
  -- T1: job_positions + employee_tags tables exist
  IF to_regclass('data.job_positions') IS NOT NULL
     AND to_regclass('data.employee_tags') IS NOT NULL THEN
    INSERT INTO test_results VALUES ('T1 job_positions + employee_tags', 'PASS', 'tables exist');
  ELSE
    INSERT INTO test_results VALUES ('T1 job_positions + employee_tags', 'FAIL', 'missing tables');
  END IF;

  -- T2: employees.job_position_id + manager_employee_id
  IF (
    SELECT count(*) FROM information_schema.columns
    WHERE table_schema = 'data' AND table_name = 'employees'
      AND column_name IN ('job_position_id', 'manager_employee_id')
  ) = 2 THEN
    INSERT INTO test_results VALUES ('T2 employees org columns', 'PASS', '2 cols');
  ELSE
    INSERT INTO test_results VALUES ('T2 employees org columns', 'FAIL', 'missing cols');
  END IF;

  -- T3: departments.manager_employee_id
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'data' AND table_name = 'departments'
      AND column_name = 'manager_employee_id'
  ) THEN
    INSERT INTO test_results VALUES ('T3 departments.manager_employee_id', 'PASS', 'ok');
  ELSE
    INSERT INTO test_results VALUES ('T3 departments.manager_employee_id', 'FAIL', 'missing');
  END IF;

  -- T4: unique tag name per tenant
  INSERT INTO data.employee_tags (tenant_id, name)
  VALUES (v_tenant, 'OrgTestTag')
  RETURNING id INTO v_tag_id;

  v_ok := false;
  BEGIN
    INSERT INTO data.employee_tags (tenant_id, name)
    VALUES (v_tenant, 'orgtesttag');
  EXCEPTION WHEN unique_violation THEN
    v_ok := true;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T4 unique tag name per tenant', 'PASS', 'unique_violation');
  ELSE
    INSERT INTO test_results VALUES ('T4 unique tag name per tenant', 'FAIL', 'duplicate allowed');
  END IF;

  DELETE FROM data.employee_tags WHERE id = v_tag_id;

  -- Clear any prior manager links for Alice/Bob
  UPDATE data.employees SET manager_employee_id = NULL
  WHERE id IN (v_alice, v_bob) AND tenant_id = v_tenant;

  -- T5: self-manager rejected
  v_ok := false;
  BEGIN
    UPDATE data.employees
    SET manager_employee_id = v_alice
    WHERE id = v_alice AND tenant_id = v_tenant;
  EXCEPTION
    WHEN check_violation THEN
      v_ok := true;
    WHEN OTHERS THEN
      IF SQLERRM ILIKE '%manager_self_reference%' THEN
        v_ok := true;
      ELSE
        RAISE;
      END IF;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T5 self-manager rejected', 'PASS', 'rejected');
  ELSE
    INSERT INTO test_results VALUES ('T5 self-manager rejected', 'FAIL', 'accepted');
  END IF;

  UPDATE data.employees SET manager_employee_id = NULL
  WHERE id IN (v_alice, v_bob) AND tenant_id = v_tenant;

  -- T6: cycle A→B→A rejected
  UPDATE data.employees
  SET manager_employee_id = v_bob
  WHERE id = v_alice AND tenant_id = v_tenant;

  v_ok := false;
  BEGIN
    UPDATE data.employees
    SET manager_employee_id = v_alice
    WHERE id = v_bob AND tenant_id = v_tenant;
  EXCEPTION
    WHEN check_violation THEN
      v_ok := true;
    WHEN OTHERS THEN
      IF SQLERRM ILIKE '%manager_cycle_detected%' THEN
        v_ok := true;
      ELSE
        RAISE;
      END IF;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T6 cycle A->B->A rejected', 'PASS', 'rejected');
  ELSE
    INSERT INTO test_results VALUES ('T6 cycle A->B->A rejected', 'FAIL', 'cycle allowed');
  END IF;

  UPDATE data.employees SET manager_employee_id = NULL
  WHERE id IN (v_alice, v_bob) AND tenant_id = v_tenant;

  -- T7: cross-tenant manager rejected (other emp on tenant 2)
  IF EXISTS (SELECT 1 FROM data.employees WHERE id = v_other AND tenant_id = v_tenant2) THEN
    v_ok := false;
    BEGIN
      UPDATE data.employees
      SET manager_employee_id = v_other
      WHERE id = v_alice AND tenant_id = v_tenant;
    EXCEPTION
      WHEN foreign_key_violation THEN
        v_ok := true;
      WHEN OTHERS THEN
        IF SQLERRM ILIKE '%manager_tenant_mismatch%' THEN
          v_ok := true;
        ELSE
          RAISE;
        END IF;
    END;

    IF v_ok THEN
      INSERT INTO test_results VALUES ('T7 cross-tenant manager rejected', 'PASS', 'rejected');
    ELSE
      INSERT INTO test_results VALUES ('T7 cross-tenant manager rejected', 'FAIL', 'accepted');
    END IF;

    UPDATE data.employees SET manager_employee_id = NULL
    WHERE id = v_alice AND tenant_id = v_tenant;
  ELSE
    INSERT INTO test_results VALUES (
      'T7 cross-tenant manager rejected',
      'PASS',
      'SKIP: no cross-tenant seed employee'
    );
  END IF;

  -- JWT as Alice owner (same as employees_profile_v2_tests.sql)
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  -- T8: Alice→Bob manager; direct reports returns Alice under Bob
  UPDATE data.employees
  SET manager_employee_id = v_bob
  WHERE id = v_alice AND tenant_id = v_tenant;

  SELECT count(*) INTO v_report_count
  FROM api.get_employee_direct_reports(v_bob)
  WHERE id = v_alice;

  IF v_report_count = 1
     AND (SELECT manager_employee_id FROM data.employees WHERE id = v_alice) = v_bob THEN
    INSERT INTO test_results VALUES ('T8 Alice reports to Bob', 'PASS', 'direct_reports ok');
  ELSE
    INSERT INTO test_results VALUES (
      'T8 Alice reports to Bob',
      'FAIL',
      format('reports=%s mgr=%s', v_report_count,
        (SELECT manager_employee_id::text FROM data.employees WHERE id = v_alice))
    );
  END IF;

  -- T9: clear managers after tests
  UPDATE data.employees SET manager_employee_id = NULL
  WHERE id IN (v_alice, v_bob) AND tenant_id = v_tenant;

  IF NOT EXISTS (
    SELECT 1 FROM data.employees
    WHERE id IN (v_alice, v_bob) AND tenant_id = v_tenant
      AND manager_employee_id IS NOT NULL
  ) THEN
    INSERT INTO test_results VALUES ('T9 clear managers', 'PASS', 'cleared');
  ELSE
    INSERT INTO test_results VALUES ('T9 clear managers', 'FAIL', 'still set');
  END IF;
END $$;

SELECT * FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  RAISE NOTICE 'EHR org tests: % PASS, % FAIL',
    (SELECT count(*) FROM test_results WHERE status = 'PASS'),
    v_fail;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EHR organization tests failed';
  END IF;
END $$;

ROLLBACK;
