-- =============================================================================
-- EA readiness — asset_requirement_rules / MISSING_ASSET
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
  asset_type_id uuid,
  asset_id uuid,
  rule_id uuid,
  rule_info_id uuid
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
  v_asset uuid;
BEGIN
  -- Cleanup leftovers
  DELETE FROM data.employee_asset_assignments
  WHERE asset_id IN (
    SELECT id FROM data.assets WHERE asset_tag LIKE 'EA2R-%'
  );
  DELETE FROM data.assets WHERE tenant_id = v_tenant AND asset_tag LIKE 'EA2R-%';
  DELETE FROM data.asset_requirement_rules
  WHERE tenant_id = v_tenant
    AND asset_type_id IN (
      SELECT id FROM data.asset_types WHERE code LIKE 'EA2R_%'
    );
  DELETE FROM data.asset_types WHERE tenant_id = v_tenant AND code LIKE 'EA2R_%';
  DELETE FROM data.employees WHERE tenant_id = v_tenant AND full_name = 'EA2R Ready Emp';

  INSERT INTO data.employees (tenant_id, full_name, status, weekly_hours, site_id)
  VALUES (v_tenant, 'EA2R Ready Emp', 'active', 40, v_site)
  RETURNING id INTO v_emp;

  INSERT INTO data.asset_types (
    tenant_id, code, name, category,
    requires_return, requires_calibration, calibration_interval_days,
    blocks_dispatch_if_missing, is_active
  ) VALUES (
    v_tenant, 'EA2R_EPI', 'EA2R Casc test', 'epi',
    true, true, 365, true, true
  )
  RETURNING id INTO v_type;

  INSERT INTO data.assets (
    tenant_id, site_id, name, asset_tag, status,
    asset_type_id, requires_calibration, calibration_due_on
  ) VALUES (
    v_tenant, v_site, 'EA2R Casc físic', 'EA2R-1', 'operational',
    v_type, true, CURRENT_DATE + 30
  )
  RETURNING id INTO v_asset;

  UPDATE test_ids SET
    employee_id = v_emp,
    asset_type_id = v_type,
    asset_id = v_asset;
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

-- T1: upsert blocking tenant rule
DO $$
DECLARE
  v_type uuid;
  v_row api.asset_requirement_rules;
