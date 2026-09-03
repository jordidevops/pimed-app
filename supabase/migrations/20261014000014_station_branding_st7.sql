-- ST-7: branding per estació (títol i logo personalitzats al kiosk)

ALTER TABLE data.attendance_devices
  ADD COLUMN IF NOT EXISTS display_title text,
  ADD COLUMN IF NOT EXISTS display_logo_url text;

ALTER TABLE data.attendance_devices
  DROP CONSTRAINT IF EXISTS attendance_devices_display_title_len_check;

ALTER TABLE data.attendance_devices
  ADD CONSTRAINT attendance_devices_display_title_len_check
  CHECK (display_title IS NULL OR char_length(display_title) <= 120);

ALTER TABLE data.attendance_devices
  DROP CONSTRAINT IF EXISTS attendance_devices_display_logo_url_len_check;

ALTER TABLE data.attendance_devices
  ADD CONSTRAINT attendance_devices_display_logo_url_len_check
  CHECK (display_logo_url IS NULL OR char_length(display_logo_url) <= 2048);

COMMENT ON COLUMN data.attendance_devices.display_title IS
  'Títol visible al kiosk. Si NULL, es mostra name.';
COMMENT ON COLUMN data.attendance_devices.display_logo_url IS
  'URL pública del logo (p.ex. bucket public-assets). Opcional.';

