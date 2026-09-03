-- ST-2a: assignacions empleat↔zona per fitxatge d'estació
-- Helpers, CRUD RPCs tenant-portal, filtre estació + validació punch.

-- -----------------------------------------------------------------------------
-- 1. Helpers
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.location_ancestor_ids(p_location_id uuid)
RETURNS uuid[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
  WITH RECURSIVE chain AS (
    SELECT id, parent_id, 0 AS level
    FROM data.locations
    WHERE id = p_location_id
    UNION ALL
    SELECT l.id, l.parent_id, c.level + 1
    FROM data.locations l
    JOIN chain c ON l.id = c.parent_id
  )
  SELECT COALESCE(array_agg(id ORDER BY level ASC), ARRAY[]::uuid[])
  FROM chain;
$$;

REVOKE ALL ON FUNCTION data.location_ancestor_ids(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.location_ancestor_ids(uuid) TO service_role;

CREATE OR REPLACE FUNCTION data.attendance_location_assignment_active(
  p_starts_on date,
  p_ends_on   date,
  p_on        date DEFAULT CURRENT_DATE
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT (p_starts_on IS NULL OR p_starts_on <= p_on)
     AND (p_ends_on IS NULL OR p_ends_on >= p_on);
$$;

REVOKE ALL ON FUNCTION data.attendance_location_assignment_active(date, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.attendance_location_assignment_active(date, date, date) TO service_role;

CREATE OR REPLACE FUNCTION data.location_scope_has_attendance_assignments(
  p_location_id uuid,
  p_on          date DEFAULT CURRENT_DATE
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM data.attendance_location_assignments ala
    WHERE ala.location_id = ANY(data.location_ancestor_ids(p_location_id))
      AND data.attendance_location_assignment_active(ala.starts_on, ala.ends_on, p_on)
  );
$$;

REVOKE ALL ON FUNCTION data.location_scope_has_attendance_assignments(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.location_scope_has_attendance_assignments(uuid, date) TO service_role;

CREATE OR REPLACE FUNCTION data.employee_can_punch_at_location(
  p_employee_id uuid,
  p_location_id uuid,
  p_on          date DEFAULT CURRENT_DATE
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM data.attendance_location_assignments ala
    WHERE ala.employee_id = p_employee_id
      AND ala.location_id = ANY(data.location_ancestor_ids(p_location_id))
      AND data.attendance_location_assignment_active(ala.starts_on, ala.ends_on, p_on)
  );
$$;

REVOKE ALL ON FUNCTION data.employee_can_punch_at_location(uuid, uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.employee_can_punch_at_location(uuid, uuid, date) TO service_role;

-- -----------------------------------------------------------------------------
-- 2. Permission helper (tenant-portal CRUD)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.assert_attendance_location_manage_privilege(p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT (
    (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    OR data.jwt_has_permission(p_tenant_id, 'attendance.devices.manage')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION data.assert_attendance_location_manage_privilege(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.assert_attendance_location_manage_privilege(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. API RPCs — CRUD assignacions des de /locations
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.list_attendance_location_assignments(p_location_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_location record;
  v_today    date := (now() AT TIME ZONE 'Europe/Madrid')::date;
  v_rows     jsonb;
  v_scope    boolean;
  v_assigned int;
  v_site_cnt int;
BEGIN
  SELECT l.id, l.tenant_id, l.site_id
    INTO v_location
  FROM data.locations l
  WHERE l.id = p_location_id
    AND (data.active_tenant_id() IS NULL OR l.tenant_id = data.active_tenant_id());

  IF NOT FOUND THEN
    RAISE EXCEPTION 'location_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  PERFORM data.assert_attendance_location_manage_privilege(v_location.tenant_id);

  v_scope := data.location_scope_has_attendance_assignments(p_location_id, v_today);

  SELECT COALESCE(jsonb_agg(row_data ORDER BY sort_name), '[]'::jsonb)
    INTO v_rows
  FROM (
    SELECT
      jsonb_build_object(
        'id', ala.id,
        'employee_id', ala.employee_id,
        'full_name', e.full_name,
        'location_id', ala.location_id,
        'starts_on', ala.starts_on,
        'ends_on', ala.ends_on,
        'created_at', ala.created_at,
        'inherited', false
      ) AS row_data,
      e.full_name AS sort_name
    FROM data.attendance_location_assignments ala
    JOIN data.employees e ON e.id = ala.employee_id
    WHERE ala.location_id = p_location_id
      AND data.attendance_location_assignment_active(ala.starts_on, ala.ends_on, v_today)
  ) sub;

  SELECT count(*)::int
    INTO v_assigned
  FROM data.attendance_location_assignments ala
  WHERE ala.location_id = p_location_id
    AND data.attendance_location_assignment_active(ala.starts_on, ala.ends_on, v_today);

  SELECT count(*)::int
    INTO v_site_cnt
  FROM data.employees e
  WHERE e.tenant_id = v_location.tenant_id
    AND e.site_id = v_location.site_id
    AND e.status = 'active';

  RETURN jsonb_build_object(
    'assignments', v_rows,
    'scope_has_assignments', v_scope,
    'assigned_count', v_assigned,
    'site_employee_count', v_site_cnt
  );
END;
$$;

REVOKE ALL ON FUNCTION api.list_attendance_location_assignments(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_attendance_location_assignments(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION api.add_attendance_location_assignment(
  p_location_id uuid,
  p_employee_id uuid,
  p_starts_on   date DEFAULT NULL,
  p_ends_on     date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_location   record;
  v_employee   record;
  v_assignment_id uuid;
BEGIN
  SELECT l.id, l.tenant_id, l.site_id
    INTO v_location
  FROM data.locations l
  WHERE l.id = p_location_id
    AND (data.active_tenant_id() IS NULL OR l.tenant_id = data.active_tenant_id());

  IF NOT FOUND THEN
    RAISE EXCEPTION 'location_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  PERFORM data.assert_attendance_location_manage_privilege(v_location.tenant_id);

  SELECT e.id, e.tenant_id, e.site_id, e.status
    INTO v_employee
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND e.tenant_id = v_location.tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_employee.site_id IS DISTINCT FROM v_location.site_id THEN
    RAISE EXCEPTION 'employee_site_mismatch' USING ERRCODE = 'check_violation';
  END IF;

  IF v_employee.status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'employee_not_active' USING ERRCODE = 'check_violation';
  END IF;

  IF p_starts_on IS NOT NULL AND p_ends_on IS NOT NULL AND p_ends_on < p_starts_on THEN
    RAISE EXCEPTION 'invalid_assignment_dates' USING ERRCODE = 'check_violation';
  END IF;

  BEGIN
    INSERT INTO data.attendance_location_assignments (
      tenant_id, employee_id, location_id, starts_on, ends_on
    ) VALUES (
      v_location.tenant_id, p_employee_id, p_location_id, p_starts_on, p_ends_on
    )
    RETURNING id INTO v_assignment_id;
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION 'assignment_already_exists' USING ERRCODE = 'unique_violation';
  END;

  RETURN jsonb_build_object('assignment_id', v_assignment_id);
END;
$$;

REVOKE ALL ON FUNCTION api.add_attendance_location_assignment(uuid, uuid, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.add_attendance_location_assignment(uuid, uuid, date, date) TO authenticated;

CREATE OR REPLACE FUNCTION api.remove_attendance_location_assignment(p_assignment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_row record;
BEGIN
  SELECT ala.id, ala.tenant_id
    INTO v_row
  FROM data.attendance_location_assignments ala
  WHERE ala.id = p_assignment_id
    AND (data.active_tenant_id() IS NULL OR ala.tenant_id = data.active_tenant_id());

  IF NOT FOUND THEN
    RAISE EXCEPTION 'assignment_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  PERFORM data.assert_attendance_location_manage_privilege(v_row.tenant_id);

  DELETE FROM data.attendance_location_assignments
  WHERE id = p_assignment_id;

  RETURN jsonb_build_object('removed', true);
END;
$$;

REVOKE ALL ON FUNCTION api.remove_attendance_location_assignment(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.remove_attendance_location_assignment(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 4. Update list_attendance_station_employees — zone filter + assignment_mode
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.list_attendance_station_employees(p_device_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_device record;
  v_rows   jsonb;
  v_today  date := (now() AT TIME ZONE 'Europe/Madrid')::date;
  v_scope  boolean;
  v_mode   text;
BEGIN
  SELECT d.id, d.tenant_id, d.site_id, d.location_id, d.status
    INTO v_device
  FROM data.attendance_devices d
  WHERE d.id = p_device_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'device_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_device.status IS DISTINCT FROM 'active' OR v_device.site_id IS NULL OR v_device.location_id IS NULL THEN
    RAISE EXCEPTION 'station_not_ready' USING ERRCODE = 'check_violation';
  END IF;

  v_scope := data.location_scope_has_attendance_assignments(v_device.location_id, v_today);
  v_mode := CASE WHEN v_scope THEN 'zone' ELSE 'site_fallback' END;

  SELECT COALESCE(jsonb_agg(row_data ORDER BY sort_name), '[]'::jsonb)
    INTO v_rows
  FROM (
    SELECT
      jsonb_build_object(
        'employee_id', e.id,
        'full_name', e.full_name,
        'last_punch_type', lp.punch_type,
        'last_punch_at', lp.occurred_at,
        'day_state', data.compute_employee_punch_day_state(e.id, v_today),
        'next_punch', data.station_kiosk_next_punch(
          data.compute_employee_punch_day_state(e.id, v_today)
        )
      ) AS row_data,
      e.full_name AS sort_name
    FROM data.employees e
    LEFT JOIN LATERAL (
      SELECT tp.punch_type, tp.occurred_at
      FROM data.time_punches tp
      WHERE tp.employee_id = e.id
        AND (tp.occurred_at AT TIME ZONE 'Europe/Madrid')::date = v_today
      ORDER BY tp.occurred_at DESC, tp.id DESC
      LIMIT 1
    ) lp ON true
    WHERE e.tenant_id = v_device.tenant_id
      AND e.site_id = v_device.site_id
      AND e.status = 'active'
      AND (
        NOT v_scope
        OR data.employee_can_punch_at_location(e.id, v_device.location_id, v_today)
      )
  ) sub;

  RETURN jsonb_build_object(
    'employees', v_rows,
    'assignment_mode', v_mode,
    'scope_has_assignments', v_scope
  );
END;
$$;

REVOKE ALL ON FUNCTION api.list_attendance_station_employees(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_attendance_station_employees(uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 5. Update record_station_time_punch — enforce zone assignments
-- -----------------------------------------------------------------------------

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
  v_today            date := (now() AT TIME ZONE 'Europe/Madrid')::date;
  v_scope            boolean;
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

  v_scope := data.location_scope_has_attendance_assignments(v_device.location_id, v_today);
  IF v_scope AND NOT data.employee_can_punch_at_location(p_employee_id, v_device.location_id, v_today) THEN
    RAISE EXCEPTION 'employee_not_allowed_at_location' USING ERRCODE = 'check_violation';
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
