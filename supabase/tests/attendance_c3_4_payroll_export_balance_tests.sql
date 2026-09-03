-- Track C3.4 — export_payroll_period includes compensation_balance_minutes
BEGIN;

CREATE TEMP TABLE c34_test_log (id serial, msg text);

CREATE OR REPLACE FUNCTION c34_assert(p_ok boolean, p_msg text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok THEN
    INSERT INTO c34_test_log (msg) VALUES ('[PASS] ' || p_msg);
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
  v_from      date := '2026-09-01';
  v_to        date := '2026-09-30';
  v_json      jsonb;
  v_row       jsonb;
  v_balance   int;
BEGIN
  DELETE FROM data.time_compensation_ledger WHERE employee_id = v_employee;

  INSERT INTO data.time_compensation_ledger (
    tenant_id, employee_id, source_work_date,
    movement_type, source_type, minutes, is_credit, created_by
  ) VALUES (
    v_tenant, v_employee, '2026-09-15',
    'accrued', 'overtime', 90, true, v_manager
  );

  v_balance := data.get_compensation_balance_minutes(v_employee);
  PERFORM c34_assert(v_balance = 90, 'seed balance 90');

  PERFORM set_config('request.jwt.claim.sub', v_manager::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    format(
      '{"sub":"%s","app_metadata":{"user_tenants":{"%s":{"global_role":"manager","sites":{"%s":"manager"}}},"user_permissions":{"%s":{"global_permissions":["attendance.export","attendance.manage","attendance.view_all"],"sites":{"%s":{"permissions":["attendance.export","attendance.manage","attendance.view_all"]}}}}}}',
      v_manager, v_tenant, v_site, v_tenant, v_site
    ),
    true
  );

  -- T1: aggregate export includes balance
  v_json := api.export_payroll_period(v_site, v_from, v_to, v_employee, 'aggregate');
  v_row := (
    SELECT elem
    FROM jsonb_array_elements(v_json->'rows') elem
    WHERE (elem->>'employee_id')::uuid = v_employee
    LIMIT 1
  );

  PERFORM c34_assert(v_row IS NOT NULL, 'aggregate row for employee');
  PERFORM c34_assert(
    (v_row->>'compensation_balance_minutes')::int = 90,
    'aggregate compensation_balance_minutes'
  );

  -- T2: daily export includes balance on each day row
  v_json := api.export_payroll_period(v_site, v_from, v_to, v_employee, 'daily');
  SELECT elem INTO v_row
  FROM jsonb_array_elements(v_json->'rows') elem
  WHERE (elem->>'employee_id')::uuid = v_employee
  LIMIT 1;

  PERFORM c34_assert(v_row IS NOT NULL, 'daily row for employee');
  PERFORM c34_assert(
    (v_row->>'compensation_balance_minutes')::int = 90,
    'daily compensation_balance_minutes'
  );

  -- T3: zero balance when no ledger entries
  DELETE FROM data.time_compensation_ledger WHERE employee_id = v_employee;
  v_json := api.export_payroll_period(v_site, v_from, v_to, v_employee, 'aggregate');
  v_row := (
    SELECT elem
    FROM jsonb_array_elements(v_json->'rows') elem
    WHERE (elem->>'employee_id')::uuid = v_employee
    LIMIT 1
  );
  PERFORM c34_assert(
    COALESCE((v_row->>'compensation_balance_minutes')::int, 0) = 0,
    'zero balance when ledger empty'
  );
END;
$$;

SELECT msg FROM c34_test_log ORDER BY id;

ROLLBACK;
