-- Track G Phase 2b: recompute mobile net

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
