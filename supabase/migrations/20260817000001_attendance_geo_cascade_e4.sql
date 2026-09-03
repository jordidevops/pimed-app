-- E4: Cascada «registrar geo» — employee → department → calendar_group → tenant/site.

ALTER TABLE data.employees
  ADD COLUMN IF NOT EXISTS attendance_geo_enabled boolean NULL;

COMMENT ON COLUMN data.employees.attendance_geo_enabled IS
  'NULL = hereta cascada (departament → grup calendari → tenant). false = no desar geo al fitxar.';

ALTER TABLE data.departments
  ADD COLUMN IF NOT EXISTS attendance_geo_enabled boolean NULL;

COMMENT ON COLUMN data.departments.attendance_geo_enabled IS
  'NULL = hereta cascada. false = empleats del departament no desen geo (salvo override empleat).';

ALTER TABLE data.calendar_groups
  ADD COLUMN IF NOT EXISTS attendance_geo_enabled boolean NULL;

COMMENT ON COLUMN data.calendar_groups.attendance_geo_enabled IS
  'NULL = hereta tenant/site. false = empleats del grup no desen geo (salvo override superior).';

-- ─── Resolver cascada ───────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.resolve_attendance_geo_enabled(p_employee_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp record;
  v_dept_enabled boolean;
  v_group_enabled boolean;
  v_settings jsonb;
BEGIN
  SELECT
    e.attendance_geo_enabled,
    e.department_id,
    e.calendar_group_id,
    e.site_id,
    e.tenant_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF v_emp.attendance_geo_enabled IS NOT NULL THEN
    RETURN v_emp.attendance_geo_enabled;
  END IF;

  IF v_emp.department_id IS NOT NULL THEN
    SELECT d.attendance_geo_enabled
    INTO v_dept_enabled
    FROM data.departments d
    WHERE d.id = v_emp.department_id;

    IF v_dept_enabled IS NOT NULL THEN
      RETURN v_dept_enabled;
    END IF;
  END IF;

  IF v_emp.calendar_group_id IS NOT NULL THEN
    SELECT cg.attendance_geo_enabled
    INTO v_group_enabled
    FROM data.calendar_groups cg
    WHERE cg.id = v_emp.calendar_group_id;

    IF v_group_enabled IS NOT NULL THEN
      RETURN v_group_enabled;
    END IF;
  END IF;

  v_settings := api.get_effective_settings(
    p_site_id => v_emp.site_id,
    p_user_id => auth.uid(),
    p_tenant_id => v_emp.tenant_id
  );

  IF v_settings ? 'attendance_geo_enabled'
     AND NULLIF(v_settings ->> 'attendance_geo_enabled', '') IS NOT NULL THEN
    RETURN (v_settings ->> 'attendance_geo_enabled')::boolean;
  END IF;

  RETURN COALESCE((v_settings ->> 'attendance_location_consent_required')::boolean, false);
END;
$$;

REVOKE ALL ON FUNCTION data.resolve_attendance_geo_enabled(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION api.get_attendance_geo_enabled(p_employee_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp record;
BEGIN
  SELECT e.user_id, e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF v_emp.user_id IS DISTINCT FROM auth.uid()
       AND NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.view_all', v_emp.site_id)
       AND NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.approve', v_emp.site_id) THEN
      RAISE EXCEPTION 'insufficient_privilege';
    END IF;
  END IF;

  RETURN data.resolve_attendance_geo_enabled(p_employee_id);
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_attendance_geo_enabled(uuid) TO authenticated;

-- ─── Vistes API ─────────────────────────────────────────────────────────────

DROP VIEW IF EXISTS api.employees CASCADE;

CREATE VIEW api.employees AS
SELECT
  id, tenant_id, site_id, user_id, department_id,
  full_name, email, phone, document_id, job_title,
  status, starts_on, ends_on, weekly_hours, metadata,
  calendar_group_id,
  location_consent_given, location_consent_at, location_consent_version,
  attendance_geo_enabled,
  created_at, updated_at
FROM data.employees;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.employees TO authenticated;

DROP VIEW IF EXISTS api.departments CASCADE;

CREATE VIEW api.departments
  WITH (security_invoker = true) AS
  SELECT
    id,
    tenant_id,
    parent_id,
    name,
    code,
    manager_id,
    is_active,
    attendance_geo_enabled,
    created_at,
    updated_at
  FROM data.departments;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.departments TO authenticated;

DROP VIEW IF EXISTS api.calendar_groups CASCADE;

CREATE VIEW api.calendar_groups AS
SELECT
  id, tenant_id, site_id, name, color, description,
  is_active, sort_order, attendance_geo_enabled,
  created_at, updated_at
FROM data.calendar_groups;

GRANT SELECT ON api.calendar_groups TO authenticated;

CREATE OR REPLACE FUNCTION api.list_calendar_groups(
  p_site_id uuid DEFAULT NULL
)
RETURNS SETOF api.calendar_groups
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = api, data, public
AS $$
  SELECT id, tenant_id, site_id, name, color, description, is_active, sort_order, attendance_geo_enabled, created_at, updated_at
  FROM data.calendar_groups
  WHERE tenant_id = data.active_tenant_id()
    AND is_active = true
    AND (p_site_id IS NULL OR site_id IS NULL OR site_id = p_site_id)
  ORDER BY sort_order, name;
$$;

GRANT EXECUTE ON FUNCTION api.list_calendar_groups(uuid) TO authenticated;

-- ─── record_time_punch: descartar geo si cascada desactivada ─────────────────

CREATE OR REPLACE FUNCTION api.record_time_punch(
  p_employee_id          uuid,
  p_client_op_id         uuid,
  p_punch_type           text,
  p_occurred_at          timestamptz DEFAULT now(),
  p_geo                  jsonb       DEFAULT NULL,
  p_location_perm        text        DEFAULT 'notrequired',
  p_notes                text        DEFAULT NULL,
  p_source               text        DEFAULT 'mobile',
  p_device_id            uuid        DEFAULT NULL,
  p_pause_type           text        DEFAULT NULL,
  p_pause_counts_as_work boolean     DEFAULT NULL,
  p_is_remote            boolean     DEFAULT false,
  p_geo_consent          boolean     DEFAULT false,
  p_geo_error            text        DEFAULT NULL,
  p_device_info          jsonb       DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, pgmq
AS $$
DECLARE
  v_employee       record;
  v_punch_id       uuid;
  v_anomalies      text[];
  v_offset_ms      bigint;
  v_threshold_ms   bigint;
  v_settings       jsonb;
  v_last_punch     record;
  v_pause_cfg      record;
  v_counts_work    boolean;
  v_geo_lat        numeric(10,7);
  v_geo_lng        numeric(10,7);
  v_geo_acc        real;
  v_geo_alt        real;
  v_geo_spd        real;
  v_work_date      date;
BEGIN
  SELECT e.tenant_id, e.site_id, e.user_id, e.status
    INTO v_employee
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND (data.active_tenant_id() IS NULL OR e.tenant_id = data.active_tenant_id());

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_employee.status != 'active' THEN
    RAISE EXCEPTION 'employee_not_active: %', p_employee_id USING ERRCODE = 'check_violation';
  END IF;
  IF v_employee.site_id IS NULL THEN
    RAISE EXCEPTION 'employee_no_site' USING ERRCODE = 'check_violation';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF v_employee.user_id IS DISTINCT FROM auth.uid() THEN
      IF NOT data.jwt_has_permission(v_employee.tenant_id, 'attendance.adjust', v_employee.site_id) THEN
        RAISE EXCEPTION 'insufficient_privilege: cannot punch for another employee' USING ERRCODE = 'insufficient_privilege';
      END IF;
    ELSE
      IF NOT data.jwt_has_permission(v_employee.tenant_id, 'attendance.punch_own', v_employee.site_id) THEN
        RAISE EXCEPTION 'insufficient_privilege: attendance.punch_own required' USING ERRCODE = 'insufficient_privilege';
      END IF;
    END IF;
  END IF;

  SELECT id INTO v_punch_id FROM data.time_punches
  WHERE tenant_id = v_employee.tenant_id AND client_op_id = p_client_op_id;

  IF v_punch_id IS NOT NULL THEN
    RETURN jsonb_build_object('punch_id', v_punch_id, 'status', 'duplicate', 'anomaly_codes', ARRAY[]::text[]);
  END IF;

  v_work_date := (p_occurred_at AT TIME ZONE 'Europe/Madrid')::date;

  SELECT punch_type, pause_type INTO v_last_punch
  FROM data.time_punches
  WHERE employee_id = p_employee_id
    AND (occurred_at AT TIME ZONE 'Europe/Madrid')::date = v_work_date
  ORDER BY occurred_at DESC, id DESC
  LIMIT 1;

  IF p_punch_type = 'in' AND v_last_punch.punch_type IN ('in', 'break_start') THEN
    RAISE EXCEPTION 'invalid_sequence: already working or on pause' USING ERRCODE = 'check_violation';
  END IF;
  IF p_punch_type = 'out' THEN
    IF v_last_punch IS NULL OR v_last_punch.punch_type = 'out' THEN
      RAISE EXCEPTION 'invalid_sequence: not working' USING ERRCODE = 'check_violation';
    END IF;
    IF v_last_punch.punch_type = 'break_start' THEN
      RAISE EXCEPTION 'invalid_sequence: close pause before punch out' USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  IF p_punch_type = 'break_start' AND COALESCE(v_last_punch.punch_type, 'out') NOT IN ('in', 'break_end') THEN
    RAISE EXCEPTION 'invalid_sequence: must be working to start pause' USING ERRCODE = 'check_violation';
  END IF;
  IF p_punch_type = 'break_end' AND v_last_punch.punch_type != 'break_start' THEN
    RAISE EXCEPTION 'invalid_sequence: no open pause' USING ERRCODE = 'check_violation';
  END IF;

  v_counts_work := p_pause_counts_as_work;
  IF p_punch_type IN ('break_start', 'break_end') AND p_pause_type IS NOT NULL THEN
    SELECT counts_as_work INTO v_pause_cfg
    FROM data.tenant_pause_configs
    WHERE tenant_id = v_employee.tenant_id AND key = p_pause_type AND is_active = true;
    IF FOUND THEN
      v_counts_work := v_pause_cfg.counts_as_work;
    END IF;
  END IF;

  SELECT api.get_effective_settings(
    p_site_id => v_employee.site_id, p_user_id => auth.uid(), p_tenant_id => v_employee.tenant_id
  ) INTO v_settings;

  IF NOT data.resolve_attendance_geo_enabled(p_employee_id) THEN
    p_geo := NULL;
    p_location_perm := 'notrequired';
    p_geo_consent := false;
    p_geo_error := NULL;
  END IF;

  v_anomalies := data.validate_geo_payload(p_geo, p_location_perm);

  v_threshold_ms := COALESCE((v_settings->>'attendance_clock_offset_threshold_ms')::bigint, 300000);
  v_offset_ms := ABS(EXTRACT(EPOCH FROM (p_occurred_at - now())) * 1000)::bigint;
  IF v_offset_ms > v_threshold_ms AND NOT ('CLOCK_SKEW' = ANY(v_anomalies)) THEN
    v_anomalies := array_append(v_anomalies, 'CLOCK_SKEW');
  END IF;

  v_geo_lat := COALESCE((p_geo->>'lat')::numeric, (p_geo->>'latitude')::numeric);
  v_geo_lng := COALESCE((p_geo->>'lng')::numeric, (p_geo->>'longitude')::numeric);
  v_geo_acc := COALESCE((p_geo->>'accuracy')::real, (p_geo->>'accuracy_m')::real);
  v_geo_alt := (p_geo->>'altitude')::real;
  v_geo_spd := (p_geo->>'speed')::real;

  INSERT INTO data.time_punches (
    tenant_id, site_id, employee_id, device_id, client_op_id,
    punch_type, occurred_at, received_at,
    geo, location_permission, anomaly_codes, source, notes,
    pause_type, pause_counts_as_work, is_remote,
    geo_lat, geo_lng, geo_accuracy_m, geo_altitude_m, geo_speed_ms,
    geo_consent, geo_error, device_info
  ) VALUES (
    v_employee.tenant_id, v_employee.site_id, p_employee_id, p_device_id, p_client_op_id,
    p_punch_type, p_occurred_at, now(),
    p_geo, p_location_perm, v_anomalies, p_source, p_notes,
    p_pause_type, v_counts_work, COALESCE(p_is_remote, false),
    v_geo_lat, v_geo_lng, v_geo_acc, v_geo_alt, v_geo_spd,
    COALESCE(p_geo_consent, false), p_geo_error, p_device_info
  )
  RETURNING id INTO v_punch_id;

  PERFORM pgmq.send('attendance_recompute_queue', jsonb_build_object(
    'task', 'recompute_attendance_day',
    'tenant_id', v_employee.tenant_id,
    'employee_id', p_employee_id,
    'work_date', v_work_date,
    'idempotency_key', 'recompute-' || p_employee_id::text || '-' || v_work_date::text || '-' || v_punch_id::text
  ));

  BEGIN
    PERFORM pgmq.send('workflow_trigger_queue', jsonb_build_object(
      'trigger_event', CASE p_punch_type
        WHEN 'in' THEN 'PUNCH_IN'
        WHEN 'out' THEN 'PUNCH_OUT'
        WHEN 'break_start' THEN 'PAUSE_START'
        ELSE 'PAUSE_END'
      END,
      'tenant_id', v_employee.tenant_id,
      'trigger_entity_type', 'employee',
      'trigger_entity_id', p_employee_id,
      'payload', jsonb_build_object(
        'punch_id', v_punch_id, 'punch_type', p_punch_type,
        'pause_type', p_pause_type, 'occurred_at', p_occurred_at, 'is_remote', p_is_remote
      )
    ));
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object('punch_id', v_punch_id, 'status', 'created', 'anomaly_codes', v_anomalies);
END;
$$;

GRANT EXECUTE ON FUNCTION api.record_time_punch(
  uuid, uuid, text, timestamptz, jsonb, text, text, text, uuid,
  text, boolean, boolean, boolean, text, jsonb
) TO authenticated;

COMMENT ON FUNCTION data.resolve_attendance_geo_enabled IS
  'Cascada geo: employee → department → calendar_group → settings (attendance_geo_enabled / attendance_location_consent_required).';

NOTIFY pgrst, 'reload schema';
