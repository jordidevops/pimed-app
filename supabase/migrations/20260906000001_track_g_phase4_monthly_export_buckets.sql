-- Track G Phase 4: monthly EP8 + D2 export — effective time buckets (§6.1, §10)

-- =============================================================================
-- 1. get_payroll_review_days — extra bucket columns for calendar / B2
-- =============================================================================
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
      'work_day_type',      COALESCE(wd.resolve ->> 'work_day_type', 'normal'),
      'expected_minutes',   COALESCE((wd.resolve ->> 'expected_minutes')::int, 0),
      'holiday_name',       wd.resolve ->> 'holiday_name',
      'is_laborable',
        COALESCE((wd.resolve ->> 'expected_minutes')::int, 0) > 0
        OR (wd.resolve ->> 'day_type') IN ('working', 'half_holiday'),
      'worked_minutes',
        COALESCE(
          NULLIF(tds.worked_minutes, 0),
          CASE
            WHEN punches.first_in IS NOT NULL
              AND punches.last_out IS NOT NULL
              AND punches.last_out > punches.first_in
            THEN ROUND(EXTRACT(EPOCH FROM (punches.last_out - punches.first_in)) / 60)::int
            WHEN punches.first_in IS NOT NULL
            THEN ROUND(EXTRACT(EPOCH FROM (now() - punches.first_in)) / 60)::int
            ELSE 0
          END
        ),
      'presence_minutes',           tds.presence_minutes,
      'work_minutes',               tds.work_minutes,
      'travel_minutes',             COALESCE(tds.travel_minutes, 0),
      'effective_minutes',          tds.effective_minutes,
      'paid_minutes',               tds.paid_minutes,
      'overtime_authorized_minutes', tds.overtime_authorized_minutes,
      'work_profile_snapshot',      tds.work_profile_snapshot,
      'overtime_minutes',           COALESCE(tds.overtime_minutes, 0),
      'punch_count',                COALESCE(tds.punch_count, COALESCE(punches.punch_count, 0)),
      'remote_punch_count',         COALESCE(punches.remote_punch_count, 0),
      'entry_status',               te.status,
      'summary_status',             COALESCE(tds.status, 'none'),
      'needs_review',               COALESCE(tds.needs_review, false),
      'anomalies',                  to_jsonb(COALESCE(tds.anomaly_codes, '{}'::text[])),
      'summary_id',                 tds.id,
      'absence_id',                 abs_row.absence_id,
      'absence_type',               abs_row.absence_type,
      'absence_status',             abs_row.absence_status,
      'absence_is_paid',            abs_row.absence_is_paid,
      'partial_start_time',         abs_row.partial_start_time,
      'partial_end_time',           abs_row.partial_end_time,
      'partial_hours',              abs_row.partial_hours,
      'is_it',                      COALESCE(abs_row.is_it, false),
      'it_type',                    CASE WHEN COALESCE(abs_row.is_it, false) THEN abs_row.absence_type ELSE NULL END,
      'payroll_locked',             tds.payroll_locked_at IS NOT NULL,
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
            AND COALESCE(tds.punch_count, punches.punch_count, 0) = 0
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
        COUNT(*)::int AS punch_count,
        COUNT(*) FILTER (WHERE tp.is_remote)::int AS remote_punch_count,
        MIN(tp.occurred_at) FILTER (WHERE tp.punch_type = 'in') AS first_in,
        MAX(tp.occurred_at) FILTER (WHERE tp.punch_type = 'out') AS last_out
      FROM data.time_punches tp
      WHERE tp.employee_id = p_employee_id
        AND (tp.occurred_at AT TIME ZONE v_tz)::date = gs.dt::date
    ) punches ON true
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
  ) q;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'from', p_from,
    'to', p_to,
    'days', v_rows
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_payroll_review_days(uuid, date, date) TO authenticated;

