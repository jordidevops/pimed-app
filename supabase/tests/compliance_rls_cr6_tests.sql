-- =============================================================================
-- CR-6 compliance RLS / security tests
-- =============================================================================

BEGIN;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

-- Seed: owner creates tech + medical certs on Alice employee
DO $$
DECLARE
  v_emp uuid := '40000000-0000-0000-0000-000000000001';
  v_prl uuid;
  v_med uuid;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT id INTO v_prl FROM data.compliance_requirement_types
  WHERE tenant_id IS NULL AND code = 'PRL_BASIC' LIMIT 1;
  SELECT id INTO v_med FROM data.compliance_requirement_types
  WHERE tenant_id IS NULL AND code = 'MEDICAL_FIT' LIMIT 1;

  -- Ensure at least one of each visible for tests
  IF NOT EXISTS (
    SELECT 1 FROM data.employee_certifications
    WHERE employee_id = v_emp AND requirement_type_id = v_prl AND revoked_at IS NULL AND notes = 'cr6_tech'
  ) THEN
    PERFORM api.upsert_employee_certification(
      NULL, v_emp, v_prl, 'cr6', NULL, CURRENT_DATE, CURRENT_DATE, CURRENT_DATE + 120, NULL, 'cr6_tech'
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.employee_certifications
    WHERE employee_id = v_emp AND requirement_type_id = v_med AND revoked_at IS NULL AND notes = 'cr6_med'
  ) THEN
    PERFORM api.upsert_employee_certification(
      NULL, v_emp, v_med, 'cr6', NULL, CURRENT_DATE, CURRENT_DATE, CURRENT_DATE + 120, NULL, 'cr6_med'
    );
  END IF;
END $$;

-- T1: owner sees tech + medical
DO $$
DECLARE
  v_tech int;
  v_med int;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT count(*) INTO v_tech FROM api.employee_certifications
  WHERE notes = 'cr6_tech';
  SELECT count(*) INTO v_med FROM api.employee_certifications
  WHERE notes = 'cr6_med';

  IF v_tech >= 1 AND v_med >= 1 THEN
    INSERT INTO test_results VALUES ('T1 owner sees tech+medical', 'PASS', format('tech=%s med=%s', v_tech, v_med));
  ELSE
    INSERT INTO test_results VALUES ('T1 owner sees tech+medical', 'FAIL', format('tech=%s med=%s', v_tech, v_med));
  END IF;
END $$;

-- T2: manager (role) sees tech, not medical
DO $$
DECLARE
  v_tech int;
  v_med int;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000004', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000004","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["compliance.certifications.view","compliance.certifications.manage","employees.view"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT count(*) INTO v_tech FROM api.employee_certifications WHERE notes = 'cr6_tech';
  SELECT count(*) INTO v_med FROM api.employee_certifications WHERE notes = 'cr6_med';

  IF v_tech >= 1 AND v_med = 0 THEN
    INSERT INTO test_results VALUES ('T2 manager tech only', 'PASS', format('tech=%s med=%s', v_tech, v_med));
  ELSE
    INSERT INTO test_results VALUES ('T2 manager tech only', 'FAIL', format('tech=%s med=%s', v_tech, v_med));
  END IF;
END $$;

-- T3: compliance officer tech-only (member + explicit perms, no medical)
DO $$
DECLARE
  v_tech int;
  v_med int;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000005', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000005","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["compliance.certifications.view","employees.view"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT count(*) INTO v_tech FROM api.employee_certifications WHERE notes = 'cr6_tech';
  SELECT count(*) INTO v_med FROM api.employee_certifications WHERE notes = 'cr6_med';

  IF v_tech >= 1 AND v_med = 0 THEN
    INSERT INTO test_results VALUES ('T3 officer tech without medical', 'PASS', format('tech=%s med=%s', v_tech, v_med));
  ELSE
    INSERT INTO test_results VALUES ('T3 officer tech without medical', 'FAIL', format('tech=%s med=%s', v_tech, v_med));
  END IF;
END $$;

-- T4: compliance officer with both medical + tech
DO $$
DECLARE
  v_tech int;
  v_med int;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000005', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000005","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["compliance.certifications.view","compliance.medical_clearance.view","employees.view"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT count(*) INTO v_tech FROM api.employee_certifications WHERE notes = 'cr6_tech';
  SELECT count(*) INTO v_med FROM api.employee_certifications WHERE notes = 'cr6_med';

  IF v_tech >= 1 AND v_med >= 1 THEN
    INSERT INTO test_results VALUES ('T4 officer tech+medical', 'PASS', format('tech=%s med=%s', v_tech, v_med));
  ELSE
    INSERT INTO test_results VALUES ('T4 officer tech+medical', 'FAIL', format('tech=%s med=%s', v_tech, v_med));
  END IF;
END $$;

-- T5: member without compliance perms sees nothing
DO $$
DECLARE
  v_count int;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000005', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000005","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["employees.view"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT count(*) INTO v_count FROM api.employee_certifications
  WHERE notes IN ('cr6_tech', 'cr6_med');

  IF v_count = 0 THEN
    INSERT INTO test_results VALUES ('T5 member without compliance sees none', 'PASS', 'count=0');
  ELSE
    INSERT INTO test_results VALUES ('T5 member without compliance sees none', 'FAIL', format('count=%s', v_count));
  END IF;
END $$;

