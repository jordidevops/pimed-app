-- Track G Phase 2a — fixed_site consolidation tests (§4, §4.6)
BEGIN;

CREATE TEMP TABLE g2a_test_log (id serial, msg text);

CREATE OR REPLACE FUNCTION g2a_assert(p_ok boolean, p_msg text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok THEN
    INSERT INTO g2a_test_log (msg) VALUES ('[PASS] ' || p_msg);
  ELSE
    RAISE EXCEPTION '[FAIL] %', p_msg;
  END IF;
END;
$$;

INSERT INTO data.employees (id, tenant_id, site_id, full_name, status, attendance_work_profile)
VALUES (
  'f4000000-0000-0000-0000-000000000010',
  '10000000-0000-0000-0000-000000000001',
  '30000000-0000-0000-0000-000000000001',
  'G2a Fixed',
  'active',
  'fixed_site'
)
ON CONFLICT (id) DO UPDATE SET attendance_work_profile = EXCLUDED.attendance_work_profile;

UPDATE data.tenants
SET settings = COALESCE(settings, '{}'::jsonb)
  || '{"attendance_effective_time_enabled": false}'::jsonb
WHERE id = '10000000-0000-0000-0000-000000000001';

DO $$
DECLARE
  v_policy   jsonb;
  v_tz       text := 'Europe/Madrid';
  v_day      date := '2026-07-15';
  v_adj      timestamptz;
  v_courtesy jsonb;
  v_iv       jsonb := '[{"start":"08:00","end":"18:00"}]'::jsonb;
  v_result   jsonb;
BEGIN
  v_policy := data.default_attendance_record_policy('fixed_site');

  -- T1: IN 08:03 tardana — mai arrodonir cap amunt a 08:15 (§4.6)
  v_adj := data.adjust_punch_for_consolidation(
    (v_day + time '08:03') AT TIME ZONE v_tz,
    'in',
    (v_day + time '08:00') AT TIME ZONE v_tz,
    v_policy,
    v_tz
  );
  PERFORM g2a_assert(
    v_adj IS DISTINCT FROM ((v_day + time '08:15') AT TIME ZONE v_tz),
    'T1_in_0803_never_0815'
  );

  -- T2: OUT 18:18 favor_employee → 18:30
  v_adj := data.adjust_punch_for_consolidation(
    (v_day + time '18:18') AT TIME ZONE v_tz,
    'out',
    (v_day + time '18:00') AT TIME ZONE v_tz,
    v_policy,
    v_tz
  );
  PERFORM g2a_assert(
    v_adj = ((v_day + time '18:30') AT TIME ZONE v_tz),
    'T2_out_1818_rounds_1830'
  );

  -- T3: cortesia entrada 07:55 → efectiu 08:00
  v_courtesy := data.apply_courtesy_work_bounds(
    (v_day + time '07:55') AT TIME ZONE v_tz,
    (v_day + time '18:05') AT TIME ZONE v_tz,
    v_day,
    v_iv,
    v_policy,
    v_tz
  );
  PERFORM g2a_assert(
    (v_courtesy->>'effective_in')::timestamptz = ((v_day + time '08:00') AT TIME ZONE v_tz),
    'T3_courtesy_early_in_0800'
  );

  -- T4: consolidate flag OFF → skipped
  v_result := data.consolidate_day_buckets(
    'f4000000-0000-0000-0000-000000000010',
    v_day,
    '10000000-0000-0000-0000-000000000001'
  );
  PERFORM g2a_assert(
    COALESCE(v_result->>'skipped', 'false') = 'true'
    AND COALESCE(v_result->>'reason', '') = 'flag_off',
    'T4_consolidate_skipped_flag_off'
  );

  -- T5: OT pas 2 — OUT 18:18 → 30 min vs expected_end 18:00
  v_courtesy := data.apply_courtesy_work_bounds(
    (v_day + time '08:00') AT TIME ZONE v_tz,
    (v_day + time '18:18') AT TIME ZONE v_tz,
    v_day,
    v_iv,
    v_policy,
    v_tz
  );
  v_adj := data.adjust_punch_for_consolidation(
    (v_courtesy->>'effective_out')::timestamptz,
    'out',
    (v_courtesy->>'expected_end')::timestamptz,
    v_policy,
    v_tz
  );
  PERFORM g2a_assert(
    (EXTRACT(EPOCH FROM (v_adj - (v_courtesy->>'expected_end')::timestamptz)) / 60)::int = 30,
    'T5_overtime_30_from_out_1818'
  );
END;
$$;

-- T6: Jornada partida §4.3 — 07:55 IN · 14:05 OUT · 16:10 IN · 18:40 OUT
DO $$
DECLARE
  v_tenant   uuid := '10000000-0000-0000-0000-000000000001';
  v_site     uuid := '30000000-0000-0000-0000-000000000001';
  v_employee uuid := 'f4000000-0000-0000-0000-000000000010';
  v_tz       text := 'Europe/Madrid';
  v_day      date := '2026-07-16';
  v_from     timestamptz;
  v_to       timestamptz;
  v_resolve  jsonb;
  v_result   jsonb;
  v_sum      int;
  v_worked   int;
  v_presence int;
  v_effective int;
  v_ot       int;
  v_anomalies text[];
BEGIN
  v_from := v_day AT TIME ZONE v_tz;
  v_to   := (v_day + 1) AT TIME ZONE v_tz;

  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb)
    || '{"attendance_effective_time_enabled": true}'::jsonb
  WHERE id = v_tenant;

  INSERT INTO data.labor_calendar_overrides (
    tenant_id, site_id, calendar_date, day_type, day_name, work_intervals
  ) VALUES (
    v_tenant, v_site, v_day, 'work', 'G2a split shift fixture',
    '[{"start":"08:00","end":"14:00"},{"start":"16:00","end":"18:00"}]'::jsonb
  )
  ON CONFLICT ON CONSTRAINT labor_calendar_overrides_unique DO UPDATE SET
    day_type = EXCLUDED.day_type,
    day_name = EXCLUDED.day_name,
    work_intervals = EXCLUDED.work_intervals,
    updated_at = now();

  DELETE FROM data.time_punches
  WHERE employee_id = v_employee
    AND occurred_at >= v_from AND occurred_at < v_to;

  DELETE FROM data.time_daily_summaries
  WHERE employee_id = v_employee AND work_date = v_day;

  DELETE FROM data.time_entries
  WHERE employee_id = v_employee AND work_date = v_day;

  INSERT INTO data.time_punches (
    tenant_id, site_id, employee_id, client_op_id, punch_type, occurred_at, source
  ) VALUES
    (v_tenant, v_site, v_employee, 'f6000000-0000-0000-0000-000000000001', 'in',  (v_day + time '07:55') AT TIME ZONE v_tz, 'mobile'),
    (v_tenant, v_site, v_employee, 'f6000000-0000-0000-0000-000000000002', 'out', (v_day + time '14:05') AT TIME ZONE v_tz, 'mobile'),
    (v_tenant, v_site, v_employee, 'f6000000-0000-0000-0000-000000000003', 'in',  (v_day + time '16:10') AT TIME ZONE v_tz, 'mobile'),
    (v_tenant, v_site, v_employee, 'f6000000-0000-0000-0000-000000000004', 'out', (v_day + time '18:40') AT TIME ZONE v_tz, 'mobile');

  v_sum := data.sum_punch_in_out_minutes(v_employee, v_from, v_to);
  PERFORM g2a_assert(v_sum = 520, 'T6a_sum_in_out_pairs_520');

  v_resolve := api.resolve_work_day(v_employee, v_day);
  PERFORM g2a_assert(
    COALESCE((v_resolve->>'expected_minutes')::int, 0) = 480,
    'T6b_expected_minutes_480'
  );

  v_result := api.recompute_attendance_worker(v_employee, v_day, v_tenant);

  SELECT worked_minutes, presence_minutes, effective_minutes, overtime_minutes, anomaly_codes
  INTO v_worked, v_presence, v_effective, v_ot, v_anomalies
  FROM data.time_daily_summaries
  WHERE employee_id = v_employee AND work_date = v_day;

  PERFORM g2a_assert(v_worked = 520, 'T6c_worked_minutes_520');
  PERFORM g2a_assert(v_presence = 520, 'T6d_presence_minutes_520');
  -- Per-tram courtesy + arrodoniment tardana IN (16:10 → ↓16:00) → efectiu 480
  PERFORM g2a_assert(v_effective = 480, 'T6e_effective_minutes_480');
  -- §4.2: OUT 18:40 → arrodoniment 18:45 → OT 45 min vs expected_end 18:00
  PERFORM g2a_assert(v_ot = 45, 'T6f_overtime_minutes_45');

  PERFORM g2a_assert(
    'LATE_ARRIVAL' = ANY(COALESCE(v_anomalies, '{}')),
    'T6g_late_arrival_anomaly'
  );
