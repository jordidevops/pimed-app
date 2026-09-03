-- Fix: attendance v2 recompute_attendance_worker regressed and always wrote
-- day_type='unknown' / expected_minutes=0. Restore resolve_work_day integration
-- while keeping v2 pause handling (PAUSE_NOT_CLOSED, pause_counts_as_work).

-- Internal timezone lookup (no auth) for workers and migrations.
CREATE OR REPLACE FUNCTION data.get_site_timezone(
  p_site_id   uuid,
  p_tenant_id uuid DEFAULT NULL
)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT COALESCE(
    NULLIF(s.settings->>'site_timezone', ''),
    NULLIF(t.settings->>'site_timezone', ''),
    NULLIF(sys.settings->>'site_timezone', ''),
    'Europe/Madrid'
  )
  FROM data.sites s
  JOIN data.tenants t ON t.id = COALESCE(p_tenant_id, s.tenant_id)
  LEFT JOIN data.system_settings sys ON sys.module = 'defaults'
  WHERE s.id = p_site_id;
$$;

-- resolve_work_day: use internal timezone helper (get_effective_settings requires auth)
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
BEGIN
  SELECT e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'day_type', 'unknown',
      'expected_minutes', 0,
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

  SELECT ea.id, ea.absence_type, ea.is_paid, ea.hours_per_day
  INTO v_absence
  FROM data.employee_absences ea
  WHERE ea.employee_id = p_employee_id
    AND ea.status      = 'approved'
    AND ea.start_date  <= p_work_date
    AND ea.end_date    >= p_work_date
  ORDER BY ea.created_at DESC
  LIMIT 1;

  IF FOUND THEN
    SELECT lc.planned_minutes INTO v_expected_min
    FROM data.resolve_labor_calendar_for_employee(
      v_emp.tenant_id, v_emp.site_id, p_employee_id, p_work_date, false
    ) lc
    WHERE lc.labor_day_type = 'work';

    v_expected_min := COALESCE(v_expected_min, 0);

    RETURN jsonb_build_object(
      'day_type',              'absence',
      'expected_minutes',      v_expected_min,
      'site_timezone',         v_tz,
      'is_holiday',            false,
      'holiday_name',          null,
      'is_absence',            true,
      'absence_id',            v_absence.id,
      'absence_type',          v_absence.absence_type,
      'absence_is_paid',       v_absence.is_paid,
      'absence_hours_per_day', v_absence.hours_per_day,
      'schedule_id',           null,
      'schedule_name',         null,
      'spans_midnight',        false,
      'shift_start_time',      null,
      'shift_end_time',        null,
      'employee_override',     false,
      'labor_source',          'absence'
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
    'employee_override', COALESCE(v_emp_override = 'force_work', false),
    'labor_source',      v_labor.labor_source,
    'labor_day_type',    v_labor.labor_day_type
  );
END;
$$;

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
  v_emp              record;
  v_tz               text;
  v_resolve          jsonb;
  v_day_type         text;
  v_expected_min     int;
  v_spans_midnight   boolean;
  v_shift_start      time;
  v_shift_end        time;
  v_punch_from       timestamptz;
  v_punch_to         timestamptz;
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
  v_anomalies        text[] := '{}';
  v_entry_status     text;
  v_locked_at        timestamptz;
  v_existing_status  text;
  v_absence_min      int  := 0;
  v_open_pause       record;
  v_max_pause_min    int;
  v_summary_day_type text;
