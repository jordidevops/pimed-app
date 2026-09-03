-- =============================================================================
-- Track G Phase 1b — Activity segments + extended punch types
-- PRD: plan-effective-work-time.md §5.0, §11.3
-- Depends: 20260901000001_track_g_phase1_record_policies.sql
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Extend punch_type CHECK
-- -----------------------------------------------------------------------------
ALTER TABLE data.time_punches
  DROP CONSTRAINT IF EXISTS time_punches_punch_type_check;

ALTER TABLE data.time_punches
  ADD CONSTRAINT time_punches_punch_type_check
  CHECK (punch_type IN (
    'in', 'out', 'break_start', 'break_end',
    'day_start', 'day_end', 'travel_start', 'travel_end'
  ));

COMMENT ON COLUMN data.time_punches.punch_type IS
  'Raw punch type. Extended types (day_*, travel_*) for mobile/hybrid profiles (Track G 1b).';

-- -----------------------------------------------------------------------------
-- 2. time_activity_segments (derived, recomputable)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.time_activity_segments (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id       uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  work_date         date NOT NULL,
  activity_kind     text NOT NULL CHECK (activity_kind IN (
    'WORK', 'TRAVEL', 'BREAK_PAID', 'BREAK_UNPAID', 'OFF_DUTY', 'STANDBY'
  )),
  started_at        timestamptz NOT NULL,
  ended_at          timestamptz,
  site_id           uuid REFERENCES data.sites(id) ON DELETE SET NULL,
  work_log_id       uuid REFERENCES data.work_logs(id) ON DELETE SET NULL,
  work_location_ref text,
  expense_ref_id    uuid REFERENCES data.project_expenses(id) ON DELETE SET NULL,
  source_punch_ids  uuid[] NOT NULL DEFAULT '{}',
  flags_snapshot    jsonb NOT NULL DEFAULT '{}',
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (employee_id, work_date, started_at, activity_kind)
);

CREATE INDEX IF NOT EXISTS idx_activity_segments_employee_date
  ON data.time_activity_segments (employee_id, work_date);

CREATE INDEX IF NOT EXISTS idx_activity_segments_tenant_date
  ON data.time_activity_segments (tenant_id, work_date);

CREATE INDEX IF NOT EXISTS idx_activity_segments_work_log
  ON data.time_activity_segments (work_log_id)
  WHERE work_log_id IS NOT NULL;

COMMENT ON TABLE data.time_activity_segments IS
  'Segments d''activitat derivats de punches (G1b). Recomputables; no substitueixen raw punches.';

ALTER TABLE data.time_activity_segments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "tas: tenant read" ON data.time_activity_segments;
CREATE POLICY "tas: tenant read" ON data.time_activity_segments
  FOR SELECT TO authenticated
  USING (tenant_id = data.active_tenant_id());

DROP POLICY IF EXISTS "tas: service all" ON data.time_activity_segments;
CREATE POLICY "tas: service all" ON data.time_activity_segments
  FOR ALL TO service_role
  USING (true) WITH CHECK (true);

