-- M-CR-2b readiness multi-scope tests
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
  job_a uuid,
  job_b uuid,
  site_id uuid,
  type_prl uuid,
  type_height uuid,
  rule_job uuid,
  rule_site uuid,
  contract_id uuid
) ON COMMIT DROP;

INSERT INTO test_ids DEFAULT VALUES;

RESET ROLE;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_owner  uuid := '20000000-0000-0000-0000-000000000002';
  v_emp uuid;
  v_job_a uuid;
  v_job_b uuid;
  v_site uuid := '30000000-0000-0000-0000-000000000001';
  v_prl uuid;
  v_height uuid;
  v_rule_job uuid;
  v_rule_site uuid;
BEGIN
  -- cleanup prior runs
  DELETE FROM data.employee_certifications
  WHERE employee_id IN (
    SELECT id FROM data.employees WHERE full_name = 'CR2B Scope Emp'
  );
  DELETE FROM data.employment_contracts
  WHERE employee_id IN (
    SELECT id FROM data.employees WHERE full_name = 'CR2B Scope Emp'
  );
  DELETE FROM data.compliance_requirement_rules
  WHERE tenant_id = v_tenant AND created_by = v_owner
    AND scope_type IN ('job_position', 'site')
    AND id IN (
      SELECT id FROM data.compliance_requirement_rules r
      WHERE r.tenant_id = v_tenant
        AND r.scope_type IN ('job_position', 'site')
        AND EXISTS (
          SELECT 1 FROM data.job_positions jp
          WHERE jp.id = r.scope_id AND jp.name LIKE 'CR2B-%'
        )
    );
  DELETE FROM data.job_positions WHERE tenant_id = v_tenant AND name LIKE 'CR2B-%';
  DELETE FROM data.employees WHERE tenant_id = v_tenant AND full_name = 'CR2B Scope Emp';

  SELECT id INTO v_prl FROM data.compliance_requirement_types WHERE code = 'PRL_BASIC' LIMIT 1;
  SELECT id INTO v_height FROM data.compliance_requirement_types WHERE code = 'HEIGHT_WORK' LIMIT 1;

  INSERT INTO data.job_positions (tenant_id, name, code, is_active)
  VALUES (v_tenant, 'CR2B-Job-A', 'CR2B_A', true)
  RETURNING id INTO v_job_a;

  INSERT INTO data.job_positions (tenant_id, name, code, is_active)
  VALUES (v_tenant, 'CR2B-Job-B', 'CR2B_B', true)
  RETURNING id INTO v_job_b;

  INSERT INTO data.employees (
    tenant_id, full_name, status, weekly_hours, site_id, job_position_id
  ) VALUES (
    v_tenant, 'CR2B Scope Emp', 'active', 40, NULL, NULL
  ) RETURNING id INTO v_emp;

  INSERT INTO data.compliance_requirement_rules (
    tenant_id, requirement_type_id, scope_type, scope_id,
    is_blocking, grace_period_days, is_active, created_by
  ) VALUES (
    v_tenant, v_prl, 'job_position', v_job_a, true, 0, true, v_owner
  ) RETURNING id INTO v_rule_job;

  INSERT INTO data.compliance_requirement_rules (
    tenant_id, requirement_type_id, scope_type, scope_id,
    is_blocking, grace_period_days, is_active, created_by
  ) VALUES (
    v_tenant, v_height, 'site', v_site, true, 0, true, v_owner
  ) RETURNING id INTO v_rule_site;

  UPDATE test_ids SET
    employee_id = v_emp,
    job_a = v_job_a,
    job_b = v_job_b,
    site_id = v_site,
    type_prl = v_prl,
    type_height = v_height,
    rule_job = v_rule_job,
    rule_site = v_rule_site;
END $$;

-- Mutations as postgres; compute under JWT (SECURITY DEFINER uses active_tenant)

