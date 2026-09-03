-- EX-02.4: station employee PIN challenge (portal_pin) with device-scoped lockout.
-- Reuses employee portal pin_hash; does NOT use portal token_id sessions (RX-A3).

-- -----------------------------------------------------------------------------
-- 1. Allow portal_pin on confirm fields
-- -----------------------------------------------------------------------------

ALTER TABLE data.attendance_devices
  DROP CONSTRAINT IF EXISTS attendance_devices_identity_confirm_check;
ALTER TABLE data.attendance_devices
  ADD CONSTRAINT attendance_devices_identity_confirm_check
  CHECK (identity_confirm IN ('none', 'tap_name', 'portal_pin'));

ALTER TABLE data.attendance_devices
  DROP CONSTRAINT IF EXISTS attendance_devices_qr_identity_confirm_check;
ALTER TABLE data.attendance_devices
  ADD CONSTRAINT attendance_devices_qr_identity_confirm_check
  CHECK (qr_identity_confirm IN ('none', 'tap_name', 'portal_pin'));

-- -----------------------------------------------------------------------------
-- 2. Device-scoped attempt lockout (separate from portal token lockout)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS data.station_employee_pin_challenges (
  device_id     uuid NOT NULL REFERENCES data.attendance_devices(id) ON DELETE CASCADE,
  employee_id   uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  pin_attempts  integer NOT NULL DEFAULT 0,
  locked_until  timestamptz,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (device_id, employee_id)
);

CREATE INDEX IF NOT EXISTS idx_station_employee_pin_challenges_locked
  ON data.station_employee_pin_challenges (locked_until)
  WHERE locked_until IS NOT NULL;

ALTER TABLE data.station_employee_pin_challenges ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "station_employee_pin_challenges: service_role"
  ON data.station_employee_pin_challenges;

CREATE POLICY "station_employee_pin_challenges: service_role"
  ON data.station_employee_pin_challenges
  FOR ALL TO service_role
  USING (true) WITH CHECK (true);

GRANT ALL ON data.station_employee_pin_challenges TO service_role;

COMMENT ON TABLE data.station_employee_pin_challenges IS
  'EX-02.4: lockout per estació+empleat per challenge PIN (independent del portal).';

