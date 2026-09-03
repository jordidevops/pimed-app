-- =============================================================================
-- EX-04.7 / ST-16 — Pauses contextuals a l'estació (break_start / break_end)
-- =============================================================================

-- Permet in/out/break_start/break_end segons estat del dia (kiosk)
CREATE OR REPLACE FUNCTION data.station_allows_punch_type(
  p_day_state  text,
  p_punch_type text
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE COALESCE(NULLIF(btrim(p_day_state), ''), 'off')
    WHEN 'off' THEN p_punch_type = 'in'
    WHEN 'day' THEN p_punch_type = 'in'
    WHEN 'work' THEN p_punch_type IN ('out', 'break_start')
    WHEN 'break' THEN p_punch_type = 'break_end'
    ELSE false
  END;
$$;

COMMENT ON FUNCTION data.station_allows_punch_type(text, text) IS
  'ST-16: validació contextual de punch_type a l''estació.';

REVOKE ALL ON FUNCTION data.station_allows_punch_type(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.station_allows_punch_type(text, text) TO service_role;

-- next_punch primari (CTA principal); pauses són accions addicionals en estat work/break
CREATE OR REPLACE FUNCTION data.station_kiosk_next_punch(p_day_state text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE COALESCE(NULLIF(btrim(p_day_state), ''), 'off')
    WHEN 'off' THEN 'in'
    WHEN 'day' THEN 'in'
    WHEN 'work' THEN 'out'
    WHEN 'break' THEN 'break_end'
    ELSE NULL
  END;
$$;

-- Configs de pausa actives del tenant de l'estació
CREATE OR REPLACE FUNCTION api.list_attendance_station_pause_configs(p_device_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_device record;
  v_rows jsonb;
BEGIN
  SELECT d.id, d.tenant_id, d.status, d.site_id, d.location_id
    INTO v_device
  FROM data.attendance_devices d
  WHERE d.id = p_device_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'device_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_device.status IS DISTINCT FROM 'active'
     OR v_device.site_id IS NULL
     OR v_device.location_id IS NULL THEN
    RAISE EXCEPTION 'station_not_ready' USING ERRCODE = 'check_violation';
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', pc.id,
      'key', pc.key,
      'label_i18n', pc.label_i18n,
      'counts_as_work', pc.counts_as_work,
      'max_duration_minutes', pc.max_duration_minutes,
      'sort_order', pc.sort_order
    )
    ORDER BY pc.sort_order, pc.key
  ), '[]'::jsonb)
  INTO v_rows
  FROM data.tenant_pause_configs pc
  WHERE pc.tenant_id = v_device.tenant_id
    AND pc.is_active = true
    AND (pc.site_id IS NULL OR pc.site_id = v_device.site_id);

  RETURN jsonb_build_object('configs', COALESCE(v_rows, '[]'::jsonb));
END;
$$;

COMMENT ON FUNCTION api.list_attendance_station_pause_configs(uuid) IS
  'ST-16: tipus de pausa actius per a la UI kiosk.';

GRANT EXECUTE ON FUNCTION api.list_attendance_station_pause_configs(uuid) TO service_role;

-- Llista empleats: active_pause_type + can_start/end pause
CREATE OR REPLACE FUNCTION api.list_attendance_station_employees(p_device_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_device record;
  v_rows   jsonb;
  v_tz     text;
  v_today  date;
  v_scope  boolean;
  v_mode   text;
BEGIN
  SELECT d.id, d.tenant_id, d.site_id, d.location_id, d.status
    INTO v_device
  FROM data.attendance_devices d
  WHERE d.id = p_device_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'device_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_device.status IS DISTINCT FROM 'active' OR v_device.site_id IS NULL OR v_device.location_id IS NULL THEN
    RAISE EXCEPTION 'station_not_ready' USING ERRCODE = 'check_violation';
  END IF;

  v_tz := data.get_site_timezone(v_device.site_id, v_device.tenant_id);
  v_today := (now() AT TIME ZONE v_tz)::date;

  v_scope := data.location_scope_has_attendance_assignments(v_device.location_id, v_today);
  v_mode := CASE WHEN v_scope THEN 'zone' ELSE 'site_fallback' END;

  SELECT COALESCE(jsonb_agg(row_data ORDER BY sort_name), '[]'::jsonb)
    INTO v_rows
  FROM (
    SELECT
      jsonb_build_object(
        'employee_id', e.id,
        'full_name', e.full_name,
        'last_punch_type', lp.punch_type,
        'last_punch_at', lp.occurred_at,
        'day_state', data.compute_employee_punch_day_state(e.id, v_today),
        'next_punch', data.station_kiosk_next_punch(
          data.compute_employee_punch_day_state(e.id, v_today)
        ),
        'active_pause_type', CASE
          WHEN data.compute_employee_punch_day_state(e.id, v_today) = 'break'
            THEN lp.pause_type
          ELSE NULL
        END,
        'can_start_pause', data.compute_employee_punch_day_state(e.id, v_today) = 'work',
        'can_end_pause', data.compute_employee_punch_day_state(e.id, v_today) = 'break'
      ) AS row_data,
      e.full_name AS sort_name
    FROM data.employees e
    LEFT JOIN LATERAL (
      SELECT tp.punch_type, tp.occurred_at, tp.pause_type
      FROM data.time_punches tp
      WHERE tp.employee_id = e.id
        AND (tp.occurred_at AT TIME ZONE v_tz)::date = v_today
      ORDER BY tp.occurred_at DESC, tp.id DESC
      LIMIT 1
    ) lp ON true
    WHERE e.tenant_id = v_device.tenant_id
      AND e.site_id = v_device.site_id
      AND e.status = 'active'
      AND (
        NOT v_scope
        OR data.employee_can_punch_at_location(e.id, v_device.location_id, v_today)
      )
  ) sub;

  RETURN jsonb_build_object(
    'employees', v_rows,
    'assignment_mode', v_mode,
    'scope_has_assignments', v_scope,
    'site_timezone', v_tz
  );
END;
$$;

-- record_time_punch: permet break_* des d'estació amb validació contextual
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
  v_tz             text;
  v_pause_type     text := p_pause_type;
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
    IF p_punch_type NOT IN ('in', 'out', 'break_start', 'break_end') THEN
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

    IF NOT data.station_allows_punch_type(v_day_state, p_punch_type) THEN
      IF v_day_state IN ('travel', 'unknown') THEN
        RAISE EXCEPTION 'station_punch_blocked: state % requires portal or manager', v_day_state
          USING ERRCODE = 'check_violation';
      END IF;
      RAISE EXCEPTION 'station_wrong_punch_type: expected for state % got %', v_day_state, p_punch_type
        USING ERRCODE = 'check_violation';
    END IF;

    IF p_punch_type = 'break_start' THEN
      IF v_pause_type IS NULL OR btrim(v_pause_type) = '' THEN
        RAISE EXCEPTION 'missing_pause_type' USING ERRCODE = 'check_violation';
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM data.tenant_pause_configs pc
        WHERE pc.tenant_id = v_employee.tenant_id
          AND pc.key = v_pause_type
          AND pc.is_active = true
      ) THEN
        RAISE EXCEPTION 'invalid_pause_type: %', v_pause_type USING ERRCODE = 'check_violation';
      END IF;
    END IF;

    IF p_punch_type = 'break_end' AND (v_pause_type IS NULL OR btrim(v_pause_type) = '') THEN
      SELECT tp.pause_type INTO v_pause_type
      FROM data.time_punches tp
      WHERE tp.employee_id = p_employee_id
        AND (tp.occurred_at AT TIME ZONE v_tz)::date = v_work_date
        AND tp.punch_type = 'break_start'
      ORDER BY tp.occurred_at DESC, tp.id DESC
      LIMIT 1;
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
  IF p_punch_type IN ('break_start', 'break_end') AND v_pause_type IS NOT NULL THEN
    SELECT counts_as_work INTO v_pause_cfg
    FROM data.tenant_pause_configs
    WHERE tenant_id = v_employee.tenant_id AND key = v_pause_type AND is_active = true;
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
    v_pause_type, v_counts_work, COALESCE(p_is_remote, false),
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
        'pause_type', v_pause_type, 'occurred_at', v_occurred_at, 'is_remote', p_is_remote,
        'location_id', p_location_id, 'device_id', p_device_id
      )
    ));
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object('punch_id', v_punch_id, 'status', 'created', 'anomaly_codes', v_anomalies);
END;
$$;

COMMENT ON FUNCTION api.record_time_punch IS
  'ST-16: estació permet in/out/break_start/break_end amb validació contextual.';

NOTIFY pgrst, 'reload schema';
