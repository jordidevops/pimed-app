-- EC-WFM P0 tests (baseline + consumers)
-- Acme tenant / Alice owner JWT; rolled back.
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
  dept_id uuid,
  site_gracia uuid,
  site_sants uuid,
  abs_id uuid,
  contract_id uuid,
  ent_tenant uuid,
  ent_dept uuid,
  ent_emp uuid,
  year int,
  alice_prev_hours numeric,
  alice_prev_site uuid
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

-- Setup: entitlements + dedicated employee snapshot
RESET ROLE;
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_alice  uuid := '40000000-0000-0000-0000-000000000001';
  v_dept   uuid;
  v_site_g uuid := '30000000-0000-0000-0000-000000000001';
  v_site_s uuid := '30000000-0000-0000-0000-000000000002';
  v_year   int := EXTRACT(YEAR FROM CURRENT_DATE)::int;
  v_ent_t  uuid;
  v_ent_d  uuid;
  v_ent_e  uuid;
  v_hours  numeric;
  v_site   uuid;
BEGIN
  SELECT department_id, weekly_hours, site_id
  INTO v_dept, v_hours, v_site
  FROM data.employees WHERE id = v_alice;

  -- Ensure Alice has a department for dept-scope entitlement
  IF v_dept IS NULL THEN
    v_dept := '43000000-0000-0000-0000-000000000001';
    UPDATE data.employees SET department_id = v_dept WHERE id = v_alice;
  END IF;

  DELETE FROM data.vacation_entitlements
  WHERE tenant_id = v_tenant AND year = v_year AND leave_type = 'vacation'
    AND (
      (scope = 'tenant')
      OR (scope = 'department' AND department_id = v_dept)
      OR (scope = 'employee' AND employee_id = v_alice)
    );

  INSERT INTO data.vacation_entitlements (
    tenant_id, scope, year, leave_type, days_allocated, days_used
  ) VALUES (v_tenant, 'tenant', v_year, 'vacation', 22, 0)
  RETURNING id INTO v_ent_t;

  INSERT INTO data.vacation_entitlements (
    tenant_id, scope, department_id, year, leave_type, days_allocated, days_used
  ) VALUES (v_tenant, 'department', v_dept, v_year, 'vacation', 25, 0)
  RETURNING id INTO v_ent_d;

  INSERT INTO data.vacation_entitlements (
    tenant_id, scope, employee_id, year, leave_type, days_allocated, days_used
  ) VALUES (v_tenant, 'employee', v_alice, v_year, 'vacation', 30, 0)
  RETURNING id INTO v_ent_e;

  -- Cancel overlapping test contracts from prior runs
  UPDATE data.employment_contracts
  SET lifecycle_status = 'cancelled', cancelled_at = now(), cancellation_reason = 'ec-wfm-p0-cleanup'
  WHERE employee_id = v_alice AND contract_number LIKE 'EC-WFM-P0-%'
    AND lifecycle_status IN ('draft', 'scheduled', 'active', 'ended');

  UPDATE test_ids SET
    emp_id = v_alice,
    dept_id = v_dept,
    site_gracia = v_site_g,
    site_sants = v_site_s,
    ent_tenant = v_ent_t,
    ent_dept = v_ent_d,
    ent_emp = v_ent_e,
    year = v_year,
    alice_prev_hours = v_hours,
    alice_prev_site = v_site;
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

-- T1: multi-scope entitlements — only employee scope increments on approve
RESET ROLE;
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_alice  uuid;
  v_abs    uuid;
  v_used_e numeric;
  v_used_d numeric;
  v_used_t numeric;
  v_start  date;
  v_end    date;
BEGIN
  SELECT emp_id INTO v_alice FROM test_ids;
  v_start := make_date((SELECT year FROM test_ids), 8, 10);
  v_end   := v_start + 2; -- 3 days

  INSERT INTO data.employee_absences (
    tenant_id, employee_id, absence_type, start_date, end_date, status
  ) VALUES (
    v_tenant, v_alice, 'vacation', v_start, v_end, 'requested'
  ) RETURNING id INTO v_abs;

  UPDATE test_ids SET abs_id = v_abs;

  UPDATE data.employee_absences SET status = 'approved' WHERE id = v_abs;

  SELECT days_used INTO v_used_e FROM data.vacation_entitlements WHERE id = (SELECT ent_emp FROM test_ids);
  SELECT days_used INTO v_used_d FROM data.vacation_entitlements WHERE id = (SELECT ent_dept FROM test_ids);
  SELECT days_used INTO v_used_t FROM data.vacation_entitlements WHERE id = (SELECT ent_tenant FROM test_ids);

  IF v_used_e = 3 AND v_used_d = 0 AND v_used_t = 0 THEN
    INSERT INTO test_results VALUES ('T1 multi-scope only employee increments', 'PASS',
      format('emp=%s dept=%s tenant=%s', v_used_e, v_used_d, v_used_t));
  ELSE
    INSERT INTO test_results VALUES ('T1 multi-scope only employee increments', 'FAIL',
      format('emp=%s dept=%s tenant=%s expected emp=3 others=0', v_used_e, v_used_d, v_used_t));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T1 multi-scope only employee increments', 'FAIL', SQLERRM);
