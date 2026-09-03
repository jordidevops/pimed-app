-- EX-03.3 / SP-1 (nucli): data.resolve_employee_work_plan canònic
-- Base = labor overrides puntuals + festius + base recurrent ADR-0003;
-- després shift_slots published (substitueixen intervals); absència aprovada
-- i employee_day_overrides com a capes superiors (paritat amb resolve_work_day).
-- location_id / snapshots → EX-03.4 (ST-19). Dual-run → EX-03.7.

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. Helper: intervals JSON des de shift_slots published del dia
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION data.published_shift_intervals_for_day(
  p_employee_id uuid,
  p_work_date   date
)
RETURNS TABLE(
  work_intervals     jsonb,
  planned_minutes    integer,
  published_slot_ids uuid[],
  slot_site_id       uuid
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_intervals jsonb := '[]'::jsonb;
  v_ids       uuid[] := ARRAY[]::uuid[];
  v_site      uuid;
  v_row       record;
BEGIN
  FOR v_row IN
    SELECT ss.id, ss.site_id, ss.start_time, ss.end_time
    FROM data.shift_slots ss
    WHERE ss.employee_id = p_employee_id
      AND ss.slot_date = p_work_date
      AND ss.status = 'published'
    ORDER BY ss.start_time, ss.id
  LOOP
    v_ids := v_ids || v_row.id;
    IF v_site IS NULL THEN
      v_site := v_row.site_id;
    END IF;
    v_intervals := v_intervals || jsonb_build_array(jsonb_build_object(
      'start', to_char(v_row.start_time, 'HH24:MI'),
      'end',   to_char(v_row.end_time,   'HH24:MI'),
      'location_id', NULL,
      'role_id', NULL
    ));
  END LOOP;

  IF cardinality(v_ids) = 0 THEN
    RETURN QUERY SELECT '[]'::jsonb, 0, ARRAY[]::uuid[], NULL::uuid;
    RETURN;
  END IF;

  RETURN QUERY SELECT
    v_intervals,
    data.labor_planned_minutes(v_intervals, NULL::time, NULL::time),
    v_ids,
    v_site;
END;
$$;

COMMENT ON FUNCTION data.published_shift_intervals_for_day(uuid, date) IS
  'EX-03.3: agrega intervals de shift_slots published per empleat+data (location_id deferred ST-19).';

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. data.resolve_employee_work_plan — funció de domini canònica
--    Sense auth (crida interna / SECURITY DEFINER). Auth a api.resolve_work_day.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION data.resolve_employee_work_plan(
  p_employee_id uuid,
  p_work_date   date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
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

  v_tz := COALESCE(data.get_site_timezone(v_emp.site_id, v_emp.tenant_id), 'Europe/Madrid');
  v_scheduled_site := v_emp.site_id;

  -- ── 0a. Absència aprovada (prioritat màxima d'incidència) ─────────────────
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
    -- Minuts de referència: base laboral (sense slots) si el dia base és work.
    SELECT lc.planned_minutes, lc.work_intervals, lc.labor_source
    INTO v_expected_min, v_work_intervals, v_base_source
    FROM data.resolve_labor_calendar_for_employee(
      v_emp.tenant_id, v_emp.site_id, p_employee_id, p_work_date, false
    ) lc
    WHERE lc.labor_day_type = 'work';

    -- Si hi ha slots published i el dia base era work, els minuts de referència
    -- segueixen la base laboral (no els slots) per paritat amb resolve_work_day pre-EX-03.3.
    -- (Els slots afecten l'obligació operativa; en absència total l'obligació queda anul·lada.)

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
      'published_slot_ids',        '[]'::jsonb,
      'base_source',               v_base_source,
      'labor_source',              'absence',
      'employee_override',         false,
      'location_id',               NULL,
      'scheduled_site_id',         v_scheduled_site,
      'scheduled_location_id',     NULL
    );
  END IF;

  -- ── 0b. employee_day_overrides (legacy fins EX-03.3+) ─────────────────────
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
        'scheduled_location_id', NULL
      );
    ELSIF v_emp_override = 'force_work' THEN
      v_skip_holiday := true;
    END IF;
  END IF;

  -- ── 1–8. Cascada laboral (overrides + festiu + base recurrent ADR-0003) ───
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

  -- ── 9. shift_slots published ──────────────────────────────────────────────
  -- Substitueixen intervals quan el dia és laborable O indefinit.
  -- No converteixen holiday / vacation / leave en work (ADR-0001 §8.5).
  SELECT * INTO v_slots
  FROM data.published_shift_intervals_for_day(p_employee_id, p_work_date);

  IF cardinality(v_slots.published_slot_ids) > 0 THEN
    v_slot_ids := v_slots.published_slot_ids;
    IF v_slots.slot_site_id IS NOT NULL THEN
      v_scheduled_site := v_slots.slot_site_id;
    END IF;

    -- ADR-0001 §8.5: un slot publicat NO converteix holiday/vacation/leave en work.
    -- Sí substitueix intervals quan el dia base és work o undefined (indefinit).
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
    -- En holiday/vacation/leave: published_slot_ids queden com a evidència sense canviar day_type.
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
    'location_id', NULL,
    'scheduled_site_id', v_scheduled_site,
    'scheduled_location_id', NULL
  );
