-- =============================================================================
-- attendance_station_offline_flag_ex056_tests.sql
-- EX-05.6 — FF-04 station_offline_deferred_punch
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0560000-0000-0000-0000-000000000001', 'EX056 Tenant', 'ex056-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES (
  'b0560000-0000-0000-0000-000000000001',
  'a0560000-0000-0000-0000-000000000001',
  'EX056 Site',
  true
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES ('c0560000-0000-0000-0000-000000000001', 'emp@ex056.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES ('c0560000-0000-0000-0000-000000000001', 'emp@ex056.test', 'Emp EX056')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES (
  gen_random_uuid(),
  'a0560000-0000-0000-0000-000000000001',
  'c0560000-0000-0000-0000-000000000001',
  'member',
  true
)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES (
  'd0560000-0000-0000-0000-000000000001',
  'a0560000-0000-0000-0000-000000000001',
  'b0560000-0000-0000-0000-000000000001',
  'c0560000-0000-0000-0000-000000000001',
  'Emp EX056',
  'active'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.locations (id, tenant_id, site_id, name, type, status)
VALUES (
  'e0560000-0000-0000-0000-000000000001',
  'a0560000-0000-0000-0000-000000000001',
  'b0560000-0000-0000-0000-000000000001',
  'Zona EX056', 'zone', 'active'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.attendance_devices (
  id, tenant_id, site_id, location_id, name, type, status,
  device_public_id, device_secret_hash, local_pin_hash, allowed_methods
) VALUES (
  '10560000-0000-0000-0000-000000000001',
  'a0560000-0000-0000-0000-000000000001',
  'b0560000-0000-0000-0000-000000000001',
  'e0560000-0000-0000-0000-000000000001',
  'Estacio EX056',
  'station',
  'active',
  'st-ex056-flag',
  data.hash_attendance_device_secret('station-secret-ex056-32chars!!!!'),
  data.hash_attendance_station_pin('4321'),
  ARRAY['manual']::text[]
)
ON CONFLICT (id) DO UPDATE
SET status = 'active',
    location_id = EXCLUDED.location_id,
    device_secret_hash = EXCLUDED.device_secret_hash;

-- Assegurar flag OFF per aquest tenant (sense override)
DELETE FROM data.tenant_feature_overrides
WHERE tenant_id = 'a0560000-0000-0000-0000-000000000001'
  AND feature_key = 'station_offline_deferred_punch';

CREATE TEMP TABLE ex056_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.ex056_clear_punches()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  ALTER TABLE data.time_punches DISABLE TRIGGER trg_immutable_time_punches;
  DELETE FROM data.time_punches
  WHERE tenant_id = 'a0560000-0000-0000-0000-000000000001'
     OR employee_id = 'd0560000-0000-0000-0000-000000000001';
  ALTER TABLE data.time_punches ENABLE TRIGGER trg_immutable_time_punches;
END;
$$;

SELECT pg_temp.ex056_clear_punches();

-- T1: flag OFF → deferred (occurred_at) rebutjat
DO $$
DECLARE
  v_ok boolean := false;
BEGIN
  IF data.is_station_offline_deferred_punch_enabled('a0560000-0000-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'expected flag OFF for EX056 tenant';
  END IF;

  BEGIN
    PERFORM api.record_station_time_punch(
      '10560000-0000-0000-0000-000000000001',
      'd0560000-0000-0000-0000-000000000001',
      'f0560000-0000-0000-0000-000000000001',
      'in', NULL, 'station', NULL, NULL,
      now() - interval '20 minutes'
    );
  EXCEPTION WHEN check_violation THEN
    IF SQLERRM LIKE '%station_offline_disabled%' THEN
      v_ok := true;
    END IF;
  END;

  IF v_ok THEN
    INSERT INTO ex056_results VALUES ('T1 flag OFF blocks deferred', 'PASS', 'station_offline_disabled');
  ELSE
    INSERT INTO ex056_results VALUES ('T1 flag OFF blocks deferred', 'FAIL', 'expected disabled');
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex056_results VALUES ('T1 flag OFF blocks deferred', 'ERROR', SQLERRM);
END $$;

-- T2: flag OFF → online (NULL occurred_at) OK
DO $$
DECLARE
  v_result jsonb;
BEGIN
  PERFORM pg_temp.ex056_clear_punches();

  v_result := api.record_station_time_punch(
    p_device_id := '10560000-0000-0000-0000-000000000001',
    p_employee_id := 'd0560000-0000-0000-0000-000000000001',
    p_client_op_id := 'f0560000-0000-0000-0000-000000000002',
    p_punch_type := 'in',
    p_occurred_at := NULL
  );

  IF v_result->>'status' = 'created' THEN
    INSERT INTO ex056_results VALUES ('T2 online OK with flag OFF', 'PASS', 'created');
  ELSE
    INSERT INTO ex056_results VALUES ('T2 online OK with flag OFF', 'FAIL', format('%s', v_result));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex056_results VALUES ('T2 online OK with flag OFF', 'ERROR', SQLERRM);
END $$;

-- T3: override ON → deferred OK
DO $$
DECLARE
  v_result jsonb;
  v_toc    timestamptz := now() - interval '25 minutes';
BEGIN
  PERFORM pg_temp.ex056_clear_punches();

  INSERT INTO data.tenant_feature_overrides (tenant_id, feature_key, override_status)
  VALUES (
    'a0560000-0000-0000-0000-000000000001',
    'station_offline_deferred_punch',
    true
  )
  ON CONFLICT (tenant_id, feature_key) DO UPDATE
  SET override_status = true;

  IF NOT data.is_station_offline_deferred_punch_enabled('a0560000-0000-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'expected flag ON after override';
  END IF;

  v_result := api.record_station_time_punch(
    '10560000-0000-0000-0000-000000000001',
    'd0560000-0000-0000-0000-000000000001',
    'f0560000-0000-0000-0000-000000000003',
    'in', NULL, 'station', NULL, NULL, v_toc
  );

  IF v_result->>'status' = 'created' THEN
    INSERT INTO ex056_results VALUES ('T3 override ON deferred', 'PASS', 'created');
  ELSE
    INSERT INTO ex056_results VALUES ('T3 override ON deferred', 'FAIL', format('%s', v_result));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex056_results VALUES ('T3 override ON deferred', 'ERROR', SQLERRM);
END $$;

-- T4: Acme seed override present (local demo)
DO $$
BEGIN
  IF data.is_station_offline_deferred_punch_enabled('10000000-0000-0000-0000-000000000001') THEN
    INSERT INTO ex056_results VALUES ('T4 Acme override ON', 'PASS', 'demo ready');
  ELSE
    INSERT INTO ex056_results VALUES ('T4 Acme override ON', 'FAIL', 'Acme should have offline ON in local');
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex056_results VALUES ('T4 Acme override ON', 'ERROR', SQLERRM);
END $$;

SELECT test_name, status, details FROM ex056_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
  v_err  int;
BEGIN
  SELECT
    COUNT(*) FILTER (WHERE status = 'FAIL'),
    COUNT(*) FILTER (WHERE status = 'ERROR')
  INTO v_fail, v_err
  FROM ex056_results;

  IF v_fail > 0 OR v_err > 0 THEN
    RAISE EXCEPTION 'EX-05.6 FF-04: % FAIL, % ERROR', v_fail, v_err;
  END IF;
END $$;

SELECT
  COUNT(*) FILTER (WHERE status = 'PASS') AS passed,
  COUNT(*) FILTER (WHERE status = 'FAIL') AS failed,
  COUNT(*) FILTER (WHERE status = 'ERROR') AS errors,
  COUNT(*) AS total
FROM ex056_results;

ROLLBACK;
