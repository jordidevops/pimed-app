-- =============================================================================
-- CR-1 employee certifications tests
-- =============================================================================

BEGIN;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

-- T1: compute_certification_status cases
DO $$
BEGIN
  IF data.compute_certification_status(CURRENT_DATE - 10, NULL) = 'indefinite'
     AND data.compute_certification_status(CURRENT_DATE - 10, CURRENT_DATE - 1) = 'expired'
     AND data.compute_certification_status(CURRENT_DATE - 10, CURRENT_DATE + 10) = 'expiring_soon'
     AND data.compute_certification_status(CURRENT_DATE + 5, CURRENT_DATE + 40) = 'not_yet_valid'
     AND data.compute_certification_status(CURRENT_DATE - 10, CURRENT_DATE + 60) = 'active'
  THEN
    INSERT INTO test_results VALUES ('T1 compute_certification_status', 'PASS', 'ok');
  ELSE
    INSERT INTO test_results VALUES ('T1 compute_certification_status', 'FAIL', 'mismatch');
  END IF;
END $$;

-- T2: owner creates indefinite + dated certifications
DO $$
DECLARE
  v_emp_id uuid;
  v_type_id uuid;
  v_med_id uuid;
  v_indef uuid;
  v_dated uuid;
  v_status text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT id INTO v_emp_id FROM data.employees
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'::uuid
    AND status <> 'terminated'
  LIMIT 1;

  SELECT id INTO v_type_id FROM data.compliance_requirement_types
  WHERE tenant_id IS NULL AND code = 'PRL_BASIC' LIMIT 1;

  SELECT id INTO v_med_id FROM data.compliance_requirement_types
  WHERE tenant_id IS NULL AND code = 'MEDICAL_FIT' LIMIT 1;

  SELECT (api.upsert_employee_certification(
    NULL, v_emp_id, v_type_id, 'PRL School', NULL, CURRENT_DATE, CURRENT_DATE, NULL, NULL, 'indefinite cert'
  )).id INTO v_indef;

  SELECT (api.upsert_employee_certification(
    NULL, v_emp_id, v_type_id, 'PRL School', NULL, CURRENT_DATE, CURRENT_DATE, CURRENT_DATE + 90, NULL, 'dated'
  )).id INTO v_dated;

  SELECT computed_status INTO v_status FROM api.employee_certifications WHERE id = v_indef;

  IF v_indef IS NOT NULL AND v_dated IS NOT NULL AND v_status = 'indefinite' THEN
    INSERT INTO test_results VALUES ('T2 create indefinite and dated', 'PASS', format('indef=%s dated=%s', v_indef, v_dated));
  ELSE
    INSERT INTO test_results VALUES ('T2 create indefinite and dated', 'FAIL', format('indef=%s dated=%s status=%s', v_indef, v_dated, v_status));
  END IF;

  -- seed medical for later tests
  PERFORM api.upsert_employee_certification(
    NULL, v_emp_id, v_med_id, 'SPP', NULL, CURRENT_DATE, CURRENT_DATE, CURRENT_DATE + 365, NULL, 'medical'
  );
END $$;

-- T3: revoke keeps row
DO $$
DECLARE
  v_id uuid;
  v_revoked_at timestamptz;
  v_count int;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT id INTO v_id FROM data.employee_certifications
  WHERE notes = 'dated' AND revoked_at IS NULL
  ORDER BY created_at DESC LIMIT 1;

  PERFORM api.revoke_employee_certification(v_id, 'test revoke');

  SELECT revoked_at INTO v_revoked_at FROM data.employee_certifications WHERE id = v_id;
  SELECT count(*) INTO v_count FROM data.employee_certifications WHERE id = v_id;

  IF v_count = 1 AND v_revoked_at IS NOT NULL THEN
    INSERT INTO test_results VALUES ('T3 revoke keeps row', 'PASS', format('id=%s', v_id));
  ELSE
    INSERT INTO test_results VALUES ('T3 revoke keeps row', 'FAIL', format('count=%s revoked=%s', v_count, v_revoked_at));
  END IF;
END $$;

-- T4: manager with certifications.view but without medical_clearance.view cannot see medical
DO $$
DECLARE
  v_med_visible int;
  v_non_med int;
BEGIN
  -- Charlie = manager real (no owner a cache/BD)
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000004', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000004","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["compliance.certifications.view","compliance.certifications.manage","employees.view","employees.manage"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT count(*) INTO v_med_visible
  FROM api.employee_certifications
  WHERE requirement_category = 'medical';

  SELECT count(*) INTO v_non_med
  FROM api.employee_certifications
  WHERE requirement_category <> 'medical'
    AND notes = 'indefinite cert';

  IF v_med_visible = 0 AND v_non_med >= 1 THEN
    INSERT INTO test_results VALUES ('T4 manager cannot see medical', 'PASS', format('med=%s nonmed=%s', v_med_visible, v_non_med));
  ELSE
    INSERT INTO test_results VALUES ('T4 manager cannot see medical', 'FAIL', format('med=%s nonmed=%s', v_med_visible, v_non_med));
  END IF;
END $$;

-- T5: member cannot manage certifications
DO $$
DECLARE
  v_emp_id uuid;
  v_type_id uuid;
  v_ok boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000005', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000005","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT id INTO v_emp_id FROM data.employees
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'::uuid LIMIT 1;
  SELECT id INTO v_type_id FROM data.compliance_requirement_types
  WHERE tenant_id IS NULL AND code = 'HEIGHT_WORK' LIMIT 1;

  BEGIN
    PERFORM api.upsert_employee_certification(
      NULL, v_emp_id, v_type_id, NULL, NULL, NULL, CURRENT_DATE, NULL, NULL, NULL
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_ok := true;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T5 member cannot manage', 'PASS', 'insufficient_privilege');
  ELSE
    INSERT INTO test_results VALUES ('T5 member cannot manage', 'FAIL', 'expected insufficient_privilege');
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
  RAISE NOTICE 'CR certifications tests: % PASS, % FAIL', v_pass, v_fail;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'CR certifications tests failed';
  END IF;
END $$;

ROLLBACK;
