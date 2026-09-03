-- M-EC-08 employment contracts automation tests
BEGIN;
SET client_min_messages TO WARNING;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text PRIMARY KEY,
  status text NOT NULL,
  details text
) ON COMMIT DROP;

CREATE TEMP TABLE test_ids (
  scheduled_ok uuid,
  scheduled_blocked uuid,
  draft_blocked uuid,
  expiring uuid,
  ended_src uuid
) ON COMMIT DROP;

CREATE TEMP TABLE test_emp (
  employee_id uuid
) ON COMMIT DROP;

INSERT INTO test_ids DEFAULT VALUES;

RESET ROLE;

-- Setup as postgres (bypass RLS) — dedicated employee avoids EXCLUDE vs Alice
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_emp uuid;
  v_ok uuid;
  v_blk uuid;
  v_draft uuid;
  v_exp uuid;
  v_end uuid;
BEGIN
  DELETE FROM data.employment_contract_notice_log
  WHERE contract_id IN (
    SELECT id FROM data.employment_contracts
    WHERE tenant_id = v_tenant AND contract_number LIKE 'EC8-%'
  );
  DELETE FROM data.employment_contracts
  WHERE tenant_id = v_tenant AND contract_number LIKE 'EC8-%';
  DELETE FROM data.employees
  WHERE tenant_id = v_tenant AND full_name = 'EC8 Automation Emp';

  INSERT INTO data.employees (
    tenant_id, full_name, status, weekly_hours, starts_on
  ) VALUES (
    v_tenant, 'EC8 Automation Emp', 'active', 40, CURRENT_DATE - 30
  ) RETURNING id INTO v_emp;

  INSERT INTO test_emp VALUES (v_emp);

  INSERT INTO data.employment_contracts (
    tenant_id, employee_id, contract_number, source,
    lifecycle_status, approval_status, signature_requirement, signature_status,
    is_primary, starts_on, ends_on, weekly_hours
  ) VALUES (
    v_tenant, v_emp, 'EC8-SCHED-OK', 'manual',
    'scheduled', 'not_required', 'none', 'not_required',
    true, CURRENT_DATE - 1, CURRENT_DATE + 120, 40
  ) RETURNING id INTO v_ok;

  INSERT INTO data.employment_contracts (
    tenant_id, employee_id, contract_number, source,
    lifecycle_status, approval_status, signature_requirement, signature_status,
    is_primary, starts_on, ends_on, weekly_hours
  ) VALUES (
    v_tenant, v_emp, 'EC8-SCHED-BLK', 'manual',
    'scheduled', 'approved', 'employee_and_employer', 'rejected',
    false, CURRENT_DATE - 1, CURRENT_DATE + 60, 20
  ) RETURNING id INTO v_blk;

  INSERT INTO data.employment_contracts (
    tenant_id, employee_id, contract_number, source,
    lifecycle_status, approval_status, signature_requirement, signature_status,
    is_primary, starts_on, ends_on, weekly_hours
  ) VALUES (
    v_tenant, v_emp, 'EC8-DRAFT-PAST', 'manual',
    'draft', 'not_required', 'none', 'not_required',
    false, CURRENT_DATE - 5, NULL, 10
  ) RETURNING id INTO v_draft;

  INSERT INTO data.employment_contracts (
    tenant_id, employee_id, contract_number, source,
    lifecycle_status, approval_status, signature_requirement, signature_status,
    is_primary, starts_on, ends_on, weekly_hours
  ) VALUES (
    v_tenant, v_emp, 'EC8-EXP-30', 'manual',
    'active', 'not_required', 'none', 'not_required',
    false, CURRENT_DATE - 100, CURRENT_DATE + 30, 15
  ) RETURNING id INTO v_exp;

  INSERT INTO data.employment_contracts (
    tenant_id, employee_id, contract_number, source,
    lifecycle_status, approval_status, signature_requirement, signature_status,
    is_primary, starts_on, ends_on, weekly_hours
  ) VALUES (
    v_tenant, v_emp, 'EC8-END-SRC', 'manual',
    'ended', 'not_required', 'none', 'not_required',
    false, CURRENT_DATE - 400, CURRENT_DATE - 10, 40
  ) RETURNING id INTO v_end;

  UPDATE test_ids SET
    scheduled_ok = v_ok,
    scheduled_blocked = v_blk,
    draft_blocked = v_draft,
    expiring = v_exp,
    ended_src = v_end;
