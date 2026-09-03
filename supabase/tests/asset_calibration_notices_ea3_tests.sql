-- M-EA-03 asset calibration notices tests
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
  asset_30 uuid,
  asset_7 uuid,
  asset_45 uuid
) ON COMMIT DROP;

INSERT INTO test_ids DEFAULT VALUES;

RESET ROLE;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_site uuid := '30000000-0000-0000-0000-000000000001';
  v_emp uuid;
  v_a30 uuid;
  v_a7 uuid;
  v_a45 uuid;
  v_as_of date := CURRENT_DATE;
BEGIN
  DELETE FROM data.asset_calibration_notice_log
  WHERE asset_id IN (SELECT id FROM data.assets WHERE asset_tag LIKE 'EA3-%');
  DELETE FROM data.employee_asset_assignments
  WHERE asset_id IN (SELECT id FROM data.assets WHERE asset_tag LIKE 'EA3-%');
  DELETE FROM data.assets WHERE tenant_id = v_tenant AND asset_tag LIKE 'EA3-%';
  DELETE FROM data.employees WHERE tenant_id = v_tenant AND full_name = 'EA3 Calib Emp';

  INSERT INTO data.employees (tenant_id, full_name, status, weekly_hours, site_id)
  VALUES (v_tenant, 'EA3 Calib Emp', 'active', 40, v_site)
  RETURNING id INTO v_emp;

  INSERT INTO data.assets (
    tenant_id, site_id, name, asset_tag, status,
    requires_calibration, calibration_due_on
  ) VALUES
    (v_tenant, v_site, 'EA3 Gauge 30', 'EA3-30', 'operational', true, v_as_of + 30)
  RETURNING id INTO v_a30;

  INSERT INTO data.assets (
    tenant_id, site_id, name, asset_tag, status,
    requires_calibration, calibration_due_on
  ) VALUES
    (v_tenant, v_site, 'EA3 Gauge 7', 'EA3-7', 'operational', true, v_as_of + 7)
  RETURNING id INTO v_a7;

  INSERT INTO data.assets (
    tenant_id, site_id, name, asset_tag, status,
    requires_calibration, calibration_due_on
  ) VALUES
    (v_tenant, v_site, 'EA3 Gauge 45', 'EA3-45', 'operational', true, v_as_of + 45)
  RETURNING id INTO v_a45;

  UPDATE test_ids SET
    employee_id = v_emp,
    asset_30 = v_a30,
    asset_7 = v_a7,
    asset_45 = v_a45;
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

-- T1: emit at 30 days
DO $$
DECLARE
  v_asset uuid;
  v_result jsonb;
  v_count int;
