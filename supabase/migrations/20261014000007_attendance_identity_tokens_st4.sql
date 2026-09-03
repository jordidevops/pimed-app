-- ST-4: tokens d'identitat signats (QR) per estacions — issue / resolve one-time

CREATE TABLE IF NOT EXISTS data.attendance_identity_tokens (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id     uuid        NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  method          text        NOT NULL CHECK (method IN ('qr', 'barcode')),
  token_hash      bytea       NOT NULL UNIQUE,
  expires_at      timestamptz NOT NULL,
  used_at         timestamptz,
  used_device_id  uuid        REFERENCES data.attendance_devices(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_attendance_identity_tokens_employee_created
  ON data.attendance_identity_tokens (employee_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_attendance_identity_tokens_expires
  ON data.attendance_identity_tokens (expires_at)
  WHERE used_at IS NULL;

ALTER TABLE data.attendance_identity_tokens ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "attendance_identity_tokens: service_role full access"
  ON data.attendance_identity_tokens;

CREATE POLICY "attendance_identity_tokens: service_role full access"
  ON data.attendance_identity_tokens FOR ALL TO service_role
  USING (true) WITH CHECK (true);

GRANT ALL ON data.attendance_identity_tokens TO service_role;

COMMENT ON TABLE data.attendance_identity_tokens IS
  'Tokens d''identitat d''un sol ús per QR/barcode a estacions (ST-4).';

-- Rate limit resolve (30 / 15 min per device+IP)
CREATE OR REPLACE FUNCTION api.assert_station_identity_resolve_rate_limit(
  p_client_key      text,
  p_max_attempts    int DEFAULT 30,
  p_window_minutes  int DEFAULT 15
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_key text := COALESCE(NULLIF(btrim(p_client_key), ''), 'unknown');
BEGIN
  IF char_length(v_key) > 128 THEN
    v_key := left(v_key, 128);
  END IF;
  RETURN api.assert_station_register_rate_limit(v_key, p_max_attempts, p_window_minutes);
END;
$$;

REVOKE ALL ON FUNCTION api.assert_station_identity_resolve_rate_limit(text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.assert_station_identity_resolve_rate_limit(text, int, int) TO service_role;

CREATE OR REPLACE FUNCTION data.build_attendance_identity_token_raw()
RETURNS text
LANGUAGE sql
VOLATILE
SET search_path = extensions, public
AS $$
  SELECT translate(encode(gen_random_bytes(32), 'base64'), '+/=', '-_');
$$;

CREATE OR REPLACE FUNCTION api.issue_attendance_identity_token(
  p_employee_id uuid,
  p_method      text DEFAULT 'qr'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_employee record;
  v_method   text;
  v_raw      text;
  v_hash     bytea;
  v_expires  timestamptz;
  v_id       uuid;
  v_ttl_min  int := 5;
BEGIN
  IF p_employee_id IS NULL THEN
    RAISE EXCEPTION 'employee_id_required' USING ERRCODE = 'check_violation';
  END IF;

  v_method := lower(btrim(COALESCE(p_method, 'qr')));
  IF v_method NOT IN ('qr', 'barcode') THEN
    RAISE EXCEPTION 'invalid_identity_method' USING ERRCODE = 'check_violation';
  END IF;

  SELECT e.id, e.tenant_id, e.status
    INTO v_employee
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND OR v_employee.status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  v_raw := data.build_attendance_identity_token_raw();
  v_hash := digest(v_raw, 'sha256');
  v_expires := now() + make_interval(mins => v_ttl_min);

  INSERT INTO data.attendance_identity_tokens (
    tenant_id, employee_id, method, token_hash, expires_at
  ) VALUES (
    v_employee.tenant_id, p_employee_id, v_method, v_hash, v_expires
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'token_id', v_id,
    'token', v_raw,
    'method', v_method,
    'expires_at', v_expires,
    'ttl_seconds', v_ttl_min * 60
  );
END;
$$;

REVOKE ALL ON FUNCTION api.issue_attendance_identity_token(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.issue_attendance_identity_token(uuid, text) TO service_role;

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
  v_device   record;
  v_row      record;
  v_hash     bytea;
  v_today    date := (now() AT TIME ZONE 'Europe/Madrid')::date;
  v_day_state text;
  v_next     text;
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

  v_hash := digest(btrim(p_token), 'sha256');

  SELECT t.*, e.full_name
    INTO v_row
  FROM data.attendance_identity_tokens t
  JOIN data.employees e ON e.id = t.employee_id
  WHERE t.token_hash = v_hash
  FOR UPDATE OF t;

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

  UPDATE data.attendance_identity_tokens
  SET used_at = now(), used_device_id = v_device.id
  WHERE id = v_row.id;

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
    'token_id', v_row.id
  );
END;
$$;

REVOKE ALL ON FUNCTION api.resolve_attendance_identity_token(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.resolve_attendance_identity_token(text, text) TO service_role;

-- Punch des d'estació amb source station | qr + validació allowed_methods
DROP FUNCTION IF EXISTS api.record_station_time_punch(uuid, uuid, uuid, text, text);

CREATE OR REPLACE FUNCTION api.record_station_time_punch(
  p_device_id    uuid,
  p_employee_id  uuid,
  p_client_op_id uuid,
  p_punch_type   text,
  p_pause_type   text DEFAULT NULL,
  p_source       text DEFAULT 'station'
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
BEGIN
  v_source := lower(btrim(COALESCE(p_source, 'station')));
  IF v_source NOT IN ('station', 'qr') THEN
    RAISE EXCEPTION 'invalid_station_punch_source' USING ERRCODE = 'check_violation';
  END IF;

  SELECT d.*, l.name AS location_name
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

REVOKE ALL ON FUNCTION api.record_station_time_punch(uuid, uuid, uuid, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.record_station_time_punch(uuid, uuid, uuid, text, text, text) TO service_role;
