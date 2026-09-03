-- M-EA-1 employee asset assignments tests
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
  asset_a uuid,
  asset_b uuid,
  assignment_id uuid
) ON COMMIT DROP;

INSERT INTO test_ids DEFAULT VALUES;

RESET ROLE;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_site uuid := '30000000-0000-0000-0000-000000000001';
  v_emp uuid;
  v_a uuid;
  v_b uuid;
BEGIN
  DELETE FROM data.employee_asset_assignments
  WHERE asset_id IN (
    SELECT id FROM data.assets WHERE asset_tag LIKE 'EA1-%'
  );
  DELETE FROM data.assets WHERE tenant_id = v_tenant AND asset_tag LIKE 'EA1-%';
  DELETE FROM data.employees WHERE tenant_id = v_tenant AND full_name = 'EA1 Assign Emp';

  INSERT INTO data.employees (tenant_id, full_name, status, weekly_hours, site_id)
  VALUES (v_tenant, 'EA1 Assign Emp', 'active', 40, v_site)
  RETURNING id INTO v_emp;

  INSERT INTO data.assets (tenant_id, site_id, name, asset_tag, status)
  VALUES (v_tenant, v_site, 'EA1 Casc A', 'EA1-A', 'operational')
  RETURNING id INTO v_a;

  INSERT INTO data.assets (tenant_id, site_id, name, asset_tag, status)
  VALUES (v_tenant, v_site, 'EA1 Casc B', 'EA1-B', 'operational')
  RETURNING id INTO v_b;

  UPDATE test_ids SET employee_id = v_emp, asset_a = v_a, asset_b = v_b;
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

-- T1: assign
DO $$
DECLARE
  v_emp uuid;
  v_asset uuid;
  v_out api.employee_asset_assignments;