-- -----------------------------------------------------------------------------
-- 3. Punch day state helpers
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.punch_day_state_after(
  p_state text,
  p_punch_type text
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  CASE p_punch_type
    WHEN 'day_start' THEN
      IF p_state IN ('off', 'day') THEN RETURN 'day'; END IF;
      RETURN NULL;
    WHEN 'day_end' THEN
      IF p_state IN ('day', 'work', 'break', 'travel') THEN RETURN 'off'; END IF;
      RETURN NULL;
    WHEN 'in' THEN
      IF p_state IN ('off', 'day', 'travel') THEN RETURN 'work'; END IF;
      RETURN NULL;
    WHEN 'out' THEN
      IF p_state = 'work' THEN RETURN 'day'; END IF;
      RETURN NULL;
    WHEN 'break_start' THEN
      IF p_state = 'work' THEN RETURN 'break'; END IF;
      RETURN NULL;
    WHEN 'break_end' THEN
      IF p_state = 'break' THEN RETURN 'work'; END IF;
      RETURN NULL;
    WHEN 'travel_start' THEN
      IF p_state IN ('day', 'work') THEN RETURN 'travel'; END IF;
      RETURN NULL;
    WHEN 'travel_end' THEN
      IF p_state = 'travel' THEN RETURN 'day'; END IF;
      RETURN NULL;
    ELSE
      RETURN NULL;
  END CASE;
END;
$$;

CREATE OR REPLACE FUNCTION data.initial_punch_day_state()
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 'off'::text $$;

CREATE OR REPLACE FUNCTION data.is_mobile_work_profile(p_profile text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT COALESCE(p_profile, 'fixed_site') IN (
    'mobile_peripatetic', 'hybrid', 'delivery'
  );
$$;

CREATE OR REPLACE FUNCTION data.policy_legacy_in_out_only(p_policy jsonb, p_work_profile text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    COALESCE(p_work_profile, 'fixed_site') = 'fixed_site'
    OR COALESCE((p_policy->>'legacy_in_out_only')::boolean, false);
$$;

-- -----------------------------------------------------------------------------
-- 4. Validate punch sequence for resolved work profile
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.validate_time_punch_sequence(
  p_employee_id   uuid,
  p_work_date     date,
  p_punch_type    text,
  p_work_profile  text DEFAULT NULL,
  p_policy        jsonb DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_profile      text;
  v_policy       jsonb;
  v_legacy       boolean;
  v_state        text := 'off';
  v_punch        record;
  v_last_type    text;
BEGIN
  IF p_work_profile IS NOT NULL THEN
    v_profile := p_work_profile;
    v_policy  := COALESCE(p_policy, '{}'::jsonb);
  ELSE
    SELECT
      (resolved->>'work_profile'),
      resolved->'policy'
    INTO v_profile, v_policy
    FROM (
      SELECT data.resolve_attendance_record_policy(p_employee_id, p_work_date) AS resolved
    ) r;
  END IF;

  v_profile := COALESCE(v_profile, 'fixed_site');
  v_policy  := COALESCE(v_policy, '{}'::jsonb);
  v_legacy  := data.policy_legacy_in_out_only(v_policy, v_profile);

  IF NOT data.is_mobile_work_profile(v_profile)
     AND p_punch_type IN ('day_start', 'day_end', 'travel_start', 'travel_end') THEN
    RAISE EXCEPTION 'invalid_sequence: punch_type % not allowed for profile %',
      p_punch_type, v_profile
      USING ERRCODE = 'check_violation';
  END IF;

  FOR v_punch IN
    SELECT punch_type
    FROM data.time_punches
    WHERE employee_id = p_employee_id
      AND (occurred_at AT TIME ZONE 'Europe/Madrid')::date = p_work_date
    ORDER BY occurred_at ASC, id ASC
  LOOP
    v_last_type := v_punch.punch_type;
    IF data.punch_day_state_after(v_state, v_punch.punch_type) IS NULL THEN
      RAISE EXCEPTION 'invalid_sequence: existing punch % breaks state machine', v_punch.punch_type
        USING ERRCODE = 'check_violation';
    END IF;
    v_state := data.punch_day_state_after(v_state, v_punch.punch_type);
  END LOOP;

  IF p_punch_type = 'in'
     AND v_state = 'off'
     AND NOT v_legacy
     AND data.is_mobile_work_profile(v_profile) THEN
    RAISE EXCEPTION 'invalid_sequence: day_start required before in for profile %', v_profile
      USING ERRCODE = 'check_violation';
  END IF;

  IF data.punch_day_state_after(v_state, p_punch_type) IS NULL THEN
    RAISE EXCEPTION 'invalid_sequence: cannot % after % (profile %)',
      p_punch_type, COALESCE(v_last_type, 'start'), v_profile
      USING ERRCODE = 'check_violation';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION data.validate_time_punch_sequence(uuid, date, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.validate_time_punch_sequence(uuid, date, text, text, jsonb) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 5. Classify activity segments from punches (G1b — punch-only)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.classify_activity_segments(
  p_employee_id uuid,
  p_work_date   date,
  p_tenant_id   uuid
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp          record;
  v_tz           text;
  v_resolved     jsonb;
  v_profile      text;
  v_legacy       boolean;
  v_punch_from   timestamptz;
  v_punch_to     timestamptz;
  v_count        int := 0;
  v_punch        record;
  v_open_kind    text;
  v_open_start   timestamptz;
  v_open_punches uuid[] := '{}';
  v_break_kind   text;
  v_first_in     timestamptz;
  v_last_out     timestamptz;
  v_day_start    timestamptz;
  v_day_end      timestamptz;
  v_added        int;
  v_has_day_start boolean := false;
  v_has_day_end   boolean := false;
BEGIN
  SELECT e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  v_tz := COALESCE(data.get_site_timezone(v_emp.site_id, p_tenant_id), 'Europe/Madrid');
  v_punch_from := p_work_date AT TIME ZONE v_tz;
  v_punch_to   := (p_work_date + 1) AT TIME ZONE v_tz;

  v_resolved := data.resolve_attendance_record_policy(p_employee_id, p_work_date);
  v_profile  := COALESCE(v_resolved->>'work_profile', 'fixed_site');
  v_legacy   := data.policy_legacy_in_out_only(v_resolved->'policy', v_profile);

  DELETE FROM data.time_activity_segments
  WHERE employee_id = p_employee_id AND work_date = p_work_date;

  SELECT MIN(occurred_at) FILTER (WHERE punch_type = 'in'),
         MAX(occurred_at) FILTER (WHERE punch_type = 'out'),
         MIN(occurred_at) FILTER (WHERE punch_type = 'day_start'),
         MAX(occurred_at) FILTER (WHERE punch_type = 'day_end')
  INTO v_first_in, v_last_out, v_day_start, v_day_end
  FROM data.time_punches
  WHERE employee_id = p_employee_id
    AND occurred_at >= v_punch_from
    AND occurred_at < v_punch_to;

  v_has_day_start := v_day_start IS NOT NULL;
  v_has_day_end   := v_day_end IS NOT NULL;

  -- fixed_site / legacy: single WORK envelope + explicit breaks
  IF NOT data.is_mobile_work_profile(v_profile) OR v_legacy THEN
    IF v_first_in IS NOT NULL AND v_last_out IS NOT NULL AND v_last_out > v_first_in THEN
      INSERT INTO data.time_activity_segments (
        tenant_id, employee_id, work_date, activity_kind,
        started_at, ended_at, site_id, source_punch_ids, flags_snapshot
      )
      SELECT
        p_tenant_id, p_employee_id, p_work_date, 'WORK',
        v_first_in, v_last_out, v_emp.site_id,
        ARRAY(
          SELECT id FROM data.time_punches
          WHERE employee_id = p_employee_id
            AND occurred_at >= v_punch_from AND occurred_at < v_punch_to
            AND punch_type IN ('in', 'out')
        ),
        jsonb_build_object('work_profile', v_profile, 'classifier', 'fixed_site_legacy');
      v_count := v_count + 1;
    END IF;

    INSERT INTO data.time_activity_segments (
      tenant_id, employee_id, work_date, activity_kind,
      started_at, ended_at, site_id, source_punch_ids, flags_snapshot
    )
    SELECT
      p_tenant_id, p_employee_id, p_work_date,
      CASE WHEN COALESCE(bs.pause_counts_as_work, false) THEN 'BREAK_PAID' ELSE 'BREAK_UNPAID' END,
      bs.occurred_at, be.occurred_at, v_emp.site_id,
      ARRAY[bs.id, be.id],
      jsonb_build_object('pause_type', bs.pause_type, 'classifier', 'fixed_site_legacy')
    FROM (
      SELECT id, occurred_at, pause_type, pause_counts_as_work,
             ROW_NUMBER() OVER (ORDER BY occurred_at) AS rn
      FROM data.time_punches
      WHERE employee_id = p_employee_id
        AND occurred_at >= v_punch_from AND occurred_at < v_punch_to
        AND punch_type = 'break_start'
    ) bs
    JOIN (
      SELECT id, occurred_at, ROW_NUMBER() OVER (ORDER BY occurred_at) AS rn
      FROM data.time_punches
      WHERE employee_id = p_employee_id
        AND occurred_at >= v_punch_from AND occurred_at < v_punch_to
        AND punch_type = 'break_end'
    ) be ON bs.rn = be.rn
    WHERE be.occurred_at > bs.occurred_at;

    GET DIAGNOSTICS v_added = ROW_COUNT;
    v_count := v_count + v_added;
    RETURN v_count;
  END IF;

  -- Mobile / hybrid: walk punches and open/close segments
  FOR v_punch IN
    SELECT id, punch_type, occurred_at, pause_type, pause_counts_as_work
    FROM data.time_punches
    WHERE employee_id = p_employee_id
      AND occurred_at >= v_punch_from
      AND occurred_at < v_punch_to
    ORDER BY occurred_at ASC, id ASC
  LOOP
    IF v_open_kind IS NOT NULL THEN
      INSERT INTO data.time_activity_segments (
        tenant_id, employee_id, work_date, activity_kind,
        started_at, ended_at, site_id, source_punch_ids, flags_snapshot
      ) VALUES (
        p_tenant_id, p_employee_id, p_work_date, v_open_kind,
        v_open_start, v_punch.occurred_at, v_emp.site_id, v_open_punches,
        jsonb_build_object('work_profile', v_profile, 'classifier', 'mobile_walk')
      );
      v_count := v_count + 1;
      v_open_kind := NULL;
      v_open_punches := '{}';
    END IF;

    CASE v_punch.punch_type
      WHEN 'day_start' THEN
        v_open_kind := 'TRAVEL';
        v_open_start := v_punch.occurred_at;
        v_open_punches := ARRAY[v_punch.id];
      WHEN 'travel_start' THEN
        v_open_kind := 'TRAVEL';
        v_open_start := v_punch.occurred_at;
        v_open_punches := ARRAY[v_punch.id];
      WHEN 'in' THEN
        v_open_kind := 'WORK';
        v_open_start := v_punch.occurred_at;
        v_open_punches := ARRAY[v_punch.id];
      WHEN 'break_start' THEN
        v_break_kind := CASE WHEN COALESCE(v_punch.pause_counts_as_work, false)
          THEN 'BREAK_PAID' ELSE 'BREAK_UNPAID' END;
        v_open_kind := v_break_kind;
        v_open_start := v_punch.occurred_at;
        v_open_punches := ARRAY[v_punch.id];
      WHEN 'out' THEN
        v_open_kind := 'TRAVEL';
        v_open_start := v_punch.occurred_at;
        v_open_punches := ARRAY[v_punch.id];
      WHEN 'break_end' THEN
        v_open_kind := 'WORK';
        v_open_start := v_punch.occurred_at;
        v_open_punches := ARRAY[v_punch.id];
      WHEN 'travel_end', 'day_end' THEN
        NULL;
      ELSE
        NULL;
    END CASE;
  END LOOP;

  IF v_open_kind IS NOT NULL THEN
    INSERT INTO data.time_activity_segments (
      tenant_id, employee_id, work_date, activity_kind,
      started_at, ended_at, site_id, source_punch_ids, flags_snapshot
    ) VALUES (
      p_tenant_id, p_employee_id, p_work_date, v_open_kind,
      v_open_start, NULL, v_emp.site_id, v_open_punches,
      jsonb_build_object('work_profile', v_profile, 'classifier', 'mobile_walk', 'open_at_eod', true)
    );
    v_count := v_count + 1;
  END IF;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION data.classify_activity_segments(uuid, date, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.classify_activity_segments(uuid, date, uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 6. API: list segments + record_time_punch validation
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.time_activity_segments AS
SELECT
  id,
  tenant_id,
  employee_id,
  work_date,
  activity_kind,
  started_at,
  ended_at,
  site_id,
  work_log_id,
  work_location_ref,
  expense_ref_id,
  source_punch_ids,
  flags_snapshot,
  created_at
FROM data.time_activity_segments
WHERE tenant_id = data.active_tenant_id();

GRANT SELECT ON api.time_activity_segments TO authenticated;

CREATE OR REPLACE FUNCTION api.get_activity_segments(
  p_employee_id uuid,
  p_work_date   date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp record;
BEGIN
  SELECT e.tenant_id, e.site_id INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.tenant_id = data.active_tenant_id();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT (
    data.jwt_has_permission(v_emp.tenant_id, 'attendance.view', v_emp.site_id)
    OR data.jwt_has_permission(v_emp.tenant_id, 'attendance.view_all', NULL)
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(
      jsonb_build_object(
        'id', s.id,
        'activity_kind', s.activity_kind,
        'started_at', s.started_at,
        'ended_at', s.ended_at,
        'source_punch_ids', s.source_punch_ids,
        'flags_snapshot', s.flags_snapshot
      )
      ORDER BY s.started_at
    )
    FROM data.time_activity_segments s
    WHERE s.employee_id = p_employee_id AND s.work_date = p_work_date
  ), '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_activity_segments(uuid, date) TO authenticated, service_role;

-- Patch record_time_punch: validate extended types via profile
CREATE OR REPLACE FUNCTION api.record_time_punch(
  p_employee_id          uuid,
  p_client_op_id         uuid,
  p_punch_type           text,
  p_occurred_at          timestamptz DEFAULT now(),
  p_geo                  jsonb       DEFAULT NULL,
  p_location_perm        text        DEFAULT 'notrequired',
  p_notes                text        DEFAULT NULL,
  p_source               text        DEFAULT 'mobile',
  p_device_id            uuid        DEFAULT NULL,
  p_pause_type           text        DEFAULT NULL,
  p_pause_counts_as_work boolean     DEFAULT NULL,
  p_is_remote            boolean     DEFAULT false,
  p_geo_consent          boolean     DEFAULT false,
  p_geo_error            text        DEFAULT NULL,
  p_device_info          jsonb       DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, pgmq
AS $$
DECLARE
  v_employee       record;
  v_punch_id       uuid;
  v_anomalies      text[];
  v_offset_ms      bigint;
  v_threshold_ms   bigint;
  v_settings       jsonb;
  v_last_punch     record;
  v_pause_cfg      record;
  v_counts_work    boolean;
  v_geo_lat        numeric(10,7);
  v_geo_lng        numeric(10,7);
  v_geo_acc        real;
  v_geo_alt        real;
  v_geo_spd        real;
  v_work_date      date;
  v_work_profile   text;
BEGIN
  SELECT e.tenant_id, e.site_id, e.user_id, e.status
    INTO v_employee
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND (data.active_tenant_id() IS NULL OR e.tenant_id = data.active_tenant_id());

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_employee.status != 'active' THEN
    RAISE EXCEPTION 'employee_not_active: %', p_employee_id USING ERRCODE = 'check_violation';
  END IF;
  IF v_employee.site_id IS NULL THEN
    RAISE EXCEPTION 'employee_no_site' USING ERRCODE = 'check_violation';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF v_employee.user_id IS DISTINCT FROM auth.uid() THEN
      IF NOT data.jwt_has_permission(v_employee.tenant_id, 'attendance.adjust', v_employee.site_id) THEN
        RAISE EXCEPTION 'insufficient_privilege: cannot punch for another employee' USING ERRCODE = 'insufficient_privilege';
      END IF;
    ELSE
      IF NOT data.jwt_has_permission(v_employee.tenant_id, 'attendance.punch_own', v_employee.site_id) THEN
        RAISE EXCEPTION 'insufficient_privilege: attendance.punch_own required' USING ERRCODE = 'insufficient_privilege';
      END IF;
    END IF;
  ELSIF p_source IS DISTINCT FROM 'portal' THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT id INTO v_punch_id FROM data.time_punches
  WHERE tenant_id = v_employee.tenant_id AND client_op_id = p_client_op_id;

  IF v_punch_id IS NOT NULL THEN
    RETURN jsonb_build_object('punch_id', v_punch_id, 'status', 'duplicate', 'anomaly_codes', ARRAY[]::text[]);
  END IF;

  v_work_date := (p_occurred_at AT TIME ZONE 'Europe/Madrid')::date;

  PERFORM data.validate_time_punch_sequence(p_employee_id, v_work_date, p_punch_type);

  v_counts_work := p_pause_counts_as_work;
  IF p_punch_type IN ('break_start', 'break_end') AND p_pause_type IS NOT NULL THEN
    SELECT counts_as_work INTO v_pause_cfg
    FROM data.tenant_pause_configs
    WHERE tenant_id = v_employee.tenant_id AND key = p_pause_type AND is_active = true;
    IF FOUND THEN
      v_counts_work := v_pause_cfg.counts_as_work;
    END IF;
  END IF;

  IF auth.uid() IS NULL AND p_source = 'portal' THEN
    v_settings := data.merge_effective_settings_for_service(v_employee.tenant_id, v_employee.site_id);
  ELSE
    SELECT api.get_effective_settings(
      p_site_id => v_employee.site_id, p_user_id => auth.uid(), p_tenant_id => v_employee.tenant_id
    ) INTO v_settings;
  END IF;

  IF NOT data.resolve_attendance_geo_enabled(p_employee_id) THEN
    p_geo := NULL;
    p_location_perm := 'notrequired';
    p_geo_consent := false;
    p_geo_error := NULL;
  END IF;

  v_anomalies := data.validate_geo_payload(p_geo, p_location_perm);

  v_threshold_ms := COALESCE((v_settings->>'attendance_clock_offset_threshold_ms')::bigint, 300000);
  v_offset_ms := ABS(EXTRACT(EPOCH FROM (p_occurred_at - now())) * 1000)::bigint;
  IF v_offset_ms > v_threshold_ms AND NOT ('CLOCK_SKEW' = ANY(v_anomalies)) THEN
    v_anomalies := array_append(v_anomalies, 'CLOCK_SKEW');
  END IF;

  v_work_profile := COALESCE(
    (data.resolve_attendance_record_policy(p_employee_id, v_work_date)->>'work_profile'),
    'fixed_site'
  );
  IF NOT data.is_mobile_work_profile(v_work_profile)
     AND p_punch_type IN ('day_start', 'day_end', 'travel_start', 'travel_end') THEN
    v_anomalies := array_append(v_anomalies, 'WORK_PROFILE_MISMATCH');
  END IF;

  v_geo_lat := COALESCE((p_geo->>'lat')::numeric, (p_geo->>'latitude')::numeric);
  v_geo_lng := COALESCE((p_geo->>'lng')::numeric, (p_geo->>'longitude')::numeric);
  v_geo_acc := COALESCE((p_geo->>'accuracy')::real, (p_geo->>'accuracy_m')::real);
  v_geo_alt := (p_geo->>'altitude')::real;
  v_geo_spd := (p_geo->>'speed')::real;

  INSERT INTO data.time_punches (
    tenant_id, site_id, employee_id, device_id, client_op_id,
    punch_type, occurred_at, received_at,
    geo, location_permission, anomaly_codes, source, notes,
    pause_type, pause_counts_as_work, is_remote,
    geo_lat, geo_lng, geo_accuracy_m, geo_altitude_m, geo_speed_ms,
    geo_consent, geo_error, device_info
  ) VALUES (
    v_employee.tenant_id, v_employee.site_id, p_employee_id, p_device_id, p_client_op_id,
    p_punch_type, p_occurred_at, now(),
    p_geo, p_location_perm, v_anomalies, p_source, p_notes,
    p_pause_type, v_counts_work, COALESCE(p_is_remote, false),
    v_geo_lat, v_geo_lng, v_geo_acc, v_geo_alt, v_geo_spd,
    COALESCE(p_geo_consent, false), p_geo_error, p_device_info
  )
  RETURNING id INTO v_punch_id;

  PERFORM pgmq.send('attendance_recompute_queue', jsonb_build_object(
    'task', 'recompute_attendance_day',
    'tenant_id', v_employee.tenant_id,
    'employee_id', p_employee_id,
    'work_date', v_work_date,
    'idempotency_key', 'recompute-' || p_employee_id::text || '-' || v_work_date::text || '-' || v_punch_id::text
  ));

  BEGIN
    PERFORM pgmq.send('workflow_trigger_queue', jsonb_build_object(
      'trigger_event', CASE p_punch_type
        WHEN 'in' THEN 'PUNCH_IN'
        WHEN 'out' THEN 'PUNCH_OUT'
        WHEN 'break_start' THEN 'PAUSE_START'
        WHEN 'break_end' THEN 'PAUSE_END'
        WHEN 'day_start' THEN 'DAY_START'
        WHEN 'day_end' THEN 'DAY_END'
        ELSE 'PUNCH_OTHER'
      END,
      'tenant_id', v_employee.tenant_id,
      'trigger_entity_type', 'employee',
      'trigger_entity_id', p_employee_id,
      'payload', jsonb_build_object(
        'punch_id', v_punch_id, 'punch_type', p_punch_type,
        'pause_type', p_pause_type, 'occurred_at', p_occurred_at, 'is_remote', p_is_remote
      )
    ));
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object('punch_id', v_punch_id, 'status', 'created', 'anomaly_codes', v_anomalies);
END;
$$;

GRANT EXECUTE ON FUNCTION api.record_time_punch(
  uuid, uuid, text, timestamptz, jsonb, text, text, text, uuid,
  text, boolean, boolean, boolean, text, jsonb
) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 7. Patch recompute_attendance_worker — classify + mobile day anomalies
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.recompute_attendance_worker(
  p_employee_id  uuid,
  p_work_date    date,
  p_tenant_id    uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp            record;
  v_tz             text;
  v_profile        text;
  v_punch_from     timestamptz;
  v_punch_to       timestamptz;
  v_day_start      timestamptz;
  v_day_end        timestamptz;
  v_travel_start   timestamptz;
  v_travel_end     timestamptz;
  v_segment_count  int;
  v_anomalies      text[];
  v_resolve          jsonb;
  v_day_type         text;
  v_expected_min     int;
  v_spans_midnight   boolean;
  v_shift_start      time;
  v_shift_end        time;
  v_first_in_at      timestamptz;
  v_first_in_id      uuid;
  v_last_out_at      timestamptz;
  v_last_out_id      uuid;
  v_gross_min        int;
  v_break_min        int  := 0;
  v_net_min          int;
  v_punch_count      int;
  v_in_count         int;
  v_out_count        int;
  v_bs_count         int;
  v_be_count         int;
  v_entry_status     text;
  v_locked_at        timestamptz;
  v_existing_status  text;
  v_absence_min      int  := 0;
  v_open_pause       record;
  v_max_pause_min    int;
  v_summary_day_type text;
BEGIN
  SELECT e.tenant_id, e.site_id INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.tenant_id = p_tenant_id;

  IF NOT FOUND OR v_emp.site_id IS NULL THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'employee_not_found_or_no_site');
  END IF;

  v_tz := COALESCE(data.get_site_timezone(v_emp.site_id, p_tenant_id), 'Europe/Madrid');
  v_punch_from := p_work_date AT TIME ZONE v_tz;
  v_punch_to   := (p_work_date + 1) AT TIME ZONE v_tz;

  v_profile := COALESCE(
    (data.resolve_attendance_record_policy(p_employee_id, p_work_date)->>'work_profile'),
    'fixed_site'
  );

  v_resolve        := api.resolve_work_day(p_employee_id, p_work_date);
    v_day_type       := COALESCE(v_resolve->>'day_type', 'unknown');
    v_expected_min   := COALESCE((v_resolve->>'expected_minutes')::int, 0);
    v_spans_midnight := COALESCE((v_resolve->>'spans_midnight')::boolean, false);
    v_summary_day_type := CASE v_day_type
      WHEN 'working' THEN 'work'
      WHEN 'half_holiday' THEN 'holiday'
      WHEN 'non_working' THEN 'weekend'
      ELSE v_day_type
    END;

    IF v_resolve->>'shift_start_time' IS NOT NULL THEN
      v_shift_start := (v_resolve->>'shift_start_time')::time;
      v_shift_end   := (v_resolve->>'shift_end_time')::time;
    END IF;

    IF v_day_type = 'absence' THEN
      v_absence_min := COALESCE(
        ((v_resolve->>'absence_hours_per_day')::numeric * 60)::int,
        v_expected_min
      );

      SELECT payroll_locked_at INTO v_locked_at
      FROM data.time_daily_summaries
      WHERE employee_id = p_employee_id AND work_date = p_work_date;

      IF v_locked_at IS NOT NULL THEN
        RETURN jsonb_build_object('skipped', true, 'reason', 'payroll_locked');
      END IF;

      INSERT INTO data.time_daily_summaries (
        tenant_id, site_id, employee_id, work_date,
        day_type, expected_minutes, worked_minutes, break_minutes,
        overtime_minutes, absence_minutes, punch_count,
        anomaly_codes, needs_review, recomputed_at, updated_at
      ) VALUES (
        p_tenant_id, v_emp.site_id, p_employee_id, p_work_date,
        'absence', v_expected_min, 0, 0,
        0, v_absence_min, 0,
        '{}', false, now(), now()
      )
      ON CONFLICT (employee_id, work_date) DO UPDATE SET
        day_type = 'absence', expected_minutes = v_expected_min,
        worked_minutes = 0, absence_minutes = v_absence_min,
        punch_count = 0, anomaly_codes = '{}', needs_review = false,
        recomputed_at = now(), updated_at = now()
      WHERE data.time_daily_summaries.status = 'draft';

      PERFORM data.classify_activity_segments(p_employee_id, p_work_date, p_tenant_id);

      RETURN jsonb_build_object(
        'success', true, 'day_type', 'absence',
        'employee_id', p_employee_id, 'work_date', p_work_date,
        'absence_minutes', v_absence_min
      );
    END IF;

    IF v_spans_midnight AND v_shift_start IS NOT NULL THEN
      v_punch_from := (p_work_date + v_shift_start) AT TIME ZONE v_tz;
      v_punch_to   := ((p_work_date + 1) + v_shift_end) AT TIME ZONE v_tz;
    END IF;

    SELECT
      COUNT(*) AS total,
      COUNT(*) FILTER (WHERE punch_type = 'in') AS in_c,
      COUNT(*) FILTER (WHERE punch_type = 'out') AS out_c,
      COUNT(*) FILTER (WHERE punch_type = 'break_start') AS bs_c,
      COUNT(*) FILTER (WHERE punch_type = 'break_end') AS be_c,
      MIN(occurred_at) FILTER (WHERE punch_type = 'in') AS first_in,
      MAX(occurred_at) FILTER (WHERE punch_type = 'out') AS last_out
    INTO v_punch_count, v_in_count, v_out_count, v_bs_count, v_be_count, v_first_in_at, v_last_out_at
    FROM data.time_punches
    WHERE employee_id = p_employee_id
      AND occurred_at >= v_punch_from AND occurred_at < v_punch_to;

    v_anomalies := '{}';

    IF v_punch_count = 0 AND v_day_type IN ('holiday', 'half_holiday', 'non_working') THEN
      RETURN jsonb_build_object(
        'skipped', true, 'reason', 'no_punches_on_' || v_day_type,
        'day_type', v_day_type
      );
    END IF;

    SELECT id INTO v_first_in_id FROM data.time_punches
    WHERE employee_id = p_employee_id AND punch_type = 'in'
      AND occurred_at >= v_punch_from AND occurred_at < v_punch_to
    ORDER BY occurred_at ASC LIMIT 1;

    SELECT id INTO v_last_out_id FROM data.time_punches
    WHERE employee_id = p_employee_id AND punch_type = 'out'
      AND occurred_at >= v_punch_from AND occurred_at < v_punch_to
    ORDER BY occurred_at DESC LIMIT 1;

    SELECT ARRAY(
      SELECT DISTINCT unnest_a FROM data.time_punches tp,
             LATERAL unnest(tp.anomaly_codes) AS unnest_a
      WHERE tp.employee_id = p_employee_id
        AND tp.occurred_at >= v_punch_from AND tp.occurred_at < v_punch_to
        AND cardinality(tp.anomaly_codes) > 0
    ) INTO v_anomalies;
    v_anomalies := COALESCE(v_anomalies, '{}');

    IF v_punch_count > 0 AND v_in_count = 0 THEN
      v_anomalies := array_append(v_anomalies, 'MISSING_IN');
    END IF;
    IF v_in_count > v_out_count AND v_out_count > 0 THEN
      v_anomalies := array_append(v_anomalies, 'EXTRA_IN');
    END IF;
    IF v_out_count > v_in_count THEN
      v_anomalies := array_append(v_anomalies, 'EXTRA_OUT');
    END IF;
    IF v_bs_count != v_be_count THEN
      v_anomalies := array_append(v_anomalies, 'BREAK_MISMATCH');
    END IF;

    -- Mobile day/travel open checks (G1b)
    IF data.is_mobile_work_profile(v_profile) THEN
      SELECT MIN(occurred_at) FILTER (WHERE punch_type = 'day_start'),
             MAX(occurred_at) FILTER (WHERE punch_type = 'day_end'),
             MAX(occurred_at) FILTER (WHERE punch_type = 'travel_start'),
             MAX(occurred_at) FILTER (WHERE punch_type = 'travel_end')
      INTO v_day_start, v_day_end, v_travel_start, v_travel_end
      FROM data.time_punches
      WHERE employee_id = p_employee_id
        AND occurred_at >= v_punch_from AND occurred_at < v_punch_to;

      IF v_day_start IS NOT NULL AND v_day_end IS NULL THEN
        v_anomalies := array_append(v_anomalies, 'DAY_NOT_CLOSED');
      END IF;
      IF v_travel_start IS NOT NULL
         AND (v_travel_end IS NULL OR v_travel_end < v_travel_start)
         AND v_day_end IS NULL THEN
        v_anomalies := array_append(v_anomalies, 'TRAVEL_NOT_CLOSED');
      END IF;
    END IF;

    IF v_bs_count > v_be_count THEN
      SELECT tp.occurred_at, tp.pause_type INTO v_open_pause
      FROM data.time_punches tp
      WHERE tp.employee_id = p_employee_id AND tp.punch_type = 'break_start'
        AND tp.occurred_at >= v_punch_from AND tp.occurred_at < v_punch_to
      ORDER BY tp.occurred_at DESC LIMIT 1;

      SELECT COALESCE(tpc.max_duration_minutes, 240) INTO v_max_pause_min
      FROM data.tenant_pause_configs tpc
      WHERE tpc.tenant_id = p_tenant_id AND tpc.key = COALESCE(v_open_pause.pause_type, 'rest')
      LIMIT 1;
      v_max_pause_min := COALESCE(v_max_pause_min, 240);

      IF EXTRACT(EPOCH FROM (now() - v_open_pause.occurred_at)) / 60 > v_max_pause_min THEN
        v_anomalies := array_append(v_anomalies, 'PAUSE_NOT_CLOSED');
      END IF;
    END IF;

    IF v_first_in_at IS NOT NULL AND v_last_out_at IS NOT NULL THEN
      v_gross_min := ROUND(EXTRACT(EPOCH FROM (v_last_out_at - v_first_in_at)) / 60)::int;

      SELECT COALESCE(ROUND(SUM(
        EXTRACT(EPOCH FROM (be.occurred_at - bs.occurred_at)) / 60
      ))::int, 0)
      INTO v_break_min
      FROM (
        SELECT occurred_at, pause_counts_as_work, ROW_NUMBER() OVER (ORDER BY occurred_at) AS rn
        FROM data.time_punches
        WHERE employee_id = p_employee_id AND punch_type = 'break_start'
          AND occurred_at >= v_punch_from AND occurred_at < v_punch_to
      ) bs
      JOIN (
        SELECT occurred_at, ROW_NUMBER() OVER (ORDER BY occurred_at) AS rn
        FROM data.time_punches
        WHERE employee_id = p_employee_id AND punch_type = 'break_end'
          AND occurred_at >= v_punch_from AND occurred_at < v_punch_to
      ) be ON bs.rn = be.rn
      WHERE be.occurred_at > bs.occurred_at
        AND COALESCE(bs.pause_counts_as_work, false) = false;

      v_net_min := GREATEST(0, v_gross_min - v_break_min);
      v_entry_status := 'closed';
    ELSIF v_first_in_at IS NOT NULL THEN
      v_gross_min := NULL; v_net_min := NULL; v_entry_status := 'open';
    ELSE
      v_gross_min := NULL; v_net_min := NULL;
      v_entry_status := CASE WHEN v_punch_count = 0 THEN 'missing' ELSE 'open' END;
    END IF;

    SELECT payroll_locked_at INTO v_locked_at
    FROM data.time_daily_summaries
    WHERE employee_id = p_employee_id AND work_date = p_work_date;

    IF v_locked_at IS NOT NULL THEN
      RETURN jsonb_build_object('skipped', true, 'reason', 'payroll_locked',
        'employee_id', p_employee_id, 'work_date', p_work_date);
    END IF;

    SELECT status INTO v_existing_status
    FROM data.time_entries
    WHERE employee_id = p_employee_id AND work_date = p_work_date;

    IF v_existing_status = 'adjusted' THEN
      UPDATE data.time_daily_summaries SET
        day_type = v_summary_day_type, expected_minutes = v_expected_min,
        punch_count = v_punch_count, anomaly_codes = v_anomalies,
        needs_review = (cardinality(v_anomalies) > 0),
        recomputed_at = now(), updated_at = now()
      WHERE employee_id = p_employee_id AND work_date = p_work_date AND status = 'draft';

      v_segment_count := data.classify_activity_segments(p_employee_id, p_work_date, p_tenant_id);

      RETURN jsonb_build_object(
        'skipped_entry', true, 'reason', 'entry_adjusted',
        'employee_id', p_employee_id, 'work_date', p_work_date,
        'segment_count', v_segment_count
      );
    END IF;

    INSERT INTO data.time_entries (
      tenant_id, site_id, employee_id, work_date,
      starts_at, ends_at, punch_in_id, punch_out_id,
      gross_minutes, break_minutes, net_minutes,
      regular_minutes, overtime_minutes, status, updated_at
    ) VALUES (
      v_emp.tenant_id, v_emp.site_id, p_employee_id, p_work_date,
      v_first_in_at, v_last_out_at, v_first_in_id, v_last_out_id,
      v_gross_min, v_break_min, v_net_min,
      v_net_min, 0, v_entry_status, now()
    )
    ON CONFLICT (employee_id, work_date) DO UPDATE SET
      starts_at = EXCLUDED.starts_at, ends_at = EXCLUDED.ends_at,
      punch_in_id = EXCLUDED.punch_in_id, punch_out_id = EXCLUDED.punch_out_id,
      gross_minutes = EXCLUDED.gross_minutes, break_minutes = EXCLUDED.break_minutes,
      net_minutes = EXCLUDED.net_minutes, regular_minutes = EXCLUDED.regular_minutes,
      overtime_minutes = EXCLUDED.overtime_minutes, status = EXCLUDED.status,
      updated_at = EXCLUDED.updated_at
    WHERE data.time_entries.status != 'adjusted';

    INSERT INTO data.time_daily_summaries (
      tenant_id, site_id, employee_id, work_date,
      day_type, expected_minutes, worked_minutes, break_minutes,
      overtime_minutes, absence_minutes, punch_count,
      anomaly_codes, needs_review, recomputed_at, updated_at
    ) VALUES (
      v_emp.tenant_id, v_emp.site_id, p_employee_id, p_work_date,
      v_summary_day_type, v_expected_min,
      COALESCE(v_net_min, 0), v_break_min,
      0, 0, v_punch_count,
      v_anomalies,
      (cardinality(v_anomalies) > 0 OR v_entry_status = 'missing'),
      now(), now()
    )
    ON CONFLICT (employee_id, work_date) DO UPDATE SET
      day_type = EXCLUDED.day_type, expected_minutes = EXCLUDED.expected_minutes,
      worked_minutes = EXCLUDED.worked_minutes, break_minutes = EXCLUDED.break_minutes,
      punch_count = EXCLUDED.punch_count, anomaly_codes = EXCLUDED.anomaly_codes,
      needs_review = EXCLUDED.needs_review, recomputed_at = EXCLUDED.recomputed_at,
      updated_at = EXCLUDED.updated_at
    WHERE data.time_daily_summaries.status = 'draft';

    BEGIN
      PERFORM data.refresh_today_site_status_mv();
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    v_segment_count := data.classify_activity_segments(p_employee_id, p_work_date, p_tenant_id);

    RETURN jsonb_build_object(
      'success', true,
      'employee_id', p_employee_id,
      'work_date', p_work_date,
      'day_type', v_day_type,
      'expected_minutes', v_expected_min,
      'punch_count', v_punch_count,
      'net_minutes', v_net_min,
      'entry_status', v_entry_status,
      'anomaly_codes', v_anomalies,
      'segment_count', v_segment_count,
      'work_profile', v_profile
    );
END;
$$;

REVOKE ALL ON FUNCTION api.recompute_attendance_worker(uuid, date, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.recompute_attendance_worker(uuid, date, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION api.recompute_attendance_worker(uuid, date, uuid) TO service_role;

NOTIFY pgrst, 'reload schema';
