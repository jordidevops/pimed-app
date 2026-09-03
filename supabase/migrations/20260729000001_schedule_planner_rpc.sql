-- Schedule planner RPCs: bulk resolved labor calendar days + attendance actuals
-- Cascade mirrors frontend buildDayMap (Employee → Group(site) → Site → Group(global) → Tenant → Holiday)

-- ─── Helper: planned minutes from work_intervals / legacy columns ───────────

CREATE OR REPLACE FUNCTION data.labor_planned_minutes(
  p_intervals   jsonb,
  p_work_start  time,
  p_work_end    time
)
RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_total  integer := 0;
  v_iv     jsonb;
  v_s      integer;
  v_e      integer;
  v_sh     integer;
  v_sm     integer;
  v_eh     integer;
  v_em     integer;
BEGIN
  IF p_intervals IS NOT NULL AND jsonb_typeof(p_intervals) = 'array' AND jsonb_array_length(p_intervals) > 0 THEN
    FOR v_iv IN SELECT value FROM jsonb_array_elements(p_intervals)
    LOOP
      v_sh := split_part(v_iv->>'start', ':', 1)::integer;
      v_sm := split_part(v_iv->>'start', ':', 2)::integer;
      v_eh := split_part(v_iv->>'end', ':', 1)::integer;
      v_em := split_part(v_iv->>'end', ':', 2)::integer;
      v_s := v_sh * 60 + v_sm;
      v_e := v_eh * 60 + v_em;
      IF v_e <= v_s THEN v_e := v_e + 24 * 60; END IF;
      v_total := v_total + (v_e - v_s);
    END LOOP;
    RETURN v_total;
  END IF;

  IF p_work_start IS NOT NULL AND p_work_end IS NOT NULL THEN
    v_s := EXTRACT(HOUR FROM p_work_start)::integer * 60 + EXTRACT(MINUTE FROM p_work_start)::integer;
    v_e := EXTRACT(HOUR FROM p_work_end)::integer * 60 + EXTRACT(MINUTE FROM p_work_end)::integer;
    IF v_e <= v_s THEN v_e := v_e + 24 * 60; END IF;
    RETURN v_e - v_s;
  END IF;

  RETURN 0;
END;
$$;

-- ─── Helper: effective work_intervals json from override row ─────────────────

