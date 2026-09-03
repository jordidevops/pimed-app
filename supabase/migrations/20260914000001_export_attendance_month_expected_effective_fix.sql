-- Fix export_attendance_month:
-- 1) expected_minutes al resum: sumar resolve_work_day de tot el mes (no només dies amb time_entry).
-- 2) has_effective_time: respectar setting tenant; no activar per columnes NOT NULL DEFAULT 0.

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
  v_settings         jsonb;
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

  v_settings := data.merge_effective_settings_for_service(v_emp.tenant_id, v_emp.site_id);
  v_has_effective := COALESCE((v_settings->>'attendance_effective_time_enabled')::boolean, false);

  IF NOT v_has_effective THEN
    SELECT EXISTS (
      SELECT 1
      FROM data.time_daily_summaries t2
      WHERE t2.employee_id = p_employee_id
        AND t2.work_date BETWEEN v_from AND v_to
        AND (
          COALESCE(t2.presence_minutes, 0) > 0
          OR COALESCE(t2.effective_minutes, 0) > 0
          OR COALESCE(t2.paid_minutes, 0) > 0
          OR COALESCE(t2.work_minutes, 0) > 0
        )
    ) INTO v_has_effective;
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'work_date', te.work_date,
    'starts_at', te.starts_at,
    'ends_at', te.ends_at,
    'break_minutes', te.break_minutes,
    'net_minutes', te.net_minutes,
    'status', te.status,
    'anomaly_codes', COALESCE(tds.anomaly_codes, '{}'),
    'presence_minutes', CASE WHEN v_has_effective THEN tds.presence_minutes ELSE NULL END,
    'work_minutes', CASE WHEN v_has_effective THEN tds.work_minutes ELSE NULL END,
    'travel_minutes', CASE WHEN v_has_effective THEN tds.travel_minutes ELSE NULL END,
    'effective_minutes', CASE WHEN v_has_effective THEN NULLIF(tds.effective_minutes, 0) ELSE NULL END,
    'paid_minutes', CASE WHEN v_has_effective THEN NULLIF(tds.paid_minutes, 0) ELSE NULL END,
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

  SELECT COALESCE(SUM(te.net_minutes), 0)
  INTO v_worked
  FROM data.time_entries te
  WHERE te.employee_id = p_employee_id
    AND te.work_date BETWEEN v_from AND v_to;

  SELECT COALESCE(SUM(COALESCE((wd.resolve ->> 'expected_minutes')::int, 0)), 0)
  INTO v_expected
  FROM generate_series(v_from, v_to, interval '1 day') AS gs(dt)
  CROSS JOIN LATERAL (
    SELECT api.resolve_work_day(p_employee_id, gs.dt::date) AS resolve
  ) wd;

  IF v_has_effective THEN
    SELECT
      COALESCE(SUM(tds.presence_minutes), 0),
      COALESCE(SUM(tds.effective_minutes), 0),
      COALESCE(SUM(tds.paid_minutes), 0),
      COALESCE(SUM(COALESCE(tds.travel_minutes, 0)), 0),
      COALESCE(SUM(COALESCE(tds.overtime_minutes, 0)), 0),
      COALESCE(SUM(COALESCE(tds.overtime_authorized_minutes, 0)), 0)
    INTO v_presence, v_effective, v_paid, v_travel, v_overtime, v_ot_auth
    FROM data.time_daily_summaries tds
    WHERE tds.employee_id = p_employee_id
      AND tds.work_date BETWEEN v_from AND v_to;
  END IF;

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
      'presence_minutes', CASE WHEN v_has_effective THEN v_presence ELSE NULL END,
      'effective_minutes', CASE WHEN v_has_effective THEN v_effective ELSE NULL END,
      'paid_minutes', CASE WHEN v_has_effective THEN v_paid ELSE NULL END,
      'travel_minutes', CASE WHEN v_has_effective THEN v_travel ELSE NULL END,
      'overtime_minutes', v_overtime,
      'overtime_authorized_minutes', v_ot_auth,
      'has_effective_time', v_has_effective
    ),
    'generated_at', now()
  );
END;
$$;

-- employee_portal_get_monthly_report: mateix criteri has_effective_time al resum
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
  v_expected_total int := 0;
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

  v_has_effective := COALESCE((v_export -> 'summary' ->> 'has_effective_time')::boolean, false);

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
    COALESCE(SUM(COALESCE((d ->> 'expected_minutes')::int, 0)), 0)
  INTO v_worked_days, v_laborable_days, v_absence_days, v_overtime_total,
       v_presence_total, v_effective_total, v_paid_total, v_travel_total, v_expected_total
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
    'summary', jsonb_build_object(
      'worked_minutes', COALESCE((v_export -> 'summary' ->> 'worked_minutes')::int, 0),
      'expected_minutes', v_expected_total,
      'difference_minutes',
        COALESCE((v_export -> 'summary' ->> 'worked_minutes')::int, 0) - v_expected_total,
      'worked_days', v_worked_days,
      'laborable_days', v_laborable_days,
      'absence_days', v_absence_days,
      'overtime_minutes', v_overtime_total,
      'presence_minutes', CASE WHEN v_has_effective THEN v_presence_total ELSE NULL END,
      'effective_minutes', CASE WHEN v_has_effective THEN v_effective_total ELSE NULL END,
      'paid_minutes', CASE WHEN v_has_effective THEN v_paid_total ELSE NULL END,
      'travel_minutes', CASE WHEN v_has_effective THEN v_travel_total ELSE NULL END,
      'has_effective_time', v_has_effective
    )
  );
END;
$$;

NOTIFY pgrst, 'reload schema';
