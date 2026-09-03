-- Permet consolidar dies laborables sense fitxatges via adjust_time_entry (crea time_entry ajustada).

CREATE OR REPLACE FUNCTION api.adjust_time_entry(
  p_employee_id        uuid,
  p_work_date          date,
  p_adjusted_net_min   int,
  p_break_minutes      int  DEFAULT NULL,
  p_reason             text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant_id   uuid;
  v_site_id     uuid;
  v_entry_id    uuid;
  v_locked_at   timestamptz;
  v_punch_count int;
  v_tz          text;
  v_brk         int;
BEGIN
  SELECT e.tenant_id, e.site_id INTO v_tenant_id, v_site_id
  FROM data.employees e WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id;
  END IF;

  IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.adjust') THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.adjust required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'adjust_reason_required' USING ERRCODE = 'check_violation';
  END IF;

  SELECT tds.payroll_locked_at INTO v_locked_at
  FROM data.time_daily_summaries tds
  WHERE tds.employee_id = p_employee_id AND tds.work_date = p_work_date;

  IF v_locked_at IS NOT NULL THEN
    RAISE EXCEPTION 'day_payroll_locked: cannot adjust after export on %', p_work_date
      USING ERRCODE = 'check_violation';
  END IF;

  v_tz := COALESCE(data.get_site_timezone(v_site_id, v_tenant_id), 'Europe/Madrid');
  v_brk := COALESCE(p_break_minutes, 0);

  SELECT id INTO v_entry_id
  FROM data.time_entries
  WHERE employee_id = p_employee_id AND work_date = p_work_date;

  IF NOT FOUND THEN
    IF EXISTS (
      SELECT 1 FROM data.time_punches tp
      WHERE tp.employee_id = p_employee_id
        AND (tp.occurred_at AT TIME ZONE v_tz)::date = p_work_date
    ) THEN
      RAISE EXCEPTION 'entry_not_found: employee %, date % — wait for recompute', p_employee_id, p_work_date;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM data.employee_absences ea
      WHERE ea.employee_id = p_employee_id
        AND ea.start_date <= p_work_date
        AND ea.end_date >= p_work_date
        AND ea.status IN ('approved', 'active', 'closed')
    ) THEN
      RAISE EXCEPTION 'cannot_consolidate_with_absence: %', p_work_date
        USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO data.time_entries (
      tenant_id, site_id, employee_id, work_date,
      starts_at, ends_at, punch_in_id, punch_out_id,
      gross_minutes, break_minutes, net_minutes,
      regular_minutes, overtime_minutes, status, adjustment_note, updated_at
    ) VALUES (
      v_tenant_id, v_site_id, p_employee_id, p_work_date,
      NULL, NULL, NULL, NULL,
      p_adjusted_net_min + v_brk, v_brk, p_adjusted_net_min,
      p_adjusted_net_min, 0, 'adjusted', p_reason, now()
    )
    RETURNING id INTO v_entry_id;

    v_punch_count := 0;
  ELSE
    UPDATE data.time_entries
    SET net_minutes     = p_adjusted_net_min,
        break_minutes   = COALESCE(p_break_minutes, break_minutes),
        gross_minutes   = p_adjusted_net_min + COALESCE(p_break_minutes, break_minutes, 0),
        regular_minutes = p_adjusted_net_min,
        status          = 'adjusted',
        adjustment_note = p_reason,
        updated_at      = now()
    WHERE id = v_entry_id;

    SELECT COUNT(*)::int INTO v_punch_count
    FROM data.time_punches tp
    WHERE tp.employee_id = p_employee_id
      AND (tp.occurred_at AT TIME ZONE v_tz)::date = p_work_date;
  END IF;

  INSERT INTO data.time_daily_summaries (
    tenant_id, site_id, employee_id, work_date,
    worked_minutes, break_minutes, punch_count, status
  )
  VALUES (
    v_tenant_id, v_site_id, p_employee_id, p_work_date,
    p_adjusted_net_min, v_brk, v_punch_count, 'draft'
  )
  ON CONFLICT (employee_id, work_date) DO UPDATE SET
    worked_minutes = EXCLUDED.worked_minutes,
    break_minutes  = COALESCE(p_break_minutes, data.time_daily_summaries.break_minutes),
    punch_count    = GREATEST(data.time_daily_summaries.punch_count, EXCLUDED.punch_count),
    updated_at     = now();

  PERFORM data.log_audit_event(
    v_tenant_id, auth.uid(), v_site_id,
    'TIME_ENTRY_ADJUSTED', 'time_entry', v_entry_id,
    jsonb_build_object(
      'employee_id',   p_employee_id,
      'work_date',     p_work_date,
      'net_minutes',   p_adjusted_net_min,
      'reason',        p_reason,
      'consolidated',  (v_punch_count = 0)
    )
  );

  PERFORM pgmq.send(
    'attendance_recompute_queue',
    jsonb_build_object(
      'task',            'recompute_attendance_day',
      'tenant_id',       v_tenant_id,
      'employee_id',     p_employee_id,
      'work_date',       p_work_date,
      'idempotency_key', 'recompute-' || p_employee_id::text || '-' || p_work_date::text
                         || '-adj-' || EXTRACT(EPOCH FROM now())::bigint::text
    )
  );

  RETURN jsonb_build_object('entry_id', v_entry_id, 'status', 'adjusted');
END;
$$;

NOTIFY pgrst, 'reload schema';
