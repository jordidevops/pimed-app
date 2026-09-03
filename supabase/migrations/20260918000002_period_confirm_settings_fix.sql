-- Fix: SECURITY DEFINER period RPCs must use merge_effective_settings_for_service (no auth context).

CREATE OR REPLACE FUNCTION data.sync_attendance_monthly_report_from_periods(
  p_employee_id   uuid,
  p_year          int,
  p_month         int,
  p_confirmed_by  uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp           record;
  v_settings      jsonb;
  v_cycle         text;
  v_month_from    date;
  v_month_to      date;
  v_fully_ok      boolean := false;
  v_report_id     uuid;
  v_prev_status   text;
  v_actor         uuid;
BEGIN
  SELECT e.id, e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  v_month_from := make_date(p_year, p_month, 1);
  v_month_to   := (v_month_from + interval '1 month' - interval '1 day')::date;

  v_settings := data.merge_effective_settings_for_service(v_emp.tenant_id, v_emp.site_id);
  v_cycle := data.attendance_employee_confirm_cycle(v_settings);

  IF v_cycle = 'calendar_month' THEN
    SELECT EXISTS (
      SELECT 1
      FROM data.attendance_period_confirmations c
      WHERE c.employee_id = p_employee_id
        AND c.period_from = v_month_from
        AND c.period_to = v_month_to
    ) INTO v_fully_ok;
  ELSE
    SELECT
      (SELECT COUNT(*) FROM data.list_calendar_month_iso_weeks(p_year, p_month)) > 0
      AND NOT EXISTS (
        SELECT 1
        FROM data.list_calendar_month_iso_weeks(p_year, p_month) w
        WHERE NOT EXISTS (
          SELECT 1
          FROM data.attendance_period_confirmations c
          WHERE c.employee_id = p_employee_id
            AND c.period_from = w.period_from
            AND c.period_to = w.period_to
        )
      )
    INTO v_fully_ok;
  END IF;

  IF NOT v_fully_ok THEN
    RETURN NULL;
  END IF;

  SELECT amr.id, amr.status
  INTO v_report_id, v_prev_status
  FROM data.attendance_monthly_reports amr
  WHERE amr.employee_id = p_employee_id
    AND amr.year = p_year
    AND amr.month = p_month;

  v_actor := COALESCE(p_confirmed_by, auth.uid());

  IF v_report_id IS NULL THEN
    INSERT INTO data.attendance_monthly_reports (
      tenant_id, employee_id, year, month, status, confirmed_by, confirmed_at
    ) VALUES (
      v_emp.tenant_id, p_employee_id, p_year, p_month,
      'employee_confirmed', v_actor, now()
    )
    RETURNING id INTO v_report_id;
    v_prev_status := 'draft';
  ELSIF v_prev_status IN ('draft') THEN
    UPDATE data.attendance_monthly_reports amr
    SET
      status = 'employee_confirmed',
      confirmed_by = COALESCE(v_actor, amr.confirmed_by),
      confirmed_at = COALESCE(amr.confirmed_at, now()),
      updated_at = now()
    WHERE amr.id = v_report_id;
  ELSE
    RETURN v_report_id;
  END IF;

  IF v_prev_status = 'draft' THEN
    PERFORM data.log_attendance_employee_audit(
      v_emp.tenant_id,
      v_actor,
      v_emp.site_id,
      p_employee_id,
      'ATTENDANCE_MONTH_EMPLOYEE_CONFIRMED',
      jsonb_build_object(
        'year', p_year,
        'month', p_month,
        'report_id', v_report_id,
        'source', 'period_sync'
      )
    );
  END IF;

  RETURN v_report_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.get_attendance_month_period_status(
  p_employee_id uuid,
  p_year        int,
  p_month       int
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp            record;
  v_settings       jsonb;
  v_cycle          text;
  v_month_from     date;
  v_month_to       date;
  v_confirmations  jsonb := '[]'::jsonb;
  v_weeks_required int := 0;
  v_weeks_confirmed int := 0;
  v_month_period_confirmed boolean := false;
  v_week           record;
BEGIN
  IF p_month < 1 OR p_month > 12 THEN
    RAISE EXCEPTION 'invalid_month';
  END IF;

  SELECT e.id, e.tenant_id, e.site_id, e.user_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF NOT (
      data.jwt_has_permission(v_emp.tenant_id, 'attendance.view_all', v_emp.site_id)
      OR v_emp.user_id = auth.uid()
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege';
    END IF;
  END IF;

  v_month_from := make_date(p_year, p_month, 1);
  v_month_to   := (v_month_from + interval '1 month' - interval '1 day')::date;

  v_settings := data.merge_effective_settings_for_service(v_emp.tenant_id, v_emp.site_id);
  v_cycle := data.attendance_employee_confirm_cycle(v_settings);

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', c.id,
      'period_from', c.period_from,
      'period_to', c.period_to,
      'cycle_type', c.cycle_type,
      'calendar_year', c.calendar_year,
      'calendar_month', c.calendar_month,
      'confirmed_at', c.confirmed_at,
      'confirmed_via', c.confirmed_via
    )
    ORDER BY c.period_from
  ), '[]'::jsonb)
  INTO v_confirmations
  FROM data.attendance_period_confirmations c
  WHERE c.employee_id = p_employee_id
    AND c.calendar_year = p_year
    AND c.calendar_month = p_month;

  SELECT EXISTS (
    SELECT 1
    FROM data.attendance_period_confirmations c
    WHERE c.employee_id = p_employee_id
      AND c.period_from = v_month_from
      AND c.period_to = v_month_to
      AND c.cycle_type = 'calendar_month'
  ) INTO v_month_period_confirmed;

  IF v_cycle = 'iso_week' THEN
    FOR v_week IN
      SELECT w.period_from, w.period_to
      FROM data.list_calendar_month_iso_weeks(p_year, p_month) w
    LOOP
      v_weeks_required := v_weeks_required + 1;
      IF EXISTS (
        SELECT 1
        FROM data.attendance_period_confirmations c
        WHERE c.employee_id = p_employee_id
          AND c.period_from = v_week.period_from
          AND c.period_to = v_week.period_to
      ) THEN
        v_weeks_confirmed := v_weeks_confirmed + 1;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'cycle', v_cycle,
    'month_from', v_month_from,
    'month_to', v_month_to,
    'confirmations', v_confirmations,
    'weeks_required', v_weeks_required,
    'weeks_confirmed', v_weeks_confirmed,
    'month_period_confirmed', v_month_period_confirmed,
    'month_fully_confirmed', CASE
      WHEN v_cycle = 'calendar_month' THEN v_month_period_confirmed
      ELSE v_weeks_required > 0 AND v_weeks_confirmed = v_weeks_required
    END
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.confirm_attendance_period(
  p_employee_id       uuid,
  p_period_from       date,
  p_period_to         date,
  p_confirmed_via     text DEFAULT 'tenant_app',
  p_calendar_year     int DEFAULT NULL,
  p_calendar_month    int DEFAULT NULL,
  p_source_session_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp            record;
  v_settings       jsonb;
  v_cycle          text;
  v_cycle_type     text;
  v_check          jsonb;
  v_id             uuid;
  v_report_id      uuid;
  v_cal_year       int;
  v_cal_month      int;
  v_month_from     date;
  v_month_to       date;
  v_actor          uuid;
BEGIN
  IF p_period_from IS NULL OR p_period_to IS NULL OR p_period_from > p_period_to THEN
    RAISE EXCEPTION 'invalid_period_range';
  END IF;

  IF p_confirmed_via NOT IN ('employee_portal', 'tenant_app') THEN
    RAISE EXCEPTION 'invalid_confirmed_via';
  END IF;

  SELECT e.id, e.tenant_id, e.site_id, e.user_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  v_actor := auth.uid();

  IF v_actor IS NOT NULL THEN
    IF NOT (
      v_emp.user_id = v_actor
      OR data.jwt_has_permission(v_emp.tenant_id, 'attendance.approve', v_emp.site_id)
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege';
    END IF;
  ELSIF p_confirmed_via <> 'employee_portal' THEN
    RAISE EXCEPTION 'insufficient_privilege';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM data.attendance_period_confirmations c
    WHERE c.employee_id = p_employee_id
      AND c.period_from = p_period_from
      AND c.period_to = p_period_to
  ) THEN
    RAISE EXCEPTION 'period_already_confirmed'
      USING ERRCODE = 'check_violation';
  END IF;

  v_settings := data.merge_effective_settings_for_service(v_emp.tenant_id, v_emp.site_id);
  v_cycle := data.attendance_employee_confirm_cycle(v_settings);

  v_cal_year := COALESCE(p_calendar_year, EXTRACT(YEAR FROM p_period_from)::int);
  v_cal_month := COALESCE(p_calendar_month, EXTRACT(MONTH FROM p_period_from)::int);
  v_month_from := make_date(v_cal_year, v_cal_month, 1);
  v_month_to   := (v_month_from + interval '1 month' - interval '1 day')::date;

  IF v_cycle = 'calendar_month' THEN
    IF p_period_from <> v_month_from OR p_period_to <> v_month_to THEN
      RAISE EXCEPTION 'invalid_period_for_cycle'
        USING ERRCODE = 'check_violation',
              DETAIL = 'calendar_month requires full natural month range';
    END IF;
    v_cycle_type := 'calendar_month';
  ELSIF v_cycle = 'iso_week' THEN
    IF p_period_from <> data.iso_week_start(p_period_from)
       OR p_period_to <> p_period_from + 6 THEN
      RAISE EXCEPTION 'invalid_period_for_cycle'
        USING ERRCODE = 'check_violation',
              DETAIL = 'iso_week requires Monday–Sunday range';
    END IF;
    IF p_period_from > v_month_to OR p_period_to < v_month_from THEN
      RAISE EXCEPTION 'invalid_period_for_cycle'
        USING ERRCODE = 'check_violation',
              DETAIL = 'iso_week must intersect calendar month reference';
    END IF;
    v_cycle_type := 'iso_week';
  ELSE
    v_cycle_type := 'manual';
  END IF;

  v_check := api.validate_attendance_period_employee_confirm(
    p_employee_id, p_period_from, p_period_to
  );
  IF NOT COALESCE((v_check ->> 'confirmable')::boolean, false) THEN
    RAISE EXCEPTION 'period_not_confirmable'
      USING ERRCODE = 'check_violation',
            DETAIL = v_check::text;
  END IF;

  INSERT INTO data.attendance_period_confirmations (
    tenant_id,
    employee_id,
    period_from,
    period_to,
    cycle_type,
    calendar_year,
    calendar_month,
    confirmed_via,
    source_session_id
  ) VALUES (
    v_emp.tenant_id,
    p_employee_id,
    p_period_from,
    p_period_to,
    v_cycle_type,
    v_cal_year,
    v_cal_month,
    p_confirmed_via,
    p_source_session_id
  )
  RETURNING id INTO v_id;

  PERFORM data.log_attendance_employee_audit(
    v_emp.tenant_id,
    v_actor,
    v_emp.site_id,
    p_employee_id,
    'ATTENDANCE_PERIOD_EMPLOYEE_CONFIRMED',
    jsonb_build_object(
      'period_from', p_period_from,
      'period_to', p_period_to,
      'cycle_type', v_cycle_type,
      'year', v_cal_year,
      'month', v_cal_month,
      'confirmation_id', v_id,
      'source', CASE
        WHEN p_confirmed_via = 'employee_portal' THEN 'employee_portal'
        ELSE 'tenant_app'
      END
    )
  );

  v_report_id := data.sync_attendance_monthly_report_from_periods(
    p_employee_id,
    v_cal_year,
    v_cal_month,
    v_actor
  );

  RETURN v_id;
END;
$$;

NOTIFY pgrst, 'reload schema';
