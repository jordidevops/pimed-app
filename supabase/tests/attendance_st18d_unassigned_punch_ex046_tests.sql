-- =============================================================================
-- attendance_st18d_unassigned_punch_ex046_tests.sql
-- EX-04.6 / ST-18d — punch sense assignació (allow / warn + OUTSIDE_ASSIGNMENT)
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0460000-0000-0000-0000-000000000001', 'EX046 Tenant', 'ex046-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES (
  'b0460000-0000-0000-0000-000000000001',
  'a0460000-0000-0000-0000-000000000001',
  'EX046 Site',
  true
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0460000-0000-0000-0000-000000000001', 'emp@ex046.test', 'authenticated', 'authenticated'),
  ('c0460000-0000-0000-0000-000000000002', 'mgr@ex046.test', 'authenticated', 'authenticated'),
  ('c0460000-0000-0000-0000-000000000003', 'una@ex046.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0460000-0000-0000-0000-000000000001', 'emp@ex046.test', 'Emp EX046'),
  ('c0460000-0000-0000-0000-000000000002', 'mgr@ex046.test', 'Mgr EX046'),
  ('c0460000-0000-0000-0000-000000000003', 'una@ex046.test', 'Una EX046')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0460000-0000-0000-0000-000000000001', 'c0460000-0000-0000-0000-000000000001', 'member', true),
  (gen_random_uuid(), 'a0460000-0000-0000-0000-000000000001', 'c0460000-0000-0000-0000-000000000002', 'manager', true),
  (gen_random_uuid(), 'a0460000-0000-0000-0000-000000000001', 'c0460000-0000-0000-0000-000000000003', 'member', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES
  (
    'd0460000-0000-0000-0000-000000000001',
    'a0460000-0000-0000-0000-000000000001',
    'b0460000-0000-0000-0000-000000000001',
    'c0460000-0000-0000-0000-000000000001',
    'Emp Assignat EX046', 'active'
  ),
  (
    'd0460000-0000-0000-0000-000000000002',
    'a0460000-0000-0000-0000-000000000001',
    'b0460000-0000-0000-0000-000000000001',
    'c0460000-0000-0000-0000-000000000003',
    'Emp Sense Assign EX046', 'active'
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.locations (id, tenant_id, site_id, name, type, status)
VALUES (
  'e0460000-0000-0000-0000-000000000001',
  'a0460000-0000-0000-0000-000000000001',
  'b0460000-0000-0000-0000-000000000001',
  'Zona EX046', 'zone', 'active'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.attendance_devices (
  id, tenant_id, site_id, location_id, name, type, status,
  device_public_id, device_secret_hash, local_pin_hash, allowed_methods,
  allow_unassigned_punch, warn_unassigned_punch
) VALUES (
  '10460000-0000-0000-0000-000000000001',
  'a0460000-0000-0000-0000-000000000001',
  'b0460000-0000-0000-0000-000000000001',
  'e0460000-0000-0000-0000-000000000001',
  'Estació EX046',
  'station',
  'active',
  'st-ex046-unassigned',
  data.hash_attendance_device_secret('station-secret-ex046-32chars!!!!'),
  data.hash_attendance_station_pin('4321'),
  ARRAY['manual']::text[],
  true,
  true
)
ON CONFLICT (id) DO UPDATE
SET location_id = EXCLUDED.location_id,
    status = 'active',
    allow_unassigned_punch = true,
    warn_unassigned_punch = true,
    device_secret_hash = EXCLUDED.device_secret_hash,
    local_pin_hash = EXCLUDED.local_pin_hash;

CREATE TEMP TABLE ex046_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.ex046_clear_punches()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  ALTER TABLE data.time_punches DISABLE TRIGGER trg_immutable_time_punches;
  DELETE FROM data.time_punches
  WHERE employee_id IN (
    'd0460000-0000-0000-0000-000000000001',
    'd0460000-0000-0000-0000-000000000002'
  );
  ALTER TABLE data.time_punches ENABLE TRIGGER trg_immutable_time_punches;
END;
$$;

-- Setup: assignació només per Emp Assignat
DO $$
DECLARE
  v_today date := (now() AT TIME ZONE 'Europe/Madrid')::date;
BEGIN
  PERFORM pg_temp.ex046_clear_punches();

  DELETE FROM data.attendance_location_assignments
  WHERE location_id = 'e0460000-0000-0000-0000-000000000001';

  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0460000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0460000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0460000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","attendance.view_all","attendance.manage"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  PERFORM api.add_attendance_location_assignment(
    'e0460000-0000-0000-0000-000000000001'::uuid,
    'd0460000-0000-0000-0000-000000000001'::uuid
  );

  SET LOCAL ROLE postgres;

  IF NOT data.location_scope_has_attendance_assignments(
       'e0460000-0000-0000-0000-000000000001'::uuid, v_today
     ) THEN
    RAISE EXCEPTION 'setup: expected scope with assignments';
  END IF;

  IF data.employee_can_punch_at_location(
       'd0460000-0000-0000-0000-000000000002'::uuid,
       'e0460000-0000-0000-0000-000000000001'::uuid,
       v_today
     ) THEN
    RAISE EXCEPTION 'setup: unassigned should not be eligible';
  END IF;

  INSERT INTO ex046_results VALUES ('SETUP assignment scope', 'PASS', 'ok');
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex046_results VALUES ('SETUP assignment scope', 'FAIL', SQLERRM);
END $$;

-- T1: allow=true → punch OK + OUTSIDE_ASSIGNMENT
DO $$
DECLARE
  v_result jsonb;
  v_codes text[];
BEGIN
  PERFORM pg_temp.ex046_clear_punches();

  UPDATE data.attendance_devices
  SET allow_unassigned_punch = true,
      warn_unassigned_punch = true
  WHERE id = '10460000-0000-0000-0000-000000000001';

  SET LOCAL ROLE service_role;
  v_result := api.record_station_time_punch(
    '10460000-0000-0000-0000-000000000001'::uuid,
    'd0460000-0000-0000-0000-000000000002'::uuid,
    gen_random_uuid(),
    'in'
  );

  SELECT anomaly_codes INTO v_codes
  FROM data.time_punches
  WHERE id = (v_result->>'punch_id')::uuid;

  RESET ROLE;

  IF v_result->>'status' = 'created'
     AND (v_result->>'outside_assignment')::boolean IS TRUE
     AND (v_result->>'punched_outside_assignment')::boolean IS TRUE
     AND 'OUTSIDE_ASSIGNMENT' = ANY (COALESCE(v_codes, ARRAY[]::text[]))
  THEN
    INSERT INTO ex046_results VALUES ('T1 allow warn + anomaly', 'PASS',
      format('codes=%s', v_codes));
  ELSE
    INSERT INTO ex046_results VALUES ('T1 allow warn + anomaly', 'FAIL',
      format('result=%s codes=%s', v_result, v_codes));
  END IF;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO ex046_results VALUES ('T1 allow warn + anomaly', 'FAIL', SQLERRM);
END $$;

-- T2: allow=false → block
DO $$
DECLARE
  v_blocked boolean := false;
  v_msg text;
BEGIN
  PERFORM pg_temp.ex046_clear_punches();

  UPDATE data.attendance_devices
  SET allow_unassigned_punch = false
  WHERE id = '10460000-0000-0000-0000-000000000001';

  SET LOCAL ROLE service_role;
  BEGIN
    PERFORM api.record_station_time_punch(
      '10460000-0000-0000-0000-000000000001'::uuid,
      'd0460000-0000-0000-0000-000000000002'::uuid,
      gen_random_uuid(),
      'in'
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM ILIKE '%employee_not_allowed_at_location%';
    v_msg := SQLERRM;
  END;
  RESET ROLE;

  UPDATE data.attendance_devices
  SET allow_unassigned_punch = true
  WHERE id = '10460000-0000-0000-0000-000000000001';

  IF v_blocked THEN
    INSERT INTO ex046_results VALUES ('T2 block unassigned', 'PASS', v_msg);
  ELSE
    INSERT INTO ex046_results VALUES ('T2 block unassigned', 'FAIL', COALESCE(v_msg, 'no exception'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO ex046_results VALUES ('T2 block unassigned', 'FAIL', SQLERRM);
END $$;

-- T3: assignat → sense OUTSIDE_ASSIGNMENT
DO $$
DECLARE
  v_result jsonb;
  v_codes text[];
BEGIN
  PERFORM pg_temp.ex046_clear_punches();

  SET LOCAL ROLE service_role;
  v_result := api.record_station_time_punch(
    '10460000-0000-0000-0000-000000000001'::uuid,
    'd0460000-0000-0000-0000-000000000001'::uuid,
    gen_random_uuid(),
    'in'
  );

  SELECT anomaly_codes INTO v_codes
  FROM data.time_punches
  WHERE id = (v_result->>'punch_id')::uuid;

  RESET ROLE;

  IF v_result->>'status' = 'created'
     AND COALESCE((v_result->>'outside_assignment')::boolean, false) IS FALSE
     AND NOT ('OUTSIDE_ASSIGNMENT' = ANY (COALESCE(v_codes, ARRAY[]::text[])))
  THEN
    INSERT INTO ex046_results VALUES ('T3 assigned no anomaly', 'PASS', 'ok');
  ELSE
    INSERT INTO ex046_results VALUES ('T3 assigned no anomaly', 'FAIL',
      format('result=%s codes=%s', v_result, v_codes));
  END IF;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO ex046_results VALUES ('T3 assigned no anomaly', 'FAIL', SQLERRM);
END $$;

-- T4: hint sessió detecta outside_assignment
DO $$
DECLARE
  v_hint jsonb;
BEGIN
  SET LOCAL ROLE service_role;
  v_hint := api.station_employee_location_hint(
    '10460000-0000-0000-0000-000000000001'::uuid,
    'd0460000-0000-0000-0000-000000000002'::uuid
  );
  RESET ROLE;

  IF (v_hint->>'outside_assignment')::boolean IS TRUE
     AND (v_hint->>'allow_unassigned_punch')::boolean IS TRUE
     AND (v_hint->>'warn_unassigned_punch')::boolean IS TRUE
  THEN
    INSERT INTO ex046_results VALUES ('T4 hint outside assignment', 'PASS', v_hint::text);
  ELSE
    INSERT INTO ex046_results VALUES ('T4 hint outside assignment', 'FAIL', v_hint::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO ex046_results VALUES ('T4 hint outside assignment', 'FAIL', SQLERRM);
END $$;

SELECT test_name, status, details FROM ex046_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM ex046_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EX-04.6 tests failed: %', v_fail;
  END IF;
END $$;

ROLLBACK;
