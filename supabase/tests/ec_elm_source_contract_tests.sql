-- =============================================================================
-- EC ↔ ELM source='contract' + install EC blueprints
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
  emp_id uuid,
  contract_id uuid,
  emp2_id uuid,
  contract2_id uuid,
  successor_id uuid
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

-- Cleanup prior runs
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
BEGIN
  DELETE FROM data.employee_lifecycle_events
  WHERE employee_id IN (
    SELECT id FROM data.employees
    WHERE tenant_id = v_tenant
      AND full_name LIKE 'EC-ELM %'
  );
  DELETE FROM data.employment_contract_notice_log
  WHERE contract_id IN (
    SELECT id FROM data.employment_contracts
    WHERE tenant_id = v_tenant AND contract_number LIKE 'EC-ELM-%'
  );
  DELETE FROM data.employment_contracts
  WHERE tenant_id = v_tenant AND contract_number LIKE 'EC-ELM-%';
  DELETE FROM data.employees
  WHERE tenant_id = v_tenant AND full_name LIKE 'EC-ELM %';
END $$;

-- T1: activate primary while onboarding → active + source=contract
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_emp uuid;
  v_cid uuid;
  v_state text;
  v_src text;
  v_reason text;
BEGIN
  INSERT INTO data.employees (
    tenant_id, full_name, status, lifecycle_state, weekly_hours, starts_on
  ) VALUES (
    v_tenant, 'EC-ELM Onboard Emp', 'inactive', 'onboarding', 40, CURRENT_DATE
  ) RETURNING id INTO v_emp;

  INSERT INTO data.employment_contracts (
    tenant_id, employee_id, contract_number, source,
    lifecycle_status, approval_status, signature_requirement, signature_status,
    is_primary, starts_on, ends_on, weekly_hours
  ) VALUES (
    v_tenant, v_emp, 'EC-ELM-ACT', 'manual',
    'draft', 'not_required', 'none', 'not_required',
    true, CURRENT_DATE, CURRENT_DATE + 90, 40
  ) RETURNING id INTO v_cid;

  UPDATE test_ids SET emp_id = v_emp, contract_id = v_cid;

  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  PERFORM api.transition_employment_contract(v_cid, 'active', NULL);

  SELECT lifecycle_state INTO v_state FROM data.employees WHERE id = v_emp;
  SELECT source, reason_code INTO v_src, v_reason
  FROM data.employee_lifecycle_events
  WHERE employee_id = v_emp
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_state = 'active'
     AND v_src = 'contract'
     AND v_reason = 'first_contract_activated'
  THEN
    INSERT INTO test_results VALUES (
      'T1 activate_onboarding_to_active',
      'PASS',
      format('state=%s src=%s reason=%s', v_state, v_src, v_reason)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T1 activate_onboarding_to_active',
      'FAIL',
      format('state=%s src=%s reason=%s', v_state, v_src, v_reason)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T1 activate_onboarding_to_active', 'FAIL', SQLERRM);
END $$;

-- T2: end primary without successor → departure + source=contract
DO $$
DECLARE
  v_emp uuid;
  v_cid uuid;
  v_state text;
  v_src text;
  v_reason text;
BEGIN
  SELECT emp_id, contract_id INTO v_emp, v_cid FROM test_ids;

  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  PERFORM api.transition_employment_contract(v_cid, 'ended', 'smoke end');

  SELECT lifecycle_state INTO v_state FROM data.employees WHERE id = v_emp;
  SELECT source, reason_code INTO v_src, v_reason
  FROM data.employee_lifecycle_events
  WHERE employee_id = v_emp
    AND to_state = 'departure'
    AND source = 'contract'
  ORDER BY created_at DESC, id DESC
  LIMIT 1;

  IF v_state = 'departure'
     AND v_src = 'contract'
     AND v_reason = 'contract_ended_without_renewal'
  THEN
    INSERT INTO test_results VALUES (
      'T2 end_without_successor_departure',
      'PASS',
      format('state=%s src=%s reason=%s', v_state, v_src, v_reason)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T2 end_without_successor_departure',
      'FAIL',
      format('state=%s src=%s reason=%s', v_state, v_src, v_reason)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 end_without_successor_departure', 'FAIL', SQLERRM);
END $$;

-- T3: end with scheduled successor → no ELM departure
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_emp uuid;
  v_cid uuid;
  v_succ uuid;
  v_state text;
  v_elm jsonb;
BEGIN
  INSERT INTO data.employees (
    tenant_id, full_name, status, lifecycle_state, weekly_hours, starts_on
  ) VALUES (
    v_tenant, 'EC-ELM Renew Emp', 'active', 'active', 40, CURRENT_DATE - 30
  ) RETURNING id INTO v_emp;

  INSERT INTO data.employment_contracts (
    tenant_id, employee_id, contract_number, source,
    lifecycle_status, approval_status, signature_requirement, signature_status,
    is_primary, starts_on, ends_on, weekly_hours, ended_at
  ) VALUES (
    v_tenant, v_emp, 'EC-ELM-OLD', 'manual',
    'ended', 'not_required', 'none', 'not_required',
    true, CURRENT_DATE - 30, CURRENT_DATE - 1, 40, now()
  ) RETURNING id INTO v_cid;

  INSERT INTO data.employment_contracts (
    tenant_id, employee_id, contract_number, source,
    lifecycle_status, approval_status, signature_requirement, signature_status,
    is_primary, starts_on, ends_on, weekly_hours
  ) VALUES (
    v_tenant, v_emp, 'EC-ELM-NEW', 'manual',
    'scheduled', 'approved', 'none', 'not_required',
    true, CURRENT_DATE, CURRENT_DATE + 180, 40
  ) RETURNING id INTO v_succ;

  UPDATE test_ids SET emp2_id = v_emp, contract2_id = v_cid, successor_id = v_succ;

  v_elm := data.apply_contract_employee_lifecycle(v_cid, 'ended', CURRENT_DATE, NULL);
  SELECT lifecycle_state INTO v_state FROM data.employees WHERE id = v_emp;

  IF coalesce((v_elm ->> 'applied')::boolean, true) = false
     AND (v_elm ->> 'reason') = 'has_successor_contract'
     AND v_state = 'active'
  THEN
    INSERT INTO test_results VALUES (
      'T3 end_with_successor_skips_elm',
      'PASS',
      v_elm::text
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T3 end_with_successor_skips_elm',
      'FAIL',
      format('state=%s elm=%s', v_state, v_elm)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 end_with_successor_skips_elm', 'FAIL', SQLERRM);
END $$;

-- T4: reconcile activates scheduled onboarding employee → ELM
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_emp uuid;
  v_cid uuid;
  v_res jsonb;
  v_state text;
  v_src text;
BEGIN
  INSERT INTO data.employees (
    tenant_id, full_name, status, lifecycle_state, weekly_hours, starts_on
  ) VALUES (
    v_tenant, 'EC-ELM Reconcile Emp', 'inactive', 'onboarding', 40, CURRENT_DATE - 2
  ) RETURNING id INTO v_emp;

  INSERT INTO data.employment_contracts (
    tenant_id, employee_id, contract_number, source,
    lifecycle_status, approval_status, signature_requirement, signature_status,
    is_primary, starts_on, ends_on, weekly_hours
  ) VALUES (
    v_tenant, v_emp, 'EC-ELM-REC', 'manual',
    'scheduled', 'approved', 'none', 'not_required',
    true, CURRENT_DATE - 1, CURRENT_DATE + 60, 40
  ) RETURNING id INTO v_cid;

  v_res := data.reconcile_employment_contracts_for_tenant(v_tenant, CURRENT_DATE);
  SELECT lifecycle_state INTO v_state FROM data.employees WHERE id = v_emp;
  SELECT source INTO v_src
  FROM data.employee_lifecycle_events
  WHERE employee_id = v_emp AND reason_code = 'first_contract_activated'
  ORDER BY created_at DESC
  LIMIT 1;

  IF coalesce((v_res ->> 'activated')::int, 0) >= 1
     AND coalesce((v_res ->> 'elm_activated')::int, 0) >= 1
     AND v_state = 'active'
     AND v_src = 'contract'
  THEN
    INSERT INTO test_results VALUES (
      'T4 reconcile_activates_elm',
      'PASS',
      v_res::text
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T4 reconcile_activates_elm',
      'FAIL',
      format('state=%s src=%s res=%s', v_state, v_src, v_res)
    );
  END IF;

  DELETE FROM data.employee_lifecycle_events WHERE employee_id = v_emp;
  DELETE FROM data.employment_contract_notice_log WHERE contract_id = v_cid;
  DELETE FROM data.employment_contracts WHERE id = v_cid;
  DELETE FROM data.employees WHERE id = v_emp;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T4 reconcile_activates_elm', 'FAIL', SQLERRM);
END $$;

-- T5: install EC blueprints for Acme (idempotent)
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_res1 jsonb;
  v_res2 jsonb;
  v_count int;
BEGIN
  v_res1 := data.install_ec_platform_blueprints_for_tenant(v_tenant, NULL);
  v_res2 := data.install_ec_platform_blueprints_for_tenant(v_tenant, NULL);

  SELECT count(*)::int INTO v_count
  FROM data.automation_workflows
  WHERE tenant_id = v_tenant
    AND is_blueprint = false
    AND is_active = true
    AND (
      trigger_event IN (
        'CONTRACT_ACTIVATION_BLOCKED',
        'CONTRACT_ACTIVATED',
        'CONTRACT_EXPIRING',
        'CONTRACT_ENDED'
      )
      OR name = 'Onboarding d''empleats'
    );

  IF coalesce((v_res1 ->> 'installed')::int, 0) >= 1
     AND coalesce((v_res2 ->> 'installed')::int, 0) = 0
     AND v_count >= 5
  THEN
    INSERT INTO test_results VALUES (
      'T5 install_ec_blueprints_idempotent',
      'PASS',
      format('first=%s second=%s count=%s', v_res1, v_res2, v_count)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T5 install_ec_blueprints_idempotent',
      'FAIL',
      format('first=%s second=%s count=%s', v_res1, v_res2, v_count)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 install_ec_blueprints_idempotent', 'FAIL', SQLERRM);
END $$;

-- Cleanup T1/T2/T3 fixtures
DO $$
DECLARE
  v_emp uuid;
  v_emp2 uuid;
BEGIN
  SELECT emp_id, emp2_id INTO v_emp, v_emp2 FROM test_ids;

  IF v_emp IS NOT NULL THEN
    DELETE FROM data.employee_lifecycle_events WHERE employee_id = v_emp;
    DELETE FROM data.employment_contract_notice_log
    WHERE contract_id IN (SELECT id FROM data.employment_contracts WHERE employee_id = v_emp);
    DELETE FROM data.employment_contracts WHERE employee_id = v_emp;
    DELETE FROM data.employees WHERE id = v_emp;
  END IF;

  IF v_emp2 IS NOT NULL THEN
    DELETE FROM data.employee_lifecycle_events WHERE employee_id = v_emp2;
    DELETE FROM data.employment_contract_notice_log
    WHERE contract_id IN (SELECT id FROM data.employment_contracts WHERE employee_id = v_emp2);
    DELETE FROM data.employment_contracts WHERE employee_id = v_emp2;
    DELETE FROM data.employees WHERE id = v_emp2;
  END IF;
END $$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'ec_elm_source_contract_tests failed: % failures', v_fail;
  END IF;
END $$;

COMMIT;
