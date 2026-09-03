-- Schedule planner actuals: include punch-only days when daily summary not yet recomputed

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

    UNION ALL

    SELECT
      ps.employee_id,
      ps.work_date,
      CASE
        WHEN ps.first_in IS NOT NULL AND ps.last_out IS NOT NULL AND ps.last_out > ps.first_in
          THEN ROUND(EXTRACT(EPOCH FROM (ps.last_out - ps.first_in)) / 60)::int
        WHEN ps.first_in IS NOT NULL
          THEN ROUND(EXTRACT(EPOCH FROM (now() - ps.first_in)) / 60)::int
        ELSE 0
      END AS worked_minutes,
      ps.punch_count,
      (cardinality(COALESCE(pa.anomaly_codes, '{}'::text[])) > 0) AS needs_review,
      COALESCE(pa.anomaly_codes, '{}'::text[]) AS anomaly_codes,
      CASE
        WHEN ps.first_in IS NOT NULL AND ps.last_out IS NOT NULL AND ps.last_out > ps.first_in
          THEN 'closed'
        WHEN ps.punch_count > 0 THEN 'open'
        ELSE 'missing'
      END AS status
    FROM (
      SELECT
        tp.employee_id,
        (tp.occurred_at AT TIME ZONE 'Europe/Madrid')::date AS work_date,
        COUNT(*)::int AS punch_count,
        MIN(tp.occurred_at) FILTER (WHERE tp.punch_type = 'in') AS first_in,
        MAX(tp.occurred_at) FILTER (WHERE tp.punch_type = 'out') AS last_out
      FROM data.time_punches tp
      JOIN data.employees e ON e.id = tp.employee_id
      WHERE tp.tenant_id = v_tenant_id
        AND (tp.occurred_at AT TIME ZONE 'Europe/Madrid')::date BETWEEN p_from AND p_to
        AND (p_site_id IS NULL OR tp.site_id = p_site_id)
        AND e.status = 'active'
        AND (p_employee_ids IS NULL OR tp.employee_id = ANY(p_employee_ids))
      GROUP BY tp.employee_id, (tp.occurred_at AT TIME ZONE 'Europe/Madrid')::date
    ) ps
    LEFT JOIN (
      SELECT
        tp.employee_id,
        (tp.occurred_at AT TIME ZONE 'Europe/Madrid')::date AS work_date,
        COALESCE(array_agg(DISTINCT unnest_a), '{}'::text[]) AS anomaly_codes
      FROM data.time_punches tp
      CROSS JOIN LATERAL unnest(tp.anomaly_codes) AS unnest_a
      JOIN data.employees e ON e.id = tp.employee_id
      WHERE tp.tenant_id = v_tenant_id
        AND (tp.occurred_at AT TIME ZONE 'Europe/Madrid')::date BETWEEN p_from AND p_to
        AND (p_site_id IS NULL OR tp.site_id = p_site_id)
        AND e.status = 'active'
        AND (p_employee_ids IS NULL OR tp.employee_id = ANY(p_employee_ids))
      GROUP BY tp.employee_id, (tp.occurred_at AT TIME ZONE 'Europe/Madrid')::date
    ) pa ON pa.employee_id = ps.employee_id AND pa.work_date = ps.work_date
    WHERE ps.punch_count > 0
      AND NOT EXISTS (
        SELECT 1
        FROM data.time_daily_summaries tds2
        WHERE tds2.employee_id = ps.employee_id
          AND tds2.work_date = ps.work_date
      )
  ) t;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION api.get_schedule_planner_actuals IS
  'Attendance daily summaries for schedule planner; falls back to live punch aggregation when summary pending.';
