-- EP8 fix: portal monthly sense auth.users — get_effective_settings exigeix auth.uid().

CREATE OR REPLACE FUNCTION api.validate_attendance_month_close(
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
  v_from             date;
  v_to               date;
  v_today            date := (now() AT TIME ZONE 'Europe/Madrid')::date;
  v_cur_year         int  := EXTRACT(YEAR FROM v_today)::int;
  v_cur_month        int  := EXTRACT(MONTH FROM v_today)::int;
  v_blockers         jsonb := '[]'::jsonb;
  v_warnings         jsonb := '[]'::jsonb;
  v_settings         jsonb;
  v_require_coverage boolean := true;
  v_diff_warn_min    int     := 120;
  v_d                date;
  v_resolve          jsonb;
  v_open_dates       date[];
  v_review_dates     date[];
  v_missing_dates    date[];
  v_draft_count      int := 0;
  v_anomaly_count    int := 0;
  v_worked_total     int := 0;
  v_expected_total   int := 0;
  v_diff_minutes     int := 0;
  v_is_laborable     boolean;
  v_has_entry        boolean;
  v_has_absence      boolean;
BEGIN
  IF p_month < 1 OR p_month > 12 THEN
    RAISE EXCEPTION 'invalid_month';
  END IF;

  SELECT e.id, e.tenant_id, e.site_id, e.user_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF NOT (
      data.jwt_has_permission(v_emp.tenant_id, 'attendance.approve', v_emp.site_id)
      OR data.jwt_has_permission(v_emp.tenant_id, 'attendance.view_all', v_emp.site_id)
      OR v_emp.user_id = auth.uid()
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege';
    END IF;
  END IF;

  v_from := make_date(p_year, p_month, 1);
  v_to   := (v_from + interval '1 month' - interval '1 day')::date;

  IF auth.uid() IS NULL THEN
    v_settings := data.merge_effective_settings_for_service(v_emp.tenant_id, v_emp.site_id);
  ELSE
    v_settings := api.get_effective_settings(
      p_site_id   => v_emp.site_id,
      p_tenant_id => v_emp.tenant_id
    );
  END IF;

  v_require_coverage := COALESCE(
    (v_settings->>'attendance_monthly_require_workday_coverage')::boolean,
    true
  );
  v_diff_warn_min := COALESCE(
    NULLIF((v_settings->>'attendance_monthly_close_diff_warning_minutes')::int, 0),
    120
  );

  IF p_year > v_cur_year OR (p_year = v_cur_year AND p_month > v_cur_month) THEN
    v_blockers := v_blockers || jsonb_build_array(
      jsonb_build_object('code', 'FUTURE_MONTH', 'year', p_year, 'month', p_month)
    );
  END IF;

  IF p_year = v_cur_year AND p_month = v_cur_month AND v_today < v_to THEN
  FOR v_d IN
    SELECT gs::date
    FROM generate_series(v_today + 1, v_to, interval '1 day') gs
  LOOP
    v_resolve := api.resolve_work_day(p_employee_id, v_d);
    IF COALESCE((v_resolve->>'expected_minutes')::int, 0) > 0
       OR (v_resolve->>'day_type') IN ('working', 'half_holiday') THEN
      v_blockers := v_blockers || jsonb_build_array(
        jsonb_build_object('code', 'CURRENT_MONTH_INCOMPLETE', 'work_date', v_d)
      );
      EXIT;
    END IF;
  END LOOP;
  END IF;

  SELECT COALESCE(array_agg(te.work_date ORDER BY te.work_date), '{}')
  INTO v_open_dates
  FROM data.time_entries te
  WHERE te.employee_id = p_employee_id
    AND te.work_date BETWEEN v_from AND v_to
    AND te.status = 'open';

  IF cardinality(v_open_dates) > 0 THEN
    v_blockers := v_blockers || jsonb_build_array(
      jsonb_build_object(
        'code', 'OPEN_TIME_ENTRY',
        'count', cardinality(v_open_dates),
        'work_dates', to_jsonb(v_open_dates)
      )
    );
  END IF;

  SELECT COALESCE(array_agg(tds.work_date ORDER BY tds.work_date), '{}')
  INTO v_review_dates
  FROM data.time_daily_summaries tds
  WHERE tds.employee_id = p_employee_id
    AND tds.work_date BETWEEN v_from AND v_to
    AND tds.needs_review = true;

  IF cardinality(v_review_dates) > 0 THEN
    v_blockers := v_blockers || jsonb_build_array(
      jsonb_build_object(
        'code', 'NEEDS_REVIEW',
        'count', cardinality(v_review_dates),
        'work_dates', to_jsonb(v_review_dates)
      )
    );
  END IF;

  IF v_require_coverage THEN
    FOR v_d IN
      SELECT gs::date
      FROM generate_series(v_from, LEAST(v_to, v_today), interval '1 day') gs
    LOOP
      v_resolve := api.resolve_work_day(p_employee_id, v_d);
      v_is_laborable := COALESCE((v_resolve->>'expected_minutes')::int, 0) > 0
        OR (v_resolve->>'day_type') IN ('working', 'half_holiday');

      IF NOT v_is_laborable OR (v_resolve->>'is_absence')::boolean IS TRUE THEN
        CONTINUE;
      END IF;

      SELECT EXISTS (
        SELECT 1 FROM data.time_entries te
        WHERE te.employee_id = p_employee_id
          AND te.work_date = v_d
          AND te.status IN ('closed', 'adjusted')
      ) INTO v_has_entry;

      IF v_has_entry THEN
        CONTINUE;
      END IF;

      SELECT EXISTS (
        SELECT 1 FROM data.employee_absences ea
        WHERE ea.employee_id = p_employee_id
          AND ea.status = 'approved'
          AND ea.start_date <= v_d
          AND ea.end_date >= v_d
      ) INTO v_has_absence;

      IF NOT v_has_absence THEN
        v_missing_dates := array_append(v_missing_dates, v_d);
      END IF;
    END LOOP;

    IF cardinality(v_missing_dates) > 0 THEN
      v_blockers := v_blockers || jsonb_build_array(
        jsonb_build_object(
          'code', 'MISSING_WORKDAY_RECORD',
          'count', cardinality(v_missing_dates),
          'work_dates', to_jsonb(v_missing_dates)
        )
      );
    END IF;
  END IF;

  SELECT COUNT(*)::int INTO v_draft_count
  FROM data.time_daily_summaries tds
  WHERE tds.employee_id = p_employee_id
    AND tds.work_date BETWEEN v_from AND v_to
    AND tds.status = 'draft'
    AND tds.work_date <= v_today;

  IF v_draft_count > 0 THEN
    v_warnings := v_warnings || jsonb_build_array(
      jsonb_build_object('code', 'DRAFT_DAYS', 'count', v_draft_count)
    );
  END IF;

  SELECT COUNT(*)::int INTO v_anomaly_count
  FROM data.time_daily_summaries tds
  WHERE tds.employee_id = p_employee_id
    AND tds.work_date BETWEEN v_from AND v_to
    AND tds.needs_review = false
    AND cardinality(COALESCE(tds.anomaly_codes, '{}')) > 0;

  IF v_anomaly_count > 0 THEN
    v_warnings := v_warnings || jsonb_build_array(
      jsonb_build_object('code', 'ANOMALY_DAYS', 'count', v_anomaly_count)
    );
  END IF;

  SELECT
    COALESCE(SUM(tds.worked_minutes), 0),
    COALESCE(SUM(tds.expected_minutes), 0)
  INTO v_worked_total, v_expected_total
  FROM data.time_daily_summaries tds
  WHERE tds.employee_id = p_employee_id
    AND tds.work_date BETWEEN v_from AND v_to
    AND tds.work_date <= v_today;

  v_diff_minutes := ABS(v_worked_total - v_expected_total);

  IF v_expected_total > 0 AND v_diff_minutes > v_diff_warn_min THEN
    v_warnings := v_warnings || jsonb_build_array(
      jsonb_build_object(
        'code', 'WORKED_EXPECTED_DIFF',
        'worked_minutes', v_worked_total,
        'expected_minutes', v_expected_total,
        'difference_minutes', v_worked_total - v_expected_total,
        'threshold_minutes', v_diff_warn_min
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'closable', jsonb_array_length(v_blockers) = 0,
    'blockers', v_blockers,
    'warnings', v_warnings,
    'period', jsonb_build_object('from', v_from, 'to', v_to),
    'summary', jsonb_build_object(
      'open_entries', cardinality(v_open_dates),
      'needs_review_days', cardinality(v_review_dates),
      'missing_workdays', cardinality(v_missing_dates),
      'draft_days', v_draft_count,
      'anomaly_days', v_anomaly_count,
      'worked_minutes', v_worked_total,
      'expected_minutes', v_expected_total
    )
  );
END;
$$;

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
  v_emp         record;
  v_report      record;
  v_has_report  boolean := false;
  v_export      jsonb;
  v_settings    jsonb;
  v_validation  jsonb;
  v_signing     jsonb := NULL;
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

  v_export := api.export_attendance_month(p_employee_id, p_year, p_month);
  v_validation := api.validate_attendance_month_employee_confirm(p_employee_id, p_year, p_month);
  v_settings := data.merge_effective_settings_for_service(v_emp.tenant_id, v_emp.site_id);

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
    'settings', jsonb_build_object(
      'employee_confirm_required', COALESCE(
        (v_settings->>'attendance_monthly_employee_confirm_required')::boolean, true
      ),
      'require_digital_signature', COALESCE(
        (v_settings->>'attendance_monthly_require_digital_signature')::boolean, false
      )
    ),
    'validation', v_validation,
    'signing', v_signing
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.employee_portal_confirm_monthly_report(
  p_employee_id uuid,
  p_tenant_id   uuid,
  p_year        int,
  p_month       int
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp         record;
  v_id          uuid;
  v_check       jsonb;
  v_settings    jsonb;
  v_status      text;
  v_require_sig boolean;
BEGIN
  SELECT e.tenant_id, e.site_id
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

  v_settings := data.merge_effective_settings_for_service(v_emp.tenant_id, v_emp.site_id);
  v_require_sig := COALESCE(
    (v_settings->>'attendance_monthly_require_digital_signature')::boolean,
    false
  );

  IF v_require_sig THEN
    RAISE EXCEPTION 'digital_signature_required'
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT amr.status INTO v_status
  FROM data.attendance_monthly_reports amr
  WHERE amr.employee_id = p_employee_id
    AND amr.year = p_year
    AND amr.month = p_month;

  IF v_status IN ('employee_confirmed', 'manager_approved', 'signed', 'archived') THEN
    RAISE EXCEPTION 'already_confirmed' USING ERRCODE = 'check_violation';
  END IF;

  v_check := api.validate_attendance_month_employee_confirm(p_employee_id, p_year, p_month);
  IF NOT COALESCE((v_check->>'confirmable')::boolean, false) THEN
    RAISE EXCEPTION 'month_not_confirmable'
      USING ERRCODE = 'check_violation',
            DETAIL = v_check::text;
  END IF;

  INSERT INTO data.attendance_monthly_reports (
    tenant_id, employee_id, year, month, status, confirmed_at
  )
  VALUES (
    v_emp.tenant_id, p_employee_id, p_year, p_month, 'employee_confirmed', now()
  )
  ON CONFLICT (employee_id, year, month) DO UPDATE SET
    status = 'employee_confirmed',
    confirmed_at = COALESCE(data.attendance_monthly_reports.confirmed_at, now()),
    updated_at = now()
  RETURNING id INTO v_id;

  PERFORM data.log_attendance_employee_audit(
    v_emp.tenant_id,
    NULL,
    v_emp.site_id,
    p_employee_id,
    'ATTENDANCE_MONTH_EMPLOYEE_CONFIRMED',
    jsonb_build_object(
      'year', p_year,
      'month', p_month,
      'report_id', v_id,
      'source', 'employee_portal'
    )
  );

  RETURN v_id;
END;
$$;

NOTIFY pgrst, 'reload schema';