BEGIN
  SELECT e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.tenant_id = p_tenant_id;

  IF NOT FOUND OR v_emp.site_id IS NULL THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'employee_not_found_or_no_site');
  END IF;

  v_tz := COALESCE(data.get_site_timezone(v_emp.site_id, p_tenant_id), 'Europe/Madrid');

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
      'absence', v_expected_min, 0, 0,
      0, v_absence_min, 0,
      '{}', false, now(), now()
    )
    ON CONFLICT (employee_id, work_date) DO UPDATE SET
      day_type         = 'absence',
      expected_minutes = v_expected_min,
      worked_minutes   = 0,
      absence_minutes  = v_absence_min,
      punch_count      = 0,
      anomaly_codes    = '{}',
      needs_review     = false,
      recomputed_at    = now(),
      updated_at       = now()
    WHERE data.time_daily_summaries.status = 'draft';

    RETURN jsonb_build_object(
      'success', true,
      'day_type', 'absence',
      'employee_id', p_employee_id,
      'work_date', p_work_date,
      'absence_minutes', v_absence_min
    );
  END IF;

  IF v_spans_midnight AND v_shift_start IS NOT NULL THEN
    v_punch_from := (p_work_date + v_shift_start) AT TIME ZONE v_tz;
    v_punch_to   := ((p_work_date + 1) + v_shift_end) AT TIME ZONE v_tz;
  ELSE
    v_punch_from := p_work_date AT TIME ZONE v_tz;
    v_punch_to   := (p_work_date + 1) AT TIME ZONE v_tz;
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
    AND occurred_at >= v_punch_from
    AND occurred_at <  v_punch_to;

  IF v_punch_count = 0 AND v_day_type IN ('holiday', 'half_holiday', 'non_working') THEN
    RETURN jsonb_build_object(
      'skipped', true,
      'reason', 'no_punches_on_' || v_day_type,
      'day_type', v_day_type
    );
  END IF;

  SELECT id INTO v_first_in_id
  FROM data.time_punches
  WHERE employee_id = p_employee_id AND punch_type = 'in'
    AND occurred_at >= v_punch_from AND occurred_at < v_punch_to
  ORDER BY occurred_at ASC LIMIT 1;

  SELECT id INTO v_last_out_id
  FROM data.time_punches
  WHERE employee_id = p_employee_id AND punch_type = 'out'
    AND occurred_at >= v_punch_from AND occurred_at < v_punch_to
  ORDER BY occurred_at DESC LIMIT 1;

  SELECT ARRAY(
    SELECT DISTINCT unnest_a
    FROM data.time_punches tp,
         LATERAL unnest(tp.anomaly_codes) AS unnest_a
    WHERE tp.employee_id = p_employee_id
      AND tp.occurred_at >= v_punch_from
      AND tp.occurred_at <  v_punch_to
      AND cardinality(tp.anomaly_codes) > 0
  ) INTO v_anomalies;
  v_anomalies := COALESCE(v_anomalies, '{}');

  IF v_punch_count > 0 AND v_in_count = 0 THEN
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

  IF v_bs_count > v_be_count THEN
    SELECT tp.occurred_at, tp.pause_type INTO v_open_pause
    FROM data.time_punches tp
    WHERE tp.employee_id = p_employee_id
      AND tp.punch_type = 'break_start'
      AND tp.occurred_at >= v_punch_from
      AND tp.occurred_at <  v_punch_to
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
    v_gross_min := ROUND(EXTRACT(EPOCH FROM (v_last_out_at - v_first_in_at)) / 60)::int;

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

    v_net_min := GREATEST(0, v_gross_min - v_break_min);
    v_entry_status := 'closed';
  ELSIF v_first_in_at IS NOT NULL THEN
    v_gross_min := NULL;
    v_net_min := NULL;
    v_entry_status := 'open';
  ELSE
    v_gross_min := NULL;
    v_net_min := NULL;
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
      day_type         = v_summary_day_type,
      expected_minutes = v_expected_min,
      punch_count      = v_punch_count,
      anomaly_codes    = v_anomalies,
      needs_review     = (cardinality(v_anomalies) > 0),
      recomputed_at    = now(),
      updated_at       = now()
    WHERE employee_id = p_employee_id AND work_date = p_work_date
      AND status = 'draft';

    RETURN jsonb_build_object('skipped_entry', true, 'reason', 'entry_adjusted',
      'employee_id', p_employee_id, 'work_date', p_work_date);
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
    starts_at        = EXCLUDED.starts_at,
    ends_at          = EXCLUDED.ends_at,
    punch_in_id      = EXCLUDED.punch_in_id,
    punch_out_id     = EXCLUDED.punch_out_id,
    gross_minutes    = EXCLUDED.gross_minutes,
    break_minutes    = EXCLUDED.break_minutes,
    net_minutes      = EXCLUDED.net_minutes,
    regular_minutes  = EXCLUDED.regular_minutes,
    overtime_minutes = EXCLUDED.overtime_minutes,
    status           = EXCLUDED.status,
    updated_at       = EXCLUDED.updated_at
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
    day_type         = EXCLUDED.day_type,
    expected_minutes = EXCLUDED.expected_minutes,
    worked_minutes   = EXCLUDED.worked_minutes,
    break_minutes    = EXCLUDED.break_minutes,
    punch_count      = EXCLUDED.punch_count,
    anomaly_codes    = EXCLUDED.anomaly_codes,
    needs_review     = EXCLUDED.needs_review,
    recomputed_at    = EXCLUDED.recomputed_at,
    updated_at       = EXCLUDED.updated_at
  WHERE data.time_daily_summaries.status = 'draft';

  BEGIN
    PERFORM data.refresh_today_site_status_mv();
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  RETURN jsonb_build_object(
    'success', true,
    'employee_id', p_employee_id,
    'work_date', p_work_date,
    'day_type', v_day_type,
    'expected_minutes', v_expected_min,
    'punch_count', v_punch_count,
    'net_minutes', v_net_min,
    'entry_status', v_entry_status,
    'anomaly_codes', v_anomalies
  );
END;
$$;

-- Backfill draft summaries that were written with expected_minutes=0
UPDATE data.time_daily_summaries tds
SET
  day_type         = r.day_type,
  expected_minutes = r.expected_minutes,
  recomputed_at    = now(),
  updated_at       = now()
FROM (
  SELECT
    tds2.id,
    CASE COALESCE(wd->>'day_type', 'unknown')
      WHEN 'working' THEN 'work'
      WHEN 'half_holiday' THEN 'holiday'
      WHEN 'non_working' THEN 'weekend'
      ELSE COALESCE(wd->>'day_type', 'unknown')
    END AS day_type,
    COALESCE((wd->>'expected_minutes')::int, 0) AS expected_minutes
  FROM data.time_daily_summaries tds2
  CROSS JOIN LATERAL api.resolve_work_day(tds2.employee_id, tds2.work_date) wd
  WHERE tds2.status = 'draft'
) r
WHERE tds.id = r.id
  AND (
    tds.day_type IS DISTINCT FROM r.day_type
    OR tds.expected_minutes IS DISTINCT FROM r.expected_minutes
  );