END;
$$;

-- T7: grace 15 min — IN 16:10 dins cortesia, sense LATE_ARRIVAL
DO $$
DECLARE
  v_tenant   uuid := '10000000-0000-0000-0000-000000000001';
  v_site     uuid := '30000000-0000-0000-0000-000000000001';
  v_employee uuid := 'f4000000-0000-0000-0000-000000000010';
  v_tz       text := 'Europe/Madrid';
  v_day      date := '2026-07-17';
  v_from     timestamptz;
  v_to       timestamptz;
  v_policy   jsonb;
  v_effective int;
  v_anomalies text[];
BEGIN
  v_from := v_day AT TIME ZONE v_tz;
  v_to   := (v_day + 1) AT TIME ZONE v_tz;

  v_policy := data.default_attendance_record_policy('fixed_site');
  v_policy := jsonb_set(
    v_policy,
    '{courtesy,late_arrival_grace_minutes}',
    '15'::jsonb
  );

  DELETE FROM data.attendance_record_policies
  WHERE employee_id = v_employee;

  INSERT INTO data.attendance_record_policies (
    tenant_id, scope, employee_id, effective_from, policy
  ) VALUES (
    v_tenant, 'employee', v_employee, '2020-01-01', v_policy
  );

  INSERT INTO data.labor_calendar_overrides (
    tenant_id, site_id, calendar_date, day_type, day_name, work_intervals
  ) VALUES (
    v_tenant, v_site, v_day, 'work', 'G2a split grace 15',
    '[{"start":"08:00","end":"14:00"},{"start":"16:00","end":"18:00"}]'::jsonb
  )
  ON CONFLICT ON CONSTRAINT labor_calendar_overrides_unique DO UPDATE SET
    work_intervals = EXCLUDED.work_intervals,
    updated_at = now();

  DELETE FROM data.time_punches
  WHERE employee_id = v_employee AND occurred_at >= v_from AND occurred_at < v_to;
  DELETE FROM data.time_daily_summaries
  WHERE employee_id = v_employee AND work_date = v_day;
  DELETE FROM data.time_entries
  WHERE employee_id = v_employee AND work_date = v_day;

  INSERT INTO data.time_punches (
    tenant_id, site_id, employee_id, client_op_id, punch_type, occurred_at, source
  ) VALUES
    (v_tenant, v_site, v_employee, 'f6000000-0000-0000-0000-000000000011', 'in',  (v_day + time '07:55') AT TIME ZONE v_tz, 'mobile'),
    (v_tenant, v_site, v_employee, 'f6000000-0000-0000-0000-000000000012', 'out', (v_day + time '14:05') AT TIME ZONE v_tz, 'mobile'),
    (v_tenant, v_site, v_employee, 'f6000000-0000-0000-0000-000000000013', 'in',  (v_day + time '16:10') AT TIME ZONE v_tz, 'mobile'),
    (v_tenant, v_site, v_employee, 'f6000000-0000-0000-0000-000000000014', 'out', (v_day + time '18:40') AT TIME ZONE v_tz, 'mobile');

  PERFORM api.recompute_attendance_worker(v_employee, v_day, v_tenant);

  SELECT effective_minutes, anomaly_codes
  INTO v_effective, v_anomalies
  FROM data.time_daily_summaries
  WHERE employee_id = v_employee AND work_date = v_day;

  PERFORM g2a_assert(v_effective = 480, 'T7_effective_minutes_480_grace_15');
  PERFORM g2a_assert(
    NOT ('LATE_ARRIVAL' = ANY(COALESCE(v_anomalies, '{}'))),
    'T7_no_late_arrival_within_grace_15'
  );

  DELETE FROM data.attendance_record_policies WHERE employee_id = v_employee;
