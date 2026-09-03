-- EX-01.3: Timezone per site a RPCs d'estació (eliminar Europe/Madrid hardcoded).

-- -----------------------------------------------------------------------------
-- 1. compute_employee_punch_day_state — resolve TZ from employee site
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.compute_employee_punch_day_state(
  p_employee_id uuid,
  p_work_date   date DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_state     text := data.initial_punch_day_state();
  v_work_date date;
  v_tz        text := 'Europe/Madrid';
  v_punch     record;
  v_next      text;
BEGIN
  SELECT COALESCE(data.get_site_timezone(e.site_id, e.tenant_id), 'Europe/Madrid')
    INTO v_tz
  FROM data.employees e
  WHERE e.id = p_employee_id;

  v_work_date := COALESCE(p_work_date, (now() AT TIME ZONE v_tz)::date);

  FOR v_punch IN
    SELECT tp.punch_type
    FROM data.time_punches tp
    WHERE tp.employee_id = p_employee_id
      AND (tp.occurred_at AT TIME ZONE v_tz)::date = v_work_date
    ORDER BY tp.occurred_at ASC, tp.id ASC
  LOOP
    v_next := data.punch_day_state_after(v_state, v_punch.punch_type);
    IF v_next IS NULL THEN
      RETURN 'unknown';
    END IF;
    v_state := v_next;
  END LOOP;
  RETURN v_state;
END;
$$;

-- -----------------------------------------------------------------------------
-- 2. list_attendance_station_employees — device site TZ
-- -----------------------------------------------------------------------------

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
        )
      ) AS row_data,
      e.full_name AS sort_name
    FROM data.employees e
    LEFT JOIN LATERAL (
      SELECT tp.punch_type, tp.occurred_at
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

-- -----------------------------------------------------------------------------
-- 3. resolve_attendance_identity_token — device site TZ
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.resolve_attendance_identity_token(
  p_token             text,
  p_device_public_id  text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_device    record;
  v_row       record;
  v_hash      bytea;
  v_tz        text;
  v_today     date;
  v_day_state text;
  v_next      text;
BEGIN
  IF p_token IS NULL OR btrim(p_token) = '' THEN
    RAISE EXCEPTION 'identity_token_required' USING ERRCODE = 'check_violation';
  END IF;

  IF p_device_public_id IS NULL OR btrim(p_device_public_id) = '' THEN
    RAISE EXCEPTION 'device_public_id_required' USING ERRCODE = 'check_violation';
  END IF;

  SELECT d.*
    INTO v_device
  FROM data.attendance_devices d
  WHERE d.device_public_id = btrim(p_device_public_id)
    AND d.type = 'station';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'station_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_device.status IS DISTINCT FROM 'active'
     OR v_device.site_id IS NULL
     OR v_device.location_id IS NULL THEN
    RAISE EXCEPTION 'station_not_ready' USING ERRCODE = 'check_violation';
  END IF;

  IF NOT ('qr' = ANY(COALESCE(v_device.allowed_methods, ARRAY['manual']::text[]))
          OR 'barcode' = ANY(COALESCE(v_device.allowed_methods, ARRAY['manual']::text[]))) THEN
    RAISE EXCEPTION 'station_qr_not_allowed' USING ERRCODE = 'check_violation';
  END IF;

  v_tz := data.get_site_timezone(v_device.site_id, v_device.tenant_id);
  v_today := (now() AT TIME ZONE v_tz)::date;

  v_hash := digest(btrim(p_token), 'sha256');

  SELECT t.*, e.full_name
    INTO v_row
  FROM data.attendance_identity_tokens t
  JOIN data.employees e ON e.id = t.employee_id
  WHERE t.token_hash = v_hash;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'identity_token_invalid' USING ERRCODE = 'check_violation';
  END IF;

  IF v_row.used_at IS NOT NULL THEN
    RAISE EXCEPTION 'identity_token_already_used' USING ERRCODE = 'check_violation';
  END IF;

  IF v_row.expires_at <= now() THEN
    RAISE EXCEPTION 'identity_token_expired' USING ERRCODE = 'check_violation';
  END IF;

  IF v_row.tenant_id IS DISTINCT FROM v_device.tenant_id THEN
    RAISE EXCEPTION 'identity_token_tenant_mismatch' USING ERRCODE = 'check_violation';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.employees e
    WHERE e.id = v_row.employee_id
      AND e.tenant_id = v_device.tenant_id
      AND e.site_id = v_device.site_id
      AND e.status = 'active'
  ) THEN
    RAISE EXCEPTION 'employee_not_allowed_at_station' USING ERRCODE = 'check_violation';
  END IF;

  UPDATE data.attendance_devices
  SET last_seen_at = now(), updated_at = now()
  WHERE id = v_device.id;

  v_day_state := data.compute_employee_punch_day_state(v_row.employee_id, v_today);
  v_next := data.station_kiosk_next_punch(v_day_state);

  RETURN jsonb_build_object(
    'employee_id', v_row.employee_id,
    'full_name', v_row.full_name,
    'method', v_row.method,
    'day_state', v_day_state,
    'next_punch', v_next,
    'token_id', v_row.id,
    'site_timezone', v_tz
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 4. record_station_time_punch — device site TZ
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.record_station_time_punch(
  p_device_id       uuid,
  p_employee_id     uuid,
  p_client_op_id    uuid,
  p_punch_type      text,
  p_pause_type      text DEFAULT NULL,
  p_source          text DEFAULT 'station',
  p_device_geo      jsonb DEFAULT NULL,
  p_identity_token  text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, pgmq, extensions
AS $$
DECLARE
  v_device           record;
  v_location_path    text;
  v_location_name    text;
  v_device_name      text;
  v_source           text;
  v_result           jsonb;
  v_location_geo     jsonb;
  v_tz               text;
  v_today            date;
  v_scope            boolean;
  v_existing         record;
  v_token_row        record;
  v_token_id         uuid;
  v_token_hash       bytea;
BEGIN
  v_source := lower(btrim(COALESCE(p_source, 'station')));
  IF v_source NOT IN ('station', 'qr') THEN
    RAISE EXCEPTION 'invalid_station_punch_source' USING ERRCODE = 'check_violation';
  END IF;

  SELECT d.*, l.name AS location_name, l.geo_coordinates AS location_geo_coordinates
    INTO v_device
  FROM data.attendance_devices d
  LEFT JOIN data.locations l ON l.id = d.location_id
  WHERE d.id = p_device_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'device_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_device.status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'station_not_active' USING ERRCODE = 'check_violation';
  END IF;

  IF v_device.site_id IS NULL OR v_device.location_id IS NULL THEN
    RAISE EXCEPTION 'station_missing_location' USING ERRCODE = 'check_violation';
  END IF;

  v_tz := data.get_site_timezone(v_device.site_id, v_device.tenant_id);
  v_today := (now() AT TIME ZONE v_tz)::date;

  IF v_source = 'qr' AND NOT ('qr' = ANY(COALESCE(v_device.allowed_methods, ARRAY['manual']::text[]))) THEN
    RAISE EXCEPTION 'station_qr_not_allowed' USING ERRCODE = 'check_violation';
  END IF;

  IF v_source = 'station' AND NOT ('manual' = ANY(COALESCE(v_device.allowed_methods, ARRAY['manual']::text[]))) THEN
    RAISE EXCEPTION 'station_manual_not_allowed' USING ERRCODE = 'check_violation';
  END IF;

  IF COALESCE(v_device.geo_antifraud_enabled, false) THEN
    v_location_geo := v_device.location_geo_coordinates;
    PERFORM data.validate_station_geo_probe(
      p_device_geo,
      v_location_geo,
      COALESCE(v_device.geo_antifraud_radius_m, 150)
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.employees e
    WHERE e.id = p_employee_id
      AND e.tenant_id = v_device.tenant_id
      AND e.site_id = v_device.site_id
      AND e.status = 'active'
  ) THEN
    RAISE EXCEPTION 'employee_not_allowed_at_station' USING ERRCODE = 'check_violation';
  END IF;

  v_scope := data.location_scope_has_attendance_assignments(v_device.location_id, v_today);
  IF v_scope AND NOT data.employee_can_punch_at_location(p_employee_id, v_device.location_id, v_today) THEN
    RAISE EXCEPTION 'employee_not_allowed_at_location' USING ERRCODE = 'check_violation';
  END IF;

  SELECT tp.id, tp.punch_type, tp.source
    INTO v_existing
  FROM data.time_punches tp
  WHERE tp.tenant_id = v_device.tenant_id
    AND tp.client_op_id = p_client_op_id
  LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'status', 'duplicate',
      'punch_id', v_existing.id,
      'punch_type', v_existing.punch_type,
      'source', v_existing.source,
      'location_id', v_device.location_id,
      'location_name', COALESCE(data.build_location_path_snapshot(v_device.location_id), v_device.location_name),
      'device_name', v_device.name
    );
  END IF;

  IF v_source = 'qr' THEN
    IF p_identity_token IS NULL OR btrim(p_identity_token) = '' THEN
      RAISE EXCEPTION 'identity_token_required' USING ERRCODE = 'check_violation';
    END IF;

    v_token_hash := digest(btrim(p_identity_token), 'sha256');

    SELECT t.*
      INTO v_token_row
    FROM data.attendance_identity_tokens t
    WHERE t.token_hash = v_token_hash
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'identity_token_invalid' USING ERRCODE = 'check_violation';
    END IF;

    IF v_token_row.used_at IS NOT NULL THEN
      RAISE EXCEPTION 'identity_token_already_used' USING ERRCODE = 'check_violation';
    END IF;

    IF v_token_row.expires_at <= now() THEN
      RAISE EXCEPTION 'identity_token_expired' USING ERRCODE = 'check_violation';
    END IF;

    IF v_token_row.employee_id IS DISTINCT FROM p_employee_id THEN
      RAISE EXCEPTION 'identity_token_employee_mismatch' USING ERRCODE = 'check_violation';
    END IF;

    IF v_token_row.tenant_id IS DISTINCT FROM v_device.tenant_id THEN
      RAISE EXCEPTION 'identity_token_tenant_mismatch' USING ERRCODE = 'check_violation';
    END IF;

    v_token_id := v_token_row.id;
  END IF;

  v_location_path := data.build_location_path_snapshot(v_device.location_id);
  v_location_name := COALESCE(v_location_path, v_device.location_name);
  v_device_name := v_device.name;

  v_result := api.record_time_punch(
    p_employee_id          => p_employee_id,
    p_client_op_id         => p_client_op_id,
    p_punch_type           => p_punch_type,
    p_occurred_at          => now(),
    p_geo                  => NULL,
    p_location_perm        => 'notrequired',
    p_notes                => NULL,
    p_source               => v_source,
    p_device_id            => p_device_id,
    p_pause_type           => p_pause_type,
    p_pause_counts_as_work => NULL,
    p_is_remote            => false,
    p_geo_consent          => false,
    p_geo_error            => NULL,
    p_device_info          => NULL,
    p_location_id          => v_device.location_id,
    p_location_name_snapshot => v_location_name,
    p_device_name_snapshot => v_device_name
  );

  IF v_source = 'qr'
     AND v_result->>'status' = 'created'
     AND v_token_id IS NOT NULL THEN
    UPDATE data.attendance_identity_tokens
    SET used_at = now(),
        used_device_id = p_device_id
    WHERE id = v_token_id
      AND used_at IS NULL;
  END IF;

  RETURN v_result || jsonb_build_object(
    'location_id', v_device.location_id,
    'location_name', v_location_name,
    'device_name', v_device_name,
    'source', v_source,
    'site_timezone', v_tz
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 5. record_time_punch — work_date from employee site TZ
-- -----------------------------------------------------------------------------

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

-- -----------------------------------------------------------------------------
-- 6. verify_attendance_station_credentials — expose site_timezone
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.verify_attendance_station_credentials(
  p_device_public_id text,
  p_device_secret    text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_row record;
  v_location_geo jsonb;
BEGIN
  SELECT
    d.id,
    d.tenant_id,
    d.site_id,
    d.location_id,
    d.name,
    d.display_title,
    d.display_logo_url,
    d.status,
    d.type,
    d.allowed_methods,
    d.geo_antifraud_enabled,
    d.geo_antifraud_radius_m,
    d.device_secret_hash,
    d.last_seen_at,
    data.build_location_path_snapshot(d.location_id) AS location_path,
    l.geo_coordinates AS location_geo_coordinates
  INTO v_row
  FROM data.attendance_devices d
  LEFT JOIN data.locations l ON l.id = d.location_id
  WHERE d.device_public_id = btrim(p_device_public_id)
    AND d.device_secret_hash IS NOT NULL
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'station_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_row.device_secret_hash IS DISTINCT FROM extensions.crypt(p_device_secret, v_row.device_secret_hash) THEN
    RAISE EXCEPTION 'station_invalid_secret' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_location_geo := v_row.location_geo_coordinates;

  RETURN jsonb_build_object(
    'device_id', v_row.id,
    'tenant_id', v_row.tenant_id,
    'site_id', v_row.site_id,
    'location_id', v_row.location_id,
    'location_path', v_row.location_path,
    'name', v_row.name,
    'display_title', v_row.display_title,
    'display_logo_url', v_row.display_logo_url,
    'effective_display_title', data.station_effective_display_title(v_row.name, v_row.display_title),
    'status', v_row.status,
    'type', v_row.type,
    'allowed_methods', v_row.allowed_methods,
    'geo_antifraud_enabled', COALESCE(v_row.geo_antifraud_enabled, false),
    'geo_antifraud_radius_m', COALESCE(v_row.geo_antifraud_radius_m, 150),
    'location_has_geo', data.extract_geo_point(v_location_geo) IS NOT NULL,
    'site_timezone', data.get_site_timezone(v_row.site_id, v_row.tenant_id)
  );
END;
$$;
