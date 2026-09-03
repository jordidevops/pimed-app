-- =============================================================================
-- CR-4 compliance dashboard tests
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
  site_id uuid,
  type_id uuid,
  cert_active uuid,
  cert_expired uuid
) ON COMMIT DROP;

INSERT INTO test_ids DEFAULT VALUES;

RESET ROLE;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_site uuid := '30000000-0000-0000-0000-000000000001';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_emp uuid;
  v_type uuid;
  v_a uuid;
  v_e uuid;
BEGIN
  DELETE FROM data.employee_certifications
  WHERE employee_id IN (
    SELECT id FROM data.employees WHERE full_name = 'CR4 Dash Emp'
  );
  DELETE FROM data.employees WHERE tenant_id = v_tenant AND full_name = 'CR4 Dash Emp';
  DELETE FROM data.compliance_requirement_types
  WHERE tenant_id = v_tenant AND code = 'CR4_DASH';

  INSERT INTO data.employees (tenant_id, full_name, status, weekly_hours, site_id)
  VALUES (v_tenant, 'CR4 Dash Emp', 'active', 40, v_site)
  RETURNING id INTO v_emp;

  INSERT INTO data.compliance_requirement_types (
    tenant_id, code, name, category, is_active
  ) VALUES (
    v_tenant, 'CR4_DASH', 'CR4 Dashboard Req', 'legal', true
  )
  RETURNING id INTO v_type;

  INSERT INTO data.employee_certifications (
    tenant_id, employee_id, requirement_type_id,
    valid_from, valid_until, created_by
  ) VALUES (
    v_tenant, v_emp, v_type,
    CURRENT_DATE - 10, CURRENT_DATE + 60, v_owner
  )
  RETURNING id INTO v_a;

  INSERT INTO data.employee_certifications (
    tenant_id, employee_id, requirement_type_id,
    valid_from, valid_until, created_by
  ) VALUES (
    v_tenant, v_emp, v_type,
    CURRENT_DATE - 100, CURRENT_DATE - 5, v_owner
  )
  RETURNING id INTO v_e;

  PERFORM data.refresh_employee_readiness_projection(v_emp);

  UPDATE test_ids SET
    employee_id = v_emp,
    site_id = v_site,
    type_id = v_type,
    cert_active = v_a,
    cert_expired = v_e;
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

-- T1: filter computed_status = expired
DO $$
DECLARE
  v_n int;
  v_emp uuid;