-- =============================================================================
-- 2. export_attendance_month — buckets + segment_breakdown (EP8 JSON)
-- =============================================================================
CREATE OR REPLACE FUNCTION api.export_attendance_month(
  p_employee_id uuid,
  p_year        int,
  p_month       int
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp              record;
  v_days             jsonb;
  v_from             date;
  v_to               date;
  v_worked           int;
  v_expected         int;
  v_presence         int := 0;
  v_effective        int := 0;
  v_paid             int := 0;
  v_travel           int := 0;
  v_overtime         int := 0;
  v_ot_auth          int := 0;
  v_has_effective    boolean := false;
BEGIN
  SELECT e.tenant_id, e.site_id, e.full_name INTO v_emp
  FROM data.employees e WHERE e.id = p_employee_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'employee_not_found'; END IF;

  IF auth.uid() IS NOT NULL THEN
    IF NOT (
      EXISTS (SELECT 1 FROM data.employees WHERE id = p_employee_id AND user_id = auth.uid())
      OR data.jwt_has_permission(v_emp.tenant_id, 'attendance.export', v_emp.site_id)
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  v_from := make_date(p_year, p_month, 1);
  v_to   := (v_from + interval '1 month' - interval '1 day')::date;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'work_date', te.work_date,
    'starts_at', te.starts_at,
    'ends_at', te.ends_at,
    'break_minutes', te.break_minutes,
    'net_minutes', te.net_minutes,
    'status', te.status,
    'anomaly_codes', COALESCE(tds.anomaly_codes, '{}'),
    'presence_minutes', tds.presence_minutes,
    'work_minutes', tds.work_minutes,
    'travel_minutes', tds.travel_minutes,
    'effective_minutes', tds.effective_minutes,
    'paid_minutes', tds.paid_minutes,
    'overtime_minutes', tds.overtime_minutes,
    'overtime_authorized_minutes', tds.overtime_authorized_minutes,
    'work_profile', tds.work_profile_snapshot,
    'segment_breakdown', COALESCE(seg.segments, '[]'::jsonb)
  ) ORDER BY te.work_date), '[]'::jsonb)
  INTO v_days
  FROM data.time_entries te
  LEFT JOIN data.time_daily_summaries tds
    ON tds.employee_id = te.employee_id AND tds.work_date = te.work_date
  LEFT JOIN LATERAL (
    SELECT COALESCE(jsonb_agg(
      jsonb_build_object(
        'activity_kind', s.activity_kind,
        'started_at', s.started_at,
        'ended_at', s.ended_at
      ) ORDER BY s.started_at
    ), '[]'::jsonb) AS segments
    FROM data.time_activity_segments s
    WHERE s.employee_id = te.employee_id AND s.work_date = te.work_date
  ) seg ON true
  WHERE te.employee_id = p_employee_id
    AND te.work_date BETWEEN v_from AND v_to;

  SELECT COALESCE(SUM(te.net_minutes), 0), COALESCE(SUM(tds.expected_minutes), 0)
  INTO v_worked, v_expected
  FROM data.time_entries te
  LEFT JOIN data.time_daily_summaries tds
    ON tds.employee_id = te.employee_id AND tds.work_date = te.work_date
  WHERE te.employee_id = p_employee_id AND te.work_date BETWEEN v_from AND v_to;

  SELECT
    COALESCE(SUM(tds.presence_minutes), 0),
    COALESCE(SUM(tds.effective_minutes), 0),
    COALESCE(SUM(tds.paid_minutes), 0),
    COALESCE(SUM(COALESCE(tds.travel_minutes, 0)), 0),
    COALESCE(SUM(COALESCE(tds.overtime_minutes, 0)), 0),
    COALESCE(SUM(COALESCE(tds.overtime_authorized_minutes, 0)), 0),
    EXISTS (
      SELECT 1 FROM data.time_daily_summaries t2
      WHERE t2.employee_id = p_employee_id
        AND t2.work_date BETWEEN v_from AND v_to
        AND (t2.effective_minutes IS NOT NULL OR t2.paid_minutes IS NOT NULL OR t2.presence_minutes IS NOT NULL)
    )
  INTO v_presence, v_effective, v_paid, v_travel, v_overtime, v_ot_auth, v_has_effective
  FROM data.time_daily_summaries tds
  WHERE tds.employee_id = p_employee_id AND tds.work_date BETWEEN v_from AND v_to;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'employee_name', v_emp.full_name,
    'year', p_year,
    'month', p_month,
    'days', v_days,
    'summary', jsonb_build_object(
      'worked_minutes', v_worked,
      'expected_minutes', v_expected,
      'difference_minutes', v_worked - v_expected,
      'presence_minutes', v_presence,
      'effective_minutes', v_effective,
      'paid_minutes', v_paid,
      'travel_minutes', v_travel,
      'overtime_minutes', v_overtime,
      'overtime_authorized_minutes', v_ot_auth,
      'has_effective_time', v_has_effective
    ),
    'generated_at', now()
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.export_attendance_month(uuid, int, int) TO authenticated;

