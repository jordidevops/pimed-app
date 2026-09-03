-- attendance_period_confirmations_schema_tests.sql — Fase 1

BEGIN;

CREATE TEMP TABLE period_schema_test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('d1000000-0000-0000-0000-000000000001', 'Period Schema Test', 'period-schema-test', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('d2000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'Period Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES (
  'd5000000-0000-0000-0000-000000000001',
  'd1000000-0000-0000-0000-000000000001',
  'd2000000-0000-0000-0000-000000000001',
  NULL,
  'Period Schema Employee',
  'active'
)
ON CONFLICT (id) DO NOTHING;

-- P1-T1: insert vàlid
DO $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO data.attendance_period_confirmations (
    tenant_id,
    employee_id,
    period_from,
    period_to,
    cycle_type,
    calendar_year,
    calendar_month,
    confirmed_via
  ) VALUES (
    'd1000000-0000-0000-0000-000000000001',
    'd5000000-0000-0000-0000-000000000001',
    '2025-06-01',
    '2025-06-30',
    'calendar_month',
    2025,
    6,
    'tenant_app'
  )
  RETURNING id INTO v_id;

  IF v_id IS NOT NULL THEN
    INSERT INTO period_schema_test_results VALUES ('P1-T1 valid insert', 'PASS', NULL);
  ELSE
    INSERT INTO period_schema_test_results VALUES ('P1-T1 valid insert', 'FAIL', 'no id');
  END IF;
END $$;

-- P1-T2: duplicate period
DO $$
BEGIN
  BEGIN
    INSERT INTO data.attendance_period_confirmations (
      tenant_id, employee_id, period_from, period_to, cycle_type, confirmed_via
    ) VALUES (
      'd1000000-0000-0000-0000-000000000001',
      'd5000000-0000-0000-0000-000000000001',
      '2025-06-01',
      '2025-06-30',
      'calendar_month',
      'employee_portal'
    );
    INSERT INTO period_schema_test_results VALUES ('P1-T2 unique period', 'FAIL', 'duplicate allowed');
  EXCEPTION WHEN unique_violation THEN
    INSERT INTO period_schema_test_results VALUES ('P1-T2 unique period', 'PASS', NULL);
  END;
END $$;

-- P1-T3: invalid cycle_type
DO $$
BEGIN
  BEGIN
    INSERT INTO data.attendance_period_confirmations (
      tenant_id, employee_id, period_from, period_to, cycle_type, confirmed_via
    ) VALUES (
      'd1000000-0000-0000-0000-000000000001',
      'd5000000-0000-0000-0000-000000000001',
      '2025-07-01',
      '2025-07-07',
      'weekly',
      'tenant_app'
    );
    INSERT INTO period_schema_test_results VALUES ('P1-T3 cycle_type check', 'FAIL', 'invalid allowed');
  EXCEPTION WHEN check_violation THEN
    INSERT INTO period_schema_test_results VALUES ('P1-T3 cycle_type check', 'PASS', NULL);
  END;
END $$;

-- P1-T4: setting default
DO $$
DECLARE
  v_cycle text;
BEGIN
  SELECT settings ->> 'attendance_employee_confirm_cycle'
  INTO v_cycle
  FROM data.system_settings
  WHERE module = 'defaults';

  IF v_cycle = 'calendar_month' THEN
    INSERT INTO period_schema_test_results VALUES ('P1-T4 setting default', 'PASS', NULL);
  ELSE
    INSERT INTO period_schema_test_results VALUES ('P1-T4 setting default', 'FAIL', COALESCE(v_cycle, 'null'));
  END IF;
END $$;

-- P1-T5: settings_registry entry
DO $$
DECLARE
  v_cnt int;
BEGIN
  SELECT COUNT(*) INTO v_cnt
  FROM data.settings_registry
  WHERE setting_key = 'attendance_employee_confirm_cycle' AND is_active;

  IF v_cnt = 1 THEN
    INSERT INTO period_schema_test_results VALUES ('P1-T5 settings_registry', 'PASS', NULL);
  ELSE
    INSERT INTO period_schema_test_results VALUES ('P1-T5 settings_registry', 'FAIL', v_cnt::text);
  END IF;
END $$;

SELECT test_name, status, details FROM period_schema_test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT COUNT(*) INTO v_fail FROM period_schema_test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'attendance_period_confirmations_schema_tests: % failure(s)', v_fail;
  END IF;
END $$;

ROLLBACK;
