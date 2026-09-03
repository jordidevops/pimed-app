-- =============================================================================
-- ST-6c+ resum hores per ubicació (RPC servidor)
-- ST-2a+ update dates + bulk assign + list amb inactives
-- =============================================================================

-- ─── ST-6c+ helper (mateixa lògica que locationWorkSummary.ts) ───────────────

CREATE OR REPLACE FUNCTION data._st6c_aggregate_location_work(
  p_site_id uuid,
  p_tenant uuid,
  p_tz text,
  p_from_ts timestamptz,
  p_to_ts timestamptz,
  p_employee_id uuid,
  p_location_id uuid
)
RETURNS TABLE (
  employee_id uuid,
  employee_name text,
  location_id uuid,
  location_name text,
  work_minutes int,
  interval_count int,
  open_interval_count int
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, public
AS $$
#variable_conflict use_column
DECLARE
  v_emp record;
  v_day date;
  v_punch record;
  v_open_at timestamptz;
  v_open_loc uuid;
  v_open_name text;
  v_mins int;
  v_loc_key text;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS _st6c_acc (
    employee_id uuid NOT NULL,
    employee_name text NOT NULL,
    location_id uuid,
    location_name text NOT NULL,
    loc_key text NOT NULL,
    work_minutes int NOT NULL DEFAULT 0,
    interval_count int NOT NULL DEFAULT 0,
    open_interval_count int NOT NULL DEFAULT 0,
    CONSTRAINT _st6c_acc_pkey PRIMARY KEY (employee_id, loc_key)
  ) ON COMMIT DROP;

  DELETE FROM _st6c_acc;

  FOR v_emp IN
    SELECT DISTINCT tp.employee_id, e.full_name AS employee_name
    FROM data.time_punches tp
    JOIN data.employees e ON e.id = tp.employee_id
    WHERE tp.site_id = p_site_id AND tp.tenant_id = p_tenant
      AND tp.occurred_at >= p_from_ts AND tp.occurred_at < p_to_ts
      AND (p_employee_id IS NULL OR tp.employee_id = p_employee_id)
      AND (p_location_id IS NULL OR tp.location_id = p_location_id)
  LOOP
    FOR v_day IN
      SELECT DISTINCT (tp.occurred_at AT TIME ZONE p_tz)::date AS d
      FROM data.time_punches tp
      WHERE tp.employee_id = v_emp.employee_id
        AND tp.site_id = p_site_id
        AND tp.occurred_at >= p_from_ts AND tp.occurred_at < p_to_ts
        AND (p_location_id IS NULL OR tp.location_id = p_location_id)
      ORDER BY 1
    LOOP
      v_open_at := NULL;
      v_open_loc := NULL;
      v_open_name := NULL;

      FOR v_punch IN
        SELECT tp.punch_type, tp.occurred_at, tp.location_id,
               COALESCE(NULLIF(btrim(tp.location_name_snapshot), ''), 'Sense ubicació') AS location_name
        FROM data.time_punches tp
        WHERE tp.employee_id = v_emp.employee_id
          AND tp.site_id = p_site_id
          AND (tp.occurred_at AT TIME ZONE p_tz)::date = v_day
          AND tp.occurred_at >= p_from_ts AND tp.occurred_at < p_to_ts
          AND (p_location_id IS NULL OR tp.location_id = p_location_id)
          AND tp.punch_type IN ('in', 'out', 'day_start', 'day_end', 'break_start', 'break_end')
        ORDER BY tp.occurred_at, tp.punch_type
      LOOP
        IF v_punch.punch_type IN ('in', 'day_start') THEN
          IF v_open_at IS NOT NULL THEN
            v_mins := GREATEST(0, round(EXTRACT(EPOCH FROM (v_punch.occurred_at - v_open_at)) / 60.0)::int);
            IF v_mins > 0 THEN
              v_loc_key := COALESCE(v_open_loc::text, '');
              INSERT INTO _st6c_acc AS a (
                employee_id, employee_name, location_id, location_name, loc_key, work_minutes, interval_count
              ) VALUES (
                v_emp.employee_id, v_emp.employee_name, v_open_loc, v_open_name, v_loc_key, v_mins, 1
              )
              ON CONFLICT ON CONSTRAINT _st6c_acc_pkey DO UPDATE SET
                work_minutes = a.work_minutes + EXCLUDED.work_minutes,
                interval_count = a.interval_count + 1;
            END IF;
          END IF;
          v_open_at := v_punch.occurred_at;
          v_open_loc := v_punch.location_id;
          v_open_name := v_punch.location_name;
        ELSIF v_punch.punch_type = 'break_start' THEN
          IF v_open_at IS NOT NULL THEN
            v_mins := GREATEST(0, round(EXTRACT(EPOCH FROM (v_punch.occurred_at - v_open_at)) / 60.0)::int);
            IF v_mins > 0 THEN
              v_loc_key := COALESCE(v_open_loc::text, '');
              INSERT INTO _st6c_acc AS a (
                employee_id, employee_name, location_id, location_name, loc_key, work_minutes, interval_count
              ) VALUES (
                v_emp.employee_id, v_emp.employee_name, v_open_loc, v_open_name, v_loc_key, v_mins, 1
              )
              ON CONFLICT ON CONSTRAINT _st6c_acc_pkey DO UPDATE SET
                work_minutes = a.work_minutes + EXCLUDED.work_minutes,
                interval_count = a.interval_count + 1;
            END IF;
            v_open_at := NULL;
          END IF;
        ELSIF v_punch.punch_type = 'break_end' THEN
          v_open_at := v_punch.occurred_at;
          v_open_loc := v_punch.location_id;
          v_open_name := v_punch.location_name;
        ELSIF v_punch.punch_type IN ('out', 'day_end') THEN
          IF v_open_at IS NOT NULL THEN
            v_mins := GREATEST(0, round(EXTRACT(EPOCH FROM (v_punch.occurred_at - v_open_at)) / 60.0)::int);
            IF v_mins > 0 THEN
              v_loc_key := COALESCE(v_open_loc::text, '');
              INSERT INTO _st6c_acc AS a (
                employee_id, employee_name, location_id, location_name, loc_key, work_minutes, interval_count
              ) VALUES (
                v_emp.employee_id, v_emp.employee_name, v_open_loc, v_open_name, v_loc_key, v_mins, 1
              )
              ON CONFLICT ON CONSTRAINT _st6c_acc_pkey DO UPDATE SET
                work_minutes = a.work_minutes + EXCLUDED.work_minutes,
                interval_count = a.interval_count + 1;
            END IF;
            v_open_at := NULL;
          END IF;
        END IF;
      END LOOP;

      IF v_open_at IS NOT NULL THEN
        v_loc_key := COALESCE(v_open_loc::text, '');
        INSERT INTO _st6c_acc AS a (
          employee_id, employee_name, location_id, location_name, loc_key, open_interval_count
        ) VALUES (
          v_emp.employee_id, v_emp.employee_name, v_open_loc,
          COALESCE(v_open_name, 'Sense ubicació'), v_loc_key, 1
        )
        ON CONFLICT ON CONSTRAINT _st6c_acc_pkey DO UPDATE SET
          open_interval_count = a.open_interval_count + 1;
      END IF;
    END LOOP;
  END LOOP;

  RETURN QUERY
  SELECT a.employee_id, a.employee_name, a.location_id, a.location_name,
         a.work_minutes, a.interval_count, a.open_interval_count
  FROM _st6c_acc a
  WHERE a.work_minutes > 0 OR a.open_interval_count > 0
  ORDER BY a.employee_name, a.location_name, a.work_minutes DESC;
END;
$$;

REVOKE ALL ON FUNCTION data._st6c_aggregate_location_work(uuid, uuid, text, timestamptz, timestamptz, uuid, uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data._st6c_aggregate_location_work(uuid, uuid, text, timestamptz, timestamptz, uuid, uuid)
  TO service_role;

CREATE OR REPLACE FUNCTION api.summarize_location_work(
  p_site_id      uuid,
  p_from         date,
  p_to           date,
  p_employee_id  uuid DEFAULT NULL,
  p_location_id  uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_tenant uuid;
  v_tz     text;
  v_from_ts timestamptz;
  v_to_ts   timestamptz;
  v_rows   jsonb;
BEGIN
  IF p_site_id IS NULL OR p_from IS NULL OR p_to IS NULL THEN
    RAISE EXCEPTION 'invalid_parameters' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_to < p_from THEN
    RAISE EXCEPTION 'invalid_date_range' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT s.tenant_id INTO v_tenant
  FROM data.sites s
  WHERE s.id = p_site_id
    AND (data.active_tenant_id() IS NULL OR s.tenant_id = data.active_tenant_id());

  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'site_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT (
    COALESCE(data.jwt_has_permission(v_tenant, 'attendance.view_all', p_site_id), false)
    OR COALESCE(data.jwt_has_permission(v_tenant, 'attendance.manage', p_site_id), false)
    OR (data.jwt_user_tenants() -> v_tenant::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_tz := COALESCE(data.get_site_timezone(p_site_id, v_tenant), 'Europe/Madrid');
  v_from_ts := (p_from::timestamp AT TIME ZONE v_tz);
  v_to_ts := ((p_to + 1)::timestamp AT TIME ZONE v_tz);

  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.employee_name, x.location_name), '[]'::jsonb)
  INTO v_rows
  FROM data._st6c_aggregate_location_work(
    p_site_id, v_tenant, v_tz, v_from_ts, v_to_ts, p_employee_id, p_location_id
  ) x;

  RETURN jsonb_build_object(
    'ok', true,
    'site_id', p_site_id,
    'from', p_from,
    'to', p_to,
    'timezone', v_tz,
    'rows', COALESCE(v_rows, '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.summarize_location_work(uuid, date, date, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.summarize_location_work(uuid, date, date, uuid, uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.summarize_location_work(uuid, date, date, uuid, uuid) IS
  'ST-6c+: agregat hores per ubicació (intervals in/out + pauses) al servidor.';

-- ─── ST-2a+: list include inactive + update + bulk ───────────────────────────

DROP FUNCTION IF EXISTS api.list_attendance_location_assignments(uuid);

CREATE OR REPLACE FUNCTION api.list_attendance_location_assignments(
  p_location_id uuid,
  p_include_inactive boolean DEFAULT false
)
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
        'inherited', false,
        'is_active_today', data.attendance_location_assignment_active(ala.starts_on, ala.ends_on, v_today)
      ) AS row_data,
      e.full_name AS sort_name
    FROM data.attendance_location_assignments ala
    JOIN data.employees e ON e.id = ala.employee_id
    WHERE ala.location_id = p_location_id
      AND (
        p_include_inactive
        OR data.attendance_location_assignment_active(ala.starts_on, ala.ends_on, v_today)
      )
  ) sub;

  SELECT count(*)::int INTO v_assigned
  FROM data.attendance_location_assignments ala
  WHERE ala.location_id = p_location_id
    AND data.attendance_location_assignment_active(ala.starts_on, ala.ends_on, v_today);

  SELECT count(*)::int INTO v_site_cnt
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

REVOKE ALL ON FUNCTION api.list_attendance_location_assignments(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_attendance_location_assignments(uuid, boolean) TO authenticated;

CREATE OR REPLACE FUNCTION api.update_attendance_location_assignment(
  p_assignment_id uuid,
  p_starts_on     date DEFAULT NULL,
  p_ends_on       date DEFAULT NULL
)
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
    RAISE EXCEPTION 'assignment_not_found' USING ERRCODE = 'P0002';
  END IF;

  PERFORM data.assert_attendance_location_manage_privilege(v_row.tenant_id);

  IF p_starts_on IS NOT NULL AND p_ends_on IS NOT NULL AND p_ends_on < p_starts_on THEN
    RAISE EXCEPTION 'invalid_assignment_dates' USING ERRCODE = 'check_violation';
  END IF;

  UPDATE data.attendance_location_assignments
  SET starts_on = p_starts_on,
      ends_on = p_ends_on
  WHERE id = p_assignment_id;

  RETURN jsonb_build_object('assignment_id', p_assignment_id, 'updated', true);
END;
$$;

REVOKE ALL ON FUNCTION api.update_attendance_location_assignment(uuid, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.update_attendance_location_assignment(uuid, date, date) TO authenticated;

CREATE OR REPLACE FUNCTION api.bulk_add_attendance_location_assignments(
  p_location_id  uuid,
  p_employee_ids uuid[],
  p_starts_on    date DEFAULT NULL,
  p_ends_on      date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp uuid;
  v_created int := 0;
  v_updated int := 0;
  v_errors jsonb := '[]'::jsonb;
  v_id uuid;
BEGIN
  IF p_employee_ids IS NULL OR cardinality(p_employee_ids) = 0 THEN
    RAISE EXCEPTION 'employee_ids_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF cardinality(p_employee_ids) > 200 THEN
    RAISE EXCEPTION 'too_many_employees' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  FOREACH v_emp IN ARRAY p_employee_ids
  LOOP
    BEGIN
      PERFORM api.add_attendance_location_assignment(p_location_id, v_emp, p_starts_on, p_ends_on);
      v_created := v_created + 1;
    EXCEPTION
      WHEN unique_violation THEN
        SELECT ala.id INTO v_id
        FROM data.attendance_location_assignments ala
        WHERE ala.location_id = p_location_id AND ala.employee_id = v_emp;
        IF v_id IS NOT NULL THEN
          PERFORM api.update_attendance_location_assignment(v_id, p_starts_on, p_ends_on);
          v_updated := v_updated + 1;
        END IF;
      WHEN others THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'employee_id', v_emp,
          'code', SQLSTATE,
          'message', SQLERRM
        ));
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'created', v_created,
    'updated', v_updated,
    'errors', v_errors
  );
END;
$$;

REVOKE ALL ON FUNCTION api.bulk_add_attendance_location_assignments(uuid, uuid[], date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.bulk_add_attendance_location_assignments(uuid, uuid[], date, date)
  TO authenticated;

COMMENT ON FUNCTION api.bulk_add_attendance_location_assignments(uuid, uuid[], date, date) IS
  'ST-2a+: assignació massiva empleats↔zona; si ja existeix, actualitza dates.';