END;
$$;

COMMENT ON FUNCTION data.resolve_employee_work_plan(uuid, date) IS
  'EX-03.3: resolver canònic d''horari operatiu (labor + festiu + weekly ADR-0003 + slots published + absència/edo).';

GRANT EXECUTE ON FUNCTION data.resolve_employee_work_plan(uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION data.resolve_employee_work_plan(uuid, date) TO service_role;
GRANT EXECUTE ON FUNCTION data.published_shift_intervals_for_day(uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION data.published_shift_intervals_for_day(uuid, date) TO service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. api.resolve_work_day — adaptador estable sobre el contracte canònic
--    Conserva auth i forma de resposta esperada pels consumidors existents.
-- ═══════════════════════════════════════════════════════════════════════════

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
  v_emp    record;
  v_plan   jsonb;
  v_out    jsonb;
BEGIN
  SELECT e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'day_type', 'unknown',
      'expected_minutes', 0,
      'work_day_type', 'normal',
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

  v_plan := data.resolve_employee_work_plan(p_employee_id, p_work_date);

  -- Forma estable del contracte API (camps que ja consumien resolve_work_day).
  -- Camps nous del canònic (base_source, published_slot_ids, …) també s'exposen.
  v_out := jsonb_build_object(
    'day_type',                  v_plan->>'day_type',
    'expected_minutes',          COALESCE((v_plan->>'expected_minutes')::int, 0),
    'work_day_type',             COALESCE(v_plan->>'work_day_type', 'normal'),
    'site_timezone',             v_plan->>'site_timezone',
    'is_holiday',                COALESCE((v_plan->>'is_holiday')::boolean, false),
    'holiday_name',              v_plan->'holiday_name',
    'holiday_type',              v_plan->'holiday_type',
    'is_half_day',               COALESCE((v_plan->>'is_half_day')::boolean, false),
    'is_absence',                COALESCE((v_plan->>'is_absence')::boolean, false),
    'absence_id',                v_plan->'absence_id',
    'absence_type',              v_plan->'absence_type',
    'absence_is_paid',           v_plan->'absence_is_paid',
    'absence_hours_per_day',     v_plan->'absence_hours_per_day',
    'absence_counts_as_worked',  COALESCE((v_plan->>'absence_counts_as_worked')::boolean, false),
    'schedule_id',               v_plan->'schedule_id',
    'schedule_name',             v_plan->'schedule_name',
    'spans_midnight',            COALESCE((v_plan->>'spans_midnight')::boolean, false),
    'shift_start_time',          v_plan->'shift_start_time',
    'shift_end_time',            v_plan->'shift_end_time',
    'work_intervals',            COALESCE(v_plan->'work_intervals', '[]'::jsonb),
    'employee_override',         COALESCE((v_plan->>'employee_override')::boolean, false),
    'labor_source',              v_plan->>'labor_source',
    'labor_day_type',            v_plan->'labor_day_type',
    'base_source',               v_plan->'base_source',
    'published_slot_ids',        COALESCE(v_plan->'published_slot_ids', '[]'::jsonb),
    'scheduled_site_id',         v_plan->'scheduled_site_id',
    'scheduled_location_id',     v_plan->'scheduled_location_id',
    'location_id',               v_plan->'location_id'
  );

  IF v_plan ? 'error' THEN
    v_out := v_out || jsonb_build_object('error', v_plan->>'error');
  END IF;

  -- Absència: només exposar absence_is_paid / hours quan is_absence
  IF NOT COALESCE((v_plan->>'is_absence')::boolean, false) THEN
    v_out := v_out - 'absence_is_paid' - 'absence_hours_per_day';
  END IF;

  RETURN v_out;
END;
$$;

COMMENT ON FUNCTION api.resolve_work_day(uuid, date) IS
  'Adaptador API sobre data.resolve_employee_work_plan (EX-03.3). Conserva auth i contracte estable.';