BEGIN
  SELECT asset_30 INTO v_asset FROM test_ids;
  v_result := api.run_emit_asset_calibration_notices(CURRENT_DATE);

  SELECT count(*) INTO v_count
  FROM data.asset_calibration_notice_log
  WHERE asset_id = v_asset AND notice_days = 30;

  IF (v_result->>'emitted')::int >= 1 AND v_count = 1 THEN
    INSERT INTO test_results VALUES ('T1 emit 30-day notice', 'PASS', v_result::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T1 emit 30-day notice', 'FAIL',
      format('result=%s count=%s', v_result, v_count)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T1 emit 30-day notice', 'FAIL', SQLERRM);
END $$;

-- T2: re-run dedupe
DO $$
DECLARE
  v_asset uuid;
  v_before int;
  v_after int;
  v_result jsonb;
BEGIN
  SELECT asset_30 INTO v_asset FROM test_ids;
  SELECT count(*) INTO v_before
  FROM data.asset_calibration_notice_log WHERE asset_id = v_asset;

  v_result := api.run_emit_asset_calibration_notices(CURRENT_DATE);

  SELECT count(*) INTO v_after
  FROM data.asset_calibration_notice_log WHERE asset_id = v_asset;

  IF v_before = v_after AND (v_result->>'skipped_duplicates')::int >= 1 THEN
    INSERT INTO test_results VALUES ('T2 re-run no duplicates', 'PASS', v_result::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T2 re-run no duplicates', 'FAIL',
      format('before=%s after=%s result=%s', v_before, v_after, v_result)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 re-run no duplicates', 'FAIL', SQLERRM);
END $$;

-- T3: audit event
DO $$
DECLARE
  v_asset uuid;
  v_count int;
BEGIN
  SELECT asset_30 INTO v_asset FROM test_ids;
  SELECT count(*) INTO v_count
  FROM data.audit_logs
  WHERE action = 'ASSET_CALIBRATION_EXPIRING'
    AND entity_id = v_asset;

  IF v_count >= 1 THEN
    INSERT INTO test_results VALUES ('T3 audit ASSET_CALIBRATION_EXPIRING', 'PASS', format('count=%s', v_count));
  ELSE
    INSERT INTO test_results VALUES ('T3 audit ASSET_CALIBRATION_EXPIRING', 'FAIL', 'no audit row');
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 audit ASSET_CALIBRATION_EXPIRING', 'FAIL', SQLERRM);
END $$;

-- T4: emit at 7 days
DO $$
DECLARE
  v_asset uuid;
  v_result jsonb;
  v_count int;
BEGIN
  SELECT asset_7 INTO v_asset FROM test_ids;
  v_result := api.run_emit_asset_calibration_notices(CURRENT_DATE);

  SELECT count(*) INTO v_count
  FROM data.asset_calibration_notice_log
  WHERE asset_id = v_asset AND notice_days = 7;

  IF v_count = 1 THEN
    INSERT INTO test_results VALUES ('T4 emit 7-day notice', 'PASS', v_result::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T4 emit 7-day notice', 'FAIL',
      format('count=%s result=%s', v_count, v_result)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T4 emit 7-day notice', 'FAIL', SQLERRM);
END $$;

-- T5: non-threshold day (45) does not emit
DO $$
DECLARE
  v_asset uuid;
  v_count int;
BEGIN
  SELECT asset_45 INTO v_asset FROM test_ids;
  PERFORM api.run_emit_asset_calibration_notices(CURRENT_DATE);

  SELECT count(*) INTO v_count
  FROM data.asset_calibration_notice_log WHERE asset_id = v_asset;

  IF v_count = 0 THEN
    INSERT INTO test_results VALUES ('T5 no emit on day 45', 'PASS', 'ok');
  ELSE
    INSERT INTO test_results VALUES ('T5 no emit on day 45', 'FAIL', format('count=%s', v_count));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 no emit on day 45', 'FAIL', SQLERRM);
END $$;

-- T6: list alerts for assigned employee includes 30-day asset
DO $$
DECLARE
  v_emp uuid;
  v_asset uuid;
  v_asn api.employee_asset_assignments;
  v_rep jsonb;
  v_found boolean := false;
  v_el jsonb;
BEGIN
  SELECT employee_id, asset_30 INTO v_emp, v_asset FROM test_ids;
  v_asn := api.assign_employee_asset(v_asset, v_emp);
  v_rep := api.list_asset_calibration_alerts(v_emp, CURRENT_DATE, 30);

  FOR v_el IN SELECT * FROM jsonb_array_elements(coalesce(v_rep->'alerts', '[]'::jsonb))
  LOOP
    IF (v_el->>'asset_id')::uuid = v_asset THEN
      v_found := true;
      EXIT;
    END IF;
  END LOOP;

  IF v_found AND (v_rep->>'count')::int >= 1 THEN
    INSERT INTO test_results VALUES ('T6 list alerts for employee', 'PASS', v_rep::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T6 list alerts for employee', 'FAIL',
      format('found=%s rep=%s asn=%s', v_found, v_rep, v_asn.id)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 list alerts for employee', 'FAIL', SQLERRM);
END $$;

-- T7: Dave (member) denied list
DO $$
DECLARE
  v_emp uuid;
BEGIN
  SELECT employee_id INTO v_emp FROM test_ids;

  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000005', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000005","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  BEGIN
    PERFORM api.list_asset_calibration_alerts(v_emp, CURRENT_DATE, 30);
    INSERT INTO test_results VALUES ('T7 privilege denied', 'FAIL', 'expected insufficient_privilege');
  EXCEPTION
    WHEN insufficient_privilege THEN
      INSERT INTO test_results VALUES ('T7 privilege denied', 'PASS', SQLERRM);
    WHEN OTHERS THEN
      IF SQLSTATE IN ('42501', 'P0001') OR SQLERRM ILIKE '%privilege%' THEN
        INSERT INTO test_results VALUES ('T7 privilege denied', 'PASS', SQLERRM);
      ELSE
        INSERT INTO test_results VALUES ('T7 privilege denied', 'FAIL', SQLERRM);
      END IF;
  END;
END $$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EA-3 tests failed: %', v_fail;
  END IF;
END $$;

ROLLBACK;
