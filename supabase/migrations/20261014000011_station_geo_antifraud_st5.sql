-- ST-5: geo anti-frau opcional per estació (validació puntual, sense guardar geo al punch)

ALTER TABLE data.attendance_devices
  ADD COLUMN IF NOT EXISTS geo_antifraud_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS geo_antifraud_radius_m integer NOT NULL DEFAULT 150;

ALTER TABLE data.attendance_devices
  DROP CONSTRAINT IF EXISTS attendance_devices_geo_antifraud_radius_check;

ALTER TABLE data.attendance_devices
  ADD CONSTRAINT attendance_devices_geo_antifraud_radius_check
  CHECK (geo_antifraud_radius_m BETWEEN 25 AND 2000);

COMMENT ON COLUMN data.attendance_devices.geo_antifraud_enabled IS
  'Si true, cal enviar device_geo al punch i validar distància vs locations.geo_coordinates (no es guarda geo al punch).';
COMMENT ON COLUMN data.attendance_devices.geo_antifraud_radius_m IS
  'Radi màxim (m) entre posició tablet i punt GPS de la ubicació. Per defecte 150, rang 25-2000.';

-- -----------------------------------------------------------------------------
-- Helpers geo
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.extract_geo_point(p_geo jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_lat float8;
  v_lng float8;
BEGIN
  IF p_geo IS NULL THEN
    RETURN NULL;
  END IF;

  v_lat := COALESCE(
    NULLIF(p_geo->>'lat', '')::float8,
    NULLIF(p_geo->>'latitude', '')::float8
  );
  v_lng := COALESCE(
    NULLIF(p_geo->>'lng', '')::float8,
    NULLIF(p_geo->>'lon', '')::float8,
    NULLIF(p_geo->>'long', '')::float8,
    NULLIF(p_geo->>'longitude', '')::float8
  );

  IF v_lat IS NULL OR v_lng IS NULL THEN
    RETURN NULL;
  END IF;

  IF v_lat < -90 OR v_lat > 90 OR v_lng < -180 OR v_lng > 180 THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object('lat', v_lat, 'lng', v_lng);
END;
$$;

REVOKE ALL ON FUNCTION data.extract_geo_point(jsonb) FROM PUBLIC;

CREATE OR REPLACE FUNCTION data.haversine_distance_m(
  p_lat1 float8,
  p_lng1 float8,
  p_lat2 float8,
  p_lng2 float8
)
RETURNS float8
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT 6371000.0 * 2.0 * asin(sqrt(
    power(sin(radians(p_lat2 - p_lat1) / 2.0), 2.0)
    + cos(radians(p_lat1)) * cos(radians(p_lat2))
      * power(sin(radians(p_lng2 - p_lng1) / 2.0), 2.0)
  ));
$$;

REVOKE ALL ON FUNCTION data.haversine_distance_m(float8, float8, float8, float8) FROM PUBLIC;

CREATE OR REPLACE FUNCTION data.validate_station_geo_probe(
  p_device_geo     jsonb,
  p_location_geo   jsonb,
  p_radius_m       integer
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_device_point   jsonb;
  v_location_point jsonb;
  v_distance_m     float8;
  v_lat            float8;
  v_lng            float8;
BEGIN
  IF p_device_geo IS NULL THEN
    RAISE EXCEPTION 'station_geo_required' USING ERRCODE = 'check_violation';
  END IF;

  BEGIN
    v_lat := (p_device_geo->>'latitude')::float8;
    v_lng := (p_device_geo->>'longitude')::float8;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'station_geo_invalid' USING ERRCODE = 'invalid_parameter_value';
  END;

  IF v_lat IS NULL OR v_lat < -90 OR v_lat > 90 THEN
    RAISE EXCEPTION 'station_geo_invalid' USING ERRCODE = 'check_violation';
  END IF;

  IF v_lng IS NULL OR v_lng < -180 OR v_lng > 180 THEN
    RAISE EXCEPTION 'station_geo_invalid' USING ERRCODE = 'check_violation';
  END IF;

  v_device_point := data.extract_geo_point(
    jsonb_build_object('lat', v_lat, 'lng', v_lng)
  );

  v_location_point := data.extract_geo_point(p_location_geo);
  IF v_location_point IS NULL THEN
    RAISE EXCEPTION 'geo_antifraud_requires_location_geo' USING ERRCODE = 'check_violation';
  END IF;

  v_distance_m := data.haversine_distance_m(
    (v_device_point->>'lat')::float8,
    (v_device_point->>'lng')::float8,
    (v_location_point->>'lat')::float8,
    (v_location_point->>'lng')::float8
  );

  IF v_distance_m > COALESCE(p_radius_m, 150) THEN
    RAISE EXCEPTION 'station_geo_out_of_range' USING ERRCODE = 'check_violation';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION data.validate_station_geo_probe(jsonb, jsonb, integer) FROM PUBLIC;

-- -----------------------------------------------------------------------------
-- verify_attendance_station_credentials — expose geo antifraud fields
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
    'status', v_row.status,
    'type', v_row.type,
    'allowed_methods', v_row.allowed_methods,
    'geo_antifraud_enabled', COALESCE(v_row.geo_antifraud_enabled, false),
    'geo_antifraud_radius_m', COALESCE(v_row.geo_antifraud_radius_m, 150),
    'location_has_geo', data.extract_geo_point(v_location_geo) IS NOT NULL
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- update_attendance_station — geo antifraud settings
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.update_attendance_station(uuid, text, uuid, uuid, text, text[]);

CREATE OR REPLACE FUNCTION api.update_attendance_station(
  p_device_id              uuid,
  p_name                   text DEFAULT NULL,
  p_site_id                uuid DEFAULT NULL,
  p_location_id            uuid DEFAULT NULL,
  p_status                 text DEFAULT NULL,
  p_allowed_methods        text[] DEFAULT NULL,
  p_geo_antifraud_enabled  boolean DEFAULT NULL,
  p_geo_antifraud_radius_m integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_row record;
  v_status text;
  v_target_location_id uuid;
  v_location_geo jsonb;
  v_geo_enabled boolean;
  v_geo_radius integer;
BEGIN
  SELECT * INTO v_row
  FROM data.attendance_devices
  WHERE id = p_device_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'device_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT (
    (data.jwt_user_tenants() -> v_row.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    OR data.jwt_has_permission(v_row.tenant_id, 'attendance.devices.manage')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_site_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.sites s
      WHERE s.id = p_site_id AND s.tenant_id = v_row.tenant_id
    ) THEN
      RAISE EXCEPTION 'site_not_found' USING ERRCODE = 'no_data_found';
    END IF;
  END IF;

  IF p_location_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.locations l
      WHERE l.id = p_location_id
        AND l.tenant_id = v_row.tenant_id
        AND (p_site_id IS NULL OR l.site_id = p_site_id OR l.site_id = COALESCE(p_site_id, v_row.site_id))
    ) THEN
      RAISE EXCEPTION 'location_not_found' USING ERRCODE = 'no_data_found';
    END IF;
  END IF;

  IF p_geo_antifraud_radius_m IS NOT NULL THEN
    IF p_geo_antifraud_radius_m < 25 OR p_geo_antifraud_radius_m > 2000 THEN
      RAISE EXCEPTION 'geo_antifraud_radius_out_of_range' USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  v_geo_enabled := COALESCE(p_geo_antifraud_enabled, v_row.geo_antifraud_enabled, false);
  v_geo_radius := COALESCE(p_geo_antifraud_radius_m, v_row.geo_antifraud_radius_m, 150);
  v_target_location_id := COALESCE(p_location_id, v_row.location_id);

  IF v_geo_enabled THEN
    SELECT l.geo_coordinates
      INTO v_location_geo
    FROM data.locations l
    WHERE l.id = v_target_location_id;

    IF data.extract_geo_point(v_location_geo) IS NULL THEN
      RAISE EXCEPTION 'geo_antifraud_requires_location_geo' USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  v_status := COALESCE(p_status, v_row.status);
  IF v_status = 'active' THEN
    IF COALESCE(p_site_id, v_row.site_id) IS NULL
       OR v_target_location_id IS NULL
       OR v_row.device_secret_hash IS NULL
       OR v_row.local_pin_hash IS NULL THEN
      RAISE EXCEPTION 'active_requires_site_location_and_secrets' USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  UPDATE data.attendance_devices d
  SET
    name = COALESCE(NULLIF(btrim(p_name), ''), d.name),
    site_id = COALESCE(p_site_id, d.site_id),
    location_id = COALESCE(p_location_id, d.location_id),
    status = v_status,
    allowed_methods = COALESCE(p_allowed_methods, d.allowed_methods),
    geo_antifraud_enabled = v_geo_enabled,
    geo_antifraud_radius_m = v_geo_radius,
    updated_at = now()
  WHERE d.id = p_device_id;

  RETURN (
    SELECT jsonb_build_object(
      'device_id', d.id,
      'name', d.name,
      'site_id', d.site_id,
      'location_id', d.location_id,
      'status', d.status,
      'allowed_methods', d.allowed_methods,
      'geo_antifraud_enabled', d.geo_antifraud_enabled,
      'geo_antifraud_radius_m', d.geo_antifraud_radius_m,
      'location_path', data.build_location_path_snapshot(d.location_id)
    )
    FROM data.attendance_devices d
    WHERE d.id = p_device_id
  );
END;
$$;

REVOKE ALL ON FUNCTION api.update_attendance_station(
  uuid, text, uuid, uuid, text, text[], boolean, integer
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.update_attendance_station(
  uuid, text, uuid, uuid, text, text[], boolean, integer
) TO authenticated;

-- -----------------------------------------------------------------------------
-- record_station_time_punch — optional device_geo validation
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.record_station_time_punch(uuid, uuid, uuid, text, text, text);

CREATE OR REPLACE FUNCTION api.record_station_time_punch(
  p_device_id    uuid,
  p_employee_id  uuid,
  p_client_op_id uuid,
  p_punch_type   text,
  p_pause_type   text DEFAULT NULL,
  p_source       text DEFAULT 'station',
  p_device_geo   jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, pgmq
AS $$
DECLARE
  v_device           record;
  v_location_path    text;
  v_location_name    text;
  v_device_name      text;
  v_source           text;
  v_result           jsonb;
  v_location_geo     jsonb;
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

  RETURN v_result || jsonb_build_object(
    'location_id', v_device.location_id,
    'location_name', v_location_name,
    'device_name', v_device_name,
    'source', v_source
  );
END;
$$;

REVOKE ALL ON FUNCTION api.record_station_time_punch(uuid, uuid, uuid, text, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.record_station_time_punch(uuid, uuid, uuid, text, text, text, jsonb) TO service_role;

-- -----------------------------------------------------------------------------
-- Vista api.attendance_devices
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS api.attendance_devices;

CREATE VIEW api.attendance_devices
  WITH (security_invoker = true) AS
  SELECT
    id, tenant_id, site_id, location_id, name, device_public_id,
    type, status, last_seen_at, metadata,
    created_at, updated_at,
    allowed_methods,
    geo_antifraud_enabled,
    geo_antifraud_radius_m,
    data.build_location_path_snapshot(location_id) AS location_path
  FROM data.attendance_devices;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.attendance_devices TO authenticated;
GRANT SELECT ON data.attendance_devices TO authenticated;
