-- EX-05.6 FF-04: station_offline_deferred_punch + gate (demo Acme override → seed.sql)
INSERT INTO data.feature_flags (key, description, is_enabled, rollout_percentage)
VALUES (
  'station_offline_deferred_punch',
  'FF-04 / EX-05.6: ST-9 V2 deferred punch delivery (outbox offline). Default OFF (prod online-only). Enable per tenant via tenant_feature_overrides.',
  false,
  0
)
ON CONFLICT (key) DO UPDATE
SET description = EXCLUDED.description,
    updated_at = now();

CREATE OR REPLACE FUNCTION data.is_station_offline_deferred_punch_enabled(p_tenant_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT COALESCE(data.is_feature_enabled(p_tenant_id, 'station_offline_deferred_punch'), false);
$$;

COMMENT ON FUNCTION data.is_station_offline_deferred_punch_enabled(uuid) IS
  'EX-05.6 FF-04: true si el tenant pot desar/pujar punches offline (occurred_at diferit).';

REVOKE ALL ON FUNCTION data.is_station_offline_deferred_punch_enabled(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.is_station_offline_deferred_punch_enabled(uuid) TO authenticated, service_role;


CREATE OR REPLACE FUNCTION api.record_station_time_punch(p_device_id uuid, p_employee_id uuid, p_client_op_id uuid, p_punch_type text, p_pause_type text DEFAULT NULL::text, p_source text DEFAULT 'station'::text, p_device_geo jsonb DEFAULT NULL::jsonb, p_identity_token text DEFAULT NULL::text, p_occurred_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'data', 'api', 'public', 'pgmq', 'extensions'
AS $function$
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

  -- EX-05.6 FF-04: sync diferit (p_occurred_at) nomes si el flag esta actiu
  IF p_occurred_at IS NOT NULL
     AND NOT data.is_station_offline_deferred_punch_enabled(v_device.tenant_id) THEN
    RAISE EXCEPTION 'station_offline_disabled'
      USING ERRCODE = 'check_violation';
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
$function$;


COMMENT ON FUNCTION api.record_station_time_punch(uuid, uuid, uuid, text, text, text, jsonb, text, timestamptz) IS
  'EX-05.6: punch estacio; offline (p_occurred_at) requereix FF-04 station_offline_deferred_punch.';

NOTIFY pgrst, 'reload schema';
