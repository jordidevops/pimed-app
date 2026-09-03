-- Track G Phase 2b — mobile_peripatetic consolidation tests (§18.4, lampista fixture)
BEGIN;

CREATE TEMP TABLE g2b_test_log (id serial, msg text);

CREATE OR REPLACE FUNCTION g2b_assert(p_ok boolean, p_msg text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok THEN
    INSERT INTO g2b_test_log (msg) VALUES ('[PASS] ' || p_msg);
  ELSE
    RAISE EXCEPTION '[FAIL] %', p_msg;
  END IF;
END;
$$;

INSERT INTO data.employees (id, tenant_id, site_id, full_name, status, attendance_work_profile)
VALUES (
  'f4000000-0000-0000-0000-000000000020',
  '10000000-0000-0000-0000-000000000001',
  '30000000-0000-0000-0000-000000000001',
  'G2b Mobile',
  'active',
  'mobile_peripatetic'
)
ON CONFLICT (id) DO UPDATE SET attendance_work_profile = EXCLUDED.attendance_work_profile;

-- Helper: lampista punch-only timeline §5.1
CREATE OR REPLACE FUNCTION pg_temp.g2b_seed_lampista(p_day date) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_tenant   uuid := '10000000-0000-0000-0000-000000000001';
  v_site     uuid := '30000000-0000-0000-0000-000000000001';
  v_employee uuid := 'f4000000-0000-0000-0000-000000000020';
  v_tz       text := 'Europe/Madrid';
  v_from     timestamptz;
  v_to       timestamptz;
  v_op_day   text;
BEGIN
  v_from := p_day AT TIME ZONE v_tz;
  v_to   := (p_day + 1) AT TIME ZONE v_tz;
  v_op_day := to_char(p_day, 'MMDD');

  DELETE FROM data.time_activity_segments
  WHERE employee_id = v_employee AND work_date = p_day;
  DELETE FROM data.time_punches
  WHERE employee_id = v_employee AND occurred_at >= v_from AND occurred_at < v_to;
  DELETE FROM data.time_daily_summaries
  WHERE employee_id = v_employee AND work_date = p_day;
  DELETE FROM data.time_entries
  WHERE employee_id = v_employee AND work_date = p_day;

  INSERT INTO data.time_punches (
    tenant_id, site_id, employee_id, client_op_id, punch_type, occurred_at, source
  ) VALUES
    (v_tenant, v_site, v_employee, (format('f7000000-%s-4000-8000-000000000001', v_op_day))::uuid, 'day_start',   (p_day + time '06:45') AT TIME ZONE v_tz, 'mobile'),
    (v_tenant, v_site, v_employee, (format('f7000000-%s-4000-8000-000000000002', v_op_day))::uuid, 'in',          (p_day + time '08:00') AT TIME ZONE v_tz, 'mobile'),
    (v_tenant, v_site, v_employee, (format('f7000000-%s-4000-8000-000000000003', v_op_day))::uuid, 'break_start', (p_day + time '12:00') AT TIME ZONE v_tz, 'mobile'),
    (v_tenant, v_site, v_employee, (format('f7000000-%s-4000-8000-000000000004', v_op_day))::uuid, 'break_end',   (p_day + time '12:30') AT TIME ZONE v_tz, 'mobile'),
    (v_tenant, v_site, v_employee, (format('f7000000-%s-4000-8000-000000000005', v_op_day))::uuid, 'out',         (p_day + time '16:30') AT TIME ZONE v_tz, 'mobile'),
    (v_tenant, v_site, v_employee, (format('f7000000-%s-4000-8000-000000000006', v_op_day))::uuid, 'day_end',     (p_day + time '17:30') AT TIME ZONE v_tz, 'mobile');
END;
$$;

-- T1: Conveni C (default mobile) — lampista §5.1
DO $$
DECLARE
  v_tenant   uuid := '10000000-0000-0000-0000-000000000001';
  v_employee uuid := 'f4000000-0000-0000-0000-000000000020';
  v_day      date := '2026-07-20';
  v_worked   int;
  v_presence int;
  v_work     int;
  v_travel   int;
  v_paid     int;
  v_effective int;
  v_ot       int;
BEGIN
  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb)
    || '{"attendance_effective_time_enabled": true}'::jsonb
  WHERE id = v_tenant;

  DELETE FROM data.attendance_record_policies WHERE employee_id = v_employee;

  PERFORM pg_temp.g2b_seed_lampista(v_day);
  PERFORM api.recompute_attendance_worker(v_employee, v_day, v_tenant);

  SELECT worked_minutes, presence_minutes, work_minutes, travel_minutes,
         effective_minutes, paid_minutes, overtime_minutes
  INTO v_worked, v_presence, v_work, v_travel, v_effective, v_paid, v_ot
  FROM data.time_daily_summaries
  WHERE employee_id = v_employee AND work_date = v_day;

  PERFORM g2b_assert(v_presence = 645, 'T1_presence_minutes_645');
  PERFORM g2b_assert(v_worked = 480, 'T1_worked_minutes_480');
  PERFORM g2b_assert(v_work = 480, 'T1_work_minutes_480');
  PERFORM g2b_assert(v_travel = 135, 'T1_travel_minutes_135');
  PERFORM g2b_assert(v_paid = 615, 'T1_paid_minutes_615');
  PERFORM g2b_assert(v_effective = 480, 'T1_effective_minutes_480');
  PERFORM g2b_assert(v_ot = 0, 'T1_overtime_minutes_0');
