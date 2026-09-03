-- Track G Phase 2c: patch consolidate mobile branch for UNCLASSIFIED_GAP

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
  v_day_start        timestamptz;
  v_day_end          timestamptz;
  v_in_count         int;
  v_out_count        int;
  v_iv_count         int;
  v_use_per_tram     boolean;
  v_gross_min        int;
  v_break_unpaid_min int := 0;
  v_resolve          jsonb;
  v_work_intervals   jsonb;
  v_expected_min     int;
  v_budget_min       int;
  v_courtesy         jsonb;
  v_adj_in           timestamptz;
  v_adj_out          timestamptz;
  v_effective_min    int := 0;
  v_work_min         int := 0;
  v_travel_min       int := 0;
  v_paid_min         int;
  v_regular_min      int;
  v_overtime_min     int;
  v_ot_base          int;
  v_ot_base_key      text;
  v_anomalies        text[] := '{}';
  v_meta             jsonb;
  v_work_counts_paid boolean;
  v_presence_min     int;
  v_idx              int;
  v_iv               jsonb;
  v_pair_in          timestamptz;
  v_pair_out         timestamptz;
  v_expected_start   timestamptz;
  v_expected_end     timestamptz;
  v_courtesy_in      jsonb;
  v_courtesy_out     jsonb;
  v_tram_adj_in      timestamptz;
  v_tram_adj_out     timestamptz;
  v_last_expected_end timestamptz;
  v_rules            jsonb;
  v_seg_agg          jsonb;
  v_by_kind          jsonb;
  v_buckets          jsonb;
  v_open_segments    int;
  v_unclassified     jsonb;
  v_gap_threshold    int;
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
  v_policy := COALESCE(v_resolved->'policy', data.default_attendance_record_policy(v_profile));

  v_punch_from := p_work_date AT TIME ZONE v_tz;
  v_punch_to   := (p_work_date + 1) AT TIME ZONE v_tz;

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

  -- ─── Mobile branch (G2b) ───────────────────────────────────────────────────
  IF data.is_mobile_work_profile(v_profile) THEN
    SELECT MIN(occurred_at) FILTER (WHERE punch_type = 'in'),
           MAX(occurred_at) FILTER (WHERE punch_type = 'out'),
           MIN(occurred_at) FILTER (WHERE punch_type = 'day_start'),
           MAX(occurred_at) FILTER (WHERE punch_type = 'day_end'),
           COUNT(*) FILTER (WHERE punch_type = 'in'),
           COUNT(*) FILTER (WHERE punch_type = 'out')
    INTO v_first_in, v_last_out, v_day_start, v_day_end, v_in_count, v_out_count
    FROM data.time_punches
    WHERE employee_id = p_employee_id
      AND occurred_at >= v_punch_from
      AND occurred_at < v_punch_to;

    IF (v_day_start IS NULL OR v_day_end IS NULL)
       AND (v_first_in IS NULL OR v_last_out IS NULL OR v_last_out <= v_first_in) THEN
      RETURN jsonb_build_object(
        'skipped', true,
        'reason', 'open_or_incomplete_day',
        'work_profile', v_profile
      );
    END IF;

    v_seg_agg := data.sum_segment_minutes_by_kind(
      p_employee_id, p_work_date, p_tenant_id, v_tz
    );
    v_by_kind := COALESCE(v_seg_agg->'by_kind', '{}'::jsonb);
    v_open_segments := COALESCE((v_seg_agg->>'open_segments')::int, 0);

    IF v_open_segments > 0 THEN
      v_anomalies := array_append(v_anomalies, 'SEGMENT_GAP');
    END IF;

    v_gap_threshold := COALESCE((v_policy->>'unclassified_gap_threshold_minutes')::int, 30);
    v_unclassified := data.collect_unclassified_gaps(
      p_employee_id, p_work_date, v_gap_threshold
    );
    IF jsonb_array_length(COALESCE(v_unclassified, '[]'::jsonb)) > 0 THEN
      v_anomalies := array_append(v_anomalies, 'UNCLASSIFIED_GAP');
    END IF;


    v_buckets := data.apply_activity_flags_to_buckets(v_by_kind, v_policy);
    v_work_min := COALESCE((v_buckets->>'work_minutes')::int, 0);
    v_travel_min := COALESCE((v_buckets->>'travel_minutes')::int, 0);
    v_paid_min := COALESCE((v_buckets->>'paid_minutes')::int, 0);
    v_effective_min := COALESCE((v_buckets->>'effective_minutes')::int, 0);

    v_presence_min := data.mobile_day_presence_minutes(
      p_employee_id, p_work_date, v_tz, v_by_kind
    );

    v_resolve := api.resolve_work_day(p_employee_id, p_work_date);
    v_expected_min := COALESCE((v_resolve->>'expected_minutes')::int, 0);
    v_budget_min := COALESCE(
      (v_policy->>'daily_work_budget_minutes')::int,
      NULLIF(v_expected_min, 0),
      480
    );

    v_ot_base_key := COALESCE(v_policy->'overtime'->>'overtime_base', 'paid_minutes');
    v_ot_base := CASE v_ot_base_key
      WHEN 'effective_minutes' THEN v_effective_min
      WHEN 'work_minutes' THEN v_work_min
      ELSE v_paid_min
    END;

    v_regular_min := LEAST(v_ot_base, v_budget_min);
    v_overtime_min := GREATEST(0, v_ot_base - v_budget_min);

    IF v_overtime_min > 0
       AND COALESCE((v_policy->'overtime'->>'requires_prior_authorization')::boolean, true) THEN
      v_anomalies := array_append(v_anomalies, 'OVERTIME_UNAUTHORIZED');
    END IF;

    v_rules := jsonb_build_array('segment_aggregation', 'time_budget', 'activity_flags');
    IF jsonb_array_length(COALESCE(v_unclassified, '[]'::jsonb)) > 0 THEN
      v_rules := v_rules || jsonb_build_array('unclassified_gaps');
    END IF;

    v_meta := jsonb_build_object(
      'policy_version', COALESCE(v_policy->>'version', '2'),
      'work_profile', v_profile,
      'resolved_from', v_resolved->>'resolved_from',
      'per_tram_courtesy', false,
      'rules_applied', v_rules,
      'unclassified_gaps', COALESCE(v_unclassified, '[]'::jsonb),
      'buckets', jsonb_build_object(
        'presence', v_presence_min,
        'work', v_work_min,
        'travel', v_travel_min,
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
      'work_minutes', v_work_min,
      'travel_minutes', v_travel_min,
      'effective_minutes', v_effective_min,
      'paid_minutes', v_paid_min,
      'regular_minutes', v_regular_min,
      'overtime_minutes', v_overtime_min,
      'overtime_authorized_minutes', 0,
      'consolidation_meta', v_meta,
      'anomaly_codes', v_anomalies
    );
  END IF;

  -- ─── fixed_site branch (G2a — unchanged) ───────────────────────────────────
  IF v_profile <> 'fixed_site' THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'unsupported_profile', 'work_profile', v_profile);
  END IF;

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

  v_presence_min := GREATEST(0, v_gross_min - v_break_unpaid_min);

  v_resolve := api.resolve_work_day(p_employee_id, p_work_date);
  v_work_intervals := COALESCE(v_resolve->'work_intervals', '[]'::jsonb);
  v_expected_min := COALESCE((v_resolve->>'expected_minutes')::int, 0);
  v_iv_count := CASE
    WHEN v_work_intervals IS NULL OR jsonb_typeof(v_work_intervals) <> 'array' THEN 0
    ELSE jsonb_array_length(v_work_intervals)
  END;

  v_use_per_tram := v_in_count = v_out_count
    AND v_in_count > 0
    AND v_iv_count > 1
    AND v_in_count = v_iv_count;

  IF v_use_per_tram THEN
    v_rules := jsonb_build_array(
      'courtesy_per_tram', 'rounding', 'schedule_intersection', 'split_shift_presence'
    );

    FOR v_idx IN 0..(v_in_count - 1) LOOP
      v_iv := v_work_intervals->v_idx;

      SELECT occurred_at INTO v_pair_in
      FROM (
        SELECT occurred_at, ROW_NUMBER() OVER (ORDER BY occurred_at ASC, id ASC) AS rn
        FROM data.time_punches
        WHERE employee_id = p_employee_id
          AND punch_type = 'in'
          AND occurred_at >= v_punch_from
          AND occurred_at < v_punch_to
      ) q
      WHERE rn = v_idx + 1;

      SELECT occurred_at INTO v_pair_out
      FROM (
        SELECT occurred_at, ROW_NUMBER() OVER (ORDER BY occurred_at ASC, id ASC) AS rn
        FROM data.time_punches
        WHERE employee_id = p_employee_id
          AND punch_type = 'out'
          AND occurred_at >= v_punch_from
          AND occurred_at < v_punch_to
      ) q
      WHERE rn = v_idx + 1;

      v_expected_start := (p_work_date + (v_iv->>'start')::time) AT TIME ZONE v_tz;
      v_expected_end := (p_work_date + (v_iv->>'end')::time) AT TIME ZONE v_tz;
      IF (v_iv->>'end')::time <= (v_iv->>'start')::time THEN
        v_expected_end := v_expected_end + interval '1 day';
      END IF;

      v_courtesy_in := data.apply_courtesy_in_bound(
        v_pair_in, v_expected_start, v_policy, v_idx = 0
      );
      v_courtesy_out := data.apply_courtesy_out_bound(
        v_pair_out, v_expected_end, v_policy
      );

      v_anomalies := v_anomalies
        || COALESCE(ARRAY(SELECT jsonb_array_elements_text(v_courtesy_in->'anomaly_codes')), '{}')
        || COALESCE(ARRAY(SELECT jsonb_array_elements_text(v_courtesy_out->'anomaly_codes')), '{}');

      v_tram_adj_in := data.adjust_punch_for_consolidation(
        (v_courtesy_in->>'effective_in')::timestamptz,
        'in',
        v_expected_start,
        v_policy,
        v_tz
      );
      v_tram_adj_out := data.adjust_punch_for_consolidation(
        (v_courtesy_out->>'effective_out')::timestamptz,
        'out',
        v_expected_end,
        v_policy,
        v_tz
      );

      v_effective_min := v_effective_min + data.interval_intersection_minutes(
        v_tram_adj_in,
        v_tram_adj_out,
        jsonb_build_array(v_iv),
        v_tz
      );

      IF v_idx = 0 THEN
        v_adj_in := v_tram_adj_in;
      END IF;
      IF v_idx = v_in_count - 1 THEN
        v_adj_out := v_tram_adj_out;
        v_last_expected_end := v_expected_end;
      END IF;
    END LOOP;

    v_effective_min := GREATEST(0, v_effective_min - v_break_unpaid_min);
  ELSE
    v_rules := jsonb_build_array(
      'courtesy', 'rounding', 'schedule_intersection', 'split_shift_presence'
    );

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
    v_last_expected_end := (v_courtesy->>'expected_end')::timestamptz;
  END IF;

  v_work_counts_paid := COALESCE((v_policy->'activities'->'WORK'->>'counts_paid')::boolean, true);
  v_paid_min := CASE WHEN v_work_counts_paid THEN v_effective_min ELSE 0 END;
  v_regular_min := LEAST(v_effective_min, v_expected_min);

  IF v_adj_out > v_last_expected_end THEN
    v_overtime_min := GREATEST(
      0,
      (EXTRACT(EPOCH FROM (v_adj_out - v_last_expected_end)) / 60)::int
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
    'per_tram_courtesy', v_use_per_tram,
    'rules_applied', v_rules,
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


REVOKE ALL ON FUNCTION data.consolidate_day_buckets(uuid, date, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.consolidate_day_buckets(uuid, date, uuid) TO service_role;

