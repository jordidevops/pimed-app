-- EX-02.1b / ST-10b: Cascada punch_only_at_stations
-- empleat → grup calendari → site → tenant → false

ALTER TABLE data.employees
  ADD COLUMN IF NOT EXISTS punch_only_at_stations boolean NULL;

COMMENT ON COLUMN data.employees.punch_only_at_stations IS
  'ST-10b: null = heretar; true = només estació; false = permet portal/mòbil.';

ALTER TABLE data.calendar_groups
  ADD COLUMN IF NOT EXISTS punch_only_at_stations boolean NULL;

COMMENT ON COLUMN data.calendar_groups.punch_only_at_stations IS
  'ST-10b: null = heretar; override massiu per empleats del grup sense valor propi.';

-- Resolver per empleat (cascada completa)
CREATE OR REPLACE FUNCTION data.resolve_punch_only_at_stations(p_employee_id uuid)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp record;
  v_group_enabled boolean;
BEGIN
  SELECT
    e.punch_only_at_stations,
    e.calendar_group_id,
    e.site_id,
    e.tenant_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF v_emp.punch_only_at_stations IS NOT NULL THEN
    RETURN v_emp.punch_only_at_stations;
  END IF;

  IF v_emp.calendar_group_id IS NOT NULL THEN
    SELECT cg.punch_only_at_stations
      INTO v_group_enabled
    FROM data.calendar_groups cg
    WHERE cg.id = v_emp.calendar_group_id;

    IF v_group_enabled IS NOT NULL THEN
      RETURN v_group_enabled;
    END IF;
  END IF;

  RETURN data.is_punch_only_at_stations(v_emp.tenant_id, v_emp.site_id);
END;
$$;

