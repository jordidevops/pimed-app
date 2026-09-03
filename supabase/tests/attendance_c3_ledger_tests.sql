-- Track C3.1 — compensation ledger list + manual movement RPCs
BEGIN;

CREATE TEMP TABLE c3_test_log (id serial, msg text);

CREATE OR REPLACE FUNCTION c3_assert(p_ok boolean, p_msg text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok THEN
    INSERT INTO c3_test_log (msg) VALUES ('[PASS] ' || p_msg);
  ELSE
    RAISE EXCEPTION '[FAIL] %', p_msg;
  END IF;
END;
$$;

DO $$
DECLARE
  v_tenant    uuid := '10000000-0000-0000-0000-000000000001';
  v_site      uuid := '30000000-0000-0000-0000-000000000001';
  v_employee  uuid := '40000000-0000-0000-0000-000000000001';
  v_manager   uuid := '20000000-0000-0000-0000-000000000004';
  v_day       date := '2026-09-20';
  v_holiday   date := '2026-12-25';
  v_id        uuid;
  v_balance   int;
  v_json      jsonb;
  v_cnt       int;
BEGIN
  DELETE FROM data.time_compensation_ledger WHERE employee_id = v_employee;

  -- Seed credit for debit tests
  INSERT INTO data.time_compensation_ledger (
    tenant_id, employee_id, source_work_date,
    movement_type, source_type, minutes, is_credit, created_by
  ) VALUES (
    v_tenant, v_employee, v_day,
    'accrued', 'overtime', 120, true, v_manager
  );

  v_balance := data.get_compensation_balance_minutes(v_employee);
  PERFORM c3_assert(v_balance = 120, 'seed balance 120');

  PERFORM set_config('request.jwt.claim.sub', v_manager::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    format(
      '{"sub":"%s","app_metadata":{"user_tenants":{"%s":{"global_role":"manager","sites":{"%s":"manager"}}},"user_permissions":{"%s":{"global_permissions":["attendance.manage","attendance.view_all"],"sites":{"%s":{"permissions":["attendance.manage","attendance.view_all"]}}}}}}',
      v_manager, v_tenant, v_site, v_tenant, v_site
    ),
    true
  );

  -- T1: list ledger JSON shape
  v_json := api.list_compensation_ledger(v_employee, 20, 0);
  PERFORM c3_assert(v_json ? 'balance_minutes', 'list has balance');
  PERFORM c3_assert(jsonb_array_length(v_json->'movements') >= 1, 'list has movements');
  PERFORM c3_assert((v_json->'movements'->0->>'signed_minutes') IS NOT NULL, 'list signed_minutes');

  -- T2: holiday_worked credit
  v_id := api.record_compensation_movement(
    v_employee, 'accrued', 60, 'holiday_worked', true, v_holiday, 'Festiu treballat'
  );
  PERFORM c3_assert(v_id IS NOT NULL, 'holiday_worked movement created');
  v_balance := data.get_compensation_balance_minutes(v_employee);
  PERFORM c3_assert(v_balance = 180, 'balance after holiday_worked');

  -- T3: compensated_time_off debit
  v_id := api.record_compensation_movement(
    v_employee, 'compensated_time_off', 90, 'overtime', false, NULL, 'Descans compensatori'
  );
  PERFORM c3_assert(v_id IS NOT NULL, 'compensated_time_off created');
  v_balance := data.get_compensation_balance_minutes(v_employee);
  PERFORM c3_assert(v_balance = 90, 'balance after time off');

  -- T4: insufficient balance rejected
  BEGIN
    PERFORM api.record_compensation_movement(
      v_employee, 'paid_payroll', 200, 'overtime', false, NULL, 'should fail'
    );
    PERFORM c3_assert(false, 'paid_payroll over balance should fail');
  EXCEPTION
    WHEN check_violation THEN
      PERFORM c3_assert(true, 'insufficient balance rejected');
  END;

  -- T5: paid_payroll within balance
  v_id := api.record_compensation_movement(
    v_employee, 'paid_payroll', 30, 'overtime', false, NULL, 'Nòmina desembre'
  );
  v_balance := data.get_compensation_balance_minutes(v_employee);
  PERFORM c3_assert(v_balance = 60, 'balance after payroll debit');

  -- T6: audit event logged
  SELECT COUNT(*) INTO v_cnt
  FROM data.audit_logs
  WHERE entity_type = 'employee'
    AND entity_id = v_employee
    AND action = 'ATTENDANCE_COMPENSATION_RECORDED';

  PERFORM c3_assert(v_cnt >= 3, 'audit events recorded');
END;
$$;

SELECT msg FROM c3_test_log ORDER BY id;

ROLLBACK;
