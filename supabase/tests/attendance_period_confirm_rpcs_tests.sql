-- attendance_period_confirm_rpcs_tests.sql — Fase 2

BEGIN;

CREATE TEMP TABLE period_rpc_test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('e1000000-0000-0000-0000-000000000001', 'Period RPC Test', 'period-rpc-test', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('e2000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'Period RPC Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES (
  'e5000000-0000-0000-0000-000000000001',
  'e1000000-0000-0000-0000-000000000001',
  'e2000000-0000-0000-0000-000000000001',
  NULL,
  'Period RPC Employee',
  'active'
)
ON CONFLICT (id) DO NOTHING;

-- P2-T1: iso_week_start dilluns
DO $$
BEGIN
  IF data.iso_week_start('2025-06-04'::date) = '2025-06-02'::date THEN
    INSERT INTO period_rpc_test_results VALUES ('P2-T1 iso_week_start', 'PASS', NULL);
  ELSE
    INSERT INTO period_rpc_test_results VALUES ('P2-T1 iso_week_start', 'FAIL', 'wrong monday');
  END IF;
END $$;

-- P2-T2: list ISO weeks for June 2025
DO $$
DECLARE
  v_cnt int;
BEGIN
  SELECT COUNT(*) INTO v_cnt
  FROM data.list_calendar_month_iso_weeks(2025, 6);

  IF v_cnt BETWEEN 4 AND 6 THEN
    INSERT INTO period_rpc_test_results VALUES ('P2-T2 list month weeks', 'PASS', v_cnt::text);
  ELSE
    INSERT INTO period_rpc_test_results VALUES ('P2-T2 list month weeks', 'FAIL', v_cnt::text);
  END IF;
END $$;

-- P2-T3: confirm període acabat (service path via direct insert + sync)
DO $$
DECLARE
  v_report_id uuid;
  v_status text;
BEGIN
  INSERT INTO data.attendance_period_confirmations (
    tenant_id, employee_id, period_from, period_to, cycle_type,
    calendar_year, calendar_month, confirmed_via
  ) VALUES (
    'e1000000-0000-0000-0000-000000000001',
    'e5000000-0000-0000-0000-000000000001',
    '2025-05-01',
    '2025-05-31',
    'calendar_month',
    2025,
    5,
    'tenant_app'
  );

  v_report_id := data.sync_attendance_monthly_report_from_periods(
    'e5000000-0000-0000-0000-000000000001',
    2025,
    5,
    NULL
  );

  SELECT amr.status INTO v_status
  FROM data.attendance_monthly_reports amr
  WHERE amr.id = v_report_id;

  IF v_status = 'employee_confirmed' THEN
    INSERT INTO period_rpc_test_results VALUES ('P2-T3 sync AMR from month period', 'PASS', NULL);
  ELSE
    INSERT INTO period_rpc_test_results VALUES ('P2-T3 sync AMR from month period', 'FAIL', COALESCE(v_status, 'null'));
  END IF;
END $$;

-- P2-T4: get_attendance_month_period_status
DO $$
DECLARE
  v_result jsonb;
BEGIN
  v_result := api.get_attendance_month_period_status(
    'e5000000-0000-0000-0000-000000000001',
    2025,
    5
  );

  IF COALESCE((v_result ->> 'month_fully_confirmed')::boolean, false) THEN
    INSERT INTO period_rpc_test_results VALUES ('P2-T4 period status month ok', 'PASS', NULL);
  ELSE
    INSERT INTO period_rpc_test_results VALUES ('P2-T4 period status month ok', 'FAIL', v_result::text);
  END IF;
END $$;

-- P2-T5: list_attendance_period_confirmations
DO $$
DECLARE
  v_result jsonb;
  v_len int;
BEGIN
  v_result := api.list_attendance_period_confirmations(
    'e5000000-0000-0000-0000-000000000001',
    2025,
    5
  );
  v_len := jsonb_array_length(COALESCE(v_result -> 'confirmations', '[]'::jsonb));

  IF v_len >= 1 THEN
    INSERT INTO period_rpc_test_results VALUES ('P2-T5 list confirmations', 'PASS', NULL);
  ELSE
    INSERT INTO period_rpc_test_results VALUES ('P2-T5 list confirmations', 'FAIL', v_result::text);
  END IF;
END $$;

SELECT test_name, status, details FROM period_rpc_test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT COUNT(*) INTO v_fail FROM period_rpc_test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'attendance_period_confirm_rpcs_tests: % failure(s)', v_fail;
  END IF;
END $$;

ROLLBACK;
