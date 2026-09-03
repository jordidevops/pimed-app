-- =============================================================================
-- EC-WFM P0 §5 — evaluate_employee_assignment
-- Composes lifecycle, work context, site, availability, absences, role quals,
-- overlap, workload, labor rules, holidays, closed periods.
-- Wires into api.assign_shift_slot for transactional revalidation.
-- =============================================================================

CREATE OR REPLACE FUNCTION data.evaluate_employee_assignment(
  p_employee_id uuid,
  p_site_id uuid,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_role_id uuid DEFAULT NULL,
  p_exclude_slot_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_work_date date;
  v_start_time time;
  v_end_time time;
  v_emp record;
  v_ctx jsonb;
  v_blocks jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_status text := 'ready';
  v_avail text;
  v_labor jsonb;
  v_issue jsonb;
  v_closed jsonb;
  v_eff_hours numeric;
  v_week_start date;
  v_shift_min int;
  v_week_min int;
  v_holiday_name text;
  v_life text;
BEGIN
  IF p_employee_id IS NULL OR p_starts_at IS NULL OR p_ends_at IS NULL THEN
    RETURN jsonb_build_object(
      'status', 'blocked',
      'blocks', jsonb_build_array(jsonb_build_object(
        'code', 'invalid_args',
        'rule', 'input',
        'source', 'evaluate_employee_assignment'
      )),
      'warnings', '[]'::jsonb,
      'resolver_version', 'ec_wfm_p0_v1'
    );
  END IF;

  IF p_ends_at <= p_starts_at THEN
    -- overnight window: still valid for time extraction via date of start
    NULL;
  END IF;

  SELECT e.id, e.tenant_id, e.status, e.lifecycle_state, e.site_id, e.full_name
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'status', 'blocked',
      'blocks', jsonb_build_array(jsonb_build_object(
        'code', 'employee_not_found',
        'rule', 'lifecycle',
        'source', 'data.employees'
      )),
      'warnings', '[]'::jsonb,
      'resolver_version', 'ec_wfm_p0_v1'
    );
  END IF;

  DECLARE
    v_tz text := 'Europe/Madrid';
  BEGIN
    IF p_site_id IS NOT NULL THEN
      v_tz := coalesce(data.get_site_timezone(p_site_id, v_emp.tenant_id), 'Europe/Madrid');
    END IF;
    v_work_date := (p_starts_at AT TIME ZONE v_tz)::date;
    v_start_time := (p_starts_at AT TIME ZONE v_tz)::time;
    v_end_time := (p_ends_at AT TIME ZONE v_tz)::time;
  END;

  v_ctx := data.resolve_employee_work_context(p_employee_id, v_work_date, p_site_id);

  IF v_ctx IS NULL THEN
    v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
      'code', 'work_context_unavailable',
      'rule', 'work_context',
      'source', 'resolve_employee_work_context'
    ));
  ELSE
    v_work_date := coalesce((v_ctx->>'work_date')::date, v_work_date);
  END IF;

  -- Lifecycle / employee status
  v_life := coalesce(v_emp.lifecycle_state, v_emp.status);
  IF v_emp.status = 'terminated'
     OR v_life IN ('terminated', 'offboarding') THEN
    v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
      'code', 'employee_not_active',
      'rule', 'lifecycle',
      'source', 'employees.lifecycle_state',
      'detail', v_life
    ));
  ELSIF v_emp.status IS DISTINCT FROM 'active'
        AND v_life IS DISTINCT FROM 'active' THEN
    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
      'code', 'employee_lifecycle_non_active',
      'rule', 'lifecycle',
      'source', 'employees.lifecycle_state',
      'detail', v_life
    ));
  END IF;

  -- Site eligibility from work context
  IF p_site_id IS NOT NULL AND v_ctx IS NOT NULL THEN
    IF coalesce((v_ctx->'requested_site'->>'eligible')::boolean, true) = false THEN
      v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
        'code', 'employee_wrong_site',
        'rule', 'placement',
        'source', 'resolve_employee_work_context',
        'detail', jsonb_build_object(
          'requested', p_site_id,
          'placement', v_ctx->'placement'->>'site_id'
        )
      ));
    END IF;
  END IF;

  -- Closed periods
  v_closed := data.shift_closed_period_issues(
    jsonb_build_array(jsonb_build_object(
      'employee_id', p_employee_id,
      'work_date', v_work_date
    ))
  );
  FOR v_issue IN SELECT * FROM jsonb_array_elements(coalesce(v_closed, '[]'::jsonb))
  LOOP
    v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
      'code', v_issue->>'code',
      'rule', 'closed_period',
      'source', 'shift_closed_period_issues',
      'detail', v_issue->>'message'
    ));
  END LOOP;

  -- Absences
  IF EXISTS (
    SELECT 1
    FROM data.employee_absences ea
    WHERE ea.employee_id = p_employee_id
      AND ea.status IN ('approved', 'active', 'closed')
      AND ea.start_date <= v_work_date
      AND coalesce(ea.end_date, ea.start_date) >= v_work_date
  ) THEN
    v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
      'code', 'employee_on_absence',
      'rule', 'absence',
      'source', 'employee_absences'
    ));
  END IF;

  -- Role qualifications
  IF p_role_id IS NOT NULL THEN
    IF NOT data.employee_meets_role_qualifications(p_employee_id, p_role_id, v_work_date) THEN
      v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
        'code', 'role_qualifications_unmet',
        'rule', 'certification',
        'source', 'employee_meets_role_qualifications'
      ));
    END IF;
  END IF;

  -- Shift overlap (warning — assign historically soft-flags; openings may still hard-block)
  IF EXISTS (
    SELECT 1
    FROM data.shift_slots ss
    WHERE ss.employee_id = p_employee_id
      AND ss.status <> 'cancelled'
      AND (p_exclude_slot_id IS NULL OR ss.id <> p_exclude_slot_id)
      AND ss.slot_date BETWEEN v_work_date - 1 AND v_work_date + 1
      AND data.shift_slots_overlap(
        v_work_date, v_start_time, v_end_time,
        ss.slot_date, ss.start_time, ss.end_time
      )
  ) THEN
    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
      'code', 'SHIFT_OVERLAP',
      'rule', 'overlap',
      'source', 'shift_slots'
    ));
  END IF;

  -- Availability
  v_avail := data.employee_availability_for_window(
    p_employee_id, v_work_date, v_start_time, v_end_time
  );
  IF v_avail = 'unavailable' THEN
    v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
      'code', 'availability_unavailable',
      'rule', 'availability',
      'source', 'employee_availability_for_window'
    ));
  ELSIF v_avail = 'unknown' THEN
    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
      'code', 'availability_unknown',
      'rule', 'availability',
      'source', 'employee_availability_for_window'
    ));
  END IF;

  -- Weekly hours (warning)
  v_eff_hours := NULLIF(v_ctx->'workload'->>'weekly_hours', '')::numeric;
  IF v_eff_hours IS NULL THEN
    v_eff_hours := data.employee_effective_weekly_hours(p_employee_id, v_work_date);
  END IF;

  v_week_start := date_trunc('week', v_work_date::timestamptz)::date;
  v_shift_min := ROUND(EXTRACT(EPOCH FROM CASE
    WHEN v_end_time > v_start_time THEN v_end_time - v_start_time
    ELSE interval '24 hours' + (v_end_time - v_start_time)
  END) / 60)::int;

  SELECT coalesce(SUM(ROUND(EXTRACT(EPOCH FROM CASE
    WHEN ss.end_time > ss.start_time THEN ss.end_time - ss.start_time
    ELSE interval '24 hours' + (ss.end_time - ss.start_time)
  END) / 60)), 0)::int
  INTO v_week_min
  FROM data.shift_slots ss
  WHERE ss.employee_id = p_employee_id
    AND ss.slot_date >= v_week_start
    AND ss.slot_date <= v_week_start + 6
    AND ss.status <> 'cancelled'
    AND (p_exclude_slot_id IS NULL OR ss.id <> p_exclude_slot_id);

  IF v_eff_hours IS NOT NULL
     AND (v_week_min + v_shift_min) > (v_eff_hours * 60) THEN
    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
      'code', 'WEEKLY_HOURS_EXCEEDED',
      'rule', 'workload',
      'source', 'resolve_employee_work_context',
      'detail', jsonb_build_object(
        'weekly_hours', v_eff_hours,
        'week_minutes', v_week_min,
        'shift_minutes', v_shift_min
      )
    ));
  END IF;

  -- Labor rules
  IF p_site_id IS NOT NULL THEN
    v_labor := data.evaluate_labor_rules_for_window(
      p_employee_id, p_site_id, v_work_date, v_start_time, v_end_time, NULL
    );
    FOR v_issue IN SELECT * FROM jsonb_array_elements(coalesce(v_labor->'issues', '[]'::jsonb))
    LOOP
      IF v_issue->>'severity' = 'block' THEN
        v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
          'code', v_issue->>'code',
          'rule', 'labor_rules',
          'source', 'evaluate_labor_rules_for_window',
          'detail', v_issue
        ));
      ELSE
        v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
          'code', v_issue->>'code',
          'rule', 'labor_rules',
          'source', 'evaluate_labor_rules_for_window',
          'detail', v_issue
        ));
      END IF;
    END LOOP;
  END IF;

  -- Site holiday (warning)
  IF p_site_id IS NOT NULL THEN
    SELECT h.holiday_name INTO v_holiday_name
    FROM data.planner_site_holidays(v_emp.tenant_id, p_site_id, v_work_date, v_work_date) h
    WHERE h.holiday_date = v_work_date
    LIMIT 1;

    IF FOUND THEN
      v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
        'code', 'SITE_HOLIDAY',
        'rule', 'holiday',
        'source', 'planner_site_holidays',
        'detail', v_holiday_name
      ));
    END IF;
  END IF;

  IF jsonb_array_length(v_blocks) > 0 THEN
    v_status := 'blocked';
  ELSIF jsonb_array_length(v_warnings) > 0 THEN
    v_status := 'warning';
  ELSE
    v_status := 'ready';
  END IF;

  RETURN jsonb_build_object(
    'status', v_status,
    'ready', v_status = 'ready',
    'blocks', v_blocks,
    'warnings', v_warnings,
    'availability', v_avail,
    'labor', v_labor,
    'work_context', v_ctx,
    'work_date', v_work_date,
    'start_time', v_start_time,
    'end_time', v_end_time,
    'employee_id', p_employee_id,
    'site_id', p_site_id,
    'role_id', p_role_id,
    'resolver_version', 'ec_wfm_p0_v1'
  );