BEGIN
  SELECT employee_id INTO v_emp FROM test_ids;
  SELECT count(*) INTO v_n
  FROM api.list_tenant_certifications('expired', NULL, NULL, false, 200, 0)
  WHERE employee_id = v_emp;

  IF v_n = 1 THEN
    INSERT INTO test_results VALUES ('T1 filter expired', 'PASS', v_n::text);
  ELSE
    INSERT INTO test_results VALUES ('T1 filter expired', 'FAIL', v_n::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T1 filter expired', 'FAIL', SQLERRM);
END $$;

-- T2: filter by site
DO $$
DECLARE
  v_n int;
  v_site uuid;
  v_emp uuid;
BEGIN
  SELECT site_id, employee_id INTO v_site, v_emp FROM test_ids;
  SELECT count(*) INTO v_n
  FROM api.list_tenant_certifications(NULL, v_site, NULL, false, 200, 0)
  WHERE employee_id = v_emp;

  IF v_n >= 2 THEN
    INSERT INTO test_results VALUES ('T2 filter site', 'PASS', v_n::text);
  ELSE
    INSERT INTO test_results VALUES ('T2 filter site', 'FAIL', v_n::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 filter site', 'FAIL', SQLERRM);
END $$;

-- T3: filter active excludes expired
DO $$
DECLARE
  v_n_exp int;
  v_emp uuid;
BEGIN
  SELECT employee_id INTO v_emp FROM test_ids;
  SELECT count(*) INTO v_n_exp
  FROM api.list_tenant_certifications('active', NULL, NULL, false, 200, 0)
  WHERE employee_id = v_emp
    AND computed_status = 'expired';

  IF v_n_exp = 0 THEN
    INSERT INTO test_results VALUES ('T3 active excludes expired', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T3 active excludes expired', 'FAIL', v_n_exp::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 active excludes expired', 'FAIL', SQLERRM);
END $$;

-- T4: summary O(1) shape + optional site filter
DO $$
DECLARE
  v_sum jsonb;
  v_site uuid;
BEGIN
  SELECT site_id INTO v_site FROM test_ids;
  v_sum := api.get_employee_readiness_projection_summary(CURRENT_DATE, v_site, NULL);

  IF v_sum ? 'ready_pct'
     AND v_sum ? 'total_employees'
     AND v_sum ? 'ready'
     AND v_sum ? 'not_ready'
     AND (v_sum->>'site_id')::uuid = v_site THEN
    INSERT INTO test_results VALUES ('T4 summary filtered', 'PASS', v_sum::text);
  ELSE
    INSERT INTO test_results VALUES ('T4 summary filtered', 'FAIL', v_sum::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T4 summary filtered', 'FAIL', SQLERRM);
END $$;

-- T5: list projection (single query)
DO $$
DECLARE
  v_n int;
  v_emp uuid;
BEGIN
  SELECT employee_id INTO v_emp FROM test_ids;
  -- Ensure projection exists
  PERFORM api.run_refresh_employee_readiness_projection(v_emp);

  SELECT count(*) INTO v_n
  FROM api.list_employee_readiness_projection(NULL, NULL, NULL, 100, 0)
  WHERE employee_id = v_emp;

  IF v_n = 1 THEN
    INSERT INTO test_results VALUES ('T5 list projection', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T5 list projection', 'FAIL', v_n::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 list projection', 'FAIL', SQLERRM);
END $$;

-- T6: wrong site → empty for our employee
DO $$
DECLARE
  v_n int;
  v_emp uuid;
  v_other uuid := '30000000-0000-0000-0000-000000000099';
BEGIN
  SELECT employee_id INTO v_emp FROM test_ids;
  SELECT count(*) INTO v_n
  FROM api.list_tenant_certifications(NULL, v_other, NULL, false, 200, 0)
  WHERE employee_id = v_emp;

  IF v_n = 0 THEN
    INSERT INTO test_results VALUES ('T6 wrong site empty', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T6 wrong site empty', 'FAIL', v_n::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 wrong site empty', 'FAIL', SQLERRM);
END $$;

-- T7: Dave denied list projection
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
    PERFORM count(*) FROM api.list_employee_readiness_projection(false, NULL, NULL, 10, 0);
  EXCEPTION WHEN insufficient_privilege THEN
    v_ok := true;
  WHEN OTHERS THEN
    IF SQLERRM ILIKE '%insufficient_privilege%' THEN
      v_ok := true;
    END IF;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T7 dave denied projection list', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T7 dave denied projection list', 'FAIL', 'expected deny');
  END IF;
END $$;

-- T8: summary amb només p_as_of (defaults site/dept)
DO $$
DECLARE
  v_sum jsonb;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  v_sum := api.get_employee_readiness_projection_summary(CURRENT_DATE, NULL, NULL);
  IF v_sum ? 'ready_pct' AND v_sum ? 'total_employees' THEN
    INSERT INTO test_results VALUES ('T8 summary defaults', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T8 summary defaults', 'FAIL', v_sum::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T8 summary defaults', 'FAIL', SQLERRM);
END $$;

DO $$
DECLARE
  v_fail int;
  r record;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  RAISE WARNING '=== CR-4 dashboard results ===';
  FOR r IN SELECT test_name, status, details FROM test_results ORDER BY test_name LOOP
    RAISE WARNING '%: % — %', r.test_name, r.status, coalesce(r.details, '');
  END LOOP;
  IF v_fail > 0 THEN
    RAISE EXCEPTION '% failed tests', v_fail;
  END IF;
END $$;

ROLLBACK;