END;
$$;

-- T8a: Conveni A — travel no remunerat
DO $$
DECLARE
  v_tenant   uuid := '10000000-0000-0000-0000-000000000001';
  v_employee uuid := 'f4000000-0000-0000-0000-000000000020';
  v_day      date := '2026-07-21';
  v_policy   jsonb;
  v_paid     int;
  v_effective int;
  v_ot       int;
BEGIN
  v_policy := data.default_attendance_record_policy('mobile_peripatetic');
  v_policy := jsonb_set(v_policy, '{activities,TRAVEL,counts_paid}', 'false'::jsonb);
  v_policy := jsonb_set(v_policy, '{activities,TRAVEL,counts_effective}', 'false'::jsonb);

  DELETE FROM data.attendance_record_policies WHERE employee_id = v_employee;
  INSERT INTO data.attendance_record_policies (
    tenant_id, scope, employee_id, effective_from, policy
  ) VALUES (v_tenant, 'employee', v_employee, '2020-01-01', v_policy);

  PERFORM pg_temp.g2b_seed_lampista(v_day);
  PERFORM api.recompute_attendance_worker(v_employee, v_day, v_tenant);

  SELECT paid_minutes, effective_minutes, overtime_minutes
  INTO v_paid, v_effective, v_ot
  FROM data.time_daily_summaries
  WHERE employee_id = v_employee AND work_date = v_day;

  PERFORM g2b_assert(v_paid = 480, 'T8a_paid_minutes_480');
  PERFORM g2b_assert(v_effective = 480, 'T8a_effective_minutes_480');
  PERFORM g2b_assert(v_ot = 0, 'T8a_overtime_minutes_0');
END;
$$;

-- T8b: Conveni B — travel paid + effective → OT 135
DO $$
DECLARE
  v_tenant   uuid := '10000000-0000-0000-0000-000000000001';
  v_employee uuid := 'f4000000-0000-0000-0000-000000000020';
  v_day      date := '2026-07-22';
  v_policy   jsonb;
  v_paid     int;
  v_effective int;
  v_ot       int;
BEGIN
  v_policy := data.default_attendance_record_policy('mobile_peripatetic');
  v_policy := jsonb_set(v_policy, '{activities,TRAVEL,counts_effective}', 'true'::jsonb);

  DELETE FROM data.attendance_record_policies WHERE employee_id = v_employee;
  INSERT INTO data.attendance_record_policies (
    tenant_id, scope, employee_id, effective_from, policy
  ) VALUES (v_tenant, 'employee', v_employee, '2020-01-01', v_policy);

  PERFORM pg_temp.g2b_seed_lampista(v_day);
  PERFORM api.recompute_attendance_worker(v_employee, v_day, v_tenant);

  SELECT paid_minutes, effective_minutes, overtime_minutes
  INTO v_paid, v_effective, v_ot
  FROM data.time_daily_summaries
  WHERE employee_id = v_employee AND work_date = v_day;

  PERFORM g2b_assert(v_paid = 615, 'T8b_paid_minutes_615');
  PERFORM g2b_assert(v_effective = 615, 'T8b_effective_minutes_615');
  PERFORM g2b_assert(v_ot = 135, 'T8b_overtime_minutes_135');
