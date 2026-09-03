-- =============================================================================
-- EX-06.4 — Capes de cobertura: planificat / confirmat / real / qualificat
-- Extén api.get_coverage_buckets. No-objectius: dashboard alertes (EX-06.5), vacants (EX-07).
-- =============================================================================

-- ─── 1. Confirmació opcional de slot ─────────────────────────────────────────

ALTER TABLE data.shift_slots
  ADD COLUMN IF NOT EXISTS employee_confirmed_at timestamptz;

COMMENT ON COLUMN data.shift_slots.employee_confirmed_at IS
  'EX-06.4: quan l''empleat ha acceptat el torn publicat (si el tenant ho exigeix).';

INSERT INTO data.settings_registry
  (setting_key, scope, required_permission, owner_only, is_active, description)
VALUES
  ('require_shift_confirmation', 'tenant', 'labor_calendar.manage', false, true,
   'EX-06.4: si true, la capa «confirmada» només compta slots amb employee_confirmed_at')
ON CONFLICT (setting_key) DO UPDATE SET
  scope = EXCLUDED.scope,
  description = EXCLUDED.description,
  updated_at = now();

INSERT INTO data.system_settings (module, settings)
VALUES ('defaults', '{"require_shift_confirmation": false}'::jsonb)
ON CONFLICT (module) DO UPDATE
  SET settings = data.system_settings.settings || EXCLUDED.settings,
      updated_at = now();

-- Vista api.shift_slots (+ role + confirmació)
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
  ss.publication_id,
  ss.employee_confirmed_at,
  ws.name AS shift_name,
  ws.color AS shift_color,
  ss.start_time,
  ss.end_time,
  (ss.end_time < ss.start_time) AS spans_midnight,
  ss.location_id,
  ss.location_name_snapshot,
  ss.location_path_snapshot,
  ss.role_id,
  ss.role_name_snapshot,
  ss.created_at,
  ss.updated_at
FROM data.shift_slots ss
JOIN data.work_shifts ws ON ws.id = ss.shift_id;

GRANT SELECT ON api.shift_slots TO authenticated, service_role;