END;
$$;

-- T8–T10: G2a.2 flex_midday (dies separats; sense DELETE de punches)
DO $$
DECLARE
  v_tenant   uuid := '10000000-0000-0000-0000-000000000001';
  v_site     uuid := '30000000-0000-0000-0000-000000000001';
  v_employee uuid := 'f4000000-0000-0000-0000-000000000010';
  v_tz       text := 'Europe/Madrid';
  v_day8     date := '2026-07-18';
  v_day9     date := '2026-07-19';
  v_day10    date := '2026-07-20';
  v_policy   jsonb;
  v_anomalies text[];
  v_needs    boolean;
BEGIN
  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb)
    || '{"attendance_effective_time_enabled": true}'::jsonb
  WHERE id = v_tenant;

  v_policy := data.default_attendance_record_policy('fixed_site');
  v_policy := jsonb_set(v_policy, '{flex_midday}', '{
    "enabled": true,
    "earliest_break_end": "13:00",
    "latest_shift_resume": "16:00",
    "min_break_minutes": 60,
    "max_break_minutes": 120,
    "outside_window": "needs_review"
  }'::jsonb);
  v_policy := jsonb_set(v_policy, '{courtesy,late_arrival_grace_minutes}', '15'::jsonb);

  DELETE FROM data.attendance_record_policies WHERE employee_id = v_employee;
  INSERT INTO data.attendance_record_policies (
    tenant_id, scope, employee_id, effective_from, policy
  ) VALUES (v_tenant, 'employee', v_employee, '2020-01-01', v_policy);

  -- T8: gap 120 min dins finestra → OK
  INSERT INTO data.labor_calendar_overrides (
    tenant_id, site_id, calendar_date, day_type, day_name, work_intervals
  ) VALUES (
    v_tenant, v_site, v_day8, 'work', 'G2a2 flex ok',
    '[{"start":"08:00","end":"14:00"},{"start":"16:00","end":"18:00"}]'::jsonb
  )
  ON CONFLICT ON CONSTRAINT labor_calendar_overrides_unique DO UPDATE SET
    work_intervals = EXCLUDED.work_intervals, updated_at = now();

  INSERT INTO data.time_punches (
    tenant_id, site_id, employee_id, client_op_id, punch_type, occurred_at, source
  ) VALUES
    (v_tenant, v_site, v_employee, 'f6000000-0000-0000-0000-000000000021', 'in',  (v_day8 + time '07:55') AT TIME ZONE v_tz, 'mobile'),
    (v_tenant, v_site, v_employee, 'f6000000-0000-0000-0000-000000000022', 'out', (v_day8 + time '14:10') AT TIME ZONE v_tz, 'mobile'),
    (v_tenant, v_site, v_employee, 'f6000000-0000-0000-0000-000000000023', 'in',  (v_day8 + time '16:10') AT TIME ZONE v_tz, 'mobile'),
    (v_tenant, v_site, v_employee, 'f6000000-0000-0000-0000-000000000024', 'out', (v_day8 + time '18:40') AT TIME ZONE v_tz, 'mobile');

  PERFORM api.recompute_attendance_worker(v_employee, v_day8, v_tenant);
  SELECT anomaly_codes INTO v_anomalies
  FROM data.time_daily_summaries
  WHERE employee_id = v_employee AND work_date = v_day8;

  PERFORM g2a_assert(
    NOT ('LONG_BREAK' = ANY(COALESCE(v_anomalies, '{}'))),
    'T8_flex_ok_no_long_break'
  );
  PERFORM g2a_assert(
    NOT ('SHORT_BREAK' = ANY(COALESCE(v_anomalies, '{}'))),
    'T8_flex_ok_no_short_break'
  );

  -- T9: gap 150 min amb latest 17:00 → LONG_BREAK
  UPDATE data.attendance_record_policies
  SET policy = jsonb_set(policy, '{flex_midday,latest_shift_resume}', '"17:00"'::jsonb)
  WHERE employee_id = v_employee;

  INSERT INTO data.labor_calendar_overrides (
    tenant_id, site_id, calendar_date, day_type, day_name, work_intervals
  ) VALUES (
    v_tenant, v_site, v_day9, 'work', 'G2a2 long break',
    '[{"start":"08:00","end":"14:00"},{"start":"16:00","end":"18:00"}]'::jsonb
  )
  ON CONFLICT ON CONSTRAINT labor_calendar_overrides_unique DO UPDATE SET
    work_intervals = EXCLUDED.work_intervals, updated_at = now();

  INSERT INTO data.time_punches (
    tenant_id, site_id, employee_id, client_op_id, punch_type, occurred_at, source
  ) VALUES
    (v_tenant, v_site, v_employee, 'f6000000-0000-0000-0000-000000000031', 'in',  (v_day9 + time '08:00') AT TIME ZONE v_tz, 'mobile'),
    (v_tenant, v_site, v_employee, 'f6000000-0000-0000-0000-000000000032', 'out', (v_day9 + time '14:00') AT TIME ZONE v_tz, 'mobile'),
    (v_tenant, v_site, v_employee, 'f6000000-0000-0000-0000-000000000033', 'in',  (v_day9 + time '16:30') AT TIME ZONE v_tz, 'mobile'),
    (v_tenant, v_site, v_employee, 'f6000000-0000-0000-0000-000000000034', 'out', (v_day9 + time '18:00') AT TIME ZONE v_tz, 'mobile');

  PERFORM api.recompute_attendance_worker(v_employee, v_day9, v_tenant);
  SELECT anomaly_codes, needs_review INTO v_anomalies, v_needs
  FROM data.time_daily_summaries
  WHERE employee_id = v_employee AND work_date = v_day9;

  PERFORM g2a_assert(
    'LONG_BREAK' = ANY(COALESCE(v_anomalies, '{}')),
    'T9_long_break_when_gap_over_max'
  );
  PERFORM g2a_assert(COALESCE(v_needs, false), 'T9_needs_review_on_long_break');

  -- T10: OUT 12:00 < earliest 13:00 → FLEX_MIDDAY_OUTSIDE_WINDOW
  UPDATE data.attendance_record_policies
  SET policy = jsonb_set(
    jsonb_set(policy, '{flex_midday,latest_shift_resume}', '"16:00"'::jsonb),
    '{flex_midday,outside_window}',
    '"needs_review"'::jsonb
  )
  WHERE employee_id = v_employee;

  INSERT INTO data.labor_calendar_overrides (
    tenant_id, site_id, calendar_date, day_type, day_name, work_intervals
  ) VALUES (
    v_tenant, v_site, v_day10, 'work', 'G2a2 outside',
    '[{"start":"08:00","end":"14:00"},{"start":"16:00","end":"18:00"}]'::jsonb
  )
  ON CONFLICT ON CONSTRAINT labor_calendar_overrides_unique DO UPDATE SET
    work_intervals = EXCLUDED.work_intervals, updated_at = now();

  INSERT INTO data.time_punches (
    tenant_id, site_id, employee_id, client_op_id, punch_type, occurred_at, source
  ) VALUES
    (v_tenant, v_site, v_employee, 'f6000000-0000-0000-0000-000000000041', 'in',  (v_day10 + time '08:00') AT TIME ZONE v_tz, 'mobile'),
    (v_tenant, v_site, v_employee, 'f6000000-0000-0000-0000-000000000042', 'out', (v_day10 + time '12:00') AT TIME ZONE v_tz, 'mobile'),
    (v_tenant, v_site, v_employee, 'f6000000-0000-0000-0000-000000000043', 'in',  (v_day10 + time '14:00') AT TIME ZONE v_tz, 'mobile'),
    (v_tenant, v_site, v_employee, 'f6000000-0000-0000-0000-000000000044', 'out', (v_day10 + time '18:00') AT TIME ZONE v_tz, 'mobile');

  PERFORM api.recompute_attendance_worker(v_employee, v_day10, v_tenant);
  SELECT anomaly_codes INTO v_anomalies
  FROM data.time_daily_summaries
  WHERE employee_id = v_employee AND work_date = v_day10;

  PERFORM g2a_assert(
    'FLEX_MIDDAY_OUTSIDE_WINDOW' = ANY(COALESCE(v_anomalies, '{}')),
    'T10_outside_window_anomaly'
  );

  DELETE FROM data.attendance_record_policies WHERE employee_id = v_employee;
END;
$$;

SELECT msg FROM g2a_test_log ORDER BY id;

ROLLBACK;
