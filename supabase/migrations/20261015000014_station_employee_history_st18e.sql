-- EX-02.6 / ST-18e: kiosk employee history (read-only, PIN-gated, max 90 days).
-- PG-08: session_allow_history default false; history requires portal PIN re-auth.

-- -----------------------------------------------------------------------------
-- 1. Default: history disabled (PG-08)
-- -----------------------------------------------------------------------------

ALTER TABLE data.attendance_devices
  ALTER COLUMN session_allow_history SET DEFAULT false;

-- Feature was config-only until EX-02.6; align existing rows with the gate.
UPDATE data.attendance_devices
SET session_allow_history = false
WHERE type = 'station'
  AND session_allow_history IS DISTINCT FROM false;

COMMENT ON COLUMN data.attendance_devices.session_allow_history IS
  'EX-02.6/PG-08: allow read-only punch history inside kiosk employee session (opt-in; default false).';

COMMENT ON COLUMN data.attendance_devices.session_history_max_days IS
  'EX-02.6: max inclusive day span for GET employee-history (1–90).';

-- -----------------------------------------------------------------------------
-- 2. RPC: station-scoped employee history (service_role only)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.get_attendance_station_employee_history(
  p_device_id   uuid,
  p_employee_id uuid,
  p_from        date,
  p_to          date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_device record;
  v_employee record;
  v_today date;
  v_scope boolean;
  v_tz text;
  v_max_days int;
  v_span int;
  v_entries jsonb;
  v_punches jsonb;
BEGIN
  IF p_device_id IS NULL OR p_employee_id IS NULL THEN
    RAISE EXCEPTION 'device_and_employee_required' USING ERRCODE = 'check_violation';
  END IF;

  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from THEN
    RAISE EXCEPTION 'invalid_date_range' USING ERRCODE = 'check_violation';
  END IF;

  SELECT
    d.id,
    d.tenant_id,
    d.site_id,
    d.location_id,
    d.status,
    d.session_allow_history,
    d.session_history_max_days
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

  IF NOT COALESCE(v_device.session_allow_history, false) THEN
    RAISE EXCEPTION 'station_history_disabled' USING ERRCODE = 'check_violation';
  END IF;

  v_max_days := LEAST(90, GREATEST(1, COALESCE(v_device.session_history_max_days, 90)));
  v_span := (p_to - p_from) + 1;
  IF v_span > v_max_days THEN
    RAISE EXCEPTION 'station_history_range_too_large' USING ERRCODE = 'check_violation';
  END IF;

  SELECT e.id, e.tenant_id, e.site_id, e.status, e.full_name
    INTO v_employee
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND
     OR v_employee.status IS DISTINCT FROM 'active'
     OR v_employee.tenant_id IS DISTINCT FROM v_device.tenant_id
     OR v_employee.site_id IS DISTINCT FROM v_device.site_id THEN
    RAISE EXCEPTION 'employee_not_allowed' USING ERRCODE = 'check_violation';
  END IF;

  v_tz := data.get_site_timezone(v_device.site_id, v_device.tenant_id);
  v_today := (now() AT TIME ZONE v_tz)::date;
  v_scope := data.location_scope_has_attendance_assignments(v_device.location_id, v_today);
  IF v_scope AND NOT data.employee_can_punch_at_location(p_employee_id, v_device.location_id, v_today) THEN
    RAISE EXCEPTION 'employee_not_allowed' USING ERRCODE = 'check_violation';
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', te.id,
        'work_date', te.work_date,
        'starts_at', te.starts_at,
        'ends_at', te.ends_at,
        'net_minutes', te.net_minutes,
        'status', te.status
      )
      ORDER BY te.work_date DESC
    ),
    '[]'::jsonb
  )
  INTO v_entries
  FROM data.time_entries te
  WHERE te.employee_id = p_employee_id
    AND te.tenant_id = v_device.tenant_id
    AND te.work_date >= p_from
    AND te.work_date <= p_to;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', tp.id,
        'punch_type', tp.punch_type,
        'occurred_at', tp.occurred_at,
        'source', tp.source
      )
      ORDER BY tp.occurred_at ASC, tp.id ASC
    ),
    '[]'::jsonb
  )
  INTO v_punches
  FROM data.time_punches tp
  WHERE tp.employee_id = p_employee_id
    AND tp.tenant_id = v_device.tenant_id
    AND (tp.occurred_at AT TIME ZONE v_tz)::date >= p_from
    AND (tp.occurred_at AT TIME ZONE v_tz)::date <= p_to;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'full_name', v_employee.full_name,
    'from', p_from,
    'to', p_to,
    'max_days', v_max_days,
    'site_timezone', v_tz,
    'entries', v_entries,
    'punches', v_punches
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_attendance_station_employee_history(uuid, uuid, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_attendance_station_employee_history(uuid, uuid, date, date) TO service_role;

NOTIFY pgrst, 'reload schema';
