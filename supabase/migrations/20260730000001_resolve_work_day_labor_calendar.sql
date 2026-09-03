-- Phase 4: align api.resolve_work_day with labor_calendar_overrides cascade
-- (same resolution as schedule planner / buildDayMap via data.resolve_schedule_planner_day)

-- ─── Helper: first/last shift bounds from work_intervals jsonb ─────────────────

CREATE OR REPLACE FUNCTION data.labor_intervals_shift_bounds(p_intervals jsonb)
RETURNS TABLE(shift_start time, shift_end time, spans_midnight boolean)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_iv     jsonb;
  v_start  time;
  v_end    time;
  v_sh     int;
  v_sm     int;
  v_eh     int;
  v_em     int;
  v_first  time;
  v_last   time;
  v_overnight boolean := false;
BEGIN
  IF p_intervals IS NULL OR jsonb_typeof(p_intervals) <> 'array' OR jsonb_array_length(p_intervals) = 0 THEN
    RETURN QUERY SELECT NULL::time, NULL::time, false;
    RETURN;
  END IF;

  FOR v_iv IN SELECT value FROM jsonb_array_elements(p_intervals)
  LOOP
    v_start := (split_part(v_iv->>'start', ':', 1) || ':' || split_part(v_iv->>'start', ':', 2))::time;
    v_end   := (split_part(v_iv->>'end', ':', 1) || ':' || split_part(v_iv->>'end', ':', 2))::time;

    v_sh := split_part(v_iv->>'start', ':', 1)::integer;
    v_sm := split_part(v_iv->>'start', ':', 2)::integer;
    v_eh := split_part(v_iv->>'end', ':', 1)::integer;
    v_em := split_part(v_iv->>'end', ':', 2)::integer;
    IF (v_eh * 60 + v_em) <= (v_sh * 60 + v_sm) THEN
      v_overnight := true;
    END IF;

    IF v_first IS NULL OR v_start < v_first THEN v_first := v_start; END IF;
    IF v_last IS NULL OR v_end > v_last THEN v_last := v_end; END IF;
  END LOOP;

  RETURN QUERY SELECT v_first, v_last, v_overnight;
END;
$$;

-- ─── Internal: resolve labor calendar for one employee+date ───────────────────

CREATE OR REPLACE FUNCTION data.resolve_labor_calendar_for_employee(
  p_tenant_id   uuid,
  p_site_id     uuid,
  p_employee_id uuid,
  p_work_date   date,
  p_skip_holiday boolean DEFAULT false
)
RETURNS TABLE(
  labor_day_type    text,
  labor_day_name    text,
  work_intervals    jsonb,
  planned_minutes   integer,
  labor_source      text,
  is_half_day       boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_group_id       uuid;
  v_group_site_id  uuid;
  v_holiday_name   text;
  v_half_day       boolean := false;
  r                record;
BEGIN
  SELECT e.calendar_group_id, cg.site_id
  INTO v_group_id, v_group_site_id
  FROM data.employees e
  LEFT JOIN data.calendar_groups cg ON cg.id = e.calendar_group_id
  WHERE e.id = p_employee_id;

  IF NOT p_skip_holiday AND p_site_id IS NOT NULL THEN
    SELECT h.holiday_name INTO v_holiday_name
    FROM data.planner_site_holidays(p_tenant_id, p_site_id, p_work_date, p_work_date) h
    LIMIT 1;

    IF v_holiday_name IS NOT NULL THEN
      SELECT COALESCE(h.is_half_day, false) INTO v_half_day
      FROM data.holidays h
      WHERE h.date = p_work_date
        AND h.name = v_holiday_name
      LIMIT 1;
    END IF;
  END IF;

  SELECT * INTO r
  FROM data.resolve_schedule_planner_day(
    p_tenant_id, p_site_id, p_employee_id,
    v_group_id, v_group_site_id,
    p_work_date, v_holiday_name
  );

  RETURN QUERY SELECT
    r.day_type,
    r.day_name,
    r.work_intervals,
    r.planned_minutes,
    r.source,
    v_half_day;
END;
$$;

-- ─── api.resolve_work_day — labor calendar v1 cascade ───────────────────────

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

  v_tz := COALESCE(
    (api.get_effective_settings(
      p_site_id   => v_emp.site_id,
      p_user_id   => NULL,
      p_tenant_id => v_emp.tenant_id
    ) ->> 'site_timezone'),
    'Europe/Madrid'
  );

  -- 1. Approved absence (highest priority)
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
    SELECT lc.planned_minutes INTO v_expected_min
    FROM data.resolve_labor_calendar_for_employee(
      v_emp.tenant_id, v_emp.site_id, p_employee_id, p_work_date, false
    ) lc
    WHERE lc.labor_day_type = 'work';

    v_expected_min := COALESCE(v_expected_min, 0);

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
      'employee_override',     false,
      'labor_source',          'absence'
    );
  END IF;

  -- 2. Legacy employee_day_overrides (force_holiday / force_work)
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
        'employee_override', true,
        'labor_source', 'employee_day_override'
      );
    ELSIF v_emp_override = 'force_work' THEN
      v_skip_holiday := true;
    END IF;
  END IF;

  -- 3. Labor calendar cascade (labor_calendar_overrides + assigned holidays)
  SELECT * INTO v_labor
  FROM data.resolve_labor_calendar_for_employee(
    v_emp.tenant_id, v_emp.site_id, p_employee_id, p_work_date, v_skip_holiday
  );

  v_expected_min := COALESCE(v_labor.planned_minutes, 0);
  v_holiday_name := v_labor.labor_day_name;
  v_is_holiday := v_labor.labor_day_type = 'holiday'
    OR (v_labor.labor_source = 'assigned_holiday');

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
    'employee_override', COALESCE(v_emp_override = 'force_work', false),
    'labor_source',      v_labor.labor_source,
    'labor_day_type',    v_labor.labor_day_type
  );
END;
$$;

COMMENT ON FUNCTION api.resolve_work_day IS
  'Resolves expected work pattern for an employee on a date. Uses labor_calendar_overrides cascade (aligned with schedule planner).';

COMMENT ON FUNCTION data.resolve_labor_calendar_for_employee IS
  'Employee-scoped labor calendar resolution wrapper for attendance worker.';
