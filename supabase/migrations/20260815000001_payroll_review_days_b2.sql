-- B2: Vista unificada de revisió nòmina per empleat (tot el període, no només dies amb fitxatge).

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
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_from > p_to THEN
    RAISE EXCEPTION 'invalid_date_range';
  END IF;

  v_days := (p_to - p_from) + 1;
  IF v_days > 93 THEN
    RAISE EXCEPTION 'date_range_too_large' USING DETAIL = 'max 93 days';
  END IF;

  SELECT e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF NOT (data.jwt_user_tenants() ? v_emp.tenant_id::text) THEN
      RAISE EXCEPTION 'insufficient_privilege';
    END IF;
    IF NOT (
      data.jwt_has_permission(v_emp.tenant_id, 'attendance.view_all', v_emp.site_id)
      OR data.jwt_has_permission(v_emp.tenant_id, 'attendance.approve', v_emp.site_id)
      OR EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = p_employee_id AND e.user_id = auth.uid()
      )
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege';
    END IF;
  END IF;

  v_tz := COALESCE(data.get_site_timezone(v_emp.site_id, v_emp.tenant_id), 'Europe/Madrid');

  SELECT COALESCE(jsonb_agg(day_row ORDER BY day_row ->> 'work_date'), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'work_date',          gs.dt::date,
      'day_type',           wd.resolve ->> 'day_type',
      'expected_minutes',   COALESCE((wd.resolve ->> 'expected_minutes')::int, 0),
      'holiday_name',       wd.resolve ->> 'holiday_name',
      'is_laborable',
        COALESCE((wd.resolve ->> 'expected_minutes')::int, 0) > 0
        OR (wd.resolve ->> 'day_type') IN ('working', 'half_holiday'),
      'worked_minutes',     COALESCE(tds.worked_minutes, 0),
      'overtime_minutes',   COALESCE(tds.overtime_minutes, 0),
      'punch_count',        COALESCE(tds.punch_count, COALESCE(punches.punch_count, 0)),
      'remote_punch_count', COALESCE(punches.remote_punch_count, 0),
      'entry_status',       te.status,
      'summary_status',     COALESCE(tds.status, 'none'),
      'needs_review',       COALESCE(tds.needs_review, false),
      'anomalies',          to_jsonb(COALESCE(tds.anomaly_codes, '{}'::text[])),
      'summary_id',         tds.id,
      'absence_id',         abs_row.absence_id,
      'absence_type',       abs_row.absence_type,
      'absence_status',   abs_row.absence_status,
      'absence_is_paid',    abs_row.absence_is_paid,
      'partial_start_time', abs_row.partial_start_time,
      'partial_end_time',   abs_row.partial_end_time,
      'partial_hours',      abs_row.partial_hours,
      'is_it',              COALESCE(abs_row.is_it, false),
      'it_type',            CASE WHEN COALESCE(abs_row.is_it, false) THEN abs_row.absence_type ELSE NULL END,
      'payroll_locked',     tds.payroll_locked_at IS NOT NULL,
      'payroll_action',
        CASE
          WHEN te.status = 'open'
            OR COALESCE(tds.needs_review, false)
            OR tds.status = 'exported'
            OR tds.payroll_locked_at IS NOT NULL
          THEN 'blocked'
          WHEN abs_row.absence_id IS NOT NULL
            AND abs_row.absence_status IN ('approved', 'active', 'closed')
          THEN 'absence_ok'
          WHEN (
            COALESCE((wd.resolve ->> 'expected_minutes')::int, 0) > 0
            OR (wd.resolve ->> 'day_type') IN ('working', 'half_holiday')
          )
            AND (te.id IS NULL OR te.status NOT IN ('closed', 'adjusted'))
          THEN 'missing_punch'
          WHEN tds.status = 'draft'
            AND (
              COALESCE(tds.worked_minutes, 0) > 0
              OR COALESCE(tds.punch_count, punches.punch_count, 0) > 0
            )
          THEN 'approve'
          ELSE NULL
        END
    ) AS day_row
    FROM generate_series(p_from, p_to, interval '1 day') AS gs(dt)
    CROSS JOIN LATERAL (
      SELECT api.resolve_work_day(p_employee_id, gs.dt::date) AS resolve
    ) wd
    LEFT JOIN data.time_entries te
      ON te.employee_id = p_employee_id
     AND te.work_date = gs.dt::date
    LEFT JOIN data.time_daily_summaries tds
      ON tds.employee_id = p_employee_id
     AND tds.work_date = gs.dt::date
    LEFT JOIN LATERAL (
      SELECT
        ea.id AS absence_id,
        ea.absence_type,
        ea.status AS absence_status,
        ea.is_paid AS absence_is_paid,
        ea.partial_start_time,
        ea.partial_end_time,
        ea.partial_hours,
        COALESCE(tatc.is_it, false) AS is_it
      FROM data.employee_absences ea
      LEFT JOIN LATERAL (
        SELECT c.is_it
        FROM data.tenant_absence_type_configs c
        WHERE c.absence_type = ea.absence_type
          AND (c.tenant_id = v_emp.tenant_id OR (c.tenant_id IS NULL AND c.is_system = true))
        ORDER BY CASE WHEN c.tenant_id = v_emp.tenant_id THEN 0 ELSE 1 END
        LIMIT 1
      ) tatc ON true
      WHERE ea.employee_id = p_employee_id
        AND ea.start_date <= gs.dt::date
        AND ea.end_date >= gs.dt::date
        AND ea.status IN ('approved', 'active', 'closed', 'requested')
      ORDER BY
        CASE ea.status
          WHEN 'active' THEN 0
          WHEN 'approved' THEN 1
          WHEN 'closed' THEN 2
          WHEN 'requested' THEN 3
          ELSE 4
        END,
        ea.created_at DESC
      LIMIT 1
    ) abs_row ON true
    LEFT JOIN LATERAL (
      SELECT
        COUNT(*)::int AS punch_count,
        COUNT(*) FILTER (WHERE tp.is_remote)::int AS remote_punch_count
      FROM data.time_punches tp
      WHERE tp.employee_id = p_employee_id
        AND (tp.occurred_at AT TIME ZONE v_tz)::date = gs.dt::date
    ) punches ON true
  ) q;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'from', p_from,
    'to', p_to,
    'days', COALESCE(v_rows, '[]'::jsonb)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_payroll_review_days(uuid, date, date) TO authenticated;

COMMENT ON FUNCTION api.get_payroll_review_days IS
  'Període de revisió nòmina per un empleat: cada dia del calendari amb horari, fitxatges, absències/IT i acció suggerida.';

NOTIFY pgrst, 'reload schema';
