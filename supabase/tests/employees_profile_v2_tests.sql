-- EHR-1 profile V2 + photo path tests
BEGIN;
SET client_min_messages TO WARNING;

CREATE TEMP TABLE test_results (
  test_name text PRIMARY KEY,
  status text NOT NULL,
  details text
) ON COMMIT DROP;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_alice  uuid := '40000000-0000-0000-0000-000000000001';
  v_bob    uuid := '40000000-0000-0000-0000-000000000002';
  v_path   text;
  v_dup_ok boolean := false;
BEGIN
  IF (
    SELECT count(*) FROM information_schema.columns
    WHERE table_schema = 'data' AND table_name = 'employees'
      AND column_name IN ('employee_code', 'legal_name', 'preferred_name', 'photo_object_path')
  ) = 4 THEN
    INSERT INTO test_results VALUES ('T1 profile columns', 'PASS', '4 cols');
  ELSE
    INSERT INTO test_results VALUES ('T1 profile columns', 'FAIL', 'missing cols');
  END IF;

  UPDATE data.employees
  SET employee_code = 'EHR1-ALICE'
  WHERE id = v_alice AND tenant_id = v_tenant;

  BEGIN
    UPDATE data.employees
    SET employee_code = 'EHR1-ALICE'
    WHERE id = v_bob AND tenant_id = v_tenant;
  EXCEPTION WHEN unique_violation THEN
    v_dup_ok := true;
  END;

  IF v_dup_ok THEN
    INSERT INTO test_results VALUES ('T2 unique employee_code', 'PASS', 'unique_violation');
  ELSE
    INSERT INTO test_results VALUES ('T2 unique employee_code', 'FAIL', 'duplicate allowed');
  END IF;

  UPDATE data.employees SET employee_code = NULL
  WHERE id IN (v_alice, v_bob) AND tenant_id = v_tenant;

  IF (
    SELECT count(*) FROM information_schema.columns
    WHERE table_schema = 'api' AND table_name = 'employee_directory'
      AND column_name IN ('preferred_name', 'employee_code', 'photo_object_path')
  ) = 3
  AND NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'api' AND table_name = 'employee_directory'
      AND column_name = 'document_id'
  ) THEN
    INSERT INTO test_results VALUES ('T3 directory columns', 'PASS', 'ok');
  ELSE
    INSERT INTO test_results VALUES ('T3 directory columns', 'FAIL', 'schema mismatch');
  END IF;

  IF EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'employee-photos' AND public = false) THEN
    INSERT INTO test_results VALUES ('T7 private bucket', 'PASS', 'employee-photos');
  ELSE
    INSERT INTO test_results VALUES ('T7 private bucket', 'FAIL', 'missing');
  END IF;

  -- JWT + tenant header (auth.uid / active_tenant_id / jwt_has_permission)
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  v_path := v_tenant::text || '/' || v_alice::text || '/photo';

  BEGIN
    PERFORM api.set_employee_photo_path(v_alice, 'bad/path');
    INSERT INTO test_results VALUES ('T4 invalid photo path', 'FAIL', 'accepted bad path');
  EXCEPTION WHEN check_violation THEN
    INSERT INTO test_results VALUES ('T4 invalid photo path', 'PASS', 'check_violation');
  WHEN OTHERS THEN
    IF SQLERRM ILIKE '%invalid_photo_path%' THEN
      INSERT INTO test_results VALUES ('T4 invalid photo path', 'PASS', SQLERRM);
    ELSE
      INSERT INTO test_results VALUES ('T4 invalid photo path', 'FAIL', SQLERRM);
    END IF;
  END;

  PERFORM api.set_employee_photo_path(v_alice, v_path);
  SELECT photo_object_path INTO v_path FROM data.employees WHERE id = v_alice;
  IF v_path = v_tenant::text || '/' || v_alice::text || '/photo' THEN
    INSERT INTO test_results VALUES ('T5 set photo path', 'PASS', v_path);
  ELSE
    INSERT INTO test_results VALUES ('T5 set photo path', 'FAIL', coalesce(v_path, 'null'));
  END IF;

  PERFORM api.set_employee_photo_path(v_alice, NULL);
  SELECT photo_object_path INTO v_path FROM data.employees WHERE id = v_alice;
  IF v_path IS NULL THEN
    INSERT INTO test_results VALUES ('T6 clear photo path', 'PASS', 'null');
  ELSE
    INSERT INTO test_results VALUES ('T6 clear photo path', 'FAIL', v_path);
  END IF;
END $$;

SELECT * FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  RAISE NOTICE 'EHR-1 profile tests: % PASS, % FAIL',
    (SELECT count(*) FROM test_results WHERE status = 'PASS'),
    v_fail;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EHR-1 profile tests failed';
  END IF;
END $$;

ROLLBACK;
