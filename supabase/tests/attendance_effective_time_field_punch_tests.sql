-- Track G Phase 2c — field_punch + gaps D-INT-7 tests
BEGIN;

CREATE TEMP TABLE g2c_test_log (id serial, msg text);

CREATE OR REPLACE FUNCTION g2c_assert(p_ok boolean, p_msg text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok THEN
    INSERT INTO g2c_test_log (msg) VALUES ('[PASS] ' || p_msg);
  ELSE
    RAISE EXCEPTION '[FAIL] %', p_msg;
  END IF;
END;
$$;

INSERT INTO data.employees (
  id, tenant_id, site_id, user_id, full_name, status, attendance_work_profile
) VALUES (
  '40000000-0000-0000-0000-000000000002',
  '10000000-0000-0000-0000-000000000001',
  '30000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000004',
  'Charlie (Acme)',
  'active',
  'mobile_peripatetic'
)
ON CONFLICT (id) DO UPDATE SET attendance_work_profile = EXCLUDED.attendance_work_profile;

-- T-A: lampista field_punch (Conveni C) — mateix buckets que G2b T1
DO $$
DECLARE
  v_tenant   uuid := '10000000-0000-0000-0000-000000000001';
  v_site     uuid := '30000000-0000-0000-0000-000000000001';
  v_employee uuid := '40000000-0000-0000-0000-000000000002';
  v_worker   uuid := '20000000-0000-0000-0000-000000000004';
  v_project  uuid := '51000000-0000-0000-0000-000000000001';
  v_day      date := '2026-08-01';
  v_tz       text := 'Europe/Madrid';
  v_from     timestamptz;
  v_to       timestamptz;
  v_worked   int;
  v_presence int;
  v_work     int;
  v_travel   int;
  v_paid     int;
  v_effective int;
BEGIN
  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb)
    || '{"attendance_effective_time_enabled": true}'::jsonb
  WHERE id = v_tenant;

  DELETE FROM data.attendance_record_policies WHERE employee_id = v_employee;

  v_from := v_day AT TIME ZONE v_tz;
  v_to   := (v_day + 1) AT TIME ZONE v_tz;

  DELETE FROM data.work_log_field_gaps WHERE employee_id = v_employee;
  DELETE FROM data.time_activity_segments WHERE employee_id = v_employee AND work_date = v_day;
  DELETE FROM data.work_logs WHERE employee_id = v_employee;
  DELETE FROM data.time_punches
  WHERE employee_id = v_employee AND occurred_at >= v_from AND occurred_at < v_to;
  DELETE FROM data.time_daily_summaries WHERE employee_id = v_employee AND work_date = v_day;
  DELETE FROM data.time_entries WHERE employee_id = v_employee AND work_date = v_day;

  INSERT INTO data.time_punches (
    tenant_id, site_id, employee_id, client_op_id, punch_type, occurred_at, source
  ) VALUES
    (v_tenant, v_site, v_employee, 'f8000000-0801-4000-8000-000000000001', 'day_start',   (v_day + time '06:45') AT TIME ZONE v_tz, 'mobile'),
    (v_tenant, v_site, v_employee, 'f8000000-0801-4000-8000-000000000002', 'break_start', (v_day + time '12:00') AT TIME ZONE v_tz, 'mobile'),
    (v_tenant, v_site, v_employee, 'f8000000-0801-4000-8000-000000000003', 'break_end',   (v_day + time '12:30') AT TIME ZONE v_tz, 'mobile'),
    (v_tenant, v_site, v_employee, 'f8000000-0801-4000-8000-000000000004', 'day_end',     (v_day + time '17:30') AT TIME ZONE v_tz, 'mobile');

  INSERT INTO data.work_logs (
    id, tenant_id, site_id, project_id, worker_id, employee_id, client_op_id,
    entry_mode, status, check_in, check_out, location_permission
  ) VALUES (
    'f8000000-0000-0000-0000-000000000001',
    v_tenant, v_site, v_project, v_worker, v_employee,
    'f8000000-0801-4000-8000-000000000010',
    'field_punch', 'closed',
    (v_day + time '08:00') AT TIME ZONE v_tz,
    (v_day + time '16:30') AT TIME ZONE v_tz,
    'notrequired'
  );

  PERFORM api.recompute_attendance_worker(v_employee, v_day, v_tenant);

  SELECT worked_minutes, presence_minutes, work_minutes, travel_minutes,
         effective_minutes, paid_minutes
  INTO v_worked, v_presence, v_work, v_travel, v_effective, v_paid
  FROM data.time_daily_summaries
  WHERE employee_id = v_employee AND work_date = v_day;

  PERFORM g2c_assert(v_presence = 645, 'TA_presence_minutes_645');
  PERFORM g2c_assert(v_worked = 480, 'TA_worked_minutes_480');
  PERFORM g2c_assert(v_work = 480, 'TA_work_minutes_480');
  PERFORM g2c_assert(v_travel = 135, 'TA_travel_minutes_135');
  PERFORM g2c_assert(v_paid = 615, 'TA_paid_minutes_615');
  PERFORM g2c_assert(v_effective = 480, 'TA_effective_minutes_480');
  PERFORM g2c_assert(
    EXISTS (
      SELECT 1 FROM data.time_activity_segments
      WHERE employee_id = v_employee AND work_date = v_day
        AND activity_kind = 'WORK' AND work_log_id IS NOT NULL
    ),
    'TA_work_segment_has_work_log_id'
  );
