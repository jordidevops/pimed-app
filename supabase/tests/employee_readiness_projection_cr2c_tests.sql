-- M-CR-07 / CR-2c employee readiness projection tests
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
  requirement_type_id uuid,
  rule_id uuid,
  certification_id uuid
) ON COMMIT DROP;

INSERT INTO test_ids DEFAULT VALUES;

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

RESET ROLE;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_site uuid := '30000000-0000-0000-0000-000000000001';
  v_emp uuid;
  v_type uuid;
  v_rule uuid;
BEGIN
  DELETE FROM data.employee_readiness_projection
  WHERE employee_id IN (
    SELECT id FROM data.employees WHERE full_name = 'CR2c Proj Emp'
  );
  DELETE FROM data.employee_certifications
  WHERE employee_id IN (
    SELECT id FROM data.employees WHERE full_name = 'CR2c Proj Emp'
  );
  DELETE FROM data.compliance_requirement_rules
  WHERE tenant_id = v_tenant
    AND requirement_type_id IN (
      SELECT id FROM data.compliance_requirement_types
      WHERE tenant_id = v_tenant AND code = 'CR2C_HEIGHT'
    );
  DELETE FROM data.compliance_requirement_types
  WHERE tenant_id = v_tenant AND code = 'CR2C_HEIGHT';
  DELETE FROM data.employees WHERE tenant_id = v_tenant AND full_name = 'CR2c Proj Emp';

  INSERT INTO data.employees (
    tenant_id, full_name, status, weekly_hours, site_id, lifecycle_state
  ) VALUES (
    v_tenant, 'CR2c Proj Emp', 'active', 40, v_site, 'active'
  )
  RETURNING id INTO v_emp;

  PERFORM set_config('data.lifecycle_state_write', '1', true);
  UPDATE data.employees SET lifecycle_state = 'active' WHERE id = v_emp;

  INSERT INTO data.compliance_requirement_types (
    tenant_id, code, name, category, is_active
  ) VALUES (
    v_tenant, 'CR2C_HEIGHT', 'CR2c Height Test', 'technical', true
  )
  RETURNING id INTO v_type;

  INSERT INTO data.compliance_requirement_rules (
    tenant_id, requirement_type_id, scope_type, scope_id,
    is_blocking, is_active, grace_period_days, created_by
  ) VALUES (
    v_tenant, v_type, 'tenant', NULL,
    true, true, 0, '20000000-0000-0000-0000-000000000002'
  )
  RETURNING id INTO v_rule;

  UPDATE test_ids SET
    employee_id = v_emp,
    requirement_type_id = v_type,
    rule_id = v_rule;
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

-- T1: refresh creates projection matching live compute (not ready)
DO $$
DECLARE
  v_emp uuid;
  v_live jsonb;
  v_proj data.employee_readiness_projection;