END;
$$;

-- T9: Flag OFF — buckets zero, worked inalterat
DO $$
DECLARE
  v_tenant   uuid := '10000000-0000-0000-0000-000000000001';
  v_employee uuid := 'f4000000-0000-0000-0000-000000000020';
  v_day      date := '2026-07-23';
  v_worked   int;
  v_paid     int;
BEGIN
  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb)
    || '{"attendance_effective_time_enabled": false}'::jsonb
  WHERE id = v_tenant;

  PERFORM pg_temp.g2b_seed_lampista(v_day);
  PERFORM api.recompute_attendance_worker(v_employee, v_day, v_tenant);

  SELECT worked_minutes, paid_minutes
  INTO v_worked, v_paid
  FROM data.time_daily_summaries
  WHERE employee_id = v_employee AND work_date = v_day;

  PERFORM g2b_assert(v_worked = 480, 'T9_worked_minutes_480_flag_off');
  PERFORM g2b_assert(COALESCE(v_paid, 0) = 0, 'T9_paid_minutes_zero_flag_off');
END;
$$;

-- T10: day_start sense day_end → DAY_NOT_CLOSED, consolidate skipped
DO $$
DECLARE
  v_tenant      uuid := '10000000-0000-0000-0000-000000000001';
  v_site        uuid := '30000000-0000-0000-0000-000000000001';
  v_employee    uuid := 'f4000000-0000-0000-0000-000000000020';
  v_day         date := '2026-07-24';
  v_tz          text := 'Europe/Madrid';
  v_from        timestamptz;
  v_to          timestamptz;
  v_op_day      text;
  v_result      jsonb;
  v_anomalies   text[];
  v_paid        int;
  v_consolidated jsonb;
BEGIN
  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb)
    || '{"attendance_effective_time_enabled": true}'::jsonb
  WHERE id = v_tenant;

  DELETE FROM data.attendance_record_policies WHERE employee_id = v_employee;

  v_from := v_day AT TIME ZONE v_tz;
  v_to   := (v_day + 1) AT TIME ZONE v_tz;
  v_op_day := to_char(v_day, 'MMDD');

  DELETE FROM data.time_activity_segments
  WHERE employee_id = v_employee AND work_date = v_day;
  DELETE FROM data.time_punches
  WHERE employee_id = v_employee AND occurred_at >= v_from AND occurred_at < v_to;
  DELETE FROM data.time_daily_summaries
  WHERE employee_id = v_employee AND work_date = v_day;
  DELETE FROM data.time_entries
  WHERE employee_id = v_employee AND work_date = v_day;

  INSERT INTO data.time_punches (
    tenant_id, site_id, employee_id, client_op_id, punch_type, occurred_at, source
  ) VALUES (
    v_tenant, v_site, v_employee,
    (format('f7000000-%s-4000-8000-000000000001', v_op_day))::uuid,
    'day_start', (v_day + time '06:45') AT TIME ZONE v_tz, 'mobile'
  );

  v_result := api.recompute_attendance_worker(v_employee, v_day, v_tenant);
  v_consolidated := v_result->'consolidation';
  v_anomalies := ARRAY(SELECT jsonb_array_elements_text(v_result->'anomaly_codes'));

  SELECT paid_minutes INTO v_paid
  FROM data.time_daily_summaries
  WHERE employee_id = v_employee AND work_date = v_day;

  PERFORM g2b_assert(
    'DAY_NOT_CLOSED' = ANY(COALESCE(v_anomalies, '{}')),
    'T10_day_not_closed_anomaly'
  );
  PERFORM g2b_assert(
    COALESCE(v_consolidated->>'skipped', 'false') = 'true'
    AND COALESCE(v_consolidated->>'reason', '') = 'open_or_incomplete_day',
    'T10_consolidate_skipped_open_day'
  );
  PERFORM g2b_assert(COALESCE(v_paid, 0) = 0, 'T10_paid_minutes_zero_while_open');
END;
$$;

