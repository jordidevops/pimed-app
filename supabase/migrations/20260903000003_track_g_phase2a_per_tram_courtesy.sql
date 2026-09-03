-- Track G Phase 2a.1: cortesia per tram (jornada partida §3.6, §4.3) + payroll review effective_minutes

-- =============================================================================
-- 1. Courtesy helpers — single IN/OUT bound vs scheduled interval edge
-- =============================================================================

CREATE OR REPLACE FUNCTION data.apply_courtesy_in_bound(
  p_in_at             timestamptz,
  p_expected_start    timestamptz,
  p_policy            jsonb,
  p_check_overflow    boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_courtesy       jsonb;
  v_eff_in         timestamptz;
  v_early_min      int;
  v_late_min       int;
  v_anomalies      text[] := '{}';
  v_overflow_early text;
BEGIN
  IF p_in_at IS NULL OR p_expected_start IS NULL THEN
    RETURN jsonb_build_object(
      'effective_in', p_in_at,
      'anomaly_codes', v_anomalies
    );
  END IF;

  v_courtesy := COALESCE(p_policy->'courtesy', '{}'::jsonb);
  v_overflow_early := COALESCE(v_courtesy->>'overflow_early', 'needs_review');

  IF p_in_at <= p_expected_start THEN
    v_early_min := GREATEST(0, (EXTRACT(EPOCH FROM (p_expected_start - p_in_at)) / 60)::int);
    IF v_early_min <= COALESCE((v_courtesy->>'early_arrival_minutes')::int, 15) THEN
      v_eff_in := p_expected_start;
    ELSE
      IF p_check_overflow AND v_overflow_early = 'needs_review' THEN
        v_anomalies := array_append(v_anomalies, 'EFFECTIVE_OVERFLOW_EARLY');
      END IF;
      v_eff_in := p_expected_start;
    END IF;
  ELSE
    v_late_min := GREATEST(0, (EXTRACT(EPOCH FROM (p_in_at - p_expected_start)) / 60)::int);
    IF v_late_min <= COALESCE((v_courtesy->>'late_arrival_grace_minutes')::int, 5) THEN
      v_eff_in := p_expected_start;
    ELSE
      v_eff_in := p_in_at;
      v_anomalies := array_append(v_anomalies, 'LATE_ARRIVAL');
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'effective_in', v_eff_in,
    'anomaly_codes', v_anomalies
  );
END;
$$;

CREATE OR REPLACE FUNCTION data.apply_courtesy_out_bound(
  p_out_at          timestamptz,
  p_expected_end    timestamptz,
  p_policy          jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_courtesy      jsonb;
  v_eff_out       timestamptz;
  v_late_out_min  int;
  v_early_out_min int;
  v_anomalies     text[] := '{}';
BEGIN
  IF p_out_at IS NULL OR p_expected_end IS NULL THEN
    RETURN jsonb_build_object(
      'effective_out', p_out_at,
      'anomaly_codes', v_anomalies
    );
  END IF;

  v_courtesy := COALESCE(p_policy->'courtesy', '{}'::jsonb);

  IF p_out_at >= p_expected_end THEN
    v_late_out_min := GREATEST(0, (EXTRACT(EPOCH FROM (p_out_at - p_expected_end)) / 60)::int);
    IF v_late_out_min <= COALESCE((v_courtesy->>'late_departure_minutes')::int, 15) THEN
      v_eff_out := p_expected_end;
    ELSE
      v_eff_out := p_out_at;
      IF v_late_out_min > COALESCE((v_courtesy->>'late_departure_minutes')::int, 15) THEN
        v_anomalies := array_append(v_anomalies, 'EFFECTIVE_OVERFLOW_LATE');
      END IF;
    END IF;
  ELSE
    v_early_out_min := GREATEST(0, (EXTRACT(EPOCH FROM (p_expected_end - p_out_at)) / 60)::int);
    IF v_early_out_min <= COALESCE((v_courtesy->>'early_departure_minutes')::int, 15) THEN
      v_eff_out := p_expected_end;
    ELSE
      v_eff_out := p_out_at;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'effective_out', v_eff_out,
    'anomaly_codes', v_anomalies
  );
END;
$$;

