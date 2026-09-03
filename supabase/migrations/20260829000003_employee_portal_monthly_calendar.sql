-- EP8: calendari mensual complet per confirmació (horari previst, treballat, absències, extra).

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
    COALESCE(SUM(COALESCE((d ->> 'overtime_minutes')::int, 0)), 0)
  INTO v_worked_days, v_laborable_days, v_absence_days, v_overtime_total
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
        'overtime_minutes', v_overtime_total
      )
  );
END;
$$;

NOTIFY pgrst, 'reload schema';
