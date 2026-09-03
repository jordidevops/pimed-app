-- D2: Export CSV nòmina ampliat (lectura; NO marca exported ni payroll_locked).

CREATE OR REPLACE FUNCTION api.export_payroll_period(
  p_site_id     uuid,
  p_from        date,
  p_to          date,
  p_employee_id uuid DEFAULT NULL,
  p_format      text DEFAULT 'daily'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id  uuid;
  v_site_name  text;
  v_days       int;
  v_rows       jsonb;
  v_count      int;
  v_format     text;
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_from > p_to THEN
    RAISE EXCEPTION 'invalid_date_range';
  END IF;

  v_days := (p_to - p_from) + 1;
  IF v_days > 93 THEN
    RAISE EXCEPTION 'date_range_too_large' USING DETAIL = 'max 93 days';
  END IF;

  v_format := lower(COALESCE(p_format, 'daily'));
  IF v_format NOT IN ('daily', 'aggregate') THEN
    RAISE EXCEPTION 'invalid_format' USING DETAIL = 'daily or aggregate';
  END IF;

  SELECT s.tenant_id, s.name INTO v_tenant_id, v_site_name
  FROM data.sites s
  WHERE s.id = p_site_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_not_found: %', p_site_id USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.export', p_site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.export required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_format = 'daily' THEN
    SELECT
      COALESCE(jsonb_agg(row_data ORDER BY sort_name, sort_date), '[]'::jsonb),
      COUNT(*)
    INTO v_rows, v_count
    FROM (
      SELECT
        jsonb_build_object(
          'employee_id',          e.id,
          'employee_name',        e.full_name,
          'document_id',          e.document_id,
          'work_date',            gs.dt::date,
          'day_type',             wd.resolve ->> 'day_type',
          'expected_minutes',     COALESCE((wd.resolve ->> 'expected_minutes')::int, 0),
          'holiday_name',         wd.resolve ->> 'holiday_name',
          'is_laborable',
            COALESCE((wd.resolve ->> 'expected_minutes')::int, 0) > 0
            OR (wd.resolve ->> 'day_type') IN ('working', 'half_holiday'),
          'worked_minutes',       COALESCE(tds.worked_minutes, 0),
          'overtime_minutes',     COALESCE(tds.overtime_minutes, 0),
          'punch_count',          COALESCE(tds.punch_count, COALESCE(punches.punch_count, 0)),
          'remote_punch_count',   COALESCE(punches.remote_punch_count, 0),
          'entry_status',         te.status,
          'summary_status',       COALESCE(tds.status, 'none'),
          'needs_review',         COALESCE(tds.needs_review, false),
          'anomaly_codes',        to_jsonb(COALESCE(tds.anomaly_codes, '{}'::text[])),
          'payroll_locked',       tds.payroll_locked_at IS NOT NULL,
          'absence_id',           abs_row.absence_id,
          'absence_type',         abs_row.absence_type,
          'absence_type_name',    abs_row.absence_type_name,
          'absence_status',       abs_row.absence_status,
          'absence_is_paid',      abs_row.absence_is_paid,
          'partial_start_time',   abs_row.partial_start_time,
          'partial_end_time',     abs_row.partial_end_time,
          'partial_hours',        abs_row.partial_hours,
          'is_it',                COALESCE(abs_row.is_it, false),
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
        ) AS row_data,
        e.full_name AS sort_name,
        gs.dt::date AS sort_date
      FROM data.employees e
      CROSS JOIN generate_series(p_from, p_to, interval '1 day') AS gs(dt)
      CROSS JOIN LATERAL (
        SELECT api.resolve_work_day(e.id, gs.dt::date) AS resolve
      ) wd
      LEFT JOIN data.time_entries te
        ON te.employee_id = e.id
       AND te.work_date = gs.dt::date
      LEFT JOIN data.time_daily_summaries tds
        ON tds.employee_id = e.id
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
          COALESCE(tatc.is_it, false) AS is_it,
          COALESCE(
            tatc.name_i18n ->> 'ca',
            tatc.name_i18n ->> 'es',
            ea.absence_type
          ) AS absence_type_name
        FROM data.employee_absences ea
        LEFT JOIN LATERAL (
          SELECT c.is_it, c.name_i18n
          FROM data.tenant_absence_type_configs c
          WHERE c.absence_type = ea.absence_type
            AND (c.tenant_id = e.tenant_id OR (c.tenant_id IS NULL AND c.is_system = true))
          ORDER BY CASE WHEN c.tenant_id = e.tenant_id THEN 0 ELSE 1 END
          LIMIT 1
        ) tatc ON true
        WHERE ea.employee_id = e.id
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
        WHERE tp.employee_id = e.id
          AND (tp.occurred_at AT TIME ZONE COALESCE(
            data.get_site_timezone(e.site_id, e.tenant_id),
            'Europe/Madrid'
          ))::date = gs.dt::date
      ) punches ON true
      WHERE e.site_id = p_site_id
        AND e.tenant_id = v_tenant_id
        AND e.status = 'active'
        AND (p_employee_id IS NULL OR e.id = p_employee_id)
    ) sub;
  ELSE
    SELECT
      COALESCE(jsonb_agg(row_data ORDER BY sort_name), '[]'::jsonb),
      COUNT(*)
    INTO v_rows, v_count
    FROM (
      SELECT
        jsonb_build_object(
          'employee_id',            e.id,
          'employee_name',          e.full_name,
          'document_id',            e.document_id,
          'period_from',            p_from,
          'period_to',              p_to,
          'total_expected_minutes', COALESCE(SUM(COALESCE((wd.resolve ->> 'expected_minutes')::int, 0)), 0),
          'total_worked_minutes',   COALESCE(SUM(COALESCE(tds.worked_minutes, 0)), 0),
          'total_overtime_minutes', COALESCE(SUM(COALESCE(tds.overtime_minutes, 0)), 0),
          'laborable_days',
            COUNT(*) FILTER (
              WHERE COALESCE((wd.resolve ->> 'expected_minutes')::int, 0) > 0
                OR (wd.resolve ->> 'day_type') IN ('working', 'half_holiday')
            ),
          'worked_days',
            COUNT(*) FILTER (WHERE COALESCE(tds.worked_minutes, 0) > 0),
          'absence_days',
            COUNT(*) FILTER (
              WHERE abs_row.absence_id IS NOT NULL
                AND abs_row.absence_status IN ('approved', 'active', 'closed')
                AND NOT COALESCE(abs_row.is_it, false)
            ),
          'it_days',
            COUNT(*) FILTER (
              WHERE abs_row.absence_id IS NOT NULL
                AND COALESCE(abs_row.is_it, false)
                AND abs_row.absence_status IN ('approved', 'active', 'closed')
            ),
          'missing_punch_days',
            COUNT(*) FILTER (
              WHERE (
                COALESCE((wd.resolve ->> 'expected_minutes')::int, 0) > 0
                OR (wd.resolve ->> 'day_type') IN ('working', 'half_holiday')
              )
                AND abs_row.absence_id IS NULL
                AND (te.id IS NULL OR te.status NOT IN ('closed', 'adjusted'))
            ),
          'draft_days',
            COUNT(*) FILTER (WHERE tds.status = 'draft'),
          'approved_days',
            COUNT(*) FILTER (WHERE tds.status = 'approved'),
          'exported_days',
            COUNT(*) FILTER (WHERE tds.status = 'exported'),
          'remote_punch_days',
            COUNT(*) FILTER (WHERE COALESCE(punches.remote_punch_count, 0) > 0)
        ) AS row_data,
        e.full_name AS sort_name
      FROM data.employees e
      CROSS JOIN generate_series(p_from, p_to, interval '1 day') AS gs(dt)
      CROSS JOIN LATERAL (
        SELECT api.resolve_work_day(e.id, gs.dt::date) AS resolve
      ) wd
      LEFT JOIN data.time_entries te
        ON te.employee_id = e.id
       AND te.work_date = gs.dt::date
      LEFT JOIN data.time_daily_summaries tds
        ON tds.employee_id = e.id
       AND tds.work_date = gs.dt::date
      LEFT JOIN LATERAL (
        SELECT
          ea.id AS absence_id,
          ea.status AS absence_status,
          COALESCE(tatc.is_it, false) AS is_it
        FROM data.employee_absences ea
        LEFT JOIN LATERAL (
          SELECT c.is_it
          FROM data.tenant_absence_type_configs c
          WHERE c.absence_type = ea.absence_type
            AND (c.tenant_id = e.tenant_id OR (c.tenant_id IS NULL AND c.is_system = true))
          ORDER BY CASE WHEN c.tenant_id = e.tenant_id THEN 0 ELSE 1 END
          LIMIT 1
        ) tatc ON true
        WHERE ea.employee_id = e.id
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
        SELECT COUNT(*) FILTER (WHERE tp.is_remote)::int AS remote_punch_count
        FROM data.time_punches tp
        WHERE tp.employee_id = e.id
          AND (tp.occurred_at AT TIME ZONE COALESCE(
            data.get_site_timezone(e.site_id, e.tenant_id),
            'Europe/Madrid'
          ))::date = gs.dt::date
      ) punches ON true
      WHERE e.site_id = p_site_id
        AND e.tenant_id = v_tenant_id
        AND e.status = 'active'
        AND (p_employee_id IS NULL OR e.id = p_employee_id)
      GROUP BY e.id, e.full_name, e.document_id
    ) sub;
  END IF;

  RETURN jsonb_build_object(
    'site_id',      p_site_id,
    'site_name',    v_site_name,
    'tenant_id',    v_tenant_id,
    'from',         p_from,
    'to',           p_to,
    'format',       v_format,
    'row_count',    COALESCE(v_count, 0),
    'rows',         COALESCE(v_rows, '[]'::jsonb),
    'generated_at', now(),
    'read_only',    true
  );
END;
$$;

COMMENT ON FUNCTION api.export_payroll_period(uuid, date, date, uuid, text) IS
  'Export nòmina ampliat (dies, absències, IT, overtime). Lectura: no marca exported ni bloqueja dies.';

GRANT EXECUTE ON FUNCTION api.export_payroll_period(uuid, date, date, uuid, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
