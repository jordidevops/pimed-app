-- Fase 5: tancament gestor segons cobertura de confirmacions per període.

CREATE OR REPLACE FUNCTION data.attendance_month_employee_confirm_satisfied(
  p_employee_id   uuid,
  p_year          int,
  p_month         int,
  p_report_status text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_status         text;
  v_period_status  jsonb;
BEGIN
  v_status := COALESCE(NULLIF(p_report_status, ''), 'draft');

  IF v_status IN ('employee_confirmed', 'manager_approved', 'signed', 'archived') THEN
    RETURN true;
  END IF;

  v_period_status := api.get_attendance_month_period_status(p_employee_id, p_year, p_month);
  RETURN COALESCE((v_period_status->>'month_fully_confirmed')::boolean, false);
END;
$$;

REVOKE ALL ON FUNCTION data.attendance_month_employee_confirm_satisfied(uuid, int, int, text) FROM PUBLIC;

-- ── Validació tancament: bloqueig si falta confirmació empleat per període ────

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
  v_emp                       record;
  v_from                      date;
  v_to                        date;
  v_today                     date := (now() AT TIME ZONE 'Europe/Madrid')::date;
  v_cur_year                  int  := EXTRACT(YEAR FROM v_today)::int;
  v_cur_month                 int  := EXTRACT(MONTH FROM v_today)::int;
  v_blockers                  jsonb := '[]'::jsonb;
  v_warnings                  jsonb := '[]'::jsonb;
  v_settings                  jsonb;
  v_require_coverage          boolean := true;
  v_require_employee_confirm  boolean := true;
  v_can_close_without         boolean := true;
  v_diff_warn_min             int     := 120;
  v_d                         date;
  v_resolve                   jsonb;
  v_open_dates                date[];
  v_review_dates              date[];
  v_missing_dates             date[];
  v_draft_count               int := 0;
  v_anomaly_count             int := 0;
  v_worked_total              int := 0;
  v_expected_total            int := 0;
  v_diff_minutes              int := 0;
  v_is_laborable              boolean;
  v_has_entry                 boolean;
  v_has_absence               boolean;
  v_report_status             text;
  v_period_status             jsonb;
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
  v_require_employee_confirm := COALESCE(
    (v_settings->>'attendance_monthly_employee_confirm_required')::boolean,
    true
  );
  v_can_close_without := COALESCE(
    (v_settings->>'attendance_monthly_manager_can_close_without_employee')::boolean,
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

  IF v_require_employee_confirm AND NOT v_can_close_without THEN
    SELECT amr.status INTO v_report_status
    FROM data.attendance_monthly_reports amr
    WHERE amr.employee_id = p_employee_id
      AND amr.year = p_year
      AND amr.month = p_month;

    IF v_report_status IS NULL THEN
      v_report_status := 'draft';
    END IF;

    IF NOT data.attendance_month_employee_confirm_satisfied(
      p_employee_id, p_year, p_month, v_report_status
    ) THEN
      v_period_status := api.get_attendance_month_period_status(p_employee_id, p_year, p_month);
      v_blockers := v_blockers || jsonb_build_array(
        jsonb_build_object(
          'code', 'EMPLOYEE_PERIOD_CONFIRM_INCOMPLETE',
          'cycle', v_period_status->>'cycle',
          'weeks_confirmed', (v_period_status->>'weeks_confirmed')::int,
          'weeks_required', (v_period_status->>'weeks_required')::int,
          'month_fully_confirmed', (v_period_status->>'month_fully_confirmed')::boolean
        )
      );
    END IF;
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

-- ── Tancament gestor: mateixa regla de cobertura de períodes ─────────────────

CREATE OR REPLACE FUNCTION api.approve_attendance_month(
  p_employee_id uuid, p_year int, p_month int
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = data, api
AS $$
DECLARE
  v_id                    uuid;
  v_emp                   record;
  v_check                 jsonb;
  v_settings              jsonb;
  v_require_confirm       boolean := true;
  v_can_close_without     boolean := true;
  v_bulk_approve          boolean := true;
  v_report_status         text;
  v_month_start           date;
  v_month_end             date;
BEGIN
  v_month_start := make_date(p_year, p_month, 1);
  v_month_end   := (v_month_start + interval '1 month' - interval '1 day')::date;

  SELECT * INTO v_emp FROM data.employees WHERE id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.approve', v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege';
  END IF;

  v_check := api.validate_attendance_month_close(p_employee_id, p_year, p_month);
  IF NOT COALESCE((v_check->>'closable')::boolean, false) THEN
    RAISE EXCEPTION 'month_not_closable'
      USING ERRCODE = 'check_violation',
            DETAIL = v_check::text;
  END IF;

  v_settings := api.get_effective_settings(
    p_site_id   => v_emp.site_id,
    p_tenant_id => v_emp.tenant_id
  );
  v_require_confirm := COALESCE(
    (v_settings->>'attendance_monthly_employee_confirm_required')::boolean,
    true
  );
  v_can_close_without := COALESCE(
    (v_settings->>'attendance_monthly_manager_can_close_without_employee')::boolean,
    true
  );
  v_bulk_approve := COALESCE(
    (v_settings->>'attendance_monthly_bulk_approve_days_on_close')::boolean,
    true
  );

  SELECT amr.status INTO v_report_status
  FROM data.attendance_monthly_reports amr
  WHERE amr.employee_id = p_employee_id
    AND amr.year = p_year
    AND amr.month = p_month;

  IF v_report_status IS NULL THEN
    v_report_status := 'draft';
  END IF;

  IF v_require_confirm
     AND NOT v_can_close_without
     AND NOT data.attendance_month_employee_confirm_satisfied(
       p_employee_id, p_year, p_month, v_report_status
     ) THEN
    RAISE EXCEPTION 'employee_confirmation_required'
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_bulk_approve THEN
    UPDATE data.time_daily_summaries tds
    SET
      status      = 'approved',
      approved_by = auth.uid(),
      approved_at = now(),
      updated_at  = now()
    WHERE tds.employee_id = p_employee_id
      AND tds.work_date BETWEEN v_month_start AND v_month_end
      AND tds.status = 'draft'
      AND tds.payroll_locked_at IS NULL;
  END IF;

  INSERT INTO data.attendance_monthly_reports (tenant_id, employee_id, year, month, status, approved_by, approved_at)
  VALUES (v_emp.tenant_id, p_employee_id, p_year, p_month, 'manager_approved', auth.uid(), now())
  ON CONFLICT (employee_id, year, month) DO UPDATE SET
    status = 'manager_approved', approved_by = auth.uid(), approved_at = now(), updated_at = now()
  RETURNING id INTO v_id;

  PERFORM data.log_attendance_employee_audit(
    v_emp.tenant_id,
    auth.uid(),
    v_emp.site_id,
    p_employee_id,
    'ATTENDANCE_MONTH_MANAGER_CLOSED',
    jsonb_build_object(
      'year', p_year,
      'month', p_month,
      'report_id', v_id,
      'previous_status', v_report_status,
      'bulk_approve_days', v_bulk_approve
    )
  );

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.approve_attendance_month(uuid, int, int) TO authenticated;