CREATE OR REPLACE FUNCTION data.labor_effective_intervals(
  p_intervals   jsonb,
  p_work_start  time,
  p_work_end    time
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_intervals IS NOT NULL AND jsonb_typeof(p_intervals) = 'array' AND jsonb_array_length(p_intervals) > 0
      THEN p_intervals
    WHEN p_work_start IS NOT NULL AND p_work_end IS NOT NULL
      THEN jsonb_build_array(jsonb_build_object(
        'start', to_char(p_work_start, 'HH24:MI'),
        'end',   to_char(p_work_end, 'HH24:MI')
      ))
    ELSE '[]'::jsonb
  END;
$$;

-- ─── Helper: holiday dates for a site (tenant + site calendars, minus exclusions) ─

CREATE OR REPLACE FUNCTION data.planner_site_holidays(
  p_tenant_id uuid,
  p_site_id   uuid,
  p_from      date,
  p_to        date
)
RETURNS TABLE(holiday_date date, holiday_name text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
  WITH calendar_ids AS (
    SELECT thca.calendar_id
    FROM data.tenant_holiday_calendar_assignments thca
    JOIN data.holiday_calendars hc ON hc.id = thca.calendar_id
    WHERE thca.tenant_id = p_tenant_id
      AND COALESCE(hc.is_active, true) = true
    UNION
    SELECT shca.calendar_id
    FROM data.site_holiday_calendar_assignments shca
    JOIN data.holiday_calendars hc ON hc.id = shca.calendar_id
    WHERE shca.site_id = p_site_id
      AND COALESCE(hc.is_active, true) = true
  )
  SELECT h.date::date, h.name
  FROM data.holidays h
  JOIN calendar_ids c ON c.calendar_id = h.calendar_id
  WHERE h.date BETWEEN p_from AND p_to
    AND NOT EXISTS (
      SELECT 1 FROM data.site_holiday_exclusions she
      WHERE she.site_id = p_site_id AND she.holiday_id = h.id
    );
$$;

-- ─── Internal: resolve one context + date ───────────────────────────────────

CREATE OR REPLACE FUNCTION data.resolve_schedule_planner_day(
  p_tenant_id              uuid,
  p_context_site_id        uuid,
  p_employee_id            uuid,
  p_calendar_group_id      uuid,
  p_calendar_group_site_id uuid,
  p_date                   date,
  p_holiday_name           text
)
RETURNS TABLE(
  day_type          text,
  day_name          text,
  work_intervals    jsonb,
  planned_minutes   integer,
  source            text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_o              data.labor_calendar_overrides%ROWTYPE;
  v_is_site_bound  boolean := p_calendar_group_site_id IS NOT NULL;
BEGIN
  -- Employee override
  IF p_employee_id IS NOT NULL THEN
    SELECT * INTO v_o
    FROM data.labor_calendar_overrides
    WHERE tenant_id = p_tenant_id AND calendar_date = p_date AND employee_id = p_employee_id
    LIMIT 1;
    IF FOUND THEN
      RETURN QUERY SELECT
        v_o.day_type,
        v_o.day_name,
        data.labor_effective_intervals(v_o.work_intervals, v_o.work_start, v_o.work_end),
        CASE WHEN v_o.day_type = 'work'
          THEN data.labor_planned_minutes(v_o.work_intervals, v_o.work_start, v_o.work_end)
          ELSE 0 END,
        'employee_override'::text;
      RETURN;
    END IF;
  END IF;

  -- Group site override
  IF p_calendar_group_id IS NOT NULL AND p_context_site_id IS NOT NULL THEN
    SELECT * INTO v_o
    FROM data.labor_calendar_overrides
    WHERE tenant_id = p_tenant_id AND calendar_date = p_date
      AND group_id = p_calendar_group_id AND site_id = p_context_site_id
    LIMIT 1;
    IF FOUND THEN
      RETURN QUERY SELECT
        v_o.day_type, v_o.day_name,
        data.labor_effective_intervals(v_o.work_intervals, v_o.work_start, v_o.work_end),
        CASE WHEN v_o.day_type = 'work'
          THEN data.labor_planned_minutes(v_o.work_intervals, v_o.work_start, v_o.work_end) ELSE 0 END,
        'group_site_override'::text;
      RETURN;
    END IF;
  END IF;

  -- Site override
  IF p_context_site_id IS NOT NULL THEN
    SELECT * INTO v_o
    FROM data.labor_calendar_overrides
    WHERE tenant_id = p_tenant_id AND calendar_date = p_date
      AND site_id = p_context_site_id AND group_id IS NULL AND employee_id IS NULL
    LIMIT 1;
    IF FOUND THEN
      RETURN QUERY SELECT
        v_o.day_type, v_o.day_name,
        data.labor_effective_intervals(v_o.work_intervals, v_o.work_start, v_o.work_end),
        CASE WHEN v_o.day_type = 'work'
          THEN data.labor_planned_minutes(v_o.work_intervals, v_o.work_start, v_o.work_end) ELSE 0 END,
        'site_override'::text;
      RETURN;
    END IF;
  END IF;

  -- Group global override (skip when group is site-bound)
  IF p_calendar_group_id IS NOT NULL AND NOT v_is_site_bound THEN
    SELECT * INTO v_o
    FROM data.labor_calendar_overrides
    WHERE tenant_id = p_tenant_id AND calendar_date = p_date
      AND group_id = p_calendar_group_id AND site_id IS NULL
    LIMIT 1;
    IF FOUND THEN
      RETURN QUERY SELECT
        v_o.day_type, v_o.day_name,
        data.labor_effective_intervals(v_o.work_intervals, v_o.work_start, v_o.work_end),
        CASE WHEN v_o.day_type = 'work'
          THEN data.labor_planned_minutes(v_o.work_intervals, v_o.work_start, v_o.work_end) ELSE 0 END,
        'group_global_override'::text;
      RETURN;
    END IF;
  END IF;

  -- Tenant override
  SELECT * INTO v_o
  FROM data.labor_calendar_overrides
  WHERE tenant_id = p_tenant_id AND calendar_date = p_date
    AND site_id IS NULL AND group_id IS NULL AND employee_id IS NULL
  LIMIT 1;
  IF FOUND THEN
    RETURN QUERY SELECT
      v_o.day_type, v_o.day_name,
      data.labor_effective_intervals(v_o.work_intervals, v_o.work_start, v_o.work_end),
      CASE WHEN v_o.day_type = 'work'
        THEN data.labor_planned_minutes(v_o.work_intervals, v_o.work_start, v_o.work_end) ELSE 0 END,
      'tenant_override'::text;
    RETURN;
  END IF;

  -- Assigned holiday
  IF p_holiday_name IS NOT NULL THEN
    RETURN QUERY SELECT
      'holiday'::text, p_holiday_name, '[]'::jsonb, 0, 'assigned_holiday'::text;
    RETURN;
  END IF;

  RETURN QUERY SELECT 'undefined'::text, NULL::text, '[]'::jsonb, 0, 'none'::text;
END;
$$;

-- ─── api.get_schedule_planner_days ───────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.get_schedule_planner_days(
  p_site_id      uuid,
  p_from         date,
  p_to           date,
  p_employee_ids uuid[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_result    jsonb;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_active_tenant';
  END IF;

  IF p_site_id IS NULL THEN
    RAISE EXCEPTION 'site_id_required';
  END IF;

  IF NOT (
    data.is_labor_cal_manager(v_tenant_id)
    OR data.jwt_has_permission(v_tenant_id, 'attendance.view_all')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.view_all or manager role required';
  END IF;

  WITH dates AS (
    SELECT d::date AS dt FROM generate_series(p_from, p_to, '1 day'::interval) d
  ),
  employees AS (
    SELECT
      e.id,
      e.site_id,
      e.full_name,
      e.department_id,
      e.calendar_group_id,
      cg.site_id AS calendar_group_site_id
    FROM data.employees e
    LEFT JOIN data.calendar_groups cg ON cg.id = e.calendar_group_id
    WHERE e.tenant_id = v_tenant_id
      AND e.status = 'active'
      AND e.site_id = p_site_id
      AND (p_employee_ids IS NULL OR e.id = ANY(p_employee_ids))
  ),
  holidays AS (
    SELECT holiday_date, holiday_name
    FROM data.planner_site_holidays(v_tenant_id, p_site_id, p_from, p_to)
  ),
  employee_days AS (
    SELECT
      'employee'::text AS scope,
      emp.id AS employee_id,
      emp.site_id,
      emp.full_name AS employee_name,
      emp.department_id,
      emp.calendar_group_id,
      d.dt AS date,
      r.day_type,
      r.day_name,
      r.work_intervals,
      r.planned_minutes,
      r.source
    FROM employees emp
    CROSS JOIN dates d
    LEFT JOIN holidays h ON h.holiday_date = d.dt
    CROSS JOIN LATERAL data.resolve_schedule_planner_day(
      v_tenant_id,
      emp.site_id,
      emp.id,
      emp.calendar_group_id,
      emp.calendar_group_site_id,
      d.dt,
      h.holiday_name
    ) r
  ),
  site_days AS (
    SELECT
      'site'::text AS scope,
      NULL::uuid AS employee_id,
      p_site_id AS site_id,
      NULL::text AS employee_name,
      NULL::uuid AS department_id,
      NULL::uuid AS calendar_group_id,
      d.dt AS date,
      r.day_type,
      r.day_name,
      r.work_intervals,
      r.planned_minutes,
      r.source
    FROM dates d
    LEFT JOIN holidays h ON h.holiday_date = d.dt
    CROSS JOIN LATERAL data.resolve_schedule_planner_day(
      v_tenant_id, p_site_id, NULL, NULL, NULL, d.dt, h.holiday_name
    ) r
  ),
  tenant_days AS (
    SELECT
      'tenant'::text AS scope,
      NULL::uuid AS employee_id,
      NULL::uuid AS site_id,
      NULL::text AS employee_name,
      NULL::uuid AS department_id,
      NULL::uuid AS calendar_group_id,
      d.dt AS date,
      r.day_type,
      r.day_name,
      r.work_intervals,
      r.planned_minutes,
      r.source
    FROM dates d
    LEFT JOIN holidays h ON h.holiday_date = d.dt
    CROSS JOIN LATERAL data.resolve_schedule_planner_day(
      v_tenant_id, NULL, NULL, NULL, NULL, d.dt, h.holiday_name
    ) r
  ),
  combined AS (
    SELECT * FROM tenant_days
    UNION ALL SELECT * FROM site_days
    UNION ALL SELECT * FROM employee_days
  )
  SELECT COALESCE(jsonb_agg(to_jsonb(combined) ORDER BY
    CASE scope WHEN 'tenant' THEN 0 WHEN 'site' THEN 1 ELSE 2 END,
    employee_name NULLS LAST,
    date
  ), '[]'::jsonb)
  INTO v_result
  FROM combined;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_schedule_planner_days(uuid, date, date, uuid[]) TO authenticated;

-- ─── api.get_schedule_planner_actuals ────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.get_schedule_planner_actuals(
  p_site_id      uuid,
  p_from         date,
  p_to           date,
  p_employee_ids uuid[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_result    jsonb;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_active_tenant';
  END IF;

  IF NOT (
    data.is_labor_cal_manager(v_tenant_id)
    OR data.jwt_has_permission(v_tenant_id, 'attendance.view_all')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.work_date, t.employee_id), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT
      tds.employee_id,
      tds.work_date,
      tds.worked_minutes,
      tds.punch_count,
      tds.needs_review,
      tds.anomaly_codes,
      tds.status
    FROM data.time_daily_summaries tds
    JOIN data.employees e ON e.id = tds.employee_id
    WHERE tds.tenant_id = v_tenant_id
      AND tds.work_date BETWEEN p_from AND p_to
      AND (p_site_id IS NULL OR tds.site_id = p_site_id)
      AND e.status = 'active'
      AND (p_employee_ids IS NULL OR tds.employee_id = ANY(p_employee_ids))
  ) t;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_schedule_planner_actuals(uuid, date, date, uuid[]) TO authenticated;

COMMENT ON FUNCTION api.get_schedule_planner_days IS
  'Bulk resolved labor calendar days for schedule planner (tenant/site reference rows + employees).';

COMMENT ON FUNCTION api.get_schedule_planner_actuals IS
  'Attendance daily summaries for schedule planner comparison mode.';
