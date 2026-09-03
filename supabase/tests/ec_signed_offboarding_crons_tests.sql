-- =============================================================================
-- EC items 3-5: CONTRACT_FULLY_SIGNED + Offboarding blueprint + cron verify
-- =============================================================================
BEGIN;
SET client_min_messages TO WARNING;

CREATE TEMP TABLE test_results (
  test_name text PRIMARY KEY,
  status text NOT NULL,
  details text
) ON COMMIT DROP;

-- T1: platform blueprint 'Contracte — signat' (CONTRACT_FULLY_SIGNED)
DO $$
DECLARE
  v_trigger text;
  v_active boolean;
BEGIN
  SELECT trigger_event, is_active INTO v_trigger, v_active
  FROM data.automation_workflows
  WHERE is_blueprint = true AND tenant_id IS NULL AND name = 'Contracte — signat';

  IF v_trigger = 'CONTRACT_FULLY_SIGNED' AND v_active THEN
    INSERT INTO test_results VALUES ('T1 fully_signed_blueprint', 'PASS', v_trigger);
  ELSE
    INSERT INTO test_results VALUES ('T1 fully_signed_blueprint', 'FAIL',
      format('trigger=%s active=%s', v_trigger, v_active));
  END IF;
END $$;

-- T2: platform blueprint 'Offboarding d'empleats' (EMPLOYEE_LIFECYCLE_CHANGED to=offboarding)
DO $$
DECLARE
  v_trigger text;
  v_filters jsonb;
  v_active boolean;
BEGIN
  SELECT trigger_event, trigger_filters, is_active
  INTO v_trigger, v_filters, v_active
  FROM data.automation_workflows
  WHERE is_blueprint = true AND tenant_id IS NULL AND name = 'Offboarding d''empleats';

  IF v_trigger = 'EMPLOYEE_LIFECYCLE_CHANGED'
     AND (v_filters ->> 'to') = 'offboarding'
     AND v_active
  THEN
    INSERT INTO test_results VALUES ('T2 offboarding_blueprint', 'PASS',
      format('trigger=%s filters=%s', v_trigger, v_filters));
  ELSE
    INSERT INTO test_results VALUES ('T2 offboarding_blueprint', 'FAIL',
      format('trigger=%s filters=%s active=%s', v_trigger, v_filters, v_active));
  END IF;
END $$;

-- T3: emit_employment_contract_fully_signed is idempotent + logs notice
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_emp uuid;
  v_cid uuid;
  v_first boolean;
  v_second boolean;
  v_notice_count int;
BEGIN
  DELETE FROM data.employment_contract_notice_log
  WHERE contract_id IN (
    SELECT id FROM data.employment_contracts
    WHERE tenant_id = v_tenant AND contract_number = 'EC-SIGNED-T3'
  );
  DELETE FROM data.employment_contracts
  WHERE tenant_id = v_tenant AND contract_number = 'EC-SIGNED-T3';
  DELETE FROM data.employees
  WHERE tenant_id = v_tenant AND full_name = 'EC-SIGNED T3 Emp';

  INSERT INTO data.employees (
    tenant_id, full_name, status, lifecycle_state, weekly_hours, starts_on
  ) VALUES (
    v_tenant, 'EC-SIGNED T3 Emp', 'inactive', 'onboarding', 40, CURRENT_DATE
  ) RETURNING id INTO v_emp;

  INSERT INTO data.employment_contracts (
    tenant_id, employee_id, contract_number, source,
    lifecycle_status, approval_status, signature_requirement, signature_status,
    is_primary, starts_on, ends_on, weekly_hours, fully_signed_at
  ) VALUES (
    v_tenant, v_emp, 'EC-SIGNED-T3', 'manual',
    'draft', 'approved', 'employee_and_employer', 'completed',
    true, CURRENT_DATE, CURRENT_DATE + 90, 40, now()
  ) RETURNING id INTO v_cid;

  v_first := data.emit_employment_contract_fully_signed(v_cid);
  v_second := data.emit_employment_contract_fully_signed(v_cid);

  SELECT count(*) INTO v_notice_count
  FROM data.employment_contract_notice_log
  WHERE contract_id = v_cid AND notice_kind = 'fully_signed';

  IF v_first = true AND v_second = false AND v_notice_count = 1 THEN
    INSERT INTO test_results VALUES ('T3 emit_fully_signed_idempotent', 'PASS',
      format('first=%s second=%s notices=%s', v_first, v_second, v_notice_count));
  ELSE
    INSERT INTO test_results VALUES ('T3 emit_fully_signed_idempotent', 'FAIL',
      format('first=%s second=%s notices=%s', v_first, v_second, v_notice_count));
  END IF;

  DELETE FROM data.employment_contract_notice_log WHERE contract_id = v_cid;
  DELETE FROM data.employment_contracts WHERE id = v_cid;
  DELETE FROM data.employees WHERE id = v_emp;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 emit_fully_signed_idempotent', 'FAIL', SQLERRM);
END $$;

-- T4: api.verify_employee_domain_crons returns 8 expected jobs (owner JWT)
DO $$
DECLARE
  v_res jsonb;
  v_total int;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  v_res := api.verify_employee_domain_crons();
  v_total := (v_res ->> 'expected_total')::int;

  IF v_total = 8
     AND (v_res ? 'pg_cron_installed')
     AND (v_res ? 'missing_total')
  THEN
    INSERT INTO test_results VALUES ('T4 verify_crons', 'PASS',
      format('total=%s pg_cron=%s missing=%s', v_total, v_res ->> 'pg_cron_installed', v_res ->> 'missing_total'));
  ELSE
    INSERT INTO test_results VALUES ('T4 verify_crons', 'FAIL', v_res::text);
  END IF;

  PERFORM set_config('request.jwt.claim', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.headers', '', true);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T4 verify_crons', 'FAIL', SQLERRM);
END $$;

-- T5: install helper installs the two new blueprints for a tenant
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000002';
  v_res jsonb;
  v_has_signed boolean;
  v_has_offb boolean;
BEGIN
  v_res := data.install_ec_platform_blueprints_for_tenant(v_tenant, NULL);

  SELECT EXISTS (
    SELECT 1 FROM data.automation_workflows
    WHERE tenant_id = v_tenant AND is_blueprint = false
      AND trigger_event = 'CONTRACT_FULLY_SIGNED'
  ) INTO v_has_signed;

  SELECT EXISTS (
    SELECT 1 FROM data.automation_workflows
    WHERE tenant_id = v_tenant AND is_blueprint = false
      AND name = 'Offboarding d''empleats'
  ) INTO v_has_offb;

  IF v_has_signed AND v_has_offb THEN
    INSERT INTO test_results VALUES ('T5 install_new_blueprints', 'PASS', v_res::text);
  ELSE
    INSERT INTO test_results VALUES ('T5 install_new_blueprints', 'FAIL',
      format('signed=%s offb=%s res=%s', v_has_signed, v_has_offb, v_res));
  END IF;
END $$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

ROLLBACK;