-- =============================================================================
-- 3. export_payroll_period — D2 §10 bucket columns
-- =============================================================================
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
          'work_day_type',        COALESCE(wd.resolve ->> 'work_day_type', 'normal'),
          'expected_minutes',     COALESCE((wd.resolve ->> 'expected_minutes')::int, 0),
          'holiday_name',         wd.resolve ->> 'holiday_name',
          'is_laborable',
            COALESCE((wd.resolve ->> 'expected_minutes')::int, 0) > 0
            OR (wd.resolve ->> 'day_type') IN ('working', 'half_holiday'),
          'worked_minutes',       COALESCE(tds.worked_minutes, 0),
          'net_minutes',          COALESCE(tds.worked_minutes, 0),
          'presence_minutes',     tds.presence_minutes,
          'work_minutes',         tds.work_minutes,
          'travel_minutes',       COALESCE(tds.travel_minutes, 0),
          'effective_minutes',    tds.effective_minutes,
          'paid_minutes',         tds.paid_minutes,
          'overtime_minutes',     COALESCE(tds.overtime_minutes, 0),
          'overtime_authorized_minutes', tds.overtime_authorized_minutes,
          'consolidation_needs_review', COALESCE(tds.needs_review, false),
          'work_profile',         tds.work_profile_snapshot,
          'allowances',           '[]'::jsonb,
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
          'total_presence_minutes', COALESCE(SUM(tds.presence_minutes), 0),
          'total_work_minutes',     COALESCE(SUM(COALESCE(tds.work_minutes, 0)), 0),
          'total_travel_minutes',   COALESCE(SUM(COALESCE(tds.travel_minutes, 0)), 0),
          'total_effective_minutes', COALESCE(SUM(tds.effective_minutes), 0),
          'total_paid_minutes',     COALESCE(SUM(tds.paid_minutes), 0),
          'total_overtime_minutes', COALESCE(SUM(COALESCE(tds.overtime_minutes, 0)), 0),
          'total_overtime_authorized_minutes', COALESCE(SUM(COALESCE(tds.overtime_authorized_minutes, 0)), 0),
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
  'Export nòmina ampliat (dies, absències, IT, overtime, buckets temps efectiu G4). Lectura: no marca exported.';

GRANT EXECUTE ON FUNCTION api.export_payroll_period(uuid, date, date, uuid, text) TO authenticated;

