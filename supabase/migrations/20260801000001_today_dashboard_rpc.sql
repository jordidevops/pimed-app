-- Today dashboard: scheduled workers only, arrival context, sorted by last punch

CREATE OR REPLACE FUNCTION data.labor_expected_start_time(p_intervals jsonb)
RETURNS time
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_intervals IS NOT NULL
      AND jsonb_typeof(p_intervals) = 'array'
      AND jsonb_array_length(p_intervals) > 0
      AND (p_intervals->0->>'start') ~ '^\d{2}:\d{2}$'
    THEN (p_intervals->0->>'start')::time
    ELSE NULL
  END;
$$;

CREATE OR REPLACE FUNCTION api.get_today_dashboard_rows(p_site_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_today     date := (now() AT TIME ZONE 'Europe/Madrid')::date;
  v_result    jsonb;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_active_tenant';
  END IF;

  IF p_site_id IS NULL THEN
    RAISE EXCEPTION 'site_id_required';
  END IF;

  IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.view_all', p_site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.sort_key DESC NULLS LAST, t.employee_name), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT
      s.employee_id,
      s.employee_name,
      s.day_type,
      s.work_intervals,
      to_char(s.expected_start, 'HH24:MI') AS expected_start,
      s.planned_minutes,
      CASE
        WHEN lp.punch_type IS NULL OR lp.punch_type = 'out' THEN 'outside'
        WHEN lp.punch_type = 'in' THEN 'working'
        WHEN lp.punch_type = 'break_start' THEN 'on_pause'
        WHEN lp.punch_type = 'break_end' THEN 'working'
        ELSE 'unknown'
      END AS current_state,
      lp.punch_type AS last_punch_type,
      lp.pause_type AS last_pause_type,
      lp.occurred_at AS last_punch_at,
      lp.is_remote AS last_is_remote,
      lp.geo_lat,
      lp.geo_lng,
      lp.geo_accuracy_m,
      ps.first_in_at,
      COALESCE(tds.anomaly_codes, '{}'::text[]) AS anomaly_codes,
      COALESCE(tds.needs_review, false) AS needs_review,
      lp.occurred_at AS sort_key
    FROM (
      SELECT
        emp.id AS employee_id,
        emp.full_name AS employee_name,
        r.day_type,
        r.work_intervals,
        data.labor_expected_start_time(r.work_intervals) AS expected_start,
        r.planned_minutes
      FROM data.employees emp
      LEFT JOIN data.calendar_groups cg ON cg.id = emp.calendar_group_id
      LEFT JOIN LATERAL (
        SELECT h.holiday_name
        FROM data.planner_site_holidays(v_tenant_id, p_site_id, v_today, v_today) h
        WHERE h.holiday_date = v_today
        LIMIT 1
      ) hol ON true
      CROSS JOIN LATERAL data.resolve_schedule_planner_day(
        v_tenant_id,
        emp.site_id,
        emp.id,
        emp.calendar_group_id,
        cg.site_id,
        v_today,
        hol.holiday_name
      ) r
      WHERE emp.tenant_id = v_tenant_id
        AND emp.status = 'active'
        AND emp.site_id = p_site_id
        AND r.day_type = 'work'
    ) s
    LEFT JOIN LATERAL (
      SELECT
        MIN(tp.occurred_at) FILTER (WHERE tp.punch_type = 'in') AS first_in_at
      FROM data.time_punches tp
      WHERE tp.employee_id = s.employee_id
        AND (tp.occurred_at AT TIME ZONE 'Europe/Madrid')::date = v_today
    ) ps ON true
    LEFT JOIN LATERAL (
      SELECT
        tp.punch_type,
        tp.pause_type,
        tp.occurred_at,
        tp.is_remote,
        tp.geo_lat,
        tp.geo_lng,
        tp.geo_accuracy_m
      FROM data.time_punches tp
      WHERE tp.employee_id = s.employee_id
        AND (tp.occurred_at AT TIME ZONE 'Europe/Madrid')::date = v_today
      ORDER BY tp.occurred_at DESC, tp.id DESC
      LIMIT 1
    ) lp ON true
    LEFT JOIN data.time_daily_summaries tds
      ON tds.employee_id = s.employee_id
      AND tds.work_date = v_today
  ) t;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_today_dashboard_rows(uuid) TO authenticated;

COMMENT ON FUNCTION api.get_today_dashboard_rows IS
  'Dashboard rows for employees scheduled to work today, with punch and arrival context.';
