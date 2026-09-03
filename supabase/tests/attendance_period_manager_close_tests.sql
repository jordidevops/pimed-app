-- attendance_period_manager_close_tests.sql — Fase 5

BEGIN;

CREATE TEMP TABLE period_manager_close_test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

INSERT INTO data.tenants (id, name, slug, is_active, settings)
VALUES (
  'f1000000-0000-0000-0000-000000000001',
  'Period Manager Close Test',
  'period-mgr-close-test',
  true,
  '{
    "attendance_monthly_employee_confirm_required": true,
    "attendance_monthly_manager_can_close_without_employee": false,
    "attendance_employee_confirm_cycle": "calendar_month"
  }'::jsonb
)
ON CONFLICT (id) DO UPDATE SET
  settings = EXCLUDED.settings;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('f2000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', 'Mgr Close Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES (
  'f5000000-0000-0000-0000-000000000001',
  'f1000000-0000-0000-0000-000000000001',
  'f2000000-0000-0000-0000-000000000001',
  NULL,
  'Mgr Close Employee',
  'active'
)
ON CONFLICT (id) DO NOTHING;

-- P5-T1: sense confirmació → no satisfet
DO $$
DECLARE
  v_ok boolean;
BEGIN
  DELETE FROM data.attendance_period_confirmations
  WHERE employee_id = 'f5000000-0000-0000-0000-000000000001';

  DELETE FROM data.attendance_monthly_reports
  WHERE employee_id = 'f5000000-0000-0000-0000-000000000001'
    AND year = 2025 AND month = 5;

  v_ok := data.attendance_month_employee_confirm_satisfied(
    'f5000000-0000-0000-0000-000000000001',
    2025,
    5,
    'draft'
  );

  IF NOT v_ok THEN
    INSERT INTO period_manager_close_test_results VALUES ('P5-T1 no confirm unsatisfied', 'PASS', NULL);
  ELSE
    INSERT INTO period_manager_close_test_results VALUES ('P5-T1 no confirm unsatisfied', 'FAIL', 'expected false');
  END IF;
END $$;

-- P5-T2: confirmació mensual → satisfet
DO $$
DECLARE
  v_ok boolean;
BEGIN
  INSERT INTO data.attendance_period_confirmations (
    tenant_id, employee_id, period_from, period_to, cycle_type,
    calendar_year, calendar_month, confirmed_via
  ) VALUES (
    'f1000000-0000-0000-0000-000000000001',
    'f5000000-0000-0000-0000-000000000001',
    '2025-05-01',
    '2025-05-31',
    'calendar_month',
    2025,
    5,
    'tenant_app'
  )
  ON CONFLICT DO NOTHING;

  v_ok := data.attendance_month_employee_confirm_satisfied(
    'f5000000-0000-0000-0000-000000000001',
    2025,
    5,
    'draft'
  );

  IF v_ok THEN
    INSERT INTO period_manager_close_test_results VALUES ('P5-T2 month period satisfied', 'PASS', NULL);
  ELSE
    INSERT INTO period_manager_close_test_results VALUES ('P5-T2 month period satisfied', 'FAIL', 'expected true');
  END IF;
END $$;

-- P5-T3: validate_attendance_month_close inclou bloqueig EMPLOYEE_PERIOD_CONFIRM_INCOMPLETE
DO $$
DECLARE
  v_result jsonb;
  v_has_blocker boolean;
BEGIN
  DELETE FROM data.attendance_period_confirmations
  WHERE employee_id = 'f5000000-0000-0000-0000-000000000001';

  v_result := api.validate_attendance_month_close(
    'f5000000-0000-0000-0000-000000000001',
    2025,
    5
  );

  SELECT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(v_result->'blockers') b
    WHERE b->>'code' = 'EMPLOYEE_PERIOD_CONFIRM_INCOMPLETE'
  ) INTO v_has_blocker;

  IF v_has_blocker THEN
    INSERT INTO period_manager_close_test_results VALUES ('P5-T3 validate blocker', 'PASS', NULL);
  ELSE
    INSERT INTO period_manager_close_test_results VALUES ('P5-T3 validate blocker', 'FAIL', v_result::text);
  END IF;
END $$;

-- P5-T4: AMR employee_confirmed → satisfet encara sense fila de període
DO $$
DECLARE
  v_ok boolean;
BEGIN
  DELETE FROM data.attendance_period_confirmations
  WHERE employee_id = 'f5000000-0000-0000-0000-000000000001';

  INSERT INTO data.attendance_monthly_reports (
    tenant_id, employee_id, year, month, status, confirmed_at
  ) VALUES (
    'f1000000-0000-0000-0000-000000000001',
    'f5000000-0000-0000-0000-000000000001',
    2025,
    6,
    'employee_confirmed',
    now()
  )
  ON CONFLICT (employee_id, year, month) DO UPDATE SET
    status = 'employee_confirmed',
    confirmed_at = now();

  v_ok := data.attendance_month_employee_confirm_satisfied(
    'f5000000-0000-0000-0000-000000000001',
    2025,
    6,
    'employee_confirmed'
  );

  IF v_ok THEN
    INSERT INTO period_manager_close_test_results VALUES ('P5-T4 AMR employee_confirmed', 'PASS', NULL);
  ELSE
    INSERT INTO period_manager_close_test_results VALUES ('P5-T4 AMR employee_confirmed', 'FAIL', 'expected true');
  END IF;
END $$;

-- P5-T5: iso_week + AMR employee_confirmed sense setmanes → no satisfet
DO $$
DECLARE
  v_ok boolean;
BEGIN
  UPDATE data.tenants
  SET settings = settings || '{"attendance_employee_confirm_cycle": "iso_week"}'::jsonb
  WHERE id = 'f1000000-0000-0000-0000-000000000001';

  DELETE FROM data.attendance_period_confirmations
  WHERE employee_id = 'f5000000-0000-0000-0000-000000000001';

  DELETE FROM data.attendance_monthly_reports
  WHERE employee_id = 'f5000000-0000-0000-0000-000000000001'
    AND year = 2025 AND month = 7;

  INSERT INTO data.attendance_monthly_reports (
    tenant_id, employee_id, year, month, status, confirmed_at
  ) VALUES (
    'f1000000-0000-0000-0000-000000000001',
    'f5000000-0000-0000-0000-000000000001',
    2025,
    7,
    'employee_confirmed',
    now()
  );

  v_ok := data.attendance_month_employee_confirm_satisfied(
    'f5000000-0000-0000-0000-000000000001',
    2025,
    7,
    'employee_confirmed'
  );

  IF NOT v_ok THEN
    INSERT INTO period_manager_close_test_results VALUES ('P5-T5 iso_week AMR bypass blocked', 'PASS', NULL);
  ELSE
    INSERT INTO period_manager_close_test_results VALUES ('P5-T5 iso_week AMR bypass blocked', 'FAIL', 'expected false');
  END IF;

  UPDATE data.tenants
  SET settings = settings || '{"attendance_employee_confirm_cycle": "calendar_month"}'::jsonb
  WHERE id = 'f1000000-0000-0000-0000-000000000001';
END $$;

SELECT test_name, status, details
FROM period_manager_close_test_results
ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT COUNT(*) INTO v_fail FROM period_manager_close_test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'attendance_period_manager_close_tests: % failure(s)', v_fail;
  END IF;
END $$;

ROLLBACK;
