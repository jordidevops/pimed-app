-- Field encryption tests: DEK, IBAN/NSS, reveal ACL, anti-swap AAD, BYO block
BEGIN;
SET client_min_messages TO WARNING;

CREATE TEMP TABLE test_results (
  test_name text PRIMARY KEY,
  status text NOT NULL,
  details text
) ON COMMIT DROP;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_alice  uuid := '40000000-0000-0000-0000-000000000001';
  v_owner  uuid := '20000000-0000-0000-0000-000000000002';
  v_mgr    uuid := '20000000-0000-0000-0000-000000000003'; -- assume exists or use owner without reveal
  v_got    api.employee_private_profiles;
  v_reveal jsonb;
  v_ok     boolean;
  v_plain  text;
  v_blob   bytea;
  v_aad_bad bytea;
  v_dek    bytea;
  v_ref    data.tenant_secret_refs%ROWTYPE;
BEGIN
  -- Owner JWT with *
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  -- E1: upsert IBAN + SSN (write-only)
  BEGIN
    PERFORM api.upsert_employee_private_profile(
      p_employee_id := v_alice,
      p_iban := 'ES9121000418450200051332',
      p_iban_set := true,
      p_social_security_number := '281234567840',
      p_ssn_set := true
    );
    SELECT * INTO v_got FROM api.get_employee_private_profile(v_alice);
    IF v_got.has_iban AND v_got.iban_last4 = '1332'
       AND v_got.has_ssn AND v_got.ssn_last4 = '7840' THEN
      INSERT INTO test_results VALUES ('E1 upsert encrypt masked', 'PASS', 'last4 ok');
    ELSE
      INSERT INTO test_results VALUES (
        'E1 upsert encrypt masked', 'FAIL',
        format('iban=%s/%s ssn=%s/%s', v_got.has_iban, v_got.iban_last4, v_got.has_ssn, v_got.ssn_last4)
      );
    END IF;
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO test_results VALUES ('E1 upsert encrypt masked', 'FAIL', SQLERRM);
  END;

  -- E2: get does not expose plaintext (no social_security_number column on row type)
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'api' AND table_name = 'employee_private_profiles'
      AND column_name = 'social_security_number'
  ) THEN
    INSERT INTO test_results VALUES ('E2 view no plaintext ssn', 'PASS', 'ok');
  ELSE
    INSERT INTO test_results VALUES ('E2 view no plaintext ssn', 'FAIL', 'column present');
  END IF;

  -- E3: reject masked input
  v_ok := false;
  BEGIN
    PERFORM api.upsert_employee_private_profile(
      p_employee_id := v_alice,
      p_iban := '****1332',
      p_iban_set := true
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%masked%' OR SQLERRM ILIKE '%invalid_iban%' THEN
      v_ok := true;
    END IF;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('E3 reject masked iban', 'PASS', 'rejected');
  ELSE
    INSERT INTO test_results VALUES ('E3 reject masked iban', 'FAIL', 'accepted or wrong error');
  END IF;

  -- E4: BYO upsert tenant_field_dek forbidden
  v_ok := false;
  BEGIN
    PERFORM api.upsert_tenant_secret(
      v_tenant, 'tenant_field_dek', 'default', 'should-not-work'
    );
  EXCEPTION WHEN OTHERS THEN
    v_ok := true;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('E4 byo upsert dek blocked', 'PASS', 'forbidden');
  ELSE
    INSERT INTO test_results VALUES ('E4 byo upsert dek blocked', 'FAIL', 'allowed');
  END IF;

  -- E5: ensure DEK idempotent
  v_ref := data.ensure_tenant_field_dek(v_tenant);
  PERFORM data.ensure_tenant_field_dek(v_tenant);
  IF (
    SELECT count(*) FROM data.tenant_secret_refs
    WHERE tenant_id = v_tenant AND secret_type = 'tenant_field_dek' AND provider = 'default'
  ) = 1 THEN
    INSERT INTO test_results VALUES ('E5 ensure dek idempotent', 'PASS', 'one ref');
  ELSE
    INSERT INTO test_results VALUES ('E5 ensure dek idempotent', 'FAIL', 'count!=1');
  END IF;

  -- E6: reveal with * works + audit
  BEGIN
    v_reveal := api.reveal_employee_private_field(v_alice, 'iban');
    IF v_reveal->>'value' = 'ES9121000418450200051332'
       AND EXISTS (
         SELECT 1 FROM data.audit_logs
         WHERE entity_id = v_alice
           AND action = 'employees.reveal_iban'
           AND created_at > now() - interval '1 minute'
       ) THEN
      INSERT INTO test_results VALUES ('E6 reveal + audit', 'PASS', 'ok');
    ELSE
      INSERT INTO test_results VALUES ('E6 reveal + audit', 'FAIL', v_reveal::text);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO test_results VALUES ('E6 reveal + audit', 'FAIL', SQLERRM);
  END;

  -- E7: manager role WITHOUT private.reveal cannot reveal
  -- Simulate custom manager: global_role manager but permissions without reveal
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000099', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000099","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["employees.private.view","employees.private.manage","employees.manage"],"sites":{}}}}}',
    true
  );
  v_ok := false;
  BEGIN
    PERFORM api.reveal_employee_private_field(v_alice, 'iban');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%insufficient_privilege%' OR SQLERRM ILIKE '%forbidden%' THEN
      v_ok := true;
    END IF;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('E7 manage without reveal denied', 'PASS', 'denied');
  ELSE
    INSERT INTO test_results VALUES ('E7 manage without reveal denied', 'FAIL', 'reveal allowed');
  END IF;

  -- E8: AAD swap fails (owner again)
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );

  SELECT iban_ciphertext INTO v_blob
  FROM data.employee_private_profiles WHERE employee_id = v_alice;

  SELECT d.dek INTO v_dek FROM data.load_tenant_field_dek(v_tenant) d;
  v_aad_bad := data.field_crypto_aad(v_tenant, gen_random_uuid(), 'iban');
  v_ok := false;
  BEGIN
    v_plain := data.field_crypto_decrypt(v_dek, v_blob, v_aad_bad);
  EXCEPTION WHEN OTHERS THEN
    v_ok := true;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('E8 aad swap fails', 'PASS', 'auth failed');
  ELSE
    INSERT INTO test_results VALUES ('E8 aad swap fails', 'FAIL', 'decrypt succeeded');
  END IF;

  -- Cleanup encrypted fields
  PERFORM api.upsert_employee_private_profile(
    p_employee_id := v_alice,
    p_clear_iban := true,
    p_clear_ssn := true
  );
END $$;

SELECT * FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  RAISE NOTICE 'Field encryption tests: % PASS, % FAIL',
    (SELECT count(*) FROM test_results WHERE status = 'PASS'),
    v_fail;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'Field encryption tests failed';
  END IF;
END $$;

ROLLBACK;
