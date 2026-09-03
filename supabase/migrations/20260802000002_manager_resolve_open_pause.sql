-- P0 F2.1: resolució manager de pausa oberta (crash / empleat absent).
-- Crea break_end (+ opcionalment out) amb source manager_correction, sense alterar raw existent.

ALTER TABLE data.time_punches
  DROP CONSTRAINT IF EXISTS time_punches_source_check;

ALTER TABLE data.time_punches
  ADD CONSTRAINT time_punches_source_check
  CHECK (source IN ('mobile', 'station', 'manual_entry', 'manager_correction'));

CREATE OR REPLACE FUNCTION api.manager_resolve_open_pause(
  p_employee_id     uuid,
  p_reason          text,
  p_work_date       date        DEFAULT NULL,
  p_break_end_at    timestamptz DEFAULT now(),
  p_also_punch_out  boolean     DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, pgmq, public
AS $$
DECLARE
  v_employee       record;
  v_work_date      date;
  v_open_pause     record;
  v_break_end_id   uuid;
  v_out_id         uuid;
  v_counts_work    boolean;
  v_locked_at      timestamptz;
  v_anomalies      text[] := ARRAY['MANAGER_CORRECTION']::text[];
  v_note           text;
BEGIN
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'reason_required'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT e.id, e.tenant_id, e.site_id, e.status
    INTO v_employee
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND (data.active_tenant_id() IS NULL OR e.tenant_id = data.active_tenant_id());

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_employee.status != 'active' THEN
    RAISE EXCEPTION 'employee_not_active: %', p_employee_id
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_employee.site_id IS NULL THEN
    RAISE EXCEPTION 'employee_no_site'
      USING ERRCODE = 'check_violation';
  END IF;

  IF NOT data.jwt_has_permission(v_employee.tenant_id, 'attendance.adjust', v_employee.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.adjust required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_work_date := COALESCE(
    p_work_date,
    (COALESCE(p_break_end_at, now()) AT TIME ZONE 'Europe/Madrid')::date
  );

  SELECT tds.payroll_locked_at INTO v_locked_at
  FROM data.time_daily_summaries tds
  WHERE tds.employee_id = p_employee_id
    AND tds.work_date = v_work_date;

  IF v_locked_at IS NOT NULL THEN
    RAISE EXCEPTION 'day_payroll_locked: cannot resolve pause on %', v_work_date
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT tp.id, tp.occurred_at, tp.pause_type, tp.pause_counts_as_work, tp.punch_type
    INTO v_open_pause
  FROM data.time_punches tp
  WHERE tp.employee_id = p_employee_id
    AND (tp.occurred_at AT TIME ZONE 'Europe/Madrid')::date = v_work_date
  ORDER BY tp.occurred_at DESC, tp.id DESC
  LIMIT 1;

  IF NOT FOUND OR v_open_pause.punch_type != 'break_start' THEN
    RAISE EXCEPTION 'no_open_pause: employee % on %', p_employee_id, v_work_date
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_break_end_at < v_open_pause.occurred_at THEN
    RAISE EXCEPTION 'break_end_before_start: % < %', p_break_end_at, v_open_pause.occurred_at
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_break_end_at > now() + interval '5 minutes' THEN
    RAISE EXCEPTION 'break_end_in_future'
      USING ERRCODE = 'check_violation';
  END IF;

  v_counts_work := v_open_pause.pause_counts_as_work;
  IF v_open_pause.pause_type IS NOT NULL THEN
    SELECT counts_as_work INTO v_counts_work
    FROM data.tenant_pause_configs
    WHERE tenant_id = v_employee.tenant_id
      AND key = v_open_pause.pause_type
      AND is_active = true;
    v_counts_work := COALESCE(v_counts_work, v_open_pause.pause_counts_as_work);
  END IF;

  v_note := 'Manager: ' || btrim(p_reason);

  INSERT INTO data.time_punches (
    tenant_id, site_id, employee_id, client_op_id,
    punch_type, occurred_at, received_at,
    location_permission, anomaly_codes, source, notes,
    pause_type, pause_counts_as_work
  ) VALUES (
    v_employee.tenant_id, v_employee.site_id, p_employee_id, gen_random_uuid(),
    'break_end', p_break_end_at, now(),
    'notrequired', v_anomalies, 'manager_correction', v_note,
    v_open_pause.pause_type, v_counts_work
  )
  RETURNING id INTO v_break_end_id;

  IF p_also_punch_out THEN
    INSERT INTO data.time_punches (
      tenant_id, site_id, employee_id, client_op_id,
      punch_type, occurred_at, received_at,
      location_permission, anomaly_codes, source, notes
    ) VALUES (
      v_employee.tenant_id, v_employee.site_id, p_employee_id, gen_random_uuid(),
      'out', p_break_end_at, now(),
      'notrequired', v_anomalies, 'manager_correction', v_note
    )
    RETURNING id INTO v_out_id;
  END IF;

  PERFORM data.log_audit_event(
    v_employee.tenant_id, auth.uid(), v_employee.site_id,
    'OPEN_PAUSE_RESOLVED', 'time_punch', v_break_end_id,
    jsonb_build_object(
      'employee_id',    p_employee_id,
      'work_date',      v_work_date,
      'break_start_id', v_open_pause.id,
      'break_end_id',   v_break_end_id,
      'out_id',         v_out_id,
      'break_end_at',   p_break_end_at,
      'also_punch_out', p_also_punch_out,
      'reason',         btrim(p_reason)
    )
  );

  PERFORM pgmq.send('attendance_recompute_queue', jsonb_build_object(
    'task', 'recompute_attendance_day',
    'tenant_id', v_employee.tenant_id,
    'employee_id', p_employee_id,
    'work_date', v_work_date,
    'idempotency_key', 'recompute-' || p_employee_id::text || '-' || v_work_date::text
      || '-mgr-pause-' || v_break_end_id::text
  ));

  RETURN jsonb_build_object(
    'status', 'resolved',
    'break_end_id', v_break_end_id,
    'out_id', v_out_id,
    'work_date', v_work_date
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.manager_resolve_open_pause(
  uuid, text, date, timestamptz, boolean
) TO authenticated;

COMMENT ON FUNCTION api.manager_resolve_open_pause IS
  'Manager closes an open break_start with a corrective break_end (and optional out). Raw punches are append-only.';

NOTIFY pgrst, 'reload schema';
