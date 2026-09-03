-- =============================================================================
-- EX-04.6 / ST-18d — Punch sense assignació de zona (allow / warn + anomaly)
-- =============================================================================
-- Flags ja existents a attendance_devices:
--   allow_unassigned_punch (default true) — si false, bloqueja com fins ara
--   warn_unassigned_punch  (default true) — banner a sessió; anomalia sempre si es permet
-- Anomaly: OUTSIDE_ASSIGNMENT (auditoria punched_outside_assignment)

CREATE OR REPLACE FUNCTION api.station_employee_location_hint(
  p_device_id   uuid,
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_device record;
  v_tz text;
  v_today date;
  v_plan jsonb;
  v_ids uuid[];
  v_mismatch boolean := false;
  v_scope boolean;
  v_outside boolean := false;
BEGIN
  SELECT d.id, d.tenant_id, d.site_id, d.location_id, d.status,
         d.warn_wrong_scheduled_location, d.block_wrong_scheduled_location,
         d.allow_unassigned_punch, d.warn_unassigned_punch,
         l.name AS location_name
    INTO v_device
  FROM data.attendance_devices d
  LEFT JOIN data.locations l ON l.id = d.location_id
  WHERE d.id = p_device_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'device_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_device.status IS DISTINCT FROM 'active'
     OR v_device.site_id IS NULL
     OR v_device.location_id IS NULL THEN
    RAISE EXCEPTION 'station_not_ready' USING ERRCODE = 'check_violation';
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

  v_tz := data.get_site_timezone(v_device.site_id, v_device.tenant_id);
  v_today := (now() AT TIME ZONE v_tz)::date;
  v_plan := data.resolve_employee_work_plan(p_employee_id, v_today);
  v_ids := data.employee_scheduled_location_ids_for_day(p_employee_id, v_today);

  IF cardinality(v_ids) > 0 AND NOT (v_device.location_id = ANY (v_ids)) THEN
    v_mismatch := true;
  END IF;

  v_scope := data.location_scope_has_attendance_assignments(v_device.location_id, v_today);
  IF v_scope AND NOT data.employee_can_punch_at_location(p_employee_id, v_device.location_id, v_today) THEN
    v_outside := true;
  END IF;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'work_date', v_today,
    'station_location_id', v_device.location_id,
    'station_location_name', COALESCE(
      data.build_location_path_snapshot(v_device.location_id),
      v_device.location_name
    ),
    'scheduled_location_id', NULLIF(v_plan->>'scheduled_location_id', '')::uuid,
    'scheduled_location_name', v_plan->>'scheduled_location_name',
    'scheduled_location_path', v_plan->>'scheduled_location_path',
    'scheduled_location_ids', to_jsonb(v_ids),
    'wrong_scheduled_location', v_mismatch,
    'warn_wrong_scheduled_location', COALESCE(v_device.warn_wrong_scheduled_location, true),
    'block_wrong_scheduled_location', COALESCE(v_device.block_wrong_scheduled_location, false),
    'outside_assignment', v_outside,
    'allow_unassigned_punch', COALESCE(v_device.allow_unassigned_punch, true),
    'warn_unassigned_punch', COALESCE(v_device.warn_unassigned_punch, true),
    'assignment_scope_active', v_scope
  );
END;
$$;

COMMENT ON FUNCTION api.station_employee_location_hint(uuid, uuid) IS
  'EX-04.5/04.6: ubicació planificada + assignació zona vs estació (sessió kiosk).';

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

  -- ST-18d: assignació zona (eligibility)
  v_scope := data.location_scope_has_attendance_assignments(v_device.location_id, v_today);
  IF v_scope AND NOT data.employee_can_punch_at_location(p_employee_id, v_device.location_id, v_today) THEN
    v_outside := true;
    IF NOT COALESCE(v_device.allow_unassigned_punch, true) THEN
      RAISE EXCEPTION 'employee_not_allowed_at_location' USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  -- ST-18c: planificat vs estació
  v_plan := data.resolve_employee_work_plan(p_employee_id, v_today);
  v_scheduled_ids := data.employee_scheduled_location_ids_for_day(p_employee_id, v_today);
  v_sched_id := NULLIF(v_plan->>'scheduled_location_id', '')::uuid;
  v_sched_name := v_plan->>'scheduled_location_name';
  v_sched_path := v_plan->>'scheduled_location_path';

  IF cardinality(v_scheduled_ids) > 0 AND NOT (v_device.location_id = ANY (v_scheduled_ids)) THEN
    v_mismatch := true;
    IF COALESCE(v_device.block_wrong_scheduled_location, false) THEN
      RAISE EXCEPTION 'wrong_scheduled_location: estació % no coincideix amb ubicació planificada %',
        COALESCE(data.build_location_path_snapshot(v_device.location_id), v_device.location_name, v_device.location_id::text),
        COALESCE(v_sched_path, v_sched_name, v_sched_id::text)
        USING ERRCODE = 'check_violation';
    END IF;
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
      'device_name', v_device.name,
      'scheduled_location_id', v_sched_id,
      'scheduled_location_name', v_sched_name,
      'scheduled_location_path', v_sched_path,
      'wrong_scheduled_location', v_mismatch,
      'outside_assignment', v_outside,
      'punched_outside_assignment', v_outside
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

  -- Anomalies append-only (ST-18c / ST-18d)
  IF v_result->>'status' = 'created' AND v_result->>'punch_id' IS NOT NULL THEN
    IF v_mismatch AND COALESCE(v_device.warn_wrong_scheduled_location, true) THEN
      v_codes_to_add := array_append(v_codes_to_add, 'WRONG_SCHEDULED_LOCATION');
    END IF;
    -- Auditoria always when outside assignment was allowed through
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

COMMENT ON FUNCTION api.record_station_time_punch(uuid, uuid, uuid, text, text, text, jsonb, text) IS
  'ST-1..ST-18d: punch estació; ubicació planificada (18c) + assignació zona warn/block (18d).';

NOTIFY pgrst, 'reload schema';
