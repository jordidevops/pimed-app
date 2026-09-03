-- =============================================================================
-- attendance_station_offline_occurred_at_ex053_tests.sql
-- EX-05.3 — offline occurred_at + received_at + monotonia
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0530000-0000-0000-0000-000000000001', 'EX053 Tenant', 'ex053-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES (
  'b0530000-0000-0000-0000-000000000001',
  'a0530000-0000-0000-0000-000000000001',
  'EX053 Site',
  true
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES ('c0530000-0000-0000-0000-000000000001', 'emp@ex053.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES ('c0530000-0000-0000-0000-000000000001', 'emp@ex053.test', 'Emp EX053')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES (
  gen_random_uuid(),
  'a0530000-0000-0000-0000-000000000001',
  'c0530000-0000-0000-0000-000000000001',
  'member',
  true
)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES (
  'd0530000-0000-0000-0000-000000000001',
  'a0530000-0000-0000-0000-000000000001',
  'b0530000-0000-0000-0000-000000000001',
  'c0530000-0000-0000-0000-000000000001',
  'Emp EX053',
  'active'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.locations (id, tenant_id, site_id, name, type, status)
VALUES (
  'e0530000-0000-0000-0000-000000000001',
  'a0530000-0000-0000-0000-000000000001',
  'b0530000-0000-0000-0000-000000000001',
  'Zona EX053', 'zone', 'active'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.attendance_devices (
  id, tenant_id, site_id, location_id, name, type, status,
  device_public_id, device_secret_hash, local_pin_hash, allowed_methods
) VALUES (
  '10530000-0000-0000-0000-000000000001',
  'a0530000-0000-0000-0000-000000000001',
  'b0530000-0000-0000-0000-000000000001',
  'e0530000-0000-0000-0000-000000000001',
  'Estacio EX053',
  'station',
  'active',
  'st-ex053-offline',
  data.hash_attendance_device_secret('station-secret-ex053-32chars!!!!'),
  data.hash_attendance_station_pin('4321'),
  ARRAY['manual']::text[]
)
ON CONFLICT (id) DO UPDATE
SET status = 'active',
    location_id = EXCLUDED.location_id,
    device_secret_hash = EXCLUDED.device_secret_hash;

INSERT INTO data.tenant_feature_overrides (tenant_id, feature_key, override_status)
VALUES (
  'a0530000-0000-0000-0000-000000000001',
  'station_offline_deferred_punch',
  true
)
ON CONFLICT (tenant_id, feature_key) DO UPDATE
SET override_status = true;

CREATE TEMP TABLE ex053_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.ex053_clear_punches()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  ALTER TABLE data.time_punches DISABLE TRIGGER trg_immutable_time_punches;
  DELETE FROM data.time_punches
  WHERE tenant_id = 'a0530000-0000-0000-0000-000000000001'
     OR employee_id = 'd0530000-0000-0000-0000-000000000001';
  ALTER TABLE data.time_punches ENABLE TRIGGER trg_immutable_time_punches;
END;
$$;

SELECT pg_temp.ex053_clear_punches();

-- T1: offline sync conserva occurred_at del toc; received_at posterior
DO $$
DECLARE
  v_result jsonb;
  v_row    record;
  v_toc    timestamptz := now() - interval '90 minutes';
BEGIN
  v_result := api.record_station_time_punch(
    '10530000-0000-0000-0000-000000000001',
    'd0530000-0000-0000-0000-000000000001',
    'f0530000-0000-0000-0000-000000000001',
    'in',
    NULL,
    'station',
    NULL,
    NULL,
    v_toc
  );

  SELECT occurred_at, received_at INTO v_row
  FROM data.time_punches
  WHERE id = (v_result->>'punch_id')::uuid;

  IF v_result->>'status' = 'created'
     AND abs(extract(epoch from (v_row.occurred_at - v_toc))) < 1
     AND v_row.received_at > v_row.occurred_at
  THEN
    INSERT INTO ex053_results VALUES (
      'T1 offline occurred_at + received_at',
      'PASS',
      format('occurred=%s received=%s', v_row.occurred_at, v_row.received_at)
    );
  ELSE
    INSERT INTO ex053_results VALUES (
      'T1 offline occurred_at + received_at',
      'FAIL',
      format('result=%s row=%s', v_result, v_row)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex053_results VALUES ('T1 offline occurred_at + received_at', 'ERROR', SQLERRM);
END $$;

-- T2: online (p_occurred_at NULL) ≈ now()
DO $$
DECLARE
  v_result jsonb;
  v_row    record;
  v_before timestamptz := now() - interval '2 seconds';
BEGIN
  PERFORM pg_temp.ex053_clear_punches();

  v_result := api.record_station_time_punch(
    p_device_id := '10530000-0000-0000-0000-000000000001',
    p_employee_id := 'd0530000-0000-0000-0000-000000000001',
    p_client_op_id := 'f0530000-0000-0000-0000-000000000002',
    p_punch_type := 'in',
    p_occurred_at := NULL
  );

  SELECT occurred_at, received_at INTO v_row
  FROM data.time_punches
  WHERE id = (v_result->>'punch_id')::uuid;

  IF v_result->>'status' = 'created'
     AND v_row.occurred_at >= v_before
     AND abs(extract(epoch from (v_row.received_at - v_row.occurred_at))) < 5
  THEN
    INSERT INTO ex053_results VALUES ('T2 online now()', 'PASS', format('occurred=%s', v_row.occurred_at));
  ELSE
    INSERT INTO ex053_results VALUES ('T2 online now()', 'FAIL', format('result=%s row=%s', v_result, v_row));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex053_results VALUES ('T2 online now()', 'ERROR', SQLERRM);
END $$;

-- T3: monotonia — offline enrere rebutjat
DO $$
DECLARE
  v_ok boolean := false;
BEGIN
  PERFORM pg_temp.ex053_clear_punches();

  PERFORM api.record_station_time_punch(
    '10530000-0000-0000-0000-000000000001',
    'd0530000-0000-0000-0000-000000000001',
    'f0530000-0000-0000-0000-000000000010',
    'in',
    NULL, 'station', NULL, NULL,
    now() - interval '30 minutes'
  );

  BEGIN
    PERFORM api.record_station_time_punch(
      '10530000-0000-0000-0000-000000000001',
      'd0530000-0000-0000-0000-000000000001',
      'f0530000-0000-0000-0000-000000000011',
      'out',
      NULL, 'station', NULL, NULL,
      now() - interval '60 minutes'
    );
  EXCEPTION WHEN check_violation THEN
    IF SQLERRM LIKE '%station_punch_not_monotonic%' THEN
      v_ok := true;
    END IF;
  END;

  IF v_ok THEN
    INSERT INTO ex053_results VALUES ('T3 monotonic reject', 'PASS', 'blocked backwards offline');
  ELSE
    INSERT INTO ex053_results VALUES ('T3 monotonic reject', 'FAIL', 'expected not_monotonic');
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex053_results VALUES ('T3 monotonic reject', 'ERROR', SQLERRM);
END $$;

-- T4: FIFO offline in→out amb hours del toc
DO $$
DECLARE
  v_in  jsonb;
  v_out jsonb;
  v_cnt int;
BEGIN
  PERFORM pg_temp.ex053_clear_punches();

  v_in := api.record_station_time_punch(
    '10530000-0000-0000-0000-000000000001',
    'd0530000-0000-0000-0000-000000000001',
    'f0530000-0000-0000-0000-000000000020',
    'in', NULL, 'station', NULL, NULL,
    now() - interval '8 hours'
  );
  v_out := api.record_station_time_punch(
    '10530000-0000-0000-0000-000000000001',
    'd0530000-0000-0000-0000-000000000001',
    'f0530000-0000-0000-0000-000000000021',
    'out', NULL, 'station', NULL, NULL,
    now() - interval '30 minutes'
  );

  SELECT COUNT(*) INTO v_cnt
  FROM data.time_punches
  WHERE employee_id = 'd0530000-0000-0000-0000-000000000001'
    AND punch_type IN ('in', 'out');

  IF v_in->>'status' = 'created' AND v_out->>'status' = 'created' AND v_cnt = 2 THEN
    INSERT INTO ex053_results VALUES ('T4 FIFO offline in/out', 'PASS', '2 punches');
  ELSE
    INSERT INTO ex053_results VALUES (
      'T4 FIFO offline in/out', 'FAIL',
      format('in=%s out=%s cnt=%s', v_in, v_out, v_cnt)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex053_results VALUES ('T4 FIFO offline in/out', 'ERROR', SQLERRM);
END $$;

SELECT test_name, status, details FROM ex053_results ORDER BY test_name;

SELECT
  COUNT(*) FILTER (WHERE status = 'PASS') AS passed,
  COUNT(*) FILTER (WHERE status = 'FAIL') AS failed,
  COUNT(*) FILTER (WHERE status = 'ERROR') AS errors,
  COUNT(*) AS total
FROM ex053_results;

ROLLBACK;