BEGIN
  SELECT employee_id, asset_a INTO v_emp, v_asset FROM test_ids;
  v_out := api.assign_employee_asset(v_asset, v_emp, NULL, NULL, 'first');

  IF v_out.employee_id = v_emp
     AND v_out.asset_id = v_asset
     AND v_out.returned_at IS NULL THEN
    UPDATE test_ids SET assignment_id = v_out.id;
    INSERT INTO test_results VALUES ('T1 assign open', 'PASS', v_out.id::text);
  ELSE
    INSERT INTO test_results VALUES ('T1 assign open', 'FAIL', coalesce(v_out::text, 'null'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T1 assign open', 'FAIL', SQLERRM);
END $$;

-- T2: double assign rejected
DO $$
DECLARE
  v_emp uuid;
  v_asset uuid;
  v_ok boolean := false;
BEGIN
  SELECT employee_id, asset_a INTO v_emp, v_asset FROM test_ids;
  BEGIN
    PERFORM api.assign_employee_asset(v_asset, v_emp);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%asset_already_assigned%' THEN
      v_ok := true;
    END IF;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T2 double assign blocked', 'PASS', 'ok');
  ELSE
    INSERT INTO test_results VALUES ('T2 double assign blocked', 'FAIL', 'accepted');
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 double assign blocked', 'FAIL', SQLERRM);
END $$;

-- T3: return good + reassign creates new row
DO $$
DECLARE
  v_emp uuid;
  v_asset uuid;
  v_first uuid;
  v_ret api.employee_asset_assignments;
  v_second api.employee_asset_assignments;
  v_cnt int;
BEGIN
  SELECT employee_id, asset_a, assignment_id INTO v_emp, v_asset, v_first FROM test_ids;
  v_ret := api.return_employee_asset(v_asset, 'good', NULL, 'ok');
  v_second := api.assign_employee_asset(v_asset, v_emp);

  SELECT count(*) INTO v_cnt
  FROM data.employee_asset_assignments
  WHERE asset_id = v_asset;

  IF v_ret.returned_at IS NOT NULL
     AND v_ret.return_condition = 'good'
     AND v_second.id IS DISTINCT FROM v_first
     AND v_second.returned_at IS NULL
     AND v_cnt = 2 THEN
    INSERT INTO test_results VALUES ('T3 return then reassign', 'PASS', format('cnt=%s', v_cnt));
  ELSE
    INSERT INTO test_results VALUES (
      'T3 return then reassign',
      'FAIL',
      format('ret=%s second=%s cnt=%s', v_ret.id, v_second.id, v_cnt)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 return then reassign', 'FAIL', SQLERRM);
END $$;

-- T4: closed row immutable (trigger; run as table owner to bypass RLS)
RESET ROLE;
DO $$
DECLARE
  v_closed uuid;
  v_ok boolean := false;
BEGIN
  SELECT id INTO v_closed
  FROM data.employee_asset_assignments
  WHERE asset_id = (SELECT asset_a FROM test_ids) AND returned_at IS NOT NULL
  LIMIT 1;

  BEGIN
    UPDATE data.employee_asset_assignments SET notes = 'hack' WHERE id = v_closed;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%closed_immutable%' OR SQLERRM ILIKE '%forbidden%' THEN
      v_ok := true;
    END IF;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T4 closed immutable', 'PASS', 'ok');
  ELSE
    INSERT INTO test_results VALUES ('T4 closed immutable', 'FAIL', 'mutated');
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T4 closed immutable', 'FAIL', SQLERRM);
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

-- T5: lost retires asset
DO $$
DECLARE
  v_emp uuid;
  v_asset uuid;
  v_st text;
BEGIN
  SELECT employee_id, asset_b INTO v_emp, v_asset FROM test_ids;
  PERFORM api.assign_employee_asset(v_asset, v_emp);
  PERFORM api.return_employee_asset(v_asset, 'lost', NULL, 'lost item');

  SELECT status INTO v_st FROM data.assets WHERE id = v_asset;
  IF v_st = 'retired' THEN
    INSERT INTO test_results VALUES ('T5 lost retires asset', 'PASS', v_st);
  ELSE
    INSERT INTO test_results VALUES ('T5 lost retires asset', 'FAIL', coalesce(v_st, 'null'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 lost retires asset', 'FAIL', SQLERRM);
END $$;

-- T6: list assignments
DO $$
DECLARE
  v_emp uuid;
  v_n int;
BEGIN
  SELECT employee_id INTO v_emp FROM test_ids;
  SELECT count(*) INTO v_n FROM api.list_employee_asset_assignments(v_emp, true);
  IF v_n >= 2 THEN
    INSERT INTO test_results VALUES ('T6 list assignments', 'PASS', format('n=%s', v_n));
  ELSE
    INSERT INTO test_results VALUES ('T6 list assignments', 'FAIL', format('n=%s', v_n));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 list assignments', 'FAIL', SQLERRM);
END $$;

-- T7: multi-tenant assign blocked
RESET ROLE;
DO $$
DECLARE
  v_other_tenant uuid;
  v_other_emp uuid;
  v_asset uuid;
  v_ok boolean := false;
BEGIN
  SELECT id INTO v_other_tenant FROM data.tenants
  WHERE id <> '10000000-0000-0000-0000-000000000001'
  LIMIT 1;

  IF v_other_tenant IS NULL THEN
    INSERT INTO test_results VALUES ('T7 cross-tenant blocked', 'PASS', 'no_other_tenant_skip');
    RETURN;
  END IF;

  SELECT asset_a INTO v_asset FROM test_ids;

  INSERT INTO data.employees (tenant_id, full_name, status)
  VALUES (v_other_tenant, 'EA1 Other Tenant Emp', 'active')
  RETURNING id INTO v_other_emp;

  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('role', 'authenticated', true);

  BEGIN
    PERFORM api.assign_employee_asset(v_asset, v_other_emp);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%employee_not_found%' OR SQLSTATE = 'P0002' THEN
      v_ok := true;
    END IF;
  END;

  DELETE FROM data.employees WHERE id = v_other_emp;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T7 cross-tenant blocked', 'PASS', 'ok');
  ELSE
    INSERT INTO test_results VALUES ('T7 cross-tenant blocked', 'FAIL', 'accepted');
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T7 cross-tenant blocked', 'FAIL', SQLERRM);
  DELETE FROM data.employees WHERE full_name = 'EA1 Other Tenant Emp';
END $$;

-- Cleanup
RESET ROLE;
DO $$
DECLARE
  v_emp uuid;
BEGIN
  SELECT employee_id INTO v_emp FROM test_ids;
  -- disable trigger for cleanup delete
  ALTER TABLE data.employee_asset_assignments DISABLE TRIGGER trg_employee_asset_assignment_append_only;
  DELETE FROM data.employee_asset_assignments WHERE employee_id = v_emp;
  ALTER TABLE data.employee_asset_assignments ENABLE TRIGGER trg_employee_asset_assignment_append_only;
  DELETE FROM data.assets WHERE asset_tag LIKE 'EA1-%';
  DELETE FROM data.employees WHERE id = v_emp;
  INSERT INTO test_results VALUES ('T8 cleanup', 'PASS', 'ok');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T8 cleanup', 'FAIL', SQLERRM);
  ALTER TABLE data.employee_asset_assignments ENABLE TRIGGER trg_employee_asset_assignment_append_only;
END $$;

SELECT * FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  RAISE NOTICE 'M-EA-1 employee asset assignments: % PASS, % FAIL',
    (SELECT count(*) FROM test_results WHERE status = 'PASS'),
    v_fail;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'M-EA-1 employee asset assignments tests failed';
  END IF;
END $$;

ROLLBACK;