BEGIN
  SELECT employee_id INTO v_emp FROM test_ids;

  RESET ROLE;
  DELETE FROM data.employee_readiness_projection WHERE employee_id = v_emp;
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  PERFORM data.refresh_employee_readiness_projection(v_emp);
  v_live := data.compute_employee_readiness(v_emp, CURRENT_DATE);

  RESET ROLE;
  SELECT * INTO v_proj FROM data.employee_readiness_projection WHERE employee_id = v_emp;

  IF v_proj.employee_id IS NOT NULL
     AND v_proj.is_ready = (v_live->>'is_ready')::boolean
     AND v_proj.is_ready = false
     AND v_proj.configuration_status = v_live->>'configuration_status' THEN
    INSERT INTO test_results VALUES ('T1 projection matches live not-ready', 'PASS', v_proj.blocking_reasons::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T1 projection matches live not-ready', 'FAIL',
      format('proj=%s live=%s', row_to_json(v_proj), v_live)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T1 projection matches live not-ready', 'FAIL', SQLERRM);
END $$;

-- T2: add cert → trigger refresh → ready; first transition emits UNBLOCKED
DO $$
DECLARE
  v_emp uuid;
  v_type uuid;
  v_cert uuid;
  v_ready boolean;
  v_audit int;
BEGIN
  SELECT employee_id, requirement_type_id INTO v_emp, v_type FROM test_ids;

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  PERFORM data.refresh_employee_readiness_projection(v_emp);

  RESET ROLE;
  DELETE FROM data.audit_logs
  WHERE entity_id = v_emp
    AND action IN ('EMPLOYEE_UNBLOCKED', 'EMPLOYEE_BLOCKED_DUE_TO_COMPLIANCE');

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT (api.upsert_employee_certification(
    NULL, v_emp, v_type, 'cr2c', NULL, CURRENT_DATE,
    CURRENT_DATE, CURRENT_DATE + 365, NULL, 'cr2c_cert'
  )).id INTO v_cert;

  UPDATE test_ids SET certification_id = v_cert;

  RESET ROLE;
  SELECT is_ready INTO v_ready
  FROM data.employee_readiness_projection WHERE employee_id = v_emp;

  SELECT count(*) INTO v_audit
  FROM data.audit_logs
  WHERE entity_id = v_emp AND action = 'EMPLOYEE_UNBLOCKED';

  IF v_ready = true AND v_audit >= 1 THEN
    INSERT INTO test_results VALUES (
      'T2 cert triggers UNBLOCKED', 'PASS',
      format('audit=%s', v_audit)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T2 cert triggers UNBLOCKED', 'FAIL',
      format('ready=%s audit=%s', v_ready, v_audit)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 cert triggers UNBLOCKED', 'FAIL', SQLERRM);
END $$;

-- T3: re-refresh does not duplicate BLOCKED/UNBLOCKED
DO $$
DECLARE
  v_emp uuid;
  v_before int;
  v_after int;
BEGIN
  SELECT employee_id INTO v_emp FROM test_ids;

  RESET ROLE;
  SELECT count(*) INTO v_before
  FROM data.audit_logs
  WHERE entity_id = v_emp
    AND action IN ('EMPLOYEE_UNBLOCKED', 'EMPLOYEE_BLOCKED_DUE_TO_COMPLIANCE');

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  PERFORM data.refresh_employee_readiness_projection(v_emp);
  PERFORM data.refresh_employee_readiness_projection(v_emp);

  RESET ROLE;
  SELECT count(*) INTO v_after
  FROM data.audit_logs
  WHERE entity_id = v_emp
    AND action IN ('EMPLOYEE_UNBLOCKED', 'EMPLOYEE_BLOCKED_DUE_TO_COMPLIANCE');

  IF v_before = v_after THEN
    INSERT INTO test_results VALUES ('T3 no duplicate transition events', 'PASS', format('count=%s', v_after));
  ELSE
    INSERT INTO test_results VALUES (
      'T3 no duplicate transition events', 'FAIL',
      format('before=%s after=%s', v_before, v_after)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 no duplicate transition events', 'FAIL', SQLERRM);
END $$;

-- T4: revoke cert → BLOCKED
DO $$
DECLARE
  v_emp uuid;
  v_cert uuid;
  v_ready boolean;
  v_audit int;
BEGIN
  SELECT employee_id, certification_id INTO v_emp, v_cert FROM test_ids;

  RESET ROLE;
  DELETE FROM data.audit_logs
  WHERE entity_id = v_emp AND action = 'EMPLOYEE_BLOCKED_DUE_TO_COMPLIANCE';

  UPDATE data.employee_certifications
  SET revoked_at = now(), revoked_reason = 'cr2c_test'
  WHERE id = v_cert;

  SELECT is_ready INTO v_ready
  FROM data.employee_readiness_projection WHERE employee_id = v_emp;

  SELECT count(*) INTO v_audit
  FROM data.audit_logs
  WHERE entity_id = v_emp AND action = 'EMPLOYEE_BLOCKED_DUE_TO_COMPLIANCE';

  IF v_ready = false AND v_audit >= 1 THEN
    INSERT INTO test_results VALUES ('T4 revoke emits BLOCKED', 'PASS', format('audit=%s', v_audit));
  ELSE
    INSERT INTO test_results VALUES (
      'T4 revoke emits BLOCKED', 'FAIL',
      format('ready=%s audit=%s', v_ready, v_audit)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T4 revoke emits BLOCKED', 'FAIL', SQLERRM);
END $$;

-- T5: convergence — refresh all then compare projection vs live for test emp
DO $$
DECLARE
  v_emp uuid;
  v_live jsonb;
  v_proj data.employee_readiness_projection;
BEGIN
  SELECT employee_id INTO v_emp FROM test_ids;
  PERFORM data.refresh_employee_readiness_projection(v_emp);
  v_live := data.compute_employee_readiness(v_emp, CURRENT_DATE);
  SELECT * INTO v_proj FROM data.employee_readiness_projection WHERE employee_id = v_emp;

  IF v_proj.is_ready = (v_live->>'is_ready')::boolean
     AND v_proj.configuration_status = v_live->>'configuration_status'
     AND v_proj.blocking_reasons = coalesce(v_live->'blocking_reasons', '[]'::jsonb) THEN
    INSERT INTO test_results VALUES ('T5 convergence live vs projection', 'PASS', 'ok');
  ELSE
    INSERT INTO test_results VALUES (
      'T5 convergence live vs projection', 'FAIL',
      format('proj_ready=%s live=%s', v_proj.is_ready, v_live)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 convergence live vs projection', 'FAIL', SQLERRM);
END $$;

-- T6: summary RPC
DO $$
DECLARE
  v_rep jsonb;
BEGIN
  v_rep := api.get_employee_readiness_projection_summary(CURRENT_DATE);
  IF (v_rep->>'total_employees')::int >= 1
     AND v_rep ? 'ready'
     AND v_rep ? 'not_ready' THEN
    INSERT INTO test_results VALUES ('T6 summary RPC', 'PASS', v_rep::text);
  ELSE
    INSERT INTO test_results VALUES ('T6 summary RPC', 'FAIL', v_rep::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 summary RPC', 'FAIL', SQLERRM);
END $$;

-- T7: multi-tenant guard on refresh
DO $$
DECLARE
  v_emp uuid;
  v_ok boolean := false;
BEGIN
  SELECT employee_id INTO v_emp FROM test_ids;
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000002"}', true);
  BEGIN
    PERFORM data.refresh_employee_readiness_projection(v_emp);
  EXCEPTION WHEN no_data_found THEN
    v_ok := true;
  END;
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T7 multi-tenant refresh denied', 'PASS', 'employee_not_found');
  ELSE
    INSERT INTO test_results VALUES ('T7 multi-tenant refresh denied', 'FAIL', 'expected no_data_found');
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T7 multi-tenant refresh denied', 'FAIL', SQLERRM);
END $$;

SELECT test_name, status, left(details, 160) AS details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'CR-2c tests failed: %', v_fail;
  END IF;
END $$;

ROLLBACK;
