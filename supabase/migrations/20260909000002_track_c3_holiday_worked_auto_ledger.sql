-- Track C3.3 — Auto-credit holiday_worked on day consolidation (sync rollups hook)

CREATE OR REPLACE FUNCTION data.sync_attendance_rollups_for_day(
  p_employee_id uuid,
  p_work_date   date,
  p_tenant_id   uuid,
  p_site_id     uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_settings             jsonb;
  v_jurisdiction         text := 'ES';
  v_period               text := 'calendar_year';
  v_fiscal_month         int  := 1;
  v_period_keys          text[];
  v_period_key           text;
  v_cy_key               text;
  v_summary              record;
  v_old                  record;
  v_old_ot_auth          int := 0;
  v_new_work             int;
  v_new_travel           int;
  v_new_paid             int;
  v_new_effective        int;
  v_new_ot_auth          int;
  v_new_ot_pending       int;
  v_day_type             text;
  v_worked_minutes       int := 0;
  v_old_holiday_credit   int := 0;
  v_new_holiday_target   int := 0;
  v_today                date := (now() AT TIME ZONE COALESCE(data.get_site_timezone(p_site_id, p_tenant_id), 'Europe/Madrid'))::date;
  v_exit_date            date;
BEGIN
  v_settings := data.merge_effective_settings_for_service(p_tenant_id, p_site_id);
  IF COALESCE((v_settings->>'attendance_effective_time_enabled')::boolean, false) IS NOT TRUE THEN
    RETURN;
  END IF;

  v_jurisdiction := COALESCE(NULLIF(v_settings->>'attendance_statutory_jurisdiction_code', ''), 'ES');
  v_period       := COALESCE(NULLIF(v_settings->>'attendance_statutory_overtime_period', ''), 'calendar_year');
  v_fiscal_month := COALESCE((v_settings->>'attendance_statutory_fiscal_year_start_month')::int, 1);

  SELECT
    COALESCE(work_minutes, 0),
    COALESCE(travel_minutes, 0),
    COALESCE(paid_minutes, 0),
    COALESCE(effective_minutes, 0),
    COALESCE(overtime_authorized_minutes, 0),
    GREATEST(0, COALESCE(overtime_minutes, 0) - COALESCE(overtime_authorized_minutes, 0)),
    day_type,
    COALESCE(worked_minutes, 0)
  INTO
    v_new_work, v_new_travel, v_new_paid, v_new_effective, v_new_ot_auth, v_new_ot_pending,
    v_day_type, v_worked_minutes
  FROM data.time_daily_summaries
  WHERE employee_id = p_employee_id AND work_date = p_work_date;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_cy_key := format('cy:%s', EXTRACT(YEAR FROM p_work_date)::int);
  SELECT COALESCE(overtime_authorized_minutes, 0) INTO v_old_ot_auth
  FROM data.attendance_rollup_day_snapshots
  WHERE employee_id = p_employee_id
    AND work_date = p_work_date
    AND period_key = v_cy_key;

  IF v_new_ot_auth > COALESCE(v_old_ot_auth, 0) THEN
    INSERT INTO data.time_compensation_ledger (
      tenant_id, employee_id, source_work_date,
      movement_type, source_type, minutes, is_credit
    ) VALUES (
      p_tenant_id, p_employee_id, p_work_date,
      'accrued', 'overtime', v_new_ot_auth - COALESCE(v_old_ot_auth, 0), true
    );
  END IF;

  -- C3.3: festiu treballat — crèdit automàtic al consolidar (dedup via sum ledger del dia)
  IF v_day_type = 'holiday' THEN
    v_new_holiday_target := CASE
      WHEN v_new_work > 0 THEN v_new_work
      WHEN v_worked_minutes > 0 THEN v_worked_minutes
      ELSE 0
    END;
  ELSE
    v_new_holiday_target := 0;
  END IF;

  IF v_new_holiday_target > 0 THEN
    SELECT COALESCE(SUM(minutes), 0) INTO v_old_holiday_credit
    FROM data.time_compensation_ledger
    WHERE employee_id = p_employee_id
      AND source_work_date = p_work_date
      AND movement_type = 'accrued'
      AND source_type = 'holiday_worked'
      AND is_credit = true;

    IF v_new_holiday_target > v_old_holiday_credit THEN
      INSERT INTO data.time_compensation_ledger (
        tenant_id, employee_id, source_work_date,
        movement_type, source_type, minutes, is_credit
      ) VALUES (
        p_tenant_id, p_employee_id, p_work_date,
        'accrued', 'holiday_worked',
        v_new_holiday_target - v_old_holiday_credit, true
      );
    END IF;
  END IF;

  v_period_keys := data.attendance_period_keys_for_date(p_work_date, v_period, v_fiscal_month);

  FOREACH v_period_key IN ARRAY v_period_keys LOOP
    IF v_period_key = 'rolling_12m' AND p_work_date < v_today - 365 THEN
      CONTINUE;
    END IF;

    SELECT * INTO v_old
    FROM data.attendance_rollup_day_snapshots
    WHERE employee_id = p_employee_id
      AND work_date = p_work_date
      AND period_key = v_period_key;

    PERFORM data.apply_attendance_rollup_delta(
      p_tenant_id, p_employee_id, v_period_key, v_jurisdiction,
      v_new_work - COALESCE(v_old.work_minutes, 0),
      v_new_travel - COALESCE(v_old.travel_minutes, 0),
      v_new_paid - COALESCE(v_old.paid_minutes, 0),
      v_new_effective - COALESCE(v_old.effective_minutes, 0),
      v_new_ot_auth - COALESCE(v_old.overtime_authorized_minutes, 0),
      v_new_ot_pending - COALESCE(v_old.overtime_pending_minutes, 0)
    );

    INSERT INTO data.attendance_rollup_day_snapshots (
      tenant_id, employee_id, work_date, period_key,
      work_minutes, travel_minutes, paid_minutes, effective_minutes,
      overtime_authorized_minutes, overtime_pending_minutes
    ) VALUES (
      p_tenant_id, p_employee_id, p_work_date, v_period_key,
      v_new_work, v_new_travel, v_new_paid, v_new_effective,
      v_new_ot_auth, v_new_ot_pending
    )
    ON CONFLICT (employee_id, work_date, period_key) DO UPDATE SET
      work_minutes = EXCLUDED.work_minutes,
      travel_minutes = EXCLUDED.travel_minutes,
      paid_minutes = EXCLUDED.paid_minutes,
      effective_minutes = EXCLUDED.effective_minutes,
      overtime_authorized_minutes = EXCLUDED.overtime_authorized_minutes,
      overtime_pending_minutes = EXCLUDED.overtime_pending_minutes,
      updated_at = now();
  END LOOP;

  -- Rolling window exit: subtract day falling out when consolidating today
  IF v_period = 'rolling_12m' AND p_work_date = v_today THEN
    v_exit_date := v_today - 365;
    SELECT * INTO v_old
    FROM data.attendance_rollup_day_snapshots
    WHERE employee_id = p_employee_id
      AND work_date = v_exit_date
      AND period_key = 'rolling_12m';

    IF FOUND THEN
      PERFORM data.apply_attendance_rollup_delta(
        p_tenant_id, p_employee_id, 'rolling_12m', v_jurisdiction,
        -v_old.work_minutes, -v_old.travel_minutes, -v_old.paid_minutes,
        -v_old.effective_minutes, -v_old.overtime_authorized_minutes,
        -v_old.overtime_pending_minutes
      );
    END IF;
  END IF;

  PERFORM data.check_attendance_legal_alerts(p_employee_id, p_work_date, p_tenant_id, p_site_id);
END;
$$;

COMMENT ON FUNCTION data.sync_attendance_rollups_for_day(uuid, date, uuid, uuid) IS
  'Track G5/C3: actualitza rollups anuals, ledger OT autoritzada i festiu treballat, i alertes legals.';
