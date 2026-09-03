-- =============================================================================
-- EHR-8 — HR reporting summary tests
-- =============================================================================

BEGIN;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

GRANT ALL ON TABLE test_results TO authenticated;

CREATE TEMP TABLE test_ids (
  emp_a uuid,
  emp_b uuid,
  emp_legacy uuid,
  site_a uuid,
  site_b uuid,
  dept_id uuid,
  pos_id uuid
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

CREATE OR REPLACE FUNCTION pg_temp.set_site_mgr_jwt() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000004', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000004","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{"30000000-0000-0000-0000-000000000001":"manager"}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{"30000000-0000-0000-0000-000000000001":["employees.directory.view","employees.view"]}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.set_member_no_scope() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000099', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000099","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
END;
$$;

RESET ROLE;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_site_a uuid := '30000000-0000-0000-0000-000000000001';
  v_site_b uuid;
  v_dept uuid;
  v_pos uuid;
  v_a uuid;
  v_b uuid;
  v_leg uuid;
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
BEGIN
  DELETE FROM data.employment_contracts
  WHERE employee_id IN (
    SELECT id FROM data.employees WHERE full_name LIKE 'EHR8 %'
  );
  DELETE FROM data.employees WHERE tenant_id = v_tenant AND full_name LIKE 'EHR8 %';
  DELETE FROM data.job_positions WHERE tenant_id = v_tenant AND code = 'EHR8-POS';
  DELETE FROM data.departments WHERE tenant_id = v_tenant AND name = 'EHR8 Dept';
  DELETE FROM data.sites WHERE tenant_id = v_tenant AND name = 'EHR8 Site B';

  INSERT INTO data.sites (tenant_id, name)
  VALUES (v_tenant, 'EHR8 Site B')
  RETURNING id INTO v_site_b;

  INSERT INTO data.departments (tenant_id, name)
  VALUES (v_tenant, 'EHR8 Dept')
  RETURNING id INTO v_dept;

  INSERT INTO data.job_positions (tenant_id, code, name, is_active)
  VALUES (v_tenant, 'EHR8-POS', 'EHR8 Position', true)
  RETURNING id INTO v_pos;

  INSERT INTO data.employees (
    tenant_id, full_name, status, site_id, department_id, job_position_id, email, weekly_hours
  ) VALUES (
    v_tenant, 'EHR8 Emp A', 'active', v_site_a, v_dept, v_pos, 'ehr8a@example.com', 40
  )
  RETURNING id INTO v_a;

  INSERT INTO data.employees (
    tenant_id, full_name, status, site_id, department_id, job_position_id, email, weekly_hours
  ) VALUES (
    v_tenant, 'EHR8 Emp B', 'active', v_site_b, v_dept, v_pos, 'ehr8b@example.com', 40
  )
  RETURNING id INTO v_b;

  INSERT INTO data.employees (
    tenant_id, full_name, status, site_id, department_id, email, weekly_hours
  ) VALUES (
    v_tenant, 'EHR8 Legacy', 'active', v_site_a, v_dept, NULL, 40
  )
  RETURNING id INTO v_leg;

  INSERT INTO data.employment_contracts (
    tenant_id, employee_id, is_primary, lifecycle_status, approval_status,
    signature_requirement, signature_status, starts_on, ends_on,
    weekly_hours, site_id, department_id, job_position_id, created_by, source
  ) VALUES
  (
    v_tenant, v_a, true, 'active', 'approved',
    'none', 'not_required', CURRENT_DATE - 60, CURRENT_DATE + 30,
    40, v_site_a, v_dept, v_pos, v_owner, 'manual'
  ),
  (
    v_tenant, v_b, true, 'active', 'approved',
    'none', 'not_required', CURRENT_DATE - 10, NULL,
    40, v_site_b, v_dept, v_pos, v_owner, 'manual'
  );

  UPDATE test_ids SET
    emp_a = v_a,
    emp_b = v_b,
    emp_legacy = v_leg,
    site_a = v_site_a,
    site_b = v_site_b,
    dept_id = v_dept,
    pos_id = v_pos;
END $$;

SET LOCAL ROLE authenticated;
SELECT pg_temp.set_owner_jwt();

-- T1: headcount effective includes A+B, legacy gap for Legacy
DO $$
DECLARE
  v_rep jsonb;
  v_eff int;
  v_leg int;
  v_a uuid;
  v_b uuid;
BEGIN
  SELECT emp_a, emp_b INTO v_a, v_b FROM test_ids;
  v_rep := api.get_hr_reporting_summary(CURRENT_DATE, 30, NULL, NULL);
  v_eff := (v_rep -> 'headcount' ->> 'effective')::int;
  v_leg := (v_rep -> 'headcount' ->> 'legacy_without_contract')::int;

  IF v_eff >= 2 AND v_leg >= 1 THEN
    INSERT INTO test_results VALUES (
      'T1 headcount effective+legacy', 'PASS',
      format('eff=%s leg=%s', v_eff, v_leg)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T1 headcount effective+legacy', 'FAIL',
      format('eff=%s leg=%s rep=%s', v_eff, v_leg, v_rep)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T1 headcount effective+legacy', 'FAIL', SQLERRM);
END $$;

-- T2: site filter only site A
DO $$
DECLARE
  v_rep jsonb;
  v_eff int;
  v_site uuid;
BEGIN
  SELECT site_a INTO v_site FROM test_ids;
  v_rep := api.get_hr_reporting_summary(CURRENT_DATE, 30, v_site, NULL);
  v_eff := (v_rep -> 'headcount' ->> 'effective')::int;

  IF v_eff >= 1 AND v_rep ->> 'site_id' = v_site::text THEN
    INSERT INTO test_results VALUES ('T2 filter site A', 'PASS', v_eff::text);
  ELSE
    INSERT INTO test_results VALUES ('T2 filter site A', 'FAIL', v_rep::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 filter site A', 'FAIL', SQLERRM);
END $$;

-- T3: hires count Emp B (started in last 30d)
DO $$
DECLARE
  v_rep jsonb;
  v_hires int;
BEGIN
  v_rep := api.get_hr_reporting_summary(CURRENT_DATE, 30, NULL, NULL);
  v_hires := (v_rep ->> 'hires')::int;
  IF v_hires >= 1 THEN
    INSERT INTO test_results VALUES ('T3 hires period', 'PASS', v_hires::text);
  ELSE
    INSERT INTO test_results VALUES ('T3 hires period', 'FAIL', v_rep::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 hires period', 'FAIL', SQLERRM);
END $$;

-- T4: contracts expiring 90d includes Emp A
DO $$
DECLARE
  v_rep jsonb;
  v_n int;
BEGIN
  v_rep := api.get_hr_reporting_summary(CURRENT_DATE, 30, NULL, NULL);
  v_n := (v_rep ->> 'contracts_expiring_90d')::int;
  IF v_n >= 1 THEN
    INSERT INTO test_results VALUES ('T4 contracts expiring', 'PASS', v_n::text);
  ELSE
    INSERT INTO test_results VALUES ('T4 contracts expiring', 'FAIL', v_rep::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T4 contracts expiring', 'FAIL', SQLERRM);
END $$;

-- T5: incomplete profiles (legacy missing email+position)
DO $$
DECLARE
  v_rep jsonb;
  v_n int;
BEGIN
  v_rep := api.get_hr_reporting_summary(CURRENT_DATE, 30, NULL, NULL);
  v_n := (v_rep ->> 'incomplete_profiles')::int;
  IF v_n >= 1 THEN
    INSERT INTO test_results VALUES ('T5 incomplete profiles', 'PASS', v_n::text);
  ELSE
    INSERT INTO test_results VALUES ('T5 incomplete profiles', 'FAIL', v_rep::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 incomplete profiles', 'FAIL', SQLERRM);
END $$;

-- T6: no private field keys in payload (exclude definitions prose)
DO $$
DECLARE
  v_rep jsonb;
  v_keys text;
BEGIN
  v_rep := api.get_hr_reporting_summary(CURRENT_DATE, 30, NULL, NULL);
  -- Flatten top-level + nested object keys only
  SELECT string_agg(k, ',')
  INTO v_keys
  FROM (
    SELECT jsonb_object_keys(v_rep) AS k
    UNION ALL
    SELECT jsonb_object_keys(v_rep -> 'headcount')
    UNION ALL
    SELECT jsonb_object_keys(coalesce(v_rep -> 'contracts_by_status', '{}'::jsonb))
  ) x;

  IF v_keys !~* 'salary|gross_amount|document_id|iban|nif|dni|ssn|annual_gross' THEN
    INSERT INTO test_results VALUES ('T6 no private fields', 'PASS', v_keys);
  ELSE
    INSERT INTO test_results VALUES ('T6 no private fields', 'FAIL', v_keys);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 no private fields', 'FAIL', SQLERRM);
END $$;

-- T7: site-scoped manager only sees site A (not B headcount for Emp B alone)
DO $$
DECLARE
  v_rep jsonb;
  v_eff int;
  v_sites jsonb;
  v_has_b boolean := false;
  v_site_b uuid;
  i int;
BEGIN
  SELECT site_b INTO v_site_b FROM test_ids;
  PERFORM pg_temp.set_site_mgr_jwt();
  v_rep := api.get_hr_reporting_summary(CURRENT_DATE, 30, NULL, NULL);
  v_eff := (v_rep -> 'headcount' ->> 'effective')::int;
  v_sites := v_rep -> 'by_site';

  FOR i IN 0 .. coalesce(jsonb_array_length(v_sites), 0) - 1 LOOP
    IF (v_sites -> i ->> 'site_id') = v_site_b::text THEN
      v_has_b := true;
    END IF;
  END LOOP;

  IF (v_rep ->> 'site_scoped')::boolean = true AND NOT v_has_b AND v_eff >= 1 THEN
    INSERT INTO test_results VALUES (
      'T7 site-scoped excludes B', 'PASS',
      format('eff=%s scoped=%s', v_eff, v_rep ->> 'site_scoped')
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T7 site-scoped excludes B', 'FAIL',
      format('eff=%s has_b=%s rep=%s', v_eff, v_has_b, v_rep)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T7 site-scoped excludes B', 'FAIL', SQLERRM);
END $$;

-- T8: member without scope denied
DO $$
DECLARE
  v_ok boolean := false;
BEGIN
  PERFORM pg_temp.set_member_no_scope();
  BEGIN
    PERFORM api.get_hr_reporting_summary(CURRENT_DATE, 30, NULL, NULL);
  EXCEPTION
    WHEN insufficient_privilege THEN
      v_ok := true;
    WHEN OTHERS THEN
      IF SQLSTATE = '42501' THEN
        v_ok := true;
      END IF;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T8 no scope denied', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T8 no scope denied', 'FAIL', 'expected privilege error');
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T8 no scope denied', 'FAIL', SQLERRM);
END $$;

-- Cleanup
RESET ROLE;
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
BEGIN
  DELETE FROM data.employment_contracts
  WHERE employee_id IN (
    SELECT id FROM data.employees WHERE full_name LIKE 'EHR8 %'
  );
  DELETE FROM data.employees WHERE tenant_id = v_tenant AND full_name LIKE 'EHR8 %';
  DELETE FROM data.job_positions WHERE tenant_id = v_tenant AND code = 'EHR8-POS';
  DELETE FROM data.departments WHERE tenant_id = v_tenant AND name = 'EHR8 Dept';
  DELETE FROM data.sites WHERE tenant_id = v_tenant AND name = 'EHR8 Site B';
END $$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EHR-8 tests failed: %', v_fail;
  END IF;
END $$;

ROLLBACK;
