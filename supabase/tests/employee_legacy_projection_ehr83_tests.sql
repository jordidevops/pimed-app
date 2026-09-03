-- =============================================================================
-- EHR-8.3 — legacy projection lock tests
-- =============================================================================

BEGIN;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

GRANT ALL ON TABLE test_results TO authenticated;

CREATE TEMP TABLE test_ids (
  emp_locked uuid,
  emp_free uuid,
  contract_id uuid
) ON COMMIT DROP;

GRANT ALL ON TABLE test_ids TO authenticated;
INSERT INTO test_ids DEFAULT VALUES;

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

RESET ROLE;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_site uuid := '30000000-0000-0000-0000-000000000001';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_locked uuid;
  v_free uuid;
  v_c uuid;
BEGIN
  DELETE FROM data.employment_contracts
  WHERE employee_id IN (
    SELECT id FROM data.employees WHERE full_name LIKE 'EHR83 %'
  );
  DELETE FROM data.employees WHERE tenant_id = v_tenant AND full_name LIKE 'EHR83 %';

  INSERT INTO data.employees (tenant_id, full_name, status, site_id, weekly_hours, starts_on)
  VALUES (v_tenant, 'EHR83 Locked', 'active', v_site, 40, CURRENT_DATE - 30)
  RETURNING id INTO v_locked;

  INSERT INTO data.employees (tenant_id, full_name, status, site_id, weekly_hours, starts_on)
  VALUES (v_tenant, 'EHR83 Free', 'active', v_site, 20, CURRENT_DATE - 10)
  RETURNING id INTO v_free;

  INSERT INTO data.employment_contracts (
    tenant_id, employee_id, is_primary, lifecycle_status, approval_status,
    signature_requirement, signature_status, starts_on, ends_on,
    weekly_hours, site_id, created_by, source
  ) VALUES (
    v_tenant, v_locked, true, 'active', 'approved',
    'none', 'not_required', CURRENT_DATE - 30, NULL,
    40, v_site, v_owner, 'manual'
  )
  RETURNING id INTO v_c;

  UPDATE test_ids SET emp_locked = v_locked, emp_free = v_free, contract_id = v_c;
END $$;

SET LOCAL ROLE authenticated;
SELECT pg_temp.set_owner_jwt();

-- T1: manual weekly_hours change blocked when effective contract
DO $$
DECLARE
  v_emp uuid;
  v_ok boolean := false;
BEGIN
  SELECT emp_locked INTO v_emp FROM test_ids;
  BEGIN
    UPDATE api.employees SET weekly_hours = 10 WHERE id = v_emp;
  EXCEPTION
    WHEN check_violation THEN
      IF SQLERRM LIKE '%legacy_terms_locked%' THEN
        v_ok := true;
      END IF;
    WHEN OTHERS THEN
      IF SQLERRM LIKE '%legacy_terms_locked%' THEN
        v_ok := true;
      END IF;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T1 lock weekly_hours', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T1 lock weekly_hours', 'FAIL', 'expected legacy_terms_locked');
  END IF;
END $$;

-- T2: free employee (no contract) can edit
DO $$
DECLARE
  v_emp uuid;
  v_hours numeric;
BEGIN
  SELECT emp_free INTO v_emp FROM test_ids;
  UPDATE api.employees SET weekly_hours = 25 WHERE id = v_emp;
  SELECT weekly_hours INTO v_hours FROM data.employees WHERE id = v_emp;
  IF v_hours = 25 THEN
    INSERT INTO test_results VALUES ('T2 free employee editable', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T2 free employee editable', 'FAIL', v_hours::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 free employee editable', 'FAIL', SQLERRM);
END $$;

-- T3: same-value UPDATE (no change) allowed even with contract
DO $$
DECLARE
  v_emp uuid;
BEGIN
  SELECT emp_locked INTO v_emp FROM test_ids;
  UPDATE api.employees SET weekly_hours = weekly_hours WHERE id = v_emp;
  INSERT INTO test_results VALUES ('T3 noop update allowed', 'PASS', NULL);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 noop update allowed', 'FAIL', SQLERRM);
END $$;

-- T4: EC-6 projection bypass works (postgres; function not granted to authenticated)
RESET ROLE;
DO $$
DECLARE
  v_c uuid;
  v_emp uuid;
  v_hours numeric;
BEGIN
  SELECT contract_id, emp_locked INTO v_c, v_emp FROM test_ids;
  UPDATE data.employment_contracts SET weekly_hours = 37.5 WHERE id = v_c;
  PERFORM data.project_employment_contract_onto_employee(v_c);
  SELECT weekly_hours INTO v_hours FROM data.employees WHERE id = v_emp;
  IF v_hours = 37.5 THEN
    INSERT INTO test_results VALUES ('T4 projection bypass', 'PASS', v_hours::text);
  ELSE
    INSERT INTO test_results VALUES ('T4 projection bypass', 'FAIL', v_hours::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T4 projection bypass', 'FAIL', SQLERRM);
END $$;

SET LOCAL ROLE authenticated;
SELECT pg_temp.set_owner_jwt();

-- T5: helper detects covering contract
DO $$
DECLARE
  v_emp uuid;
  v_free uuid;
BEGIN
  SELECT emp_locked, emp_free INTO v_emp, v_free FROM test_ids;
  IF data.employee_has_primary_contract_covering(v_emp, CURRENT_DATE)
     AND NOT data.employee_has_primary_contract_covering(v_free, CURRENT_DATE) THEN
    INSERT INTO test_results VALUES ('T5 covering helper', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T5 covering helper', 'FAIL', NULL);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 covering helper', 'FAIL', SQLERRM);
END $$;

RESET ROLE;
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
BEGIN
  DELETE FROM data.employment_contracts
  WHERE employee_id IN (
    SELECT id FROM data.employees WHERE full_name LIKE 'EHR83 %'
  );
  DELETE FROM data.employees WHERE tenant_id = v_tenant AND full_name LIKE 'EHR83 %';
END $$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EHR-8.3 tests failed: %', v_fail;
  END IF;
END $$;

ROLLBACK;
