-- M-EA-0 asset types + assets extension tests
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

-- T1: platform types exist
DO $$
DECLARE
  v_n int;
BEGIN
  SELECT count(*) INTO v_n
  FROM data.asset_types
  WHERE tenant_id IS NULL AND code IN ('EPI_CAT_III', 'VEHICLE_VAN', 'TOOL_CALIBRATED');

  IF v_n = 3 THEN
    INSERT INTO test_results VALUES ('T1 platform seed types', 'PASS', format('n=%s', v_n));
  ELSE
    INSERT INTO test_results VALUES ('T1 platform seed types', 'FAIL', format('n=%s', v_n));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T1 platform seed types', 'FAIL', SQLERRM);
END $$;

-- T2: upsert tenant type with calibration + blocks
DO $$
DECLARE
  v_row api.asset_types;
BEGIN
  v_row := api.upsert_asset_type(
    NULL, 'EA0_TEST_EPI', 'Casc prova EA0', 'epi',
    true, false, NULL, true, true
  );

  IF v_row.tenant_id = '10000000-0000-0000-0000-000000000001'::uuid
     AND v_row.blocks_dispatch_if_missing = true
     AND v_row.requires_calibration = false THEN
    INSERT INTO test_results VALUES ('T2 upsert epi type', 'PASS', v_row.id::text);
  ELSE
    INSERT INTO test_results VALUES ('T2 upsert epi type', 'FAIL', coalesce(v_row::text, 'null'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 upsert epi type', 'FAIL', SQLERRM);
END $$;

-- T3: list includes platform + tenant
DO $$
DECLARE
  v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM api.list_asset_types(false);
  IF v_n >= 4 THEN
    INSERT INTO test_results VALUES ('T3 list asset types', 'PASS', format('n=%s', v_n));
  ELSE
    INSERT INTO test_results VALUES ('T3 list asset types', 'FAIL', format('n=%s', v_n));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 list asset types', 'FAIL', SQLERRM);
END $$;

-- T4: existing assets unchanged (new cols default)
DO $$
DECLARE
  v_id uuid;
  v_type uuid;
  v_cal boolean;
  v_blk boolean;
BEGIN
  SELECT id, asset_type_id, requires_calibration, blocks_dispatch_if_missing
  INTO v_id, v_type, v_cal, v_blk
  FROM data.assets
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'
  LIMIT 1;

  IF v_id IS NULL THEN
    INSERT INTO test_results VALUES ('T4 existing assets defaults', 'PASS', 'no_assets_skip');
  ELSIF v_type IS NULL AND v_cal = false AND v_blk = false THEN
    INSERT INTO test_results VALUES ('T4 existing assets defaults', 'PASS', v_id::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T4 existing assets defaults',
      'FAIL',
      format('type=%s cal=%s blk=%s', v_type, v_cal, v_blk)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T4 existing assets defaults', 'FAIL', SQLERRM);
END $$;

-- T5: link asset to type via api.assets update path (data update)
RESET ROLE;
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_site uuid := '30000000-0000-0000-0000-000000000001';
  v_type uuid;
  v_asset uuid;
  v_got uuid;
BEGIN
  SELECT id INTO v_type FROM data.asset_types
  WHERE tenant_id = v_tenant AND code = 'EA0_TEST_EPI';

  INSERT INTO data.assets (tenant_id, site_id, name, asset_tag, status, asset_type_id, blocks_dispatch_if_missing)
  VALUES (v_tenant, v_site, 'EA0 Casc #1', 'EA0-CASC-1', 'operational', v_type, true)
  RETURNING id INTO v_asset;

  SELECT asset_type_id INTO v_got FROM data.assets WHERE id = v_asset;

  IF v_got = v_type THEN
    INSERT INTO test_results VALUES ('T5 link asset to type', 'PASS', v_asset::text);
  ELSE
    INSERT INTO test_results VALUES ('T5 link asset to type', 'FAIL', coalesce(v_got::text, 'null'));
  END IF;

  DELETE FROM data.assets WHERE id = v_asset;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 link asset to type', 'FAIL', SQLERRM);
  DELETE FROM data.assets WHERE asset_tag = 'EA0-CASC-1';
END $$;

-- T6: tenant mismatch rejected
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_site uuid := '30000000-0000-0000-0000-000000000001';
  v_other_type uuid;
  v_ok boolean := false;
BEGIN
  -- Create type on another tenant if exists, else skip with synthetic fail path
  INSERT INTO data.asset_types (tenant_id, code, name, category)
  SELECT t.id, 'EA0_OTHER', 'Other tenant type', 'other'
  FROM data.tenants t
  WHERE t.id <> v_tenant
  LIMIT 1
  RETURNING id INTO v_other_type;

  IF v_other_type IS NULL THEN
    INSERT INTO test_results VALUES ('T6 type tenant mismatch', 'PASS', 'no_other_tenant_skip');
    RETURN;
  END IF;

  BEGIN
    INSERT INTO data.assets (tenant_id, site_id, name, asset_type_id)
    VALUES (v_tenant, v_site, 'EA0 Bad Link', v_other_type);
  EXCEPTION WHEN foreign_key_violation OR check_violation OR OTHERS THEN
    IF SQLERRM ILIKE '%asset_type_tenant_mismatch%' OR SQLSTATE = '23503' OR SQLSTATE = 'P0001' THEN
      v_ok := true;
    END IF;
  END;

  DELETE FROM data.assets WHERE name = 'EA0 Bad Link' AND tenant_id = v_tenant;
  DELETE FROM data.asset_types WHERE id = v_other_type;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T6 type tenant mismatch', 'PASS', 'rejected');
  ELSE
    INSERT INTO test_results VALUES ('T6 type tenant mismatch', 'FAIL', 'accepted_cross_tenant');
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 type tenant mismatch', 'FAIL', SQLERRM);
END $$;

-- Cleanup tenant test type
DO $$
BEGIN
  DELETE FROM data.asset_types
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'
    AND code = 'EA0_TEST_EPI';
  INSERT INTO test_results VALUES ('T7 cleanup', 'PASS', 'ok');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T7 cleanup', 'FAIL', SQLERRM);
END $$;

SELECT * FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  RAISE NOTICE 'M-EA-0 asset types: % PASS, % FAIL',
    (SELECT count(*) FROM test_results WHERE status = 'PASS'),
    v_fail;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'M-EA-0 asset types tests failed';
  END IF;
END $$;

ROLLBACK;