CREATE OR REPLACE FUNCTION data.station_effective_display_title(
  p_name          text,
  p_display_title text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT COALESCE(NULLIF(btrim(p_display_title), ''), NULLIF(btrim(p_name), ''), 'Estació');
$$;

REVOKE ALL ON FUNCTION data.station_effective_display_title(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.station_effective_display_title(text, text) TO service_role;

-- -----------------------------------------------------------------------------
-- verify_attendance_station_credentials — branding fields
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
    'location_has_geo', data.extract_geo_point(v_location_geo) IS NOT NULL
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- update_attendance_station — branding (extends ST-8 audit version)
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.update_attendance_station(
  uuid, text, uuid, uuid, text, text[], boolean, integer
);

CREATE OR REPLACE FUNCTION api.update_attendance_station(
  p_device_id              uuid,
  p_name                   text DEFAULT NULL,
  p_site_id                uuid DEFAULT NULL,
  p_location_id            uuid DEFAULT NULL,
  p_status                 text DEFAULT NULL,
  p_allowed_methods        text[] DEFAULT NULL,
  p_geo_antifraud_enabled  boolean DEFAULT NULL,
  p_geo_antifraud_radius_m integer DEFAULT NULL,
  p_display_title          text DEFAULT NULL,
  p_display_logo_url       text DEFAULT NULL
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
  v_new_name text;
  v_new_site_id uuid;
  v_new_location_id uuid;
  v_new_allowed_methods text[];
  v_new_display_title text;
  v_new_display_logo_url text;
  v_changes jsonb := '[]'::jsonb;
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

  IF p_display_title IS NOT NULL AND char_length(btrim(p_display_title)) > 120 THEN
    RAISE EXCEPTION 'display_title_too_long' USING ERRCODE = 'check_violation';
  END IF;

  IF p_display_logo_url IS NOT NULL AND char_length(btrim(p_display_logo_url)) > 2048 THEN
    RAISE EXCEPTION 'display_logo_url_too_long' USING ERRCODE = 'check_violation';
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

  v_new_name := COALESCE(NULLIF(btrim(p_name), ''), v_row.name);
  v_new_site_id := COALESCE(p_site_id, v_row.site_id);
  v_new_location_id := COALESCE(p_location_id, v_row.location_id);
  v_new_allowed_methods := COALESCE(p_allowed_methods, v_row.allowed_methods);
  v_new_display_title := CASE
    WHEN p_display_title IS NOT NULL THEN NULLIF(btrim(p_display_title), '')
    ELSE v_row.display_title
  END;
  v_new_display_logo_url := CASE
    WHEN p_display_logo_url IS NOT NULL THEN NULLIF(btrim(p_display_logo_url), '')
    ELSE v_row.display_logo_url
  END;

  IF v_row.name IS DISTINCT FROM v_new_name THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'name', 'old', to_jsonb(v_row.name), 'new', to_jsonb(v_new_name)
    ));
  END IF;

  IF v_row.site_id IS DISTINCT FROM v_new_site_id THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'site_id', 'old', to_jsonb(v_row.site_id), 'new', to_jsonb(v_new_site_id)
    ));
  END IF;

  IF v_row.location_id IS DISTINCT FROM v_new_location_id THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'location_id',
      'old', to_jsonb(v_row.location_id),
      'new', to_jsonb(v_new_location_id),
      'old_location_path', to_jsonb(data.build_location_path_snapshot(v_row.location_id)),
      'new_location_path', to_jsonb(data.build_location_path_snapshot(v_new_location_id))
    ));
  END IF;

  IF v_row.status IS DISTINCT FROM v_status THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'status', 'old', to_jsonb(v_row.status), 'new', to_jsonb(v_status)
    ));
  END IF;

  IF v_row.allowed_methods IS DISTINCT FROM v_new_allowed_methods THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'allowed_methods',
      'old', to_jsonb(v_row.allowed_methods),
      'new', to_jsonb(v_new_allowed_methods)
    ));
  END IF;

  IF COALESCE(v_row.geo_antifraud_enabled, false) IS DISTINCT FROM v_geo_enabled THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'geo_antifraud_enabled',
      'old', to_jsonb(COALESCE(v_row.geo_antifraud_enabled, false)),
      'new', to_jsonb(v_geo_enabled)
    ));
  END IF;

  IF COALESCE(v_row.geo_antifraud_radius_m, 150) IS DISTINCT FROM v_geo_radius THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'geo_antifraud_radius_m',
      'old', to_jsonb(COALESCE(v_row.geo_antifraud_radius_m, 150)),
      'new', to_jsonb(v_geo_radius)
    ));
  END IF;

  IF v_row.display_title IS DISTINCT FROM v_new_display_title THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'display_title',
      'old', to_jsonb(v_row.display_title),
      'new', to_jsonb(v_new_display_title)
    ));
  END IF;

  IF v_row.display_logo_url IS DISTINCT FROM v_new_display_logo_url THEN
    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'field', 'display_logo_url',
      'old', to_jsonb(v_row.display_logo_url),
      'new', to_jsonb(v_new_display_logo_url)
    ));
  END IF;

  UPDATE data.attendance_devices d
  SET
    name = v_new_name,
    site_id = v_new_site_id,
    location_id = v_new_location_id,
    status = v_status,
    allowed_methods = v_new_allowed_methods,
    geo_antifraud_enabled = v_geo_enabled,
    geo_antifraud_radius_m = v_geo_radius,
    display_title = v_new_display_title,
    display_logo_url = v_new_display_logo_url,
    updated_at = now()
  WHERE d.id = p_device_id;

  IF jsonb_array_length(v_changes) > 0 THEN
    PERFORM data.log_audit_event(
      v_row.tenant_id,
      auth.uid(),
      v_new_site_id,
      'ATTENDANCE_STATION_UPDATED',
      'attendance_device',
      p_device_id,
      jsonb_build_object(
        'device_id', p_device_id,
        'name', v_new_name,
        'changes', v_changes
      )
    );
  END IF;

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
      'display_title', d.display_title,
      'display_logo_url', d.display_logo_url,
      'effective_display_title', data.station_effective_display_title(d.name, d.display_title),
      'location_path', data.build_location_path_snapshot(d.location_id)
    )
    FROM data.attendance_devices d
    WHERE d.id = p_device_id
  );
END;
$$;

REVOKE ALL ON FUNCTION api.update_attendance_station(
  uuid, text, uuid, uuid, text, text[], boolean, integer, text, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.update_attendance_station(
  uuid, text, uuid, uuid, text, text[], boolean, integer, text, text
) TO authenticated;

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
    display_title,
    display_logo_url,
    data.station_effective_display_title(name, display_title) AS effective_display_title,
    data.build_location_path_snapshot(location_id) AS location_path
  FROM data.attendance_devices;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.attendance_devices TO authenticated;
GRANT SELECT ON data.attendance_devices TO authenticated;