END;
$$;

-- T-B: multi-obra amb gaps declarats TRAVEL — needs_review false
DO $$
DECLARE
  v_tenant   uuid := '10000000-0000-0000-0000-000000000001';
  v_site     uuid := '30000000-0000-0000-0000-000000000001';
  v_employee uuid := '40000000-0000-0000-0000-000000000002';
  v_worker   uuid := '20000000-0000-0000-0000-000000000004';
  v_proj_a   uuid := '51000000-0000-0000-0000-000000000001';
  v_proj_b   uuid := '51000000-0000-0000-0000-000000000002';
  v_day      date := '2026-08-02';
  v_tz       text := 'Europe/Madrid';
  v_from     timestamptz;
  v_to       timestamptz;
  v_wl_a     uuid := 'f8000000-0000-0000-0000-000000000002';
  v_wl_b     uuid := 'f8000000-0000-0000-0000-000000000003';
  v_review   boolean;
  v_anomalies text[];
BEGIN
  v_from := v_day AT TIME ZONE v_tz;
  v_to   := (v_day + 1) AT TIME ZONE v_tz;

  DELETE FROM data.work_log_field_gaps WHERE employee_id = v_employee;
  DELETE FROM data.time_activity_segments WHERE employee_id = v_employee AND work_date = v_day;
  DELETE FROM data.work_logs WHERE employee_id = v_employee;
  DELETE FROM data.time_punches
  WHERE employee_id = v_employee AND occurred_at >= v_from AND occurred_at < v_to;
  DELETE FROM data.time_daily_summaries WHERE employee_id = v_employee AND work_date = v_day;
  DELETE FROM data.time_entries WHERE employee_id = v_employee AND work_date = v_day;

  INSERT INTO data.time_punches (
    tenant_id, site_id, employee_id, client_op_id, punch_type, occurred_at, source
  ) VALUES
    (v_tenant, v_site, v_employee, 'f8000000-0802-4000-8000-000000000001', 'day_start', (v_day + time '07:30') AT TIME ZONE v_tz, 'mobile'),
    (v_tenant, v_site, v_employee, 'f8000000-0802-4000-8000-000000000002', 'day_end',   (v_day + time '17:00') AT TIME ZONE v_tz, 'mobile');

  INSERT INTO data.work_logs (
    id, tenant_id, site_id, project_id, worker_id, employee_id, client_op_id,
    entry_mode, status, check_in, check_out, location_permission
  ) VALUES
    (v_wl_a, v_tenant, v_site, v_proj_a, v_worker, v_employee, 'f8000000-0802-4000-8000-000000000010',
     'field_punch', 'closed', (v_day + time '08:00') AT TIME ZONE v_tz, (v_day + time '11:30') AT TIME ZONE v_tz, 'notrequired'),
    (v_wl_b, v_tenant, v_site, v_proj_b, v_worker, v_employee, 'f8000000-0802-4000-8000-000000000011',
     'field_punch', 'closed', (v_day + time '12:00') AT TIME ZONE v_tz, (v_day + time '16:30') AT TIME ZONE v_tz, 'notrequired');

  INSERT INTO data.work_log_field_gaps (
    tenant_id, employee_id, work_date, started_at, ended_at, gap_kind,
    prev_work_log_id, next_work_log_id
  ) VALUES (
    v_tenant, v_employee, v_day,
    (v_day + time '11:30') AT TIME ZONE v_tz,
    (v_day + time '12:00') AT TIME ZONE v_tz,
    'TRAVEL', v_wl_a, v_wl_b
  );

  PERFORM api.recompute_attendance_worker(v_employee, v_day, v_tenant);

  SELECT needs_review, anomaly_codes
  INTO v_review, v_anomalies
  FROM data.time_daily_summaries
  WHERE employee_id = v_employee AND work_date = v_day;

  PERFORM g2c_assert(v_review = false, 'TB_needs_review_false');
  PERFORM g2c_assert(
    NOT ('UNCLASSIFIED_GAP' = ANY(COALESCE(v_anomalies, '{}'))),
    'TB_no_unclassified_gap'
  );
  PERFORM g2c_assert(
    (SELECT COUNT(*) FROM data.time_activity_segments
     WHERE employee_id = v_employee AND work_date = v_day AND activity_kind = 'WORK') = 2,
    'TB_two_work_segments'
  );
