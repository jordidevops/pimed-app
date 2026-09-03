-- EHR employee private profiles RLS + RPC tests (M-EHR-05)
BEGIN;
SET client_min_messages TO WARNING;

CREATE TEMP TABLE test_results (
  test_name text PRIMARY KEY,
  status text NOT NULL,
  details text
) ON COMMIT DROP;

GRANT ALL ON test_results TO authenticated;

DO $$
DECLARE
  v_tenant     uuid := '10000000-0000-0000-0000-000000000001';
  v_alice      uuid := '40000000-0000-0000-0000-000000000001';
  v_alice_user uuid := '20000000-0000-0000-0000-000000000002';
  v_dave_user  uuid := '20000000-0000-0000-0000-000000000005';
  v_orig_doc   text;
  v_pp_doc     text;
  v_emp_doc    text;
  v_got        boolean;
  v_ok         boolean;
BEGIN
  SELECT document_id INTO v_orig_doc
  FROM data.employees
  WHERE id = v_alice AND tenant_id = v_tenant;

  -- T1: table exists with document_number
  IF to_regclass('data.employee_private_profiles') IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM information_schema.columns
       WHERE table_schema = 'data'
         AND table_name = 'employee_private_profiles'
         AND column_name = 'document_number'
     ) THEN
    INSERT INTO test_results VALUES ('T1 employee_private_profiles exists', 'PASS', 'document_number ok');
  ELSE
    INSERT INTO test_results VALUES ('T1 employee_private_profiles exists', 'FAIL', 'missing table/col');
  END IF;

  -- T2: directory must not expose private fields
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'api' AND table_name = 'employee_directory'
      AND column_name IN ('document_id', 'document_number', 'birth_date')
  ) THEN
    INSERT INTO test_results VALUES ('T2 directory hides private cols', 'PASS', 'no doc/birth');
  ELSE
    INSERT INTO test_results VALUES ('T2 directory hides private cols', 'FAIL', 'private cols exposed');
  END IF;

  -- T3: backfill (as table owner / bypass RLS in this DO as postgres)
  IF EXISTS (
    SELECT 1 FROM data.employee_private_profiles
    WHERE employee_id = v_alice AND tenant_id = v_tenant
  ) THEN
    INSERT INTO test_results VALUES ('T3 Alice private row backfill', 'PASS', 'row exists');
  ELSE
    INSERT INTO test_results VALUES ('T3 Alice private row backfill', 'FAIL', 'missing before get');
  END IF;

  -- JWT Alice owner
  PERFORM set_config('request.jwt.claim.sub', v_alice_user::text, true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  -- T4: owner get + upsert + sync
  v_got := false;
  BEGIN
    PERFORM api.get_employee_private_profile(v_alice);
    v_got := true;
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO test_results VALUES ('T4 owner get/upsert/sync', 'FAIL', 'get: ' || SQLERRM);
  END;

  IF v_got THEN
    BEGIN
      PERFORM api.upsert_employee_private_profile(
        p_employee_id := v_alice,
        p_document_number := 'EHR5-TEST-DOC'
      );
      SELECT pp.document_number, e.document_id
      INTO v_pp_doc, v_emp_doc
      FROM data.employee_private_profiles pp
      JOIN data.employees e ON e.id = pp.employee_id
      WHERE pp.employee_id = v_alice;

      IF v_pp_doc = 'EHR5-TEST-DOC' AND v_emp_doc = 'EHR5-TEST-DOC' THEN
        INSERT INTO test_results VALUES ('T4 owner get/upsert/sync', 'PASS', 'synced document_id');
      ELSE
        INSERT INTO test_results VALUES (
          'T4 owner get/upsert/sync',
          'FAIL',
          format('pp=%s emp=%s', v_pp_doc, v_emp_doc)
        );
      END IF;
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO test_results VALUES ('T4 owner get/upsert/sync', 'FAIL', 'upsert: ' || SQLERRM);
    END;
  END IF;

  -- T5: Dave member get denied
  PERFORM set_config('request.jwt.claim.sub', v_dave_user::text, true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000005","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  v_ok := false;
  BEGIN
    PERFORM api.get_employee_private_profile(v_alice);
  EXCEPTION
    WHEN insufficient_privilege THEN
      v_ok := true;
    WHEN OTHERS THEN
      IF SQLERRM ILIKE '%insufficient_privilege%' THEN
        v_ok := true;
      ELSE
        INSERT INTO test_results VALUES ('T5 Dave get denied', 'FAIL', SQLERRM);
      END IF;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T5 Dave get denied', 'PASS', 'insufficient_privilege');
  ELSIF NOT EXISTS (SELECT 1 FROM test_results WHERE test_name = 'T5 Dave get denied') THEN
    INSERT INTO test_results VALUES ('T5 Dave get denied', 'FAIL', 'get succeeded');
  END IF;

  -- T7: ciphertext columns exist; API view has no plaintext SSN / no ciphertext
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'data'
      AND table_name = 'employee_private_profiles'
      AND column_name IN ('iban_ciphertext', 'ssn_ciphertext')
  )
  AND NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'api'
      AND table_name = 'employee_private_profiles'
      AND column_name IN (
        'social_security_number', 'iban_ciphertext', 'ssn_ciphertext', 'iban_nonce', 'ssn_nonce'
      )
  )
  AND EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'api'
      AND table_name = 'employee_private_profiles'
      AND column_name IN ('has_iban', 'iban_last4', 'has_ssn', 'ssn_last4')
  ) THEN
    INSERT INTO test_results VALUES ('T7 encrypted cols + safe view', 'PASS', 'ciphertext data / masked api');
  ELSE
    INSERT INTO test_results VALUES ('T7 encrypted cols + safe view', 'FAIL', 'schema mismatch');
  END IF;

  -- stash orig doc for cleanup DO
  PERFORM set_config('test.ehr5_orig_doc', coalesce(v_orig_doc, ''), true);