-- =============================================================================
-- 4. employee_portal_get_monthly_report — summary bucket totals (EP8)
-- =============================================================================
CREATE OR REPLACE FUNCTION api.employee_portal_get_monthly_report(
  p_employee_id uuid,
  p_tenant_id   uuid,
  p_year        int,
  p_month       int
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp            record;
  v_report         record;
  v_has_report     boolean := false;
  v_export         jsonb;
  v_settings       jsonb;
  v_validation     jsonb;
  v_signing        jsonb := NULL;
  v_from           date;
  v_to             date;
  v_payroll        jsonb;
  v_calendar_days  jsonb;
  v_worked_days    int := 0;
  v_laborable_days int := 0;
  v_absence_days   int := 0;
  v_overtime_total int := 0;
  v_presence_total int := 0;
  v_effective_total int := 0;
  v_paid_total     int := 0;
  v_travel_total   int := 0;
  v_has_effective  boolean := false;
BEGIN
  SELECT e.id, e.tenant_id, e.site_id, e.full_name, e.email
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND e.tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF p_month < 1 OR p_month > 12 THEN
    RAISE EXCEPTION 'invalid_month' USING ERRCODE = 'check_violation';
  END IF;

  v_from := make_date(p_year, p_month, 1);
  v_to   := (v_from + interval '1 month' - interval '1 day')::date;

  v_export := api.export_attendance_month(p_employee_id, p_year, p_month);
  v_validation := api.validate_attendance_month_employee_confirm(p_employee_id, p_year, p_month);
  v_settings := data.merge_effective_settings_for_service(v_emp.tenant_id, v_emp.site_id);
  v_payroll := api.get_payroll_review_days(p_employee_id, v_from, v_to);

  SELECT COALESCE(jsonb_agg(enriched ORDER BY enriched ->> 'work_date'), '[]'::jsonb)
  INTO v_calendar_days
  FROM (
    SELECT
      day_row
      || jsonb_build_object(
        'starts_at', te.starts_at,
        'ends_at', te.ends_at,
        'net_minutes', te.net_minutes,
        'break_minutes', te.break_minutes,
        'balance_minutes',
          COALESCE(
            NULLIF((day_row ->> 'worked_minutes')::int, 0),
            te.net_minutes,
            0
          ) - COALESCE((day_row ->> 'expected_minutes')::int, 0)
      ) AS enriched
    FROM jsonb_array_elements(COALESCE(v_payroll -> 'days', '[]'::jsonb)) AS day_row
    LEFT JOIN data.time_entries te
      ON te.employee_id = p_employee_id
     AND te.work_date = (day_row ->> 'work_date')::date
  ) sub;

  SELECT
    COUNT(*) FILTER (WHERE COALESCE((d ->> 'worked_minutes')::int, 0) > 0),
    COUNT(*) FILTER (WHERE COALESCE((d ->> 'is_laborable')::boolean, false)),
    COUNT(*) FILTER (WHERE d ->> 'absence_id' IS NOT NULL),
    COALESCE(SUM(COALESCE((d ->> 'overtime_minutes')::int, 0)), 0),
    COALESCE(SUM(COALESCE((d ->> 'presence_minutes')::int, 0)), 0),
    COALESCE(SUM(COALESCE((d ->> 'effective_minutes')::int, 0)), 0),
    COALESCE(SUM(COALESCE((d ->> 'paid_minutes')::int, 0)), 0),
    COALESCE(SUM(COALESCE((d ->> 'travel_minutes')::int, 0)), 0),
    EXISTS (
      SELECT 1 FROM jsonb_array_elements(COALESCE(v_calendar_days, '[]'::jsonb)) AS x
      WHERE (x ->> 'effective_minutes') IS NOT NULL
         OR (x ->> 'paid_minutes') IS NOT NULL
         OR (x ->> 'presence_minutes') IS NOT NULL
    )
  INTO v_worked_days, v_laborable_days, v_absence_days, v_overtime_total,
       v_presence_total, v_effective_total, v_paid_total, v_travel_total, v_has_effective
  FROM jsonb_array_elements(COALESCE(v_calendar_days, '[]'::jsonb)) AS d;

  SELECT
    amr.id,
    amr.status,
    amr.confirmed_at,
    amr.approved_at,
    amr.signing_submission_id,
    amr.document_id,
    amr.content_hash
  INTO v_report
  FROM data.attendance_monthly_reports amr
  WHERE amr.employee_id = p_employee_id
    AND amr.year = p_year
    AND amr.month = p_month;

  v_has_report := FOUND;

  IF v_has_report AND v_report.signing_submission_id IS NOT NULL THEN
    SELECT jsonb_build_object(
      'submission_id', ss.id,
      'status', ss.status,
      'signers', ss.signers
    )
    INTO v_signing
    FROM data.signing_submissions ss
    WHERE ss.id = v_report.signing_submission_id;
  END IF;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'tenant_id', p_tenant_id,
    'year', p_year,
    'month', p_month,
    'employee_name', v_emp.full_name,
    'employee_email', v_emp.email,
    'report', CASE
      WHEN NOT v_has_report THEN jsonb_build_object(
        'id', NULL,
        'status', 'draft',
        'confirmed_at', NULL,
        'approved_at', NULL,
        'signing_submission_id', NULL,
        'document_id', NULL,
        'content_hash', NULL
      )
      ELSE jsonb_build_object(
        'id', v_report.id,
        'status', v_report.status,
        'confirmed_at', v_report.confirmed_at,
        'approved_at', v_report.approved_at,
        'signing_submission_id', v_report.signing_submission_id,
        'document_id', v_report.document_id,
        'content_hash', v_report.content_hash
      )
    END,
    'export', v_export,
    'calendar_days', COALESCE(v_calendar_days, '[]'::jsonb),
    'settings', jsonb_build_object(
      'employee_confirm_required', COALESCE(
        (v_settings->>'attendance_monthly_employee_confirm_required')::boolean, true
      ),
      'require_digital_signature', COALESCE(
        (v_settings->>'attendance_monthly_require_digital_signature')::boolean, false
      )
    ),
    'validation', v_validation,
    'signing', v_signing,
    'summary', (v_export -> 'summary')
      || jsonb_build_object(
        'worked_days', v_worked_days,
        'laborable_days', v_laborable_days,
        'absence_days', v_absence_days,
        'overtime_minutes', v_overtime_total,
        'presence_minutes', v_presence_total,
        'effective_minutes', v_effective_total,
        'paid_minutes', v_paid_total,
        'travel_minutes', v_travel_total,
        'has_effective_time', COALESCE(v_has_effective, false)
          OR COALESCE((v_export -> 'summary' ->> 'has_effective_time')::boolean, false)
      )
  );
END;
$$;

NOTIFY pgrst, 'reload schema';