-- Same hash format as edge hashPortalPin / tenant hashPortalPin.
CREATE OR REPLACE FUNCTION data.hash_employee_portal_pin(p_pin text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT 'sha256:' || encode(
    extensions.digest(convert_to('employee-portal-pin:' || p_pin, 'UTF8'), 'sha256'),
    'hex'
  );
$$;

REVOKE ALL ON FUNCTION data.hash_employee_portal_pin(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.hash_employee_portal_pin(text) TO service_role;

-- -----------------------------------------------------------------------------
-- 3. Verify employee PIN at station
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.verify_attendance_station_employee_pin(
  p_device_id   uuid,
  p_employee_id uuid,
  p_pin         text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_device record;
  v_employee record;
  v_token record;
  v_challenge record;
  v_today date;
  v_scope boolean;
  v_attempts int;
  v_locked_until timestamptz;
  v_threshold constant int := 5;
  v_lock_minutes constant int := 15;
  v_pin_hash text;
BEGIN
  IF p_device_id IS NULL OR p_employee_id IS NULL THEN
    RAISE EXCEPTION 'device_and_employee_required' USING ERRCODE = 'check_violation';
  END IF;

  IF p_pin IS NULL OR p_pin !~ '^\d{4,6}$' THEN
    RETURN jsonb_build_object('status', 'invalid_format');
  END IF;

  SELECT
    d.id,
    d.tenant_id,
    d.site_id,
    d.location_id,
    d.status
  INTO v_device
  FROM data.attendance_devices d
  WHERE d.id = p_device_id
    AND d.type = 'station';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'device_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_device.status IS DISTINCT FROM 'active'
     OR v_device.site_id IS NULL
     OR v_device.location_id IS NULL THEN
    RAISE EXCEPTION 'station_not_ready' USING ERRCODE = 'check_violation';
  END IF;

  SELECT e.id, e.tenant_id, e.site_id, e.status
    INTO v_employee
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND
     OR v_employee.status IS DISTINCT FROM 'active'
     OR v_employee.tenant_id IS DISTINCT FROM v_device.tenant_id
     OR v_employee.site_id IS DISTINCT FROM v_device.site_id THEN
    RETURN jsonb_build_object('status', 'employee_not_allowed');
  END IF;

  v_today := (now() AT TIME ZONE data.get_site_timezone(v_device.site_id, v_device.tenant_id))::date;
  v_scope := data.location_scope_has_attendance_assignments(v_device.location_id, v_today);
  IF v_scope AND NOT data.employee_can_punch_at_location(p_employee_id, v_device.location_id, v_today) THEN
    RETURN jsonb_build_object('status', 'employee_not_allowed');
  END IF;

  SELECT t.id, t.pin_hash, t.pin_must_set
    INTO v_token
  FROM data.employee_portal_tokens t
  WHERE t.employee_id = p_employee_id
    AND t.tenant_id = v_device.tenant_id
    AND t.is_active
    AND t.revoked_at IS NULL
    AND t.pin_hash IS NOT NULL
    AND NOT COALESCE(t.pin_must_set, false)
  ORDER BY t.created_at DESC NULLS LAST
  LIMIT 1;

  IF NOT FOUND OR v_token.pin_hash IS NULL THEN
    RETURN jsonb_build_object('status', 'no_pin');
  END IF;

  INSERT INTO data.station_employee_pin_challenges (device_id, employee_id)
  VALUES (p_device_id, p_employee_id)
  ON CONFLICT (device_id, employee_id) DO NOTHING;

  SELECT c.pin_attempts, c.locked_until
    INTO v_challenge
  FROM data.station_employee_pin_challenges c
  WHERE c.device_id = p_device_id
    AND c.employee_id = p_employee_id
  FOR UPDATE;

  IF v_challenge.locked_until IS NOT NULL AND v_challenge.locked_until <= now() THEN
    UPDATE data.station_employee_pin_challenges
    SET pin_attempts = 0,
        locked_until = NULL,
        updated_at = now()
    WHERE device_id = p_device_id
      AND employee_id = p_employee_id;
    v_challenge.pin_attempts := 0;
    v_challenge.locked_until := NULL;
  END IF;

  IF v_challenge.locked_until IS NOT NULL AND v_challenge.locked_until > now() THEN
    RETURN jsonb_build_object(
      'status', 'locked',
      'pin_attempts', v_challenge.pin_attempts,
      'retry_after_seconds', GREATEST(
        1,
        CEIL(EXTRACT(EPOCH FROM (v_challenge.locked_until - now())))::int
      )
    );
  END IF;

  v_pin_hash := data.hash_employee_portal_pin(p_pin);

  IF v_token.pin_hash = v_pin_hash THEN
    UPDATE data.station_employee_pin_challenges
    SET pin_attempts = 0,
        locked_until = NULL,
        updated_at = now()
    WHERE device_id = p_device_id
      AND employee_id = p_employee_id;

    RETURN jsonb_build_object('status', 'ok', 'pin_attempts', 0);
  END IF;

  v_attempts := COALESCE(v_challenge.pin_attempts, 0) + 1;
  v_locked_until := NULL;
  IF v_attempts >= v_threshold THEN
    v_locked_until := now() + make_interval(mins => v_lock_minutes);
    v_attempts := v_threshold;
  END IF;

  UPDATE data.station_employee_pin_challenges
  SET pin_attempts = v_attempts,
      locked_until = v_locked_until,
      updated_at = now()
  WHERE device_id = p_device_id
    AND employee_id = p_employee_id;

  IF v_locked_until IS NOT NULL THEN
    RETURN jsonb_build_object(
      'status', 'locked',
      'pin_attempts', v_attempts,
      'retry_after_seconds', GREATEST(
        1,
        CEIL(EXTRACT(EPOCH FROM (v_locked_until - now())))::int
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'status', 'invalid',
    'pin_attempts', v_attempts
  );
END;
$$;

REVOKE ALL ON FUNCTION api.verify_attendance_station_employee_pin(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.verify_attendance_station_employee_pin(uuid, uuid, text) TO service_role;

COMMENT ON FUNCTION api.verify_attendance_station_employee_pin(uuid, uuid, text) IS
  'EX-02.4: challenge PIN empleat a l''estació (hash portal, lockout per device+employee).';