END $$;

-- T6: Dave SELECT under authenticated (RLS enforced)
SET LOCAL ROLE authenticated;
DO $$
DECLARE
  v_alice uuid := '40000000-0000-0000-0000-000000000001';
  v_cnt int;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000005', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000005","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT count(*) INTO v_cnt
  FROM api.employee_private_profiles
  WHERE employee_id = v_alice;

  IF v_cnt = 0 THEN
    INSERT INTO test_results VALUES ('T6 Dave select Alice is 0', 'PASS', 'count=0');
  ELSE
    INSERT INTO test_results VALUES ('T6 Dave select Alice is 0', 'FAIL', format('count=%s', v_cnt));
  END IF;
END $$;
RESET ROLE;

-- T8 cleanup as postgres (bypass) + owner RPC
DO $$
DECLARE
  v_alice uuid := '40000000-0000-0000-0000-000000000001';
  v_orig_doc text := nullif(current_setting('test.ehr5_orig_doc', true), '');
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  IF v_orig_doc IS NULL THEN
    UPDATE data.employee_private_profiles SET document_number = NULL WHERE employee_id = v_alice;
    UPDATE data.employees SET document_id = NULL WHERE id = v_alice;
  ELSE
    UPDATE data.employee_private_profiles
    SET document_number = v_orig_doc
    WHERE employee_id = v_alice;
  END IF;

  INSERT INTO test_results VALUES (
    'T8 cleanup restore Alice document',
    'PASS',
    coalesce(v_orig_doc, 'null')
  );
END $$;

SELECT * FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  RAISE NOTICE 'EHR private profile RLS tests: % PASS, % FAIL',
    (SELECT count(*) FROM test_results WHERE status = 'PASS'),
    v_fail;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EHR private profile RLS tests failed';
  END IF;
END $$;

ROLLBACK;
