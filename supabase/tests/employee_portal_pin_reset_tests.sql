-- =============================================================================
-- employee_portal_pin_reset_tests.sql — EP-ACC-4b
-- =============================================================================

BEGIN;

CREATE TEMP TABLE ep_pin_reset_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('b1000000-0000-0000-0000-000000000001', 'EP Pin Reset Tenant', 'ep-pin-reset', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b2000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', 'EP Pin Reset Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES ('b3000000-0000-0000-0000-000000000001', 'ep-pin-reset-mgr@test.com', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES ('b3000000-0000-0000-0000-000000000001', 'ep-pin-reset-mgr@test.com', 'EP Pin Reset Manager')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES (
  'b4000000-0000-0000-0000-000000000001',
  'b1000000-0000-0000-0000-000000000001',
  'b3000000-0000-0000-0000-000000000001',
  'manager',
  true
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES (
  'b5000000-0000-0000-0000-000000000001',
  'b1000000-0000-0000-0000-000000000001',
  'b2000000-0000-0000-0000-000000000001',
  NULL,
  'EP Pin Reset Employee',
  'active'
)
ON CONFLICT (id) DO NOTHING;

-- Setup portal token with PIN
DO $$
DECLARE
  v_token_id uuid;
  v_portal_hash bytea := decode('112233445566778899aabbccddeeff00112233445566778899aabbccdd', 'hex');
  v_reset_hash bytea := decode('2233445566778899aabbccddeeff00112233445566778899aabbccddeeff', 'hex');
  v_reset_hash2 bytea := decode('33445566778899aabbccddeeff00112233445566778899aabbccddeeff0011', 'hex');
  v_result jsonb;
  v_lookup jsonb;
  v_consume jsonb;
  v_session_version int;
  v_pin_set_by text;
  v_pin_attempts int;
  v_pending_hash bytea := decode('445566778899aabbccddeeff00112233445566778899aabbccddeeff001122', 'hex');
  v_pending_hash2 bytea := decode('5566778899aabbccddeeff00112233445566778899aabbccddeeff00112233', 'hex');
BEGIN
  PERFORM set_config(
    'request.jwt.claims',
    '{"sub":"b3000000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"b1000000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"b1000000-0000-0000-0000-000000000001":{"global_permissions":["attendance.manage"],"sites":{}}}}}',
    true
  );
  SET LOCAL ROLE authenticated;

  v_result := api.create_employee_portal_token(
    p_employee_id => 'b5000000-0000-0000-0000-000000000001',
    p_token_hash  => v_portal_hash,
    p_pin_hash    => 'sha256:existingpinhash',
    p_pin_must_set => false
  );
  v_token_id := (v_result ->> 'token_id')::uuid;

  UPDATE data.employee_portal_tokens
  SET pin_attempts = 3,
      pin_locked_until = now() + interval '10 minutes'
  WHERE id = v_token_id;

  v_result := api.create_employee_portal_pin_reset(
    p_employee_portal_token_id => v_token_id,
    p_reset_token_hash => v_reset_hash
  );

  SET LOCAL ROLE postgres;

  IF (v_result ->> 'reset_id') IS NULL THEN
    INSERT INTO ep_pin_reset_results VALUES ('EP4b-T1 create reset', 'FAIL', 'missing reset_id');
  ELSE
    INSERT INTO ep_pin_reset_results VALUES ('EP4b-T1 create reset', 'PASS', v_result ->> 'reset_id');
  END IF;

  v_lookup := api.lookup_employee_portal_pin_reset_by_hash(
    encode(v_reset_hash, 'hex')
  );

  IF COALESCE(v_lookup ->> 'status', '') = 'valid' THEN
    INSERT INTO ep_pin_reset_results VALUES ('EP4b-T2 lookup valid', 'PASS', v_lookup ->> 'employee_name');
  ELSE
    INSERT INTO ep_pin_reset_results VALUES ('EP4b-T2 lookup valid', 'FAIL', COALESCE(v_lookup ->> 'status', 'null'));
  END IF;

  v_consume := api.employee_portal_consume_pin_reset(
    encode(v_reset_hash, 'hex'),
    'sha256:newpinhash'
  );

  IF COALESCE(v_consume ->> 'status', '') = 'ok' THEN
    INSERT INTO ep_pin_reset_results VALUES ('EP4b-T3 consume once', 'PASS', v_consume ->> 'employee_name');
  ELSE
    INSERT INTO ep_pin_reset_results VALUES ('EP4b-T3 consume once', 'FAIL', COALESCE(v_consume ->> 'status', 'null'));
  END IF;

  SELECT session_version, pin_set_by, pin_attempts
  INTO v_session_version, v_pin_set_by, v_pin_attempts
  FROM data.employee_portal_tokens
  WHERE id = v_token_id;

  IF v_pin_set_by = 'reset'
     AND v_session_version >= 2
     AND v_pin_attempts = 0
     AND (SELECT pin_locked_until FROM data.employee_portal_tokens WHERE id = v_token_id) IS NULL THEN
    INSERT INTO ep_pin_reset_results VALUES ('EP4b-T4 lockout cleared + session_version', 'PASS', v_session_version::text);
  ELSE
    INSERT INTO ep_pin_reset_results VALUES ('EP4b-T4 lockout cleared + session_version', 'FAIL', v_pin_set_by);
  END IF;

  v_consume := api.employee_portal_consume_pin_reset(
    encode(v_reset_hash, 'hex'),
    'sha256:anotherpin'
  );

  IF COALESCE(v_consume ->> 'status', '') = 'used' THEN
    INSERT INTO ep_pin_reset_results VALUES ('EP4b-T5 second consume blocked', 'PASS', 'used');
  ELSE
    INSERT INTO ep_pin_reset_results VALUES ('EP4b-T5 second consume blocked', 'FAIL', COALESCE(v_consume ->> 'status', 'null'));
  END IF;

  PERFORM set_config(
    'request.jwt.claims',
    '{"sub":"b3000000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"b1000000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"b1000000-0000-0000-0000-000000000001":{"global_permissions":["attendance.manage"],"sites":{}}}}}',
    true
  );
  SET LOCAL ROLE authenticated;

  PERFORM api.create_employee_portal_pin_reset(
    p_employee_portal_token_id => v_token_id,
    p_reset_token_hash => v_pending_hash
  );
  PERFORM api.create_employee_portal_pin_reset(
    p_employee_portal_token_id => v_token_id,
    p_reset_token_hash => v_pending_hash2
  );

  SET LOCAL ROLE postgres;

  v_lookup := api.lookup_employee_portal_pin_reset_by_hash(
    encode(v_pending_hash, 'hex')
  );

  IF COALESCE(v_lookup ->> 'status', '') = 'revoked' THEN
    INSERT INTO ep_pin_reset_results VALUES ('EP4b-T6 new reset revokes pending', 'PASS', 'revoked');
  ELSE
    INSERT INTO ep_pin_reset_results VALUES ('EP4b-T6 new reset revokes pending', 'FAIL', COALESCE(v_lookup ->> 'status', 'null'));
  END IF;

EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ep_pin_reset_results VALUES ('EP4b setup', 'ERROR', SQLERRM);
END;
$$;

SELECT test_name, status, details FROM ep_pin_reset_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM ep_pin_reset_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'employee_portal_pin_reset_tests failed: % cases', v_fail;
  END IF;
END;
$$;

ROLLBACK;