-- T11: gap out→day_end (60 min) classificat com TRAVEL — sense UNCLASSIFIED_GAP
DO $$
DECLARE
  v_tenant    uuid := '10000000-0000-0000-0000-000000000001';
  v_employee  uuid := 'f4000000-0000-0000-0000-000000000020';
  v_day       date := '2026-07-25';
  v_tz        text := 'Europe/Madrid';
  v_travel    int;
  v_anomalies text[];
  v_last_travel_min int;
BEGIN
  DELETE FROM data.attendance_record_policies WHERE employee_id = v_employee;

  PERFORM pg_temp.g2b_seed_lampista(v_day);
  PERFORM api.recompute_attendance_worker(v_employee, v_day, v_tenant);

  SELECT travel_minutes, anomaly_codes
  INTO v_travel, v_anomalies
  FROM data.time_daily_summaries
  WHERE employee_id = v_employee AND work_date = v_day;

  SELECT ROUND(EXTRACT(EPOCH FROM (s.ended_at - s.started_at)) / 60)::int
  INTO v_last_travel_min
  FROM data.time_activity_segments s
  WHERE s.employee_id = v_employee
    AND s.work_date = v_day
    AND s.activity_kind = 'TRAVEL'
  ORDER BY s.started_at DESC
  LIMIT 1;

  PERFORM g2b_assert(v_travel = 135, 'T11_travel_minutes_135');
  PERFORM g2b_assert(v_last_travel_min = 60, 'T11_last_travel_segment_60_out_to_day_end');
  PERFORM g2b_assert(
    NOT ('UNCLASSIFIED_GAP' = ANY(COALESCE(v_anomalies, '{}'))),
    'T11_no_unclassified_gap'
  );
END;
$$;

-- T12: smoke fixed_site — branca G2a no regressió amb flag ON
DO $$
DECLARE
  v_tenant    uuid := '10000000-0000-0000-0000-000000000001';
  v_site      uuid := '30000000-0000-0000-0000-000000000001';
  v_employee  uuid := 'f4000000-0000-0000-0000-000000000010';
  v_day       date := '2026-07-26';
  v_tz        text := 'Europe/Madrid';
  v_from      timestamptz;
  v_to        timestamptz;
  v_effective int;
  v_profile   text;
BEGIN
  INSERT INTO data.employees (id, tenant_id, site_id, full_name, status, attendance_work_profile)
  VALUES (v_employee, v_tenant, v_site, 'G2b Fixed Smoke', 'active', 'fixed_site')
  ON CONFLICT (id) DO UPDATE SET attendance_work_profile = EXCLUDED.attendance_work_profile;

  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb)
    || '{"attendance_effective_time_enabled": true}'::jsonb
  WHERE id = v_tenant;

  DELETE FROM data.attendance_record_policies WHERE employee_id = v_employee;

  v_from := v_day AT TIME ZONE v_tz;
  v_to   := (v_day + 1) AT TIME ZONE v_tz;

  INSERT INTO data.labor_calendar_overrides (
    tenant_id, site_id, calendar_date, day_type, day_name, work_intervals
  ) VALUES (
    v_tenant, v_site, v_day, 'work', 'G2b T12 smoke',
    '[{"start":"09:00","end":"17:00"}]'::jsonb
  )
  ON CONFLICT ON CONSTRAINT labor_calendar_overrides_unique DO UPDATE SET
    day_type = EXCLUDED.day_type,
    day_name = EXCLUDED.day_name,
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
    (v_tenant, v_site, v_employee, 'f6000000-0000-0000-0000-000000000026', 'in',  (v_day + time '09:00') AT TIME ZONE v_tz, 'mobile'),
    (v_tenant, v_site, v_employee, 'f6000000-0000-0000-0000-000000000027', 'out', (v_day + time '17:00') AT TIME ZONE v_tz, 'mobile');

  PERFORM api.recompute_attendance_worker(v_employee, v_day, v_tenant);

  SELECT effective_minutes, work_profile_snapshot
  INTO v_effective, v_profile
  FROM data.time_daily_summaries
  WHERE employee_id = v_employee AND work_date = v_day;

  PERFORM g2b_assert(v_effective = 480, 'T12_fixed_site_effective_minutes_480');
  PERFORM g2b_assert(v_profile = 'fixed_site', 'T12_fixed_site_profile_snapshot');
END;
$$;

SELECT msg FROM g2b_test_log ORDER BY id;

ROLLBACK;