-- T6: no leak of certification fields on api.employees / directory
DO $$
DECLARE
  v_emp_cols int;
  v_dir_cols int;
BEGIN
  SELECT count(*) INTO v_emp_cols
  FROM information_schema.columns
  WHERE table_schema = 'api' AND table_name = 'employees'
    AND column_name IN ('document_id', 'certification_id', 'is_ready', 'blocking_reasons', 'revoked_reason');

  SELECT count(*) INTO v_dir_cols
  FROM information_schema.columns
  WHERE table_schema = 'api' AND table_name = 'employee_directory'
    AND column_name IN ('document_id', 'certification_id', 'is_ready', 'blocking_reasons', 'revoked_reason');

  IF v_emp_cols = 0 AND v_dir_cols = 0 THEN
    INSERT INTO test_results VALUES ('T6 no leak on employees/directory', 'PASS', 'ok');
  ELSE
    INSERT INTO test_results VALUES ('T6 no leak on employees/directory', 'FAIL',
      format('emp=%s dir=%s', v_emp_cols, v_dir_cols));
  END IF;
END $$;

-- T7: compute_employee_readiness multi-tenant
DO $$
DECLARE
  v_emp uuid := '40000000-0000-0000-0000-000000000001';
  v_ok boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}},"10000000-0000-0000-0000-000000000002":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000002"}', true);

  BEGIN
    PERFORM data.compute_employee_readiness(v_emp, CURRENT_DATE);
  EXCEPTION WHEN no_data_found THEN
    v_ok := true;
  END;

  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T7 readiness multi-tenant', 'PASS', 'employee_not_found');
  ELSE
    INSERT INTO test_results VALUES ('T7 readiness multi-tenant', 'FAIL', 'expected no_data_found');
  END IF;
END $$;

-- T8: refresh_employee_readiness_projection multi-tenant
DO $$
DECLARE
  v_emp uuid := '40000000-0000-0000-0000-000000000001';
  v_ok boolean := false;
BEGIN
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000002"}', true);
  BEGIN
    PERFORM data.refresh_employee_readiness_projection(v_emp);
  EXCEPTION WHEN no_data_found THEN
    v_ok := true;
  END;
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T8 refresh projection multi-tenant', 'PASS', 'employee_not_found');
  ELSE
    INSERT INTO test_results VALUES ('T8 refresh projection multi-tenant', 'FAIL', 'expected no_data_found');
  END IF;
END $$;

-- T9: get_own_certifications via portal token
DO $$
DECLARE
  v_emp uuid := '40000000-0000-0000-0000-000000000001';
  v_hash bytea;
  v_hex text;
  v_count int;
BEGIN
  v_hash := digest('cr6-portal-token-secret', 'sha256');
  v_hex := encode(v_hash, 'hex');

  -- Insert token as postgres briefly
  RESET ROLE;
  INSERT INTO data.employee_portal_tokens (
    tenant_id, employee_id, token_hash, is_active
  ) VALUES (
    '10000000-0000-0000-0000-000000000001',
    v_emp,
    v_hash,
    true
  )
  ON CONFLICT (token_hash) DO UPDATE SET is_active = true, revoked_at = NULL;

  SET LOCAL ROLE authenticated;

  SELECT count(*) INTO v_count
  FROM api.get_own_certifications(v_hex);

  IF v_count >= 1 THEN
    INSERT INTO test_results VALUES ('T9 get_own_certifications via token', 'PASS', format('count=%s', v_count));
  ELSE
    INSERT INTO test_results VALUES ('T9 get_own_certifications via token', 'FAIL', format('count=%s', v_count));
  END IF;
END $$;

-- T10: get_own_certifications does not expose revoked_reason column
DO $$
DECLARE
  v_has_revoked boolean := false;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'api'
      AND table_name LIKE '%get_own%' -- won't work for functions
  ) INTO v_has_revoked;

  -- Check return shape via a probe: querying a column that shouldn't exist fails
  BEGIN
    EXECUTE $q$SELECT revoked_reason FROM api.get_own_certifications('00') LIMIT 0$q$;
    INSERT INTO test_results VALUES ('T10 no revoked_reason in portal RPC', 'FAIL', 'column exists');
  EXCEPTION WHEN undefined_column THEN
    INSERT INTO test_results VALUES ('T10 no revoked_reason in portal RPC', 'PASS', 'undefined_column');
  WHEN OTHERS THEN
    -- invalid hash may raise before column check — still verify via pg_proc result type
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'api' AND p.proname = 'get_own_certifications'
        AND pg_get_function_result(p.oid) ILIKE '%revoked_reason%'
    ) THEN
      INSERT INTO test_results VALUES ('T10 no revoked_reason in portal RPC', 'PASS', 'not in result type');
    ELSE
      INSERT INTO test_results VALUES ('T10 no revoked_reason in portal RPC', 'FAIL', 'in result type');
    END IF;
  END;
END $$;

SELECT * FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_pass int;
  v_fail int;
BEGIN
  SELECT count(*) FILTER (WHERE status = 'PASS'), count(*) FILTER (WHERE status = 'FAIL')
  INTO v_pass, v_fail FROM test_results;
  RAISE NOTICE 'CR-6 security tests: % PASS, % FAIL', v_pass, v_fail;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'CR-6 security tests failed';
  END IF;
END $$;

ROLLBACK;
