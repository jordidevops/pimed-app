-- Track G Phase 2a: jornada partida — presència per trams IN/OUT (§4.3)

CREATE OR REPLACE FUNCTION data.sum_punch_in_out_minutes(
  p_employee_id uuid,
  p_from        timestamptz,
  p_to          timestamptz
)
RETURNS int
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(SUM(
    GREATEST(0, EXTRACT(EPOCH FROM (o.occurred_at - i.occurred_at)) / 60)
  )::int, 0)
  FROM (
    SELECT occurred_at, ROW_NUMBER() OVER (ORDER BY occurred_at ASC, id ASC) AS rn
    FROM data.time_punches
    WHERE employee_id = p_employee_id
      AND punch_type = 'in'
      AND occurred_at >= p_from
      AND occurred_at < p_to
  ) i
  JOIN (
    SELECT occurred_at, ROW_NUMBER() OVER (ORDER BY occurred_at ASC, id ASC) AS rn
    FROM data.time_punches
    WHERE employee_id = p_employee_id
      AND punch_type = 'out'
      AND occurred_at >= p_from
      AND occurred_at < p_to
  ) o ON i.rn = o.rn
  WHERE o.occurred_at > i.occurred_at;
$$;

REVOKE ALL ON FUNCTION data.sum_punch_in_out_minutes(uuid, timestamptz, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.sum_punch_in_out_minutes(uuid, timestamptz, timestamptz) TO service_role;

-- Patch consolidate: presence = Σ trams IN→OUT (no envelope first→last)
CREATE OR REPLACE FUNCTION data.consolidate_day_buckets(
  p_employee_id uuid,
  p_work_date   date,
  p_tenant_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp              record;
  v_settings         jsonb;
  v_enabled          boolean;
  v_resolved         jsonb;
  v_profile          text;
  v_policy           jsonb;
  v_tz               text;
  v_punch_from       timestamptz;
  v_punch_to         timestamptz;
  v_first_in         timestamptz;
  v_last_out         timestamptz;
  v_in_count         int;
  v_out_count        int;
  v_gross_min        int;
  v_break_unpaid_min int := 0;
  v_resolve          jsonb;
  v_work_intervals   jsonb;
  v_expected_min     int;
  v_courtesy         jsonb;
  v_adj_in           timestamptz;
  v_adj_out          timestamptz;
  v_effective_min    int;
  v_paid_min         int;
  v_regular_min      int;
  v_overtime_min     int;
  v_anomalies        text[] := '{}';
  v_meta             jsonb;
  v_work_counts_paid boolean;
  v_presence_min     int;
BEGIN
  SELECT e.tenant_id, e.site_id INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'employee_not_found');
  END IF;

  v_tz := COALESCE(data.get_site_timezone(v_emp.site_id, p_tenant_id), 'Europe/Madrid');
  v_settings := data.merge_effective_settings_for_service(p_tenant_id, v_emp.site_id);
  v_enabled := COALESCE((v_settings->>'attendance_effective_time_enabled')::boolean, false);

  IF NOT v_enabled THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'flag_off');
  END IF;

  v_resolved := data.resolve_attendance_record_policy(p_employee_id, p_work_date);
  v_profile := COALESCE(v_resolved->>'work_profile', 'fixed_site');
  v_policy := COALESCE(v_resolved->'policy', data.default_attendance_record_policy('fixed_site'));

  IF data.is_mobile_work_profile(v_profile) THEN
    RETURN jsonb_build_object(
      'skipped', true,
      'reason', 'awaiting_g2b',
      'work_profile', v_profile,
      'consolidation_meta', jsonb_build_object('skipped', 'awaiting_g2b')
    );
  END IF;

  IF v_profile <> 'fixed_site' THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'unsupported_profile', 'work_profile', v_profile);
  END IF;

  v_punch_from := p_work_date AT TIME ZONE v_tz;
  v_punch_to   := (p_work_date + 1) AT TIME ZONE v_tz;

  SELECT MIN(occurred_at) FILTER (WHERE punch_type = 'in'),
         MAX(occurred_at) FILTER (WHERE punch_type = 'out'),
         COUNT(*) FILTER (WHERE punch_type = 'in'),
         COUNT(*) FILTER (WHERE punch_type = 'out')
  INTO v_first_in, v_last_out, v_in_count, v_out_count
  FROM data.time_punches
  WHERE employee_id = p_employee_id
    AND occurred_at >= v_punch_from
    AND occurred_at < v_punch_to;

  IF v_first_in IS NULL OR v_last_out IS NULL OR v_last_out <= v_first_in THEN
    RETURN jsonb_build_object(
      'skipped', true,
      'reason', 'open_or_incomplete_day',
      'work_profile', v_profile
    );
  END IF;

  IF v_in_count = v_out_count AND v_in_count > 0 THEN
    v_gross_min := data.sum_punch_in_out_minutes(p_employee_id, v_punch_from, v_punch_to);
  ELSE
    v_gross_min := (EXTRACT(EPOCH FROM (v_last_out - v_first_in)) / 60)::int;
  END IF;

  SELECT COALESCE(ROUND(SUM(
    EXTRACT(EPOCH FROM (be.occurred_at - bs.occurred_at)) / 60
  ))::int, 0)
  INTO v_break_unpaid_min
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

  v_presence_min := GREATEST(0, v_gross_min - v_break_unpaid_min);

  v_resolve := api.resolve_work_day(p_employee_id, p_work_date);
  v_work_intervals := COALESCE(v_resolve->'work_intervals', '[]'::jsonb);
  v_expected_min := COALESCE((v_resolve->>'expected_minutes')::int, 0);

  v_courtesy := data.apply_courtesy_work_bounds(
    v_first_in, v_last_out, p_work_date, v_work_intervals, v_policy, v_tz
  );

  v_anomalies := COALESCE(
    ARRAY(SELECT jsonb_array_elements_text(v_courtesy->'anomaly_codes')),
    '{}'
  );

  v_adj_in := data.adjust_punch_for_consolidation(
    (v_courtesy->>'effective_in')::timestamptz,
    'in',
    (v_courtesy->>'expected_start')::timestamptz,
    v_policy,
    v_tz
  );
  v_adj_out := data.adjust_punch_for_consolidation(
    (v_courtesy->>'effective_out')::timestamptz,
    'out',
    (v_courtesy->>'expected_end')::timestamptz,
    v_policy,
    v_tz
  );

  v_effective_min := data.interval_intersection_minutes(
    v_adj_in, v_adj_out, v_work_intervals, v_tz
  );
  v_effective_min := GREATEST(0, v_effective_min - v_break_unpaid_min);

  v_work_counts_paid := COALESCE((v_policy->'activities'->'WORK'->>'counts_paid')::boolean, true);
  v_paid_min := CASE WHEN v_work_counts_paid THEN v_effective_min ELSE 0 END;
  v_regular_min := LEAST(v_effective_min, v_expected_min);

  IF v_adj_out > (v_courtesy->>'expected_end')::timestamptz THEN
    v_overtime_min := GREATEST(
      0,
      (EXTRACT(EPOCH FROM (v_adj_out - (v_courtesy->>'expected_end')::timestamptz)) / 60)::int
    );
  ELSE
    v_overtime_min := 0;
  END IF;

  IF v_overtime_min > 0
     AND COALESCE((v_policy->'overtime'->>'requires_prior_authorization')::boolean, true) THEN
    v_anomalies := array_append(v_anomalies, 'OVERTIME_UNAUTHORIZED');
  END IF;

  v_meta := jsonb_build_object(
    'policy_version', COALESCE(v_policy->>'version', '2'),
    'work_profile', v_profile,
    'resolved_from', v_resolved->>'resolved_from',
    'rules_applied', jsonb_build_array('courtesy', 'rounding', 'schedule_intersection', 'split_shift_presence'),
    'adjusted_in', v_adj_in,
    'adjusted_out', v_adj_out,
    'buckets', jsonb_build_object(
      'presence', v_presence_min,
      'work', v_effective_min,
      'travel', 0,
      'effective', v_effective_min,
      'paid', v_paid_min,
      'regular', v_regular_min,
      'overtime', v_overtime_min
    )
  );

  RETURN jsonb_build_object(
    'skipped', false,
    'work_profile', v_profile,
    'presence_minutes', v_presence_min,
    'work_minutes', v_effective_min,
    'travel_minutes', 0,
    'effective_minutes', v_effective_min,
    'paid_minutes', v_paid_min,
    'regular_minutes', v_regular_min,
    'overtime_minutes', v_overtime_min,
    'overtime_authorized_minutes', 0,
    'consolidation_meta', v_meta,
    'anomaly_codes', v_anomalies
  );
