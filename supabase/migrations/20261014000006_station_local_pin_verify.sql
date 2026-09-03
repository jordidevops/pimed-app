-- ST-2b: verify local kiosk PIN with lockout (mirrors employee portal pin pattern)

ALTER TABLE data.attendance_devices
  ADD COLUMN IF NOT EXISTS local_pin_attempts int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS local_pin_locked_until timestamptz;

COMMENT ON COLUMN data.attendance_devices.local_pin_attempts IS
  'Failed local PIN attempts for kiosk unlock (ST-2b).';
COMMENT ON COLUMN data.attendance_devices.local_pin_locked_until IS
  'Lockout until timestamp after too many failed local PIN attempts (ST-2b).';

CREATE OR REPLACE FUNCTION api.verify_attendance_station_local_pin(
  p_device_id uuid,
  p_local_pin text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_row record;
  v_attempts int;
  v_locked_until timestamptz;
  v_threshold constant int := 5;
  v_lock_minutes constant int := 15;
BEGIN
  IF p_device_id IS NULL THEN
    RAISE EXCEPTION 'device_id_required' USING ERRCODE = 'check_violation';
  END IF;

  IF p_local_pin IS NULL OR p_local_pin !~ '^\d{4,6}$' THEN
    RETURN jsonb_build_object('status', 'invalid_format');
  END IF;

  SELECT
    d.id,
    d.local_pin_hash,
    d.local_pin_attempts,
    d.local_pin_locked_until
  INTO v_row
  FROM data.attendance_devices d
  WHERE d.id = p_device_id
    AND d.type = 'station'
  FOR UPDATE;

  IF NOT FOUND OR v_row.local_pin_hash IS NULL THEN
    RETURN jsonb_build_object('status', 'no_pin');
  END IF;

  IF v_row.local_pin_locked_until IS NOT NULL AND v_row.local_pin_locked_until <= now() THEN
    UPDATE data.attendance_devices
    SET local_pin_attempts = 0,
        local_pin_locked_until = NULL
    WHERE id = p_device_id;
    v_row.local_pin_attempts := 0;
    v_row.local_pin_locked_until := NULL;
  END IF;

  IF v_row.local_pin_locked_until IS NOT NULL AND v_row.local_pin_locked_until > now() THEN
    RETURN jsonb_build_object(
      'status', 'locked',
      'pin_attempts', v_row.local_pin_attempts,
      'retry_after_seconds', GREATEST(
        1,
        CEIL(EXTRACT(EPOCH FROM (v_row.local_pin_locked_until - now())))::int
      )
    );
  END IF;

  IF v_row.local_pin_hash = data.hash_attendance_station_pin(p_local_pin) THEN
    UPDATE data.attendance_devices
    SET local_pin_attempts = 0,
        local_pin_locked_until = NULL
    WHERE id = p_device_id;

    RETURN jsonb_build_object('status', 'ok', 'pin_attempts', 0);
  END IF;

  v_attempts := v_row.local_pin_attempts + 1;
  v_locked_until := NULL;

  IF v_attempts >= v_threshold THEN
    v_locked_until := now() + make_interval(mins => v_lock_minutes);
    v_attempts := v_threshold;
  END IF;

  UPDATE data.attendance_devices
  SET local_pin_attempts = v_attempts,
      local_pin_locked_until = v_locked_until
  WHERE id = p_device_id;

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

REVOKE ALL ON FUNCTION api.verify_attendance_station_local_pin(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.verify_attendance_station_local_pin(uuid, text) TO service_role;
