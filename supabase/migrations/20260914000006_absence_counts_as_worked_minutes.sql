-- Absències amb counts_as_worked: comptar hores previstes de l'horari a worked_minutes.

-- 1. resolve_work_day: exposar absence_counts_as_worked
CREATE OR REPLACE FUNCTION api.resolve_work_day(
  p_employee_id  uuid,
  p_work_date    date
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp                 record;
  v_tz                  text;
  v_expected_min        int     := 0;
  v_spans_midnight      boolean := false;
  v_shift_start         time;
  v_shift_end           time;
  v_day_type            text    := 'unknown';
  v_absence             record;
  v_emp_override        text;
  v_skip_holiday        boolean := false;
  v_labor               record;
  v_bounds              record;
  v_is_holiday          boolean := false;
  v_holiday_name        text;
  v_work_intervals      jsonb;
BEGIN
  SELECT e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'day_type', 'unknown',
      'expected_minutes', 0,
      'work_day_type', 'normal',
      'error', 'employee_not_found'
    );
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF NOT (data.jwt_user_tenants() ? v_emp.tenant_id::text) THEN
      RAISE EXCEPTION 'insufficient_privilege: access denied for employee %', p_employee_id
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NOT (
      data.jwt_has_permission(v_emp.tenant_id, 'attendance.view_all')
      OR data.jwt_has_permission(v_emp.tenant_id, 'labor_calendar.manage')
      OR EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = p_employee_id AND e.user_id = auth.uid()
      )
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege: necessites attendance.view_all o ser l''empleat consultat'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  v_tz := COALESCE(data.get_site_timezone(v_emp.site_id, v_emp.tenant_id), 'Europe/Madrid');

  SELECT ea.id, ea.absence_type, ea.is_paid, ea.hours_per_day, ea.counts_as_worked
  INTO v_absence
  FROM data.employee_absences ea
  WHERE ea.employee_id = p_employee_id
    AND ea.status      = 'approved'
    AND ea.start_date  <= p_work_date
    AND ea.end_date    >= p_work_date
  ORDER BY ea.created_at DESC
  LIMIT 1;

  IF FOUND THEN
    SELECT lc.planned_minutes, lc.work_intervals
    INTO v_expected_min, v_work_intervals
    FROM data.resolve_labor_calendar_for_employee(
      v_emp.tenant_id, v_emp.site_id, p_employee_id, p_work_date, false
    ) lc
    WHERE lc.labor_day_type = 'work';

    v_expected_min := COALESCE(v_expected_min, 0);
    v_work_intervals := COALESCE(v_work_intervals, '[]'::jsonb);

    RETURN jsonb_build_object(
      'day_type',                  'absence',
      'expected_minutes',          v_expected_min,
      'work_day_type',             'normal',
      'site_timezone',             v_tz,
      'is_holiday',                false,
      'holiday_name',              null,
      'is_absence',                true,
      'absence_id',                v_absence.id,
      'absence_type',              v_absence.absence_type,
      'absence_is_paid',           v_absence.is_paid,
      'absence_hours_per_day',     v_absence.hours_per_day,
      'absence_counts_as_worked',  COALESCE(v_absence.counts_as_worked, false),
      'schedule_id',               null,
      'schedule_name',             null,
      'spans_midnight',            false,
      'shift_start_time',          null,
      'shift_end_time',            null,
      'work_intervals',            v_work_intervals,
      'employee_override',         false,
      'labor_source',              'absence'
    );
  END IF;

  SELECT edo.override_type INTO v_emp_override
  FROM data.employee_day_overrides edo
  WHERE edo.employee_id  = p_employee_id
    AND edo.override_date = p_work_date;

  IF FOUND THEN
    IF v_emp_override = 'force_holiday' THEN
      RETURN jsonb_build_object(
        'day_type', 'holiday',
        'expected_minutes', 0,
        'work_day_type', 'normal',
        'site_timezone', v_tz,
        'is_holiday', true,
        'holiday_name', null,
        'holiday_type', 'tenant_custom',
        'is_half_day', false,
        'is_absence', false,
        'absence_id', null,
        'absence_type', null,
        'schedule_id', null,
        'schedule_name', null,
        'spans_midnight', false,
        'shift_start_time', null,
        'shift_end_time', null,
        'work_intervals', '[]'::jsonb,
        'employee_override', true,
        'labor_source', 'employee_day_override'
      );
    ELSIF v_emp_override = 'force_work' THEN
      v_skip_holiday := true;
    END IF;
  END IF;

  SELECT * INTO v_labor
  FROM data.resolve_labor_calendar_for_employee(
    v_emp.tenant_id, v_emp.site_id, p_employee_id, p_work_date, v_skip_holiday
  );

  v_expected_min := COALESCE(v_labor.planned_minutes, 0);
  v_holiday_name := v_labor.labor_day_name;
  v_is_holiday := v_labor.labor_day_type = 'holiday'
    OR (v_labor.labor_source = 'assigned_holiday');
  v_work_intervals := COALESCE(v_labor.work_intervals, '[]'::jsonb);

  CASE v_labor.labor_day_type
    WHEN 'work' THEN
      v_day_type := 'working';
      SELECT * INTO v_bounds FROM data.labor_intervals_shift_bounds(v_labor.work_intervals);
      v_shift_start := v_bounds.shift_start;
      v_shift_end := v_bounds.shift_end;
      v_spans_midnight := COALESCE(v_bounds.spans_midnight, false);

    WHEN 'holiday' THEN
      v_day_type := CASE WHEN COALESCE(v_labor.is_half_day, false) THEN 'half_holiday' ELSE 'holiday' END;
      v_expected_min := 0;
      v_is_holiday := true;

    WHEN 'vacation', 'leave' THEN
      v_day_type := 'non_working';
      v_expected_min := 0;

    ELSE
      v_day_type := 'unknown';
      v_expected_min := 0;
  END CASE;

  RETURN jsonb_build_object(
    'day_type',          v_day_type,
    'expected_minutes',  v_expected_min,
    'work_day_type',     'normal',
    'site_timezone',     v_tz,
    'is_holiday',        v_is_holiday,
    'holiday_name',      v_holiday_name,
    'holiday_type',      CASE WHEN v_is_holiday THEN 'assigned' ELSE null END,
    'is_half_day',       COALESCE(v_labor.is_half_day, false),
    'is_absence',        false,
    'absence_id',        null,
    'absence_type',      null,
    'schedule_id',       null,
    'schedule_name',     null,
    'spans_midnight',    v_spans_midnight,
    'shift_start_time',  v_shift_start,
    'shift_end_time',    v_shift_end,
    'work_intervals',    v_work_intervals,
    'employee_override', COALESCE(v_emp_override = 'force_work', false),
    'labor_source',      v_labor.labor_source,
    'labor_day_type',    v_labor.labor_day_type
  );
