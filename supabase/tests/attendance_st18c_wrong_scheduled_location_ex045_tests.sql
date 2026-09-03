-- =============================================================================
-- attendance_st18c_wrong_scheduled_location_ex045_tests.sql
-- EX-04.5 / ST-18c — ubicació planificada vs estació (warn / block)
-- Executar:
--   psql postgresql://postgres:postgres@127.0.0.1:54322/postgres \
--     -f supabase/tests/attendance_st18c_wrong_scheduled_location_ex045_tests.sql
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0450000-0000-0000-0000-000000000001', 'EX045 Tenant', 'ex045-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES (
  'b0450000-0000-0000-0000-000000000001',
  'a0450000-0000-0000-0000-000000000001',
  'EX045 Site',
  true
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0450000-0000-0000-0000-000000000001', 'emp@ex045.test', 'authenticated', 'authenticated'),
  ('c0450000-0000-0000-0000-000000000002', 'mgr@ex045.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0450000-0000-0000-0000-000000000001', 'emp@ex045.test', 'Emp EX045'),
  ('c0450000-0000-0000-0000-000000000002', 'mgr@ex045.test', 'Mgr EX045')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0450000-0000-0000-0000-000000000001', 'c0450000-0000-0000-0000-000000000001', 'member', true),
  (gen_random_uuid(), 'a0450000-0000-0000-0000-000000000001', 'c0450000-0000-0000-0000-000000000002', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES (
  'd0450000-0000-0000-0000-000000000001',
  'a0450000-0000-0000-0000-000000000001',
  'b0450000-0000-0000-0000-000000000001',
  'c0450000-0000-0000-0000-000000000001',
  'Emp EX045',
  'active'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.locations (id, tenant_id, site_id, name, type, status)
VALUES
  ('e0450000-0000-0000-0000-000000000001', 'a0450000-0000-0000-0000-000000000001',
   'b0450000-0000-0000-0000-000000000001', 'Cuina EX045', 'zone', 'active'),
  ('e0450000-0000-0000-0000-000000000002', 'a0450000-0000-0000-0000-000000000001',
   'b0450000-0000-0000-0000-000000000001', 'Magatzem EX045', 'zone', 'active')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.work_shifts (
  id, tenant_id, site_id, name, color, start_time, end_time, is_active, default_location_id
) VALUES (
  'f0450000-0000-0000-0000-000000000001',
  'a0450000-0000-0000-0000-000000000001',
  'b0450000-0000-0000-0000-000000000001',
  'Torn Cuina EX045', '#3b82f6', '09:00', '17:00', true,
  'e0450000-0000-0000-0000-000000000001'
)
ON CONFLICT DO NOTHING;

-- Estació a Magatzem (diferent de la Cuina planificada)
INSERT INTO data.attendance_devices (
  id, tenant_id, site_id, location_id, name, type, status,
  device_public_id, device_secret_hash, local_pin_hash, allowed_methods,
  warn_wrong_scheduled_location, block_wrong_scheduled_location
) VALUES (
  '10450000-0000-0000-0000-000000000001',
  'a0450000-0000-0000-0000-000000000001',
  'b0450000-0000-0000-0000-000000000001',
  'e0450000-0000-0000-0000-000000000002',
  'Estació Magatzem EX045',
  'station',
  'active',
  'st-ex045-wrong-loc',
  data.hash_attendance_device_secret('station-secret-ex045-32chars!!!!'),
  data.hash_attendance_station_pin('4321'),
  ARRAY['manual']::text[],
  true,
  false
)
ON CONFLICT (id) DO UPDATE
SET location_id = EXCLUDED.location_id,
    status = 'active',
    device_secret_hash = EXCLUDED.device_secret_hash,
    local_pin_hash = EXCLUDED.local_pin_hash,
    warn_wrong_scheduled_location = true,
    block_wrong_scheduled_location = false;

CREATE TEMP TABLE ex045_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.ex045_clear_punches()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  -- Tests: bypass immutability trigger (no DELETE legal en producció)
  ALTER TABLE data.time_punches DISABLE TRIGGER trg_immutable_time_punches;
  DELETE FROM data.time_punches
  WHERE employee_id = 'd0450000-0000-0000-0000-000000000001';
  ALTER TABLE data.time_punches ENABLE TRIGGER trg_immutable_time_punches;
END;
$$;

-- Setup: slot published avui a Cuina + override laboral
DO $$
DECLARE
  v_today date := (now() AT TIME ZONE 'Europe/Madrid')::date;
  v_week_start date;
  v_pub jsonb;
BEGIN
  v_week_start := v_today - ((EXTRACT(ISODOW FROM v_today)::int) - 1);

  PERFORM pg_temp.ex045_clear_punches();

  DELETE FROM data.shift_slots
  WHERE employee_id = 'd0450000-0000-0000-0000-000000000001';

  DELETE FROM data.labor_calendar_overrides
  WHERE employee_id = 'd0450000-0000-0000-0000-000000000001'
    AND calendar_date = v_today;

  INSERT INTO data.labor_calendar_overrides (
    tenant_id, site_id, group_id, employee_id,
    calendar_date, day_type, work_start, work_end, work_intervals
  ) VALUES (
    'a0450000-0000-0000-0000-000000000001',
    NULL, NULL, 'd0450000-0000-0000-0000-000000000001',
    v_today, 'work', '09:00', '17:00',
    '[{"start":"09:00","end":"17:00"}]'::jsonb
  );

  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0450000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0450000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0450000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","attendance.view_all"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  PERFORM api.assign_shift_slot(
    'd0450000-0000-0000-0000-000000000001'::uuid,
    v_today,
    'f0450000-0000-0000-0000-000000000001'::uuid
  );

  v_pub := api.publish_shifts(
    'b0450000-0000-0000-0000-000000000001'::uuid,
    v_week_start,
    ARRAY[]::text[]
  );

  SET LOCAL ROLE postgres;

  IF COALESCE((v_pub->>'published')::int, 0) < 1 THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.shift_slots
      WHERE employee_id = 'd0450000-0000-0000-0000-000000000001'
        AND slot_date = v_today
        AND status = 'published'
        AND location_id = 'e0450000-0000-0000-0000-000000000001'
    ) THEN
      RAISE EXCEPTION 'setup publish failed: %', v_pub;
    END IF;
  END IF;

  INSERT INTO ex045_results VALUES ('SETUP published slot Cuina', 'PASS', v_pub::text);
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex045_results VALUES ('SETUP published slot Cuina', 'FAIL', SQLERRM);
END $$;

-- T1: warn default → punch OK + anomaly WRONG_SCHEDULED_LOCATION
DO $$
DECLARE
  v_result jsonb;
  v_codes text[];
BEGIN
  SET LOCAL ROLE service_role;

  v_result := api.record_station_time_punch(
    '10450000-0000-0000-0000-000000000001'::uuid,
    'd0450000-0000-0000-0000-000000000001'::uuid,
    gen_random_uuid(),
    'in'
  );

  SELECT anomaly_codes INTO v_codes
  FROM data.time_punches
  WHERE id = (v_result->>'punch_id')::uuid;

  RESET ROLE;

  IF v_result->>'status' = 'created'
     AND (v_result->>'wrong_scheduled_location')::boolean IS TRUE
     AND v_result->>'scheduled_location_id' = 'e0450000-0000-0000-0000-000000000001'
     AND 'WRONG_SCHEDULED_LOCATION' = ANY (COALESCE(v_codes, ARRAY[]::text[]))
  THEN
    INSERT INTO ex045_results VALUES ('T1 warn mismatch + anomaly', 'PASS',
      format('sched=%s codes=%s', v_result->>'scheduled_location_name', v_codes));
  ELSE
    INSERT INTO ex045_results VALUES ('T1 warn mismatch + anomaly', 'FAIL',
      format('result=%s codes=%s', v_result, v_codes));
  END IF;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO ex045_results VALUES ('T1 warn mismatch + anomaly', 'FAIL', SQLERRM);
END $$;

-- T2: block → rebutja punch
DO $$
DECLARE
  v_blocked boolean := false;
  v_msg text;
BEGIN
  PERFORM pg_temp.ex045_clear_punches();

  UPDATE data.attendance_devices
  SET block_wrong_scheduled_location = true,
      warn_wrong_scheduled_location = true
  WHERE id = '10450000-0000-0000-0000-000000000001';

  SET LOCAL ROLE service_role;
  BEGIN
    PERFORM api.record_station_time_punch(
      '10450000-0000-0000-0000-000000000001'::uuid,
      'd0450000-0000-0000-0000-000000000001'::uuid,
      gen_random_uuid(),
      'in'
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM ILIKE '%wrong_scheduled_location%';
    v_msg := SQLERRM;
  END;

  RESET ROLE;

  UPDATE data.attendance_devices
  SET block_wrong_scheduled_location = false
  WHERE id = '10450000-0000-0000-0000-000000000001';

  IF v_blocked THEN
    INSERT INTO ex045_results VALUES ('T2 block mismatch', 'PASS', v_msg);
  ELSE
    INSERT INTO ex045_results VALUES ('T2 block mismatch', 'FAIL', COALESCE(v_msg, 'no exception'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO ex045_results VALUES ('T2 block mismatch', 'FAIL', SQLERRM);
END $$;

-- T3: estació = planificada → sense mismatch
DO $$
DECLARE
  v_result jsonb;
  v_codes text[];
BEGIN
  PERFORM pg_temp.ex045_clear_punches();

  UPDATE data.attendance_devices
  SET location_id = 'e0450000-0000-0000-0000-000000000001',
      block_wrong_scheduled_location = false,
      warn_wrong_scheduled_location = true
  WHERE id = '10450000-0000-0000-0000-000000000001';

  SET LOCAL ROLE service_role;
  v_result := api.record_station_time_punch(
    '10450000-0000-0000-0000-000000000001'::uuid,
    'd0450000-0000-0000-0000-000000000001'::uuid,
    gen_random_uuid(),
    'in'
  );

  SELECT anomaly_codes INTO v_codes
  FROM data.time_punches
  WHERE id = (v_result->>'punch_id')::uuid;

  RESET ROLE;

  IF v_result->>'status' = 'created'
     AND COALESCE((v_result->>'wrong_scheduled_location')::boolean, false) IS FALSE
     AND NOT ('WRONG_SCHEDULED_LOCATION' = ANY (COALESCE(v_codes, ARRAY[]::text[])))
  THEN
    INSERT INTO ex045_results VALUES ('T3 match location no anomaly', 'PASS',
      format('loc=%s', v_result->>'location_name'));
  ELSE
    INSERT INTO ex045_results VALUES ('T3 match location no anomaly', 'FAIL',
      format('result=%s codes=%s', v_result, v_codes));
  END IF;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO ex045_results VALUES ('T3 match location no anomaly', 'FAIL', SQLERRM);
END $$;

-- T4: hint sessió detecta mismatch
DO $$
DECLARE
  v_hint jsonb;
BEGIN
  UPDATE data.attendance_devices
  SET location_id = 'e0450000-0000-0000-0000-000000000002'
  WHERE id = '10450000-0000-0000-0000-000000000001';

  SET LOCAL ROLE service_role;
  v_hint := api.station_employee_location_hint(
    '10450000-0000-0000-0000-000000000001'::uuid,
    'd0450000-0000-0000-0000-000000000001'::uuid
  );
  RESET ROLE;

  IF (v_hint->>'wrong_scheduled_location')::boolean IS TRUE
     AND v_hint->>'scheduled_location_id' = 'e0450000-0000-0000-0000-000000000001'
     AND v_hint->>'station_location_id' = 'e0450000-0000-0000-0000-000000000002'
  THEN
    INSERT INTO ex045_results VALUES ('T4 location hint mismatch', 'PASS',
      format('sched=%s station=%s', v_hint->>'scheduled_location_name', v_hint->>'station_location_name'));
  ELSE
    INSERT INTO ex045_results VALUES ('T4 location hint mismatch', 'FAIL', v_hint::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO ex045_results VALUES ('T4 location hint mismatch', 'FAIL', SQLERRM);
END $$;

-- T5: sense planificació → no mismatch
DO $$
DECLARE
  v_today date := (now() AT TIME ZONE 'Europe/Madrid')::date;
  v_result jsonb;
BEGIN
  PERFORM pg_temp.ex045_clear_punches();

  DELETE FROM data.shift_slots
  WHERE employee_id = 'd0450000-0000-0000-0000-000000000001'
    AND slot_date = v_today;

  SET LOCAL ROLE service_role;
  v_result := api.record_station_time_punch(
    '10450000-0000-0000-0000-000000000001'::uuid,
    'd0450000-0000-0000-0000-000000000001'::uuid,
    gen_random_uuid(),
    'in'
  );
  RESET ROLE;

  IF v_result->>'status' = 'created'
     AND COALESCE((v_result->>'wrong_scheduled_location')::boolean, false) IS FALSE
  THEN
    INSERT INTO ex045_results VALUES ('T5 no schedule no mismatch', 'PASS', 'ok');
  ELSE
    INSERT INTO ex045_results VALUES ('T5 no schedule no mismatch', 'FAIL', v_result::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO ex045_results VALUES ('T5 no schedule no mismatch', 'FAIL', SQLERRM);
END $$;

SELECT test_name, status, details FROM ex045_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM ex045_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EX-04.5 tests failed: %', v_fail;
  END IF;
END $$;

ROLLBACK;
