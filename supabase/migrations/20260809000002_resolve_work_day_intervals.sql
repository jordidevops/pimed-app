-- Expose work_intervals in resolve_work_day for punch page / employee self-service UI.

CREATE OR REPLACE FUNCTION api.resolve_work_day(
  p_employee_id  uuid,
  p_work_date    date
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp                 record;
  v_tz                  text;
  v_expected_min        int     := 0;
  v_spans_midnight      boolean := false;
  v_shift_start         time;
  v_shift_end           time;
  v_day_type            text    := 'unknown';
  v_absence             record;
  v_emp_override        text;
  v_skip_holiday        boolean := false;
  v_labor               record;
  v_bounds              record;
  v_is_holiday          boolean := false;
  v_holiday_name        text;
  v_work_intervals      jsonb;
BEGIN
  SELECT e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'day_type', 'unknown',
      'expected_minutes', 0,
      'error', 'employee_not_found'
    );
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF NOT (data.jwt_user_tenants() ? v_emp.tenant_id::text) THEN
      RAISE EXCEPTION 'insufficient_privilege: access denied for employee %', p_employee_id
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NOT (
      data.jwt_has_permission(v_emp.tenant_id, 'attendance.view_all')
      OR data.jwt_has_permission(v_emp.tenant_id, 'labor_calendar.manage')
      OR EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = p_employee_id AND e.user_id = auth.uid()
      )
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege: necessites attendance.view_all o ser l''empleat consultat'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  v_tz := COALESCE(data.get_site_timezone(v_emp.site_id, v_emp.tenant_id), 'Europe/Madrid');

  SELECT ea.id, ea.absence_type, ea.is_paid, ea.hours_per_day
  INTO v_absence
  FROM data.employee_absences ea
  WHERE ea.employee_id = p_employee_id
    AND ea.status      = 'approved'
    AND ea.start_date  <= p_work_date
    AND ea.end_date    >= p_work_date
  ORDER BY ea.created_at DESC
  LIMIT 1;

  IF FOUND THEN
    SELECT lc.planned_minutes, lc.work_intervals
    INTO v_expected_min, v_work_intervals
    FROM data.resolve_labor_calendar_for_employee(
      v_emp.tenant_id, v_emp.site_id, p_employee_id, p_work_date, false
    ) lc
    WHERE lc.labor_day_type = 'work';

    v_expected_min := COALESCE(v_expected_min, 0);
    v_work_intervals := COALESCE(v_work_intervals, '[]'::jsonb);

    RETURN jsonb_build_object(
      'day_type',              'absence',
      'expected_minutes',      v_expected_min,
      'site_timezone',         v_tz,
      'is_holiday',            false,
      'holiday_name',          null,
      'is_absence',            true,
      'absence_id',            v_absence.id,
      'absence_type',          v_absence.absence_type,
      'absence_is_paid',       v_absence.is_paid,
      'absence_hours_per_day', v_absence.hours_per_day,
      'schedule_id',           null,
      'schedule_name',         null,
      'spans_midnight',        false,
      'shift_start_time',      null,
      'shift_end_time',        null,
      'work_intervals',        v_work_intervals,
      'employee_override',     false,
      'labor_source',          'absence'
    );
  END IF;

  SELECT edo.override_type INTO v_emp_override
  FROM data.employee_day_overrides edo
  WHERE edo.employee_id  = p_employee_id
    AND edo.override_date = p_work_date;

  IF FOUND THEN
    IF v_emp_override = 'force_holiday' THEN
      RETURN jsonb_build_object(
        'day_type', 'holiday',
        'expected_minutes', 0,
        'site_timezone', v_tz,
        'is_holiday', true,
        'holiday_name', null,
        'holiday_type', 'tenant_custom',
        'is_half_day', false,
        'is_absence', false,
        'absence_id', null,
        'absence_type', null,
        'schedule_id', null,
        'schedule_name', null,
        'spans_midnight', false,
        'shift_start_time', null,
        'shift_end_time', null,
        'work_intervals', '[]'::jsonb,
        'employee_override', true,
        'labor_source', 'employee_day_override'
      );
    ELSIF v_emp_override = 'force_work' THEN
      v_skip_holiday := true;
    END IF;
  END IF;

  SELECT * INTO v_labor
  FROM data.resolve_labor_calendar_for_employee(
    v_emp.tenant_id, v_emp.site_id, p_employee_id, p_work_date, v_skip_holiday
  );

  v_expected_min := COALESCE(v_labor.planned_minutes, 0);
  v_holiday_name := v_labor.labor_day_name;
  v_is_holiday := v_labor.labor_day_type = 'holiday'
    OR (v_labor.labor_source = 'assigned_holiday');
  v_work_intervals := COALESCE(v_labor.work_intervals, '[]'::jsonb);

  CASE v_labor.labor_day_type
    WHEN 'work' THEN
      v_day_type := 'working';
      SELECT * INTO v_bounds FROM data.labor_intervals_shift_bounds(v_labor.work_intervals);
      v_shift_start := v_bounds.shift_start;
      v_shift_end := v_bounds.shift_end;
      v_spans_midnight := COALESCE(v_bounds.spans_midnight, false);

    WHEN 'holiday' THEN
      v_day_type := CASE WHEN COALESCE(v_labor.is_half_day, false) THEN 'half_holiday' ELSE 'holiday' END;
      v_expected_min := 0;
      v_is_holiday := true;

    WHEN 'vacation', 'leave' THEN
      v_day_type := 'non_working';
      v_expected_min := 0;

    ELSE
      v_day_type := 'unknown';
      v_expected_min := 0;
  END CASE;

  RETURN jsonb_build_object(
    'day_type',          v_day_type,
    'expected_minutes',  v_expected_min,
    'site_timezone',     v_tz,
    'is_holiday',        v_is_holiday,
    'holiday_name',      v_holiday_name,
    'holiday_type',      CASE WHEN v_is_holiday THEN 'assigned' ELSE null END,
    'is_half_day',       COALESCE(v_labor.is_half_day, false),
    'is_absence',        false,
    'absence_id',        null,
    'absence_type',      null,
    'schedule_id',       null,
    'schedule_name',     null,
    'spans_midnight',    v_spans_midnight,
    'shift_start_time',  v_shift_start,
    'shift_end_time',    v_shift_end,
    'work_intervals',    v_work_intervals,
    'employee_override', COALESCE(v_emp_override = 'force_work', false),
    'labor_source',      v_labor.labor_source,
    'labor_day_type',    v_labor.labor_day_type
  );
END;
$$;
