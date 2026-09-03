-- EX-05.3: occurred_at / received_at per sync offline estacio (ST-9 V2)
-- Online: occurred_at = now() servidor
-- Offline: occurred_at = toc client; received_at = pujada (INSERT)
-- CLOCK_SKEW / OFFLINE_DELAY / max_age → EX-05.4
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
    -- EX-05.3: respectar p_occurred_at del sync offline (online passa now() des del wrapper)
    -- no forcar now() aqui
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
    RETURN jsonb_build_object(
      'punch_id', v_punch_id,
      'status', 'duplicate',
      'anomaly_codes', ARRAY[]::text[],
      'occurred_at', (SELECT occurred_at FROM data.time_punches WHERE id = v_punch_id),
      'received_at', (SELECT received_at FROM data.time_punches WHERE id = v_punch_id)
    );
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

  RETURN jsonb_build_object(
    'punch_id', v_punch_id,
    'status', 'created',
    'anomaly_codes', v_anomalies,
    'occurred_at', v_occurred_at,
    'received_at', now()
  );
END;
$$;




-- EX-05.3: p_occurred_at opcional (NULL = online → now())
DROP FUNCTION IF EXISTS api.record_station_time_punch(uuid, uuid, uuid, text, text, text, jsonb, text);

CREATE OR REPLACE FUNCTION api.record_station_time_punch(
  p_device_id       uuid,
  p_employee_id     uuid,
  p_client_op_id    uuid,
  p_punch_type      text,
  p_pause_type      text DEFAULT NULL,
  p_source          text DEFAULT 'station',
  p_device_geo      jsonb DEFAULT NULL,
  p_identity_token  text DEFAULT NULL,
  p_occurred_at     timestamptz DEFAULT NULL
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
  v_effective_at     timestamptz;
  v_scope            boolean;
  v_existing         record;
  v_token_row        record;
  v_token_id         uuid;
  v_token_hash       bytea;
  v_plan             jsonb;
  v_scheduled_ids    uuid[];
  v_mismatch         boolean := false;
  v_outside          boolean := false;
  v_sched_id         uuid;
  v_sched_name       text;
  v_sched_path       text;
  v_anomalies        text[];
  v_punch_id         uuid;
  v_codes_to_add     text[] := ARRAY[]::text[];
  v_code             text;
  v_last_at          timestamptz;
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
  -- Online: now(). Offline sync: hora del toc (cua local)
  v_effective_at := COALESCE(p_occurred_at, now());
  v_today := (v_effective_at AT TIME ZONE v_tz)::date;

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
    v_outside := true;
    IF NOT COALESCE(v_device.allow_unassigned_punch, true) THEN
      RAISE EXCEPTION 'employee_not_allowed_at_location' USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  v_plan := data.resolve_employee_work_plan(p_employee_id, v_today);
  v_scheduled_ids := data.employee_scheduled_location_ids_for_day(p_employee_id, v_today);
  v_sched_id := NULLIF(v_plan->>'scheduled_location_id', '')::uuid;
  v_sched_name := v_plan->>'scheduled_location_name';
  v_sched_path := v_plan->>'scheduled_location_path';

  IF cardinality(v_scheduled_ids) > 0 AND NOT (v_device.location_id = ANY (v_scheduled_ids)) THEN
    v_mismatch := true;
    IF COALESCE(v_device.block_wrong_scheduled_location, false) THEN
      RAISE EXCEPTION 'wrong_scheduled_location: estacio % no coincideix amb ubicacio planificada %',
        COALESCE(data.build_location_path_snapshot(v_device.location_id), v_device.location_name, v_device.location_id::text),
        COALESCE(v_sched_path, v_sched_name, v_sched_id::text)
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  SELECT tp.id, tp.punch_type, tp.source, tp.occurred_at, tp.received_at
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
      'occurred_at', v_existing.occurred_at,
      'received_at', v_existing.received_at,
      'location_id', v_device.location_id,
      'location_name', COALESCE(data.build_location_path_snapshot(v_device.location_id), v_device.location_name),
      'device_name', v_device.name,
      'scheduled_location_id', v_sched_id,
      'scheduled_location_name', v_sched_name,
      'scheduled_location_path', v_sched_path,
      'wrong_scheduled_location', v_mismatch,
      'outside_assignment', v_outside,
      'punched_outside_assignment', v_outside
    );
  END IF;

  -- Monotonia (EX-05.3): offline no pot anar enrere respecte l'ultim punch del dia
  IF p_occurred_at IS NOT NULL THEN
    SELECT MAX(tp.occurred_at) INTO v_last_at
    FROM data.time_punches tp
    WHERE tp.employee_id = p_employee_id
      AND (tp.occurred_at AT TIME ZONE v_tz)::date = v_today;
    IF v_last_at IS NOT NULL AND p_occurred_at < v_last_at THEN
      RAISE EXCEPTION 'station_punch_not_monotonic: occurred_at % < last %',
        p_occurred_at, v_last_at
        USING ERRCODE = 'check_violation';
    END IF;
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
    p_occurred_at          => v_effective_at,
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

  IF v_result->>'status' = 'created' AND v_result->>'punch_id' IS NOT NULL THEN
    IF v_mismatch AND COALESCE(v_device.warn_wrong_scheduled_location, true) THEN
      v_codes_to_add := array_append(v_codes_to_add, 'WRONG_SCHEDULED_LOCATION');
    END IF;
    IF v_outside THEN
      v_codes_to_add := array_append(v_codes_to_add, 'OUTSIDE_ASSIGNMENT');
    END IF;

    IF cardinality(v_codes_to_add) > 0 THEN
      v_punch_id := (v_result->>'punch_id')::uuid;
      FOREACH v_code IN ARRAY v_codes_to_add LOOP
        UPDATE data.time_punches tp
        SET anomaly_codes = CASE
              WHEN v_code = ANY (COALESCE(tp.anomaly_codes, ARRAY[]::text[]))
                THEN tp.anomaly_codes
              ELSE array_append(COALESCE(tp.anomaly_codes, ARRAY[]::text[]), v_code)
            END
        WHERE tp.id = v_punch_id
        RETURNING tp.anomaly_codes INTO v_anomalies;
      END LOOP;

      v_result := v_result || jsonb_build_object(
        'anomaly_codes', to_jsonb(COALESCE(v_anomalies, v_codes_to_add))
      );
    END IF;
  END IF;

  RETURN v_result || jsonb_build_object(
    'location_id', v_device.location_id,
    'location_name', v_location_name,
    'device_name', v_device_name,
    'source', v_source,
    'site_timezone', v_tz,
    'scheduled_location_id', v_sched_id,
    'scheduled_location_name', v_sched_name,
    'scheduled_location_path', v_sched_path,
    'wrong_scheduled_location', v_mismatch,
    'outside_assignment', v_outside,
    'punched_outside_assignment', v_outside
  );
END;
$$;

REVOKE ALL ON FUNCTION api.record_station_time_punch(uuid, uuid, uuid, text, text, text, jsonb, text, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.record_station_time_punch(uuid, uuid, uuid, text, text, text, jsonb, text, timestamptz) TO service_role;

COMMENT ON FUNCTION api.record_station_time_punch(uuid, uuid, uuid, text, text, text, jsonb, text, timestamptz) IS
  'EX-05.3: punch estacio; p_occurred_at NULL=online(now), NOT NULL=offline sync toc local; received_at=now().';

NOTIFY pgrst, 'reload schema';