END $$;

-- T1: job reconcile activates OK, skips signature-blocked, notices draft
DO $$
DECLARE
  v_res jsonb;
  v_st text;
  v_blk_n int;
BEGIN
  v_res := data.reconcile_employment_contracts_job(CURRENT_DATE);

  SELECT lifecycle_status INTO v_st
  FROM data.employment_contracts WHERE id = (SELECT scheduled_ok FROM test_ids);

  SELECT count(*) INTO v_blk_n
  FROM data.employment_contract_notice_log
  WHERE notice_kind = 'activation_blocked'
    AND contract_id IN (
      SELECT scheduled_blocked FROM test_ids
      UNION ALL
      SELECT draft_blocked FROM test_ids
    );

  IF v_st = 'active'
     AND (v_res ->> 'activated')::int >= 1
     AND (v_res ->> 'skipped_signature_blocked')::int >= 1
     AND v_blk_n >= 2 THEN
    INSERT INTO test_results VALUES (
      'T1 reconcile job activate+block',
      'PASS',
      format('res=%s blocked_notices=%s', v_res, v_blk_n)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T1 reconcile job activate+block',
      'FAIL',
      format('st=%s res=%s blk=%s', v_st, v_res, v_blk_n)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T1 reconcile job activate+block', 'FAIL', SQLERRM);
END $$;

-- T2: idempotent reconcile (no double activate notice)
DO $$
DECLARE
  v_res jsonb;
  v_act_n int;
  v_before int;
BEGIN
  SELECT count(*) INTO v_before
  FROM data.employment_contract_notice_log
  WHERE contract_id = (SELECT scheduled_ok FROM test_ids)
    AND notice_kind = 'activated';

  v_res := data.reconcile_employment_contracts_for_tenant(
    '10000000-0000-0000-0000-000000000001', CURRENT_DATE
  );

  SELECT count(*) INTO v_act_n
  FROM data.employment_contract_notice_log
  WHERE contract_id = (SELECT scheduled_ok FROM test_ids)
    AND notice_kind = 'activated';

  IF (v_res ->> 'activated')::int = 0 AND v_act_n = v_before AND v_before = 1 THEN
    INSERT INTO test_results VALUES ('T2 reconcile idempotent', 'PASS', v_res::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T2 reconcile idempotent',
      'FAIL',
      format('res=%s act_n=%s before=%s', v_res, v_act_n, v_before)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 reconcile idempotent', 'FAIL', SQLERRM);
END $$;

-- T3: expiring notice on exact day 30
DO $$
DECLARE
  v_res jsonb;
  v_n int;
BEGIN
  v_res := data.emit_employment_contract_expiry_notices(CURRENT_DATE);

  SELECT count(*) INTO v_n
  FROM data.employment_contract_notice_log
  WHERE contract_id = (SELECT expiring FROM test_ids)
    AND notice_kind = 'expiring'
    AND notice_days = 30;

  IF (v_res ->> 'emitted')::int >= 1 AND v_n = 1 THEN
    INSERT INTO test_results VALUES (
      'T3 expiring day-30 emit',
      'PASS',
      format('res=%s', v_res)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T3 expiring day-30 emit',
      'FAIL',
      format('res=%s n=%s', v_res, v_n)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 expiring day-30 emit', 'FAIL', SQLERRM);
END $$;

-- T4: expiring dedupe
DO $$
DECLARE
  v_res jsonb;
BEGIN
  v_res := data.emit_employment_contract_expiry_notices(CURRENT_DATE);
  IF (v_res ->> 'emitted')::int = 0 AND (v_res ->> 'skipped_duplicates')::int >= 1 THEN
    INSERT INTO test_results VALUES ('T4 expiring dedupe', 'PASS', v_res::text);
  ELSE
    INSERT INTO test_results VALUES ('T4 expiring dedupe', 'FAIL', coalesce(v_res::text, 'null'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T4 expiring dedupe', 'FAIL', SQLERRM);
END $$;

-- T5: indefinite never expires
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_emp uuid;
  v_id uuid;
  v_before int;
  v_after int;
  v_res jsonb;
BEGIN
  SELECT employee_id INTO v_emp FROM test_emp;
  INSERT INTO data.employment_contracts (
    tenant_id, employee_id, contract_number, source,
    lifecycle_status, approval_status, signature_requirement, signature_status,
    is_primary, starts_on, ends_on, weekly_hours
  ) VALUES (
    v_tenant, v_emp, 'EC8-INDEF', 'manual',
    'active', 'not_required', 'none', 'not_required',
    false, CURRENT_DATE - 10, NULL, 8
  ) RETURNING id INTO v_id;

  SELECT count(*) INTO v_before FROM data.employment_contract_notice_log WHERE contract_id = v_id;
  v_res := data.emit_employment_contract_expiry_notices(CURRENT_DATE);
  SELECT count(*) INTO v_after FROM data.employment_contract_notice_log WHERE contract_id = v_id;

  IF v_before = v_after THEN
    INSERT INTO test_results VALUES ('T5 indefinite no expiry', 'PASS', 'ok');
  ELSE
    INSERT INTO test_results VALUES ('T5 indefinite no expiry', 'FAIL', format('before=%s after=%s', v_before, v_after));
  END IF;

  DELETE FROM data.employment_contracts WHERE id = v_id;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 indefinite no expiry', 'FAIL', SQLERRM);
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

-- T6: list alerts
DO $$
DECLARE
  v_rep jsonb;
  v_cnt int;
  v_kinds text;
  v_emp uuid;
BEGIN
  SELECT employee_id INTO v_emp FROM test_emp;
  v_rep := api.list_employment_contract_alerts(v_emp, CURRENT_DATE);
  v_cnt := (v_rep ->> 'count')::int;
  SELECT string_agg(DISTINCT a ->> 'kind', ',')
  INTO v_kinds
  FROM jsonb_array_elements(v_rep -> 'alerts') a;

  IF v_cnt >= 2
     AND v_kinds LIKE '%activation_blocked%'
     AND v_kinds LIKE '%expiring_soon%' THEN
    INSERT INTO test_results VALUES (
      'T6 list alerts',
      'PASS',
      format('count=%s kinds=%s', v_cnt, v_kinds)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T6 list alerts',
      'FAIL',
      coalesce(v_rep::text, 'null')
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 list alerts', 'FAIL', SQLERRM);
END $$;

-- T7: create renewal
DO $$
DECLARE
  v_src uuid;
  v_out api.employment_contracts;
BEGIN
  SELECT ended_src INTO v_src FROM test_ids;
  v_out := api.create_employment_contract_renewal(v_src, NULL, NULL);

  IF v_out.lifecycle_status = 'draft'
     AND v_out.supersedes_contract_id = v_src
     AND v_out.starts_on = (CURRENT_DATE - 10) + 1 THEN
    INSERT INTO test_results VALUES (
      'T7 create renewal',
      'PASS',
      format('id=%s starts=%s', v_out.id, v_out.starts_on)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T7 create renewal',
      'FAIL',
      format('status=%s supersedes=%s starts=%s',
        v_out.lifecycle_status, v_out.supersedes_contract_id, v_out.starts_on)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T7 create renewal', 'FAIL', SQLERRM);
END $$;

-- Cleanup EC8 rows
RESET ROLE;
DO $$
DECLARE
  v_emp uuid;
BEGIN
  SELECT employee_id INTO v_emp FROM test_emp;
  DELETE FROM data.employment_contract_notice_log
  WHERE contract_id IN (
    SELECT id FROM data.employment_contracts
    WHERE contract_number LIKE 'EC8-%'
       OR (employee_id = v_emp AND source = 'renewal')
  );
  DELETE FROM data.employment_contracts
  WHERE contract_number LIKE 'EC8-%'
     OR (employee_id = v_emp AND source = 'renewal');
  DELETE FROM data.employees WHERE id = v_emp;
  INSERT INTO test_results VALUES ('T8 cleanup', 'PASS', 'ok');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T8 cleanup', 'FAIL', SQLERRM);
END $$;

SELECT * FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  RAISE NOTICE 'M-EC-08 employment contracts automation: % PASS, % FAIL',
    (SELECT count(*) FROM test_results WHERE status = 'PASS'),
    v_fail;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'M-EC-08 employment contracts automation tests failed';
  END IF;
END $$;

ROLLBACK;
