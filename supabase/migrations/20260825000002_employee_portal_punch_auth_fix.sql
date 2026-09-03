-- Employee portal punch: record_time_punch sense auth.users (source = portal)

CREATE OR REPLACE FUNCTION data.merge_effective_settings_for_service(
  p_tenant_id uuid,
  p_site_id   uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT
    COALESCE((SELECT s.settings FROM data.system_settings s WHERE s.module = 'defaults' LIMIT 1), '{}'::jsonb)
    || COALESCE((SELECT t.settings FROM data.tenants t WHERE t.id = p_tenant_id), '{}'::jsonb)
    || COALESCE((SELECT s.settings FROM data.sites s WHERE s.id = p_site_id), '{}'::jsonb);
$$;

REVOKE ALL ON FUNCTION data.merge_effective_settings_for_service(uuid, uuid) FROM PUBLIC;

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

  SELECT punch_type, pause_type INTO v_last_punch
  FROM data.time_punches
  WHERE employee_id = p_employee_id
    AND (occurred_at AT TIME ZONE 'Europe/Madrid')::date = v_work_date
  ORDER BY occurred_at DESC, id DESC
  LIMIT 1;

  IF p_punch_type = 'in' AND v_last_punch.punch_type IN ('in', 'break_start') THEN
    RAISE EXCEPTION 'invalid_sequence: already working or on pause' USING ERRCODE = 'check_violation';
  END IF;
  IF p_punch_type = 'out' THEN
    IF v_last_punch IS NULL OR v_last_punch.punch_type = 'out' THEN
      RAISE EXCEPTION 'invalid_sequence: not working' USING ERRCODE = 'check_violation';
    END IF;
    IF v_last_punch.punch_type = 'break_start' THEN
      RAISE EXCEPTION 'invalid_sequence: close pause before punch out' USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  IF p_punch_type = 'break_start' AND COALESCE(v_last_punch.punch_type, 'out') NOT IN ('in', 'break_end') THEN
    RAISE EXCEPTION 'invalid_sequence: must be working to start pause' USING ERRCODE = 'check_violation';
  END IF;
  IF p_punch_type = 'break_end' AND v_last_punch.punch_type != 'break_start' THEN
    RAISE EXCEPTION 'invalid_sequence: no open pause' USING ERRCODE = 'check_violation';
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
        ELSE 'PAUSE_END'
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

NOTIFY pgrst, 'reload schema';
