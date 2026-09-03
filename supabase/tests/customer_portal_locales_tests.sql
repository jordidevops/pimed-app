-- =============================================================================
-- Customer Portal locales (00035) — defaults es, persist, allow gate
-- =============================================================================
BEGIN;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;
GRANT ALL ON TABLE test_results TO service_role;
GRANT ALL ON TABLE test_results TO authenticated;

CREATE OR REPLACE FUNCTION pg_temp.as_service_role() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  SET ROLE service_role;
  PERFORM set_config('request.jwt.claim.role', 'service_role', true);
  PERFORM set_config('request.jwt.claim', '{"role":"service_role"}', true);
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.as_authenticated_owner() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000003":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000003":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000003"}', true);
END;
$$;

-- T1: peek virtual defaults → default_locale es, allow false
DO $$
DECLARE
  v_row data.customer_portal_tenant_state%ROWTYPE;
  v_tid uuid := '10000000-0000-0000-0000-00000000dead'::uuid;
BEGIN
  RESET ROLE;
  v_row := data.peek_customer_portal_tenant_state(v_tid);
  IF v_row.default_locale = 'es'
     AND v_row.allow_client_locale_change = false
     AND cardinality(v_row.supported_locales) >= 1
     AND 'es' = ANY (v_row.supported_locales)
  THEN
    INSERT INTO test_results VALUES ('T1_peek_defaults_es', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'T1_peek_defaults_es',
      'FAIL',
      format('default=%s allow=%s supported=%s',
        v_row.default_locale,
        v_row.allow_client_locale_change,
        v_row.supported_locales::text)
    );
  END IF;
END $$;

-- T2: column defaults on ensure / existing tenant row
DO $$
DECLARE
  v_tid uuid := '10000000-0000-0000-0000-000000000003'::uuid;
  v_def text;
  v_allow boolean;
BEGIN
  RESET ROLE;
  PERFORM data.ensure_customer_portal_tenant_state(v_tid);
  SELECT default_locale, allow_client_locale_change
    INTO v_def, v_allow
  FROM data.customer_portal_tenant_state
  WHERE tenant_id = v_tid;

  IF v_def = 'es' THEN
    INSERT INTO test_results VALUES ('T2_tenant_default_locale_es', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'T2_tenant_default_locale_es',
      'FAIL',
      coalesce(v_def, 'null')
    );
  END IF;
END $$;

-- T3: locale fields helper — preferred out of supported → preferred still returned (BFF resolves)
DO $$
DECLARE
  v_tid uuid := '10000000-0000-0000-0000-000000000003'::uuid;
  v_account uuid := '80000000-0000-0000-0000-000000000101'::uuid;
  v_fields jsonb;
BEGIN
  RESET ROLE;
  UPDATE data.contacts
  SET preferred_locale = 'en'
  WHERE id = v_account;

  UPDATE data.customer_portal_tenant_state
  SET supported_locales = ARRAY['ca', 'es']::text[],
      default_locale = 'es',
      allow_client_locale_change = false
  WHERE tenant_id = v_tid;

  v_fields := data.customer_portal_locale_fields(v_tid, v_account, 'ca');

  IF (v_fields->>'preferred_locale') = 'en'
     AND (v_fields->>'default_locale') = 'es'
     AND (v_fields->>'content_locale') = 'ca'
  THEN
    INSERT INTO test_results VALUES ('T3_locale_fields_preferred_raw', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'T3_locale_fields_preferred_raw',
      'FAIL',
      v_fields::text
    );
  END IF;
END $$;

-- T4: set_customer_portal_account_locale forbidden when allow=false
DO $$
BEGIN
  PERFORM pg_temp.as_service_role();
  BEGIN
    PERFORM api.set_customer_portal_account_locale(
      '10000000-0000-0000-0000-000000000003'::uuid,
      '80000000-0000-0000-0000-000000000101'::uuid,
      'ca'
    );
    INSERT INTO test_results VALUES (
      'T4_set_locale_allow_false',
      'FAIL',
      'expected client_locale_change_not_allowed'
    );
  EXCEPTION
    WHEN others THEN
      IF SQLERRM LIKE '%client_locale_change_not_allowed%' THEN
        INSERT INTO test_results VALUES ('T4_set_locale_allow_false', 'PASS', NULL);
      ELSE
        INSERT INTO test_results VALUES ('T4_set_locale_allow_false', 'FAIL', SQLERRM);
      END IF;
  END;
  RESET ROLE;
END $$;

