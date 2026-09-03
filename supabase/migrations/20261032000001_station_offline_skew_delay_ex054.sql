-- EX-05.4: CLOCK_SKEW / OFFLINE_DELAY / max_age + quarantena (ST-9 V2)
-- Offline sync: acceptar occurred_at del toc amb anomalies; rebutjar si massa antic.

INSERT INTO data.settings_registry
  (setting_key, scope, required_permission, owner_only, is_active, description)
VALUES
  ('attendance_offline_delay_threshold_ms', 'site', 'attendance.devices.manage', false, true,
   'Retard (ms) received_at−occurred_at abans de marcar OFFLINE_DELAY. Per defecte: 300000 (5 min)'),
  ('attendance_offline_max_age_ms', 'site', 'attendance.devices.manage', false, true,
   'Edat màxima (ms) d''un punch offline abans de rebutjar (station_punch_too_old). Per defecte: 259200000 (72 h)')
ON CONFLICT (setting_key) DO UPDATE SET
  scope               = EXCLUDED.scope,
  required_permission = EXCLUDED.required_permission,
  owner_only          = EXCLUDED.owner_only,
  is_active           = EXCLUDED.is_active,
  description         = EXCLUDED.description,
  updated_at          = now();

INSERT INTO data.system_settings (module, settings)
VALUES ('defaults', '{
  "attendance_offline_delay_threshold_ms": 300000,
  "attendance_offline_max_age_ms": 259200000
}'::jsonb)
ON CONFLICT (module) DO UPDATE
  SET settings = data.system_settings.settings || EXCLUDED.settings,
      updated_at = now();

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
  v_delay_ms       bigint;
  v_threshold_ms   bigint;
  v_delay_threshold_ms bigint;
  v_max_age_ms     bigint;
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
  v_received_at    timestamptz := now();
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

  IF auth.uid() IS NULL AND p_source IN ('portal', 'station', 'qr') THEN
    v_settings := data.merge_effective_settings_for_service(v_employee.tenant_id, v_employee.site_id);
  ELSE
    SELECT api.get_effective_settings(
      p_site_id => v_employee.site_id, p_user_id => auth.uid(), p_tenant_id => v_employee.tenant_id
    ) INTO v_settings;
  END IF;

  v_threshold_ms := COALESCE((v_settings->>'attendance_clock_offset_threshold_ms')::bigint, 300000);
  v_delay_threshold_ms := COALESCE(
    (v_settings->>'attendance_offline_delay_threshold_ms')::bigint,
    v_threshold_ms
  );
  v_max_age_ms := COALESCE((v_settings->>'attendance_offline_max_age_ms')::bigint, 259200000);

  -- EX-05.4: max_age (només passat) — rebutjar → client quarantenà
  IF p_source IN ('station', 'qr') AND v_occurred_at < v_received_at THEN
    v_delay_ms := (EXTRACT(EPOCH FROM (v_received_at - v_occurred_at)) * 1000)::bigint;
    IF v_delay_ms > v_max_age_ms THEN
      RAISE EXCEPTION 'station_punch_too_old: delay_ms % > max_age_ms %',
        v_delay_ms, v_max_age_ms
        USING ERRCODE = 'check_violation';
    END IF;
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

  -- CLOCK_SKEW: desfasament absolut (portal/mobile + estació offline)
  v_offset_ms := ABS(EXTRACT(EPOCH FROM (v_occurred_at - v_received_at)) * 1000)::bigint;
  IF v_offset_ms > v_threshold_ms AND NOT ('CLOCK_SKEW' = ANY(v_anomalies)) THEN
    v_anomalies := array_append(v_anomalies, 'CLOCK_SKEW');
  END IF;

  -- OFFLINE_DELAY: sync diferit (received_at > occurred_at + llindar)
  IF p_source IN ('station', 'qr', 'portal') AND v_occurred_at < v_received_at THEN
    v_delay_ms := (EXTRACT(EPOCH FROM (v_received_at - v_occurred_at)) * 1000)::bigint;
    IF v_delay_ms > v_delay_threshold_ms AND NOT ('OFFLINE_DELAY' = ANY(v_anomalies)) THEN
      v_anomalies := array_append(v_anomalies, 'OFFLINE_DELAY');
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
    p_punch_type, v_occurred_at, v_received_at,
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
    'received_at', v_received_at
  );
END;
$$;

COMMENT ON FUNCTION api.record_time_punch IS
  'EX-05.4: CLOCK_SKEW/OFFLINE_DELAY anomalies; station/qr max_age → station_punch_too_old.';

NOTIFY pgrst, 'reload schema';
