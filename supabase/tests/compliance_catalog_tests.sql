-- =============================================================================
-- CR-0 Compliance catalog tests
-- =============================================================================

BEGIN;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

-- T1: platform seed types exist
DO $$
DECLARE v_count int;
BEGIN
  SELECT count(*) INTO v_count
  FROM data.compliance_requirement_types
  WHERE tenant_id IS NULL AND is_active;
  IF v_count >= 3 THEN
    INSERT INTO test_results VALUES ('T1 platform requirement types seeded', 'PASS', format('count=%s', v_count));
  ELSE
    INSERT INTO test_results VALUES ('T1 platform requirement types seeded', 'FAIL', format('count=%s', v_count));
  END IF;
END $$;

-- T2: owner can create tenant-wide rule via RPC
DO $$
DECLARE
  v_type_id uuid;
  v_rule_id uuid;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT id INTO v_type_id
  FROM data.compliance_requirement_types
  WHERE tenant_id IS NULL AND code = 'PRL_BASIC'
  LIMIT 1;

  SELECT (api.upsert_compliance_requirement_rule(
    NULL, v_type_id, 'tenant', NULL, true, 7, true
  )).id INTO v_rule_id;

  IF v_rule_id IS NOT NULL THEN
    INSERT INTO test_results VALUES ('T2 owner creates tenant-wide rule', 'PASS', v_rule_id::text);
  ELSE
    INSERT INTO test_results VALUES ('T2 owner creates tenant-wide rule', 'FAIL', 'null id');
  END IF;
END $$;

-- T3: grace_period_days persisted
DO $$
DECLARE v_grace int;
BEGIN
  SELECT grace_period_days INTO v_grace
  FROM data.compliance_requirement_rules
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'::uuid
    AND scope_type = 'tenant'
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_grace = 7 THEN
    INSERT INTO test_results VALUES ('T3 grace_period_days stored', 'PASS', 'grace=7');
  ELSE
    INSERT INTO test_results VALUES ('T3 grace_period_days stored', 'FAIL', format('grace=%s', v_grace));
  END IF;
END $$;

-- T4: site scope rule requires scope_id
DO $$
DECLARE v_caught boolean := false;
  v_type_id uuid;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT id INTO v_type_id FROM data.compliance_requirement_types WHERE code = 'HEIGHT_WORK' LIMIT 1;

  BEGIN
    PERFORM api.upsert_compliance_requirement_rule(
      NULL, v_type_id, 'site', NULL, true, 0, true
    );
  EXCEPTION WHEN invalid_parameter_value THEN
    v_caught := true;
  END;

  IF v_caught THEN
    INSERT INTO test_results VALUES ('T4 site scope requires scope_id', 'PASS', 'rejected');
  ELSE
    INSERT INTO test_results VALUES ('T4 site scope requires scope_id', 'FAIL', 'insert allowed');
  END IF;
END $$;

-- T5: member cannot upsert requirement type
DO $$
DECLARE v_denied boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000005', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000005","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  BEGIN
    PERFORM api.upsert_compliance_requirement_type(
      NULL, 'TEST_X', 'Test', 'legal', 12, '{30}'::int[], true
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;

  IF v_denied THEN
    INSERT INTO test_results VALUES ('T5 member cannot manage catalog', 'PASS', 'insufficient_privilege');
  ELSE
    INSERT INTO test_results VALUES ('T5 member cannot manage catalog', 'FAIL', 'upsert succeeded');
  END IF;
END $$;

DO $$
DECLARE v_pass int; v_fail int;
BEGIN
  SELECT count(*) FILTER (WHERE status = 'PASS'), count(*) FILTER (WHERE status = 'FAIL')
  INTO v_pass, v_fail FROM test_results;
  RAISE NOTICE 'CR catalog tests: % PASS, % FAIL', v_pass, v_fail;
END $$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN RAISE EXCEPTION 'CR catalog tests failed: % failure(s)', v_fail; END IF;
END $$;

ROLLBACK;
