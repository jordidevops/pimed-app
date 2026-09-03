-- Fix EX-04.3: Postgres format() no accepta %.0f
CREATE OR REPLACE FUNCTION api.preflight_publish_shifts(
  p_site_id    uuid,
  p_week_start date
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid;
  v_week_end date;
  v_draft_count int := 0;
  v_blockers jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_pairs jsonb := '[]'::jsonb;
  v_closed jsonb;
  v_affected uuid[] := ARRAY[]::uuid[];
  v_slot record;
  v_plan jsonb;
  v_labor_day text;
  v_day_type text;
  v_other record;
  v_week_min numeric;
  v_slot_min numeric;
  v_weekly_hours numeric;
  v_cov record;
  v_emp_ids uuid[];
BEGIN
  IF EXTRACT(DOW FROM p_week_start)::int <> 1 THEN
    RAISE EXCEPTION 'invalid_week_start: p_week_start ha de ser dilluns'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT s.tenant_id INTO v_tenant_id FROM data.sites s WHERE s.id = p_site_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_not_found: %', p_site_id USING ERRCODE = 'P0002';
  END IF;

  IF NOT COALESCE(data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage', p_site_id), false) THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_week_end := p_week_start + 6;

  SELECT count(*)::int,
         coalesce(array_agg(DISTINCT ss.employee_id), ARRAY[]::uuid[])
  INTO v_draft_count, v_emp_ids
  FROM data.shift_slots ss
  WHERE ss.site_id = p_site_id
    AND ss.slot_date BETWEEN p_week_start AND v_week_end
    AND ss.status = 'draft';

  v_affected := coalesce(v_emp_ids, ARRAY[]::uuid[]);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'employee_id', ss.employee_id,
    'work_date', ss.slot_date
  )), '[]'::jsonb)
  INTO v_pairs
  FROM data.shift_slots ss
  WHERE ss.site_id = p_site_id
    AND ss.slot_date BETWEEN p_week_start AND v_week_end
    AND ss.status = 'draft';

  v_closed := data.shift_closed_period_issues(v_pairs);
  IF jsonb_array_length(v_closed) > 0 THEN
    v_blockers := v_blockers || v_closed;
  END IF;

  FOR v_slot IN
    SELECT ss.id, ss.employee_id, ss.slot_date, ss.start_time, ss.end_time
    FROM data.shift_slots ss
    WHERE ss.site_id = p_site_id
      AND ss.slot_date BETWEEN p_week_start AND v_week_end
      AND ss.status = 'draft'
    ORDER BY ss.slot_date, ss.start_time, ss.id
  LOOP
    -- Solapament amb qualsevol altre slot no cancel·lat
    SELECT ss2.id, ss2.slot_date, ss2.start_time, ss2.end_time
    INTO v_other
    FROM data.shift_slots ss2
    WHERE ss2.employee_id = v_slot.employee_id
      AND ss2.id <> v_slot.id
      AND ss2.status <> 'cancelled'
      AND ss2.slot_date BETWEEN v_slot.slot_date - 1 AND v_slot.slot_date + 1
      AND data.shift_slots_overlap(
        v_slot.slot_date, v_slot.start_time, v_slot.end_time,
        ss2.slot_date, ss2.start_time, ss2.end_time
      )
    LIMIT 1;

    IF FOUND THEN
      v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
        'code', 'SHIFT_OVERLAP',
        'severity', 'warn_require_reason',
        'employee_id', v_slot.employee_id,
        'work_date', v_slot.slot_date,
        'slot_id', v_slot.id,
        'message', 'Solapament amb un altre torn'
      ));
    END IF;

    -- Hores setmanals
    SELECT e.weekly_hours INTO v_weekly_hours
    FROM data.employees e WHERE e.id = v_slot.employee_id;

    v_slot_min := ROUND(EXTRACT(EPOCH FROM CASE
      WHEN v_slot.end_time > v_slot.start_time THEN v_slot.end_time - v_slot.start_time
      ELSE interval '24 hours' + (v_slot.end_time - v_slot.start_time)
    END) / 60);

    SELECT COALESCE(SUM(ROUND(EXTRACT(EPOCH FROM CASE
      WHEN ss2.end_time > ss2.start_time THEN ss2.end_time - ss2.start_time
      ELSE interval '24 hours' + (ss2.end_time - ss2.start_time)
    END) / 60)), 0)
    INTO v_week_min
    FROM data.shift_slots ss2
    WHERE ss2.employee_id = v_slot.employee_id
      AND ss2.slot_date BETWEEN p_week_start AND v_week_end
      AND ss2.status <> 'cancelled';

    IF v_weekly_hours IS NOT NULL AND v_week_min > (v_weekly_hours * 60) THEN
      v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
        'code', 'WEEKLY_HOURS_EXCEEDED',
        'severity', 'warn_require_reason',
        'employee_id', v_slot.employee_id,
        'work_date', v_slot.slot_date,
        'slot_id', v_slot.id,
        'message', format('Hores setmanals superades (%s min / %s h)', round(v_week_min)::int, v_weekly_hours)
      ));
    END IF;

    -- Dia no laboral (festiu/vacances/leave) sense override work
    v_plan := data.resolve_employee_work_plan(v_slot.employee_id, v_slot.slot_date);
    v_labor_day := v_plan->>'labor_day_type';
    v_day_type := v_plan->>'day_type';

    IF COALESCE(v_labor_day, '') IN ('holiday', 'vacation', 'leave')
       OR COALESCE(v_day_type, '') IN ('holiday', 'half_holiday', 'non_working', 'absence')
    THEN
      -- Absència total ja coberta més avall; holiday/vacation/leave sense work → blocker
      IF COALESCE(v_day_type, '') <> 'absence'
         AND COALESCE(v_labor_day, '') IN ('holiday', 'vacation', 'leave') THEN
        v_blockers := v_blockers || jsonb_build_array(jsonb_build_object(
          'code', 'NON_WORK_DAY',
          'severity', 'block',
          'employee_id', v_slot.employee_id,
          'work_date', v_slot.slot_date,
          'slot_id', v_slot.id,
          'labor_day_type', v_labor_day,
          'message', 'Cal override laboral (work) abans de publicar un torn en festiu/vacances/leave'
        ));
      END IF;
    END IF;

    -- Absència aprovada solapada
    IF EXISTS (
      SELECT 1
      FROM data.employee_absences ea
      WHERE ea.employee_id = v_slot.employee_id
        AND ea.status IN ('approved', 'active', 'closed')
        AND ea.start_date <= v_slot.slot_date
        AND COALESCE(ea.end_date, '9999-12-31'::date) >= v_slot.slot_date
    ) THEN
      v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
        'code', 'APPROVED_ABSENCE',
        'severity', 'warn_require_reason',
        'employee_id', v_slot.employee_id,
        'work_date', v_slot.slot_date,
        'slot_id', v_slot.id,
        'message', 'Hi ha una absència aprovada/activa aquest dia'
      ));
    END IF;
  END LOOP;

  -- Cobertura negativa (warn informatiu)
  FOR v_cov IN
    SELECT *
    FROM jsonb_array_elements(
      COALESCE(api.get_coverage_for_period(p_site_id, p_week_start, v_week_end), '[]'::jsonb)
    ) AS x(day)
  LOOP
    IF COALESCE((v_cov.day->>'coverage_delta')::int, 0) < 0 THEN
      v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
        'code', 'COVERAGE_SHORTAGE',
        'severity', 'warn',
        'work_date', v_cov.day->>'work_date',
        'coverage_delta', (v_cov.day->>'coverage_delta')::int,
        'message', format(
          'Cobertura insuficient: %s/%s',
          v_cov.day->>'employee_count',
          v_cov.day->>'required_employee_count'
        )
      ));
    END IF;
  END LOOP;

  -- Deduplicar warnings per (code, employee_id, work_date, slot_id)
  SELECT COALESCE(jsonb_agg(DISTINCT w), '[]'::jsonb)
  INTO v_warnings
  FROM jsonb_array_elements(v_warnings) AS w;

  SELECT COALESCE(jsonb_agg(DISTINCT b), '[]'::jsonb)
  INTO v_blockers
  FROM jsonb_array_elements(v_blockers) AS b;

  RETURN jsonb_build_object(
    'site_id', p_site_id,
    'week_start', p_week_start,
    'week_end', v_week_end,
    'draft_count', v_draft_count,
    'can_publish', jsonb_array_length(v_blockers) = 0 AND v_draft_count > 0,
    'blockers', COALESCE(v_blockers, '[]'::jsonb),
    'warnings', COALESCE(v_warnings, '[]'::jsonb),
    'affected_employee_ids', to_jsonb(v_affected),
    'required_warning_codes', (
      SELECT COALESCE(jsonb_agg(DISTINCT w->>'code'), '[]'::jsonb)
      FROM jsonb_array_elements(COALESCE(v_warnings, '[]'::jsonb)) w
      WHERE w->>'severity' = 'warn_require_reason'
    )
  );
END;
$$;

COMMENT ON FUNCTION api.preflight_publish_shifts(uuid, date) IS
  'EX-04.3: validació prèvia a publish_shifts (blockers + warnings).';

GRANT EXECUTE ON FUNCTION api.preflight_publish_shifts(uuid, date) TO authenticated, service_role;

