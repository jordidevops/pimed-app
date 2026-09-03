-- =============================================================================
-- EC-WFM P0 - Consumers: use effective helpers for site/weekly_hours
-- Depends on: 20261096000001_ec_wfm_p0_baseline.sql
-- Annex: plan-employment-contracts-inspiracio-orquest.md §4.3
-- =============================================================================
CREATE OR REPLACE FUNCTION data.resolve_employee_work_plan(p_employee_id uuid, p_work_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'data', 'public'
AS $$
DECLARE
  v_emp              record;
  v_tz               text;
  v_absence          record;
  v_emp_override     text;
  v_skip_holiday     boolean := false;
  v_labor            record;
  v_bounds           record;
  v_slots            record;
  v_base_source      text;
  v_labor_source     text;
  v_day_type         text := 'unknown';
  v_labor_day_type   text;
  v_expected_min     int := 0;
  v_work_intervals   jsonb := '[]'::jsonb;
  v_spans_midnight   boolean := false;
  v_shift_start      time;
  v_shift_end        time;
  v_is_holiday       boolean := false;
  v_holiday_name     text;
  v_is_half_day      boolean := false;
  v_slot_ids         uuid[] := ARRAY[]::uuid[];
  v_scheduled_site   uuid;
  v_scheduled_loc    uuid;
  v_scheduled_loc_name text;
  v_scheduled_loc_path text;
BEGIN
  SELECT e.id, e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'employee_id', p_employee_id,
      'work_date', p_work_date,
      'day_type', 'unknown',
      'expected_minutes', 0,
      'work_day_type', 'normal',
      'error', 'employee_not_found'
    );
  END IF;

  -- EC-WFM P0: prefer effective site from work context
  v_emp.site_id := COALESCE(
    data.employee_effective_site_id(p_employee_id, p_work_date),
    v_emp.site_id
  );

  v_tz := COALESCE(data.get_site_timezone(v_emp.site_id, v_emp.tenant_id), 'Europe/Madrid');
  v_scheduled_site := v_emp.site_id;

  SELECT ea.id, ea.absence_type, ea.is_paid, ea.hours_per_day, ea.counts_as_worked
  INTO v_absence
  FROM data.employee_absences ea
  WHERE ea.employee_id = p_employee_id
    AND ea.status = 'approved'
    AND ea.start_date <= p_work_date
    AND ea.end_date >= p_work_date
  ORDER BY ea.created_at DESC
  LIMIT 1;

  IF FOUND THEN
    SELECT lc.planned_minutes, lc.work_intervals, lc.labor_source
    INTO v_expected_min, v_work_intervals, v_base_source
    FROM data.resolve_labor_calendar_for_employee(
      v_emp.tenant_id, v_emp.site_id, p_employee_id, p_work_date, false
    ) lc
    WHERE lc.labor_day_type = 'work';

    SELECT * INTO v_slots FROM data.published_shift_intervals_for_day(p_employee_id, p_work_date);

    RETURN jsonb_build_object(
      'employee_id',               p_employee_id,
      'work_date',                 p_work_date,
      'site_timezone',             v_tz,
      'day_type',                  'absence',
      'labor_day_type',            NULL,
      'expected_minutes',          COALESCE(v_expected_min, 0),
      'work_day_type',             'normal',
      'spans_midnight',            false,
      'work_intervals',            COALESCE(v_work_intervals, '[]'::jsonb),
      'shift_start_time',          NULL,
      'shift_end_time',            NULL,
      'is_holiday',                false,
      'holiday_name',              NULL,
      'holiday_type',              NULL,
      'is_half_day',               false,
      'is_absence',                true,
      'absence_id',                v_absence.id,
      'absence_type',              v_absence.absence_type,
      'absence_is_paid',           v_absence.is_paid,
      'absence_hours_per_day',     v_absence.hours_per_day,
      'absence_counts_as_worked',  COALESCE(v_absence.counts_as_worked, false),
      'schedule_id',               NULL,
      'schedule_name',             NULL,
      'published_slot_ids',        to_jsonb(COALESCE(v_slots.published_slot_ids, ARRAY[]::uuid[])),
      'base_source',               v_base_source,
      'labor_source',              'absence',
      'employee_override',         false,
      'location_id',               v_slots.scheduled_location_id,
      'scheduled_site_id',         COALESCE(v_slots.slot_site_id, v_scheduled_site),
      'scheduled_location_id',     v_slots.scheduled_location_id,
      'scheduled_location_name',   v_slots.scheduled_location_name,
      'scheduled_location_path',   v_slots.scheduled_location_path
    );
  END IF;

  SELECT edo.override_type INTO v_emp_override
  FROM data.employee_day_overrides edo
  WHERE edo.employee_id = p_employee_id
    AND edo.override_date = p_work_date;

  IF FOUND THEN
    IF v_emp_override = 'force_holiday' THEN
      RETURN jsonb_build_object(
        'employee_id', p_employee_id,
        'work_date', p_work_date,
        'site_timezone', v_tz,
        'day_type', 'holiday',
        'labor_day_type', 'holiday',
        'expected_minutes', 0,
        'work_day_type', 'normal',
        'spans_midnight', false,
        'work_intervals', '[]'::jsonb,
        'shift_start_time', NULL,
        'shift_end_time', NULL,
        'is_holiday', true,
        'holiday_name', NULL,
        'holiday_type', 'tenant_custom',
        'is_half_day', false,
        'is_absence', false,
        'absence_id', NULL,
        'absence_type', NULL,
        'absence_counts_as_worked', false,
        'schedule_id', NULL,
        'schedule_name', NULL,
        'published_slot_ids', '[]'::jsonb,
        'base_source', 'employee_day_override',
        'labor_source', 'employee_day_override',
        'employee_override', true,
        'location_id', NULL,
        'scheduled_site_id', v_scheduled_site,
        'scheduled_location_id', NULL,
        'scheduled_location_name', NULL,
        'scheduled_location_path', NULL
      );
    ELSIF v_emp_override = 'force_work' THEN
      v_skip_holiday := true;
    END IF;
  END IF;

  SELECT * INTO v_labor
  FROM data.resolve_labor_calendar_for_employee(
    v_emp.tenant_id, v_emp.site_id, p_employee_id, p_work_date, v_skip_holiday
  );

  v_labor_day_type := v_labor.labor_day_type;
  v_base_source := v_labor.labor_source;
  v_labor_source := v_labor.labor_source;
  v_expected_min := COALESCE(v_labor.planned_minutes, 0);
  v_holiday_name := v_labor.labor_day_name;
  v_is_half_day := COALESCE(v_labor.is_half_day, false);
  v_is_holiday := v_labor_day_type = 'holiday'
    OR (v_labor.labor_source = 'assigned_holiday');
  v_work_intervals := COALESCE(v_labor.work_intervals, '[]'::jsonb);

  CASE v_labor_day_type
    WHEN 'work' THEN
      v_day_type := 'working';
      SELECT * INTO v_bounds FROM data.labor_intervals_shift_bounds(v_labor.work_intervals);
      v_shift_start := v_bounds.shift_start;
      v_shift_end := v_bounds.shift_end;
      v_spans_midnight := COALESCE(v_bounds.spans_midnight, false);

    WHEN 'holiday' THEN
      v_day_type := CASE WHEN v_is_half_day THEN 'half_holiday' ELSE 'holiday' END;
      v_expected_min := 0;
      v_is_holiday := true;
      v_work_intervals := '[]'::jsonb;

    WHEN 'vacation', 'leave' THEN
      v_day_type := 'non_working';
      v_expected_min := 0;
      v_work_intervals := '[]'::jsonb;

    ELSE
      v_day_type := 'unknown';
      v_expected_min := 0;
      IF v_labor_source = 'none' OR v_labor_source IS NULL THEN
        v_labor_source := 'none';
        v_base_source := COALESCE(v_base_source, 'none');
      END IF;
  END CASE;

  SELECT * INTO v_slots
  FROM data.published_shift_intervals_for_day(p_employee_id, p_work_date);

  IF cardinality(v_slots.published_slot_ids) > 0 THEN
    v_slot_ids := v_slots.published_slot_ids;
    IF v_slots.slot_site_id IS NOT NULL THEN
      v_scheduled_site := v_slots.slot_site_id;
    END IF;
    v_scheduled_loc := v_slots.scheduled_location_id;
    v_scheduled_loc_name := v_slots.scheduled_location_name;
    v_scheduled_loc_path := v_slots.scheduled_location_path;

    IF v_labor_day_type IN ('work', 'undefined') THEN
      v_work_intervals := v_slots.work_intervals;
      v_expected_min := v_slots.planned_minutes;
      v_labor_source := 'published_shift';
      v_day_type := 'working';
      v_labor_day_type := 'work';
      SELECT * INTO v_bounds FROM data.labor_intervals_shift_bounds(v_work_intervals);
      v_shift_start := v_bounds.shift_start;
      v_shift_end := v_bounds.shift_end;
      v_spans_midnight := COALESCE(v_bounds.spans_midnight, false);
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'work_date', p_work_date,
    'site_timezone', v_tz,
    'day_type', v_day_type,
    'labor_day_type', v_labor_day_type,
    'expected_minutes', v_expected_min,
    'work_day_type', 'normal',
    'spans_midnight', v_spans_midnight,
    'work_intervals', v_work_intervals,
    'shift_start_time', v_shift_start,
    'shift_end_time', v_shift_end,
    'is_holiday', v_is_holiday,
    'holiday_name', v_holiday_name,
    'holiday_type', CASE WHEN v_is_holiday THEN 'assigned' ELSE NULL END,
    'is_half_day', v_is_half_day,
    'is_absence', false,
    'absence_id', NULL,
    'absence_type', NULL,
    'absence_counts_as_worked', false,
    'schedule_id', NULL,
    'schedule_name', NULL,
    'published_slot_ids', to_jsonb(COALESCE(v_slot_ids, ARRAY[]::uuid[])),
    'base_source', v_base_source,
    'labor_source', v_labor_source,
    'employee_override', COALESCE(v_emp_override = 'force_work', false),
    'location_id', v_scheduled_loc,
    'scheduled_site_id', v_scheduled_site,
    'scheduled_location_id', v_scheduled_loc,
    'scheduled_location_name', v_scheduled_loc_name,
    'scheduled_location_path', v_scheduled_loc_path
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.preflight_publish_shifts(p_site_id uuid, p_week_start date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'data', 'api', 'public'
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
  v_labor jsonb;
  v_issue jsonb;
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
    SELECT ss.id, ss.employee_id, ss.slot_date, ss.start_time, ss.end_time, ss.site_id
    FROM data.shift_slots ss
    WHERE ss.site_id = p_site_id
      AND ss.slot_date BETWEEN p_week_start AND v_week_end
      AND ss.status = 'draft'
    ORDER BY ss.slot_date, ss.start_time, ss.id
  LOOP
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

    -- EC-WFM P0: effective weekly hours from work context
    v_weekly_hours := data.employee_effective_weekly_hours(v_slot.employee_id, v_slot.slot_date);

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

    v_plan := data.resolve_employee_work_plan(v_slot.employee_id, v_slot.slot_date);
    v_labor_day := v_plan->>'labor_day_type';
    v_day_type := v_plan->>'day_type';

    IF COALESCE(v_labor_day, '') IN ('holiday', 'vacation', 'leave')
       OR COALESCE(v_day_type, '') IN ('holiday', 'half_holiday', 'non_working', 'absence')
    THEN
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
        'message', 'Hi ha una abs├¿ncia aprovada/activa aquest dia'
      ));
    END IF;

    -- EX-08.1 labor rules
    v_labor := data.evaluate_labor_rules_for_window(
      v_slot.employee_id, v_slot.site_id, v_slot.slot_date,
      v_slot.start_time, v_slot.end_time, v_slot.id
    );
    FOR v_issue IN SELECT * FROM jsonb_array_elements(COALESCE(v_labor->'issues', '[]'::jsonb))
    LOOP
      IF v_issue->>'severity' = 'block' THEN
        v_blockers := v_blockers || jsonb_build_array(v_issue || jsonb_build_object('slot_id', v_slot.id));
      ELSE
        v_warnings := v_warnings || jsonb_build_array(v_issue || jsonb_build_object('slot_id', v_slot.id));
      END IF;
    END LOOP;
  END LOOP;

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
    'can_publish', jsonb_array_length(COALESCE(v_blockers, '[]'::jsonb)) = 0 AND v_draft_count > 0,
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

