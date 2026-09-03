-- =============================================================================
-- attendance_station_offline_skew_delay_ex054_tests.sql
-- EX-05.4 — CLOCK_SKEW / OFFLINE_DELAY / max_age
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0540000-0000-0000-0000-000000000001', 'EX054 Tenant', 'ex054-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES (
  'b0540000-0000-0000-0000-000000000001',
  'a0540000-0000-0000-0000-000000000001',
  'EX054 Site',
  true
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES ('c0540000-0000-0000-0000-000000000001', 'emp@ex054.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES ('c0540000-0000-0000-0000-000000000001', 'emp@ex054.test', 'Emp EX054')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES (
  gen_random_uuid(),
  'a0540000-0000-0000-0000-000000000001',
  'c0540000-0000-0000-0000-000000000001',
  'member',
  true
)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES (
  'd0540000-0000-0000-0000-000000000001',
  'a0540000-0000-0000-0000-000000000001',
  'b0540000-0000-0000-0000-000000000001',
  'c0540000-0000-0000-0000-000000000001',
  'Emp EX054',
  'active'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.locations (id, tenant_id, site_id, name, type, status)
VALUES (
  'e0540000-0000-0000-0000-000000000001',
  'a0540000-0000-0000-0000-000000000001',
  'b0540000-0000-0000-0000-000000000001',
  'Zona EX054', 'zone', 'active'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.attendance_devices (
  id, tenant_id, site_id, location_id, name, type, status,
  device_public_id, device_secret_hash, local_pin_hash, allowed_methods
) VALUES (
  '10540000-0000-0000-0000-000000000001',
  'a0540000-0000-0000-0000-000000000001',
  'b0540000-0000-0000-0000-000000000001',
  'e0540000-0000-0000-0000-000000000001',
  'Estacio EX054',
  'station',
  'active',
  'st-ex054-skew',
  data.hash_attendance_device_secret('station-secret-ex054-32chars!!!!'),
  data.hash_attendance_station_pin('4321'),
  ARRAY['manual']::text[]
)
ON CONFLICT (id) DO UPDATE
SET status = 'active',
    location_id = EXCLUDED.location_id,
    device_secret_hash = EXCLUDED.device_secret_hash;

INSERT INTO data.tenant_feature_overrides (tenant_id, feature_key, override_status)
VALUES (
  'a0540000-0000-0000-0000-000000000001',
  'station_offline_deferred_punch',
  true
)
ON CONFLICT (tenant_id, feature_key) DO UPDATE
SET override_status = true;

CREATE TEMP TABLE ex054_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.ex054_clear_punches()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  ALTER TABLE data.time_punches DISABLE TRIGGER trg_immutable_time_punches;
  DELETE FROM data.time_punches
  WHERE tenant_id = 'a0540000-0000-0000-0000-000000000001'
     OR employee_id = 'd0540000-0000-0000-0000-000000000001';
  ALTER TABLE data.time_punches ENABLE TRIGGER trg_immutable_time_punches;
END;
$$;

SELECT pg_temp.ex054_clear_punches();

-- T1: offline 90 min → CLOCK_SKEW + OFFLINE_DELAY, occurred_at conservat
DO $$
DECLARE
  v_result jsonb;
  v_row    record;
  v_toc    timestamptz := now() - interval '90 minutes';
  v_codes  text[];
BEGIN
  v_result := api.record_station_time_punch(
    '10540000-0000-0000-0000-000000000001',
    'd0540000-0000-0000-0000-000000000001',
    'f0540000-0000-0000-0000-000000000001',
    'in',
    NULL,
    'station',
    NULL,
    NULL,
    v_toc
  );

  SELECT occurred_at, anomaly_codes INTO v_row
  FROM data.time_punches
  WHERE id = (v_result->>'punch_id')::uuid;

  v_codes := COALESCE(v_row.anomaly_codes, ARRAY[]::text[]);

  IF v_result->>'status' = 'created'
     AND abs(extract(epoch from (v_row.occurred_at - v_toc))) < 1
     AND 'CLOCK_SKEW' = ANY (v_codes)
     AND 'OFFLINE_DELAY' = ANY (v_codes)
  THEN
    INSERT INTO ex054_results VALUES (
      'T1 CLOCK_SKEW+OFFLINE_DELAY',
      'PASS',
      format('codes=%s', v_codes)
    );
  ELSE
    INSERT INTO ex054_results VALUES (
      'T1 CLOCK_SKEW+OFFLINE_DELAY',
      'FAIL',
      format('result=%s codes=%s occurred=%s', v_result, v_codes, v_row.occurred_at)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex054_results VALUES ('T1 CLOCK_SKEW+OFFLINE_DELAY', 'ERROR', SQLERRM);
END $$;

-- T2: online (NULL occurred_at) sense anomalies de skew/delay
DO $$
DECLARE
  v_result jsonb;
  v_codes  text[];
BEGIN
  PERFORM pg_temp.ex054_clear_punches();

  v_result := api.record_station_time_punch(
    p_device_id := '10540000-0000-0000-0000-000000000001',
    p_employee_id := 'd0540000-0000-0000-0000-000000000001',
    p_client_op_id := 'f0540000-0000-0000-0000-000000000002',
    p_punch_type := 'in',
    p_occurred_at := NULL
  );

  SELECT COALESCE(anomaly_codes, ARRAY[]::text[]) INTO v_codes
  FROM data.time_punches
  WHERE id = (v_result->>'punch_id')::uuid;

  IF v_result->>'status' = 'created'
     AND NOT ('CLOCK_SKEW' = ANY (v_codes))
     AND NOT ('OFFLINE_DELAY' = ANY (v_codes))
  THEN
    INSERT INTO ex054_results VALUES ('T2 online sense skew', 'PASS', format('codes=%s', v_codes));
  ELSE
    INSERT INTO ex054_results VALUES ('T2 online sense skew', 'FAIL', format('result=%s codes=%s', v_result, v_codes));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex054_results VALUES ('T2 online sense skew', 'ERROR', SQLERRM);
END $$;

-- T3: max_age → station_punch_too_old
DO $$
DECLARE
  v_ok boolean := false;
BEGIN
  PERFORM pg_temp.ex054_clear_punches();

  BEGIN
    PERFORM api.record_station_time_punch(
      '10540000-0000-0000-0000-000000000001',
      'd0540000-0000-0000-0000-000000000001',
      'f0540000-0000-0000-0000-000000000003',
      'in',
      NULL, 'station', NULL, NULL,
      now() - interval '80 days'
    );
  EXCEPTION WHEN check_violation THEN
    IF SQLERRM LIKE '%station_punch_too_old%' THEN
      v_ok := true;
    END IF;
  END;

  IF v_ok THEN
    INSERT INTO ex054_results VALUES ('T3 max_age reject', 'PASS', 'station_punch_too_old');
  ELSE
    INSERT INTO ex054_results VALUES ('T3 max_age reject', 'FAIL', 'expected too_old');
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex054_results VALUES ('T3 max_age reject', 'ERROR', SQLERRM);
END $$;

-- T4: retard curt (<5 min) sense OFFLINE_DELAY
DO $$
DECLARE
  v_result jsonb;
  v_codes  text[];
BEGIN
  PERFORM pg_temp.ex054_clear_punches();

  v_result := api.record_station_time_punch(
    '10540000-0000-0000-0000-000000000001',
    'd0540000-0000-0000-0000-000000000001',
    'f0540000-0000-0000-0000-000000000004',
    'in',
    NULL, 'station', NULL, NULL,
    now() - interval '2 minutes'
  );

  SELECT COALESCE(anomaly_codes, ARRAY[]::text[]) INTO v_codes
  FROM data.time_punches
  WHERE id = (v_result->>'punch_id')::uuid;

  IF v_result->>'status' = 'created'
     AND NOT ('OFFLINE_DELAY' = ANY (v_codes))
     AND NOT ('CLOCK_SKEW' = ANY (v_codes))
  THEN
    INSERT INTO ex054_results VALUES ('T4 delay curt net', 'PASS', format('codes=%s', v_codes));
  ELSE
    INSERT INTO ex054_results VALUES ('T4 delay curt net', 'FAIL', format('codes=%s', v_codes));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex054_results VALUES ('T4 delay curt net', 'ERROR', SQLERRM);
END $$;

SELECT test_name, status, details FROM ex054_results ORDER BY test_name;

SELECT
  COUNT(*) FILTER (WHERE status = 'PASS') AS passed,
  COUNT(*) FILTER (WHERE status = 'FAIL') AS failed,
  COUNT(*) FILTER (WHERE status = 'ERROR') AS errors,
  COUNT(*) AS total
FROM ex054_results;

ROLLBACK;
