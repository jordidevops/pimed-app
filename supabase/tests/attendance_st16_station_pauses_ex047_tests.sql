-- =============================================================================
-- attendance_st16_station_pauses_ex047_tests.sql
-- EX-04.7 / ST-16 — pauses contextuals a l'estació
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0470000-0000-0000-0000-000000000001', 'EX047 Tenant', 'ex047-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES (
  'b0470000-0000-0000-0000-000000000001',
  'a0470000-0000-0000-0000-000000000001',
  'EX047 Site',
  true
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0470000-0000-0000-0000-000000000001', 'emp@ex047.test', 'authenticated', 'authenticated'),
  ('c0470000-0000-0000-0000-000000000002', 'mgr@ex047.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0470000-0000-0000-0000-000000000001', 'emp@ex047.test', 'Emp EX047'),
  ('c0470000-0000-0000-0000-000000000002', 'mgr@ex047.test', 'Mgr EX047')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0470000-0000-0000-0000-000000000001', 'c0470000-0000-0000-0000-000000000001', 'member', true),
  (gen_random_uuid(), 'a0470000-0000-0000-0000-000000000001', 'c0470000-0000-0000-0000-000000000002', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES (
  'd0470000-0000-0000-0000-000000000001',
  'a0470000-0000-0000-0000-000000000001',
  'b0470000-0000-0000-0000-000000000001',
  'c0470000-0000-0000-0000-000000000001',
  'Emp EX047',
  'active'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.locations (id, tenant_id, site_id, name, type, status)
VALUES (
  'e0470000-0000-0000-0000-000000000001',
  'a0470000-0000-0000-0000-000000000001',
  'b0470000-0000-0000-0000-000000000001',
  'Zona EX047', 'zone', 'active'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_pause_configs (
  id, tenant_id, key, label_i18n, counts_as_work, max_duration_minutes, is_active, sort_order
) VALUES (
  'f0470000-0000-0000-0000-000000000001',
  'a0470000-0000-0000-0000-000000000001',
  'rest',
  '{"ca":"Descans","es":"Descanso"}'::jsonb,
  false,
  30,
  true,
  10
)
ON CONFLICT DO NOTHING;

INSERT INTO data.attendance_devices (
  id, tenant_id, site_id, location_id, name, type, status,
  device_public_id, device_secret_hash, local_pin_hash, allowed_methods
) VALUES (
  '10470000-0000-0000-0000-000000000001',
  'a0470000-0000-0000-0000-000000000001',
  'b0470000-0000-0000-0000-000000000001',
  'e0470000-0000-0000-0000-000000000001',
  'Estació EX047',
  'station',
  'active',
  'st-ex047-pauses',
  data.hash_attendance_device_secret('station-secret-ex047-32chars!!!!'),
  data.hash_attendance_station_pin('4321'),
  ARRAY['manual']::text[]
)
ON CONFLICT (id) DO UPDATE
SET status = 'active',
    location_id = EXCLUDED.location_id,
    device_secret_hash = EXCLUDED.device_secret_hash,
    local_pin_hash = EXCLUDED.local_pin_hash;

CREATE TEMP TABLE ex047_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.ex047_clear_punches()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  ALTER TABLE data.time_punches DISABLE TRIGGER trg_immutable_time_punches;
  DELETE FROM data.time_punches
  WHERE tenant_id = 'a0470000-0000-0000-0000-000000000001'
     OR employee_id = 'd0470000-0000-0000-0000-000000000001';
  ALTER TABLE data.time_punches ENABLE TRIGGER trg_immutable_time_punches;
END;
$$;

-- Clear any leftover punches before scenarios
SELECT pg_temp.ex047_clear_punches();

-- T0: helper contextual
DO $$
BEGIN
  IF data.station_allows_punch_type('work', 'break_start')
     AND data.station_allows_punch_type('break', 'break_end')
     AND data.station_allows_punch_type('work', 'out')
     AND NOT data.station_allows_punch_type('break', 'out')
     AND data.station_kiosk_next_punch('break') = 'break_end'
  THEN
    INSERT INTO ex047_results VALUES ('T0 allows helper', 'PASS', 'ok');
  ELSE
    INSERT INTO ex047_results VALUES ('T0 allows helper', 'FAIL', 'helper mismatch');
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex047_results VALUES ('T0 allows helper', 'FAIL', SQLERRM);
END $$;

-- T1: list pause configs
DO $$
DECLARE
  v_payload jsonb;
BEGIN
  SET LOCAL ROLE service_role;
  v_payload := api.list_attendance_station_pause_configs(
    '10470000-0000-0000-0000-000000000001'::uuid
  );
  RESET ROLE;

  IF jsonb_array_length(COALESCE(v_payload->'configs', '[]'::jsonb)) >= 1
     AND EXISTS (
       SELECT 1 FROM jsonb_array_elements(v_payload->'configs') c
       WHERE c->>'key' = 'rest'
     )
  THEN
    INSERT INTO ex047_results VALUES ('T1 list pause configs', 'PASS', v_payload::text);
  ELSE
    INSERT INTO ex047_results VALUES ('T1 list pause configs', 'FAIL', v_payload::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO ex047_results VALUES ('T1 list pause configs', 'FAIL', SQLERRM);
END $$;

-- T2: in → break_start → break_end → out
DO $$
DECLARE
  v_in jsonb;
  v_bs jsonb;
  v_be jsonb;
  v_out jsonb;
  v_state text;
  v_device uuid := '10470000-0000-0000-0000-000000000001';
  v_emp uuid := 'd0470000-0000-0000-0000-000000000001';
BEGIN
  PERFORM pg_temp.ex047_clear_punches();
  SET LOCAL ROLE service_role;

  v_in := api.record_station_time_punch(
    p_device_id => v_device,
    p_employee_id => v_emp,
    p_client_op_id => gen_random_uuid(),
    p_punch_type => 'in'
  );

  v_state := data.compute_employee_punch_day_state(v_emp);
  IF v_state IS DISTINCT FROM 'work' THEN
    RAISE EXCEPTION 'after in expected work, got % (in=%)', v_state, v_in;
  END IF;

  v_bs := api.record_station_time_punch(
    p_device_id => v_device,
    p_employee_id => v_emp,
    p_client_op_id => gen_random_uuid(),
    p_punch_type => 'break_start',
    p_pause_type => 'rest'
  );

  v_state := data.compute_employee_punch_day_state(v_emp);
  IF v_state IS DISTINCT FROM 'break' THEN
    RAISE EXCEPTION 'after break_start expected break, got % (bs=%)', v_state, v_bs;
  END IF;

  v_be := api.record_station_time_punch(
    p_device_id => v_device,
    p_employee_id => v_emp,
    p_client_op_id => gen_random_uuid(),
    p_punch_type => 'break_end',
    p_pause_type => 'rest'
  );

  v_out := api.record_station_time_punch(
    p_device_id => v_device,
    p_employee_id => v_emp,
    p_client_op_id => gen_random_uuid(),
    p_punch_type => 'out'
  );

  RESET ROLE;

  IF v_in->>'status' = 'created'
     AND v_bs->>'status' = 'created'
     AND v_be->>'status' = 'created'
     AND v_out->>'status' = 'created'
  THEN
    INSERT INTO ex047_results VALUES ('T2 in-break-out cycle', 'PASS', 'ok');
  ELSE
    INSERT INTO ex047_results VALUES ('T2 in-break-out cycle', 'FAIL',
      format('in=%s bs=%s be=%s out=%s', v_in, v_bs, v_be, v_out));
  END IF;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO ex047_results VALUES ('T2 in-break-out cycle', 'FAIL', SQLERRM);
END $$;

-- T3: break_start sense estar working → reject
DO $$
DECLARE
  v_blocked boolean := false;
  v_msg text;
BEGIN
  PERFORM pg_temp.ex047_clear_punches();
  SET LOCAL ROLE service_role;
  BEGIN
    PERFORM api.record_station_time_punch(
      '10470000-0000-0000-0000-000000000001'::uuid,
      'd0470000-0000-0000-0000-000000000001'::uuid,
      gen_random_uuid(),
      'break_start',
      'rest'
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM ILIKE '%station_wrong_punch_type%'
              OR SQLERRM ILIKE '%station_punch_blocked%';
    v_msg := SQLERRM;
  END;
  RESET ROLE;

  IF v_blocked THEN
    INSERT INTO ex047_results VALUES ('T3 break without in blocked', 'PASS', v_msg);
  ELSE
    INSERT INTO ex047_results VALUES ('T3 break without in blocked', 'FAIL', COALESCE(v_msg, 'no exception'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO ex047_results VALUES ('T3 break without in blocked', 'FAIL', SQLERRM);
END $$;

-- T4: out mentre en pausa → reject
DO $$
DECLARE
  v_blocked boolean := false;
  v_msg text;
BEGIN
  PERFORM pg_temp.ex047_clear_punches();
  SET LOCAL ROLE service_role;

  PERFORM api.record_station_time_punch(
    '10470000-0000-0000-0000-000000000001'::uuid,
    'd0470000-0000-0000-0000-000000000001'::uuid,
    gen_random_uuid(),
    'in'
  );
  PERFORM api.record_station_time_punch(
    '10470000-0000-0000-0000-000000000001'::uuid,
    'd0470000-0000-0000-0000-000000000001'::uuid,
    gen_random_uuid(),
    'break_start',
    'rest'
  );

  BEGIN
    PERFORM api.record_station_time_punch(
      '10470000-0000-0000-0000-000000000001'::uuid,
      'd0470000-0000-0000-0000-000000000001'::uuid,
      gen_random_uuid(),
      'out'
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM ILIKE '%station_wrong_punch_type%';
    v_msg := SQLERRM;
  END;
  RESET ROLE;

  IF v_blocked THEN
    INSERT INTO ex047_results VALUES ('T4 out during break blocked', 'PASS', v_msg);
  ELSE
    INSERT INTO ex047_results VALUES ('T4 out during break blocked', 'FAIL', COALESCE(v_msg, 'no exception'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO ex047_results VALUES ('T4 out during break blocked', 'FAIL', SQLERRM);
END $$;

-- T5: list employees exposa can_start/end pause
DO $$
DECLARE
  v_payload jsonb;
  v_emp jsonb;
BEGIN
  PERFORM pg_temp.ex047_clear_punches();
  SET LOCAL ROLE service_role;

  PERFORM api.record_station_time_punch(
    '10470000-0000-0000-0000-000000000001'::uuid,
    'd0470000-0000-0000-0000-000000000001'::uuid,
    gen_random_uuid(),
    'in'
  );

  v_payload := api.list_attendance_station_employees(
    '10470000-0000-0000-0000-000000000001'::uuid
  );

  SELECT elem INTO v_emp
  FROM jsonb_array_elements(COALESCE(v_payload->'employees', '[]'::jsonb)) elem
  WHERE elem->>'employee_id' = 'd0470000-0000-0000-0000-000000000001'
  LIMIT 1;

  RESET ROLE;

  IF (v_emp->>'day_state') = 'work'
     AND (v_emp->>'can_start_pause')::boolean IS TRUE
     AND (v_emp->>'next_punch') = 'out'
  THEN
    INSERT INTO ex047_results VALUES ('T5 list can_start_pause', 'PASS', v_emp::text);
  ELSE
    INSERT INTO ex047_results VALUES ('T5 list can_start_pause', 'FAIL', COALESCE(v_emp::text, v_payload::text));
  END IF;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO ex047_results VALUES ('T5 list can_start_pause', 'FAIL', SQLERRM);
END $$;

SELECT test_name, status, details FROM ex047_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM ex047_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EX-04.7 tests failed: %', v_fail;
  END IF;
END $$;

ROLLBACK;