CREATE OR REPLACE FUNCTION api.assign_shift_slot(p_employee_id uuid, p_slot_date date, p_shift_id uuid, p_notes text DEFAULT NULL::text, p_location_id uuid DEFAULT NULL::uuid, p_role_id uuid DEFAULT NULL::uuid)
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
  v_week_start date;
  v_week_min numeric := 0;
  v_shift_min numeric;
  v_location_id uuid;
  v_site_id uuid;
  v_role_id uuid;
  v_role_name text;
BEGIN
  SELECT e.tenant_id, e.site_id, e.weekly_hours, e.status INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id USING ERRCODE = 'P0002';
  END IF;

  -- EC-WFM P0: overlay effective weekly_hours / site from work context
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

  PERFORM data.assert_shift_pairs_mutable(
    jsonb_build_array(jsonb_build_object(
      'employee_id', p_employee_id,
      'work_date', p_slot_date
    ))
  );

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

  IF EXISTS (
    SELECT 1
    FROM data.shift_slots ss2
    WHERE ss2.employee_id = p_employee_id
      AND ss2.status <> 'cancelled'
      AND ss2.slot_date BETWEEN p_slot_date - 1 AND p_slot_date + 1
      AND data.shift_slots_overlap(
        p_slot_date, v_shift.start_time, v_shift.end_time,
        ss2.slot_date, ss2.start_time, ss2.end_time
      )
  ) THEN
    v_anomalies := array_append(v_anomalies, 'SHIFT_OVERLAP');
  END IF;

  v_week_start := date_trunc('week', p_slot_date::timestamptz)::date;

  v_shift_min := ROUND(EXTRACT(EPOCH FROM CASE WHEN v_shift.end_time > v_shift.start_time THEN v_shift.end_time - v_shift.start_time ELSE interval '24 hours' + (v_shift.end_time - v_shift.start_time) END) / 60);

  SELECT COALESCE(SUM(ROUND(EXTRACT(EPOCH FROM CASE WHEN ss2.end_time > ss2.start_time THEN ss2.end_time - ss2.start_time ELSE interval '24 hours' + (ss2.end_time - ss2.start_time) END) / 60)), 0)
  INTO v_week_min
  FROM data.shift_slots ss2
  WHERE ss2.employee_id = p_employee_id
    AND ss2.slot_date >= v_week_start
    AND ss2.slot_date <= v_week_start + 6
    AND ss2.status <> 'cancelled';

  IF v_emp.weekly_hours IS NOT NULL AND (v_week_min + v_shift_min) > (v_emp.weekly_hours * 60) THEN
    v_anomalies := array_append(v_anomalies, 'WEEKLY_HOURS_EXCEEDED');
  END IF;

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
      'anomalies', v_anomalies
    )
  );

  RETURN jsonb_build_object(
    'slot_id', v_slot_id,
    'status', 'draft',
    'location_id', v_location_id,
    'role_id', v_role_id,
    'anomalies', to_jsonb(v_anomalies)
  );
END;
$$;

COMMENT ON FUNCTION data.resolve_employee_work_plan(uuid, date) IS
  'EC-WFM P0 §4.3: work plan uses employee_effective_site_id for labor calendar resolution.';

COMMENT ON FUNCTION api.preflight_publish_shifts(uuid, date) IS
  'EC-WFM P0 §4.3: weekly hours check uses employee_effective_weekly_hours.';

COMMENT ON FUNCTION api.assign_shift_slot(uuid, date, uuid, text, uuid, uuid) IS
  'EC-WFM P0 §4.3: assignment uses effective weekly_hours and site_id from work context.';

NOTIFY pgrst, 'reload schema';