END;
$$;

-- T-D: gap UNCLASSIFIED > 30 min → needs_review + UNCLASSIFIED_GAP
DO $$
DECLARE
  v_tenant   uuid := '10000000-0000-0000-0000-000000000001';
  v_site     uuid := '30000000-0000-0000-0000-000000000001';
  v_employee uuid := '40000000-0000-0000-0000-000000000002';
  v_worker   uuid := '20000000-0000-0000-0000-000000000004';
  v_project  uuid := '51000000-0000-0000-0000-000000000001';
  v_day      date := '2026-08-03';
  v_tz       text := 'Europe/Madrid';
  v_from     timestamptz;
  v_to       timestamptz;
  v_wl_a     uuid := 'f8000000-0000-0000-0000-000000000004';
  v_wl_b     uuid := 'f8000000-0000-0000-0000-000000000005';
  v_review   boolean;
  v_anomalies text[];
  v_meta     jsonb;
BEGIN
  v_from := v_day AT TIME ZONE v_tz;
  v_to   := (v_day + 1) AT TIME ZONE v_tz;

  DELETE FROM data.work_log_field_gaps WHERE employee_id = v_employee;
  DELETE FROM data.time_activity_segments WHERE employee_id = v_employee AND work_date = v_day;
  DELETE FROM data.work_logs WHERE employee_id = v_employee;
  DELETE FROM data.time_punches
  WHERE employee_id = v_employee AND occurred_at >= v_from AND occurred_at < v_to;
  DELETE FROM data.time_daily_summaries WHERE employee_id = v_employee AND work_date = v_day;
  DELETE FROM data.time_entries WHERE employee_id = v_employee AND work_date = v_day;

  INSERT INTO data.time_punches (
    tenant_id, site_id, employee_id, client_op_id, punch_type, occurred_at, source
  ) VALUES
    (v_tenant, v_site, v_employee, 'f8000000-0803-4000-8000-000000000001', 'day_start', (v_day + time '08:00') AT TIME ZONE v_tz, 'mobile'),
    (v_tenant, v_site, v_employee, 'f8000000-0803-4000-8000-000000000002', 'day_end',   (v_day + time '18:00') AT TIME ZONE v_tz, 'mobile');

  INSERT INTO data.work_logs (
    id, tenant_id, site_id, project_id, worker_id, employee_id, client_op_id,
    entry_mode, status, check_in, check_out, location_permission
  ) VALUES
    (v_wl_a, v_tenant, v_site, v_project, v_worker, v_employee, 'f8000000-0803-4000-8000-000000000010',
     'field_punch', 'closed', (v_day + time '09:00') AT TIME ZONE v_tz, (v_day + time '11:00') AT TIME ZONE v_tz, 'notrequired'),
    (v_wl_b, v_tenant, v_site, v_project, v_worker, v_employee, 'f8000000-0803-4000-8000-000000000011',
     'field_punch', 'closed', (v_day + time '11:45') AT TIME ZONE v_tz, (v_day + time '17:00') AT TIME ZONE v_tz, 'notrequired');

  INSERT INTO data.work_log_field_gaps (
    tenant_id, employee_id, work_date, started_at, ended_at, gap_kind,
    prev_work_log_id, next_work_log_id
  ) VALUES (
    v_tenant, v_employee, v_day,
    (v_day + time '11:00') AT TIME ZONE v_tz,
    (v_day + time '11:45') AT TIME ZONE v_tz,
    'UNCLASSIFIED', v_wl_a, v_wl_b
  );

  PERFORM api.recompute_attendance_worker(v_employee, v_day, v_tenant);

  SELECT needs_review, anomaly_codes, consolidation_meta
  INTO v_review, v_anomalies, v_meta
  FROM data.time_daily_summaries
  WHERE employee_id = v_employee AND work_date = v_day;

  PERFORM g2c_assert(v_review = true, 'TD_needs_review_true');
  PERFORM g2c_assert(
    'UNCLASSIFIED_GAP' = ANY(COALESCE(v_anomalies, '{}')),
    'TD_unclassified_gap_anomaly'
  );
  PERFORM g2c_assert(
    jsonb_array_length(COALESCE(v_meta->'unclassified_gaps', '[]'::jsonb)) = 1,
    'TD_unclassified_gaps_meta'
  );
END;
$$;

SELECT msg FROM g2c_test_log ORDER BY id;

ROLLBACK;
