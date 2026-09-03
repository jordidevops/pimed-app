-- Track G Phase 2c: field_punch RPCs (D-INT-1, D-INT-6, D-INT-7)

CREATE OR REPLACE FUNCTION data.insert_work_log_field_gap(
  p_tenant_id        uuid,
  p_employee_id      uuid,
  p_work_date        date,
  p_started_at       timestamptz,
  p_ended_at         timestamptz,
  p_gap_kind         text,
  p_prev_work_log_id uuid DEFAULT NULL,
  p_next_work_log_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_kind text;
  v_id   uuid;
BEGIN
  IF p_ended_at <= p_started_at THEN
    RETURN NULL;
  END IF;

  v_kind := data.normalize_field_gap_kind(p_gap_kind);

  INSERT INTO data.work_log_field_gaps (
    tenant_id, employee_id, work_date,
    started_at, ended_at, gap_kind,
    prev_work_log_id, next_work_log_id
  ) VALUES (
    p_tenant_id, p_employee_id, p_work_date,
    p_started_at, p_ended_at, v_kind,
    p_prev_work_log_id, p_next_work_log_id
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.field_punch_start(
  p_employee_id    uuid,
  p_client_op_id   uuid,
  p_project_id     uuid,
  p_task_id        uuid        DEFAULT NULL,
  p_timestamp      timestamptz DEFAULT now(),
  p_geo            jsonb       DEFAULT NULL,
  p_location_perm  text        DEFAULT 'notrequired',
  p_punch_type     text        DEFAULT 'in',
  p_notes          text        DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp        record;
  v_punch      jsonb;
  v_punch_id   uuid;
  v_log_id     uuid;
  v_anomalies  text[];
  v_punch_type text := COALESCE(NULLIF(p_punch_type, ''), 'in');
BEGIN
  SELECT e.id, e.tenant_id, e.site_id, e.user_id, e.status
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND OR v_emp.status != 'active' OR v_emp.user_id IS NULL THEN
    RAISE EXCEPTION 'employee_not_found_or_inactive: %', p_employee_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF auth.uid() IS NOT NULL AND auth.uid() IS DISTINCT FROM v_emp.user_id THEN
    IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.adjust', v_emp.site_id) THEN
      RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  IF auth.uid() IS NOT NULL AND NOT data.can_access_project(p_project_id) THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied: %', p_project_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_punch_type NOT IN ('in', 'day_start') THEN
    RAISE EXCEPTION 'invalid_punch_type_for_field_start: %', v_punch_type
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT id INTO v_log_id
  FROM data.work_logs
  WHERE tenant_id = v_emp.tenant_id AND client_op_id = p_client_op_id;

  IF v_log_id IS NOT NULL THEN
    SELECT time_punch_in_id INTO v_punch_id FROM data.work_logs WHERE id = v_log_id;
    RETURN jsonb_build_object(
      'work_log_id', v_log_id,
      'punch_id', v_punch_id,
      'status', 'duplicate'
    );
  END IF;

  v_punch := api.record_time_punch(
    p_employee_id    => p_employee_id,
    p_client_op_id   => gen_random_uuid(),
    p_punch_type     => v_punch_type,
    p_occurred_at    => p_timestamp,
    p_geo            => p_geo,
    p_location_perm  => p_location_perm,
    p_notes          => p_notes,
    p_source         => CASE WHEN auth.uid() IS NULL THEN 'portal' ELSE 'mobile' END
  );
  v_punch_id := (v_punch->>'punch_id')::uuid;

  v_anomalies := data.validate_geo_payload(p_geo, p_location_perm);

  INSERT INTO data.work_logs (
    tenant_id, site_id, project_id, task_id,
    worker_id, employee_id, client_op_id, entry_mode,
    time_punch_in_id, status,
    check_in, check_in_geo, check_in_received_at,
    location_permission, anomaly_codes, notes
  )
  SELECT
    p.tenant_id, p.site_id, p_project_id, p_task_id,
    v_emp.user_id, v_emp.id, p_client_op_id, 'field_punch',
    v_punch_id, 'open',
    p_timestamp, p_geo, now(),
    p_location_perm, v_anomalies, p_notes
  FROM data.projects p
  WHERE p.id = p_project_id
  RETURNING id INTO v_log_id;

  PERFORM data.log_audit_event(
    v_emp.tenant_id, COALESCE(auth.uid(), v_emp.user_id), v_emp.site_id,
    'WORK_LOG_STARTED', 'work_log', v_log_id,
    jsonb_build_object(
      'entry_mode', 'field_punch',
      'project_id', p_project_id,
      'punch_id', v_punch_id,
      'punch_type', v_punch_type
    )
  );

  RETURN jsonb_build_object(
    'work_log_id', v_log_id,
    'punch_id', v_punch_id,
    'status', 'created'
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.field_punch_stop(
  p_employee_id    uuid,
  p_log_id         uuid,
  p_client_op_id   uuid,
  p_timestamp      timestamptz DEFAULT now(),
  p_geo            jsonb       DEFAULT NULL,
  p_location_perm  text        DEFAULT 'notrequired',
  p_gap_kind       text        DEFAULT NULL,
  p_record_day_end boolean     DEFAULT false,
  p_notes          text        DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp       record;
  v_log       record;
  v_punch     jsonb;
  v_punch_id  uuid;
  v_anomalies text[];
  v_punch_type text := CASE WHEN p_record_day_end THEN 'day_end' ELSE 'out' END;
BEGIN
  SELECT e.id, e.tenant_id, e.site_id, e.user_id, e.status
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id;
  END IF;

  SELECT * INTO v_log
  FROM data.work_logs wl
  WHERE wl.id = p_log_id
    AND wl.employee_id = p_employee_id
    AND wl.entry_mode = 'field_punch'
    AND wl.status IN ('open', 'paused');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'work_log_not_found_or_not_open: %', p_log_id;
  END IF;

  v_punch := api.record_time_punch(
    p_employee_id  => p_employee_id,
    p_client_op_id => p_client_op_id,
    p_punch_type   => v_punch_type,
    p_occurred_at  => p_timestamp,
    p_geo          => p_geo,
    p_location_perm => p_location_perm,
    p_notes        => p_notes,
    p_source       => CASE WHEN auth.uid() IS NULL THEN 'portal' ELSE 'mobile' END
  );
  v_punch_id := (v_punch->>'punch_id')::uuid;

  v_anomalies := data.validate_geo_payload(p_geo, p_location_perm);
  v_anomalies := ARRAY(
    SELECT DISTINCT unnest(COALESCE(v_log.anomaly_codes, '{}') || v_anomalies)
  );

  UPDATE data.work_logs SET
    status = 'closed',
    check_out = p_timestamp,
    check_out_geo = p_geo,
    check_out_received_at = now(),
    time_punch_out_id = v_punch_id,
    anomaly_codes = v_anomalies,
    notes = COALESCE(p_notes, notes),
    updated_at = now()
  WHERE id = p_log_id;

  PERFORM data.log_audit_event(
    v_emp.tenant_id, COALESCE(auth.uid(), v_emp.user_id), v_emp.site_id,
    'WORK_LOG_STOPPED', 'work_log', p_log_id,
    jsonb_build_object(
      'entry_mode', 'field_punch',
      'punch_id', v_punch_id,
      'gap_kind', p_gap_kind,
      'record_day_end', p_record_day_end
    )
  );

  RETURN jsonb_build_object(
    'work_log_id', p_log_id,
    'punch_id', v_punch_id,
    'duration_minutes', GREATEST(0, EXTRACT(EPOCH FROM (p_timestamp - v_log.check_in)) / 60)::int
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.switch_work_log(
  p_employee_id      uuid,
  p_current_log_id   uuid,
  p_next_project_id  uuid,
  p_client_op_id     uuid,
  p_next_task_id     uuid        DEFAULT NULL,
  p_gap_kind         text        DEFAULT NULL,
  p_stop_at          timestamptz DEFAULT NULL,
  p_start_at         timestamptz DEFAULT NULL,
  p_geo              jsonb       DEFAULT NULL,
  p_location_perm    text        DEFAULT 'notrequired',
  p_notes            text        DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp        record;
  v_log        record;
  v_stop_at    timestamptz;
  v_start_at   timestamptz;
  v_work_date  date;
  v_gap_id     uuid;
  v_next       jsonb;
  v_anomalies  text[];
BEGIN
  SELECT e.id, e.tenant_id, e.site_id, e.user_id, e.status
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id;
  END IF;

  SELECT * INTO v_log
  FROM data.work_logs
  WHERE id = p_current_log_id
    AND employee_id = p_employee_id
    AND entry_mode = 'field_punch'
    AND status IN ('open', 'paused');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'work_log_not_open: %', p_current_log_id;
  END IF;

  v_start_at := COALESCE(p_start_at, p_stop_at, now());
  v_stop_at  := COALESCE(p_stop_at, v_start_at);

  v_work_date := (v_start_at AT TIME ZONE COALESCE(
    data.get_site_timezone(v_emp.site_id, v_emp.tenant_id), 'Europe/Madrid'
  ))::date;

  v_anomalies := data.validate_geo_payload(p_geo, p_location_perm);

  UPDATE data.work_logs SET
    status = 'closed',
    check_out = v_stop_at,
    check_out_geo = p_geo,
    check_out_received_at = now(),
    anomaly_codes = ARRAY(SELECT DISTINCT unnest(anomaly_codes || v_anomalies)),
    updated_at = now()
  WHERE id = p_current_log_id;

  IF v_start_at > v_stop_at THEN
    v_gap_id := data.insert_work_log_field_gap(
      v_emp.tenant_id, v_emp.id, v_work_date,
      v_stop_at, v_start_at,
      COALESCE(p_gap_kind, 'UNCLASSIFIED'),
      p_current_log_id, NULL
    );
  END IF;

  v_next := api.field_punch_start(
    p_employee_id   => p_employee_id,
    p_client_op_id  => p_client_op_id,
    p_project_id    => p_next_project_id,
    p_task_id       => p_next_task_id,
    p_timestamp     => v_start_at,
    p_geo           => p_geo,
    p_location_perm => p_location_perm,
    p_punch_type    => 'in',
    p_notes         => p_notes
  );

  UPDATE data.work_log_field_gaps
  SET next_work_log_id = (v_next->>'work_log_id')::uuid
  WHERE id = v_gap_id;

  PERFORM data.log_audit_event(
    v_emp.tenant_id, COALESCE(auth.uid(), v_emp.user_id), v_emp.site_id,
    'PROJECT_SWITCH', 'work_log', p_current_log_id,
    jsonb_build_object(
      'next_work_log_id', v_next->>'work_log_id',
      'next_project_id', p_next_project_id,
      'gap_kind', p_gap_kind,
      'gap_id', v_gap_id
    )
  );

  RETURN jsonb_build_object(
    'previous_work_log_id', p_current_log_id,
    'next_work_log_id', v_next->>'work_log_id',
    'gap_id', v_gap_id,
    'status', 'switched'
  );
END;
$$;

REVOKE ALL ON FUNCTION data.insert_work_log_field_gap(uuid, uuid, date, timestamptz, timestamptz, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.insert_work_log_field_gap(uuid, uuid, date, timestamptz, timestamptz, text, uuid, uuid) TO service_role;

REVOKE ALL ON FUNCTION api.field_punch_start(uuid, uuid, uuid, uuid, timestamptz, jsonb, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.field_punch_stop(uuid, uuid, uuid, timestamptz, jsonb, text, text, boolean, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.switch_work_log(uuid, uuid, uuid, uuid, uuid, text, timestamptz, timestamptz, jsonb, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.field_punch_start(uuid, uuid, uuid, uuid, timestamptz, jsonb, text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.field_punch_stop(uuid, uuid, uuid, timestamptz, jsonb, text, text, boolean, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.switch_work_log(uuid, uuid, uuid, uuid, uuid, text, timestamptz, timestamptz, jsonb, text, text) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