-- T1: no matching scope → ready (partial if scoped rules exist and scopes NULL)
DO $$
DECLARE
  v_emp uuid;
  v_res jsonb;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT employee_id INTO v_emp FROM test_ids;
  v_res := data.compute_employee_readiness(v_emp, CURRENT_DATE);

  IF (v_res ->> 'is_ready')::boolean = true
     AND v_res ->> 'configuration_status' = 'partial'
     AND v_res ->> 'scope_source' = 'employee_flat' THEN
    INSERT INTO test_results VALUES ('T1 no-scope partial ready', 'PASS', v_res::text);
  ELSE
    INSERT INTO test_results VALUES ('T1 no-scope partial ready', 'FAIL', coalesce(v_res::text, 'null'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T1 no-scope partial ready', 'FAIL', SQLERRM);
END $$;

-- T2: flat job_position matches → blocks without cert
DO $$
DECLARE
  v_emp uuid;
  v_job uuid;
  v_res jsonb;
BEGIN
  SELECT employee_id, job_a INTO v_emp, v_job FROM test_ids;
  UPDATE data.employees SET job_position_id = v_job WHERE id = v_emp;

  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
  v_res := data.compute_employee_readiness(v_emp, CURRENT_DATE);

  IF (v_res ->> 'is_ready')::boolean = false
     AND (v_res -> 'blocking_reasons')::text LIKE '%PRL_BASIC%'
     AND v_res #>> '{resolved_scope,job_position_id}' = v_job::text THEN
    INSERT INTO test_results VALUES ('T2 flat job blocks', 'PASS', v_res::text);
  ELSE
    INSERT INTO test_results VALUES ('T2 flat job blocks', 'FAIL', coalesce(v_res::text, 'null'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 flat job blocks', 'FAIL', SQLERRM);
END $$;

-- T3: contract governa job_position (flat = A, contract = B → no PRL block)
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_emp uuid;
  v_job_a uuid;
  v_job_b uuid;
  v_cid uuid;
  v_res jsonb;
BEGIN
  SELECT employee_id, job_a, job_b INTO v_emp, v_job_a, v_job_b FROM test_ids;

  UPDATE data.employees SET job_position_id = v_job_a, site_id = NULL WHERE id = v_emp;

  INSERT INTO data.employment_contracts (
    tenant_id, employee_id, contract_number, source,
    lifecycle_status, approval_status, signature_requirement, signature_status,
    is_primary, starts_on, ends_on, weekly_hours, job_position_id, site_id
  ) VALUES (
    v_tenant, v_emp, 'CR2B-CTR-1', 'manual',
    'active', 'not_required', 'none', 'not_required',
    true, CURRENT_DATE - 1, NULL, 40, v_job_b, NULL
  ) RETURNING id INTO v_cid;

  UPDATE test_ids SET contract_id = v_cid;

  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
  v_res := data.compute_employee_readiness(v_emp, CURRENT_DATE);

  IF (v_res ->> 'is_ready')::boolean = true
     AND v_res ->> 'scope_source' = 'employment_contract'
     AND v_res #>> '{resolved_scope,job_position_id}' = v_job_b::text THEN
    INSERT INTO test_results VALUES ('T3 contract overrides flat job', 'PASS', v_res::text);
  ELSE
    INSERT INTO test_results VALUES ('T3 contract overrides flat job', 'FAIL', coalesce(v_res::text, 'null'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 contract overrides flat job', 'FAIL', SQLERRM);
END $$;

-- T4: multi-scope OR — site rule + job A on contract → both can block
DO $$
DECLARE
  v_emp uuid;
  v_job_a uuid;
  v_site uuid;
  v_cid uuid;
  v_res jsonb;
BEGIN
  SELECT employee_id, job_a, site_id, contract_id
  INTO v_emp, v_job_a, v_site, v_cid FROM test_ids;

  UPDATE data.employment_contracts
  SET job_position_id = v_job_a, site_id = v_site
  WHERE id = v_cid;

  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
  v_res := data.compute_employee_readiness(v_emp, CURRENT_DATE);

  IF (v_res ->> 'is_ready')::boolean = false
     AND (v_res -> 'blocking_reasons')::text LIKE '%PRL_BASIC%'
     AND (v_res -> 'blocking_reasons')::text LIKE '%HEIGHT_WORK%' THEN
    INSERT INTO test_results VALUES ('T4 multi-scope OR both block', 'PASS', v_res::text);
  ELSE
    INSERT INTO test_results VALUES ('T4 multi-scope OR both block', 'FAIL', coalesce(v_res::text, 'null'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T4 multi-scope OR both block', 'FAIL', SQLERRM);
END $$;

-- T5: as_of before contract starts → flat fallback
DO $$
DECLARE
  v_emp uuid;
  v_job_a uuid;
  v_job_b uuid;
  v_cid uuid;
  v_res jsonb;
  v_future date := CURRENT_DATE + 30;
BEGIN
  SELECT employee_id, job_a, job_b, contract_id
  INTO v_emp, v_job_a, v_job_b, v_cid FROM test_ids;

  UPDATE data.employees SET job_position_id = v_job_a, site_id = NULL WHERE id = v_emp;
  UPDATE data.employment_contracts
  SET lifecycle_status = 'scheduled',
      starts_on = v_future,
      job_position_id = v_job_b,
      site_id = NULL,
      activated_at = NULL
  WHERE id = v_cid;

  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  v_res := data.compute_employee_readiness(v_emp, CURRENT_DATE);
  IF NOT (
    (v_res ->> 'is_ready')::boolean = false
    AND v_res ->> 'scope_source' = 'employee_flat'
    AND (v_res -> 'blocking_reasons')::text LIKE '%PRL_BASIC%'
  ) THEN
    INSERT INTO test_results VALUES ('T5 as_of before contract', 'FAIL', 'today=' || coalesce(v_res::text, 'null'));
    RETURN;
  END IF;

  v_res := data.compute_employee_readiness(v_emp, v_future);
  IF (v_res ->> 'is_ready')::boolean = true
     AND v_res ->> 'scope_source' = 'employment_contract'
     AND v_res #>> '{resolved_scope,job_position_id}' = v_job_b::text THEN
    INSERT INTO test_results VALUES ('T5 as_of before contract', 'PASS', 'future_ok');
  ELSE
    INSERT INTO test_results VALUES ('T5 as_of before contract', 'FAIL', 'future=' || coalesce(v_res::text, 'null'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 as_of before contract', 'FAIL', SQLERRM);
END $$;

-- T6: cert satisfies job rule
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_emp uuid;
  v_job_a uuid;
  v_prl uuid;
  v_cid uuid;
  v_res jsonb;
BEGIN
  SELECT employee_id, job_a, type_prl, contract_id
  INTO v_emp, v_job_a, v_prl, v_cid FROM test_ids;

  UPDATE data.employees SET job_position_id = v_job_a, site_id = NULL WHERE id = v_emp;
  UPDATE data.employment_contracts
  SET lifecycle_status = 'active',
      starts_on = CURRENT_DATE - 1,
      job_position_id = v_job_a,
      site_id = NULL,
      activated_at = now()
  WHERE id = v_cid;

  INSERT INTO data.employee_certifications (
    tenant_id, employee_id, requirement_type_id,
    valid_from, valid_until, created_by
  ) VALUES (
    v_tenant, v_emp, v_prl, CURRENT_DATE - 10, CURRENT_DATE + 365, v_owner
  );

  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
  v_res := data.compute_employee_readiness(v_emp, CURRENT_DATE);

  IF (v_res ->> 'is_ready')::boolean = true
     AND NOT ((v_res -> 'blocking_reasons')::text LIKE '%PRL_BASIC%') THEN
    INSERT INTO test_results VALUES ('T6 cert satisfies job rule', 'PASS', v_res::text);
  ELSE
    INSERT INTO test_results VALUES ('T6 cert satisfies job rule', 'FAIL', coalesce(v_res::text, 'null'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 cert satisfies job rule', 'FAIL', SQLERRM);
END $$;

-- Cleanup
RESET ROLE;
DO $$
DECLARE
  v_emp uuid;
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
BEGIN
  SELECT employee_id INTO v_emp FROM test_ids;

  DELETE FROM data.employee_certifications WHERE employee_id = v_emp;
  DELETE FROM data.employment_contract_notice_log
  WHERE contract_id IN (SELECT id FROM data.employment_contracts WHERE employee_id = v_emp);
  DELETE FROM data.employment_contracts WHERE employee_id = v_emp;
  DELETE FROM data.compliance_requirement_rules
  WHERE id IN (SELECT rule_job FROM test_ids UNION SELECT rule_site FROM test_ids);
  DELETE FROM data.employees WHERE id = v_emp;
  DELETE FROM data.job_positions WHERE tenant_id = v_tenant AND name LIKE 'CR2B-%';

  INSERT INTO test_results VALUES ('T7 cleanup', 'PASS', 'ok');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T7 cleanup', 'FAIL', SQLERRM);
END $$;

SELECT * FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  RAISE NOTICE 'M-CR-2b readiness scopes: % PASS, % FAIL',
    (SELECT count(*) FROM test_results WHERE status = 'PASS'),
    v_fail;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'M-CR-2b readiness scopes tests failed';
  END IF;
END $$;

ROLLBACK;