END $$;

-- T2: cancel approved vacation decrements
DO $$
DECLARE
  v_abs uuid;
  v_used numeric;
BEGIN
  SELECT abs_id INTO v_abs FROM test_ids;
  UPDATE data.employee_absences SET status = 'cancelled' WHERE id = v_abs;
  SELECT days_used INTO v_used FROM data.vacation_entitlements WHERE id = (SELECT ent_emp FROM test_ids);

  IF v_used = 0 THEN
    INSERT INTO test_results VALUES ('T2 cancel approved decrements', 'PASS', format('used=%s', v_used));
  ELSE
    INSERT INTO test_results VALUES ('T2 cancel approved decrements', 'FAIL', format('used=%s expected 0', v_used));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 cancel approved decrements', 'FAIL', SQLERRM);
END $$;

-- T3: work_context without contract → source employee_fallback
DO $$
DECLARE
  v_alice uuid;
  v_ctx jsonb;
BEGIN
  SELECT emp_id INTO v_alice FROM test_ids;

  -- Ensure no covering active/scheduled primary for far-past date
  v_ctx := data.resolve_employee_work_context(v_alice, CURRENT_DATE - 400, NULL);

  IF v_ctx IS NOT NULL
     AND v_ctx->'contract'->>'source' = 'employee_fallback'
     AND v_ctx->'workload'->>'source' = 'employee_fallback' THEN
    INSERT INTO test_results VALUES ('T3 work_context employee_fallback', 'PASS', v_ctx->'contract'->>'source');
  ELSE
    INSERT INTO test_results VALUES ('T3 work_context employee_fallback', 'FAIL', coalesce(v_ctx::text, 'null'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 work_context employee_fallback', 'FAIL', SQLERRM);
END $$;

-- T4: work_context with active contract → source employment_contract
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

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_alice  uuid;
  v_id     uuid;
  v_ctx    jsonb;
  v_site_s uuid;
BEGIN
  SELECT emp_id, site_sants INTO v_alice, v_site_s FROM test_ids;

  INSERT INTO api.employment_contracts (
    tenant_id, employee_id, contract_number, starts_on, weekly_hours, site_id,
    lifecycle_status, is_primary, signature_requirement, signature_status
  ) VALUES (
    v_tenant, v_alice, 'EC-WFM-P0-T4', CURRENT_DATE, 37.5, v_site_s,
    'draft', true, 'none', 'not_required'
  ) RETURNING id INTO v_id;

  UPDATE test_ids SET contract_id = v_id;
  PERFORM api.transition_employment_contract(v_id, 'active', NULL);

  v_ctx := data.resolve_employee_work_context(v_alice, CURRENT_DATE, NULL);

  IF v_ctx->'contract'->>'source' = 'employment_contract'
     AND v_ctx->'contract'->>'id' = v_id::text THEN
    INSERT INTO test_results VALUES ('T4 work_context employment_contract', 'PASS', v_ctx->'contract'->>'source');
  ELSE
    INSERT INTO test_results VALUES ('T4 work_context employment_contract', 'FAIL', coalesce(v_ctx::text, 'null'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T4 work_context employment_contract', 'FAIL', SQLERRM);
END $$;

-- T5: employee_effective_weekly_hours prefers contract over flat divergence
RESET ROLE;
DO $$
DECLARE
  v_alice uuid;
  v_cid uuid;
  v_eff numeric;
  v_flat numeric;
BEGIN
  SELECT emp_id, contract_id INTO v_alice, v_cid FROM test_ids;

  -- Force flat divergence without going through material-edit guard:
  -- projection may have set 37.5; overwrite flat to 20 while contract stays 37.5
  PERFORM set_config('data.legacy_employee_projection', '1', true);
  UPDATE data.employees SET weekly_hours = 20 WHERE id = v_alice;

  v_eff := data.employee_effective_weekly_hours(v_alice, CURRENT_DATE);
  SELECT weekly_hours INTO v_flat FROM data.employees WHERE id = v_alice;

  IF v_eff = 37.5 AND v_flat = 20 THEN
    INSERT INTO test_results VALUES ('T5 effective hours prefers contract', 'PASS',
      format('eff=%s flat=%s', v_eff, v_flat));
  ELSE
    INSERT INTO test_results VALUES ('T5 effective hours prefers contract', 'FAIL',
      format('eff=%s flat=%s contract_id=%s', v_eff, v_flat, v_cid));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 effective hours prefers contract', 'FAIL', SQLERRM);
END $$;

-- T6: lock_version bumps on update
DO $$
DECLARE
  v_cid uuid;
  v_before int;
  v_after int;
BEGIN
  SELECT contract_id INTO v_cid FROM test_ids;
  SELECT lock_version INTO v_before FROM data.employment_contracts WHERE id = v_cid;

  -- Non-material field update on active should still bump lock_version
  UPDATE data.employment_contracts
  SET metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('p0_lock_test', true)
  WHERE id = v_cid;

  SELECT lock_version INTO v_after FROM data.employment_contracts WHERE id = v_cid;

  IF v_after = v_before + 1 THEN
    INSERT INTO test_results VALUES ('T6 lock_version bumps', 'PASS', format('%s->%s', v_before, v_after));
  ELSE
    INSERT INTO test_results VALUES ('T6 lock_version bumps', 'FAIL', format('%s->%s', v_before, v_after));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 lock_version bumps', 'FAIL', SQLERRM);
END $$;

-- T7: material edit on active contract raises contract_immutable_use_successor
DO $$
DECLARE
  v_cid uuid;
  v_ok boolean := false;
  v_msg text;
BEGIN
  SELECT contract_id INTO v_cid FROM test_ids;

  BEGIN
    UPDATE data.employment_contracts SET weekly_hours = 10 WHERE id = v_cid;
  EXCEPTION
    WHEN check_violation THEN
      IF SQLERRM ILIKE '%contract_immutable_use_successor%' THEN
        v_ok := true;
        v_msg := SQLERRM;
      ELSE
        v_msg := SQLERRM;
      END IF;
    WHEN OTHERS THEN
      IF SQLERRM ILIKE '%contract_immutable_use_successor%' THEN
        v_ok := true;
        v_msg := SQLERRM;
      ELSE
        v_msg := SQLERRM;
      END IF;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T7 material edit immutable', 'PASS', v_msg);
  ELSE
    INSERT INTO test_results VALUES ('T7 material edit immutable', 'FAIL', coalesce(v_msg, 'no exception'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T7 material edit immutable', 'FAIL', SQLERRM);
END $$;

-- T8: resolve_employee_work_context API callable as owner
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

DO $$
DECLARE
  v_alice uuid;
  v_ctx jsonb;
BEGIN
  SELECT emp_id INTO v_alice FROM test_ids;
  v_ctx := api.resolve_employee_work_context(v_alice, CURRENT_DATE, NULL);

  IF v_ctx IS NOT NULL
     AND v_ctx->>'resolver_version' IN ('ec_wfm_p1_v1', 'ec_wfm_p0_v1')
     AND v_ctx->>'employee_id' = v_alice::text THEN
    INSERT INTO test_results VALUES ('T8 api work_context as owner', 'PASS', v_ctx->>'resolver_version');
  ELSE
    INSERT INTO test_results VALUES ('T8 api work_context as owner', 'FAIL', coalesce(v_ctx::text, 'null'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T8 api work_context as owner', 'FAIL', SQLERRM);
END $$;

-- Cleanup (still inside transaction; ROLLBACK will undo anyway)
RESET ROLE;
DO $$
DECLARE
  v_alice uuid;
  v_prev_h numeric;
  v_prev_s uuid;
BEGIN
  SELECT emp_id, alice_prev_hours, alice_prev_site
  INTO v_alice, v_prev_h, v_prev_s
  FROM test_ids;

  DELETE FROM data.employee_absences WHERE id = (SELECT abs_id FROM test_ids);
  DELETE FROM data.vacation_entitlements
  WHERE id IN (SELECT ent_tenant FROM test_ids
               UNION SELECT ent_dept FROM test_ids
               UNION SELECT ent_emp FROM test_ids);
  DELETE FROM data.employment_contracts WHERE contract_number LIKE 'EC-WFM-P0-%';

  UPDATE data.employees
  SET weekly_hours = v_prev_h, site_id = v_prev_s
  WHERE id = v_alice;
END $$;

SELECT * FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  RAISE NOTICE 'EC-WFM P0: % PASS, % FAIL',
    (SELECT count(*) FROM test_results WHERE status = 'PASS'),
    v_fail;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EC-WFM P0 tests failed';
  END IF;
END $$;

ROLLBACK;
