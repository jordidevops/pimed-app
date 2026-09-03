-- Track G Phase 1b — activity segments + punch sequence tests
BEGIN;

CREATE TEMP TABLE g1b_test_log (id serial, msg text);

CREATE OR REPLACE FUNCTION g1b_assert(p_ok boolean, p_msg text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok THEN
    INSERT INTO g1b_test_log (msg) VALUES ('[PASS] ' || p_msg);
  ELSE
    RAISE EXCEPTION '[FAIL] %', p_msg;
  END IF;
END;
$$;

INSERT INTO data.employees (id, tenant_id, site_id, full_name, status, attendance_work_profile)
VALUES
  ('f4000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'G1b Fixed', 'active', 'fixed_site'),
  ('f4000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'G1b Mobile', 'active', 'mobile_peripatetic')
ON CONFLICT (id) DO UPDATE SET attendance_work_profile = EXCLUDED.attendance_work_profile;

DO $$
DECLARE
  v_tenant   uuid := '10000000-0000-0000-0000-000000000001';
  v_site     uuid := '30000000-0000-0000-0000-000000000001';
  v_fixed    uuid := 'f4000000-0000-0000-0000-000000000010';
  v_mobile   uuid := 'f4000000-0000-0000-0000-000000000011';
  v_day      date;
  v_cnt      int;
  v_kinds    text[];
BEGIN
  -- T1: fixed_site rejects day_start
  BEGIN
    PERFORM data.validate_time_punch_sequence(v_fixed, '2026-07-11', 'day_start', 'fixed_site', '{}'::jsonb);
    RAISE EXCEPTION 'expected rejection';
  EXCEPTION WHEN check_violation THEN
    PERFORM g1b_assert(true, 'T1_fixed_rejects_day_start');
  END;

  -- T2: fixed_site in/out → WORK segment
  v_day := '2026-07-12';
  INSERT INTO data.time_punches (
    tenant_id, site_id, employee_id, client_op_id, punch_type, occurred_at, source
  ) VALUES
    (v_tenant, v_site, v_fixed, 'f5000000-0000-0000-0000-000000000001', 'in',  (v_day + time '09:00') AT TIME ZONE 'Europe/Madrid', 'mobile'),
    (v_tenant, v_site, v_fixed, 'f5000000-0000-0000-0000-000000000002', 'out', (v_day + time '17:00') AT TIME ZONE 'Europe/Madrid', 'mobile')
  ON CONFLICT DO NOTHING;

  v_cnt := data.classify_activity_segments(v_fixed, v_day, v_tenant);
  SELECT array_agg(activity_kind ORDER BY started_at) INTO v_kinds
  FROM data.time_activity_segments
  WHERE employee_id = v_fixed AND work_date = v_day;

  PERFORM g1b_assert(v_cnt >= 1, 'T2_fixed_classify_count');
  PERFORM g1b_assert(v_kinds @> ARRAY['WORK']::text[], 'T2_fixed_has_work');

  -- T3: mobile day_start → in → out → day_end
  v_day := '2026-07-13';
  PERFORM data.validate_time_punch_sequence(v_mobile, v_day, 'day_start', 'mobile_peripatetic', '{}'::jsonb);

  INSERT INTO data.time_punches (
    tenant_id, site_id, employee_id, client_op_id, punch_type, occurred_at, source
  ) VALUES
    (v_tenant, v_site, v_mobile, 'f5000000-0000-0000-0000-000000000011', 'day_start', (v_day + time '07:30') AT TIME ZONE 'Europe/Madrid', 'mobile'),
    (v_tenant, v_site, v_mobile, 'f5000000-0000-0000-0000-000000000012', 'in',        (v_day + time '08:00') AT TIME ZONE 'Europe/Madrid', 'mobile'),
    (v_tenant, v_site, v_mobile, 'f5000000-0000-0000-0000-000000000013', 'out',       (v_day + time '17:00') AT TIME ZONE 'Europe/Madrid', 'mobile'),
    (v_tenant, v_site, v_mobile, 'f5000000-0000-0000-0000-000000000014', 'day_end',   (v_day + time '17:30') AT TIME ZONE 'Europe/Madrid', 'mobile')
  ON CONFLICT DO NOTHING;

  v_cnt := data.classify_activity_segments(v_mobile, v_day, v_tenant);
  SELECT array_agg(DISTINCT activity_kind ORDER BY activity_kind) INTO v_kinds
  FROM data.time_activity_segments
  WHERE employee_id = v_mobile AND work_date = v_day;

  PERFORM g1b_assert(v_cnt >= 3, 'T3_mobile_segment_count');
  PERFORM g1b_assert(v_kinds @> ARRAY['WORK', 'TRAVEL']::text[], 'T3_mobile_travel_and_work');

  -- T4: recompute persists segments
  v_day := '2026-07-14';
  INSERT INTO data.time_punches (
    tenant_id, site_id, employee_id, client_op_id, punch_type, occurred_at, source
  ) VALUES
    (v_tenant, v_site, v_mobile, 'f5000000-0000-0000-0000-000000000021', 'in',  (v_day + time '09:00') AT TIME ZONE 'Europe/Madrid', 'mobile'),
    (v_tenant, v_site, v_mobile, 'f5000000-0000-0000-0000-000000000022', 'out', (v_day + time '17:00') AT TIME ZONE 'Europe/Madrid', 'mobile')
  ON CONFLICT DO NOTHING;

  PERFORM api.recompute_attendance_worker(v_mobile, v_day, v_tenant);
  SELECT count(*) INTO v_cnt FROM data.time_activity_segments WHERE employee_id = v_mobile AND work_date = v_day;
  PERFORM g1b_assert(v_cnt >= 1, 'T4_recompute_persists_segments');
END;
$$;

SELECT msg FROM g1b_test_log ORDER BY id;

ROLLBACK;
