-- Fase 2 (plan-period-employee-confirm): RPCs confirmació per període + sync AMR + audit.

-- ── Helpers ISO setmana (dilluns–diumenge) ─────────────────────────────────────

CREATE OR REPLACE FUNCTION data.iso_week_start(p_date date)
RETURNS date
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT p_date - ((EXTRACT(DOW FROM p_date)::int + 6) % 7);
$$;

CREATE OR REPLACE FUNCTION data.iso_week_end(p_date date)
RETURNS date
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT data.iso_week_start(p_date) + 6;
$$;

CREATE OR REPLACE FUNCTION data.list_calendar_month_iso_weeks(
  p_year  int,
  p_month int
)
RETURNS TABLE(period_from date, period_to date)
LANGUAGE sql
STABLE
AS $$
  WITH month_bounds AS (
    SELECT
      make_date(p_year, p_month, 1) AS month_start,
      (make_date(p_year, p_month, 1) + interval '1 month' - interval '1 day')::date AS month_end
  ),
  days AS (
    SELECT generate_series(mb.month_start, mb.month_end, interval '1 day')::date AS d
    FROM month_bounds mb
  ),
  weeks AS (
    SELECT DISTINCT data.iso_week_start(d) AS week_start
    FROM days
  )
  SELECT week_start, week_start + 6
  FROM weeks
  ORDER BY 1;
$$;

CREATE OR REPLACE FUNCTION data.attendance_employee_confirm_cycle(p_settings jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN COALESCE(p_settings ->> 'attendance_employee_confirm_cycle', 'calendar_month') = 'iso_week'
      THEN 'iso_week'
    ELSE 'calendar_month'
  END;
$$;

-- ── Estat confirmacions del mes legal ─────────────────────────────────────────

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

GRANT EXECUTE ON FUNCTION api.get_attendance_month_period_status(uuid, int, int) TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_attendance_month_period_status(uuid, int, int) TO service_role;

-- ── Llistar confirmacions per període ─────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.list_attendance_period_confirmations(
  p_employee_id   uuid,
  p_calendar_year int DEFAULT NULL,
  p_calendar_month int DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp  record;
  v_rows jsonb := '[]'::jsonb;
BEGIN
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
    ORDER BY c.period_from DESC, c.confirmed_at DESC
  ), '[]'::jsonb)
  INTO v_rows
  FROM data.attendance_period_confirmations c
  WHERE c.employee_id = p_employee_id
    AND (p_calendar_year IS NULL OR c.calendar_year = p_calendar_year)
    AND (p_calendar_month IS NULL OR c.calendar_month = p_calendar_month);

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'calendar_year', p_calendar_year,
    'calendar_month', p_calendar_month,
    'confirmations', v_rows
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_attendance_period_confirmations(uuid, int, int) TO authenticated;
GRANT EXECUTE ON FUNCTION api.list_attendance_period_confirmations(uuid, int, int) TO service_role;

-- ── Sync AMR des de confirmacions de període ──────────────────────────────────

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

-- ── Confirmació per període ───────────────────────────────────────────────────

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