END;
$$;

COMMENT ON FUNCTION data.evaluate_employee_assignment(uuid, uuid, timestamptz, timestamptz, uuid, uuid) IS
  'EC-WFM P0 §5: assignment readiness ready|warning|blocked with rule provenance.';

-- Convenience: date + wall-clock times (shift model)
CREATE OR REPLACE FUNCTION data.evaluate_employee_assignment(
  p_employee_id uuid,
  p_site_id uuid,
  p_work_date date,
  p_start_time time,
  p_end_time time,
  p_role_id uuid DEFAULT NULL,
  p_exclude_slot_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant uuid;
  v_tz text := 'Europe/Madrid';
  v_starts timestamptz;
  v_ends timestamptz;
BEGIN
  SELECT tenant_id INTO v_tenant FROM data.employees WHERE id = p_employee_id;
  IF p_site_id IS NOT NULL AND v_tenant IS NOT NULL THEN
    v_tz := coalesce(data.get_site_timezone(p_site_id, v_tenant), 'Europe/Madrid');
  END IF;

  v_starts := (p_work_date::text || ' ' || p_start_time::text)::timestamp AT TIME ZONE v_tz;
  IF p_end_time > p_start_time THEN
    v_ends := (p_work_date::text || ' ' || p_end_time::text)::timestamp AT TIME ZONE v_tz;
  ELSE
    v_ends := ((p_work_date + 1)::text || ' ' || p_end_time::text)::timestamp AT TIME ZONE v_tz;
  END IF;

  RETURN data.evaluate_employee_assignment(
    p_employee_id, p_site_id, v_starts, v_ends, p_role_id, p_exclude_slot_id
  );
END;
$$;

COMMENT ON FUNCTION data.evaluate_employee_assignment(uuid, uuid, date, time, time, uuid, uuid) IS
  'EC-WFM P0 §5 convenience overload for shift date/time windows.';

CREATE OR REPLACE FUNCTION api.evaluate_employee_assignment(
  p_employee_id uuid,
  p_site_id uuid,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_role_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_emp_tenant uuid;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = '28000';
  END IF;

  SELECT tenant_id INTO v_emp_tenant
  FROM data.employees WHERE id = p_employee_id;

  IF v_emp_tenant IS NULL OR v_emp_tenant <> v_tenant_id THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT (
    data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage')
    OR data.jwt_has_permission(v_tenant_id, 'employees.read')
    OR data.jwt_has_permission(v_tenant_id, 'employees.manage')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = '42501';
  END IF;

  RETURN data.evaluate_employee_assignment(
    p_employee_id, p_site_id, p_starts_at, p_ends_at, p_role_id, NULL
  );
END;
$$;

REVOKE ALL ON FUNCTION data.evaluate_employee_assignment(uuid, uuid, timestamptz, timestamptz, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.evaluate_employee_assignment(uuid, uuid, date, time, time, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.evaluate_employee_assignment(uuid, uuid, timestamptz, timestamptz, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION data.evaluate_employee_assignment(uuid, uuid, timestamptz, timestamptz, uuid, uuid)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION data.evaluate_employee_assignment(uuid, uuid, date, time, time, uuid, uuid)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.evaluate_employee_assignment(uuid, uuid, timestamptz, timestamptz, uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Wire assign_shift_slot: revalidate via evaluate_employee_assignment
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.assign_shift_slot(
  p_employee_id uuid,
  p_slot_date date,
  p_shift_id uuid,
  p_notes text DEFAULT NULL,
  p_location_id uuid DEFAULT NULL,
  p_role_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'data', 'api'
AS $$
DECLARE
  v_emp record;
  v_shift record;
  v_slot_id uuid;
  v_anomalies text[] := '{}';
  v_location_id uuid;
  v_site_id uuid;
  v_role_id uuid;
  v_role_name text;
  v_eval jsonb;
  v_finding jsonb;
  v_codes text[] := '{}';
BEGIN
  SELECT e.tenant_id, e.site_id, e.weekly_hours, e.status INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id USING ERRCODE = 'P0002';
  END IF;

  v_emp.weekly_hours := data.employee_effective_weekly_hours(p_employee_id, p_slot_date);
  v_emp.site_id := COALESCE(
    data.employee_effective_site_id(p_employee_id, p_slot_date),
    v_emp.site_id
  );

  IF v_emp.status = 'terminated' THEN
    RAISE EXCEPTION 'employee_terminated: no es pot assignar torn a un empleat donat de baixa'
      USING ERRCODE = 'check_violation';
  END IF;

  IF NOT data.jwt_has_permission(v_emp.tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT ws.* INTO v_shift
  FROM data.work_shifts ws
  WHERE ws.id = p_shift_id
    AND ws.tenant_id = v_emp.tenant_id
    AND ws.is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'shift_not_found_or_inactive: %', p_shift_id USING ERRCODE = 'P0002';
  END IF;

  v_site_id := COALESCE(v_shift.site_id, v_emp.site_id);
  v_location_id := COALESCE(p_location_id, v_shift.default_location_id);
  v_role_id := COALESCE(p_role_id, v_shift.default_role_id);

  IF v_role_id IS NOT NULL THEN
    SELECT wr.name INTO v_role_name
    FROM data.work_roles wr
    WHERE wr.id = v_role_id
      AND wr.tenant_id = v_emp.tenant_id
      AND wr.is_active = true;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'work_role_not_found_or_inactive' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  -- §5 transactional revalidation (includes closed periods)
  v_eval := data.evaluate_employee_assignment(
    p_employee_id,
    v_site_id,
    p_slot_date,
    v_shift.start_time,
    v_shift.end_time,
    v_role_id,
    NULL
  );

  IF v_eval->>'status' = 'blocked' THEN
    SELECT coalesce(array_agg(f->>'code'), ARRAY['assignment_blocked'])
    INTO v_codes
    FROM jsonb_array_elements(coalesce(v_eval->'blocks', '[]'::jsonb)) f;

    RAISE EXCEPTION 'assignment_blocked: %', array_to_string(v_codes, ',')
      USING ERRCODE = 'check_violation',
            DETAIL = v_eval::text;
  END IF;

  FOR v_finding IN SELECT * FROM jsonb_array_elements(coalesce(v_eval->'warnings', '[]'::jsonb))
  LOOP
    v_anomalies := array_append(v_anomalies, v_finding->>'code');
  END LOOP;

  INSERT INTO data.shift_slots (
    tenant_id, site_id, employee_id, shift_id, slot_date, status, notes, created_by,
    start_time, end_time, location_id, role_id, role_name_snapshot
  ) VALUES (
    v_emp.tenant_id, v_site_id, p_employee_id, p_shift_id,
    p_slot_date, 'draft', p_notes, auth.uid(),
    v_shift.start_time, v_shift.end_time, v_location_id, v_role_id, v_role_name
  )
  RETURNING id INTO v_slot_id;

  PERFORM data.log_audit_event(
    v_emp.tenant_id, auth.uid(), v_site_id,
    'SHIFT_SLOT_ASSIGNED', 'shift_slot', v_slot_id,
    jsonb_build_object(
      'employee_id', p_employee_id,
      'shift_id', p_shift_id,
      'slot_date', p_slot_date,
      'location_id', v_location_id,
      'role_id', v_role_id,
      'anomalies', v_anomalies,
      'evaluation_status', v_eval->>'status'
    )
  );

  RETURN jsonb_build_object(
    'slot_id', v_slot_id,
    'status', 'draft',
    'location_id', v_location_id,
    'role_id', v_role_id,
    'anomalies', to_jsonb(v_anomalies),
    'evaluation', jsonb_build_object(
      'status', v_eval->>'status',
      'warnings', v_eval->'warnings',
      'resolver_version', v_eval->>'resolver_version'
    )
  );
END;
$$;

COMMENT ON FUNCTION api.assign_shift_slot(uuid, date, uuid, text, uuid, uuid) IS
  'EC-WFM P0 §5: revalidates via evaluate_employee_assignment before insert.';

NOTIFY pgrst, 'reload schema';
