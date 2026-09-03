-- =============================================================================
-- EX-06.2 — RPCs CRUD cobertura demanda + get_coverage suma legacy + demands
-- =============================================================================

CREATE OR REPLACE FUNCTION api.list_coverage_demands(
  p_site_id uuid,
  p_include_inactive boolean DEFAULT false
)
RETURNS TABLE (
  id uuid,
  tenant_id uuid,
  site_id uuid,
  location_id uuid,
  role_id uuid,
  role_key text,
  role_name text,
  kind text,
  day_of_week smallint,
  demand_date date,
  start_time time,
  end_time time,
  required_min int,
  required_target int,
  required_max int,
  priority int,
  source text,
  name text,
  notes text,
  effective_from date,
  effective_to date,
  is_active boolean,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant uuid;
BEGIN
  IF p_site_id IS NULL THEN
    RAISE EXCEPTION 'site_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT s.tenant_id INTO v_tenant FROM data.sites s WHERE s.id = p_site_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT (
    data.jwt_has_permission(v_tenant, 'labor_calendar.view', p_site_id)
    OR data.jwt_has_permission(v_tenant, 'labor_calendar.manage', p_site_id)
    OR data.jwt_has_permission(v_tenant, 'attendance.view_all', p_site_id)
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.view requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  SELECT
    cd.id, cd.tenant_id, cd.site_id, cd.location_id, cd.role_id,
    wr.key, wr.name,
    cd.kind, cd.day_of_week, cd.demand_date, cd.start_time, cd.end_time,
    cd.required_min, cd.required_target, cd.required_max, cd.priority,
    cd.source, cd.name, cd.notes, cd.effective_from, cd.effective_to,
    cd.is_active, cd.created_at, cd.updated_at
  FROM data.coverage_demands cd
  LEFT JOIN data.work_roles wr ON wr.id = cd.role_id
  WHERE cd.site_id = p_site_id
    AND (p_include_inactive OR cd.is_active)
  ORDER BY cd.kind, cd.priority, cd.demand_date NULLS LAST, cd.day_of_week NULLS LAST, cd.start_time;
END;
$$;

CREATE OR REPLACE FUNCTION api.upsert_coverage_demand(
  p_id              uuid DEFAULT NULL,
  p_site_id         uuid DEFAULT NULL,
  p_location_id     uuid DEFAULT NULL,
  p_role_id         uuid DEFAULT NULL,
  p_kind            text DEFAULT NULL,
  p_day_of_week     smallint DEFAULT NULL,
  p_demand_date     date DEFAULT NULL,
  p_start_time      time DEFAULT NULL,
  p_end_time        time DEFAULT NULL,
  p_required_min    int DEFAULT 0,
  p_required_target int DEFAULT NULL,
  p_required_max    int DEFAULT NULL,
  p_priority        int DEFAULT 100,
  p_source          text DEFAULT 'manual',
  p_name            text DEFAULT NULL,
  p_notes           text DEFAULT NULL,
  p_effective_from  date DEFAULT NULL,
  p_effective_to    date DEFAULT NULL,
  p_is_active       boolean DEFAULT true,
  p_clear_location  boolean DEFAULT false,
  p_clear_role      boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_row data.coverage_demands;
  v_tenant uuid;
  v_site uuid;
  v_kind text;
  v_from date;
  v_to date;
  v_loc uuid;
  v_role uuid;
BEGIN
  IF p_id IS NOT NULL THEN
    SELECT * INTO v_row FROM data.coverage_demands WHERE id = p_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'coverage_demand_not_found' USING ERRCODE = 'P0002';
    END IF;
    v_tenant := v_row.tenant_id;
    v_site := v_row.site_id;
  ELSE
    IF p_site_id IS NULL THEN
      RAISE EXCEPTION 'site_id_required' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    SELECT s.tenant_id INTO v_tenant FROM data.sites s WHERE s.id = p_site_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'site_not_found' USING ERRCODE = 'P0002';
    END IF;
    v_site := p_site_id;
  END IF;

  IF NOT COALESCE(data.jwt_has_permission(v_tenant, 'labor_calendar.manage', v_site), false) THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_kind := COALESCE(p_kind, v_row.kind);
  IF v_kind IS NULL OR v_kind NOT IN ('recurring', 'extraordinary') THEN
    RAISE EXCEPTION 'invalid_demand_kind' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_id IS NULL THEN
    IF p_start_time IS NULL OR p_end_time IS NULL OR p_required_target IS NULL THEN
      RAISE EXCEPTION 'start_end_target_required' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_kind = 'recurring' AND p_day_of_week IS NULL THEN
      RAISE EXCEPTION 'day_of_week_required_for_recurring' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_kind = 'extraordinary' AND p_demand_date IS NULL THEN
      RAISE EXCEPTION 'demand_date_required_for_extraordinary' USING ERRCODE = 'invalid_parameter_value';
    END IF;
  END IF;

  IF p_clear_location THEN
    v_loc := NULL;
  ELSIF p_location_id IS NOT NULL THEN
    v_loc := p_location_id;
  ELSE
    v_loc := v_row.location_id;
  END IF;

  IF p_clear_role THEN
    v_role := NULL;
  ELSIF p_role_id IS NOT NULL THEN
    v_role := p_role_id;
  ELSE
    v_role := v_row.role_id;
  END IF;

  IF v_kind = 'extraordinary' THEN
    v_from := COALESCE(p_effective_from, p_demand_date, v_row.demand_date, CURRENT_DATE);
    v_to := COALESCE(p_effective_to, (COALESCE(p_demand_date, v_row.demand_date) + 1));
  ELSE
    v_from := COALESCE(p_effective_from, v_row.effective_from, CURRENT_DATE);
    v_to := COALESCE(p_effective_to, v_row.effective_to);
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO data.coverage_demands (
      tenant_id, site_id, location_id, role_id, kind, day_of_week, demand_date,
      start_time, end_time, required_min, required_target, required_max,
      priority, source, name, notes, effective_from, effective_to, is_active
    ) VALUES (
      v_tenant, v_site, v_loc, v_role, v_kind,
      CASE WHEN v_kind = 'recurring' THEN p_day_of_week ELSE NULL END,
      CASE WHEN v_kind = 'extraordinary' THEN p_demand_date ELSE NULL END,
      p_start_time, p_end_time,
      COALESCE(p_required_min, 0), p_required_target, p_required_max,
      COALESCE(p_priority, 100), COALESCE(nullif(btrim(p_source), ''), 'manual'),
      nullif(btrim(p_name), ''), p_notes, v_from, v_to, COALESCE(p_is_active, true)
    )
    RETURNING * INTO v_row;
  ELSE
    UPDATE data.coverage_demands
    SET location_id = v_loc,
        role_id = v_role,
        kind = v_kind,
        day_of_week = CASE
          WHEN v_kind = 'recurring' THEN COALESCE(p_day_of_week, day_of_week)
          ELSE NULL
        END,
        demand_date = CASE
          WHEN v_kind = 'extraordinary' THEN COALESCE(p_demand_date, demand_date)
          ELSE NULL
        END,
        start_time = COALESCE(p_start_time, start_time),
        end_time = COALESCE(p_end_time, end_time),
        required_min = COALESCE(p_required_min, required_min),
        required_target = COALESCE(p_required_target, required_target),
        required_max = CASE
          WHEN p_required_max IS NOT NULL THEN p_required_max
          ELSE required_max
        END,
        priority = COALESCE(p_priority, priority),
        source = COALESCE(nullif(btrim(p_source), ''), source),
        name = COALESCE(nullif(btrim(p_name), ''), name),
        notes = COALESCE(p_notes, notes),
        effective_from = v_from,
        effective_to = v_to,
        is_active = COALESCE(p_is_active, is_active),
        updated_at = now()
    WHERE id = p_id
    RETURNING * INTO v_row;
  END IF;

  RETURN to_jsonb(v_row);
END;
$$;

CREATE OR REPLACE FUNCTION api.deactivate_coverage_demand(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_row data.coverage_demands;
BEGIN
  SELECT * INTO v_row FROM data.coverage_demands WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'coverage_demand_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT COALESCE(data.jwt_has_permission(v_row.tenant_id, 'labor_calendar.manage', v_row.site_id), false) THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.coverage_demands
  SET is_active = false, updated_at = now()
  WHERE id = p_id
  RETURNING * INTO v_row;

  RETURN to_jsonb(v_row);
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_coverage_demands(uuid, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.upsert_coverage_demand(
  uuid, uuid, uuid, uuid, text, smallint, date, time, time, int, int, int, int, text, text, text, date, date, boolean, boolean, boolean
) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.deactivate_coverage_demand(uuid) TO authenticated, service_role;

-- ─── get_coverage_for_period: legacy SCR + coverage_demands ──────────────────

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
      (
        COALESCE((
          SELECT SUM(scr.required_employees)
          FROM data.shift_coverage_requirements scr
          WHERE scr.site_id = p_site_id
            AND (scr.day_of_week IS NULL OR scr.day_of_week = EXTRACT(DOW FROM gs.d)::smallint)
            AND scr.effective_from <= gs.d::date
            AND (scr.effective_to IS NULL OR scr.effective_to > gs.d::date)
        ), 0)
        + data.sum_coverage_demand_target(p_site_id, gs.d::date)
      )::int AS required_employee_count,
      (
        COUNT(DISTINCT ss.employee_id)
        - (
          COALESCE((
            SELECT SUM(scr.required_employees)
            FROM data.shift_coverage_requirements scr
            WHERE scr.site_id = p_site_id
              AND (scr.day_of_week IS NULL OR scr.day_of_week = EXTRACT(DOW FROM gs.d)::smallint)
              AND scr.effective_from <= gs.d::date
              AND (scr.effective_to IS NULL OR scr.effective_to > gs.d::date)
          ), 0)
          + data.sum_coverage_demand_target(p_site_id, gs.d::date)
        )
      )::int AS coverage_delta,
      COALESCE(jsonb_agg(DISTINCT jsonb_build_object(
        'requirement_id', scr.id,
        'shift_id', scr.shift_id,
        'required_employees', scr.required_employees,
        'source', 'legacy'
      )) FILTER (WHERE scr.id IS NOT NULL), '[]'::jsonb)
      || COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'demand_id', cd.id,
          'role_id', cd.role_id,
          'location_id', cd.location_id,
          'kind', cd.kind,
          'start_time', cd.start_time,
          'end_time', cd.end_time,
          'required_target', cd.required_target,
          'source', cd.source
        ))
        FROM data.coverage_demands cd
        WHERE cd.site_id = p_site_id
          AND data.coverage_demand_applies_on(cd, gs.d::date)
      ), '[]'::jsonb) AS requirements,
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
    GROUP BY gs.d
  ) AS day_row;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_coverage_for_period(uuid, date, date) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