GRANT EXECUTE ON FUNCTION api.confirm_attendance_period(uuid, date, date, text, int, int, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.confirm_attendance_period(uuid, date, date, text, int, int, uuid) TO service_role;

-- ── Wrapper mensual (tenant app) ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.confirm_attendance_month(
  p_employee_id uuid,
  p_year        int,
  p_month       int
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp    record;
  v_from   date;
  v_to     date;
  v_settings jsonb;
  v_cycle  text;
  v_report_id uuid;
BEGIN
  IF p_month < 1 OR p_month > 12 THEN
    RAISE EXCEPTION 'invalid_month';
  END IF;

  SELECT e.tenant_id, e.site_id, e.user_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.user_id = auth.uid();

  IF v_emp.tenant_id IS NULL THEN
    RAISE EXCEPTION 'insufficient_privilege';
  END IF;

  v_settings := data.merge_effective_settings_for_service(v_emp.tenant_id, v_emp.site_id);
  v_cycle := data.attendance_employee_confirm_cycle(v_settings);

  IF v_cycle = 'iso_week' THEN
    RAISE EXCEPTION 'employee_confirm_cycle_requires_weekly'
      USING ERRCODE = 'check_violation';
  END IF;

  v_from := make_date(p_year, p_month, 1);
  v_to   := (v_from + interval '1 month' - interval '1 day')::date;

  PERFORM api.confirm_attendance_period(
    p_employee_id,
    v_from,
    v_to,
    'tenant_app',
    p_year,
    p_month,
    NULL
  );

  SELECT amr.id INTO v_report_id
  FROM data.attendance_monthly_reports amr
  WHERE amr.employee_id = p_employee_id
    AND amr.year = p_year
    AND amr.month = p_month;

  RETURN v_report_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.confirm_attendance_month(uuid, int, int) TO authenticated;

-- ── Portal empleat: confirmació mensual via període ───────────────────────────

CREATE OR REPLACE FUNCTION api.employee_portal_confirm_monthly_report(
  p_employee_id uuid,
  p_tenant_id   uuid,
  p_year        int,
  p_month       int
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp         record;
  v_settings    jsonb;
  v_status      text;
  v_require_sig boolean;
  v_cycle       text;
  v_from        date;
  v_to          date;
  v_report_id   uuid;
BEGIN
  SELECT e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND e.tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF p_month < 1 OR p_month > 12 THEN
    RAISE EXCEPTION 'invalid_month' USING ERRCODE = 'check_violation';
  END IF;

  v_settings := data.merge_effective_settings_for_service(v_emp.tenant_id, v_emp.site_id);
  v_require_sig := COALESCE(
    (v_settings->>'attendance_monthly_require_digital_signature')::boolean,
    false
  );

  IF v_require_sig THEN
    RAISE EXCEPTION 'digital_signature_required'
      USING ERRCODE = 'check_violation';
  END IF;

  v_cycle := data.attendance_employee_confirm_cycle(v_settings);
  IF v_cycle = 'iso_week' THEN
    RAISE EXCEPTION 'employee_confirm_cycle_requires_weekly'
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT amr.status INTO v_status
  FROM data.attendance_monthly_reports amr
  WHERE amr.employee_id = p_employee_id
    AND amr.year = p_year
    AND amr.month = p_month;

  IF v_status IN ('employee_confirmed', 'manager_approved', 'signed', 'archived') THEN
    RAISE EXCEPTION 'already_confirmed' USING ERRCODE = 'check_violation';
  END IF;

  v_from := make_date(p_year, p_month, 1);
  v_to   := (v_from + interval '1 month' - interval '1 day')::date;

  PERFORM api.confirm_attendance_period(
    p_employee_id,
    v_from,
    v_to,
    'employee_portal',
    p_year,
    p_month,
    NULL
  );

  SELECT amr.id INTO v_report_id
  FROM data.attendance_monthly_reports amr
  WHERE amr.employee_id = p_employee_id
    AND amr.year = p_year
    AND amr.month = p_month;

  RETURN v_report_id;
END;
$$;

REVOKE ALL ON FUNCTION api.employee_portal_confirm_monthly_report(uuid, uuid, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_portal_confirm_monthly_report(uuid, uuid, int, int) TO service_role;

-- ── Portal GET: cicle + estat períodes ────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.employee_portal_get_monthly_report(
  p_employee_id uuid,
  p_tenant_id   uuid,
  p_year        int,
  p_month       int
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp            record;
  v_report         record;
  v_has_report     boolean := false;
  v_export         jsonb;
  v_settings       jsonb;
  v_validation     jsonb;
  v_signing        jsonb := NULL;
  v_from           date;
  v_to             date;
  v_payroll        jsonb;
  v_calendar_days  jsonb;
  v_worked_days    int := 0;
  v_laborable_days int := 0;
  v_absence_days   int := 0;
  v_overtime_total int := 0;
  v_presence_total int := 0;
  v_effective_total int := 0;
  v_paid_total     int := 0;
  v_travel_total   int := 0;
  v_has_effective  boolean := false;
  v_expected_total int := 0;
  v_period_status  jsonb;
BEGIN
  SELECT e.id, e.tenant_id, e.site_id, e.full_name, e.email
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND e.tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF p_month < 1 OR p_month > 12 THEN
    RAISE EXCEPTION 'invalid_month' USING ERRCODE = 'check_violation';
  END IF;

  v_from := make_date(p_year, p_month, 1);
  v_to   := (v_from + interval '1 month' - interval '1 day')::date;

  v_export := api.export_attendance_month(p_employee_id, p_year, p_month);
  v_validation := api.validate_attendance_month_employee_confirm(p_employee_id, p_year, p_month);
  v_settings := data.merge_effective_settings_for_service(v_emp.tenant_id, v_emp.site_id);
  v_payroll := api.get_payroll_review_days(p_employee_id, v_from, v_to);
  v_period_status := api.get_attendance_month_period_status(p_employee_id, p_year, p_month);

  v_has_effective := COALESCE((v_export -> 'summary' ->> 'has_effective_time')::boolean, false);

  SELECT COALESCE(jsonb_agg(enriched ORDER BY enriched ->> 'work_date'), '[]'::jsonb)
  INTO v_calendar_days
  FROM (
    SELECT
      day_row
      || jsonb_build_object(
        'starts_at', te.starts_at,
        'ends_at', te.ends_at,
        'net_minutes', te.net_minutes,
        'break_minutes', te.break_minutes,
        'balance_minutes',
          COALESCE(
            NULLIF((day_row ->> 'worked_minutes')::int, 0),
            te.net_minutes,
            0
          ) - COALESCE((day_row ->> 'expected_minutes')::int, 0)
      ) AS enriched
    FROM jsonb_array_elements(COALESCE(v_payroll -> 'days', '[]'::jsonb)) AS day_row
    LEFT JOIN data.time_entries te
      ON te.employee_id = p_employee_id
     AND te.work_date = (day_row ->> 'work_date')::date
  ) sub;

  SELECT
    COUNT(*) FILTER (WHERE COALESCE((d ->> 'worked_minutes')::int, 0) > 0),
    COUNT(*) FILTER (WHERE COALESCE((d ->> 'is_laborable')::boolean, false)),
    COUNT(*) FILTER (WHERE d ->> 'absence_id' IS NOT NULL),
    COALESCE(SUM(COALESCE((d ->> 'overtime_minutes')::int, 0)), 0),
    COALESCE(SUM(COALESCE((d ->> 'presence_minutes')::int, 0)), 0),
    COALESCE(SUM(COALESCE((d ->> 'effective_minutes')::int, 0)), 0),
    COALESCE(SUM(COALESCE((d ->> 'paid_minutes')::int, 0)), 0),
    COALESCE(SUM(COALESCE((d ->> 'travel_minutes')::int, 0)), 0),
    COALESCE(SUM(COALESCE((d ->> 'expected_minutes')::int, 0)), 0)
  INTO v_worked_days, v_laborable_days, v_absence_days, v_overtime_total,
       v_presence_total, v_effective_total, v_paid_total, v_travel_total, v_expected_total
  FROM jsonb_array_elements(COALESCE(v_calendar_days, '[]'::jsonb)) AS d;

  SELECT
    amr.id,
    amr.status,
    amr.confirmed_at,
    amr.approved_at,
    amr.signing_submission_id,
    amr.document_id,
    amr.content_hash
  INTO v_report
  FROM data.attendance_monthly_reports amr
  WHERE amr.employee_id = p_employee_id
    AND amr.year = p_year
    AND amr.month = p_month;

  v_has_report := FOUND;

  IF v_has_report AND v_report.signing_submission_id IS NOT NULL THEN
    SELECT jsonb_build_object(
      'submission_id', ss.id,
      'status', ss.status,
      'signers', ss.signers
    )
    INTO v_signing
    FROM data.signing_submissions ss
    WHERE ss.id = v_report.signing_submission_id;
  END IF;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'tenant_id', p_tenant_id,
    'year', p_year,
    'month', p_month,
    'employee_name', v_emp.full_name,
    'employee_email', v_emp.email,
    'report', CASE
      WHEN NOT v_has_report THEN jsonb_build_object(
        'id', NULL,
        'status', 'draft',
        'confirmed_at', NULL,
        'approved_at', NULL,
        'signing_submission_id', NULL,
        'document_id', NULL,
        'content_hash', NULL
      )
      ELSE jsonb_build_object(
        'id', v_report.id,
        'status', v_report.status,
        'confirmed_at', v_report.confirmed_at,
        'approved_at', v_report.approved_at,
        'signing_submission_id', v_report.signing_submission_id,
        'document_id', v_report.document_id,
        'content_hash', v_report.content_hash
      )
    END,
    'export', v_export,
    'calendar_days', COALESCE(v_calendar_days, '[]'::jsonb),
    'settings', jsonb_build_object(
      'employee_confirm_required', COALESCE(
        (v_settings->>'attendance_monthly_employee_confirm_required')::boolean, true
      ),
      'require_digital_signature', COALESCE(
        (v_settings->>'attendance_monthly_require_digital_signature')::boolean, false
      ),
      'employee_confirm_cycle', data.attendance_employee_confirm_cycle(v_settings)
    ),
    'validation', v_validation,
    'period_status', v_period_status,
    'signing', v_signing,
    'summary', jsonb_build_object(
      'worked_minutes', COALESCE((v_export -> 'summary' ->> 'worked_minutes')::int, 0),
      'expected_minutes', v_expected_total,
      'difference_minutes',
        COALESCE((v_export -> 'summary' ->> 'worked_minutes')::int, 0) - v_expected_total,
      'worked_days', v_worked_days,
      'laborable_days', v_laborable_days,
      'absence_days', v_absence_days,
      'overtime_minutes', v_overtime_total,
      'presence_minutes', CASE WHEN v_has_effective THEN v_presence_total ELSE NULL END,
      'effective_minutes', CASE WHEN v_has_effective THEN v_effective_total ELSE NULL END,
      'paid_minutes', CASE WHEN v_has_effective THEN v_paid_total ELSE NULL END,
      'travel_minutes', CASE WHEN v_has_effective THEN v_travel_total ELSE NULL END,
      'has_effective_time', v_has_effective
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION api.employee_portal_get_monthly_report(uuid, uuid, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_portal_get_monthly_report(uuid, uuid, int, int) TO service_role;

COMMENT ON FUNCTION api.confirm_attendance_period IS
  'Confirma un període de dates; sincronitza attendance_monthly_reports quan el mes legal queda cobert.';

NOTIFY pgrst, 'reload schema';
