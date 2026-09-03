-- Migration: 20260528000003_fix_coverage_group_by
-- Fix: api.get_coverage_for_period — error 42803 "subquery uses ungrouped column gs.d"
--
-- El problema: els correlated subqueries dins el SELECT referencien gs.d (columna bruta
-- de generate_series, de tipus timestamptz). El GROUP BY era gs.d::date (expressió derivada),
-- i PostgreSQL no reconeix gs.d com a columna agrupada → error 42803.
--
-- Solució: GROUP BY gs.d (la columna bruta). Semànticament equivalent perquè
-- generate_series amb interval '1 day' produeix exactament un timestamp per dia,
-- sense duplicats dins del mateix date. gs.d::date segueix sent una expressió vàlida
-- sobre una columna agrupada.

CREATE OR REPLACE FUNCTION api.get_coverage_for_period(
  p_site_id uuid,
  p_from date,
  p_to date
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant_id uuid;
  v_result jsonb;
BEGIN
  SELECT s.tenant_id INTO v_tenant_id FROM data.sites s WHERE s.id = p_site_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_not_found: %', p_site_id USING ERRCODE = 'P0002';
  END IF;

  IF NOT (data.jwt_user_tenants() ? v_tenant_id::text) THEN
    RAISE EXCEPTION 'insufficient_privilege: no ets membre del tenant'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT (
    data.jwt_has_permission(v_tenant_id, 'attendance.view_all')
    OR data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage')
    OR data.jwt_has_permission(v_tenant_id, 'labor_calendar.view')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.view o view_all requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT jsonb_agg(day_row ORDER BY work_date)
  INTO v_result
  FROM (
    SELECT
      gs.d::date AS work_date,
      COUNT(DISTINCT ss.employee_id) AS employee_count,
      COALESCE((
        SELECT SUM(scr.required_employees)
        FROM data.shift_coverage_requirements scr
        WHERE scr.site_id = p_site_id
          AND (scr.day_of_week IS NULL OR scr.day_of_week = EXTRACT(DOW FROM gs.d)::smallint)
          AND scr.effective_from <= gs.d::date
          AND (scr.effective_to IS NULL OR scr.effective_to > gs.d::date)
      ), 0)::int AS required_employee_count,
      (
        COUNT(DISTINCT ss.employee_id)
        - COALESCE((
          SELECT SUM(scr.required_employees)
          FROM data.shift_coverage_requirements scr
          WHERE scr.site_id = p_site_id
            AND (scr.day_of_week IS NULL OR scr.day_of_week = EXTRACT(DOW FROM gs.d)::smallint)
            AND scr.effective_from <= gs.d::date
            AND (scr.effective_to IS NULL OR scr.effective_to > gs.d::date)
        ), 0)
      )::int AS coverage_delta,
      COALESCE(jsonb_agg(DISTINCT jsonb_build_object(
        'requirement_id', scr.id,
        'shift_id', scr.shift_id,
        'required_employees', scr.required_employees
      )) FILTER (WHERE scr.id IS NOT NULL), '[]'::jsonb) AS requirements,
      COALESCE(jsonb_agg(DISTINCT jsonb_build_object(
        'slot_id', ss.id,
        'employee_id', ss.employee_id,
        'shift_id', ss.shift_id,
        'shift_name', ws.name,
        'color', ws.color,
        'start_time', ss.start_time,
        'end_time', ss.end_time,
        'spans_midnight', (ss.end_time < ss.start_time),
        'status', ss.status
      )) FILTER (WHERE ss.id IS NOT NULL), '[]'::jsonb) AS slots
    FROM generate_series(p_from, p_to, '1 day'::interval) AS gs(d)
    LEFT JOIN data.shift_slots ss
      ON ss.slot_date = gs.d::date
     AND ss.site_id = p_site_id
     AND ss.status <> 'cancelled'
    LEFT JOIN data.work_shifts ws ON ws.id = ss.shift_id
    LEFT JOIN data.shift_coverage_requirements scr
      ON scr.site_id = p_site_id
     AND (scr.day_of_week IS NULL OR scr.day_of_week = EXTRACT(DOW FROM gs.d)::smallint)
     AND scr.effective_from <= gs.d::date
     AND (scr.effective_to IS NULL OR scr.effective_to > gs.d::date)
    GROUP BY gs.d  -- FIX: was gs.d::date → correlated subqueries need the raw column
  ) AS day_row;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;
