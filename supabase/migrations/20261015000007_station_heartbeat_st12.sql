-- EX-01.6 / ST-12: Heartbeat, connectivity status i salut mínima de flota.

-- -----------------------------------------------------------------------------
-- 1. Connectivity classifier
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.station_connectivity_status(
  p_last_seen_at   timestamptz,
  p_device_status  text DEFAULT 'active',
  p_stale_minutes  int DEFAULT 15,
  p_offline_minutes int DEFAULT 60
)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = data, public
AS $$
  SELECT CASE
    WHEN COALESCE(NULLIF(btrim(p_device_status), ''), 'pending') IS DISTINCT FROM 'active' THEN 'inactive'
    WHEN p_last_seen_at IS NULL THEN 'never_seen'
    WHEN p_last_seen_at >= now() - make_interval(mins => GREATEST(COALESCE(p_stale_minutes, 15), 1)) THEN 'online'
    WHEN p_last_seen_at >= now() - make_interval(mins => GREATEST(COALESCE(p_offline_minutes, 60), 1)) THEN 'stale'
    ELSE 'offline'
  END;
$$;

REVOKE ALL ON FUNCTION data.station_connectivity_status(timestamptz, text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.station_connectivity_status(timestamptz, text, int, int) TO service_role;

-- -----------------------------------------------------------------------------
-- 2. Touch last_seen (heartbeat)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.touch_attendance_station_seen(p_device_id uuid)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_seen timestamptz;
BEGIN
  UPDATE data.attendance_devices
  SET last_seen_at = now(),
      updated_at = now()
  WHERE id = p_device_id
  RETURNING last_seen_at INTO v_seen;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'device_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  RETURN v_seen;
END;
$$;

REVOKE ALL ON FUNCTION data.touch_attendance_station_seen(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.touch_attendance_station_seen(uuid) TO service_role;

CREATE OR REPLACE FUNCTION api.record_attendance_station_heartbeat(
  p_device_public_id text,
  p_device_secret    text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_ctx jsonb;
BEGIN
  v_ctx := api.verify_attendance_station_credentials(p_device_public_id, p_device_secret);

  RETURN jsonb_build_object(
    'device_id', v_ctx->>'device_id',
    'last_seen_at', v_ctx->>'last_seen_at',
    'connectivity_status', v_ctx->>'connectivity_status',
    'seconds_since_seen', COALESCE((v_ctx->>'seconds_since_seen')::int, 0)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.record_attendance_station_heartbeat(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.record_attendance_station_heartbeat(text, text) TO service_role;

-- -----------------------------------------------------------------------------
-- 3. verify_attendance_station_credentials — touch + health fields
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.verify_attendance_station_credentials(
  p_device_public_id text,
  p_device_secret    text
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_row record;
  v_location_geo jsonb;
  v_seen timestamptz;
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

  v_seen := data.touch_attendance_station_seen(v_row.id);
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
    'site_timezone', data.get_site_timezone(v_row.site_id, v_row.tenant_id),
    'last_seen_at', v_seen,
    'connectivity_status', data.station_connectivity_status(v_seen, v_row.status),
    'seconds_since_seen', GREATEST(0, floor(extract(epoch FROM (now() - v_seen))))::int
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 4. Fleet health (admin) — estacions + cua recompute
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.get_attendance_station_fleet_health(
  p_tenant_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid := COALESCE(p_tenant_id, data.active_tenant_id());
  v_counts jsonb;
  v_queue jsonb;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'check_violation';
  END IF;

  IF auth.uid() IS NOT NULL
     AND NOT data.jwt_has_permission(v_tenant_id, 'attendance.manage', NULL) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT jsonb_object_agg(status_key, cnt)
    INTO v_counts
  FROM (
    SELECT
      data.station_connectivity_status(d.last_seen_at, d.status) AS status_key,
      count(*)::int AS cnt
    FROM data.attendance_devices d
    WHERE d.tenant_id = v_tenant_id
      AND d.type = 'station'
    GROUP BY 1
  ) sub;

  BEGIN
    v_queue := api.get_attendance_queue_health();
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN
    v_queue := NULL;
  END;

  RETURN jsonb_build_object(
    'tenant_id', v_tenant_id,
    'station_counts', COALESCE(v_counts, '{}'::jsonb),
    'offline_stations', COALESCE(
      (
        SELECT jsonb_agg(jsonb_build_object(
          'device_id', d.id,
          'name', d.name,
          'site_id', d.site_id,
          'location_path', data.build_location_path_snapshot(d.location_id),
          'last_seen_at', d.last_seen_at,
          'connectivity_status', data.station_connectivity_status(d.last_seen_at, d.status)
        ) ORDER BY d.last_seen_at NULLS FIRST)
        FROM data.attendance_devices d
        WHERE d.tenant_id = v_tenant_id
          AND d.type = 'station'
          AND d.status = 'active'
          AND data.station_connectivity_status(d.last_seen_at, d.status) IN ('offline', 'never_seen', 'stale')
      ),
      '[]'::jsonb
    ),
    'queue_health', v_queue,
    'checked_at', now()
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_attendance_station_fleet_health(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_attendance_station_fleet_health(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_attendance_station_fleet_health(uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 5. Vista api.attendance_devices — connectivity_status
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
    display_title,
    display_logo_url,
    data.station_effective_display_title(name, display_title) AS effective_display_title,
    data.build_location_path_snapshot(location_id) AS location_path,
    data.station_connectivity_status(last_seen_at, status) AS connectivity_status
  FROM data.attendance_devices;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.attendance_devices TO authenticated;
GRANT SELECT ON data.attendance_devices TO authenticated;
