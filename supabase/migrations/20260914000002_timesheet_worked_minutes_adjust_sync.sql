-- Timesheet: treballat coherent després d'ajust; no inflar hores amb entrades obertes de dies passats.

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
  v_tenant_id  uuid;
  v_site_id    uuid;
  v_entry_id   uuid;
  v_locked_at  timestamptz;
  v_punch_count int;
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

  SELECT tds.payroll_locked_at INTO v_locked_at
  FROM data.time_daily_summaries tds
  WHERE tds.employee_id = p_employee_id AND tds.work_date = p_work_date;

  IF v_locked_at IS NOT NULL THEN
    RAISE EXCEPTION 'day_payroll_locked: cannot adjust after export on %', p_work_date
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT id INTO v_entry_id
  FROM data.time_entries
  WHERE employee_id = p_employee_id AND work_date = p_work_date;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'entry_not_found: employee %, date %', p_employee_id, p_work_date;
  END IF;

  UPDATE data.time_entries
  SET net_minutes     = p_adjusted_net_min,
      break_minutes   = COALESCE(p_break_minutes, break_minutes),
      status          = 'adjusted',
      adjustment_note = p_reason,
      updated_at      = now()
  WHERE id = v_entry_id;

  SELECT COUNT(*)::int INTO v_punch_count
  FROM data.time_punches tp
  WHERE tp.employee_id = p_employee_id
    AND (tp.occurred_at AT TIME ZONE COALESCE(
      data.get_site_timezone(v_site_id, v_tenant_id), 'Europe/Madrid'
    ))::date = p_work_date;

  INSERT INTO data.time_daily_summaries (
    tenant_id, site_id, employee_id, work_date,
    worked_minutes, break_minutes, punch_count, status
  )
  VALUES (
    v_tenant_id, v_site_id, p_employee_id, p_work_date,
    p_adjusted_net_min, COALESCE(p_break_minutes, 0), v_punch_count, 'draft'
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
      'reason',        p_reason
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

-- Patch worked_minutes + approve després d'ajust (funció vigent post C1).
CREATE OR REPLACE FUNCTION api.get_payroll_review_days(
  p_employee_id uuid,
  p_from        date,
  p_to          date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp   record;
  v_tz    text;
  v_days  int;
  v_rows  jsonb;
  v_today date;
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_from > p_to THEN
    RAISE EXCEPTION 'invalid_date_range';
  END IF;

  v_days := (p_to - p_from) + 1;
  IF v_days > 93 THEN
    RAISE EXCEPTION 'date_range_too_large' USING DETAIL = 'max 93 days';
  END IF;

  SELECT e.tenant_id, e.site_id INTO v_emp
  FROM data.employees e WHERE e.id = p_employee_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'employee_not_found'; END IF;

  IF auth.uid() IS NOT NULL THEN
    IF NOT (data.jwt_user_tenants() ? v_emp.tenant_id::text) THEN
      RAISE EXCEPTION 'insufficient_privilege';
    END IF;
    IF NOT (
      data.jwt_has_permission(v_emp.tenant_id, 'attendance.view_all', v_emp.site_id)
      OR data.jwt_has_permission(v_emp.tenant_id, 'attendance.approve', v_emp.site_id)
      OR EXISTS (SELECT 1 FROM data.employees e WHERE e.id = p_employee_id AND e.user_id = auth.uid())
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege';
    END IF;
  END IF;

  v_tz := COALESCE(data.get_site_timezone(v_emp.site_id, v_emp.tenant_id), 'Europe/Madrid');
  v_today := (now() AT TIME ZONE v_tz)::date;

  SELECT COALESCE(jsonb_agg(day_row ORDER BY day_row ->> 'work_date'), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'work_date', gs.dt::date,
      'day_type', wd.resolve ->> 'day_type',
      'work_day_type', COALESCE(wd.resolve ->> 'work_day_type', 'normal'),
      'expected_minutes', COALESCE((wd.resolve ->> 'expected_minutes')::int, 0),
      'holiday_name', wd.resolve ->> 'holiday_name',
      'is_laborable',
        COALESCE((wd.resolve ->> 'expected_minutes')::int, 0) > 0
        OR (wd.resolve ->> 'day_type') IN ('working', 'half_holiday'),
      'worked_minutes',
        COALESCE(
          CASE
            WHEN te.status IN ('closed', 'adjusted') AND te.net_minutes IS NOT NULL
              THEN te.net_minutes
            ELSE NULL
          END,
          NULLIF(tds.worked_minutes, 0),
          CASE
            WHEN punches.first_in IS NOT NULL
              AND punches.last_out IS NOT NULL
              AND punches.last_out > punches.first_in
            THEN ROUND(EXTRACT(EPOCH FROM (punches.last_out - punches.first_in)) / 60)::int
            WHEN punches.first_in IS NOT NULL
              AND (te.id IS NULL OR te.status = 'open')
              AND gs.dt::date = v_today
            THEN ROUND(EXTRACT(EPOCH FROM (now() - punches.first_in)) / 60)::int
            ELSE 0
          END
        ),
      'presence_minutes', tds.presence_minutes,
      'work_minutes', tds.work_minutes,
      'travel_minutes', COALESCE(tds.travel_minutes, 0),
      'effective_minutes', tds.effective_minutes,
      'paid_minutes', tds.paid_minutes,
      'overtime_authorized_minutes', tds.overtime_authorized_minutes,
      'work_profile_snapshot', tds.work_profile_snapshot,
      'overtime_minutes', COALESCE(tds.overtime_minutes, 0),
      'punch_count', COALESCE(tds.punch_count, COALESCE(punches.punch_count, 0)),
      'remote_punch_count', COALESCE(punches.remote_punch_count, 0),
      'entry_status', te.status,
      'summary_status', COALESCE(tds.status, 'none'),
      'needs_review', COALESCE(tds.needs_review, false),
      'anomalies', to_jsonb(COALESCE(tds.anomaly_codes, '{}'::text[])),
      'summary_id', tds.id,
      'absence_id', NULLIF(abs.config->>'absence_id', '')::uuid,
      'absence_type', NULLIF(abs.config->>'absence_type', ''),
      'absence_status', NULLIF(abs.config->>'absence_status', ''),
      'absence_is_paid', (abs.config->>'absence_is_paid')::boolean,
      'partial_start_time', abs.config->>'partial_start_time',
      'partial_end_time', abs.config->>'partial_end_time',
      'partial_hours', (abs.config->>'partial_hours')::numeric,
      'is_it', COALESCE((abs.config->>'is_it')::boolean, false),
      'it_type', CASE WHEN COALESCE((abs.config->>'is_it')::boolean, false) THEN abs.config->>'absence_type' ELSE NULL END,
      'absence_export_code', abs.config->>'export_code',
      'absence_parent_key', abs.config->>'parent_key',
      'absence_subtype_key', abs.config->>'subtype_key',
      'payroll_locked', tds.payroll_locked_at IS NOT NULL,
      'payroll_action',
        CASE
          WHEN te.status = 'open' OR COALESCE(tds.needs_review, false) OR tds.status = 'exported' OR tds.payroll_locked_at IS NOT NULL
          THEN 'blocked'
          WHEN abs.config->>'absence_id' IS NOT NULL AND abs.config->>'absence_status' IN ('approved', 'active', 'closed')
          THEN 'absence_ok'
          WHEN (COALESCE((wd.resolve ->> 'expected_minutes')::int, 0) > 0 OR (wd.resolve ->> 'day_type') IN ('working', 'half_holiday'))
            AND (te.id IS NULL OR te.status NOT IN ('closed', 'adjusted'))
            AND abs.config->>'absence_id' IS NULL
          THEN 'missing_punch'
          WHEN tds.status = 'draft' AND (
            COALESCE(tds.worked_minutes, 0) > 0
            OR COALESCE(tds.punch_count, punches.punch_count, 0) > 0
            OR te.status = 'adjusted'
          )
          THEN 'approve'
          ELSE NULL
        END
    ) AS day_row
    FROM generate_series(p_from, p_to, interval '1 day') AS gs(dt)
    CROSS JOIN LATERAL (SELECT api.resolve_work_day(p_employee_id, gs.dt::date) AS resolve) wd
    LEFT JOIN data.time_entries te ON te.employee_id = p_employee_id AND te.work_date = gs.dt::date
    LEFT JOIN data.time_daily_summaries tds ON tds.employee_id = p_employee_id AND tds.work_date = gs.dt::date
    LEFT JOIN LATERAL (
      SELECT COUNT(*)::int AS punch_count,
        COUNT(*) FILTER (WHERE tp.is_remote)::int AS remote_punch_count,
        MIN(tp.occurred_at) FILTER (WHERE tp.punch_type = 'in') AS first_in,
        MAX(tp.occurred_at) FILTER (WHERE tp.punch_type = 'out') AS last_out
      FROM data.time_punches tp
      WHERE tp.employee_id = p_employee_id
        AND (tp.occurred_at AT TIME ZONE v_tz)::date = gs.dt::date
    ) punches ON true
    LEFT JOIN LATERAL (
      SELECT data.select_absence_for_employee_day(p_employee_id, v_emp.tenant_id, gs.dt::date) AS config
    ) abs ON true
  ) q;

  RETURN jsonb_build_object('employee_id', p_employee_id, 'from', p_from, 'to', p_to, 'days', v_rows);
END;
$$;

NOTIFY pgrst, 'reload schema';
