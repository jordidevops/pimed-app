-- =============================================================================
-- CR-3 certification expiry notice tests
-- =============================================================================

BEGIN;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

DO $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
END $$;

-- T1: emit notice at 30 days
DO $$
DECLARE
  v_emp uuid := '40000000-0000-0000-0000-000000000001';
  v_type uuid;
  v_cert uuid;
  v_as_of date := CURRENT_DATE;
  v_result jsonb;
  v_count int;
BEGIN
  SELECT id INTO v_type FROM data.compliance_requirement_types
  WHERE tenant_id IS NULL AND code = 'HEIGHT_WORK' LIMIT 1;

  SELECT (api.upsert_employee_certification(
    NULL, v_emp, v_type, 'test', NULL, v_as_of,
    v_as_of, v_as_of + 30, NULL, 'cr3_notice_30'
  )).id INTO v_cert;

  v_result := api.run_emit_certification_expiry_notices(v_as_of);

  SELECT count(*) INTO v_count
  FROM data.compliance_notice_log
  WHERE certification_id = v_cert AND notice_days = 30;

  IF (v_result->>'emitted')::int >= 1 AND v_count = 1 THEN
    INSERT INTO test_results VALUES ('T1 emit 30-day notice', 'PASS', v_result::text);
  ELSE
    INSERT INTO test_results VALUES ('T1 emit 30-day notice', 'FAIL',
      format('result=%s count=%s', v_result::text, v_count));
  END IF;
END $$;

-- T2: re-run does not duplicate
DO $$
DECLARE
  v_cert uuid;
  v_before int;
  v_after int;
  v_result jsonb;
BEGIN
  SELECT id INTO v_cert FROM data.employee_certifications
  WHERE notes = 'cr3_notice_30' AND revoked_at IS NULL
  ORDER BY created_at DESC LIMIT 1;

  SELECT count(*) INTO v_before FROM data.compliance_notice_log
  WHERE certification_id = v_cert;

  v_result := api.run_emit_certification_expiry_notices(CURRENT_DATE);

  SELECT count(*) INTO v_after FROM data.compliance_notice_log
  WHERE certification_id = v_cert;

  IF v_before = v_after AND (v_result->>'skipped_duplicates')::int >= 1 THEN
    INSERT INTO test_results VALUES ('T2 re-run no duplicates', 'PASS', v_result::text);
  ELSE
    INSERT INTO test_results VALUES ('T2 re-run no duplicates', 'FAIL',
      format('before=%s after=%s result=%s', v_before, v_after, v_result::text));
  END IF;
END $$;

-- T3: audit event CERTIFICATION_EXPIRING written
DO $$
DECLARE
  v_cert uuid;
  v_count int;
BEGIN
  SELECT id INTO v_cert FROM data.employee_certifications
  WHERE notes = 'cr3_notice_30' AND revoked_at IS NULL
  ORDER BY created_at DESC LIMIT 1;

  SELECT count(*) INTO v_count
  FROM data.audit_logs
  WHERE action = 'CERTIFICATION_EXPIRING'
    AND entity_id = v_cert;

  IF v_count >= 1 THEN
    INSERT INTO test_results VALUES ('T3 audit CERTIFICATION_EXPIRING', 'PASS', format('count=%s', v_count));
  ELSE
    INSERT INTO test_results VALUES ('T3 audit CERTIFICATION_EXPIRING', 'FAIL', 'no audit row');
  END IF;
END $$;

-- T4: 90-day threshold also fires
DO $$
DECLARE
  v_emp uuid := '40000000-0000-0000-0000-000000000001';
  v_type uuid;
  v_cert uuid;
  v_as_of date := CURRENT_DATE;
  v_result jsonb;
  v_count int;
BEGIN
  SELECT id INTO v_type FROM data.compliance_requirement_types
  WHERE tenant_id IS NULL AND code = 'PRL_BASIC' LIMIT 1;

  SELECT (api.upsert_employee_certification(
    NULL, v_emp, v_type, 'test', NULL, v_as_of,
    v_as_of, v_as_of + 90, NULL, 'cr3_notice_90'
  )).id INTO v_cert;

  v_result := api.run_emit_certification_expiry_notices(v_as_of);

  SELECT count(*) INTO v_count
  FROM data.compliance_notice_log
  WHERE certification_id = v_cert AND notice_days = 90;

  IF v_count = 1 THEN
    INSERT INTO test_results VALUES ('T4 emit 90-day notice', 'PASS', v_result::text);
  ELSE
    INSERT INTO test_results VALUES ('T4 emit 90-day notice', 'FAIL', format('count=%s', v_count));
  END IF;
END $$;

-- T5: non-threshold day does not emit
DO $$
DECLARE
  v_emp uuid := '40000000-0000-0000-0000-000000000001';
  v_type uuid;
  v_cert uuid;
  v_as_of date := CURRENT_DATE;
  v_count int;
BEGIN
  SELECT id INTO v_type FROM data.compliance_requirement_types
  WHERE tenant_id IS NULL AND code = 'MEDICAL_FIT' LIMIT 1;

  SELECT (api.upsert_employee_certification(
    NULL, v_emp, v_type, 'test', NULL, v_as_of,
    v_as_of, v_as_of + 45, NULL, 'cr3_notice_45'
  )).id INTO v_cert;

  PERFORM api.run_emit_certification_expiry_notices(v_as_of);

  SELECT count(*) INTO v_count
  FROM data.compliance_notice_log
  WHERE certification_id = v_cert;

  IF v_count = 0 THEN
    INSERT INTO test_results VALUES ('T5 non-threshold ignored', 'PASS', 'count=0');
  ELSE
    INSERT INTO test_results VALUES ('T5 non-threshold ignored', 'FAIL', format('count=%s', v_count));
  END IF;
END $$;

SELECT * FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_pass int;
  v_fail int;
BEGIN
  SELECT count(*) FILTER (WHERE status = 'PASS'), count(*) FILTER (WHERE status = 'FAIL')
  INTO v_pass, v_fail FROM test_results;
  RAISE NOTICE 'CR notice tests: % PASS, % FAIL', v_pass, v_fail;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'CR notice tests failed';
  END IF;
END $$;

ROLLBACK;
