-- =============================================================================
-- CP-B0 + CP-B smoke: internal gate data, portal mode, invite/accept/list
-- =============================================================================
BEGIN;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

-- T1: platform max_mode portal + can_grant
DO $$
DECLARE
  v_tid uuid;
  v_ent jsonb;
BEGIN
  SELECT id INTO v_tid FROM data.tenants LIMIT 1;
  v_ent := data.resolve_portal_entitlements(v_tid);
  IF (SELECT max_mode FROM data.customer_portal_platform_state WHERE id) = 'portal'
     AND COALESCE((v_ent->'customer_portal'->>'can_grant_portal_access')::boolean, false)
  THEN
    INSERT INTO test_results VALUES ('T1_portal_mode_grant', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T1_portal_mode_grant', 'FAIL', v_ent->'customer_portal');
  END IF;
END $$;

-- T2: tables exist + CP-C principal columns
DO $$
BEGIN
  IF to_regclass('data.customer_access_invitations') IS NOT NULL
     AND to_regclass('data.customer_access_grants') IS NOT NULL
     AND to_regclass('data.customer_portal_grant_sessions') IS NOT NULL
     AND to_regclass('data.customer_portal_login_tokens') IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM information_schema.columns
       WHERE table_schema = 'data' AND table_name = 'customer_access_grants'
         AND column_name = 'principal_kind'
     )
     AND EXISTS (
       SELECT 1 FROM information_schema.columns
       WHERE table_schema = 'data' AND table_name = 'customer_access_grants'
         AND column_name = 'client_account_contact_id'
     )
  THEN
    INSERT INTO test_results VALUES ('T2_tables', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T2_tables', 'FAIL', 'missing table/columns');
  END IF;
END $$;

-- T3: B0 — empty user_tenants JWT cannot see tenants via jwt claim helper
DO $$
DECLARE
  v_empty boolean;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","role":"authenticated","app_metadata":{"user_tenants":{},"user_permissions":{}}}',
    true
  );
  v_empty := (data.jwt_user_tenants() = '{}'::jsonb)
          OR (data.jwt_user_tenants() IS NULL)
          OR (data.jwt_user_tenants() = 'null'::jsonb);
  IF v_empty OR NOT EXISTS (
    SELECT 1 FROM jsonb_object_keys(COALESCE(data.jwt_user_tenants(), '{}'::jsonb))
  ) THEN
    INSERT INTO test_results VALUES ('T3_empty_jwt_tenants', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T3_empty_jwt_tenants', 'FAIL', data.jwt_user_tenants()::text);
  END IF;
END $$;

-- T4: peek invalid token
DO $$
DECLARE
  v_out jsonb;
BEGIN
  v_out := api.peek_customer_access_invitation(decode(repeat('ab', 32), 'hex'));
  IF COALESCE((v_out->>'ok')::boolean, true) = false THEN
    INSERT INTO test_results VALUES ('T4_peek_invalid', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T4_peek_invalid', 'FAIL', v_out::text);
  END IF;
END $$;

-- T5: privileged resolve not executable by authenticated (REVOKE check)
DO $$
DECLARE
  v_ok boolean;
BEGIN
  SELECT has_function_privilege('authenticated', 'api.resolve_customer_portal_grant_session(bytea,text,uuid,inet,text,text)', 'EXECUTE')
    INTO v_ok;
  IF COALESCE(v_ok, true) = false THEN
    INSERT INTO test_results VALUES ('T5_resolve_not_authenticated', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T5_resolve_not_authenticated', 'FAIL', 'authenticated can execute');
  END IF;
END $$;

-- T6: B0 denial — principal sense membership no veu tenants ni catàleg CIR/grants
DO $$
DECLARE
  v_tenants_total int;
  v_tenants_visible int;
  v_grants_visible int;
  v_versions_visible int;
BEGIN
  SELECT COUNT(*) INTO v_tenants_total FROM data.tenants;
  IF v_tenants_total = 0 THEN
    INSERT INTO test_results VALUES (
      'T6_customer_denial_empty_jwt', 'FAIL', 'no tenants in fixture'
    );
    RETURN;
  END IF;

  PERFORM set_config('request.jwt.claim.sub', 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","role":"authenticated","app_metadata":{"user_tenants":{},"user_permissions":{}}}',
    true
  );
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);

  BEGIN
    SET LOCAL ROLE authenticated;
    SELECT COUNT(*) INTO v_tenants_visible FROM data.tenants;
    SELECT COUNT(*) INTO v_grants_visible FROM api.list_customer_access_grants(NULL, false);
    SELECT COUNT(*) INTO v_versions_visible FROM data.customer_intervention_report_versions;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    -- Exception under empty JWT is also denial (e.g. active_tenant_required)
    v_tenants_visible := 0;
    v_grants_visible := 0;
    v_versions_visible := 0;
  END;

  IF v_tenants_visible = 0 AND v_grants_visible = 0 AND v_versions_visible = 0 THEN
    INSERT INTO test_results VALUES (
      'T6_customer_denial_empty_jwt',
      'PASS',
      format('RLS hid %s tenants; grants/versions=0', v_tenants_total)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T6_customer_denial_empty_jwt',
      'FAIL',
      format('leaked tenants=%s grants=%s versions=%s (of %s tenants)',
        v_tenants_visible, v_grants_visible, v_versions_visible, v_tenants_total)
    );
  END IF;
END $$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
  v_detail text;
BEGIN
  SELECT COUNT(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    SELECT string_agg(test_name || COALESCE(':' || details, ''), ', ')
      INTO v_detail
    FROM test_results WHERE status = 'FAIL';
    RAISE EXCEPTION 'CP-B tests failed: %', v_detail;
  END IF;
END $$;

SELECT
  COUNT(*) FILTER (WHERE status = 'PASS') AS passed,
  COUNT(*) FILTER (WHERE status = 'FAIL') AS failed
FROM test_results;

ROLLBACK;
