-- =============================================================================
-- ES-4 — entity_types registry tests
-- =============================================================================

BEGIN;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.set_owner_jwt() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
END;
$$;

-- T1: table exists with expected seed size
DO $$
DECLARE
  v_cnt int;
BEGIN
  SELECT count(*) INTO v_cnt FROM data.entity_types;
  IF v_cnt >= 13 THEN
    INSERT INTO test_results VALUES ('T1 seed size', 'PASS', v_cnt::text);
  ELSE
    INSERT INTO test_results VALUES ('T1 seed size', 'FAIL', v_cnt::text);
  END IF;
END $$;

-- T2: required codes present
DO $$
DECLARE
  v_missing text[];
BEGIN
  SELECT array_agg(c) INTO v_missing
  FROM unnest(ARRAY[
    'employee', 'contact', 'project', 'document',
    'user', 'person', 'site', 'asset', 'tenant', 'catalog_item',
    'employee_certification', 'employee_asset_assignment', 'employment_contract'
  ]) AS c
  WHERE NOT EXISTS (SELECT 1 FROM data.entity_types et WHERE et.code = c);

  IF v_missing IS NULL THEN
    INSERT INTO test_results VALUES ('T2 required codes', 'PASS', 'all present');
  ELSE
    INSERT INTO test_results VALUES ('T2 required codes', 'FAIL', array_to_string(v_missing, ','));
  END IF;
END $$;

-- T3: capability flags sanity
DO $$
DECLARE
  v_emp record;
  v_cert record;
  v_assign record;
  v_asset record;
BEGIN
  SELECT * INTO v_emp FROM data.entity_types WHERE code = 'employee';
  SELECT * INTO v_cert FROM data.entity_types WHERE code = 'employee_certification';
  SELECT * INTO v_assign FROM data.entity_types WHERE code = 'employee_asset_assignment';
  SELECT * INTO v_asset FROM data.entity_types WHERE code = 'asset';

  IF v_emp.supports_timeline
     AND v_emp.supports_documents
     AND v_cert.supports_documents
     AND v_assign.supports_documents
     AND NOT v_assign.supports_signing
     AND v_asset.code = 'asset'
     AND v_asset.code IS DISTINCT FROM 'employee_asset_assignment' THEN
    INSERT INTO test_results VALUES ('T3 capability flags', 'PASS', 'ok');
  ELSE
    INSERT INTO test_results VALUES ('T3 capability flags', 'FAIL', 'flag mismatch');
  END IF;
END $$;

-- T4: idempotent re-seed (same count)
DO $$
DECLARE
  v_before int;
  v_after  int;
BEGIN
  SELECT count(*) INTO v_before FROM data.entity_types;

  INSERT INTO data.entity_types (
    code, label_key,
    supports_timeline, supports_documents, supports_signing, supports_subscriptions
  )
  SELECT v.code, v.label_key, v.tl, v.doc, v.sig, v.sub
  FROM (
    VALUES
      ('employee', 'entity_types.employee', true, true, true, true)
  ) AS v(code, label_key, tl, doc, sig, sub)
  WHERE NOT EXISTS (
    SELECT 1 FROM data.entity_types et WHERE et.code = v.code
  );

  SELECT count(*) INTO v_after FROM data.entity_types;

  IF v_before = v_after THEN
    INSERT INTO test_results VALUES ('T4 idempotent reseed', 'PASS', v_after::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T4 idempotent reseed', 'FAIL', format('%s→%s', v_before, v_after)
    );
  END IF;
END $$;

-- T5: api.entity_types readable as authenticated
DO $$
DECLARE
  v_cnt int;
BEGIN
  PERFORM set_config('role', 'authenticated', true);
  PERFORM pg_temp.set_owner_jwt();
  SELECT count(*) INTO v_cnt FROM api.entity_types;
  PERFORM set_config('role', 'postgres', true);

  IF v_cnt >= 13 THEN
    INSERT INTO test_results VALUES ('T5 api view authenticated', 'PASS', v_cnt::text);
  ELSE
    INSERT INTO test_results VALUES ('T5 api view authenticated', 'FAIL', v_cnt::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('role', 'postgres', true);
  INSERT INTO test_results VALUES ('T5 api view authenticated', 'FAIL', SQLERRM);
END $$;

-- T6: soft docs still readable (no new FK breakage)
DO $$
DECLARE
  v_cnt int;
BEGIN
  SELECT count(*) INTO v_cnt
  FROM data.documents
  WHERE entity_type IN (
    'employee_certification',
    'employee_asset_assignment',
    'employment_contract'
  );

  -- Zero rows is fine if seed has none; the SELECT must not error
  INSERT INTO test_results VALUES ('T6 soft docs still readable', 'PASS', v_cnt::text);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 soft docs still readable', 'FAIL', SQLERRM);
END $$;

-- T7: assert helper known / unknown
DO $$
DECLARE
  v_ok boolean := false;
BEGIN
  PERFORM data.assert_entity_type_registered('employee');

  BEGIN
    PERFORM data.assert_entity_type_registered('not_a_real_entity_type_xyz');
  EXCEPTION
    WHEN check_violation THEN
      v_ok := true;
    WHEN OTHERS THEN
      IF SQLERRM ILIKE '%unknown_entity_type%' THEN
        v_ok := true;
      END IF;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T7 assert helper', 'PASS', 'known+unknown');
  ELSE
    INSERT INTO test_results VALUES ('T7 assert helper', 'FAIL', 'expected unknown_entity_type');
  END IF;
END $$;

-- T8: no accidental employee_asset code (wrong name)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM data.entity_types WHERE code = 'employee_asset') THEN
    INSERT INTO test_results VALUES ('T8 no employee_asset alias', 'FAIL', 'unexpected code');
  ELSE
    INSERT INTO test_results VALUES ('T8 no employee_asset alias', 'PASS', 'ok');
  END IF;
END $$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'ES-4 tests failed: % failures', v_fail;
  END IF;
END $$;

ROLLBACK;
