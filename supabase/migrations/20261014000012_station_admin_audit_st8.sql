-- ST-8: auditoria accions admin sobre estacions (separat de l'historial de fitxatges ST-6)

-- -----------------------------------------------------------------------------
-- api.create_attendance_station_pairing_code — audit pairing code created
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.create_attendance_station_pairing_code(
  p_site_id     uuid DEFAULT NULL,
  p_location_id uuid DEFAULT NULL,
  p_ttl_minutes int  DEFAULT 15
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_tenant_id    uuid := data.active_tenant_id();
  v_site         record;
  v_location     record;
  v_code         text;
  v_code_hash    bytea;
  v_expires_at   timestamptz;
  v_id           uuid;
  v_ttl_minutes  int;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'check_violation';
  END IF;

  IF NOT (
    (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    OR data.jwt_has_permission(v_tenant_id, 'attendance.devices.manage')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_site_id IS NOT NULL THEN
    SELECT id, tenant_id INTO v_site FROM data.sites WHERE id = p_site_id;
    IF NOT FOUND OR v_site.tenant_id IS DISTINCT FROM v_tenant_id THEN
      RAISE EXCEPTION 'site_not_found' USING ERRCODE = 'no_data_found';
    END IF;
  END IF;

  IF p_location_id IS NOT NULL THEN
    SELECT id, tenant_id, site_id INTO v_location FROM data.locations WHERE id = p_location_id;
    IF NOT FOUND OR v_location.tenant_id IS DISTINCT FROM v_tenant_id THEN
      RAISE EXCEPTION 'location_not_found' USING ERRCODE = 'no_data_found';
    END IF;
    IF p_site_id IS NOT NULL AND v_location.site_id IS DISTINCT FROM p_site_id THEN
      RAISE EXCEPTION 'location_site_mismatch' USING ERRCODE = 'check_violation';
    END IF;
    p_site_id := COALESCE(p_site_id, v_location.site_id);
  END IF;

  v_ttl_minutes := GREATEST(5, LEAST(COALESCE(p_ttl_minutes, 15), 60));
  v_expires_at := now() + make_interval(mins => v_ttl_minutes);

  LOOP
    v_code := upper(substr(encode(extensions.gen_random_bytes(6), 'hex'), 1, 8));
    v_code_hash := digest(v_code, 'sha256');
    BEGIN
      INSERT INTO data.attendance_device_pairing_codes (
        tenant_id, site_id, location_id, code_hash, expires_at, created_by
      ) VALUES (
        v_tenant_id, p_site_id, p_location_id, v_code_hash, v_expires_at, auth.uid()
      )
      RETURNING id INTO v_id;
      EXIT;
    EXCEPTION WHEN unique_violation THEN
      NULL;
    END;
  END LOOP;

  PERFORM data.log_audit_event(
    v_tenant_id,
    auth.uid(),
    p_site_id,
    'ATTENDANCE_STATION_PAIRING_CODE_CREATED',
    'attendance_station_pairing_code',
    v_id,
    jsonb_build_object(
      'pairing_code_id', v_id,
      'site_id', p_site_id,
      'location_id', p_location_id,
      'location_path', data.build_location_path_snapshot(p_location_id),
      'expires_at', v_expires_at,
      'ttl_minutes', v_ttl_minutes
    )
  );

  RETURN jsonb_build_object(
    'pairing_code_id', v_id,
    'code', v_code,
    'expires_at', v_expires_at,
    'site_id', p_site_id,
    'location_id', p_location_id
  );
END;
$$;

REVOKE ALL ON FUNCTION api.create_attendance_station_pairing_code(uuid, uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_attendance_station_pairing_code(uuid, uuid, int) TO authenticated;

-- -----------------------------------------------------------------------------
-- api.register_attendance_device — audit station registered (actor = code creator)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.register_attendance_device(
  p_pairing_code      text,
  p_device_public_id  text,
  p_device_secret     text,
  p_local_pin         text,
  p_name              text DEFAULT NULL,
  p_metadata          jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_code_norm    text;
  v_code_hash    bytea;
  v_pairing      record;
  v_device_id    uuid;
  v_name         text;
BEGIN
  v_code_norm := data.normalize_attendance_pairing_code(p_pairing_code);
  IF length(v_code_norm) < 6 THEN
    RAISE EXCEPTION 'invalid_pairing_code' USING ERRCODE = 'check_violation';
  END IF;

  IF p_device_public_id IS NULL OR btrim(p_device_public_id) = '' THEN
    RAISE EXCEPTION 'device_public_id_required' USING ERRCODE = 'check_violation';
  END IF;

  IF p_device_secret IS NULL OR length(p_device_secret) < 16 THEN
    RAISE EXCEPTION 'device_secret_too_short' USING ERRCODE = 'check_violation';
  END IF;

  IF p_local_pin IS NULL OR p_local_pin !~ '^\d{4,6}$' THEN
    RAISE EXCEPTION 'invalid_local_pin' USING ERRCODE = 'check_violation';
  END IF;

  v_code_hash := digest(v_code_norm, 'sha256');

  SELECT *
    INTO v_pairing
  FROM data.attendance_device_pairing_codes c
  WHERE c.code_hash = v_code_hash
    AND c.used_at IS NULL
    AND c.expires_at > now()
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'pairing_code_invalid_or_expired' USING ERRCODE = 'check_violation';
  END IF;

  v_name := COALESCE(NULLIF(btrim(p_name), ''), 'Estació ' || left(p_device_public_id, 8));

  INSERT INTO data.attendance_devices (
    tenant_id,
    site_id,
    location_id,
    name,
    device_public_id,
    device_secret_hash,
    local_pin_hash,
    type,
    status,
    metadata
  ) VALUES (
    v_pairing.tenant_id,
    v_pairing.site_id,
    v_pairing.location_id,
    v_name,
    btrim(p_device_public_id),
    data.hash_attendance_device_secret(p_device_secret),
    data.hash_attendance_station_pin(p_local_pin),
    'station',
    'pending',
    COALESCE(p_metadata, '{}'::jsonb)
  )
  RETURNING id INTO v_device_id;

  UPDATE data.attendance_device_pairing_codes
  SET used_at = now(), used_device_id = v_device_id
  WHERE id = v_pairing.id;

  PERFORM data.log_audit_event(
    v_pairing.tenant_id,
    v_pairing.created_by,
    v_pairing.site_id,
    'ATTENDANCE_STATION_REGISTERED',
    'attendance_device',
    v_device_id,
    jsonb_build_object(
      'device_id', v_device_id,
      'device_public_id', btrim(p_device_public_id),
      'name', v_name,
      'pairing_code_id', v_pairing.id,
      'site_id', v_pairing.site_id,
      'location_id', v_pairing.location_id,
      'location_path', data.build_location_path_snapshot(v_pairing.location_id),
      'status', 'pending'
    )
  );

  RETURN jsonb_build_object(
    'device_id', v_device_id,
    'tenant_id', v_pairing.tenant_id,
    'site_id', v_pairing.site_id,
    'location_id', v_pairing.location_id,
    'status', 'pending',
    'device_public_id', btrim(p_device_public_id)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.register_attendance_device(text, text, text, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.register_attendance_device(text, text, text, text, text, jsonb) TO service_role;

-- -----------------------------------------------------------------------------
-- api.update_attendance_station — audit only when fields change
-- -----------------------------------------------------------------------------
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
  v_new_name text;
  v_new_site_id uuid;
  v_new_location_id uuid;
  v_new_allowed_methods text[];
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

  UPDATE data.attendance_devices d
  SET
    name = v_new_name,
    site_id = v_new_site_id,
    location_id = v_new_location_id,
    status = v_status,
    allowed_methods = v_new_allowed_methods,
    geo_antifraud_enabled = v_geo_enabled,
    geo_antifraud_radius_m = v_geo_radius,
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
-- api.revoke_attendance_station_secret — audit secret revoked
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.revoke_attendance_station_secret(p_device_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_row record;
BEGIN
  SELECT * INTO v_row FROM data.attendance_devices WHERE id = p_device_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'device_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT (
    (data.jwt_user_tenants() -> v_row.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    OR data.jwt_has_permission(v_row.tenant_id, 'attendance.devices.manage')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.attendance_devices
  SET
    device_secret_hash = NULL,
    status = 'pending',
    updated_at = now()
  WHERE id = p_device_id;

  PERFORM data.log_audit_event(
    v_row.tenant_id,
    auth.uid(),
    v_row.site_id,
    'ATTENDANCE_STATION_SECRET_REVOKED',
    'attendance_device',
    p_device_id,
    jsonb_build_object(
      'device_id', p_device_id,
      'name', v_row.name,
      'device_public_id', v_row.device_public_id,
      'previous_status', v_row.status,
      'new_status', 'pending'
    )
  );

  RETURN jsonb_build_object('device_id', p_device_id, 'status', 'pending', 'secret_revoked', true);
END;
$$;

REVOKE ALL ON FUNCTION api.revoke_attendance_station_secret(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.revoke_attendance_station_secret(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- api.list_attendance_station_admin_audit_logs
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.list_attendance_station_admin_audit_logs(
  p_device_id uuid,
  p_limit     int DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_device record;
  v_limit  int;
  v_rows   jsonb;
BEGIN
  SELECT d.id, d.tenant_id
    INTO v_device
  FROM data.attendance_devices d
  WHERE d.id = p_device_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'device_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT (
    (data.jwt_user_tenants() -> v_device.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    OR data.jwt_has_permission(v_device.tenant_id, 'attendance.devices.manage')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_limit := GREATEST(1, LEAST(COALESCE(p_limit, 100), 500));

  SELECT COALESCE(jsonb_agg(row_data ORDER BY created_at DESC), '[]'::jsonb)
    INTO v_rows
  FROM (
    SELECT
      jsonb_build_object(
        'id', al.id,
        'action', al.action,
        'created_at', al.created_at,
        'user_id', al.user_id,
        'user_name', pr.full_name,
        'payload', al.payload
      ) AS row_data,
      al.created_at
    FROM data.audit_logs al
    LEFT JOIN data.profiles pr ON pr.id = al.user_id
    WHERE al.tenant_id = v_device.tenant_id
      AND (
        (al.entity_type = 'attendance_device' AND al.entity_id = p_device_id)
        OR (
          al.entity_type = 'attendance_station_pairing_code'
          AND al.entity_id IN (
            SELECT pc.id
            FROM data.attendance_device_pairing_codes pc
            WHERE pc.used_device_id = p_device_id
          )
        )
      )
    ORDER BY al.created_at DESC
    LIMIT v_limit
  ) sub;

  RETURN v_rows;
END;
$$;

REVOKE ALL ON FUNCTION api.list_attendance_station_admin_audit_logs(uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_attendance_station_admin_audit_logs(uuid, int) TO authenticated;