-- Empleat confirma el seu torn publicat
CREATE OR REPLACE FUNCTION api.confirm_shift_slot(p_slot_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_slot record;
  v_emp_id uuid;
BEGIN
  IF p_slot_id IS NULL THEN
    RAISE EXCEPTION 'slot_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT ss.* INTO v_slot FROM data.shift_slots ss WHERE ss.id = p_slot_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'slot_not_found: %', p_slot_id USING ERRCODE = 'P0002';
  END IF;

  IF NOT (data.jwt_user_tenants() ? v_slot.tenant_id::text) THEN
    RAISE EXCEPTION 'insufficient_privilege: no ets membre del tenant'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT e.id INTO v_emp_id
  FROM data.employees e
  WHERE e.id = v_slot.employee_id
    AND e.user_id = auth.uid();

  IF v_emp_id IS NULL THEN
    -- Manager amb labor_calendar.manage pot marcar confirmació en nom de l'empleat
    IF NOT data.jwt_has_permission(v_slot.tenant_id, 'labor_calendar.manage', v_slot.site_id) THEN
      RAISE EXCEPTION 'insufficient_privilege: només el titular o un manager'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  IF v_slot.status <> 'published' THEN
    RAISE EXCEPTION 'slot_not_published' USING ERRCODE = 'check_violation';
  END IF;

  UPDATE data.shift_slots
  SET employee_confirmed_at = COALESCE(employee_confirmed_at, now()),
      updated_at = now()
  WHERE id = p_slot_id
  RETURNING employee_confirmed_at INTO v_slot.employee_confirmed_at;

  RETURN jsonb_build_object(
    'slot_id', p_slot_id,
    'employee_confirmed_at', v_slot.employee_confirmed_at
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.confirm_shift_slot(uuid) TO authenticated, service_role;

COMMENT ON FUNCTION api.confirm_shift_slot IS
  'EX-06.4: marca employee_confirmed_at al slot publicat (empleat titular o manager).';

-- ─── 2. Presència per dia (IN/OUT; pausa = encara present) ───────────────────

CREATE OR REPLACE FUNCTION data.coverage_presence_intervals(
  p_site_id uuid,
  p_date    date,
  p_tz      text DEFAULT 'Europe/Madrid'
)
RETURNS TABLE (
  employee_id uuid,
  start_min   int,
  end_min     int
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tz text := COALESCE(NULLIF(btrim(p_tz), ''), 'Europe/Madrid');
  v_day_start timestamptz;
  v_day_end   timestamptz;
  v_lookback  timestamptz;
  v_now       timestamptz := clock_timestamp();
  v_emp uuid;
  v_present_from timestamptz;
  r record;
  v_clip_start int;
  v_clip_end int;
  v_seg_start timestamptz;
  v_seg_end timestamptz;
BEGIN
  v_day_start := (p_date::timestamp AT TIME ZONE v_tz);
  v_day_end   := ((p_date + 1)::timestamp AT TIME ZONE v_tz);
  v_lookback  := ((p_date - 1)::timestamp AT TIME ZONE v_tz);

  FOR v_emp IN
    SELECT DISTINCT tp.employee_id
    FROM data.time_punches tp
    WHERE tp.site_id = p_site_id
      AND tp.occurred_at >= v_lookback
      AND tp.occurred_at < v_day_end + interval '12 hours'
      AND tp.punch_type IN ('in', 'out', 'break_start', 'break_end')
  LOOP
    v_present_from := NULL;

    FOR r IN
      SELECT tp.punch_type, tp.occurred_at
      FROM data.time_punches tp
      WHERE tp.employee_id = v_emp
        AND tp.site_id = p_site_id
        AND tp.occurred_at >= v_lookback
        AND tp.occurred_at < v_day_end + interval '12 hours'
        AND tp.punch_type IN ('in', 'out', 'break_start', 'break_end')
      ORDER BY tp.occurred_at ASC, tp.id ASC
    LOOP
      IF r.punch_type = 'in' AND v_present_from IS NULL THEN
        v_present_from := r.occurred_at;
      ELSIF r.punch_type = 'out' AND v_present_from IS NOT NULL THEN
        v_seg_start := v_present_from;
        v_seg_end := r.occurred_at;
        v_present_from := NULL;

        IF v_seg_end > v_day_start AND v_seg_start < v_day_end THEN
          v_clip_start := GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (GREATEST(v_seg_start, v_day_start) - v_day_start)) / 60)::int);
          v_clip_end := LEAST(1440, CEIL(EXTRACT(EPOCH FROM (LEAST(v_seg_end, v_day_end) - v_day_start)) / 60)::int);
          IF v_clip_end > v_clip_start THEN
            employee_id := v_emp;
            start_min := v_clip_start;
            end_min := v_clip_end;
            RETURN NEXT;
          END IF;
        END IF;
      END IF;
      -- break_start / break_end: segueix present
    END LOOP;

    -- Sessió oberta
    IF v_present_from IS NOT NULL THEN
      v_seg_start := v_present_from;
      IF p_date = (v_now AT TIME ZONE v_tz)::date THEN
        v_seg_end := LEAST(v_now, v_day_end);
      ELSE
        v_seg_end := v_day_end;
      END IF;

      IF v_seg_end > v_day_start AND v_seg_start < v_day_end THEN
        v_clip_start := GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (GREATEST(v_seg_start, v_day_start) - v_day_start)) / 60)::int);
        v_clip_end := LEAST(1440, CEIL(EXTRACT(EPOCH FROM (LEAST(v_seg_end, v_day_end) - v_day_start)) / 60)::int);
        IF v_clip_end > v_clip_start THEN
          employee_id := v_emp;
          start_min := v_clip_start;
          end_min := v_clip_end;
          RETURN NEXT;
        END IF;
      END IF;
    END IF;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION data.coverage_presence_intervals(uuid, date, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.coverage_presence_intervals(uuid, date, text) TO authenticated, service_role;

COMMENT ON FUNCTION data.coverage_presence_intervals IS
  'EX-06.4: intervals de presència (minuts locals) per site/data a partir de fitxatges.';

-- ─── 3. get_coverage_buckets amb 4 capes ─────────────────────────────────────

CREATE OR REPLACE FUNCTION api.get_coverage_buckets(
  p_site_id         uuid,
  p_date            date,
  p_bucket_minutes  int DEFAULT 30,
  p_role_id         uuid DEFAULT NULL,
  p_location_id     uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant_id uuid;
  v_bucket int;
  v_result jsonb;
  v_tz text := 'Europe/Madrid';
  v_require_confirm boolean := false;
BEGIN
  IF p_site_id IS NULL OR p_date IS NULL THEN
    RAISE EXCEPTION 'site_and_date_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  v_bucket := COALESCE(p_bucket_minutes, 30);
  IF v_bucket NOT IN (15, 30) THEN
    RAISE EXCEPTION 'invalid_bucket_minutes: use 15 or 30'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

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

  SELECT COALESCE(
    NULLIF(btrim(si.settings->>'site_timezone'), ''),
    NULLIF(btrim(t.settings->>'site_timezone'), ''),
    'Europe/Madrid'
  )
  INTO v_tz
  FROM data.sites si
  JOIN data.tenants t ON t.id = si.tenant_id
  WHERE si.id = p_site_id;

  SELECT COALESCE(
    (COALESCE(t.settings, '{}'::jsonb)->>'require_shift_confirmation')::boolean,
    (SELECT (ss.settings->>'require_shift_confirmation')::boolean
     FROM data.system_settings ss WHERE ss.module = 'defaults'),
    false
  )
  INTO v_require_confirm
  FROM data.tenants t
  WHERE t.id = v_tenant_id;

  v_require_confirm := COALESCE(v_require_confirm, false);

  WITH buckets AS (
    SELECT
      gs AS bucket_start_min,
      gs + v_bucket AS bucket_end_min,
      make_time((gs / 60)::int, (gs % 60)::int, 0) AS bucket_start,
      CASE
        WHEN gs + v_bucket >= 1440 THEN make_time(23, 59, 0)
        ELSE make_time(((gs + v_bucket) / 60)::int, ((gs + v_bucket) % 60)::int, 0)
      END AS bucket_end
    FROM generate_series(0, 1440 - v_bucket, v_bucket) AS gs
  ),
  demands AS (
    SELECT
      cd.id,
      cd.role_id,
      cd.location_id,
      cd.required_target,
      data.time_to_minutes(cd.start_time) AS start_min,
      data.time_to_minutes(cd.end_time) AS end_min
    FROM data.coverage_demands cd
    WHERE cd.site_id = p_site_id
      AND data.coverage_demand_applies_on(cd, p_date)
      AND (p_role_id IS NULL OR cd.role_id IS NULL OR cd.role_id = p_role_id)
      AND (p_location_id IS NULL OR cd.location_id IS NULL OR cd.location_id = p_location_id)
  ),
  slots AS (
    SELECT
      ss.id AS slot_id,
      ss.employee_id,
      ss.role_id,
      ss.location_id,
      ss.employee_confirmed_at,
      CASE
        WHEN ss.slot_date = p_date THEN data.time_to_minutes(ss.start_time)
        ELSE 0
      END AS start_min,
      CASE
        WHEN ss.slot_date = p_date AND ss.end_time > ss.start_time THEN data.time_to_minutes(ss.end_time)
        WHEN ss.slot_date = p_date AND ss.end_time <= ss.start_time THEN 1440
        WHEN ss.slot_date = p_date - 1 AND ss.end_time <= ss.start_time THEN data.time_to_minutes(ss.end_time)
        ELSE data.time_to_minutes(ss.end_time)
      END AS end_min
    FROM data.shift_slots ss
    WHERE ss.site_id = p_site_id
      AND ss.status = 'published'
      AND (
        ss.slot_date = p_date
        OR (
          ss.slot_date = p_date - 1
          AND ss.end_time <= ss.start_time
        )
      )
      AND (p_role_id IS NULL OR ss.role_id IS NULL OR ss.role_id = p_role_id)
      AND (p_location_id IS NULL OR ss.location_id IS NULL OR ss.location_id = p_location_id)
  ),
  presence AS (
    SELECT p.employee_id, p.start_min, p.end_min
    FROM data.coverage_presence_intervals(p_site_id, p_date, v_tz) p
    WHERE p_role_id IS NULL
       OR data.employee_has_active_role(p.employee_id, p_role_id, p_date)
       OR EXISTS (
         SELECT 1 FROM slots s
         WHERE s.employee_id = p.employee_id
           AND (s.role_id IS NULL OR s.role_id = p_role_id)
       )
  ),
  scored AS (
    SELECT
      b.bucket_start_min,
      b.bucket_end_min,
      b.bucket_start,
      b.bucket_end,
      COALESCE((
        SELECT SUM(d.required_target)::int
        FROM demands d
        WHERE data.time_range_overlaps_minutes(
          d.start_min, d.end_min, b.bucket_start_min, b.bucket_end_min
        )
      ), 0) AS required,
      COALESCE((
        SELECT COUNT(DISTINCT s.employee_id)::int
        FROM slots s
        WHERE data.time_range_overlaps_minutes(
          s.start_min, s.end_min, b.bucket_start_min, b.bucket_end_min
        )
      ), 0) AS planned,
      COALESCE((
        SELECT COUNT(DISTINCT s.employee_id)::int
        FROM slots s
        WHERE data.time_range_overlaps_minutes(
          s.start_min, s.end_min, b.bucket_start_min, b.bucket_end_min
        )
          AND (
            NOT v_require_confirm
            OR s.employee_confirmed_at IS NOT NULL
          )
      ), 0) AS confirmed,
      COALESCE((
        SELECT COUNT(DISTINCT pr.employee_id)::int
        FROM presence pr
        WHERE data.time_range_overlaps_minutes(
          pr.start_min, pr.end_min, b.bucket_start_min, b.bucket_end_min
        )
      ), 0) AS present,
      COALESCE((
        SELECT COUNT(DISTINCT pr.employee_id)::int
        FROM presence pr
        WHERE data.time_range_overlaps_minutes(
          pr.start_min, pr.end_min, b.bucket_start_min, b.bucket_end_min
        )
          AND (
            CASE
              WHEN p_role_id IS NOT NULL THEN
                data.employee_meets_role_qualifications(pr.employee_id, p_role_id, p_date)
              ELSE
                COALESCE(
                  (
                    SELECT bool_and(
                      CASE
                        WHEN s.role_id IS NULL THEN true
                        ELSE data.employee_meets_role_qualifications(pr.employee_id, s.role_id, p_date)
                      END
                    )
                    FROM slots s
                    WHERE s.employee_id = pr.employee_id
                      AND data.time_range_overlaps_minutes(
                        s.start_min, s.end_min, b.bucket_start_min, b.bucket_end_min
                      )
                  ),
                  true
                )
            END
          )
      ), 0) AS qualified
    FROM buckets b
  )
  SELECT jsonb_agg(
    jsonb_build_object(
      'bucket_start', to_char(bucket_start, 'HH24:MI'),
      'bucket_end', CASE
        WHEN bucket_end_min >= 1440 THEN '24:00'
        ELSE to_char(bucket_end, 'HH24:MI')
      END,
      'bucket_start_min', bucket_start_min,
      'bucket_end_min', bucket_end_min,
      'required', required,
      'planned', planned,
      'confirmed', confirmed,
      'present', present,
      'qualified', qualified,
      'assigned', planned,
      'gap', planned - required,
      'gap_planned', planned - required,
      'gap_confirmed', confirmed - required,
      'gap_present', present - required,
      'gap_qualified', qualified - required,
      'role_id', p_role_id,
      'location_id', p_location_id,
      'require_shift_confirmation', v_require_confirm
    )
    ORDER BY bucket_start_min
  )
  INTO v_result
  FROM scored;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_coverage_buckets(uuid, date, int, uuid, uuid) TO authenticated, service_role;

COMMENT ON FUNCTION api.get_coverage_buckets IS
  'EX-06.4: cobertura per buckets 15/30 — required + planned/confirmed/present/qualified.';

NOTIFY pgrst, 'reload schema';