END;
$$;

-- Patch recompute: gross/net per trams quan IN/OUT emparellats (§4.3)
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
  v_open_pause       record;
  v_max_pause_min    int;
  v_summary_day_type text;
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
        day_type = 'absence', expected_minutes = v_expected_min,
        worked_minutes = 0, absence_minutes = v_absence_min,
        punch_count = 0, anomaly_codes = '{}', needs_review = false,
        recomputed_at = now(), updated_at = now()
      WHERE data.time_daily_summaries.status = 'draft';

      PERFORM data.classify_activity_segments(p_employee_id, p_work_date, p_tenant_id);

      RETURN jsonb_build_object(
        'success', true, 'day_type', 'absence',
        'employee_id', p_employee_id, 'work_date', p_work_date,
        'absence_minutes', v_absence_min
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
      IF v_in_count = v_out_count AND v_in_count > 0 THEN
        v_gross_min := data.sum_punch_in_out_minutes(p_employee_id, v_punch_from, v_punch_to);
      ELSE
        v_gross_min := ROUND(EXTRACT(EPOCH FROM (v_last_out_at - v_first_in_at)) / 60)::int;
      END IF;

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

    v_segment_count := data.classify_activity_segments(p_employee_id, p_work_date, p_tenant_id);

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
    ELSIF v_consolidated->>'reason' = 'awaiting_g2b' THEN
      UPDATE data.time_daily_summaries SET
        consolidation_meta = COALESCE(v_consolidated->'consolidation_meta', '{}'::jsonb),
        work_profile_snapshot = v_consolidated->>'work_profile',
        updated_at = now()
      WHERE employee_id = p_employee_id AND work_date = p_work_date AND status = 'draft';
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

REVOKE ALL ON FUNCTION api.recompute_attendance_worker(uuid, date, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.recompute_attendance_worker(uuid, date, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION api.recompute_attendance_worker(uuid, date, uuid) TO service_role;

NOTIFY pgrst, 'reload schema';
