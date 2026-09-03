-- =============================================================================
-- attendance_station_offline_e2e_ex055_tests.sql
-- EX-05.5 — E2E lògic: mode avió, retry/duplicat, clock change, torn nocturn
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0550000-0000-0000-0000-000000000001', 'EX055 Tenant', 'ex055-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active, settings)
VALUES (
  'b0550000-0000-0000-0000-000000000001',
  'a0550000-0000-0000-0000-000000000001',
  'EX055 Site',
  true,
  '{"site_timezone":"Europe/Madrid"}'::jsonb
)
ON CONFLICT (id) DO UPDATE
SET settings = jsonb_set(COALESCE(data.sites.settings, '{}'::jsonb), '{site_timezone}', '"Europe/Madrid"');

INSERT INTO auth.users (id, email, role, aud)
VALUES ('c0550000-0000-0000-0000-000000000001', 'emp@ex055.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES ('c0550000-0000-0000-0000-000000000001', 'emp@ex055.test', 'Emp EX055')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES (
  gen_random_uuid(),
  'a0550000-0000-0000-0000-000000000001',
  'c0550000-0000-0000-0000-000000000001',
  'member',
  true
)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES (
  'd0550000-0000-0000-0000-000000000001',
  'a0550000-0000-0000-0000-000000000001',
  'b0550000-0000-0000-0000-000000000001',
  'c0550000-0000-0000-0000-000000000001',
  'Emp EX055',
  'active'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.locations (id, tenant_id, site_id, name, type, status)
VALUES (
  'e0550000-0000-0000-0000-000000000001',
  'a0550000-0000-0000-0000-000000000001',
  'b0550000-0000-0000-0000-000000000001',
  'Zona EX055', 'zone', 'active'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.attendance_devices (
  id, tenant_id, site_id, location_id, name, type, status,
  device_public_id, device_secret_hash, local_pin_hash, allowed_methods
) VALUES (
  '10550000-0000-0000-0000-000000000001',
  'a0550000-0000-0000-0000-000000000001',
  'b0550000-0000-0000-0000-000000000001',
  'e0550000-0000-0000-0000-000000000001',
  'Estacio EX055',
  'station',
  'active',
  'st-ex055-e2e',
  data.hash_attendance_device_secret('station-secret-ex055-32chars!!!!'),
  data.hash_attendance_station_pin('4321'),
  ARRAY['manual']::text[]
)
ON CONFLICT (id) DO UPDATE
SET status = 'active',
    location_id = EXCLUDED.location_id,
    device_secret_hash = EXCLUDED.device_secret_hash;

INSERT INTO data.tenant_feature_overrides (tenant_id, feature_key, override_status)
VALUES (
  'a0550000-0000-0000-0000-000000000001',
  'station_offline_deferred_punch',
  true
)
ON CONFLICT (tenant_id, feature_key) DO UPDATE
SET override_status = true;

CREATE TEMP TABLE ex055_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.ex055_clear_punches()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  ALTER TABLE data.time_punches DISABLE TRIGGER trg_immutable_time_punches;
  DELETE FROM data.time_punches
  WHERE tenant_id = 'a0550000-0000-0000-0000-000000000001'
     OR employee_id = 'd0550000-0000-0000-0000-000000000001';
  ALTER TABLE data.time_punches ENABLE TRIGGER trg_immutable_time_punches;
END;
$$;

SELECT pg_temp.ex055_clear_punches();

-- T1: mode avió — IN/OUT diferits FIFO; occurred_at toc; received_at pujada; OFFLINE_DELAY
DO $$
DECLARE
  v_in_toc   timestamptz := now() - interval '3 hours';
  v_out_toc  timestamptz := now() - interval '30 minutes';
  v_in       jsonb;
  v_out      jsonb;
  v_in_row   record;
  v_out_row  record;
BEGIN
  v_in := api.record_station_time_punch(
    '10550000-0000-0000-0000-000000000001',
    'd0550000-0000-0000-0000-000000000001',
    'f0550000-0000-0000-0000-000000000001',
    'in', NULL, 'station', NULL, NULL, v_in_toc
  );
  v_out := api.record_station_time_punch(
    '10550000-0000-0000-0000-000000000001',
    'd0550000-0000-0000-0000-000000000001',
    'f0550000-0000-0000-0000-000000000002',
    'out', NULL, 'station', NULL, NULL, v_out_toc
  );

  SELECT occurred_at, received_at, anomaly_codes INTO v_in_row
  FROM data.time_punches WHERE id = (v_in->>'punch_id')::uuid;
  SELECT occurred_at, received_at, anomaly_codes INTO v_out_row
  FROM data.time_punches WHERE id = (v_out->>'punch_id')::uuid;

  IF v_in->>'status' = 'created'
     AND v_out->>'status' = 'created'
     AND abs(extract(epoch from (v_in_row.occurred_at - v_in_toc))) < 1
     AND abs(extract(epoch from (v_out_row.occurred_at - v_out_toc))) < 1
     AND v_in_row.received_at > v_in_row.occurred_at
     AND v_out_row.received_at > v_out_row.occurred_at
     AND 'OFFLINE_DELAY' = ANY (COALESCE(v_in_row.anomaly_codes, ARRAY[]::text[]))
     AND v_in_row.occurred_at < v_out_row.occurred_at
  THEN
    INSERT INTO ex055_results VALUES ('T1 airplane FIFO sync', 'PASS', 'in/out deferred OK');
  ELSE
    INSERT INTO ex055_results VALUES (
      'T1 airplane FIFO sync', 'FAIL',
      format('in=%s out=%s in_row=%s out_row=%s', v_in, v_out, v_in_row, v_out_row)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex055_results VALUES ('T1 airplane FIFO sync', 'ERROR', SQLERRM);
END $$;

-- T2: retry/duplicat — mateix client_op_id → duplicate, 1 fila
DO $$
DECLARE
  v_op     uuid := 'f0550000-0000-0000-0000-000000000010';
  v_first  jsonb;
  v_second jsonb;
  v_cnt    int;
BEGIN
  PERFORM pg_temp.ex055_clear_punches();

  v_first := api.record_station_time_punch(
    '10550000-0000-0000-0000-000000000001',
    'd0550000-0000-0000-0000-000000000001',
    v_op, 'in', NULL, 'station', NULL, NULL,
    now() - interval '45 minutes'
  );
  v_second := api.record_station_time_punch(
    '10550000-0000-0000-0000-000000000001',
    'd0550000-0000-0000-0000-000000000001',
    v_op, 'in', NULL, 'station', NULL, NULL,
    now() - interval '45 minutes'
  );

  SELECT COUNT(*) INTO v_cnt
  FROM data.time_punches
  WHERE client_op_id = v_op;

  IF v_first->>'status' = 'created'
     AND v_second->>'status' = 'duplicate'
     AND v_second->>'punch_id' = v_first->>'punch_id'
     AND v_cnt = 1
  THEN
    INSERT INTO ex055_results VALUES ('T2 retry duplicate', 'PASS', 'idempotent');
  ELSE
    INSERT INTO ex055_results VALUES (
      'T2 retry duplicate', 'FAIL',
      format('first=%s second=%s cnt=%s', v_first, v_second, v_cnt)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex055_results VALUES ('T2 retry duplicate', 'ERROR', SQLERRM);
END $$;

-- T3: clock change — occurred_at futur → CLOCK_SKEW, sense OFFLINE_DELAY
DO $$
DECLARE
  v_result jsonb;
  v_codes  text[];
  v_future timestamptz := now() + interval '2 hours';
BEGIN
  PERFORM pg_temp.ex055_clear_punches();

  v_result := api.record_station_time_punch(
    '10550000-0000-0000-0000-000000000001',
    'd0550000-0000-0000-0000-000000000001',
    'f0550000-0000-0000-0000-000000000020',
    'in', NULL, 'station', NULL, NULL, v_future
  );

  SELECT COALESCE(anomaly_codes, ARRAY[]::text[]) INTO v_codes
  FROM data.time_punches WHERE id = (v_result->>'punch_id')::uuid;

  IF v_result->>'status' = 'created'
     AND 'CLOCK_SKEW' = ANY (v_codes)
     AND NOT ('OFFLINE_DELAY' = ANY (v_codes))
  THEN
    INSERT INTO ex055_results VALUES ('T3 clock change future', 'PASS', format('codes=%s', v_codes));
  ELSE
    INSERT INTO ex055_results VALUES ('T3 clock change future', 'FAIL', format('result=%s codes=%s', v_result, v_codes));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex055_results VALUES ('T3 clock change future', 'ERROR', SQLERRM);
END $$;

-- T4: torn nocturn mateix dia local (Madrid) — IN 22:00 OUT 23:30; work_date compartit
DO $$
DECLARE
  v_base    date := ((now() AT TIME ZONE 'Europe/Madrid')::date - 2);
  v_in_at   timestamptz;
  v_out_at  timestamptz;
  v_in      jsonb;
  v_out     jsonb;
  v_in_wd   date;
  v_out_wd  date;
BEGIN
  PERFORM pg_temp.ex055_clear_punches();

  v_in_at := (v_base::text || ' 22:00:00')::timestamp AT TIME ZONE 'Europe/Madrid';
  v_out_at := (v_base::text || ' 23:30:00')::timestamp AT TIME ZONE 'Europe/Madrid';

  v_in := api.record_station_time_punch(
    '10550000-0000-0000-0000-000000000001',
    'd0550000-0000-0000-0000-000000000001',
    'f0550000-0000-0000-0000-000000000030',
    'in', NULL, 'station', NULL, NULL, v_in_at
  );
  v_out := api.record_station_time_punch(
    '10550000-0000-0000-0000-000000000001',
    'd0550000-0000-0000-0000-000000000001',
    'f0550000-0000-0000-0000-000000000031',
    'out', NULL, 'station', NULL, NULL, v_out_at
  );

  SELECT (occurred_at AT TIME ZONE 'Europe/Madrid')::date INTO v_in_wd
  FROM data.time_punches WHERE id = (v_in->>'punch_id')::uuid;
  SELECT (occurred_at AT TIME ZONE 'Europe/Madrid')::date INTO v_out_wd
  FROM data.time_punches WHERE id = (v_out->>'punch_id')::uuid;

  IF v_in->>'status' = 'created'
     AND v_out->>'status' = 'created'
     AND v_in_wd = v_base
     AND v_out_wd = v_base
     AND data.compute_employee_punch_day_state(
       'd0550000-0000-0000-0000-000000000001', v_base
     ) = 'day'
  THEN
    INSERT INTO ex055_results VALUES (
      'T4 night same local day', 'PASS',
      format('work_date=%s state=day after out', v_base)
    );
  ELSE
    INSERT INTO ex055_results VALUES (
      'T4 night same local day', 'FAIL',
      format('in=%s out=%s in_wd=%s out_wd=%s state=%s',
        v_in, v_out, v_in_wd, v_out_wd,
        data.compute_employee_punch_day_state('d0550000-0000-0000-0000-000000000001', v_base))
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex055_results VALUES ('T4 night same local day', 'ERROR', SQLERRM);
END $$;

-- T5: frontera TZ recent — 23:45 UTC → work_date Madrid del dia següent (dins max_age)
DO $$
DECLARE
  v_utc_day  date := ((now() AT TIME ZONE 'UTC')::date - 1);
  v_punch_ts timestamptz;
  v_result   jsonb;
  v_wd_mad   date;
  v_expected date;
BEGIN
  PERFORM pg_temp.ex055_clear_punches();

  v_punch_ts := (v_utc_day::text || ' 23:45:00')::timestamp AT TIME ZONE 'UTC';
  v_expected := (v_punch_ts AT TIME ZONE 'Europe/Madrid')::date;

  v_result := api.record_station_time_punch(
    '10550000-0000-0000-0000-000000000001',
    'd0550000-0000-0000-0000-000000000001',
    'f0550000-0000-0000-0000-000000000040',
    'in', NULL, 'station', NULL, NULL, v_punch_ts
  );

  SELECT (occurred_at AT TIME ZONE 'Europe/Madrid')::date INTO v_wd_mad
  FROM data.time_punches WHERE id = (v_result->>'punch_id')::uuid;

  IF v_result->>'status' = 'created'
     AND v_wd_mad = v_expected
     AND v_expected > v_utc_day  -- 23:45 UTC cau al dia següent a Madrid (CET/CEST)
  THEN
    INSERT INTO ex055_results VALUES (
      'T5 TZ midnight boundary', 'PASS',
      format('utc_day=%s madrid_wd=%s', v_utc_day, v_wd_mad)
    );
  ELSE
    INSERT INTO ex055_results VALUES (
      'T5 TZ midnight boundary', 'FAIL',
      format('result=%s wd=%s expected=%s utc_day=%s', v_result, v_wd_mad, v_expected, v_utc_day)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex055_results VALUES ('T5 TZ midnight boundary', 'ERROR', SQLERRM);
END $$;

-- T6: max_age (quarantena servidor) — regressió EX-05.4
DO $$
DECLARE
  v_ok boolean := false;
BEGIN
  PERFORM pg_temp.ex055_clear_punches();
  BEGIN
    PERFORM api.record_station_time_punch(
      '10550000-0000-0000-0000-000000000001',
      'd0550000-0000-0000-0000-000000000001',
      'f0550000-0000-0000-0000-000000000050',
      'in', NULL, 'station', NULL, NULL,
      now() - interval '80 days'
    );
  EXCEPTION WHEN check_violation THEN
    IF SQLERRM LIKE '%station_punch_too_old%' THEN
      v_ok := true;
    END IF;
  END;

  IF v_ok THEN
    INSERT INTO ex055_results VALUES ('T6 max_age quarantine', 'PASS', 'too_old');
  ELSE
    INSERT INTO ex055_results VALUES ('T6 max_age quarantine', 'FAIL', 'expected too_old');
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex055_results VALUES ('T6 max_age quarantine', 'ERROR', SQLERRM);
END $$;

SELECT test_name, status, details FROM ex055_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
  v_err  int;
BEGIN
  SELECT
    COUNT(*) FILTER (WHERE status = 'FAIL'),
    COUNT(*) FILTER (WHERE status = 'ERROR')
  INTO v_fail, v_err
  FROM ex055_results;

  IF v_fail > 0 OR v_err > 0 THEN
    RAISE EXCEPTION 'EX-05.5 offline E2E: % FAIL, % ERROR', v_fail, v_err;
  END IF;
END $$;

SELECT
  COUNT(*) FILTER (WHERE status = 'PASS') AS passed,
  COUNT(*) FILTER (WHERE status = 'FAIL') AS failed,
  COUNT(*) FILTER (WHERE status = 'ERROR') AS errors,
  COUNT(*) AS total
FROM ex055_results;

ROLLBACK;