END;
$$;

-- 2. recompute: worked_minutes = absence_min quan counts_as_worked
CREATE OR REPLACE FUNCTION api.recompute_attendance_worker(
  p_employee_id  uuid,
  p_work_date    date,
  p_tenant_id    uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp            record;
  v_tz             text;
  v_profile        text;
  v_punch_from     timestamptz;
  v_punch_to       timestamptz;
  v_day_start      timestamptz;
  v_day_end        timestamptz;
  v_travel_start   timestamptz;
  v_travel_end     timestamptz;
  v_segment_count  int;
  v_consolidated   jsonb;
  v_anomalies      text[];
  v_resolve          jsonb;
  v_day_type         text;
  v_expected_min     int;
  v_spans_midnight   boolean;
  v_shift_start      time;
  v_shift_end        time;
  v_first_in_at      timestamptz;
  v_first_in_id      uuid;
  v_last_out_at      timestamptz;
  v_last_out_id      uuid;
  v_gross_min        int;
  v_break_min        int  := 0;
  v_net_min          int;
  v_punch_count      int;
  v_in_count         int;
  v_out_count        int;
  v_bs_count         int;
  v_be_count         int;
  v_entry_status     text;
  v_locked_at        timestamptz;
  v_existing_status  text;
  v_absence_min      int  := 0;
  v_worked_min       int  := 0;
  v_open_pause       record;
  v_max_pause_min    int;
  v_summary_day_type text;
  v_settings         jsonb;
  v_enabled          boolean;
  v_resolved_policy  jsonb;
  v_policy           jsonb;
  v_seg_agg          jsonb;
  v_travel_min       int := 0;
BEGIN
  SELECT e.tenant_id, e.site_id INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.tenant_id = p_tenant_id;

  IF NOT FOUND OR v_emp.site_id IS NULL THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'employee_not_found_or_no_site');
  END IF;

  v_tz := COALESCE(data.get_site_timezone(v_emp.site_id, p_tenant_id), 'Europe/Madrid');
  v_punch_from := p_work_date AT TIME ZONE v_tz;
  v_punch_to   := (p_work_date + 1) AT TIME ZONE v_tz;

  v_profile := COALESCE(
    (data.resolve_attendance_record_policy(p_employee_id, p_work_date)->>'work_profile'),
    'fixed_site'
  );

  v_resolve        := api.resolve_work_day(p_employee_id, p_work_date);
    v_day_type       := COALESCE(v_resolve->>'day_type', 'unknown');
    v_expected_min   := COALESCE((v_resolve->>'expected_minutes')::int, 0);
    v_spans_midnight := COALESCE((v_resolve->>'spans_midnight')::boolean, false);
    v_summary_day_type := CASE v_day_type
      WHEN 'working' THEN 'work'
      WHEN 'half_holiday' THEN 'holiday'
      WHEN 'non_working' THEN 'weekend'
      ELSE v_day_type
    END;

    IF v_resolve->>'shift_start_time' IS NOT NULL THEN
      v_shift_start := (v_resolve->>'shift_start_time')::time;
      v_shift_end   := (v_resolve->>'shift_end_time')::time;
    END IF;

    IF v_day_type = 'absence' THEN
      v_absence_min := COALESCE(
        ((v_resolve->>'absence_hours_per_day')::numeric * 60)::int,
        v_expected_min
      );
      v_worked_min := CASE
        WHEN COALESCE((v_resolve->>'absence_counts_as_worked')::boolean, false)
        THEN v_absence_min
        ELSE 0
      END;

      SELECT payroll_locked_at INTO v_locked_at
      FROM data.time_daily_summaries
      WHERE employee_id = p_employee_id AND work_date = p_work_date;

      IF v_locked_at IS NOT NULL THEN
        RETURN jsonb_build_object('skipped', true, 'reason', 'payroll_locked');
      END IF;

      INSERT INTO data.time_daily_summaries (
        tenant_id, site_id, employee_id, work_date,
        day_type, expected_minutes, worked_minutes, break_minutes,
        overtime_minutes, absence_minutes, punch_count,
        anomaly_codes, needs_review, recomputed_at, updated_at
      ) VALUES (
        p_tenant_id, v_emp.site_id, p_employee_id, p_work_date,
        'absence', v_expected_min, v_worked_min, 0,
        0, v_absence_min, 0,
        '{}', false, now(), now()
      )
      ON CONFLICT (employee_id, work_date) DO UPDATE SET
        day_type = 'absence', expected_minutes = v_expected_min,
        worked_minutes = v_worked_min, absence_minutes = v_absence_min,
        punch_count = 0, anomaly_codes = '{}', needs_review = false,
        recomputed_at = now(), updated_at = now()
      WHERE data.time_daily_summaries.status = 'draft';

      PERFORM data.classify_activity_segments(p_employee_id, p_work_date, p_tenant_id);

      RETURN jsonb_build_object(
        'success', true, 'day_type', 'absence',
        'employee_id', p_employee_id, 'work_date', p_work_date,
        'absence_minutes', v_absence_min,
        'worked_minutes', v_worked_min
      );
    END IF;

    IF v_spans_midnight AND v_shift_start IS NOT NULL THEN
      v_punch_from := (p_work_date + v_shift_start) AT TIME ZONE v_tz;
      v_punch_to   := ((p_work_date + 1) + v_shift_end) AT TIME ZONE v_tz;
    END IF;

    SELECT
      COUNT(*) AS total,
      COUNT(*) FILTER (WHERE punch_type = 'in') AS in_c,
      COUNT(*) FILTER (WHERE punch_type = 'out') AS out_c,
      COUNT(*) FILTER (WHERE punch_type = 'break_start') AS bs_c,
      COUNT(*) FILTER (WHERE punch_type = 'break_end') AS be_c,
      MIN(occurred_at) FILTER (WHERE punch_type = 'in') AS first_in,
      MAX(occurred_at) FILTER (WHERE punch_type = 'out') AS last_out
    INTO v_punch_count, v_in_count, v_out_count, v_bs_count, v_be_count, v_first_in_at, v_last_out_at
    FROM data.time_punches
    WHERE employee_id = p_employee_id
      AND occurred_at >= v_punch_from AND occurred_at < v_punch_to;

    v_anomalies := '{}';

    IF v_punch_count = 0 AND v_day_type IN ('holiday', 'half_holiday', 'non_working') THEN
      RETURN jsonb_build_object(
        'skipped', true, 'reason', 'no_punches_on_' || v_day_type,
        'day_type', v_day_type
      );
    END IF;

    SELECT id INTO v_first_in_id FROM data.time_punches
    WHERE employee_id = p_employee_id AND punch_type = 'in'
      AND occurred_at >= v_punch_from AND occurred_at < v_punch_to
    ORDER BY occurred_at ASC LIMIT 1;

    SELECT id INTO v_last_out_id FROM data.time_punches
    WHERE employee_id = p_employee_id AND punch_type = 'out'
      AND occurred_at >= v_punch_from AND occurred_at < v_punch_to
    ORDER BY occurred_at DESC LIMIT 1;

    SELECT ARRAY(
      SELECT DISTINCT unnest_a FROM data.time_punches tp,
             LATERAL unnest(tp.anomaly_codes) AS unnest_a
      WHERE tp.employee_id = p_employee_id
        AND tp.occurred_at >= v_punch_from AND tp.occurred_at < v_punch_to
        AND cardinality(tp.anomaly_codes) > 0
    ) INTO v_anomalies;
    v_anomalies := COALESCE(v_anomalies, '{}');

    IF v_punch_count > 0 AND v_in_count = 0
       AND NOT data.employee_has_field_punch_logs(
         p_employee_id, p_work_date, p_tenant_id, v_tz
       ) THEN
      v_anomalies := array_append(v_anomalies, 'MISSING_IN');
    END IF;
    IF v_in_count > v_out_count AND v_out_count > 0 THEN
      v_anomalies := array_append(v_anomalies, 'EXTRA_IN');
    END IF;
    IF v_out_count > v_in_count THEN
      v_anomalies := array_append(v_anomalies, 'EXTRA_OUT');
    END IF;
    IF v_bs_count != v_be_count THEN
      v_anomalies := array_append(v_anomalies, 'BREAK_MISMATCH');
    END IF;

    IF data.is_mobile_work_profile(v_profile) THEN
      SELECT MIN(occurred_at) FILTER (WHERE punch_type = 'day_start'),
             MAX(occurred_at) FILTER (WHERE punch_type = 'day_end'),
             MAX(occurred_at) FILTER (WHERE punch_type = 'travel_start'),
             MAX(occurred_at) FILTER (WHERE punch_type = 'travel_end')
      INTO v_day_start, v_day_end, v_travel_start, v_travel_end
      FROM data.time_punches
      WHERE employee_id = p_employee_id
        AND occurred_at >= v_punch_from AND occurred_at < v_punch_to;

      IF v_day_start IS NOT NULL AND v_day_end IS NULL THEN
        v_anomalies := array_append(v_anomalies, 'DAY_NOT_CLOSED');
      END IF;
      IF v_travel_start IS NOT NULL
         AND (v_travel_end IS NULL OR v_travel_end < v_travel_start)
         AND v_day_end IS NULL THEN
        v_anomalies := array_append(v_anomalies, 'TRAVEL_NOT_CLOSED');
      END IF;
    END IF;

    IF data.is_mobile_work_profile(v_profile)
       AND (v_first_in_at IS NULL OR v_last_out_at IS NULL)
       AND v_day_start IS NOT NULL
       AND v_day_end IS NOT NULL
       AND v_day_end > v_day_start
       AND data.employee_has_field_punch_logs(p_employee_id, p_work_date, p_tenant_id, v_tz)
    THEN
      v_first_in_at := COALESCE(v_first_in_at, v_day_start);
      v_last_out_at := COALESCE(v_last_out_at, v_day_end);
    END IF;

    IF v_bs_count > v_be_count THEN
      SELECT tp.occurred_at, tp.pause_type INTO v_open_pause
      FROM data.time_punches tp
      WHERE tp.employee_id = p_employee_id AND tp.punch_type = 'break_start'
        AND tp.occurred_at >= v_punch_from AND tp.occurred_at < v_punch_to
      ORDER BY tp.occurred_at DESC LIMIT 1;

      SELECT COALESCE(tpc.max_duration_minutes, 240) INTO v_max_pause_min
      FROM data.tenant_pause_configs tpc
      WHERE tpc.tenant_id = p_tenant_id AND tpc.key = COALESCE(v_open_pause.pause_type, 'rest')
      LIMIT 1;
      v_max_pause_min := COALESCE(v_max_pause_min, 240);

      IF EXTRACT(EPOCH FROM (now() - v_open_pause.occurred_at)) / 60 > v_max_pause_min THEN
        v_anomalies := array_append(v_anomalies, 'PAUSE_NOT_CLOSED');
      END IF;
    END IF;

    IF v_first_in_at IS NOT NULL AND v_last_out_at IS NOT NULL THEN
      SELECT COALESCE(ROUND(SUM(
        EXTRACT(EPOCH FROM (be.occurred_at - bs.occurred_at)) / 60
      ))::int, 0)
      INTO v_break_min
      FROM (
        SELECT occurred_at, pause_counts_as_work, ROW_NUMBER() OVER (ORDER BY occurred_at) AS rn
        FROM data.time_punches
        WHERE employee_id = p_employee_id AND punch_type = 'break_start'
          AND occurred_at >= v_punch_from AND occurred_at < v_punch_to
      ) bs
      JOIN (
        SELECT occurred_at, ROW_NUMBER() OVER (ORDER BY occurred_at) AS rn
        FROM data.time_punches
        WHERE employee_id = p_employee_id AND punch_type = 'break_end'
          AND occurred_at >= v_punch_from AND occurred_at < v_punch_to
      ) be ON bs.rn = be.rn
      WHERE be.occurred_at > bs.occurred_at
        AND COALESCE(bs.pause_counts_as_work, false) = false;

      v_settings := data.merge_effective_settings_for_service(p_tenant_id, v_emp.site_id);
      v_enabled := COALESCE((v_settings->>'attendance_effective_time_enabled')::boolean, false);
      v_resolved_policy := data.resolve_attendance_record_policy(p_employee_id, p_work_date);
      v_policy := COALESCE(
        v_resolved_policy->'policy',
        data.default_attendance_record_policy(v_profile)
      );

      IF data.is_mobile_work_profile(v_profile) AND v_enabled THEN
        v_segment_count := data.classify_activity_segments(p_employee_id, p_work_date, p_tenant_id);
        v_seg_agg := data.sum_segment_minutes_by_kind(
          p_employee_id, p_work_date, p_tenant_id, v_tz
        );
        v_travel_min := COALESCE((v_seg_agg->'by_kind'->>'TRAVEL')::int, 0);

        IF v_day_start IS NOT NULL AND v_day_end IS NOT NULL AND v_day_end > v_day_start THEN
          v_gross_min := ROUND(EXTRACT(EPOCH FROM (v_day_end - v_day_start)) / 60)::int;
        ELSIF v_in_count = v_out_count AND v_in_count > 0 THEN
          v_gross_min := data.sum_punch_in_out_minutes(p_employee_id, v_punch_from, v_punch_to);
        ELSE
          v_gross_min := ROUND(EXTRACT(EPOCH FROM (v_last_out_at - v_first_in_at)) / 60)::int;
        END IF;

        v_net_min := data.compute_mobile_net_minutes(
          v_gross_min, v_break_min, v_travel_min, v_policy
        );
      ELSE
        IF v_in_count = v_out_count AND v_in_count > 0 THEN
          v_gross_min := data.sum_punch_in_out_minutes(p_employee_id, v_punch_from, v_punch_to);
        ELSE
          v_gross_min := ROUND(EXTRACT(EPOCH FROM (v_last_out_at - v_first_in_at)) / 60)::int;
        END IF;

        v_net_min := GREATEST(0, v_gross_min - v_break_min);
      END IF;

      v_entry_status := 'closed';
    ELSIF v_first_in_at IS NOT NULL THEN
      v_gross_min := NULL; v_net_min := NULL; v_entry_status := 'open';
    ELSE
      v_gross_min := NULL; v_net_min := NULL;
      v_entry_status := CASE WHEN v_punch_count = 0 THEN 'missing' ELSE 'open' END;
    END IF;

    SELECT payroll_locked_at INTO v_locked_at
    FROM data.time_daily_summaries
    WHERE employee_id = p_employee_id AND work_date = p_work_date;

    IF v_locked_at IS NOT NULL THEN
      RETURN jsonb_build_object('skipped', true, 'reason', 'payroll_locked',
        'employee_id', p_employee_id, 'work_date', p_work_date);
    END IF;

    SELECT status INTO v_existing_status
    FROM data.time_entries
    WHERE employee_id = p_employee_id AND work_date = p_work_date;

    IF v_existing_status = 'adjusted' THEN
      UPDATE data.time_daily_summaries SET
        day_type = v_summary_day_type, expected_minutes = v_expected_min,
        punch_count = v_punch_count, anomaly_codes = v_anomalies,
        needs_review = (cardinality(v_anomalies) > 0),
        recomputed_at = now(), updated_at = now()
      WHERE employee_id = p_employee_id AND work_date = p_work_date AND status = 'draft';

      v_segment_count := data.classify_activity_segments(p_employee_id, p_work_date, p_tenant_id);

      RETURN jsonb_build_object(
        'skipped_entry', true, 'reason', 'entry_adjusted',
        'employee_id', p_employee_id, 'work_date', p_work_date,
        'segment_count', v_segment_count
      );
    END IF;

    INSERT INTO data.time_entries (
      tenant_id, site_id, employee_id, work_date,
      starts_at, ends_at, punch_in_id, punch_out_id,
      gross_minutes, break_minutes, net_minutes,
      regular_minutes, overtime_minutes, status, updated_at
    ) VALUES (
      v_emp.tenant_id, v_emp.site_id, p_employee_id, p_work_date,
      v_first_in_at, v_last_out_at, v_first_in_id, v_last_out_id,
      v_gross_min, v_break_min, v_net_min,
      v_net_min, 0, v_entry_status, now()
    )
    ON CONFLICT (employee_id, work_date) DO UPDATE SET
      starts_at = EXCLUDED.starts_at, ends_at = EXCLUDED.ends_at,
      punch_in_id = EXCLUDED.punch_in_id, punch_out_id = EXCLUDED.punch_out_id,
      gross_minutes = EXCLUDED.gross_minutes, break_minutes = EXCLUDED.break_minutes,
      net_minutes = EXCLUDED.net_minutes, regular_minutes = EXCLUDED.regular_minutes,
      overtime_minutes = EXCLUDED.overtime_minutes, status = EXCLUDED.status,
      updated_at = EXCLUDED.updated_at
    WHERE data.time_entries.status != 'adjusted';

    INSERT INTO data.time_daily_summaries (
      tenant_id, site_id, employee_id, work_date,
      day_type, expected_minutes, worked_minutes, break_minutes,
      overtime_minutes, absence_minutes, punch_count,
      anomaly_codes, needs_review, recomputed_at, updated_at
    ) VALUES (
      v_emp.tenant_id, v_emp.site_id, p_employee_id, p_work_date,
      v_summary_day_type, v_expected_min,
      COALESCE(v_net_min, 0), v_break_min,
      0, 0, v_punch_count,
      v_anomalies,
      (cardinality(v_anomalies) > 0 OR v_entry_status = 'missing'),
      now(), now()
    )
    ON CONFLICT (employee_id, work_date) DO UPDATE SET
      day_type = EXCLUDED.day_type, expected_minutes = EXCLUDED.expected_minutes,
      worked_minutes = EXCLUDED.worked_minutes, break_minutes = EXCLUDED.break_minutes,
      punch_count = EXCLUDED.punch_count, anomaly_codes = EXCLUDED.anomaly_codes,
      needs_review = EXCLUDED.needs_review, recomputed_at = EXCLUDED.recomputed_at,
      updated_at = EXCLUDED.updated_at
    WHERE data.time_daily_summaries.status = 'draft';

    BEGIN
      PERFORM data.refresh_today_site_status_mv();
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    IF v_segment_count IS NULL THEN
      v_segment_count := data.classify_activity_segments(p_employee_id, p_work_date, p_tenant_id);
    END IF;

    v_consolidated := data.consolidate_day_buckets(p_employee_id, p_work_date, p_tenant_id);

    IF COALESCE((v_consolidated->>'skipped')::boolean, true) = false THEN
      v_anomalies := v_anomalies || COALESCE(
        ARRAY(SELECT jsonb_array_elements_text(v_consolidated->'anomaly_codes')),
        '{}'
      );
      v_anomalies := ARRAY(SELECT DISTINCT unnest(v_anomalies));

      UPDATE data.time_daily_summaries SET
        presence_minutes = COALESCE((v_consolidated->>'presence_minutes')::int, 0),
        work_minutes = COALESCE((v_consolidated->>'work_minutes')::int, 0),
        travel_minutes = COALESCE((v_consolidated->>'travel_minutes')::int, 0),
        effective_minutes = COALESCE((v_consolidated->>'effective_minutes')::int, 0),
        paid_minutes = COALESCE((v_consolidated->>'paid_minutes')::int, 0),
        regular_minutes = COALESCE((v_consolidated->>'regular_minutes')::int, 0),
        overtime_minutes = COALESCE((v_consolidated->>'overtime_minutes')::int, 0),
        overtime_authorized_minutes = COALESCE((v_consolidated->>'overtime_authorized_minutes')::int, 0),
        consolidation_meta = COALESCE(v_consolidated->'consolidation_meta', '{}'::jsonb),
        work_profile_snapshot = v_consolidated->>'work_profile',
        anomaly_codes = v_anomalies,
        needs_review = (cardinality(v_anomalies) > 0 OR v_entry_status = 'missing'),
        updated_at = now()
      WHERE employee_id = p_employee_id AND work_date = p_work_date AND status = 'draft';

      UPDATE data.time_entries SET
        presence_minutes = COALESCE((v_consolidated->>'presence_minutes')::int, 0),
        work_minutes = COALESCE((v_consolidated->>'work_minutes')::int, 0),
        travel_minutes = COALESCE((v_consolidated->>'travel_minutes')::int, 0),
        effective_minutes = COALESCE((v_consolidated->>'effective_minutes')::int, 0),
        paid_minutes = COALESCE((v_consolidated->>'paid_minutes')::int, 0),
        updated_at = now()
      WHERE employee_id = p_employee_id AND work_date = p_work_date
        AND status != 'adjusted';

      BEGIN
        PERFORM data.sync_attendance_rollups_for_day(
          p_employee_id, p_work_date, p_tenant_id, v_emp.site_id
        );
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'sync_attendance_rollups_for_day: %', SQLERRM;
      END;
    END IF;

    RETURN jsonb_build_object(
      'success', true,
      'employee_id', p_employee_id,
      'work_date', p_work_date,
      'day_type', v_day_type,
      'expected_minutes', v_expected_min,
      'punch_count', v_punch_count,
      'net_minutes', v_net_min,
      'entry_status', v_entry_status,
      'anomaly_codes', v_anomalies,
      'segment_count', v_segment_count,
      'work_profile', v_profile,
      'consolidation', v_consolidated
    );
END;
$$;

-- 3. get_payroll_review_days: fallback worked per absències retribuïdes
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
            WHEN (wd.resolve ->> 'day_type') = 'absence'
              AND COALESCE((wd.resolve ->> 'absence_counts_as_worked')::boolean, false)
            THEN GREATEST(
              COALESCE(tds.absence_minutes, 0),
              COALESCE(((wd.resolve ->> 'absence_hours_per_day')::numeric * 60)::int, 0),
              COALESCE((wd.resolve ->> 'expected_minutes')::int, 0)
            )
            ELSE NULL
          END,
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

-- 4. Backfill resums existents (draft)
UPDATE data.time_daily_summaries tds
SET
  worked_minutes = tds.absence_minutes,
  updated_at = now(),
  recomputed_at = now()
FROM data.employee_absences ea
WHERE tds.day_type = 'absence'
  AND tds.status = 'draft'
  AND tds.worked_minutes = 0
  AND tds.absence_minutes > 0
  AND ea.employee_id = tds.employee_id
  AND ea.status = 'approved'
  AND ea.start_date <= tds.work_date
  AND ea.end_date >= tds.work_date
  AND ea.counts_as_worked = true;

NOTIFY pgrst, 'reload schema';