REVOKE ALL ON FUNCTION data.apply_courtesy_in_bound(timestamptz, timestamptz, jsonb, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.apply_courtesy_out_bound(timestamptz, timestamptz, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.apply_courtesy_in_bound(timestamptz, timestamptz, jsonb, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION data.apply_courtesy_out_bound(timestamptz, timestamptz, jsonb) TO service_role;

-- Envelope courtesy (single tram / fallback) — delegates to per-bound helpers
CREATE OR REPLACE FUNCTION data.apply_courtesy_work_bounds(
  p_in_at             timestamptz,
  p_out_at            timestamptz,
  p_work_date         date,
  p_work_intervals    jsonb,
  p_policy            jsonb,
  p_tz                text
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_first_iv       jsonb;
  v_last_iv        jsonb;
  v_expected_start timestamptz;
  v_expected_end   timestamptz;
  v_in_result      jsonb;
  v_out_result     jsonb;
  v_anomalies      text[] := '{}';
BEGIN
  IF p_in_at IS NULL OR p_out_at IS NULL OR p_out_at <= p_in_at THEN
    RETURN jsonb_build_object(
      'effective_in', p_in_at,
      'effective_out', p_out_at,
      'anomaly_codes', v_anomalies
    );
  END IF;

  IF p_work_intervals IS NULL
     OR jsonb_typeof(p_work_intervals) <> 'array'
     OR jsonb_array_length(p_work_intervals) = 0 THEN
    RETURN jsonb_build_object(
      'effective_in', p_in_at,
      'effective_out', p_out_at,
      'anomaly_codes', v_anomalies
    );
  END IF;

  v_first_iv := p_work_intervals->0;
  v_last_iv := p_work_intervals->(jsonb_array_length(p_work_intervals) - 1);

  v_expected_start := (p_work_date + (v_first_iv->>'start')::time) AT TIME ZONE p_tz;
  v_expected_end := (p_work_date + (v_last_iv->>'end')::time) AT TIME ZONE p_tz;
  IF (v_last_iv->>'end')::time <= (v_last_iv->>'start')::time THEN
    v_expected_end := v_expected_end + interval '1 day';
  END IF;

  v_in_result := data.apply_courtesy_in_bound(p_in_at, v_expected_start, p_policy, true);
  v_out_result := data.apply_courtesy_out_bound(p_out_at, v_expected_end, p_policy);

  v_anomalies := COALESCE(
    ARRAY(SELECT jsonb_array_elements_text(v_in_result->'anomaly_codes')),
    '{}'
  ) || COALESCE(
    ARRAY(SELECT jsonb_array_elements_text(v_out_result->'anomaly_codes')),
    '{}'
  );

  RETURN jsonb_build_object(
    'effective_in', v_in_result->'effective_in',
    'effective_out', v_out_result->'effective_out',
    'expected_start', v_expected_start,
    'expected_end', v_expected_end,
    'anomaly_codes', to_jsonb(v_anomalies)
  );
END;
$$;

-- =============================================================================
-- 2. consolidate_day_buckets — per-tram courtesy when #IN=#OUT=#intervals
-- =============================================================================

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
  v_iv_count         int;
  v_use_per_tram     boolean;
  v_gross_min        int;
  v_break_unpaid_min int := 0;
  v_resolve          jsonb;
  v_work_intervals   jsonb;
  v_expected_min     int;
  v_courtesy         jsonb;
  v_adj_in           timestamptz;
  v_adj_out          timestamptz;
  v_effective_min    int := 0;
  v_paid_min         int;
  v_regular_min      int;
  v_overtime_min     int;
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

-- =============================================================================
-- 3. get_payroll_review_days — expose effective_minutes (G2a)
-- =============================================================================

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
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_from > p_to THEN
    RAISE EXCEPTION 'invalid_date_range';
  END IF;

  v_days := (p_to - p_from) + 1;
  IF v_days > 93 THEN
    RAISE EXCEPTION 'date_range_too_large' USING DETAIL = 'max 93 days';
  END IF;

  SELECT e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF NOT (data.jwt_user_tenants() ? v_emp.tenant_id::text) THEN
      RAISE EXCEPTION 'insufficient_privilege';
    END IF;
    IF NOT (
      data.jwt_has_permission(v_emp.tenant_id, 'attendance.view_all', v_emp.site_id)
      OR data.jwt_has_permission(v_emp.tenant_id, 'attendance.approve', v_emp.site_id)
      OR EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = p_employee_id AND e.user_id = auth.uid()
      )
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege';
    END IF;
  END IF;

  v_tz := COALESCE(data.get_site_timezone(v_emp.site_id, v_emp.tenant_id), 'Europe/Madrid');

  SELECT COALESCE(jsonb_agg(day_row ORDER BY day_row ->> 'work_date'), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'work_date',          gs.dt::date,
      'day_type',           wd.resolve ->> 'day_type',
      'expected_minutes',   COALESCE((wd.resolve ->> 'expected_minutes')::int, 0),
      'holiday_name',       wd.resolve ->> 'holiday_name',
      'is_laborable',
        COALESCE((wd.resolve ->> 'expected_minutes')::int, 0) > 0
        OR (wd.resolve ->> 'day_type') IN ('working', 'half_holiday'),
      'worked_minutes',
        COALESCE(
          NULLIF(tds.worked_minutes, 0),
          CASE
            WHEN punches.first_in IS NOT NULL
              AND punches.last_out IS NOT NULL
              AND punches.last_out > punches.first_in
            THEN ROUND(EXTRACT(EPOCH FROM (punches.last_out - punches.first_in)) / 60)::int
            WHEN punches.first_in IS NOT NULL
            THEN ROUND(EXTRACT(EPOCH FROM (now() - punches.first_in)) / 60)::int
            ELSE 0
          END
        ),
      'effective_minutes',  tds.effective_minutes,
      'overtime_minutes',   COALESCE(tds.overtime_minutes, 0),
      'punch_count',        COALESCE(tds.punch_count, COALESCE(punches.punch_count, 0)),
      'remote_punch_count', COALESCE(punches.remote_punch_count, 0),
      'entry_status',       te.status,
      'summary_status',     COALESCE(tds.status, 'none'),
      'needs_review',       COALESCE(tds.needs_review, false),
      'anomalies',          to_jsonb(COALESCE(tds.anomaly_codes, '{}'::text[])),
      'summary_id',         tds.id,
      'absence_id',         abs_row.absence_id,
      'absence_type',       abs_row.absence_type,
      'absence_status',   abs_row.absence_status,
      'absence_is_paid',    abs_row.absence_is_paid,
      'partial_start_time', abs_row.partial_start_time,
      'partial_end_time',   abs_row.partial_end_time,
      'partial_hours',      abs_row.partial_hours,
      'is_it',              COALESCE(abs_row.is_it, false),
      'it_type',            CASE WHEN COALESCE(abs_row.is_it, false) THEN abs_row.absence_type ELSE NULL END,
      'payroll_locked',     tds.payroll_locked_at IS NOT NULL,
      'payroll_action',
        CASE
          WHEN te.status = 'open'
            OR COALESCE(tds.needs_review, false)
            OR tds.status = 'exported'
            OR tds.payroll_locked_at IS NOT NULL
          THEN 'blocked'
          WHEN abs_row.absence_id IS NOT NULL
            AND abs_row.absence_status IN ('approved', 'active', 'closed')
          THEN 'absence_ok'
          WHEN (
            COALESCE((wd.resolve ->> 'expected_minutes')::int, 0) > 0
            OR (wd.resolve ->> 'day_type') IN ('working', 'half_holiday')
          )
            AND (te.id IS NULL OR te.status NOT IN ('closed', 'adjusted'))
            AND COALESCE(tds.punch_count, punches.punch_count, 0) = 0
          THEN 'missing_punch'
          WHEN tds.status = 'draft'
            AND (
              COALESCE(tds.worked_minutes, 0) > 0
              OR COALESCE(tds.punch_count, punches.punch_count, 0) > 0
            )
          THEN 'approve'
          ELSE NULL
        END
    ) AS day_row
    FROM generate_series(p_from, p_to, interval '1 day') AS gs(dt)
    CROSS JOIN LATERAL (
      SELECT api.resolve_work_day(p_employee_id, gs.dt::date) AS resolve
    ) wd
    LEFT JOIN data.time_entries te
      ON te.employee_id = p_employee_id
     AND te.work_date = gs.dt::date
    LEFT JOIN data.time_daily_summaries tds
      ON tds.employee_id = p_employee_id
     AND tds.work_date = gs.dt::date
    LEFT JOIN LATERAL (
      SELECT
        COUNT(*)::int AS punch_count,
        COUNT(*) FILTER (WHERE tp.is_remote)::int AS remote_punch_count,
        MIN(tp.occurred_at) FILTER (WHERE tp.punch_type = 'in') AS first_in,
        MAX(tp.occurred_at) FILTER (WHERE tp.punch_type = 'out') AS last_out
      FROM data.time_punches tp
      WHERE tp.employee_id = p_employee_id
        AND (tp.occurred_at AT TIME ZONE v_tz)::date = gs.dt::date
    ) punches ON true
    LEFT JOIN LATERAL (
      SELECT
        ea.id AS absence_id,
        ea.absence_type,
        ea.status AS absence_status,
        ea.is_paid AS absence_is_paid,
        ea.partial_start_time,
        ea.partial_end_time,
        ea.partial_hours,
        COALESCE(tatc.is_it, false) AS is_it
      FROM data.employee_absences ea
      LEFT JOIN LATERAL (
        SELECT c.is_it
        FROM data.tenant_absence_type_configs c
        WHERE c.absence_type = ea.absence_type
          AND (c.tenant_id = v_emp.tenant_id OR (c.tenant_id IS NULL AND c.is_system = true))
        ORDER BY CASE WHEN c.tenant_id = v_emp.tenant_id THEN 0 ELSE 1 END
        LIMIT 1
      ) tatc ON true
      WHERE ea.employee_id = p_employee_id
        AND ea.start_date <= gs.dt::date
        AND ea.end_date >= gs.dt::date
        AND ea.status IN ('approved', 'active', 'closed', 'requested')
      ORDER BY
        CASE ea.status
          WHEN 'active' THEN 0
          WHEN 'approved' THEN 1
          WHEN 'closed' THEN 2
          WHEN 'requested' THEN 3
          ELSE 4
        END,
        ea.created_at DESC
      LIMIT 1
    ) abs_row ON true
  ) q;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'from', p_from,
    'to', p_to,
    'days', v_rows
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_payroll_review_days(uuid, date, date) TO authenticated;

COMMENT ON FUNCTION api.get_payroll_review_days IS
  'Dies de revisió nòmina per empleat. Inclou effective_minutes quan consolidació G2a activa.';

NOTIFY pgrst, 'reload schema';
