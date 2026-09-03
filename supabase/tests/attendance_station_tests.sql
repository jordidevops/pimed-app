-- =============================================================================
-- attendance_station_tests.sql — E2E estacions (ST-1b / ST-3)
-- Executar: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -f supabase/tests/attendance_station_tests.sql
-- =============================================================================

BEGIN;

CREATE TEMP TABLE st_test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

-- ---------------------------------------------------------------------------
-- ST-T1: register_attendance_device + activate + punch with location snapshot
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_code         text := 'STE2E001';
  v_code_hash    bytea := digest(data.normalize_attendance_pairing_code(v_code), 'sha256');
  v_device_id    uuid;
  v_secret       text := 'station-secret-32chars-minimum!!';
  v_pin          text := '4321';
  v_employee_id  uuid := '40000000-0000-0000-0000-000000000005';
  v_site_id      uuid := '30000000-0000-0000-0000-000000000001';
  v_location_id  uuid := '41000000-0000-0000-0000-000000000002';
  v_punch        record;
  v_result       jsonb;
BEGIN
  DELETE FROM data.time_punches
  WHERE device_id IN (
    SELECT id FROM data.attendance_devices WHERE device_public_id = 'st-e2e-test-device'
  );
  DELETE FROM data.attendance_devices WHERE device_public_id = 'st-e2e-test-device';
  DELETE FROM data.attendance_location_assignments
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001';

  INSERT INTO data.attendance_device_pairing_codes (
    tenant_id, site_id, location_id, code_hash, expires_at
  ) VALUES (
    '10000000-0000-0000-0000-000000000001',
    v_site_id,
    v_location_id,
    v_code_hash,
    now() + interval '15 minutes'
  );

  SET LOCAL ROLE service_role;

  v_result := api.register_attendance_device(
    v_code,
    'st-e2e-test-device',
    v_secret,
    v_pin,
    'Estació E2E Test',
    '{}'::jsonb
  );
  v_device_id := (v_result->>'device_id')::uuid;

  IF (v_result->>'status') IS DISTINCT FROM 'pending' THEN
    RAISE EXCEPTION 'expected pending, got %', v_result->>'status';
  END IF;

  RESET ROLE;
  PERFORM set_config('request.jwt.claims',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  v_result := api.update_attendance_station(
    v_device_id,
    'Estació E2E Test',
    v_site_id,
    v_location_id,
    'active'
  );

  IF (v_result->>'status') IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'expected active, got %', v_result->>'status';
  END IF;

  RESET ROLE;
  SET LOCAL ROLE service_role;

  v_result := api.record_station_time_punch(
    v_device_id,
    v_employee_id,
    gen_random_uuid(),
    'in'
  );

  IF (v_result->>'status') IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'punch not created: %', v_result;
  END IF;

  SELECT *
    INTO v_punch
  FROM data.time_punches
  WHERE id = (v_result->>'punch_id')::uuid;

  IF v_punch.source IS DISTINCT FROM 'station' THEN
    RAISE EXCEPTION 'expected source station, got %', v_punch.source;
  END IF;
  IF v_punch.location_id IS DISTINCT FROM v_location_id THEN
    RAISE EXCEPTION 'location_id mismatch';
  END IF;
  IF v_punch.location_name_snapshot IS NULL OR v_punch.location_name_snapshot = '' THEN
    RAISE EXCEPTION 'missing location_name_snapshot';
  END IF;
  IF v_punch.device_name_snapshot IS NULL THEN
    RAISE EXCEPTION 'missing device_name_snapshot';
  END IF;
  IF v_punch.geo_lat IS NOT NULL OR v_punch.geo_lng IS NOT NULL THEN
    RAISE EXCEPTION 'station punch must not store geo';
  END IF;
  IF v_punch.device_id IS DISTINCT FROM v_device_id THEN
    RAISE EXCEPTION 'device_id mismatch';
  END IF;

  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T1 station punch with location snapshot, no geo',
    'PASS',
    format('location=%s device=%s', v_punch.location_name_snapshot, v_punch.device_name_snapshot)
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO st_test_results VALUES ('ST-T1 station punch with location snapshot, no geo', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- ST-T2: verify_attendance_station_credentials
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_ctx jsonb;
BEGIN
  SET LOCAL ROLE service_role;
  v_ctx := api.verify_attendance_station_credentials('st-e2e-test-device', 'station-secret-32chars-minimum!!');
  IF (v_ctx->>'status') IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'verify failed: %', v_ctx;
  END IF;
  RESET ROLE;
  INSERT INTO st_test_results VALUES ('ST-T2 verify station credentials', 'PASS', v_ctx->>'location_path');
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO st_test_results VALUES ('ST-T2 verify station credentials', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- ST-T3: list_attendance_station_employees
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_payload jsonb;
  v_count   int;
  v_device_id uuid;
BEGIN
  SET LOCAL ROLE service_role;
  SELECT id INTO v_device_id FROM data.attendance_devices WHERE device_public_id = 'st-e2e-test-device' LIMIT 1;
  v_payload := api.list_attendance_station_employees(v_device_id);
  v_count := jsonb_array_length(COALESCE(v_payload->'employees', '[]'::jsonb));
  IF v_count < 1 THEN
    RAISE EXCEPTION 'expected employees, got %', v_count;
  END IF;
  RESET ROLE;
  INSERT INTO st_test_results VALUES ('ST-T3 list station employees', 'PASS', v_count::text || ' employees');
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO st_test_results VALUES ('ST-T3 list station employees', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- ST-T4: assert_station_register_rate_limit (21st attempt blocked)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_i int;
  v_err text;
BEGIN
  SET LOCAL ROLE service_role;
  DELETE FROM data.station_register_rate_limits WHERE client_key = 'ip:test-rate-limit';

  FOR v_i IN 1..20 LOOP
    PERFORM api.assert_station_register_rate_limit('ip:test-rate-limit', 20, 15);
  END LOOP;

  BEGIN
    PERFORM api.assert_station_register_rate_limit('ip:test-rate-limit', 20, 15);
    RAISE EXCEPTION 'expected rate limit on attempt 21';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    IF v_err NOT LIKE '%station_register_rate_limited%' THEN
      RAISE;
    END IF;
  END;

  RESET ROLE;
  INSERT INTO st_test_results VALUES ('ST-T4 register rate limit 20/15min', 'PASS', v_err);
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO st_test_results VALUES ('ST-T4 register rate limit 20/15min', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- ST-T5: mobile_peripatetic employee can punch in/out at station (no day_start)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_code         text := 'STE2E002';
  v_code_hash    bytea := digest(data.normalize_attendance_pairing_code(v_code), 'sha256');
  v_result       jsonb;
  v_device_id    uuid;
  v_mobile_id    uuid := '40000000-0000-0000-0000-000000000021';
  v_today        date := (now() AT TIME ZONE 'Europe/Madrid')::date;
BEGIN
  DELETE FROM data.time_punches
  WHERE employee_id = v_mobile_id
    AND (occurred_at AT TIME ZONE 'Europe/Madrid')::date = v_today;

  INSERT INTO data.attendance_device_pairing_codes (tenant_id, site_id, location_id, code_hash, expires_at)
  VALUES (
    '10000000-0000-0000-0000-000000000001',
    '30000000-0000-0000-0000-000000000001',
    '41000000-0000-0000-0000-000000000002',
    v_code_hash,
    now() + interval '15 minutes'
  );

  SET LOCAL ROLE service_role;
  v_result := api.register_attendance_device(
    v_code, 'st-e2e-mobile', 'station-secret-32chars-minimum!!', '4321', 'Estació mobile test', '{}'::jsonb
  );
  v_device_id := (v_result->>'device_id')::uuid;
  RESET ROLE;

  PERFORM set_config('request.jwt.claims',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;
  v_result := api.update_attendance_station(
    v_device_id, 'Estació mobile test',
    '30000000-0000-0000-0000-000000000001',
    '41000000-0000-0000-0000-000000000002',
    'active'
  );
  RESET ROLE;
  SET LOCAL ROLE service_role;

  v_result := api.record_station_time_punch(
    v_device_id, v_mobile_id, gen_random_uuid(), 'in'
  );
  IF (v_result->>'status') IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'mobile station in failed: %', v_result;
  END IF;

  v_result := api.record_station_time_punch(
    v_device_id, v_mobile_id, gen_random_uuid(), 'out'
  );
  IF (v_result->>'status') IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'mobile station out failed: %', v_result;
  END IF;

  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T5 mobile_peripatetic station in/out without day_start',
    'PASS',
    'in then out'
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO st_test_results VALUES ('ST-T5 mobile_peripatetic station in/out without day_start', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- ST-T6: wrong punch type rejected at station
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_device_id uuid;
  v_employee_id uuid := '40000000-0000-0000-0000-000000000005';
  v_err text;
BEGIN
  SELECT id INTO v_device_id FROM data.attendance_devices WHERE device_public_id = 'st-e2e-test-device' LIMIT 1;
  IF v_device_id IS NULL THEN
    RAISE EXCEPTION 'missing test device';
  END IF;

  SET LOCAL ROLE service_role;
  BEGIN
    PERFORM api.record_station_time_punch(v_device_id, v_employee_id, gen_random_uuid(), 'in');
    RAISE EXCEPTION 'expected station_wrong_punch_type';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    IF v_err NOT LIKE '%station_wrong_punch_type%' AND v_err NOT LIKE '%cannot in after%' THEN
      RAISE;
    END IF;
  END;

  RESET ROLE;
  INSERT INTO st_test_results VALUES ('ST-T6 station rejects wrong punch type', 'PASS', v_err);
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO st_test_results VALUES ('ST-T6 station rejects wrong punch type', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- ST-T7: local PIN verify + lockout (ST-2b)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_code         text := 'STPIN001';
  v_code_hash    bytea := digest(data.normalize_attendance_pairing_code(v_code), 'sha256');
  v_device_id    uuid;
  v_secret       text := 'station-secret-pin-test-min!!';
  v_pin          text := '5678';
  v_result       jsonb;
  v_i            int;
BEGIN
  INSERT INTO data.attendance_device_pairing_codes (
    tenant_id, site_id, location_id, code_hash, expires_at
  ) VALUES (
    '10000000-0000-0000-0000-000000000001',
    '30000000-0000-0000-0000-000000000001',
    '41000000-0000-0000-0000-000000000002',
    v_code_hash,
    now() + interval '15 minutes'
  );

  SET LOCAL ROLE service_role;

  v_result := api.register_attendance_device(
    v_code,
    'st-pin-test-device',
    v_secret,
    v_pin,
    'Estació PIN Test',
    '{}'::jsonb
  );
  v_device_id := (v_result->>'device_id')::uuid;

  v_result := api.verify_attendance_station_local_pin(v_device_id, v_pin);
  IF (v_result->>'status') IS DISTINCT FROM 'ok' THEN
    RAISE EXCEPTION 'expected ok, got %', v_result->>'status';
  END IF;

  v_result := api.verify_attendance_station_local_pin(v_device_id, '0000');
  IF (v_result->>'status') IS DISTINCT FROM 'invalid' THEN
    RAISE EXCEPTION 'expected invalid, got %', v_result->>'status';
  END IF;

  FOR v_i IN 1..4 LOOP
    v_result := api.verify_attendance_station_local_pin(v_device_id, '0000');
  END LOOP;

  v_result := api.verify_attendance_station_local_pin(v_device_id, '0000');
  IF (v_result->>'status') IS DISTINCT FROM 'locked' THEN
    RAISE EXCEPTION 'expected locked after 5 failures, got %', v_result->>'status';
  END IF;

  v_result := api.verify_attendance_station_local_pin(v_device_id, v_pin);
  IF (v_result->>'status') IS DISTINCT FROM 'locked' THEN
    RAISE EXCEPTION 'expected still locked with correct pin, got %', v_result->>'status';
  END IF;

  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T7 local PIN verify and lockout',
    'PASS',
    format('locked after 5 fails, retry=%ss', v_result->>'retry_after_seconds')
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO st_test_results VALUES ('ST-T7 local PIN verify and lockout', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- ST-T8: identity QR issue / preview resolve / atomic punch (ST-4 / EX-01.1)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_device_id    uuid;
  v_employee_id  uuid := '40000000-0000-0000-0000-000000000005';
  v_issue        jsonb;
  v_token        text;
  v_resolve      jsonb;
  v_punch        jsonb;
  v_row          record;
  v_used_at      timestamptz;
BEGIN
  SELECT id INTO v_device_id FROM data.attendance_devices WHERE device_public_id = 'st-e2e-test-device' LIMIT 1;
  IF v_device_id IS NULL THEN
    RAISE EXCEPTION 'missing test device for ST-T8';
  END IF;

  RESET ROLE;
  PERFORM set_config('request.jwt.claims',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  PERFORM api.update_attendance_station(
    v_device_id,
    NULL,
    NULL,
    NULL,
    NULL,
    ARRAY['manual', 'qr']::text[]
  );

  RESET ROLE;
  SET LOCAL ROLE service_role;

  v_issue := api.issue_attendance_identity_token(v_employee_id, 'qr');
  v_token := v_issue->>'token';
  IF v_token IS NULL OR v_token = '' THEN
    RAISE EXCEPTION 'issue token failed: %', v_issue;
  END IF;

  v_resolve := api.resolve_attendance_identity_token(v_token, 'st-e2e-test-device');
  IF (v_resolve->>'employee_id')::uuid IS DISTINCT FROM v_employee_id THEN
    RAISE EXCEPTION 'resolve employee mismatch: %', v_resolve;
  END IF;

  -- Preview: resolve no consumeix el token
  v_resolve := api.resolve_attendance_identity_token(v_token, 'st-e2e-test-device');
  IF (v_resolve->>'employee_id')::uuid IS DISTINCT FROM v_employee_id THEN
    RAISE EXCEPTION 'second resolve employee mismatch: %', v_resolve;
  END IF;

  v_punch := api.record_station_time_punch(
    v_device_id,
    v_employee_id,
    gen_random_uuid(),
    'out',
    NULL,
    'qr',
    NULL,
    v_token
  );

  IF (v_punch->>'status') IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'qr punch not created: %', v_punch;
  END IF;

  SELECT used_at INTO v_used_at
  FROM data.attendance_identity_tokens
  WHERE id = (v_issue->>'token_id')::uuid;

  IF v_used_at IS NULL THEN
    RAISE EXCEPTION 'expected token consumed after qr punch';
  END IF;

  SELECT * INTO v_row FROM data.time_punches WHERE id = (v_punch->>'punch_id')::uuid;
  IF v_row.source IS DISTINCT FROM 'qr' THEN
    RAISE EXCEPTION 'expected source qr, got %', v_row.source;
  END IF;

  BEGIN
    PERFORM api.record_station_time_punch(
      v_device_id,
      v_employee_id,
      gen_random_uuid(),
      'in',
      NULL,
      'qr',
      NULL,
      v_token
    );
    RAISE EXCEPTION 'expected identity_token_already_used after punch';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%identity_token_already_used%' THEN
      RAISE;
    END IF;
  END;

  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T8 identity QR preview + atomic punch',
    'PASS',
    format('employee=%s source=%s', v_resolve->>'full_name', v_row.source)
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO st_test_results VALUES ('ST-T8 identity QR preview + atomic punch', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- ST-T8a: resolve cancel·lat — token encara vàlid (EX-01.1)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_device_id    uuid;
  v_employee_id  uuid := '40000000-0000-0000-0000-000000000005';
  v_token        text;
  v_resolve      jsonb;
BEGIN
  SELECT id INTO v_device_id FROM data.attendance_devices WHERE device_public_id = 'st-e2e-test-device' LIMIT 1;
  IF v_device_id IS NULL THEN
    RAISE EXCEPTION 'missing test device for ST-T8a';
  END IF;

  SET LOCAL ROLE service_role;

  v_token := (api.issue_attendance_identity_token(v_employee_id, 'qr'))->>'token';
  v_resolve := api.resolve_attendance_identity_token(v_token, 'st-e2e-test-device');
  -- Simula cancel·lació: no es fa punch
  v_resolve := api.resolve_attendance_identity_token(v_token, 'st-e2e-test-device');

  IF (v_resolve->>'employee_id')::uuid IS DISTINCT FROM v_employee_id THEN
    RAISE EXCEPTION 'token should remain valid after preview-only resolve';
  END IF;

  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T8a resolve cancel·lat token vàlid',
    'PASS',
    format('employee=%s', v_resolve->>'full_name')
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO st_test_results VALUES ('ST-T8a resolve cancel·lat token vàlid', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- ST-T8b: punch QR sense token rebutjat (EX-01.1 / RC-04)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_device_id    uuid;
  v_employee_id  uuid := '40000000-0000-0000-0000-000000000005';
  v_err          text;
BEGIN
  SELECT id INTO v_device_id FROM data.attendance_devices WHERE device_public_id = 'st-e2e-test-device' LIMIT 1;
  IF v_device_id IS NULL THEN
    RAISE EXCEPTION 'missing test device for ST-T8b';
  END IF;

  SET LOCAL ROLE service_role;
  BEGIN
    PERFORM api.record_station_time_punch(
      v_device_id,
      v_employee_id,
      gen_random_uuid(),
      'in',
      NULL,
      'qr',
      NULL,
      NULL
    );
    RAISE EXCEPTION 'expected identity_token_required';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    IF v_err NOT LIKE '%identity_token_required%' THEN
      RAISE;
    END IF;
  END;

  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T8b punch qr sense token rebutjat',
    'PASS',
    v_err
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO st_test_results VALUES ('ST-T8b punch qr sense token rebutjat', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- ST-T9: geo antifraud enabled, probe within range -> punch ok, geo still NULL
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_code         text := 'STGEO001';
  v_code_hash    bytea := digest(data.normalize_attendance_pairing_code(v_code), 'sha256');
  v_device_id    uuid;
  v_secret       text := 'station-secret-geo-test-min!!';
  v_pin          text := '7890';
  v_employee_id  uuid := '40000000-0000-0000-0000-000000000006';
  v_site_id      uuid := '30000000-0000-0000-0000-000000000001';
  v_location_id  uuid := '41000000-0000-0000-0000-000000000004';
  v_result       jsonb;
  v_punch        record;
  v_device_geo   jsonb := jsonb_build_object(
    'latitude', 41.39081,
    'longitude', 2.15446,
    'accuracy_meters', 8,
    'timestamp', now()
  );
BEGIN
  INSERT INTO data.attendance_device_pairing_codes (
    tenant_id, site_id, location_id, code_hash, expires_at
  ) VALUES (
    '10000000-0000-0000-0000-000000000001',
    v_site_id,
    v_location_id,
    v_code_hash,
    now() + interval '15 minutes'
  );

  SET LOCAL ROLE service_role;

  v_result := api.register_attendance_device(
    v_code,
    'st-geo-test-device',
    v_secret,
    v_pin,
    'Estació Geo Test',
    '{}'::jsonb
  );
  v_device_id := (v_result->>'device_id')::uuid;

  RESET ROLE;
  PERFORM set_config('request.jwt.claims',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  v_result := api.update_attendance_station(
    v_device_id,
    'Estació Geo Test',
    v_site_id,
    v_location_id,
    'active',
    ARRAY['manual']::text[],
    true,
    150
  );

  IF (v_result->>'geo_antifraud_enabled')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'expected geo_antifraud_enabled true, got %', v_result;
  END IF;

  RESET ROLE;
  SET LOCAL ROLE service_role;

  v_result := api.record_station_time_punch(
    v_device_id,
    v_employee_id,
    gen_random_uuid(),
    'in',
    NULL,
    'station',
    v_device_geo
  );

  IF (v_result->>'status') IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'geo punch not created: %', v_result;
  END IF;

  SELECT * INTO v_punch FROM data.time_punches WHERE id = (v_result->>'punch_id')::uuid;

  IF v_punch.geo_lat IS NOT NULL OR v_punch.geo_lng IS NOT NULL THEN
    RAISE EXCEPTION 'station punch must not store geo even with antifraud';
  END IF;

  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T9 geo antifraud within range punch ok geo NULL',
    'PASS',
    format('location=%s', v_punch.location_name_snapshot)
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO st_test_results VALUES ('ST-T9 geo antifraud within range punch ok geo NULL', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- ST-T10: geo enabled, probe far -> station_geo_out_of_range
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_device_id    uuid;
  v_employee_id  uuid := '40000000-0000-0000-0000-000000000006';
  v_err          text;
  v_far_geo      jsonb := jsonb_build_object(
    'latitude', 41.50000,
    'longitude', 2.50000,
    'accuracy_meters', 8,
    'timestamp', now()
  );
BEGIN
  SELECT id INTO v_device_id FROM data.attendance_devices WHERE device_public_id = 'st-geo-test-device' LIMIT 1;
  IF v_device_id IS NULL THEN
    RAISE EXCEPTION 'missing geo test device';
  END IF;

  SET LOCAL ROLE service_role;
  BEGIN
    PERFORM api.record_station_time_punch(
      v_device_id,
      v_employee_id,
      gen_random_uuid(),
      'out',
      NULL,
      'station',
      v_far_geo
    );
    RAISE EXCEPTION 'expected station_geo_out_of_range';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    IF v_err NOT LIKE '%station_geo_out_of_range%' THEN
      RAISE;
    END IF;
  END;

  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T10 geo antifraud far probe rejected',
    'PASS',
    v_err
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO st_test_results VALUES ('ST-T10 geo antifraud far probe rejected', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- ST-T11: admin audit logs after update + revoke (ST-8)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_code         text := 'STAUD001';
  v_code_hash    bytea := digest(data.normalize_attendance_pairing_code(v_code), 'sha256');
  v_device_id    uuid;
  v_secret       text := 'station-secret-audit-test-min!!';
  v_pin          text := '2468';
  v_site_id      uuid := '30000000-0000-0000-0000-000000000001';
  v_location_id  uuid := '41000000-0000-0000-0000-000000000002';
  v_result       jsonb;
  v_logs         jsonb;
  v_actions      text[];
BEGIN
  INSERT INTO data.attendance_device_pairing_codes (
    tenant_id, site_id, location_id, code_hash, expires_at, created_by
  ) VALUES (
    '10000000-0000-0000-0000-000000000001',
    v_site_id,
    v_location_id,
    v_code_hash,
    now() + interval '15 minutes',
    '20000000-0000-0000-0000-000000000002'
  );

  SET LOCAL ROLE service_role;

  v_result := api.register_attendance_device(
    v_code,
    'st-audit-test-device',
    v_secret,
    v_pin,
    'Estació Audit Test',
    '{}'::jsonb
  );
  v_device_id := (v_result->>'device_id')::uuid;

  RESET ROLE;
  PERFORM set_config('request.jwt.claims',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  v_result := api.update_attendance_station(
    v_device_id,
    'Estació Audit Test (editada)',
    v_site_id,
    v_location_id,
    'active'
  );

  IF (v_result->>'status') IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'update failed: %', v_result;
  END IF;

  v_result := api.revoke_attendance_station_secret(v_device_id);

  IF (v_result->>'secret_revoked')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'revoke failed: %', v_result;
  END IF;

  v_logs := api.list_attendance_station_admin_audit_logs(v_device_id, 50);

  SELECT array_agg(DISTINCT elem->>'action')
    INTO v_actions
  FROM jsonb_array_elements(v_logs) elem;

  IF NOT ('ATTENDANCE_STATION_REGISTERED' = ANY(COALESCE(v_actions, ARRAY[]::text[]))) THEN
    RAISE EXCEPTION 'missing ATTENDANCE_STATION_REGISTERED in %', v_actions;
  END IF;

  IF NOT ('ATTENDANCE_STATION_UPDATED' = ANY(COALESCE(v_actions, ARRAY[]::text[]))) THEN
    RAISE EXCEPTION 'missing ATTENDANCE_STATION_UPDATED in %', v_actions;
  END IF;

  IF NOT ('ATTENDANCE_STATION_SECRET_REVOKED' = ANY(COALESCE(v_actions, ARRAY[]::text[]))) THEN
    RAISE EXCEPTION 'missing ATTENDANCE_STATION_SECRET_REVOKED in %', v_actions;
  END IF;

  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T11 admin audit logs after update revoke',
    'PASS',
    format('%s actions', array_length(v_actions, 1))
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO st_test_results VALUES ('ST-T11 admin audit logs after update revoke', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- ST-T12: location assignments — scope filter, inheritance, punch enforcement
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_parent_loc    uuid := '41000000-0000-0000-0000-000000000001';
  v_child_loc     uuid := '41000000-0000-0000-0000-000000000002';
  v_assigned_emp  uuid := '40000000-0000-0000-0000-000000000005';
  v_unassigned    uuid := '40000000-0000-0000-0000-000000000006';
  v_device_id     uuid;
  v_payload       jsonb;
  v_count         int;
  v_site_count    int;
  v_err           text;
BEGIN
  DELETE FROM data.attendance_location_assignments
  WHERE location_id IN (v_parent_loc, v_child_loc);

  PERFORM set_config('request.jwt.claims',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  PERFORM api.add_attendance_location_assignment(v_parent_loc, v_assigned_emp);

  RESET ROLE;
  SET LOCAL ROLE service_role;

  IF NOT data.employee_can_punch_at_location(v_assigned_emp, v_child_loc) THEN
    RAISE EXCEPTION 'inheritance failed: parent assignment should allow child punch';
  END IF;

  IF data.employee_can_punch_at_location(v_unassigned, v_child_loc) THEN
    RAISE EXCEPTION 'unassigned employee should not punch at child location';
  END IF;

  IF NOT data.location_scope_has_attendance_assignments(v_child_loc) THEN
    RAISE EXCEPTION 'scope_has_assignments expected true for child with parent assignment';
  END IF;

  SELECT id INTO v_device_id
  FROM data.attendance_devices
  WHERE device_public_id = 'st-e2e-test-device'
  LIMIT 1;

  v_payload := api.list_attendance_station_employees(v_device_id);
  v_count := jsonb_array_length(COALESCE(v_payload->'employees', '[]'::jsonb));

  SELECT count(*)::int INTO v_site_count
  FROM data.employees e
  WHERE e.site_id = '30000000-0000-0000-0000-000000000001'
    AND e.status = 'active';

  IF (v_payload->>'assignment_mode') IS DISTINCT FROM 'zone' THEN
    RAISE EXCEPTION 'expected assignment_mode zone, got %', v_payload->>'assignment_mode';
  END IF;

  IF v_count >= v_site_count THEN
    RAISE EXCEPTION 'expected filtered employee list (< %), got %', v_site_count, v_count;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(COALESCE(v_payload->'employees', '[]'::jsonb)) elem
    WHERE (elem->>'employee_id')::uuid = v_assigned_emp
  ) THEN
    RAISE EXCEPTION 'assigned employee missing from station list';
  END IF;

  -- ST-18d: block when allow_unassigned_punch = false (strict)
  UPDATE data.attendance_devices
  SET allow_unassigned_punch = false
  WHERE id = v_device_id;

  BEGIN
    PERFORM api.record_station_time_punch(
      v_device_id, v_unassigned, gen_random_uuid(), 'in'
    );
    RAISE EXCEPTION 'expected employee_not_allowed_at_location for unassigned punch';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    IF v_err NOT LIKE '%employee_not_allowed_at_location%' THEN
      RAISE;
    END IF;
  END;

  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T12 location assignments filter inheritance punch',
    'PASS',
    format('zone mode, %s/%s employees, inheritance ok', v_count, v_site_count)
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T12 location assignments filter inheritance punch',
    'FAIL',
    SQLERRM
  );
END $$;

-- ---------------------------------------------------------------------------
-- ST-T13: station branding (display_title, display_logo_url, effective title)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_device_id uuid;
  v_device_name text;
  v_result jsonb;
  v_verify jsonb;
  v_secret text := 'station-secret-32chars-minimum!!';
BEGIN
  SELECT id, name
    INTO v_device_id, v_device_name
  FROM data.attendance_devices
  WHERE device_public_id = 'st-e2e-test-device'
  LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  v_result := api.update_attendance_station(
    v_device_id,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    'Totem Cuina',
    'https://example.com/station-logo.png'
  );

  IF (v_result->>'display_title') IS DISTINCT FROM 'Totem Cuina' THEN
    RAISE EXCEPTION 'display_title not saved: %', v_result->>'display_title';
  END IF;

  IF (v_result->>'effective_display_title') IS DISTINCT FROM 'Totem Cuina' THEN
    RAISE EXCEPTION 'effective_display_title mismatch: %', v_result->>'effective_display_title';
  END IF;

  RESET ROLE;
  SET LOCAL ROLE service_role;

  v_verify := api.verify_attendance_station_credentials('st-e2e-test-device', v_secret);

  IF (v_verify->>'display_logo_url') IS DISTINCT FROM 'https://example.com/station-logo.png' THEN
    RAISE EXCEPTION 'verify display_logo_url mismatch: %', v_verify->>'display_logo_url';
  END IF;

  IF (v_verify->>'effective_display_title') IS DISTINCT FROM 'Totem Cuina' THEN
    RAISE EXCEPTION 'verify effective_display_title mismatch';
  END IF;

  PERFORM set_config('request.jwt.claims',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  v_result := api.update_attendance_station(
    v_device_id,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    '',
    NULL
  );

  IF (v_result->>'effective_display_title') IS DISTINCT FROM v_device_name THEN
    RAISE EXCEPTION 'expected fallback to device name %, got %',
      v_device_name, v_result->>'effective_display_title';
  END IF;

  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T13 station branding title logo and fallback',
    'PASS',
    format('title=%s logo ok', v_result->>'effective_display_title')
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T13 station branding title logo and fallback',
    'FAIL',
    SQLERRM
  );
END $$;

-- ---------------------------------------------------------------------------
-- ST-T15: issue_attendance_identity_token rate limit (10/15min per employee)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_employee_id uuid := '40000000-0000-0000-0000-000000000010';
  v_i           int;
  v_err         text;
  v_events      int;
BEGIN
  SET LOCAL ROLE service_role;

  DELETE FROM data.station_register_rate_limits
  WHERE client_key = 'issue:employee:' || v_employee_id::text;

  DELETE FROM data.station_rate_limit_events
  WHERE bucket_type = 'identity_issue'
    AND employee_id = v_employee_id;

  FOR v_i IN 1..10 LOOP
    PERFORM api.issue_attendance_identity_token(v_employee_id, 'qr');
  END LOOP;

  BEGIN
    PERFORM api.issue_attendance_identity_token(v_employee_id, 'qr');
    RAISE EXCEPTION 'expected station_identity_issue_rate_limited on attempt 11';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    IF v_err NOT LIKE '%station_identity_issue_rate_limited%' THEN
      RAISE;
    END IF;
  END;

  PERFORM api.record_station_rate_limit_block(
    'identity_issue',
    'issue:employee:' || v_employee_id::text,
    11,
    10,
    15,
    '10000000-0000-0000-0000-000000000001',
    v_employee_id
  );

  SELECT count(*)::int
    INTO v_events
  FROM data.station_rate_limit_events
  WHERE bucket_type = 'identity_issue'
    AND employee_id = v_employee_id;

  IF v_events < 1 THEN
    RAISE EXCEPTION 'expected identity_issue metric event, got %', v_events;
  END IF;

  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T15 identity issue rate limit 10/15min',
    'PASS',
    format('%s; metrics=%s', v_err, v_events)
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T15 identity issue rate limit 10/15min',
    'FAIL',
    SQLERRM
  );
END $$;

-- ---------------------------------------------------------------------------
-- ST-T16: assert_station_identity_resolve_rate_limit (30/15min)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_i   int;
  v_err text;
  v_key text := 'resolve:test-rate-limit';
BEGIN
  SET LOCAL ROLE service_role;

  DELETE FROM data.station_register_rate_limits WHERE client_key = v_key;

  FOR v_i IN 1..30 LOOP
    PERFORM api.assert_station_identity_resolve_rate_limit(v_key, 30, 15);
  END LOOP;

  BEGIN
    PERFORM api.assert_station_identity_resolve_rate_limit(v_key, 30, 15);
    RAISE EXCEPTION 'expected rate limit on resolve attempt 31';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    IF v_err NOT LIKE '%station_identity_resolve_rate_limited%' THEN
      RAISE;
    END IF;
  END;

  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T16 identity resolve rate limit 30/15min',
    'PASS',
    v_err
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T16 identity resolve rate limit 30/15min',
    'FAIL',
    SQLERRM
  );
END $$;

-- ---------------------------------------------------------------------------
-- ST-T17: heartbeat touch + connectivity_status classifier
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_device_id uuid;
  v_seen      timestamptz;
  v_status    text;
  v_hb        jsonb;
BEGIN
  SELECT id INTO v_device_id
  FROM data.attendance_devices
  WHERE device_public_id = 'st-e2e-test-device';

  IF v_device_id IS NULL THEN
    RAISE EXCEPTION 'missing st-e2e-test-device from ST-T1';
  END IF;

  UPDATE data.attendance_devices SET last_seen_at = NULL WHERE id = v_device_id;

  v_status := data.station_connectivity_status(NULL, 'active');
  IF v_status IS DISTINCT FROM 'never_seen' THEN
    RAISE EXCEPTION 'expected never_seen, got %', v_status;
  END IF;

  SET LOCAL ROLE service_role;
  v_seen := data.touch_attendance_station_seen(v_device_id);
  v_status := data.station_connectivity_status(v_seen, 'active');
  IF v_status IS DISTINCT FROM 'online' THEN
    RAISE EXCEPTION 'expected online after touch, got %', v_status;
  END IF;

  v_status := data.station_connectivity_status(now() - interval '20 minutes', 'active');
  IF v_status IS DISTINCT FROM 'stale' THEN
    RAISE EXCEPTION 'expected stale at 20min, got %', v_status;
  END IF;

  v_status := data.station_connectivity_status(now() - interval '90 minutes', 'active');
  IF v_status IS DISTINCT FROM 'offline' THEN
    RAISE EXCEPTION 'expected offline at 90min, got %', v_status;
  END IF;

  v_status := data.station_connectivity_status(now(), 'pending');
  IF v_status IS DISTINCT FROM 'inactive' THEN
    RAISE EXCEPTION 'expected inactive for pending device, got %', v_status;
  END IF;

  v_hb := api.record_attendance_station_heartbeat(
    'st-e2e-test-device',
    'station-secret-32chars-minimum!!'
  );
  IF (v_hb->>'connectivity_status') IS DISTINCT FROM 'online' THEN
    RAISE EXCEPTION 'heartbeat expected online, got %', v_hb;
  END IF;
  IF (v_hb->>'last_seen_at') IS NULL THEN
    RAISE EXCEPTION 'heartbeat missing last_seen_at';
  END IF;

  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T17 heartbeat touch + connectivity classifier',
    'PASS',
    format('hb=%s', v_hb->>'connectivity_status')
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T17 heartbeat touch + connectivity classifier',
    'FAIL',
    SQLERRM
  );
END $$;

-- ---------------------------------------------------------------------------
-- ST-T18: punch_only_at_stations (ST-10) — portal blocked when resolved true
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_employee_id uuid := '40000000-0000-0000-0000-000000000010';
  v_tenant_id   uuid := '10000000-0000-0000-0000-000000000001';
  v_site_id     uuid := '30000000-0000-0000-0000-000000000001';
  v_err         text;
  v_today       jsonb;
  v_raw         text;
  v_updated     int;
BEGIN
  UPDATE data.employees SET punch_only_at_stations = NULL WHERE id = v_employee_id;
  UPDATE data.calendar_groups SET punch_only_at_stations = NULL
  WHERE id = '46000000-0000-0000-0000-000000000001';

  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb) || jsonb_build_object('punch_only_at_stations', true)
  WHERE id = v_tenant_id;
  GET DIAGNOSTICS v_updated = ROW_COUNT;

  SELECT settings->>'punch_only_at_stations'
    INTO v_raw
  FROM data.tenants
  WHERE id = v_tenant_id;

  IF v_updated <> 1 OR v_raw IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'tenant punch_only update failed: rows=% raw=%', v_updated, v_raw;
  END IF;

  IF NOT data.is_punch_only_at_stations(v_tenant_id, v_site_id) THEN
    RAISE EXCEPTION 'expected is_punch_only_at_stations true';
  END IF;

  IF NOT data.resolve_punch_only_at_stations(v_employee_id) THEN
    RAISE EXCEPTION 'expected resolve_punch_only_at_stations true from tenant';
  END IF;

  SET LOCAL ROLE service_role;

  BEGIN
    PERFORM data.assert_portal_mobile_punch_allowed(v_employee_id, 'portal');
    RAISE EXCEPTION 'st_t18_assert_not_blocked';
  EXCEPTION
    WHEN check_violation THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      IF v_err IS DISTINCT FROM 'punch_only_at_stations' THEN
        RAISE;
      END IF;
    WHEN OTHERS THEN
      RAISE;
  END;

  v_today := api.employee_portal_get_today(v_employee_id, v_tenant_id);
  IF COALESCE((v_today->>'punch_only_at_stations')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'expected punch_only_at_stations in portal today payload';
  END IF;

  PERFORM data.assert_portal_mobile_punch_allowed(v_employee_id, 'station');

  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T18 punch_only_at_stations portal blocked station ok',
    'PASS',
    format('portal_err=%s', v_err)
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T18 punch_only_at_stations portal blocked station ok',
    'FAIL',
    SQLERRM
  );
END $$;

-- ---------------------------------------------------------------------------
-- ST-T18b: ST-10b cascade group + employee overrides
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_employee_id uuid := '40000000-0000-0000-0000-000000000010';
  v_group_id    uuid := '46000000-0000-0000-0000-000000000001';
  v_tenant_id   uuid := '10000000-0000-0000-0000-000000000001';
BEGIN
  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb) || jsonb_build_object('punch_only_at_stations', true)
  WHERE id = v_tenant_id;

  UPDATE data.employees SET punch_only_at_stations = NULL WHERE id = v_employee_id;

  -- Group false overrides tenant true → portal allowed
  UPDATE data.calendar_groups SET punch_only_at_stations = false WHERE id = v_group_id;
  IF data.resolve_punch_only_at_stations(v_employee_id) IS NOT FALSE THEN
    RAISE EXCEPTION 'group false should allow portal';
  END IF;

  SET LOCAL ROLE service_role;
  PERFORM data.assert_portal_mobile_punch_allowed(v_employee_id, 'portal');
  RESET ROLE;

  -- Group true + employee false → portal allowed
  UPDATE data.calendar_groups SET punch_only_at_stations = true WHERE id = v_group_id;
  UPDATE data.employees SET punch_only_at_stations = false WHERE id = v_employee_id;
  IF data.resolve_punch_only_at_stations(v_employee_id) IS NOT FALSE THEN
    RAISE EXCEPTION 'employee false should allow portal';
  END IF;

  SET LOCAL ROLE service_role;
  PERFORM data.assert_portal_mobile_punch_allowed(v_employee_id, 'portal');
  RESET ROLE;

  -- Employee true → blocked even if group false
  UPDATE data.calendar_groups SET punch_only_at_stations = false WHERE id = v_group_id;
  UPDATE data.employees SET punch_only_at_stations = true WHERE id = v_employee_id;
  IF NOT data.resolve_punch_only_at_stations(v_employee_id) THEN
    RAISE EXCEPTION 'employee true should block portal';
  END IF;

  SET LOCAL ROLE service_role;
  BEGIN
    PERFORM data.assert_portal_mobile_punch_allowed(v_employee_id, 'portal');
    RAISE EXCEPTION 'st_t18b_employee_true_not_blocked';
  EXCEPTION
    WHEN check_violation THEN
      IF SQLERRM IS DISTINCT FROM 'punch_only_at_stations' THEN
        RAISE;
      END IF;
    WHEN OTHERS THEN
      RAISE;
  END;
  RESET ROLE;

  -- Cleanup for later tests in same txn
  UPDATE data.employees SET punch_only_at_stations = NULL WHERE id = v_employee_id;
  UPDATE data.calendar_groups SET punch_only_at_stations = NULL WHERE id = v_group_id;
  INSERT INTO st_test_results VALUES (
    'ST-T18b punch_only cascade group and employee',
    'PASS',
    'group false / employee false / employee true'
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T18b punch_only cascade group and employee',
    'FAIL',
    SQLERRM
  );
END $$;

-- ---------------------------------------------------------------------------
-- ST-T19: ST-18 core defaults + update entry_mode / session timers + verify
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_device_id uuid;
  v_result jsonb;
  v_verify jsonb;
  v_secret text := 'station-secret-32chars-minimum!!';
  v_entry text;
  v_idle int;
  v_countdown int;
BEGIN
  SELECT id INTO v_device_id
  FROM data.attendance_devices
  WHERE device_public_id = 'st-e2e-test-device'
  LIMIT 1;

  SELECT entry_mode, session_idle_seconds, session_return_countdown_seconds
    INTO v_entry, v_idle, v_countdown
  FROM data.attendance_devices
  WHERE id = v_device_id;

  -- New stations (ST-T1 register in this txn) inherit ST-18a default document_entry.
  IF v_entry NOT IN ('employee_list', 'document_entry') THEN
    RAISE EXCEPTION 'entry_mode unexpected: %', v_entry;
  END IF;
  IF v_idle IS DISTINCT FROM 60 THEN
    RAISE EXCEPTION 'default session_idle_seconds expected 60, got %', v_idle;
  END IF;
  IF v_countdown IS DISTINCT FROM 15 THEN
    RAISE EXCEPTION 'default session_return_countdown_seconds expected 15, got %', v_countdown;
  END IF;

  PERFORM set_config('request.jwt.claims',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  v_result := api.update_attendance_station(
    v_device_id,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    'document_entry',
    'search_first',
    NULL,
    NULL,
    'tap_name',
    'tap_name',
    90,
    20,
    false,
    30
  );

  IF (v_result->>'entry_mode') IS DISTINCT FROM 'document_entry' THEN
    RAISE EXCEPTION 'entry_mode not saved: %', v_result->>'entry_mode';
  END IF;
  IF (v_result->>'session_idle_seconds')::int IS DISTINCT FROM 90 THEN
    RAISE EXCEPTION 'session_idle_seconds not saved: %', v_result->>'session_idle_seconds';
  END IF;
  IF (v_result->>'session_return_countdown_seconds')::int IS DISTINCT FROM 20 THEN
    RAISE EXCEPTION 'countdown not saved: %', v_result->>'session_return_countdown_seconds';
  END IF;
  IF (v_result->>'session_allow_history')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 'session_allow_history not saved false';
  END IF;

  RESET ROLE;
  SET LOCAL ROLE service_role;

  v_verify := api.verify_attendance_station_credentials('st-e2e-test-device', v_secret);

  IF (v_verify->>'entry_mode') IS DISTINCT FROM 'document_entry' THEN
    RAISE EXCEPTION 'verify entry_mode mismatch: %', v_verify->>'entry_mode';
  END IF;
  IF (v_verify->>'employee_list_layout') IS DISTINCT FROM 'search_first' THEN
    RAISE EXCEPTION 'verify layout mismatch: %', v_verify->>'employee_list_layout';
  END IF;
  IF (v_verify->>'identity_confirm') IS DISTINCT FROM 'tap_name' THEN
    RAISE EXCEPTION 'verify identity_confirm mismatch';
  END IF;
  IF (v_verify->>'session_idle_seconds')::int IS DISTINCT FROM 90 THEN
    RAISE EXCEPTION 'verify idle mismatch';
  END IF;

  -- Restore MVP defaults for any later assertions in same txn
  PERFORM set_config('request.jwt.claims',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;
  PERFORM api.update_attendance_station(
    v_device_id,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    'employee_list',
    'compact',
    NULL,
    NULL,
    'tap_name',
    'none',
    60,
    15,
    false,
    90
  );
  RESET ROLE;

  INSERT INTO st_test_results VALUES (
    'ST-T19 ST-18 core config defaults and update',
    'PASS',
    'defaults + entry_mode/timers via update+verify'
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T19 ST-18 core config defaults and update',
    'FAIL',
    SQLERRM
  );
END $$;

-- ---------------------------------------------------------------------------
-- ST-T20: ST-18a document resolve (exact/suffix/ambiguous/not_found) + default
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_device_id uuid;
  v_emp_a uuid := '40000000-0000-0000-0000-000000000005';
  v_emp_b uuid := '40000000-0000-0000-0000-000000000006';
  v_doc_a text;
  v_doc_b text;
  v_result jsonb;
  v_default text;
BEGIN
  SELECT id INTO v_device_id
  FROM data.attendance_devices
  WHERE device_public_id = 'st-e2e-test-device'
  LIMIT 1;

  SELECT column_default INTO v_default
  FROM information_schema.columns
  WHERE table_schema = 'data'
    AND table_name = 'attendance_devices'
    AND column_name = 'entry_mode';

  IF v_default IS NULL OR v_default NOT LIKE '%document_entry%' THEN
    RAISE EXCEPTION 'new-station default entry_mode should be document_entry, got %', v_default;
  END IF;

  SELECT document_id INTO v_doc_a FROM data.employees WHERE id = v_emp_a;
  SELECT document_id INTO v_doc_b FROM data.employees WHERE id = v_emp_b;

  -- Site fallback so both same-site employees are eligible (ST-T12 may have left zone mode).
  DELETE FROM data.attendance_location_assignments
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001';

  UPDATE data.employees
  SET document_id = 'ST18A-1111X'
  WHERE id = v_emp_a;

  UPDATE data.employees
  SET document_id = 'ST18A-2222Y'
  WHERE id = v_emp_b;

  UPDATE data.attendance_devices
  SET document_match = 'exact',
      document_suffix_length = 4
  WHERE id = v_device_id;

  SET LOCAL ROLE service_role;
  v_result := api.resolve_attendance_station_employee_document(v_device_id, 'st18a-1111x');
  RESET ROLE;

  IF (v_result->>'status') IS DISTINCT FROM 'matched' THEN
    RAISE EXCEPTION 'exact match expected, got %', v_result;
  END IF;
  IF (v_result->>'employee_id')::uuid IS DISTINCT FROM v_emp_a THEN
    RAISE EXCEPTION 'exact match wrong employee';
  END IF;

  SET LOCAL ROLE service_role;
  v_result := api.resolve_attendance_station_employee_document(v_device_id, 'ZZZNOEXIST999');
  RESET ROLE;

  IF (v_result->>'status') IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'miss should be not_found, got %', v_result->>'status';
  END IF;

  UPDATE data.attendance_devices
  SET document_match = 'suffix',
      document_suffix_length = 4
  WHERE id = v_device_id;

  SET LOCAL ROLE service_role;
  v_result := api.resolve_attendance_station_employee_document(v_device_id, '111x');
  RESET ROLE;

  IF (v_result->>'status') IS DISTINCT FROM 'matched' THEN
    RAISE EXCEPTION 'suffix match expected, got %', v_result;
  END IF;

  -- Collision: same suffix for two employees
  UPDATE data.employees SET document_id = 'ST18A-AAAAZ' WHERE id = v_emp_a;
  UPDATE data.employees SET document_id = 'ST18B-AAAAZ' WHERE id = v_emp_b;

  SET LOCAL ROLE service_role;
  v_result := api.resolve_attendance_station_employee_document(v_device_id, 'aaaz');
  RESET ROLE;

  IF (v_result->>'status') IS DISTINCT FROM 'ambiguous' THEN
    RAISE EXCEPTION 'suffix collision expected ambiguous, got %', v_result;
  END IF;
  IF jsonb_array_length(v_result->'matches') < 2 THEN
    RAISE EXCEPTION 'ambiguous should list >=2 matches';
  END IF;

  SET LOCAL ROLE service_role;
  PERFORM api.assert_station_document_resolve_rate_limit('st-t20-doc-limit', 2, 15);
  PERFORM api.assert_station_document_resolve_rate_limit('st-t20-doc-limit', 2, 15);
  BEGIN
    PERFORM api.assert_station_document_resolve_rate_limit('st-t20-doc-limit', 2, 15);
    RAISE EXCEPTION 'expected station_document_resolve_rate_limited';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%station_document_resolve_rate_limited%' THEN
        RAISE;
      END IF;
  END;
  RESET ROLE;

  -- Restore docs for later tests in same txn
  UPDATE data.employees SET document_id = v_doc_a WHERE id = v_emp_a;
  UPDATE data.employees SET document_id = v_doc_b WHERE id = v_emp_b;
  UPDATE data.attendance_devices
  SET document_match = 'suffix',
      document_suffix_length = 4
  WHERE id = v_device_id;

  INSERT INTO st_test_results VALUES (
    'ST-T20 ST-18a document resolve anti-enumeration',
    'PASS',
    'exact/suffix/ambiguous/not_found + rate limit'
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T20 ST-18a document resolve anti-enumeration',
    'FAIL',
    SQLERRM
  );
END $$;

-- ---------------------------------------------------------------------------
-- ST-T21: EX-02.4 station employee PIN challenge (portal hash + device lockout)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_device_id uuid;
  v_employee_id uuid := '40000000-0000-0000-0000-000000000005';
  v_tenant_id uuid := '10000000-0000-0000-0000-000000000001';
  v_token_id uuid := 'a6000000-0000-0000-0000-000000000021';
  v_result jsonb;
  v_pin text := '2468';
  v_i int;
BEGIN
  SELECT id INTO v_device_id
  FROM data.attendance_devices
  WHERE device_public_id = 'st-e2e-test-device'
  LIMIT 1;

  DELETE FROM data.attendance_location_assignments
  WHERE tenant_id = v_tenant_id;

  DELETE FROM data.station_employee_pin_challenges
  WHERE device_id = v_device_id AND employee_id = v_employee_id;

  -- Reuse the employee's unique active portal token (constraint: one active/employee).
  UPDATE data.employee_portal_tokens
  SET pin_hash = data.hash_employee_portal_pin(v_pin),
      pin_must_set = false,
      pin_attempts = 0,
      pin_locked_until = NULL,
      is_active = true,
      revoked_at = NULL
  WHERE employee_id = v_employee_id
    AND tenant_id = v_tenant_id
    AND is_active
    AND revoked_at IS NULL;

  IF NOT FOUND THEN
    INSERT INTO data.employee_portal_tokens (
      id, tenant_id, employee_id, token_hash, is_active,
      pin_hash, pin_must_set, pin_attempts, pin_locked_until
    ) VALUES (
      v_token_id,
      v_tenant_id,
      v_employee_id,
      decode(repeat('ab', 16), 'hex'),
      true,
      data.hash_employee_portal_pin(v_pin),
      false,
      0,
      NULL
    );
  END IF;

  SET LOCAL ROLE service_role;

  v_result := api.verify_attendance_station_employee_pin(v_device_id, v_employee_id, v_pin);
  IF (v_result->>'status') IS DISTINCT FROM 'ok' THEN
    RAISE EXCEPTION 'expected ok for correct PIN, got %', v_result;
  END IF;

  v_result := api.verify_attendance_station_employee_pin(v_device_id, v_employee_id, '0000');
  IF (v_result->>'status') IS DISTINCT FROM 'invalid' THEN
    RAISE EXCEPTION 'expected invalid for wrong PIN, got %', v_result;
  END IF;

  FOR v_i IN 1..4 LOOP
    v_result := api.verify_attendance_station_employee_pin(v_device_id, v_employee_id, '0000');
  END LOOP;

  IF (v_result->>'status') IS DISTINCT FROM 'locked' THEN
    RAISE EXCEPTION 'expected locked after 5 fails, got %', v_result;
  END IF;

  v_result := api.verify_attendance_station_employee_pin(v_device_id, v_employee_id, v_pin);
  IF (v_result->>'status') IS DISTINCT FROM 'locked' THEN
    RAISE EXCEPTION 'correct PIN must stay locked during lockout, got %', v_result;
  END IF;

  RESET ROLE;

  -- Clear lockout and confirm recovery
  UPDATE data.station_employee_pin_challenges
  SET pin_attempts = 0, locked_until = NULL
  WHERE device_id = v_device_id AND employee_id = v_employee_id;

  SET LOCAL ROLE service_role;
  v_result := api.verify_attendance_station_employee_pin(v_device_id, v_employee_id, v_pin);
  RESET ROLE;
  IF (v_result->>'status') IS DISTINCT FROM 'ok' THEN
    RAISE EXCEPTION 'expected ok after unlock, got %', v_result;
  END IF;

  -- no_pin when token has no pin
  UPDATE data.employee_portal_tokens
  SET pin_hash = NULL, pin_must_set = true
  WHERE employee_id = v_employee_id
    AND tenant_id = v_tenant_id
    AND is_active;

  SET LOCAL ROLE service_role;
  v_result := api.verify_attendance_station_employee_pin(v_device_id, v_employee_id, v_pin);
  RESET ROLE;
  IF (v_result->>'status') IS DISTINCT FROM 'no_pin' THEN
    RAISE EXCEPTION 'expected no_pin, got %', v_result;
  END IF;

  -- Restore token pin clearing from test
  UPDATE data.employee_portal_tokens
  SET pin_hash = NULL, pin_must_set = false, pin_attempts = 0, pin_locked_until = NULL
  WHERE employee_id = v_employee_id
    AND tenant_id = v_tenant_id
    AND is_active;

  DELETE FROM data.employee_portal_tokens WHERE id = v_token_id;
  DELETE FROM data.station_employee_pin_challenges
  WHERE device_id = v_device_id AND employee_id = v_employee_id;

  INSERT INTO st_test_results VALUES (
    'ST-T21 station employee PIN challenge lockout',
    'PASS',
    'ok/invalid/locked/no_pin'
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T21 station employee PIN challenge lockout',
    'FAIL',
    SQLERRM
  );
END $$;

-- ---------------------------------------------------------------------------
-- ST-T22: EX-02.6 / ST-18e station employee history (disabled / range / data)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_device_id uuid;
  v_employee_id uuid := '40000000-0000-0000-0000-000000000005';
  v_tenant_id uuid := '10000000-0000-0000-0000-000000000001';
  v_site_id uuid := '30000000-0000-0000-0000-000000000001';
  v_result jsonb;
  v_allow boolean;
  v_raised boolean;
BEGIN
  SELECT id INTO v_device_id
  FROM data.attendance_devices
  WHERE device_public_id = 'st-e2e-test-device'
  LIMIT 1;

  SELECT session_allow_history INTO v_allow
  FROM data.attendance_devices
  WHERE id = v_device_id;

  IF v_allow IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'PG-08 default session_allow_history expected false, got %', v_allow;
  END IF;

  SET LOCAL ROLE service_role;

  v_raised := false;
  BEGIN
    PERFORM api.get_attendance_station_employee_history(
      v_device_id,
      v_employee_id,
      current_date - 6,
      current_date
    );
  EXCEPTION WHEN check_violation THEN
    IF SQLERRM LIKE '%station_history_disabled%' THEN
      v_raised := true;
    ELSE
      RAISE;
    END IF;
  END;
  IF NOT v_raised THEN
    RAISE EXCEPTION 'expected station_history_disabled when allow_history=false';
  END IF;

  RESET ROLE;

  UPDATE data.attendance_devices
  SET session_allow_history = true,
      session_history_max_days = 14
  WHERE id = v_device_id;

  DELETE FROM data.attendance_location_assignments
  WHERE tenant_id = v_tenant_id;

  INSERT INTO data.time_punches (
    tenant_id, site_id, employee_id, client_op_id, punch_type,
    occurred_at, received_at, source, location_permission, anomaly_codes
  ) VALUES (
    v_tenant_id,
    v_site_id,
    v_employee_id,
    gen_random_uuid(),
    'in',
    now() - interval '2 hours',
    now(),
    'station',
    'notrequired',
    ARRAY[]::text[]
  );

  SET LOCAL ROLE service_role;

  v_result := api.get_attendance_station_employee_history(
    v_device_id,
    v_employee_id,
    current_date - 6,
    current_date
  );

  IF (v_result->>'employee_id') IS DISTINCT FROM v_employee_id::text THEN
    RAISE EXCEPTION 'history employee_id mismatch: %', v_result;
  END IF;
  IF jsonb_array_length(v_result->'punches') < 1 THEN
    RAISE EXCEPTION 'expected at least one punch in history, got %', v_result->'punches';
  END IF;
  IF (v_result->>'max_days')::int IS DISTINCT FROM 14 THEN
    RAISE EXCEPTION 'expected max_days 14, got %', v_result->>'max_days';
  END IF;

  v_raised := false;
  BEGIN
    PERFORM api.get_attendance_station_employee_history(
      v_device_id,
      v_employee_id,
      current_date - 30,
      current_date
    );
  EXCEPTION WHEN check_violation THEN
    IF SQLERRM LIKE '%station_history_range_too_large%' THEN
      v_raised := true;
    ELSE
      RAISE;
    END IF;
  END;
  IF NOT v_raised THEN
    RAISE EXCEPTION 'expected station_history_range_too_large for 31-day span with max 14';
  END IF;

  RESET ROLE;

  UPDATE data.attendance_devices
  SET session_allow_history = false,
      session_history_max_days = 90
  WHERE id = v_device_id;

  INSERT INTO st_test_results VALUES (
    'ST-T22 station employee history ST-18e',
    'PASS',
    'disabled/default + range + punches'
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T22 station employee history ST-18e',
    'FAIL',
    SQLERRM
  );
END $$;

-- ---------------------------------------------------------------------------
-- ST-T23: EX-02.7 presets + unsafe combo rejection + privacy fields
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_device_id uuid;
  v_result jsonb;
  v_raised boolean;
BEGIN
  SELECT id INTO v_device_id
  FROM data.attendance_devices
  WHERE device_public_id = 'st-e2e-test-device'
  LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  v_result := api.update_attendance_station(
    v_device_id,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL,
    'estricte',
    NULL,
    NULL
  );

  IF (v_result->>'ux_preset') IS DISTINCT FROM 'estricte' THEN
    RAISE EXCEPTION 'preset estricte not saved: %', v_result->>'ux_preset';
  END IF;
  IF (v_result->>'entry_mode') IS DISTINCT FROM 'document_entry' THEN
    RAISE EXCEPTION 'estricte entry_mode expected document_entry';
  END IF;
  IF (v_result->>'identity_confirm') IS DISTINCT FROM 'tap_name' THEN
    RAISE EXCEPTION 'estricte identity_confirm expected tap_name';
  END IF;
  IF (v_result->>'mask_names_on_waiting')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'estricte should mask names';
  END IF;
  IF (v_result->>'waiting_idle_seconds')::int IS DISTINCT FROM 90 THEN
    RAISE EXCEPTION 'estricte waiting_idle expected 90, got %', v_result->>'waiting_idle_seconds';
  END IF;
  IF (v_result->>'session_allow_history')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 'estricte should disable history';
  END IF;

  v_result := api.update_attendance_station(
    v_device_id,
    NULL, NULL, NULL, NULL, ARRAY['qr']::text[], NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL,
    'qr',
    NULL,
    NULL
  );
  IF (v_result->>'ux_preset') IS DISTINCT FROM 'qr' THEN
    RAISE EXCEPTION 'preset qr not saved';
  END IF;
  IF NOT ((v_result->'allowed_methods') @> '["qr"]'::jsonb)
     OR jsonb_array_length(v_result->'allowed_methods') <> 1 THEN
    RAISE EXCEPTION 'qr preset should force allowed_methods=[qr], got %', v_result->'allowed_methods';
  END IF;

  v_raised := false;
  BEGIN
    PERFORM api.update_attendance_station(
      v_device_id,
      NULL, NULL, NULL, NULL, ARRAY['manual']::text[], NULL, NULL, NULL, NULL,
      'employee_list',
      NULL, NULL, NULL,
      'none',
      NULL, NULL, NULL, NULL, NULL,
      NULL, NULL, NULL, NULL,
      'custom',
      0,
      false
    );
  EXCEPTION WHEN check_violation THEN
    IF SQLERRM LIKE '%unsafe_station_config%' THEN
      v_raised := true;
    ELSE
      RAISE;
    END IF;
  END;
  IF NOT v_raised THEN
    RAISE EXCEPTION 'expected unsafe_station_config for employee_list + identity none';
  END IF;

  -- Restore safe custom baseline for later tests
  PERFORM api.update_attendance_station(
    v_device_id,
    NULL, NULL, NULL, NULL, ARRAY['manual']::text[], NULL, NULL, NULL, NULL,
    'employee_list',
    'compact',
    NULL, NULL,
    'tap_name',
    'none',
    60, 15, false, 90,
    NULL, NULL, NULL, NULL,
    'custom',
    0,
    false
  );

  RESET ROLE;

  INSERT INTO st_test_results VALUES (
    'ST-T23 station UX presets and unsafe combo',
    'PASS',
    'estricte/qr + unsafe rejected'
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO st_test_results VALUES (
    'ST-T23 station UX presets and unsafe combo',
    'FAIL',
    SQLERRM
  );
END $$;

-- ---------------------------------------------------------------------------
-- ST-T14: site timezone (Atlantic/Canary) drives work_date boundaries
-- Uses a fixed historical timestamp so earlier tests' punches today do not interfere.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_employee_id uuid := '40000000-0000-0000-0000-000000000010';
  v_site_id     uuid := '30000000-0000-0000-0000-000000000001';
  v_punch_ts    timestamptz := timestamptz '2025-12-15 23:45:00+00';
  v_work_date   date := '2025-12-15'::date;
  v_state_canary text;
  v_state_madrid_date text;
BEGIN
  UPDATE data.sites
  SET settings = jsonb_set(COALESCE(settings, '{}'::jsonb), '{site_timezone}', '"Atlantic/Canary"')
  WHERE id = v_site_id;

  INSERT INTO data.time_punches (
    tenant_id, site_id, employee_id, client_op_id, punch_type,
    occurred_at, received_at, source, location_permission, anomaly_codes
  ) VALUES (
    '10000000-0000-0000-0000-000000000001',
    v_site_id,
    v_employee_id,
    gen_random_uuid(),
    'in',
    v_punch_ts,
    now(),
    'station',
    'notrequired',
    ARRAY[]::text[]
  );

  -- 23:45 UTC = 2025-12-15 in Canary, 2025-12-16 in Madrid
  v_state_canary := data.compute_employee_punch_day_state(v_employee_id, v_work_date);
  IF v_state_canary IS DISTINCT FROM 'work' THEN
    RAISE EXCEPTION 'expected work on Canary %, got %', v_work_date, v_state_canary;
  END IF;

  v_state_madrid_date := data.compute_employee_punch_day_state(v_employee_id, '2025-12-16'::date);
  IF v_state_madrid_date IS DISTINCT FROM 'off' THEN
    RAISE EXCEPTION 'Canary site should not count punch on Madrid date 2025-12-16, got %',
      v_state_madrid_date;
  END IF;

  INSERT INTO st_test_results VALUES (
    'ST-T14 site timezone work_date boundary',
    'PASS',
    'Atlantic/Canary vs Madrid midnight boundary'
  );
EXCEPTION WHEN OTHERS THEN
  INSERT INTO st_test_results VALUES (
    'ST-T14 site timezone work_date boundary',
    'FAIL',
    SQLERRM
  );
END $$;

SELECT test_name, status, details FROM st_test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM st_test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION '% attendance station test(s) FAILED', v_fail;
  END IF;
  RAISE NOTICE 'All attendance station tests PASSED';
END $$;

ROLLBACK;