BEGIN
  SELECT asset_type_id INTO v_type FROM test_ids;
  v_row := api.upsert_asset_requirement_rule(
    NULL, v_type, 'tenant', NULL, true, true
  );
  IF v_row.asset_type_id = v_type
     AND v_row.scope_type = 'tenant'
     AND v_row.is_blocking = true THEN
    UPDATE test_ids SET rule_id = v_row.id;
    INSERT INTO test_results VALUES ('T1 upsert blocking rule', 'PASS', v_row.id::text);
  ELSE
    INSERT INTO test_results VALUES ('T1 upsert blocking rule', 'FAIL', v_row::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T1 upsert blocking rule', 'FAIL', SQLERRM);
END $$;

-- T2: missing asset → MISSING_ASSET + not ready
DO $$
DECLARE
  v_emp uuid;
  v_result jsonb;
  v_reasons jsonb;
BEGIN
  SELECT employee_id INTO v_emp FROM test_ids;
  v_result := data.compute_employee_readiness(v_emp, CURRENT_DATE);
  v_reasons := v_result->'blocking_reasons';

  IF (v_result->>'is_ready')::boolean = false
     AND v_reasons @> '["MISSING_ASSET:EA2R_EPI"]'::jsonb THEN
    INSERT INTO test_results VALUES ('T2 missing asset blocks', 'PASS', v_result::text);
  ELSE
    INSERT INTO test_results VALUES ('T2 missing asset blocks', 'FAIL', v_result::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 missing asset blocks', 'FAIL', SQLERRM);
END $$;

-- T3: assign valid → MISSING_ASSET desapareix
DO $$
DECLARE
  v_emp uuid;
  v_asset uuid;
  v_result jsonb;
  v_reasons jsonb;
BEGIN
  SELECT employee_id, asset_id INTO v_emp, v_asset FROM test_ids;
  PERFORM api.assign_employee_asset(v_asset, v_emp, NULL, NULL, 'ea2r');
  v_result := data.compute_employee_readiness(v_emp, CURRENT_DATE);
  v_reasons := coalesce(v_result->'blocking_reasons', '[]'::jsonb);

  IF NOT (v_reasons @> '["MISSING_ASSET:EA2R_EPI"]'::jsonb) THEN
    INSERT INTO test_results VALUES ('T3 assigned clears MISSING_ASSET', 'PASS', v_result::text);
  ELSE
    INSERT INTO test_results VALUES ('T3 assigned clears MISSING_ASSET', 'FAIL', v_result::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 assigned clears MISSING_ASSET', 'FAIL', SQLERRM);
END $$;

-- T4a: expire calibration (bypass RLS)
RESET ROLE;
DO $$
BEGIN
  UPDATE data.assets
  SET calibration_due_on = CURRENT_DATE - 1
  WHERE id = (SELECT asset_id FROM test_ids);
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

-- T4: calibration expired → MISSING_ASSET again
DO $$
DECLARE
  v_emp uuid;
  v_result jsonb;
  v_reasons jsonb;
BEGIN
  SELECT employee_id INTO v_emp FROM test_ids;
  v_result := data.compute_employee_readiness(v_emp, CURRENT_DATE);
  v_reasons := v_result->'blocking_reasons';

  IF (v_result->>'is_ready')::boolean = false
     AND v_reasons @> '["MISSING_ASSET:EA2R_EPI"]'::jsonb THEN
    INSERT INTO test_results VALUES ('T4 expired calibration blocks', 'PASS', v_result::text);
  ELSE
    INSERT INTO test_results VALUES ('T4 expired calibration blocks', 'FAIL', v_result::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T4 expired calibration blocks', 'FAIL', SQLERRM);
END $$;

-- T5a: restore calib + return asset + deactivate blocking rule
RESET ROLE;
DO $$
BEGIN
  UPDATE data.assets
  SET calibration_due_on = CURRENT_DATE + 30
  WHERE id = (SELECT asset_id FROM test_ids);
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

DO $$
DECLARE
  v_asset uuid;
  v_rule uuid;
BEGIN
  SELECT asset_id, rule_id INTO v_asset, v_rule FROM test_ids;
  PERFORM api.return_employee_asset(v_asset, 'good', NULL, 'ea2r return');
  PERFORM api.upsert_asset_requirement_rule(v_rule, NULL, NULL, NULL, NULL, false);
END $$;

-- T5: is_blocking=false → no MISSING_ASSET
DO $$
DECLARE
  v_emp uuid;
  v_type uuid;
  v_info api.asset_requirement_rules;
  v_result jsonb;
  v_reasons jsonb;
BEGIN
  SELECT employee_id, asset_type_id INTO v_emp, v_type FROM test_ids;

  v_info := api.upsert_asset_requirement_rule(
    NULL, v_type, 'tenant', NULL, false, true
  );
  UPDATE test_ids SET rule_info_id = v_info.id;

  v_result := data.compute_employee_readiness(v_emp, CURRENT_DATE);
  v_reasons := coalesce(v_result->'blocking_reasons', '[]'::jsonb);

  IF NOT (v_reasons @> '["MISSING_ASSET:EA2R_EPI"]'::jsonb) THEN
    INSERT INTO test_results VALUES ('T5 non-blocking informational', 'PASS', v_result::text);
  ELSE
    INSERT INTO test_results VALUES ('T5 non-blocking informational', 'FAIL', v_result::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 non-blocking informational', 'FAIL', SQLERRM);
END $$;

-- T6: reactivar blocking + projecció refresca amb MISSING_ASSET
DO $$
DECLARE
  v_emp uuid;
  v_rule uuid;
  v_proj data.employee_readiness_projection;
  v_reasons jsonb;
BEGIN
  SELECT employee_id, rule_id INTO v_emp, v_rule FROM test_ids;
  PERFORM api.upsert_asset_requirement_rule(v_rule, NULL, NULL, NULL, true, true);

  -- Trigger de regla refresca tenant; comprova projecció
  SELECT * INTO v_proj
  FROM data.employee_readiness_projection
  WHERE employee_id = v_emp;

  v_reasons := coalesce(v_proj.blocking_reasons, '[]'::jsonb);

  IF v_proj.employee_id IS NOT NULL
     AND v_proj.is_ready = false
     AND v_reasons @> '["MISSING_ASSET:EA2R_EPI"]'::jsonb THEN
    INSERT INTO test_results VALUES ('T6 projection refresh on rule', 'PASS', v_proj.blocking_reasons::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T6 projection refresh on rule',
      'FAIL',
      coalesce(v_proj::text, 'no_proj')
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 projection refresh on rule', 'FAIL', SQLERRM);
END $$;

-- T7: Dave sense permís no pot upsert
DO $$
DECLARE
  v_type uuid;
  v_ok boolean := false;
BEGIN
  SELECT asset_type_id INTO v_type FROM test_ids;

  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000005', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000005","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  BEGIN
    PERFORM api.upsert_asset_requirement_rule(NULL, v_type, 'tenant', NULL, true, true);
  EXCEPTION WHEN insufficient_privilege THEN
    v_ok := true;
  WHEN OTHERS THEN
    IF SQLERRM ILIKE '%insufficient_privilege%' THEN
      v_ok := true;
    END IF;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T7 dave denied upsert', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T7 dave denied upsert', 'FAIL', 'expected privilege error');
  END IF;
END $$;

-- T8: list retorna regles del tenant
DO $$
DECLARE
  v_count int;
BEGIN
  -- Restore owner JWT
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT count(*) INTO v_count
  FROM api.list_asset_requirement_rules(true)
  WHERE asset_type_id = (SELECT asset_type_id FROM test_ids);

  IF v_count >= 1 THEN
    INSERT INTO test_results VALUES ('T8 list rules', 'PASS', v_count::text);
  ELSE
    INSERT INTO test_results VALUES ('T8 list rules', 'FAIL', v_count::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T8 list rules', 'FAIL', SQLERRM);
END $$;

-- Summary
DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  RAISE NOTICE '=== EA asset readiness MISSING_ASSET ===';
  RAISE NOTICE '%', (SELECT string_agg(test_name || ': ' || status || coalesce(' — ' || details, ''), E'\n' ORDER BY test_name) FROM test_results);
  IF v_fail > 0 THEN
    RAISE EXCEPTION '% failed tests', v_fail;
  END IF;
END $$;

ROLLBACK;
