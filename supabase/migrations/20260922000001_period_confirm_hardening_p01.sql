-- P0/P1 hardening: validació període, confirm només empleat, signatura, AMR bypass iso_week.

-- ── Core: cobertura confirmació empleat (sense doble RPC) ────────────────────

CREATE OR REPLACE FUNCTION data.attendance_month_employee_confirm_satisfied_core(
  p_report_status text,
  p_period_status jsonb
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_status text;
  v_cycle  text;
  v_fully  boolean;
BEGIN
  v_status := COALESCE(NULLIF(p_report_status, ''), 'draft');

  IF v_status IN ('manager_approved', 'signed', 'archived') THEN
    RETURN true;
  END IF;

  v_cycle := COALESCE(p_period_status ->> 'cycle', 'calendar_month');
  v_fully := COALESCE((p_period_status ->> 'month_fully_confirmed')::boolean, false);

  IF v_cycle = 'iso_week' THEN
    RETURN v_fully;
  END IF;

  IF v_fully THEN
    RETURN true;
  END IF;

  -- calendar_month: compatibilitat AMR legacy sense fila de període
  IF v_status = 'employee_confirmed' THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$$;

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
  v_status        text;
  v_period_status jsonb;
BEGIN
  v_status := COALESCE(NULLIF(p_report_status, ''), 'draft');

  v_period_status := api.get_attendance_month_period_status(p_employee_id, p_year, p_month);
  RETURN data.attendance_month_employee_confirm_satisfied_core(v_status, v_period_status);
END;
$$;

REVOKE ALL ON FUNCTION data.attendance_month_employee_confirm_satisfied_core(text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.attendance_month_employee_confirm_satisfied(uuid, int, int, text) FROM PUBLIC;

-- ── Validació confirmació empleat per període (cobertura + revisió) ───────────

CREATE OR REPLACE FUNCTION api.validate_attendance_period_employee_confirm(
  p_employee_id uuid,
  p_period_from date,
  p_period_to   date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp              record;
  v_today            date := (now() AT TIME ZONE 'Europe/Madrid')::date;
  v_period_end       date;
  v_blockers         jsonb := '[]'::jsonb;
  v_open_dates       date[];
  v_review_dates     date[];
  v_missing_dates    date[];
  v_settings         jsonb;
  v_require_coverage boolean := true;
  v_d                date;
  v_resolve          jsonb;
  v_is_laborable     boolean;
  v_has_entry        boolean;
  v_has_absence      boolean;
BEGIN
  IF p_period_from IS NULL OR p_period_to IS NULL OR p_period_from > p_period_to THEN
    RAISE EXCEPTION 'invalid_period_range';
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

  IF p_period_to >= v_today THEN
    v_blockers := v_blockers || jsonb_build_array(
      jsonb_build_object(
        'code', 'PERIOD_NOT_ENDED',
        'period_from', p_period_from,
        'period_to', p_period_to,
        'today', v_today
      )
    );
  END IF;

  SELECT COALESCE(array_agg(te.work_date ORDER BY te.work_date), '{}')
  INTO v_open_dates
  FROM data.time_entries te
  WHERE te.employee_id = p_employee_id
    AND te.work_date BETWEEN p_period_from AND p_period_to
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
    AND tds.work_date BETWEEN p_period_from AND p_period_to
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

  v_period_end := LEAST(p_period_to, v_today);

  IF v_require_coverage AND v_period_end >= p_period_from THEN
    FOR v_d IN
      SELECT gs::date
      FROM generate_series(p_period_from, v_period_end, interval '1 day') gs
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

  RETURN jsonb_build_object(
    'confirmable', jsonb_array_length(v_blockers) = 0,
    'blockers', v_blockers,
    'period', jsonb_build_object('from', p_period_from, 'to', p_period_to)
  );
END;
$$;

COMMENT ON FUNCTION api.validate_attendance_period_employee_confirm IS
  'Validació confirmació empleat per rang: PERIOD_NOT_ENDED, OPEN_TIME_ENTRY, NEEDS_REVIEW, MISSING_WORKDAY_RECORD.';

-- ── Confirmació període: només empleat (+ portal service) + signatura ─────────

CREATE OR REPLACE FUNCTION api.confirm_attendance_period(
  p_employee_id       uuid,
  p_period_from       date,
  p_period_to         date,
  p_confirmed_via     text DEFAULT 'tenant_app',
  p_calendar_year     int DEFAULT NULL,
  p_calendar_month    int DEFAULT NULL,
  p_source_session_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp            record;
  v_settings       jsonb;
  v_cycle          text;
  v_cycle_type     text;
  v_check          jsonb;
  v_id             uuid;
  v_report_id      uuid;
  v_cal_year       int;
  v_cal_month      int;
  v_month_from     date;
  v_month_to       date;
  v_actor          uuid;
  v_require_sig    boolean;
BEGIN
  IF p_period_from IS NULL OR p_period_to IS NULL OR p_period_from > p_period_to THEN
    RAISE EXCEPTION 'invalid_period_range';
  END IF;

  IF p_confirmed_via NOT IN ('employee_portal', 'tenant_app') THEN
    RAISE EXCEPTION 'invalid_confirmed_via';
  END IF;

  SELECT e.id, e.tenant_id, e.site_id, e.user_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  v_actor := auth.uid();

  IF v_actor IS NOT NULL THEN
    IF v_emp.user_id IS DISTINCT FROM v_actor THEN
      RAISE EXCEPTION 'insufficient_privilege';
    END IF;
  ELSIF p_confirmed_via <> 'employee_portal' THEN
    RAISE EXCEPTION 'insufficient_privilege';
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

  IF EXISTS (
    SELECT 1
    FROM data.attendance_period_confirmations c
    WHERE c.employee_id = p_employee_id
      AND c.period_from = p_period_from
      AND c.period_to = p_period_to
  ) THEN
    RAISE EXCEPTION 'period_already_confirmed'
      USING ERRCODE = 'check_violation';
  END IF;

  v_cycle := data.attendance_employee_confirm_cycle(v_settings);

  v_cal_year := COALESCE(p_calendar_year, EXTRACT(YEAR FROM p_period_from)::int);
  v_cal_month := COALESCE(p_calendar_month, EXTRACT(MONTH FROM p_period_from)::int);
  v_month_from := make_date(v_cal_year, v_cal_month, 1);
  v_month_to   := (v_month_from + interval '1 month' - interval '1 day')::date;

  IF v_cycle = 'calendar_month' THEN
    IF p_period_from <> v_month_from OR p_period_to <> v_month_to THEN
      RAISE EXCEPTION 'invalid_period_for_cycle'
        USING ERRCODE = 'check_violation',
              DETAIL = 'calendar_month requires full natural month range';
    END IF;
    v_cycle_type := 'calendar_month';
  ELSIF v_cycle = 'iso_week' THEN
    IF p_period_from <> data.iso_week_start(p_period_from)
       OR p_period_to <> p_period_from + 6 THEN
      RAISE EXCEPTION 'invalid_period_for_cycle'
        USING ERRCODE = 'check_violation',
              DETAIL = 'iso_week requires Monday–Sunday range';
    END IF;
    IF p_period_from > v_month_to OR p_period_to < v_month_from THEN
      RAISE EXCEPTION 'invalid_period_for_cycle'
        USING ERRCODE = 'check_violation',
              DETAIL = 'iso_week must intersect calendar month reference';
    END IF;
    v_cycle_type := 'iso_week';
  ELSE
    v_cycle_type := 'manual';
  END IF;

  v_check := api.validate_attendance_period_employee_confirm(
    p_employee_id, p_period_from, p_period_to
  );
  IF NOT COALESCE((v_check ->> 'confirmable')::boolean, false) THEN
    RAISE EXCEPTION 'period_not_confirmable'
      USING ERRCODE = 'check_violation',
            DETAIL = v_check::text;
  END IF;

  INSERT INTO data.attendance_period_confirmations (
    tenant_id,
    employee_id,
    period_from,
    period_to,
    cycle_type,
    calendar_year,
    calendar_month,
    confirmed_via,
    source_session_id
  ) VALUES (
    v_emp.tenant_id,
    p_employee_id,
    p_period_from,
    p_period_to,
    v_cycle_type,
    v_cal_year,
    v_cal_month,
    p_confirmed_via,
    p_source_session_id
  )
  RETURNING id INTO v_id;

  PERFORM data.log_attendance_employee_audit(
    v_emp.tenant_id,
    v_actor,
    v_emp.site_id,
    p_employee_id,
    'ATTENDANCE_PERIOD_EMPLOYEE_CONFIRMED',
    jsonb_build_object(
      'period_from', p_period_from,
      'period_to', p_period_to,
      'cycle_type', v_cycle_type,
      'year', v_cal_year,
      'month', v_cal_month,
      'confirmation_id', v_id,
      'source', CASE
        WHEN p_confirmed_via = 'employee_portal' THEN 'employee_portal'
        ELSE 'tenant_app'
      END
    )
  );

  v_report_id := data.sync_attendance_monthly_report_from_periods(
    p_employee_id,
    v_cal_year,
    v_cal_month,
    v_actor
  );

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.confirm_attendance_period(uuid, date, date, text, int, int, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.confirm_attendance_period(uuid, date, date, text, int, int, uuid) TO service_role;

-- ── validate_attendance_month_close: una sola crida period_status ───────────────

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

    v_period_status := api.get_attendance_month_period_status(p_employee_id, p_year, p_month);

    IF NOT data.attendance_month_employee_confirm_satisfied_core(
      v_report_status, v_period_status
    ) THEN
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

NOTIFY pgrst, 'reload schema';
