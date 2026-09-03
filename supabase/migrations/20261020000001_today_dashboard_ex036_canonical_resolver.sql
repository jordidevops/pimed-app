-- =============================================================================
-- EX-03.6 — Dashboard «programat avui» usa el resolver canònic
--
-- api.get_today_dashboard_rows deixava de banda absències (i slots published)
-- perquè cridava data.resolve_schedule_planner_day directament.
-- Ara usa data.resolve_employee_work_plan (mateixa font que resolve_work_day).
--
-- get_schedule_planner_days es manté amb resolve_schedule_planner_day (vista laboral).
-- Portal / export / recordatoris ja usaven api.resolve_work_day.
-- =============================================================================

DROP FUNCTION IF EXISTS api.get_today_dashboard_rows(uuid);

CREATE OR REPLACE FUNCTION api.get_today_dashboard_rows(
  p_site_id   uuid,
  p_work_date date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_tz        text;
  v_today     date;
  v_result    jsonb;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_active_tenant';
  END IF;

  IF p_site_id IS NULL THEN
    RAISE EXCEPTION 'site_id_required';
  END IF;

  IF NOT COALESCE(data.jwt_has_permission(v_tenant_id, 'attendance.view_all', p_site_id), false) THEN
    RAISE EXCEPTION 'insufficient_privilege';
  END IF;

  v_tz := COALESCE(data.get_site_timezone(p_site_id, v_tenant_id), 'Europe/Madrid');
  v_today := COALESCE(p_work_date, (now() AT TIME ZONE v_tz)::date);

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
      COALESCE(
        tds.worked_minutes,
        CASE
          WHEN ps.first_in_at IS NOT NULL
            AND ps.last_out_at IS NOT NULL
            AND ps.last_out_at > ps.first_in_at
          THEN ROUND(EXTRACT(EPOCH FROM (ps.last_out_at - ps.first_in_at)) / 60)::int
          WHEN ps.first_in_at IS NOT NULL
          THEN ROUND(EXTRACT(EPOCH FROM (now() - ps.first_in_at)) / 60)::int
          ELSE 0
        END
      ) AS worked_minutes,
      COALESCE(tds.anomaly_codes, '{}'::text[]) AS anomaly_codes,
      COALESCE(tds.needs_review, false) AS needs_review,
      lp.occurred_at AS sort_key
    FROM (
      SELECT
        emp.id AS employee_id,
        emp.full_name AS employee_name,
        -- Contracte estable UI: «work» (labor) per dies efectivament laborables
        'work'::text AS day_type,
        plan.work_intervals,
        data.labor_expected_start_time(plan.work_intervals) AS expected_start,
        plan.planned_minutes
      FROM data.employees emp
      CROSS JOIN LATERAL (
        SELECT
          p->'work_intervals' AS work_intervals,
          COALESCE((p->>'expected_minutes')::int, 0) AS planned_minutes,
          p->>'day_type' AS plan_day_type,
          COALESCE((p->>'is_absence')::boolean, false) AS is_absence
        FROM (SELECT data.resolve_employee_work_plan(emp.id, v_today) AS p) x
      ) plan
      WHERE emp.tenant_id = v_tenant_id
        AND emp.status = 'active'
        AND emp.site_id = p_site_id
        AND plan.plan_day_type = 'working'
        AND plan.is_absence = false
        AND plan.planned_minutes > 0
    ) s
    LEFT JOIN LATERAL (
      SELECT
        MIN(tp.occurred_at) FILTER (WHERE tp.punch_type = 'in') AS first_in_at,
        MAX(tp.occurred_at) FILTER (WHERE tp.punch_type = 'out') AS last_out_at
      FROM data.time_punches tp
      WHERE tp.employee_id = s.employee_id
        AND (tp.occurred_at AT TIME ZONE v_tz)::date = v_today
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
        AND (tp.occurred_at AT TIME ZONE v_tz)::date = v_today
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

COMMENT ON FUNCTION api.get_today_dashboard_rows(uuid, date) IS
  'EX-03.6: «Programat avui» via data.resolve_employee_work_plan (absències i slots published). '
  'p_work_date opcional (tests / override); per defecte dia local del site.';

GRANT EXECUTE ON FUNCTION api.get_today_dashboard_rows(uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_today_dashboard_rows(uuid, date) TO service_role;