-- T5: allow=true → persists preferred_locale on account
DO $$
DECLARE
  v_tid uuid := '10000000-0000-0000-0000-000000000003'::uuid;
  v_account uuid := '80000000-0000-0000-0000-000000000101'::uuid;
  v_pref text;
BEGIN
  RESET ROLE;
  UPDATE data.customer_portal_tenant_state
  SET supported_locales = ARRAY['ca', 'es', 'en']::text[],
      default_locale = 'es',
      allow_client_locale_change = true
  WHERE tenant_id = v_tid;

  UPDATE data.contacts SET preferred_locale = NULL WHERE id = v_account;

  PERFORM pg_temp.as_service_role();
  PERFORM api.set_customer_portal_account_locale(v_tid, v_account, 'ca');
  RESET ROLE;

  SELECT preferred_locale INTO v_pref FROM data.contacts WHERE id = v_account;
  IF v_pref = 'ca' THEN
    INSERT INTO test_results VALUES ('T5_set_locale_persists', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'T5_set_locale_persists',
      'FAIL',
      coalesce(v_pref, 'null')
    );
  END IF;
END $$;

-- T6: unsupported locale rejected
DO $$
DECLARE
  v_tid uuid := '10000000-0000-0000-0000-000000000003'::uuid;
  v_account uuid := '80000000-0000-0000-0000-000000000101'::uuid;
BEGIN
  RESET ROLE;
  UPDATE data.customer_portal_tenant_state
  SET supported_locales = ARRAY['es']::text[],
      default_locale = 'es',
      allow_client_locale_change = true
  WHERE tenant_id = v_tid;

  PERFORM pg_temp.as_service_role();
  BEGIN
    PERFORM api.set_customer_portal_account_locale(v_tid, v_account, 'ca');
    INSERT INTO test_results VALUES (
      'T6_locale_not_supported',
      'FAIL',
      'expected locale_not_supported'
    );
  EXCEPTION
    WHEN others THEN
      IF SQLERRM LIKE '%locale_not_supported%' THEN
        INSERT INTO test_results VALUES ('T6_locale_not_supported', 'PASS', NULL);
      ELSE
        INSERT INTO test_results VALUES ('T6_locale_not_supported', 'FAIL', SQLERRM);
      END IF;
  END;
  RESET ROLE;
END $$;

-- T7: authenticated cannot call set_customer_portal_account_locale
DO $$
BEGIN
  PERFORM pg_temp.as_authenticated_owner();
  BEGIN
    PERFORM api.set_customer_portal_account_locale(
      '10000000-0000-0000-0000-000000000003'::uuid,
      '80000000-0000-0000-0000-000000000101'::uuid,
      'es'
    );
    INSERT INTO test_results VALUES (
      'T7_authenticated_forbidden',
      'FAIL',
      'expected forbidden'
    );
  EXCEPTION
    WHEN insufficient_privilege THEN
      INSERT INTO test_results VALUES ('T7_authenticated_forbidden', 'PASS', NULL);
    WHEN others THEN
      IF SQLERRM LIKE '%forbidden%' OR SQLERRM LIKE '%permission denied%' THEN
        INSERT INTO test_results VALUES ('T7_authenticated_forbidden', 'PASS', NULL);
      ELSE
        INSERT INTO test_results VALUES ('T7_authenticated_forbidden', 'FAIL', SQLERRM);
      END IF;
  END;
  RESET ROLE;
END $$;

-- T8: settings.manage can set locales (default remains in supported)
DO $$
DECLARE
  v_out jsonb;
BEGIN
  PERFORM pg_temp.as_authenticated_owner();
  v_out := api.set_my_customer_portal_locales(
    ARRAY['ca', 'es', 'en']::text[],
    'es',
    false
  );
  IF (v_out->>'default_locale') = 'es'
     AND (v_out->>'allow_client_locale_change')::boolean = false
  THEN
    INSERT INTO test_results VALUES ('T8_set_my_locales', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T8_set_my_locales', 'FAIL', v_out::text);
  END IF;
  RESET ROLE;
END $$;

-- Cleanup fixture locale noise
DO $$
BEGIN
  RESET ROLE;
  UPDATE data.contacts
  SET preferred_locale = NULL
  WHERE id = '80000000-0000-0000-0000-000000000101'::uuid;
  UPDATE data.customer_portal_tenant_state
  SET supported_locales = ARRAY['ca', 'es', 'en']::text[],
      default_locale = 'es',
      allow_client_locale_change = false
  WHERE tenant_id = '10000000-0000-0000-0000-000000000003'::uuid;
END $$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'customer_locale_tests_failed:%', v_fail;
  END IF;
END $$;

ROLLBACK;
