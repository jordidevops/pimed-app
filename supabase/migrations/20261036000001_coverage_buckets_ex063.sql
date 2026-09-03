-- =============================================================================
-- EX-06.3 — Cobertura per buckets de 15/30 min (demanda vs slots planificats)
-- No-objectius: confirmat/real/qualificat (EX-06.4), dashboard alertes (EX-06.5)
-- =============================================================================

-- Solapament de franges horàries el mateix dia (minuts des de mitjanit).
-- Overnight: end_min <= start_min ⇒ [start, 1440) ∪ [0, end).
CREATE OR REPLACE FUNCTION data.time_range_overlaps_minutes(
  p_start_a int,
  p_end_a   int,
  p_start_b int,
  p_end_b   int
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_start_a < p_end_a AND p_start_b < p_end_b THEN
      p_start_a < p_end_b AND p_start_b < p_end_a
    WHEN p_start_a >= p_end_a AND p_start_b < p_end_b THEN
      -- A overnight: overlaps B if B intersects [start_a,1440) or [0,end_a)
      p_start_b < p_end_a OR p_end_b > p_start_a
    WHEN p_start_a < p_end_a AND p_start_b >= p_end_b THEN
      p_start_a < p_end_b OR p_end_a > p_start_b
    ELSE
      -- both overnight: always overlap on a 24h day unless identical empty (not possible)
      true
  END;
$$;

CREATE OR REPLACE FUNCTION data.time_to_minutes(p_t time)
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT (EXTRACT(HOUR FROM p_t) * 60 + EXTRACT(MINUTE FROM p_t))::int;
$$;

COMMENT ON FUNCTION data.time_range_overlaps_minutes IS
  'EX-06.3: solapament de dos intervals en minuts (suporta overnight).';

-- ─── RPC principal ───────────────────────────────────────────────────────────

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
    -- Slots del dia + overnight del dia anterior que cobreixen matinada
    SELECT
      ss.id AS slot_id,
      ss.employee_id,
      ss.role_id,
      ss.location_id,
      CASE
        WHEN ss.slot_date = p_date THEN data.time_to_minutes(ss.start_time)
        ELSE 0  -- carry from previous overnight: from midnight
      END AS start_min,
      CASE
        WHEN ss.slot_date = p_date AND ss.end_time > ss.start_time THEN data.time_to_minutes(ss.end_time)
        WHEN ss.slot_date = p_date AND ss.end_time <= ss.start_time THEN 1440  -- until midnight of slot day
        WHEN ss.slot_date = p_date - 1 AND ss.end_time <= ss.start_time THEN data.time_to_minutes(ss.end_time)
        ELSE data.time_to_minutes(ss.end_time)
      END AS end_min
    FROM data.shift_slots ss
    WHERE ss.site_id = p_site_id
      AND ss.status <> 'cancelled'
      AND (
        ss.slot_date = p_date
        OR (
          ss.slot_date = p_date - 1
          AND ss.end_time <= ss.start_time  -- overnight into p_date
        )
      )
      AND (p_role_id IS NULL OR ss.role_id IS NULL OR ss.role_id = p_role_id)
      AND (p_location_id IS NULL OR ss.location_id IS NULL OR ss.location_id = p_location_id)
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
      ), 0) AS assigned
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
      'assigned', assigned,
      'gap', assigned - required,
      'role_id', p_role_id,
      'location_id', p_location_id
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
  'EX-06.3: cobertura planificada per buckets 15/30 min (demanda vs slots).';

NOTIFY pgrst, 'reload schema';
