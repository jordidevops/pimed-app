-- EX-03.4 / ST-19 (nucli schema): ubicació al planificador de torns
-- - work_shifts.default_location_id
-- - shift_slots.location_id + snapshots (name/path)
-- - integritat tenant/site/location
-- - herència a assign_shift_slot; freeze de snapshots a publish
-- - exposició a data.resolve_employee_work_plan / published_shift_intervals
-- UI planner completa, ST-18c, publication lots, role_id → paquets posteriors.

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. Schema
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE data.work_shifts
  ADD COLUMN IF NOT EXISTS default_location_id uuid
    REFERENCES data.locations(id) ON DELETE SET NULL;

COMMENT ON COLUMN data.work_shifts.default_location_id IS
  'ST-19: ubicació per defecte en assignar un slot des d''aquesta plantilla (nullable).';

ALTER TABLE data.shift_slots
  ADD COLUMN IF NOT EXISTS location_id uuid
    REFERENCES data.locations(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS location_name_snapshot text,
  ADD COLUMN IF NOT EXISTS location_path_snapshot text;

COMMENT ON COLUMN data.shift_slots.location_id IS
  'ST-19: lloc planificat del torn (override del default de la plantilla).';
COMMENT ON COLUMN data.shift_slots.location_name_snapshot IS
  'ST-19: nom de la ubicació congelat en publicar (o en assignar si ja es coneix).';
COMMENT ON COLUMN data.shift_slots.location_path_snapshot IS
  'ST-19: path «A › B › C» congelat; no es reescriu si es reanomena la location viva.';

CREATE INDEX IF NOT EXISTS idx_work_shifts_default_location
  ON data.work_shifts (default_location_id)
  WHERE default_location_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_shift_slots_location_date
  ON data.shift_slots (location_id, slot_date, status)
  WHERE location_id IS NOT NULL;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. Helper: omplir snapshots des de location_id
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION data.shift_slot_fill_location_snapshots(
  p_location_id uuid,
  OUT o_name text,
  OUT o_path text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF p_location_id IS NULL THEN
    o_name := NULL;
    o_path := NULL;
    RETURN;
  END IF;

  SELECT l.name, data.build_location_path_snapshot(l.id)
  INTO o_name, o_path
  FROM data.locations l
  WHERE l.id = p_location_id;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. Integritat work_shifts.default_location_id
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION data.trg_validate_work_shift_location()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_loc record;
BEGIN
  IF NEW.default_location_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT tenant_id, site_id, status INTO v_loc
  FROM data.locations
  WHERE id = NEW.default_location_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'integrity_violation: default_location not found'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF v_loc.tenant_id <> NEW.tenant_id THEN
    RAISE EXCEPTION 'integrity_violation: work_shift default_location tenant mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF NEW.site_id IS NOT NULL AND v_loc.site_id <> NEW.site_id THEN
    RAISE EXCEPTION 'integrity_violation: work_shift default_location site mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_work_shift_location ON data.work_shifts;
CREATE TRIGGER trg_validate_work_shift_location
  BEFORE INSERT OR UPDATE OF tenant_id, site_id, default_location_id ON data.work_shifts
  FOR EACH ROW EXECUTE FUNCTION data.trg_validate_work_shift_location();

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. Integritat shift_slots.location_id + freeze snapshots publicats
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION data.trg_validate_shift_slot_integrity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_emp record;
  v_shift record;
  v_site_tenant uuid;
  v_loc record;
  v_snap record;
BEGIN
  SELECT tenant_id, site_id, status INTO v_emp FROM data.employees WHERE id = NEW.employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'integrity_violation: employee not found'
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF v_emp.tenant_id <> NEW.tenant_id THEN
    RAISE EXCEPTION 'integrity_violation: shift_slot employee tenant mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  SELECT tenant_id, site_id, start_time, end_time, default_location_id
  INTO v_shift
  FROM data.work_shifts
  WHERE id = NEW.shift_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'integrity_violation: work_shift not found'
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF v_shift.tenant_id <> NEW.tenant_id THEN
    RAISE EXCEPTION 'integrity_violation: shift_slot shift tenant mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  SELECT tenant_id INTO v_site_tenant FROM data.sites WHERE id = NEW.site_id;
  IF v_site_tenant IS NULL OR v_site_tenant <> NEW.tenant_id THEN
    RAISE EXCEPTION 'integrity_violation: shift_slot site tenant mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF v_shift.site_id IS NOT NULL AND v_shift.site_id <> NEW.site_id THEN
    RAISE EXCEPTION 'integrity_violation: shift_slot shift site mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF NEW.start_time IS NULL THEN
    NEW.start_time := v_shift.start_time;
  END IF;
  IF NEW.end_time IS NULL THEN
    NEW.end_time := v_shift.end_time;
  END IF;

  -- Herència: si no hi ha location_id explícit en INSERT, agafar default de la plantilla
  IF TG_OP = 'INSERT' AND NEW.location_id IS NULL THEN
    NEW.location_id := v_shift.default_location_id;
  END IF;

  -- Validar location vs tenant/site del slot
  IF NEW.location_id IS NOT NULL THEN
    SELECT tenant_id, site_id INTO v_loc FROM data.locations WHERE id = NEW.location_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'integrity_violation: shift_slot location not found'
        USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF v_loc.tenant_id <> NEW.tenant_id THEN
      RAISE EXCEPTION 'integrity_violation: shift_slot location tenant mismatch'
        USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF v_loc.site_id <> NEW.site_id THEN
      RAISE EXCEPTION 'integrity_violation: shift_slot location site mismatch'
        USING ERRCODE = 'foreign_key_violation';
    END IF;
  END IF;

  -- Omplir / refrescar snapshots quan location canvia (només draft o en publicar)
  IF TG_OP = 'INSERT'
     OR NEW.location_id IS DISTINCT FROM OLD.location_id
     OR (OLD.status = 'draft' AND NEW.status = 'published')
  THEN
    IF NEW.location_id IS NULL THEN
      NEW.location_name_snapshot := NULL;
      NEW.location_path_snapshot := NULL;
    ELSE
      SELECT * INTO v_snap FROM data.shift_slot_fill_location_snapshots(NEW.location_id);
      NEW.location_name_snapshot := v_snap.o_name;
      NEW.location_path_snapshot := v_snap.o_path;
    END IF;
  END IF;

  -- Freeze: un slot published no pot mutar horari ni ubicació/snapshots
  -- (cancel·lació i notes sí; status published→cancelled sí).
  IF TG_OP = 'UPDATE' AND OLD.status = 'published' AND NEW.status = 'published' THEN
    IF NEW.start_time IS DISTINCT FROM OLD.start_time
       OR NEW.end_time IS DISTINCT FROM OLD.end_time
       OR NEW.location_id IS DISTINCT FROM OLD.location_id
       OR NEW.location_name_snapshot IS DISTINCT FROM OLD.location_name_snapshot
       OR NEW.location_path_snapshot IS DISTINCT FROM OLD.location_path_snapshot
       OR NEW.slot_date IS DISTINCT FROM OLD.slot_date
       OR NEW.employee_id IS DISTINCT FROM OLD.employee_id
       OR NEW.shift_id IS DISTINCT FROM OLD.shift_id
    THEN
      RAISE EXCEPTION 'integrity_violation: cannot mutate published shift_slot schedule/location snapshots'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_shift_slot_integrity ON data.shift_slots;
CREATE TRIGGER trg_validate_shift_slot_integrity
  BEFORE INSERT OR UPDATE OF tenant_id, site_id, employee_id, shift_id,
    start_time, end_time, location_id, location_name_snapshot, location_path_snapshot,
    status, slot_date
  ON data.shift_slots
  FOR EACH ROW EXECUTE FUNCTION data.trg_validate_shift_slot_integrity();

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. Vistes API
-- ═══════════════════════════════════════════════════════════════════════════

DROP VIEW IF EXISTS api.work_shifts CASCADE;
CREATE VIEW api.work_shifts
  WITH (security_invoker = true)
AS
SELECT
  ws.id,
  ws.tenant_id,
  ws.site_id,
  ws.name,
  ws.color,
  ws.start_time,
  ws.end_time,
  (ws.end_time < ws.start_time) AS spans_midnight,
  ROUND(
    EXTRACT(EPOCH FROM
      CASE WHEN ws.end_time > ws.start_time
           THEN ws.end_time - ws.start_time
           ELSE interval '24 hours' + (ws.end_time - ws.start_time)
      END
    ) / 60
  )::int AS duration_minutes,
  ws.is_active,
  ws.default_location_id,
  l.name AS default_location_name,
  data.build_location_path_snapshot(ws.default_location_id) AS default_location_path,
  ws.created_at,
  ws.updated_at
FROM data.work_shifts ws
LEFT JOIN data.locations l ON l.id = ws.default_location_id;

DROP VIEW IF EXISTS api.shift_slots CASCADE;
CREATE VIEW api.shift_slots
  WITH (security_invoker = true)
AS
SELECT
  ss.id,
  ss.tenant_id,
  ss.site_id,
  ss.employee_id,
  ss.shift_id,
  ss.slot_date,
  ss.status,
  ss.notes,
  ss.created_by,
  ss.published_at,
  ss.cancelled_at,
  ws.name AS shift_name,
  ws.color AS shift_color,
  ss.start_time,
  ss.end_time,
  (ss.end_time < ss.start_time) AS spans_midnight,
  ss.location_id,
  ss.location_name_snapshot,
  ss.location_path_snapshot,
  ss.created_at,
  ss.updated_at
FROM data.shift_slots ss
JOIN data.work_shifts ws ON ws.id = ss.shift_id;

GRANT SELECT ON api.work_shifts TO authenticated, service_role;
GRANT SELECT ON api.shift_slots TO authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- 6. api.assign_shift_slot — p_location_id opcional + herència
-- ═══════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS api.assign_shift_slot(uuid, date, uuid, text);

CREATE OR REPLACE FUNCTION api.assign_shift_slot(
  p_employee_id uuid,
  p_slot_date date,
  p_shift_id uuid,
  p_notes text DEFAULT NULL,
  p_location_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
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
BEGIN
  SELECT e.tenant_id, e.site_id, e.weekly_hours, e.status INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id USING ERRCODE = 'P0002';
  END IF;

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
    start_time, end_time, location_id
  ) VALUES (
    v_emp.tenant_id, v_site_id, p_employee_id, p_shift_id,
    p_slot_date, 'draft', p_notes, auth.uid(),
    v_shift.start_time, v_shift.end_time, v_location_id
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
      'anomalies', v_anomalies
    )
  );

  RETURN jsonb_build_object(
    'slot_id', v_slot_id,
    'status', 'draft',
    'location_id', v_location_id,
    'anomalies', v_anomalies
  );
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 7. api.publish_shifts — refresca snapshots en publicar (via trigger status)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION api.publish_shifts(
  p_site_id uuid,
  p_week_start date
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant_id uuid;
  v_tz text;
  v_week_end date;
  v_count int;
  v_slot record;
  v_start_at timestamptz;
  v_end_at timestamptz;
BEGIN
  IF EXTRACT(DOW FROM p_week_start)::int <> 1 THEN
    RAISE EXCEPTION 'invalid_week_start: p_week_start ha de ser dilluns'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT s.tenant_id INTO v_tenant_id FROM data.sites s WHERE s.id = p_site_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_not_found: %', p_site_id USING ERRCODE = 'P0002';
  END IF;

  IF NOT data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_tz := COALESCE((api.get_effective_settings(p_site_id => p_site_id, p_user_id => NULL, p_tenant_id => v_tenant_id) ->> 'site_timezone'), 'Europe/Madrid');
  v_week_end := p_week_start + 6;

  -- status draft→published dispara el trigger que refresca location_*_snapshot
  UPDATE data.shift_slots
  SET status = 'published', published_at = now(), updated_at = now()
  WHERE site_id = p_site_id
    AND slot_date BETWEEN p_week_start AND v_week_end
    AND status = 'draft';

  GET DIAGNOSTICS v_count = ROW_COUNT;

  FOR v_slot IN
    SELECT ss.id AS slot_id, ss.employee_id, ss.slot_date, ss.site_id,
           ss.start_time, ss.end_time, ss.location_id,
           ss.location_name_snapshot, ss.location_path_snapshot,
           ws.name, ws.color
    FROM data.shift_slots ss
    JOIN data.work_shifts ws ON ws.id = ss.shift_id
    WHERE ss.site_id = p_site_id
      AND ss.slot_date BETWEEN p_week_start AND v_week_end
      AND ss.status = 'published'
  LOOP
    v_start_at := (v_slot.slot_date::text || ' ' || v_slot.start_time::text)::timestamp AT TIME ZONE v_tz;
    IF v_slot.end_time > v_slot.start_time THEN
      v_end_at := (v_slot.slot_date::text || ' ' || v_slot.end_time::text)::timestamp AT TIME ZONE v_tz;
    ELSE
      v_end_at := ((v_slot.slot_date + 1)::text || ' ' || v_slot.end_time::text)::timestamp AT TIME ZONE v_tz;
    END IF;

    DELETE FROM data.calendar_events WHERE entity_type = 'shift_slot' AND entity_id = v_slot.slot_id;

    INSERT INTO data.calendar_events (
      tenant_id, site_id, entity_type, entity_id, title, start_at, end_at, color, required_permissions, owner_id, metadata
    ) VALUES (
      v_tenant_id, v_slot.site_id, 'shift_slot', v_slot.slot_id, v_slot.name,
      v_start_at, v_end_at, v_slot.color, ARRAY['labor_calendar.view'],
      (SELECT id FROM data.profiles WHERE id = auth.uid() LIMIT 1),
      jsonb_build_object(
        'employee_id', v_slot.employee_id,
        'slot_date', v_slot.slot_date,
        'location_id', v_slot.location_id,
        'location_name', v_slot.location_name_snapshot,
        'location_path', v_slot.location_path_snapshot
      )
    );
  END LOOP;

  PERFORM data.log_audit_event(
    v_tenant_id, auth.uid(), p_site_id,
    'SHIFTS_PUBLISHED', 'shift_slot', NULL,
    jsonb_build_object('site_id', p_site_id, 'week_start', p_week_start, 'published', v_count)
  );

  RETURN jsonb_build_object('site_id', p_site_id, 'week_start', p_week_start, 'published', v_count);
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 8. Resolver: intervals amb location_id + scheduled_location_id
-- ═══════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS data.resolve_employee_work_plan(uuid, date);
DROP FUNCTION IF EXISTS data.published_shift_intervals_for_day(uuid, date);

CREATE OR REPLACE FUNCTION data.published_shift_intervals_for_day(
  p_employee_id uuid,
  p_work_date   date
)
RETURNS TABLE(
  work_intervals          jsonb,
  planned_minutes         integer,
  published_slot_ids      uuid[],
  slot_site_id            uuid,
  scheduled_location_id   uuid,
  scheduled_location_name text,
  scheduled_location_path text
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
  v_loc_id    uuid;
  v_loc_name  text;
  v_loc_path  text;
  v_row       record;
BEGIN
  FOR v_row IN
    SELECT ss.id, ss.site_id, ss.start_time, ss.end_time,
           ss.location_id, ss.location_name_snapshot, ss.location_path_snapshot
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
    IF v_loc_id IS NULL AND v_row.location_id IS NOT NULL THEN
      v_loc_id := v_row.location_id;
      v_loc_name := v_row.location_name_snapshot;
      v_loc_path := v_row.location_path_snapshot;
    END IF;
    v_intervals := v_intervals || jsonb_build_array(jsonb_build_object(
      'start', to_char(v_row.start_time, 'HH24:MI'),
      'end',   to_char(v_row.end_time,   'HH24:MI'),
      'location_id', v_row.location_id,
      'location_name', v_row.location_name_snapshot,
      'location_path', v_row.location_path_snapshot,
      'role_id', NULL
    ));
  END LOOP;

  IF cardinality(v_ids) = 0 THEN
    RETURN QUERY SELECT
      '[]'::jsonb, 0, ARRAY[]::uuid[], NULL::uuid, NULL::uuid, NULL::text, NULL::text;
    RETURN;
  END IF;

  RETURN QUERY SELECT
    v_intervals,
    data.labor_planned_minutes(v_intervals, NULL::time, NULL::time),
    v_ids,
    v_site,
    v_loc_id,
    v_loc_name,
    v_loc_path;
END;
$$;

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

-- Exposar camps nous a l'adaptador API
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
    'scheduled_location_name',   v_plan->'scheduled_location_name',
    'scheduled_location_path',   v_plan->'scheduled_location_path',
    'location_id',               v_plan->'location_id'
  );

  IF v_plan ? 'error' THEN
    v_out := v_out || jsonb_build_object('error', v_plan->>'error');
  END IF;

  IF NOT COALESCE((v_plan->>'is_absence')::boolean, false) THEN
    v_out := v_out - 'absence_is_paid' - 'absence_hours_per_day';
  END IF;

  RETURN v_out;
END;
$$;

COMMENT ON FUNCTION data.resolve_employee_work_plan(uuid, date) IS
  'EX-03.3/03.4: resolver canònic (labor + weekly + slots published amb location snapshots).';