REVOKE ALL ON FUNCTION data.resolve_punch_only_at_stations(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.resolve_punch_only_at_stations(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION data.resolve_punch_only_at_stations(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION api.get_punch_only_at_stations(p_employee_id uuid)
RETURNS boolean
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
  SELECT data.resolve_punch_only_at_stations(p_employee_id);
$$;

REVOKE ALL ON FUNCTION api.get_punch_only_at_stations(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_punch_only_at_stations(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_punch_only_at_stations(uuid) TO service_role;

-- Assert: per empleat (no només tenant/site)
DROP FUNCTION IF EXISTS data.assert_portal_mobile_punch_allowed(uuid, uuid, text);

CREATE OR REPLACE FUNCTION data.assert_portal_mobile_punch_allowed(
  p_employee_id uuid,
  p_source      text
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_emp record;
BEGIN
  IF p_source NOT IN ('portal', 'mobile') THEN
    RETURN;
  END IF;

  IF NOT data.resolve_punch_only_at_stations(p_employee_id) THEN
    RETURN;
  END IF;

  SELECT e.tenant_id, e.site_id
    INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF p_source = 'mobile'
     AND auth.uid() IS NOT NULL
     AND v_emp.tenant_id IS NOT NULL
     AND data.jwt_has_permission(v_emp.tenant_id, 'attendance.adjust', v_emp.site_id) THEN
    RETURN;
  END IF;

  RAISE EXCEPTION 'punch_only_at_stations'
    USING ERRCODE = 'check_violation';
END;
$$;

REVOKE ALL ON FUNCTION data.assert_portal_mobile_punch_allowed(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.assert_portal_mobile_punch_allowed(uuid, text) TO service_role;

-- record_time_punch: call employee-scoped assert
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
  p_device_info          jsonb       DEFAULT NULL,
  p_location_id          uuid        DEFAULT NULL,
  p_location_name_snapshot text      DEFAULT NULL,
  p_device_name_snapshot text        DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, pgmq
AS $$
DECLARE
  v_employee       record;
  v_punch_id       uuid;
  v_anomalies      text[] ;
  v_offset_ms      bigint;
  v_threshold_ms   bigint;
  v_settings       jsonb;
  v_pause_cfg      record;
  v_counts_work    boolean;
  v_geo_lat        numeric(10,7);
  v_geo_lng        numeric(10,7);
  v_geo_acc        real;
  v_geo_alt        real;
  v_geo_spd        real;
  v_work_date      date;
  v_work_profile   text;
  v_occurred_at    timestamptz := p_occurred_at;
  v_geo            jsonb := p_geo;
  v_location_perm  text := p_location_perm;
  v_geo_consent    boolean := COALESCE(p_geo_consent, false);
  v_geo_error      text := p_geo_error;
  v_day_state      text;
  v_expected_punch text;
  v_tz             text;
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

  PERFORM data.assert_portal_mobile_punch_allowed(p_employee_id, p_source);

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
  ELSIF p_source NOT IN ('portal', 'station', 'qr') THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_source IN ('station', 'qr') THEN
    v_occurred_at := now();
    v_geo := NULL;
    v_location_perm := 'notrequired';
    v_geo_consent := false;
    v_geo_error := NULL;
    IF p_device_id IS NULL THEN
      RAISE EXCEPTION 'station_punch_requires_device' USING ERRCODE = 'check_violation';
    END IF;
    IF p_punch_type NOT IN ('in', 'out') THEN
      RAISE EXCEPTION 'station_punch_type_not_allowed' USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  SELECT id INTO v_punch_id FROM data.time_punches
  WHERE tenant_id = v_employee.tenant_id AND client_op_id = p_client_op_id;

  IF v_punch_id IS NOT NULL THEN
    RETURN jsonb_build_object('punch_id', v_punch_id, 'status', 'duplicate', 'anomaly_codes', ARRAY[]::text[]);
  END IF;

  v_tz := data.get_site_timezone(v_employee.site_id, v_employee.tenant_id);
  v_work_date := (v_occurred_at AT TIME ZONE v_tz)::date;

  IF p_source IN ('station', 'qr') THEN
    v_day_state := data.compute_employee_punch_day_state(p_employee_id, v_work_date);
    v_expected_punch := data.station_kiosk_next_punch(v_day_state);

    IF v_expected_punch IS NULL THEN
      RAISE EXCEPTION 'station_punch_blocked: state % requires portal or manager', v_day_state
        USING ERRCODE = 'check_violation';
    END IF;

    IF p_punch_type IS DISTINCT FROM v_expected_punch THEN
      RAISE EXCEPTION 'station_wrong_punch_type: expected % got %', v_expected_punch, p_punch_type
        USING ERRCODE = 'check_violation';
    END IF;

    PERFORM data.validate_time_punch_sequence(
      p_employee_id,
      v_work_date,
      p_punch_type,
      'fixed_site',
      data.default_attendance_record_policy('fixed_site')
    );
  ELSE
    PERFORM data.validate_time_punch_sequence(p_employee_id, v_work_date, p_punch_type);
  END IF;

  v_counts_work := p_pause_counts_as_work;
  IF p_punch_type IN ('break_start', 'break_end') AND p_pause_type IS NOT NULL THEN
    SELECT counts_as_work INTO v_pause_cfg
    FROM data.tenant_pause_configs
    WHERE tenant_id = v_employee.tenant_id AND key = p_pause_type AND is_active = true;
    IF FOUND THEN
      v_counts_work := v_pause_cfg.counts_as_work;
    END IF;
  END IF;

  IF auth.uid() IS NULL AND p_source IN ('portal', 'station', 'qr') THEN
    v_settings := data.merge_effective_settings_for_service(v_employee.tenant_id, v_employee.site_id);
  ELSE
    SELECT api.get_effective_settings(
      p_site_id => v_employee.site_id, p_user_id => auth.uid(), p_tenant_id => v_employee.tenant_id
    ) INTO v_settings;
  END IF;

  IF p_source NOT IN ('station', 'qr') AND NOT data.resolve_attendance_geo_enabled(p_employee_id) THEN
    v_geo := NULL;
    v_location_perm := 'notrequired';
    v_geo_consent := false;
    v_geo_error := NULL;
  END IF;

  IF p_source IN ('station', 'qr') THEN
    v_anomalies := ARRAY[]::text[];
  ELSE
    v_anomalies := data.validate_geo_payload(v_geo, v_location_perm);
  END IF;

  v_threshold_ms := COALESCE((v_settings->>'attendance_clock_offset_threshold_ms')::bigint, 300000);
  IF p_source NOT IN ('station', 'qr') THEN
    v_offset_ms := ABS(EXTRACT(EPOCH FROM (v_occurred_at - now())) * 1000)::bigint;
    IF v_offset_ms > v_threshold_ms AND NOT ('CLOCK_SKEW' = ANY(v_anomalies)) THEN
      v_anomalies := array_append(v_anomalies, 'CLOCK_SKEW');
    END IF;
  END IF;

  v_work_profile := COALESCE(
    (data.resolve_attendance_record_policy(p_employee_id, v_work_date)->>'work_profile'),
    'fixed_site'
  );
  IF NOT data.is_mobile_work_profile(v_work_profile)
     AND p_punch_type IN ('day_start', 'day_end', 'travel_start', 'travel_end') THEN
    v_anomalies := array_append(v_anomalies, 'WORK_PROFILE_MISMATCH');
  END IF;

  v_geo_lat := CASE WHEN p_source IN ('station', 'qr') THEN NULL
    ELSE COALESCE((v_geo->>'lat')::numeric, (v_geo->>'latitude')::numeric) END;
  v_geo_lng := CASE WHEN p_source IN ('station', 'qr') THEN NULL
    ELSE COALESCE((v_geo->>'lng')::numeric, (v_geo->>'longitude')::numeric) END;
  v_geo_acc := CASE WHEN p_source IN ('station', 'qr') THEN NULL
    ELSE COALESCE((v_geo->>'accuracy')::real, (v_geo->>'accuracy_m')::real) END;
  v_geo_alt := CASE WHEN p_source IN ('station', 'qr') THEN NULL ELSE (v_geo->>'altitude')::real END;
  v_geo_spd := CASE WHEN p_source IN ('station', 'qr') THEN NULL ELSE (v_geo->>'speed')::real END;

  INSERT INTO data.time_punches (
    tenant_id, site_id, employee_id, device_id, location_id,
    client_op_id, punch_type, occurred_at, received_at,
    geo, location_permission, anomaly_codes, source, notes,
    pause_type, pause_counts_as_work, is_remote,
    geo_lat, geo_lng, geo_accuracy_m, geo_altitude_m, geo_speed_ms,
    geo_consent, geo_error, device_info,
    location_name_snapshot, device_name_snapshot
  ) VALUES (
    v_employee.tenant_id, v_employee.site_id, p_employee_id, p_device_id, p_location_id, p_client_op_id,
    p_punch_type, v_occurred_at, now(),
    v_geo, v_location_perm, v_anomalies, p_source, p_notes,
    p_pause_type, v_counts_work, COALESCE(p_is_remote, false),
    v_geo_lat, v_geo_lng, v_geo_acc, v_geo_alt, v_geo_spd,
    v_geo_consent, v_geo_error, p_device_info,
    p_location_name_snapshot, p_device_name_snapshot
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
        'pause_type', p_pause_type, 'occurred_at', v_occurred_at, 'is_remote', p_is_remote,
        'location_id', p_location_id, 'device_id', p_device_id
      )
    ));
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object('punch_id', v_punch_id, 'status', 'created', 'anomaly_codes', v_anomalies);
END;
$$;

-- Portal today: valor resolt per empleat
CREATE OR REPLACE FUNCTION api.employee_portal_get_today(
  p_employee_id uuid,
  p_tenant_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp record;
  v_today date;
  v_punches jsonb;
  v_last record;
  v_status text;
  v_active_pause_type text;
  v_open_pause_since timestamptz;
  v_resolved jsonb;
  v_profile text;
  v_legacy boolean;
  v_day_state text := 'off';
  v_next_state text;
  v_punch record;
  v_tz text;
  v_punch_only boolean;
BEGIN
  SELECT e.id, e.tenant_id, e.site_id, e.status
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND e.tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  v_tz := data.get_site_timezone(v_emp.site_id, v_emp.tenant_id);
  v_today := (now() AT TIME ZONE v_tz)::date;
  v_punch_only := data.resolve_punch_only_at_stations(p_employee_id);

  SELECT data.resolve_attendance_record_policy(p_employee_id, v_today)
  INTO v_resolved;

  v_profile := COALESCE(v_resolved->>'work_profile', 'fixed_site');
  v_legacy := data.policy_legacy_in_out_only(v_resolved->'policy', v_profile);

  SELECT COALESCE(jsonb_agg(row_to_json(p)::jsonb ORDER BY p.occurred_at ASC, p.id ASC), '[]'::jsonb)
  INTO v_punches
  FROM (
    SELECT
      tp.id,
      tp.punch_type,
      tp.occurred_at,
      tp.received_at,
      tp.anomaly_codes,
      tp.source,
      tp.pause_type,
      tp.is_remote
    FROM data.time_punches tp
    WHERE tp.employee_id = p_employee_id
      AND (tp.occurred_at AT TIME ZONE v_tz)::date = v_today
    ORDER BY tp.occurred_at ASC, tp.id ASC
  ) p;

  FOR v_punch IN
    SELECT punch_type
    FROM data.time_punches
    WHERE employee_id = p_employee_id
      AND (occurred_at AT TIME ZONE v_tz)::date = v_today
    ORDER BY occurred_at ASC, id ASC
  LOOP
    v_next_state := data.punch_day_state_after(v_day_state, v_punch.punch_type);
    IF v_next_state IS NULL THEN
      v_status := 'unknown';
      EXIT;
    END IF;
    v_day_state := v_next_state;
  END LOOP;

  SELECT punch_type, occurred_at, pause_type
  INTO v_last
  FROM data.time_punches
  WHERE employee_id = p_employee_id
    AND (occurred_at AT TIME ZONE v_tz)::date = v_today
  ORDER BY occurred_at DESC, id DESC
  LIMIT 1;

  IF v_status IS NULL THEN
    v_status := CASE v_day_state
      WHEN 'off' THEN 'outside'
      WHEN 'day' THEN
        CASE
          WHEN data.is_mobile_work_profile(v_profile) AND NOT v_legacy THEN 'on_day'
          ELSE 'outside'
        END
      WHEN 'work' THEN 'working'
      WHEN 'break' THEN 'on_pause'
      WHEN 'travel' THEN 'traveling'
      ELSE 'unknown'
    END;
  END IF;

  v_active_pause_type := NULL;
  v_open_pause_since := NULL;

  IF v_status = 'on_pause' AND v_last.punch_type IS NOT NULL THEN
    v_active_pause_type := v_last.pause_type;
    v_open_pause_since := v_last.occurred_at;
  END IF;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'tenant_id', p_tenant_id,
    'work_date', v_today,
    'punches', v_punches,
    'last_punch_type', v_last.punch_type,
    'last_punch_at', v_last.occurred_at,
    'current_status', v_status,
    'active_pause_type', v_active_pause_type,
    'open_pause_since', v_open_pause_since,
    'work_profile', v_profile,
    'legacy_in_out_only', v_legacy,
    'day_state', v_day_state,
    'punch_only_at_stations', v_punch_only
  );
END;
$$;

-- Vistes API (list_calendar_groups dependeix de api.calendar_groups)
DROP FUNCTION IF EXISTS api.list_calendar_groups(uuid);
DROP VIEW IF EXISTS api.calendar_groups CASCADE;

CREATE VIEW api.calendar_groups
  WITH (security_invoker = true) AS
  SELECT
    id, tenant_id, site_id, name, color, description,
    is_active, sort_order,
    attendance_geo_enabled,
    punch_only_at_stations,
    created_at, updated_at
  FROM data.calendar_groups;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.calendar_groups TO authenticated;

CREATE OR REPLACE FUNCTION api.list_calendar_groups(
  p_site_id uuid DEFAULT NULL
)
RETURNS SETOF api.calendar_groups
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = api, data, public
AS $$
  SELECT
    id, tenant_id, site_id, name, color, description,
    is_active, sort_order, attendance_geo_enabled, punch_only_at_stations,
    created_at, updated_at
  FROM data.calendar_groups
  WHERE tenant_id = data.active_tenant_id()
    AND is_active = true
    AND (p_site_id IS NULL OR site_id IS NULL OR site_id = p_site_id)
  ORDER BY sort_order, name;
$$;

GRANT EXECUTE ON FUNCTION api.list_calendar_groups(uuid) TO authenticated;

DROP FUNCTION IF EXISTS api.upsert_calendar_group(text, text, text, uuid, boolean, integer, uuid, boolean);

CREATE OR REPLACE FUNCTION api.upsert_calendar_group(
  p_name                     text,
  p_color                    text    DEFAULT '#6366f1',
  p_description              text    DEFAULT NULL,
  p_site_id                  uuid    DEFAULT NULL,
  p_is_active                boolean DEFAULT true,
  p_sort_order               int     DEFAULT 0,
  p_id                       uuid    DEFAULT NULL,
  p_attendance_geo_enabled   boolean DEFAULT NULL,
  p_punch_only_at_stations   boolean DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = api, data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_id        uuid := COALESCE(p_id, gen_random_uuid());
BEGIN
  IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.manage required';
  END IF;

  INSERT INTO data.calendar_groups (
    id, tenant_id, site_id, name, color, description,
    is_active, sort_order, attendance_geo_enabled, punch_only_at_stations
  )
  VALUES (
    v_id, v_tenant_id, p_site_id, p_name, p_color, p_description,
    p_is_active, p_sort_order, p_attendance_geo_enabled, p_punch_only_at_stations
  )
  ON CONFLICT (id) DO UPDATE SET
    name                     = EXCLUDED.name,
    color                    = EXCLUDED.color,
    description              = EXCLUDED.description,
    site_id                  = EXCLUDED.site_id,
    is_active                = EXCLUDED.is_active,
    sort_order               = EXCLUDED.sort_order,
    attendance_geo_enabled   = EXCLUDED.attendance_geo_enabled,
    punch_only_at_stations   = EXCLUDED.punch_only_at_stations,
    updated_at               = now();

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_calendar_group(
  text, text, text, uuid, boolean, integer, uuid, boolean, boolean
) TO authenticated;

DROP VIEW IF EXISTS api.employees CASCADE;
CREATE VIEW api.employees AS
SELECT
  id, tenant_id, site_id, user_id, department_id,
  full_name, email, phone, document_id, job_title,
  status, starts_on, ends_on, weekly_hours, metadata,
  calendar_group_id,
  location_consent_given, location_consent_at, location_consent_version,
  attendance_geo_enabled,
  attendance_work_profile,
  punch_only_at_stations,
  created_at, updated_at
FROM data.employees;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.employees TO authenticated;

NOTIFY pgrst, 'reload schema';
