-- =============================================================================
-- attendance_station_qr_hardening_st11_tests.sql
-- ST-11 — Entropia mínima + rate limit dins resolve_attendance_identity_token
-- =============================================================================

BEGIN;

CREATE TEMP TABLE st11_results (test_name text, status text, details text) ON COMMIT DROP;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0110000-0000-0000-0000-000000000001', 'ST11 Tenant', 'st11-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b0110000-0000-0000-0000-000000000001', 'a0110000-0000-0000-0000-000000000001', 'ST11 Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.locations (id, tenant_id, site_id, name, type, status)
VALUES (
  'c0110000-0000-0000-0000-000000000001',
  'a0110000-0000-0000-0000-000000000001',
  'b0110000-0000-0000-0000-000000000001',
  'ST11 Loc', 'zone', 'active'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, full_name, status)
VALUES (
  'd0110000-0000-0000-0000-000000000001',
  'a0110000-0000-0000-0000-000000000001',
  'b0110000-0000-0000-0000-000000000001',
  'Emp ST11', 'active'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.attendance_devices (
  id, tenant_id, site_id, location_id, name, type, status,
  device_public_id, device_secret_hash, local_pin_hash, allowed_methods
)
VALUES (
  'e0110000-0000-0000-0000-000000000001',
  'a0110000-0000-0000-0000-000000000001',
  'b0110000-0000-0000-0000-000000000001',
  'c0110000-0000-0000-0000-000000000001',
  'ST11 Station',
  'station',
  'active',
  'st11-device-public',
  data.hash_attendance_device_secret('station-secret-st11-32chars!!!!!!'),
  data.hash_attendance_station_pin('4321'),
  ARRAY['qr','manual']::text[]
)
ON CONFLICT (id) DO UPDATE SET
  status = EXCLUDED.status,
  allowed_methods = EXCLUDED.allowed_methods,
  location_id = EXCLUDED.location_id,
  site_id = EXCLUDED.site_id,
  device_secret_hash = EXCLUDED.device_secret_hash,
  local_pin_hash = EXCLUDED.local_pin_hash;

-- T1 constants + builder length
DO $$
DECLARE
  v_len int;
  v_raw text;
BEGIN
  v_raw := data.build_attendance_identity_token_raw();
  v_len := char_length(v_raw);
  IF data.attendance_identity_token_entropy_bytes() = 32
     AND data.attendance_identity_token_min_raw_length() = 43
     AND v_len >= 43
     AND v_raw ~ '^[A-Za-z0-9_-]+$' THEN
    INSERT INTO st11_results VALUES ('T1 builder_entropy', 'PASS', format('len=%s', v_len));
  ELSE
    INSERT INTO st11_results VALUES ('T1 builder_entropy', 'FAIL', format('len=%s raw=%s', v_len, v_raw));
  END IF;
END;
$$;

-- T2 assert rejects short token
DO $$
BEGIN
  BEGIN
    PERFORM data.assert_attendance_identity_token_entropy('short');
    INSERT INTO st11_results VALUES ('T2 reject_short', 'FAIL', 'expected exception');
  EXCEPTION WHEN others THEN
    IF SQLERRM LIKE '%identity_token_entropy_too_low%' THEN
      INSERT INTO st11_results VALUES ('T2 reject_short', 'PASS', SQLERRM);
    ELSE
      INSERT INTO st11_results VALUES ('T2 reject_short', 'FAIL', SQLERRM);
    END IF;
  END;
END;
$$;

-- T3 issue returns entropy_bytes + long enough token
DO $$
DECLARE
  v jsonb;
BEGIN
  SET LOCAL ROLE service_role;
  -- neteja buckets d'issue previs d'aquest empleat
  DELETE FROM data.station_register_rate_limits
  WHERE client_key = 'issue:employee:d0110000-0000-0000-0000-000000000001';

  v := api.issue_attendance_identity_token('d0110000-0000-0000-0000-000000000001'::uuid, 'qr');
  RESET ROLE;

  IF (v->>'entropy_bytes')::int = 32
     AND char_length(v->>'token') >= 43 THEN
    INSERT INTO st11_results VALUES ('T3 issue_entropy_meta', 'PASS', v->>'token');
  ELSE
    INSERT INTO st11_results VALUES ('T3 issue_entropy_meta', 'FAIL', v::text);
  END IF;
END;
$$;

-- T4 resolve rejects short token (after rate-limit slot)
DO $$
DECLARE
  v_key text := 'st11-entropy-key';
  v_err text;
BEGIN
  DELETE FROM data.station_register_rate_limits WHERE client_key = v_key;
  SET LOCAL ROLE service_role;
  BEGIN
    PERFORM api.resolve_attendance_identity_token(
      'tooshort',
      'st11-device-public',
      v_key
    );
    v_err := NULL;
  EXCEPTION WHEN others THEN
    v_err := SQLERRM;
  END;
  RESET ROLE;

  IF v_err LIKE '%identity_token_entropy_too_low%' THEN
    INSERT INTO st11_results VALUES ('T4 resolve_short', 'PASS', v_err);
  ELSIF v_err IS NULL THEN
    INSERT INTO st11_results VALUES ('T4 resolve_short', 'FAIL', 'expected exception');
  ELSE
    INSERT INTO st11_results VALUES ('T4 resolve_short', 'FAIL', v_err);
  END IF;
END;
$$;

-- T5 resolve rate limit assert (3/window)
DO $$
DECLARE
  v_key text := 'st11-rl-resolve';
  v_i int;
  v_err text;
  v_early text;
BEGIN
  DELETE FROM data.station_register_rate_limits WHERE client_key = v_key;

  SET LOCAL ROLE service_role;
  FOR v_i IN 1..3 LOOP
    BEGIN
      PERFORM api.assert_station_identity_resolve_rate_limit(v_key, 3, 15);
    EXCEPTION WHEN others THEN
      v_early := format('blocked early at %s: %s', v_i, SQLERRM);
      EXIT;
    END;
  END LOOP;

  IF v_early IS NULL THEN
    BEGIN
      PERFORM api.assert_station_identity_resolve_rate_limit(v_key, 3, 15);
    EXCEPTION WHEN others THEN
      v_err := SQLERRM;
    END;
  END IF;
  RESET ROLE;

  IF v_early IS NOT NULL THEN
    INSERT INTO st11_results VALUES ('T5 resolve_rl_rpc', 'FAIL', v_early);
  ELSIF v_err LIKE '%station_identity_resolve_rate_limited%' THEN
    INSERT INTO st11_results VALUES ('T5 resolve_rl_rpc', 'PASS', v_err);
  ELSE
    INSERT INTO st11_results VALUES ('T5 resolve_rl_rpc', 'FAIL', COALESCE(v_err, 'expected rate limit'));
  END IF;
END;
$$;

-- T5b: resolve RPC wires rate limit (RL before entropy)
DO $$
DECLARE
  v_key text := 'st11-rl-via-resolve';
  v_i int;
  v_err text;
  v_pad text := rpad('Aa0_', 43, 'x'); -- longitud vàlida; hash inexistent
BEGIN
  DELETE FROM data.station_register_rate_limits WHERE client_key = v_key;
  SET LOCAL ROLE service_role;

  -- Omple el bucket al límit per defecte del resolve (30/15min)
  FOR v_i IN 1..30 LOOP
    PERFORM api.assert_station_identity_resolve_rate_limit(v_key, 30, 15);
  END LOOP;

  BEGIN
    -- 31è intent: ha de fallar per RL abans d'entropia/lookup
    PERFORM api.resolve_attendance_identity_token(v_pad, 'st11-device-public', v_key);
  EXCEPTION WHEN others THEN
    v_err := SQLERRM;
  END;
  RESET ROLE;

  IF v_err LIKE '%station_identity_resolve_rate_limited%' THEN
    INSERT INTO st11_results VALUES ('T5b resolve_rpc_wires_rl', 'PASS', v_err);
  ELSIF v_err LIKE '%identity_token%' THEN
    INSERT INTO st11_results VALUES ('T5b resolve_rpc_wires_rl', 'FAIL',
      'token path before RL: ' || v_err);
  ELSE
    INSERT INTO st11_results VALUES ('T5b resolve_rpc_wires_rl', 'FAIL', COALESCE(v_err, 'no exception'));
  END IF;
END;
$$;

-- T6 happy path resolve with issued token
DO $$
DECLARE
  v_token text;
  v jsonb;
  v_key text := 'st11-happy';
BEGIN
  DELETE FROM data.station_register_rate_limits WHERE client_key = v_key;
  SET LOCAL ROLE service_role;
  v_token := (api.issue_attendance_identity_token(
    'd0110000-0000-0000-0000-000000000001'::uuid, 'qr'
  ))->>'token';
  v := api.resolve_attendance_identity_token(v_token, 'st11-device-public', v_key);
  RESET ROLE;

  IF (v->>'employee_id') = 'd0110000-0000-0000-0000-000000000001' THEN
    INSERT INTO st11_results VALUES ('T6 resolve_ok', 'PASS', v->>'full_name');
  ELSE
    INSERT INTO st11_results VALUES ('T6 resolve_ok', 'FAIL', v::text);
  END IF;
END;
$$;

SELECT test_name, status, details FROM st11_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM st11_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'ST-11 tests failed: %', v_fail;
  END IF;
END;
$$;

ROLLBACK;
