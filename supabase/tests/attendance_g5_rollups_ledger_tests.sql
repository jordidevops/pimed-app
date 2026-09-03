-- Track G Phase 5 — rollups, ledger C3, legal alerts tests
BEGIN;

CREATE TEMP TABLE g5_test_log (id serial, msg text);

CREATE OR REPLACE FUNCTION g5_assert(p_ok boolean, p_msg text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok THEN
    INSERT INTO g5_test_log (msg) VALUES ('[PASS] ' || p_msg);
  ELSE
    RAISE EXCEPTION '[FAIL] %', p_msg;
  END IF;
END;
$$;

DO $$
DECLARE
  v_tenant   uuid := '10000000-0000-0000-0000-000000000001';
  v_site     uuid := '30000000-0000-0000-0000-000000000001';
  v_employee uuid := '40000000-0000-0000-0000-000000000001';
  v_day      date := '2026-09-15';
  v_period   text := 'cy:2026';
  v_balance  int;
  v_rollup   record;
  v_cnt      int;
  v_json     jsonb;
BEGIN
  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb)
    || jsonb_build_object(
      'attendance_effective_time_enabled', true,
      'attendance_statutory_max_overtime_minutes_year', 4800,
      'attendance_statutory_alert_thresholds_pct', '[80]'::jsonb
    )
  WHERE id = v_tenant;

  DELETE FROM data.attendance_legal_alert_fired WHERE employee_id = v_employee;
  DELETE FROM data.time_compensation_ledger WHERE employee_id = v_employee;
  DELETE FROM data.attendance_rollup_day_snapshots WHERE employee_id = v_employee;
  DELETE FROM data.attendance_yearly_rollups WHERE employee_id = v_employee;
  DELETE FROM data.time_daily_summaries WHERE employee_id = v_employee AND work_date = v_day;

  -- T1: incremental rollup delta
  PERFORM data.apply_attendance_rollup_delta(
    v_tenant, v_employee, v_period, 'ES',
    100, 20, 120, 110, 30, 10
  );

  SELECT * INTO v_rollup
  FROM data.attendance_yearly_rollups
  WHERE employee_id = v_employee AND period_key = v_period;

  PERFORM g5_assert(v_rollup.work_minutes_ytd = 100, 'rollup work_minutes_ytd');
  PERFORM g5_assert(v_rollup.overtime_authorized_ytd = 30, 'rollup overtime_authorized_ytd');

  PERFORM data.apply_attendance_rollup_delta(
    v_tenant, v_employee, v_period, 'ES',
    -50, 0, -50, -50, -10, -5
  );

  SELECT * INTO v_rollup
  FROM data.attendance_yearly_rollups
  WHERE employee_id = v_employee AND period_key = v_period;

  PERFORM g5_assert(v_rollup.work_minutes_ytd = 50, 'rollup delta subtract work');
  PERFORM g5_assert(v_rollup.overtime_authorized_ytd = 20, 'rollup delta subtract ot');

  -- T2: sync day creates snapshot, rollup update, ledger accrued
  INSERT INTO data.time_daily_summaries (
    tenant_id, site_id, employee_id, work_date,
    worked_minutes, overtime_minutes,
    work_minutes, travel_minutes, paid_minutes, effective_minutes,
    overtime_authorized_minutes
  ) VALUES (
    v_tenant, v_site, v_employee, v_day,
    480, 60,
    400, 30, 430, 410,
    45
  );

  PERFORM data.sync_attendance_rollups_for_day(v_employee, v_day, v_tenant, v_site);

  SELECT COUNT(*) INTO v_cnt
  FROM data.attendance_rollup_day_snapshots
  WHERE employee_id = v_employee AND work_date = v_day AND period_key = v_period;

  PERFORM g5_assert(v_cnt = 1, 'rollup day snapshot created');

  SELECT * INTO v_rollup
  FROM data.attendance_yearly_rollups
  WHERE employee_id = v_employee AND period_key = v_period;

  PERFORM g5_assert(v_rollup.overtime_authorized_ytd >= 45, 'sync increases ot rollup');

  SELECT COUNT(*) INTO v_cnt
  FROM data.time_compensation_ledger
  WHERE employee_id = v_employee
    AND movement_type = 'accrued'
    AND source_work_date = v_day;

  PERFORM g5_assert(v_cnt >= 1, 'ledger accrued on ot increase');

  v_balance := data.get_compensation_balance_minutes(v_employee);
  PERFORM g5_assert(v_balance > 0, 'compensation balance positive');

  -- T3: alert dedup — force high OT rollup then check alerts twice
  UPDATE data.attendance_yearly_rollups
  SET overtime_authorized_ytd = 4000
  WHERE employee_id = v_employee AND period_key = v_period;

  PERFORM data.check_attendance_legal_alerts(v_employee, v_day, v_tenant, v_site);
  PERFORM data.check_attendance_legal_alerts(v_employee, v_day, v_tenant, v_site);

  SELECT COUNT(*) INTO v_cnt
  FROM data.attendance_legal_alert_fired
  WHERE employee_id = v_employee
    AND alert_kind = 'overtime_statutory'
    AND period_key = v_period
    AND threshold_pct = 80;

  PERFORM g5_assert(v_cnt = 1, 'legal alert dedup unique');

  -- T4: API legal counters JSON shape
  v_json := api.get_attendance_legal_counters(v_employee, v_day);

  PERFORM g5_assert(v_json ? 'compensation_balance_minutes', 'counters json has balance');
  PERFORM g5_assert(jsonb_array_length(v_json->'counters') >= 1, 'counters json has rows');
  PERFORM g5_assert((v_json->'counters'->0->'limits'->>'statutory_overtime_minutes') IS NOT NULL,
    'counters json has statutory limit');
END;
$$;

SELECT msg FROM g5_test_log ORDER BY id;

ROLLBACK;
