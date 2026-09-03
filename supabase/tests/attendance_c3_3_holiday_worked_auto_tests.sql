-- Track C3.3 — auto holiday_worked credit on sync_attendance_rollups_for_day
BEGIN;

CREATE TEMP TABLE c33_test_log (id serial, msg text);

CREATE OR REPLACE FUNCTION c33_assert(p_ok boolean, p_msg text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok THEN
    INSERT INTO c33_test_log (msg) VALUES ('[PASS] ' || p_msg);
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
  v_holiday   date := '2026-12-25';
  v_workday   date := '2026-12-26';
  v_balance   int;
  v_cnt       int;
  v_minutes   int;
BEGIN
  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb)
    || jsonb_build_object('attendance_effective_time_enabled', true)
  WHERE id = v_tenant;

  DELETE FROM data.time_compensation_ledger
  WHERE employee_id = v_employee
    AND source_work_date IN (v_holiday, v_workday);
  DELETE FROM data.attendance_rollup_day_snapshots
  WHERE employee_id = v_employee
    AND work_date IN (v_holiday, v_workday);
  DELETE FROM data.time_daily_summaries
  WHERE employee_id = v_employee
    AND work_date IN (v_holiday, v_workday);

  -- T1: holiday with work → auto accrued holiday_worked
  INSERT INTO data.time_daily_summaries (
    tenant_id, site_id, employee_id, work_date, day_type,
    worked_minutes, work_minutes, travel_minutes, paid_minutes, effective_minutes
  ) VALUES (
    v_tenant, v_site, v_employee, v_holiday, 'holiday',
    300, 280, 0, 280, 270
  );

  PERFORM data.sync_attendance_rollups_for_day(v_employee, v_holiday, v_tenant, v_site);

  SELECT COALESCE(SUM(minutes), 0) INTO v_minutes
  FROM data.time_compensation_ledger
  WHERE employee_id = v_employee
    AND source_work_date = v_holiday
    AND movement_type = 'accrued'
    AND source_type = 'holiday_worked'
    AND is_credit = true;

  PERFORM c33_assert(v_minutes = 280, 'holiday auto credit prefers work_minutes = 280');

  -- T2: re-sync same target → no duplicate
  PERFORM data.sync_attendance_rollups_for_day(v_employee, v_holiday, v_tenant, v_site);

  SELECT COUNT(*) INTO v_cnt
  FROM data.time_compensation_ledger
  WHERE employee_id = v_employee
    AND source_work_date = v_holiday
    AND source_type = 'holiday_worked';

  PERFORM c33_assert(v_cnt = 1, 're-sync does not duplicate holiday_worked');

  -- T3: recompute increases work → delta only
  UPDATE data.time_daily_summaries
  SET work_minutes = 320, worked_minutes = 310
  WHERE employee_id = v_employee AND work_date = v_holiday;

  PERFORM data.sync_attendance_rollups_for_day(v_employee, v_holiday, v_tenant, v_site);

  SELECT COALESCE(SUM(minutes), 0) INTO v_minutes
  FROM data.time_compensation_ledger
  WHERE employee_id = v_employee
    AND source_work_date = v_holiday
    AND source_type = 'holiday_worked'
    AND is_credit = true;

  PERFORM c33_assert(v_minutes = 320, 're-sync adds delta when work increases');

  -- T4: regular work day → no holiday_worked
  INSERT INTO data.time_daily_summaries (
    tenant_id, site_id, employee_id, work_date, day_type,
    worked_minutes, work_minutes
  ) VALUES (
    v_tenant, v_site, v_employee, v_workday, 'work',
    480, 450
  );

  PERFORM data.sync_attendance_rollups_for_day(v_employee, v_workday, v_tenant, v_site);

  SELECT COUNT(*) INTO v_cnt
  FROM data.time_compensation_ledger
  WHERE employee_id = v_employee
    AND source_work_date = v_workday
    AND source_type = 'holiday_worked';

  PERFORM c33_assert(v_cnt = 0, 'work day does not create holiday_worked');

  -- T5: holiday without work → no credit
  DELETE FROM data.time_compensation_ledger
  WHERE employee_id = v_employee AND source_work_date = v_holiday;

  UPDATE data.time_daily_summaries
  SET work_minutes = 0, worked_minutes = 0
  WHERE employee_id = v_employee AND work_date = v_holiday;

  PERFORM data.sync_attendance_rollups_for_day(v_employee, v_holiday, v_tenant, v_site);

  SELECT COUNT(*) INTO v_cnt
  FROM data.time_compensation_ledger
  WHERE employee_id = v_employee
    AND source_work_date = v_holiday
    AND source_type = 'holiday_worked';

  PERFORM c33_assert(v_cnt = 0, 'holiday without work does not credit');

  v_balance := data.get_compensation_balance_minutes(v_employee);
  PERFORM c33_assert(v_balance >= 0, 'balance remains consistent');
END;
$$;

SELECT msg FROM c33_test_log ORDER BY id;

ROLLBACK;
