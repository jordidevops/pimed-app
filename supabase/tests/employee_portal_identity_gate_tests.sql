-- =============================================================================
-- employee_portal_identity_gate_tests.sql — EP-ACC-9a/9b/9d/9e (I-Ta*, I-T1…I-T8, I-Td1)
-- =============================================================================

BEGIN;

CREATE TEMP TABLE ep_identity_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('e1000000-0000-0000-0000-000000000001', 'EP Identity Tenant', 'ep-identity', true)
ON CONFLICT (id) DO UPDATE SET public_portal_enabled = true;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('e2000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'EP Identity Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, document_id, status)
VALUES
  (
    'e5000000-0000-0000-0000-000000000001',
    'e1000000-0000-0000-0000-000000000001',
    'e2000000-0000-0000-0000-000000000001',
    NULL,
    'Identity Emp Personal',
    '12345678Z',
    'active'
  ),
  (
    'e5000000-0000-0000-0000-000000000002',
    'e1000000-0000-0000-0000-000000000001',
    'e2000000-0000-0000-0000-000000000001',
    NULL,
    'Identity Emp Shared',
    '87654321X',
    'active'
  ),
  (
    'e5000000-0000-0000-0000-000000000003',
    'e1000000-0000-0000-0000-000000000001',
    'e2000000-0000-0000-0000-000000000001',
    NULL,
    'Identity Emp No Doc',
    NULL,
    'active'
  )
ON CONFLICT (id) DO UPDATE
SET document_id = EXCLUDED.document_id,
    full_name = EXCLUDED.full_name;

DO $$
DECLARE
  v_personal_hash bytea := decode('aa112233445566778899aabbccddeeff00112233445566778899aabbcc', 'hex');
  v_shared_hash bytea := decode('bb112233445566778899aabbccddeeff00112233445566778899aabbcc', 'hex');
  v_grandfather_hash bytea := decode('cc112233445566778899aabbccddeeff00112233445566778899aabbcc', 'hex');
  v_no_doc_hash bytea := decode('ee112233445566778899aabbccddeeff00112233445566778899aabbcc', 'hex');
  v_shared_id uuid;
  v_grandfather_id uuid;
  v_personal_id uuid;
  v_no_doc_id uuid;
  v_first_access timestamptz := '2026-06-01 10:00:00+00';
  v_lookup jsonb;
  v_view_identity timestamptz;
BEGIN
  SET LOCAL ROLE postgres;

  -- Neteja tokens actius de prova (índex uq per tipus)
  UPDATE data.employee_portal_tokens
  SET is_active = false,
      revoked_at = COALESCE(revoked_at, now()),
      revoke_reason = COALESCE(revoke_reason, 'test_cleanup')
  WHERE employee_id IN (
    'e5000000-0000-0000-0000-000000000001',
    'e5000000-0000-0000-0000-000000000002',
    'e5000000-0000-0000-0000-000000000003'
  )
    AND is_active = true
    AND id NOT IN (
      'e6000000-0000-0000-0000-000000000002',
      'e6000000-0000-0000-0000-000000000003',
      'e6000000-0000-0000-0000-000000000004',
      'e6000000-0000-0000-0000-000000000005'
    );

  -- I-Ta1: normalització DNI
  IF api.normalize_employee_document_id('12-345.678-Z') = '12345678Z'
     AND api.normalize_employee_document_id('  x1234567l  ') = 'X1234567L' THEN
    INSERT INTO ep_identity_results VALUES ('I-Ta1 normalize format', 'PASS', '12345678Z');
  ELSE
    INSERT INTO ep_identity_results VALUES (
      'I-Ta1 normalize format',
      'FAIL',
      coalesce(api.normalize_employee_document_id('12-345.678-Z'), 'null')
    );
  END IF;

  -- I-Ta2: normalització buida
  IF api.normalize_employee_document_id(NULL) IS NULL
     AND api.normalize_employee_document_id('   ') IS NULL
     AND api.normalize_employee_document_id('---') IS NULL THEN
    INSERT INTO ep_identity_results VALUES ('I-Ta2 normalize empty', 'PASS', 'null');
  ELSE
    INSERT INTO ep_identity_results VALUES ('I-Ta2 normalize empty', 'FAIL', 'expected null');
  END IF;

  -- I-Ta3: match mateix document format diferent
  IF api.employee_portal_document_id_matches('12345678Z', '12.345.678-Z') THEN
    INSERT INTO ep_identity_results VALUES ('I-Ta3 document match', 'PASS', 'true');
  ELSE
    INSERT INTO ep_identity_results VALUES ('I-Ta3 document match', 'FAIL', 'false');
  END IF;

  -- I-Ta4: match document incorrecte
  IF NOT api.employee_portal_document_id_matches('12345678Z', '99999999R') THEN
    INSERT INTO ep_identity_results VALUES ('I-Ta4 document mismatch', 'PASS', 'false');
  ELSE
    INSERT INTO ep_identity_results VALUES ('I-Ta4 document mismatch', 'FAIL', 'true');
  END IF;

  -- Tokens de prova
  INSERT INTO data.employee_portal_tokens (
    id,
    tenant_id,
    employee_id,
    token_hash,
    is_active,
    first_accessed_at,
    identity_verified_at,
    revoked_at,
    revoke_reason
  ) VALUES (
    'e6000000-0000-0000-0000-000000000003',
    'e1000000-0000-0000-0000-000000000001',
    'e5000000-0000-0000-0000-000000000001',
    v_grandfather_hash,
    false,
    v_first_access,
    NULL,
    now(),
    'test_grandfather'
  )
  ON CONFLICT (id) DO UPDATE
  SET first_accessed_at = EXCLUDED.first_accessed_at,
      identity_verified_at = NULL,
      token_hash = EXCLUDED.token_hash,
      is_active = false,
      revoked_at = COALESCE(data.employee_portal_tokens.revoked_at, now()),
      revoke_reason = 'test_grandfather';

  v_grandfather_id := 'e6000000-0000-0000-0000-000000000003';

  -- Simula backfill de migració (idempotent amb el que ja hagi aplicat la migració)
  UPDATE data.employee_portal_tokens
  SET identity_verified_at = COALESCE(identity_verified_at, first_accessed_at)
  WHERE id = v_grandfather_id;

  -- I-Ta5 / I-T9: grandfather
  SELECT identity_verified_at
  INTO v_view_identity
  FROM data.employee_portal_tokens
  WHERE id = v_grandfather_id;

  IF v_view_identity = v_first_access THEN
    INSERT INTO ep_identity_results VALUES ('I-Ta5 grandfather backfill', 'PASS', v_view_identity::text);
  ELSE
    INSERT INTO ep_identity_results VALUES (
      'I-Ta5 grandfather backfill',
      'FAIL',
      coalesce(v_view_identity::text, 'null')
    );
  END IF;

  INSERT INTO data.employee_portal_tokens (
    id,
    tenant_id,
    employee_id,
    token_hash,
    is_active,
    pin_must_set,
    first_accessed_at,
    identity_verified_at,
    revoked_at
  ) VALUES (
    'e6000000-0000-0000-0000-000000000004',
    'e1000000-0000-0000-0000-000000000001',
    'e5000000-0000-0000-0000-000000000001',
    v_personal_hash,
    true,
    true,
    NULL,
    NULL,
    NULL
  )
  ON CONFLICT (id) DO UPDATE
  SET token_hash = EXCLUDED.token_hash,
      is_active = true,
      pin_must_set = true,
      first_accessed_at = NULL,
      identity_verified_at = NULL,
      revoked_at = NULL,
      revoke_reason = NULL;

  v_personal_id := 'e6000000-0000-0000-0000-000000000004';

  -- I-Ta6: token nou sense ús → identity_verified_at NULL
  IF EXISTS (
    SELECT 1
    FROM data.employee_portal_tokens
    WHERE id = v_personal_id
      AND identity_verified_at IS NULL
      AND first_accessed_at IS NULL
  ) THEN
    INSERT INTO ep_identity_results VALUES ('I-Ta6 new token unverified', 'PASS', v_personal_id::text);
  ELSE
    INSERT INTO ep_identity_results VALUES ('I-Ta6 new token unverified', 'FAIL', 'expected null');
  END IF;

  INSERT INTO data.employee_portal_tokens (
    id,
    tenant_id,
    employee_id,
    token_hash,
    is_active
  ) VALUES (
    'e6000000-0000-0000-0000-000000000002',
    'e1000000-0000-0000-0000-000000000001',
    'e5000000-0000-0000-0000-000000000002',
    v_shared_hash,
    true
  )
  ON CONFLICT (id) DO UPDATE
  SET token_hash = EXCLUDED.token_hash,
      is_active = true;

  v_shared_id := 'e6000000-0000-0000-0000-000000000002';

  -- I-Ta7: identity_required personal sense verificar
  IF api.employee_portal_identity_required( NULL) THEN
    INSERT INTO ep_identity_results VALUES ('I-Ta7 identity required personal', 'PASS', 'true');
  ELSE
    INSERT INTO ep_identity_results VALUES ('I-Ta7 identity required personal', 'FAIL', 'false');
  END IF;

  -- I-Ta9: ja verificat → no required
  IF NOT api.employee_portal_identity_required( now()) THEN
    INSERT INTO ep_identity_results VALUES ('I-Ta9 verified not required', 'PASS', 'false');
  ELSE
    INSERT INTO ep_identity_results VALUES ('I-Ta9 verified not required', 'FAIL', 'true');
  END IF;

  -- I-Ta10: lookup retorna camps d'identitat
  v_lookup := api.lookup_employee_portal_token_by_hash(encode(v_personal_hash, 'hex'));

  IF COALESCE(v_lookup ->> 'identity_required', 'missing') = 'true'
     AND (v_lookup ->> 'identity_verified_at') IS NULL
     AND COALESCE(v_lookup ->> 'has_document_id', 'missing') = 'true' THEN
    INSERT INTO ep_identity_results VALUES ('I-Ta10 lookup identity fields', 'PASS', v_lookup ->> 'token_id');
  ELSE
    INSERT INTO ep_identity_results VALUES ('I-Ta10 lookup identity fields', 'FAIL', v_lookup::text);
  END IF;

  -- I-Ta11: second employee token also requires identity
  v_lookup := api.lookup_employee_portal_token_by_hash(encode(v_shared_hash, 'hex'));

  IF COALESCE(v_lookup ->> 'identity_required', 'missing') = 'true' THEN
    INSERT INTO ep_identity_results VALUES ('I-Ta11 all tokens require identity', 'PASS', v_lookup ->> 'token_id');
  ELSE
    INSERT INTO ep_identity_results VALUES ('I-Ta11 all tokens require identity', 'FAIL', v_lookup::text);
  END IF;

  INSERT INTO data.employee_portal_tokens (
    id,
    tenant_id,
    employee_id,
    token_hash,
    is_active
  ) VALUES (
    'e6000000-0000-0000-0000-000000000005',
    'e1000000-0000-0000-0000-000000000001',
    'e5000000-0000-0000-0000-000000000003',
    v_no_doc_hash,
    true
  )
  ON CONFLICT (id) DO UPDATE
  SET token_hash = EXCLUDED.token_hash,
      is_active = true,
      revoked_at = NULL,
      revoke_reason = NULL;

  v_no_doc_id := 'e6000000-0000-0000-0000-000000000005';

  -- I-Ta12: empleat sense document_id
  v_lookup := api.get_employee_portal_token_session(v_no_doc_id);

  IF COALESCE(v_lookup ->> 'has_document_id', 'missing') = 'false' THEN
    INSERT INTO ep_identity_results VALUES ('I-Ta12 no document_id flag', 'PASS', 'false');
  ELSE
    INSERT INTO ep_identity_results VALUES ('I-Ta12 no document_id flag', 'FAIL', v_lookup::text);
  END IF;

  -- I-Ta13: view api.employee_portal_tokens exposa identity_verified_at
  SELECT identity_verified_at
  INTO v_view_identity
  FROM api.employee_portal_tokens
  WHERE id = v_grandfather_id;

  IF v_view_identity = v_first_access THEN
    INSERT INTO ep_identity_results VALUES ('I-Ta13 view identity_verified_at', 'PASS', v_view_identity::text);
  ELSE
    INSERT INTO ep_identity_results VALUES (
      'I-Ta13 view identity_verified_at',
      'FAIL',
      coalesce(v_view_identity::text, 'null')
    );
  END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- EP-ACC-9b RPC tests (I-T1, I-T2, I-T3, I-T7)
-- -----------------------------------------------------------------------------

DO $$
DECLARE
  v_personal_hash_hex text := 'aa112233445566778899aabbccddeeff00112233445566778899aabbcc';
  v_shared_hash_hex text := 'bb112233445566778899aabbccddeeff00112233445566778899aabbcc';
  v_no_doc_hash_hex text := 'ee112233445566778899aabbccddeeff00112233445566778899aabbcc';
  v_personal_id uuid := 'e6000000-0000-0000-0000-000000000004';
  v_verify jsonb;
  v_confirm jsonb;
  v_setup jsonb;
  v_lookup jsonb;
  v_identity_at timestamptz;
  v_log_count int;
  v_log_count_text text;
  v_i int;
BEGIN
  SET LOCAL ROLE postgres;

  UPDATE data.employee_portal_tokens
  SET identity_verified_at = NULL,
      identity_challenge_at = NULL,
      identity_attempts = 0,
      identity_locked_until = NULL,
      pin_must_set = true,
      pin_hash = NULL,
      is_active = true,
      revoked_at = NULL
  WHERE id = v_personal_id;

  -- I-T1: DNI OK + confirm → identity_verified_at; després pin_setup
  v_verify := api.employee_portal_verify_identity_document(v_personal_hash_hex, '12.345.678-Z');

  IF COALESCE(v_verify ->> 'status', '') = 'match'
     AND (v_verify ->> 'full_name') IS NOT NULL THEN
    INSERT INTO ep_identity_results VALUES ('I-T1 verify match', 'PASS', v_verify ->> 'full_name');
  ELSE
    INSERT INTO ep_identity_results VALUES ('I-T1 verify match', 'FAIL', v_verify::text);
  END IF;

  v_confirm := api.employee_portal_confirm_identity(v_personal_hash_hex);

  IF COALESCE(v_confirm ->> 'status', '') = 'ok'
     AND COALESCE(v_confirm ->> 'next', '') = 'pin_setup' THEN
    INSERT INTO ep_identity_results VALUES ('I-T1 confirm pin_setup', 'PASS', v_confirm ->> 'next');
  ELSE
    INSERT INTO ep_identity_results VALUES ('I-T1 confirm pin_setup', 'FAIL', v_confirm::text);
  END IF;

  SELECT identity_verified_at
  INTO v_identity_at
  FROM data.employee_portal_tokens
  WHERE id = v_personal_id;

  IF v_identity_at IS NOT NULL THEN
    INSERT INTO ep_identity_results VALUES ('I-T1 identity_verified_at', 'PASS', v_identity_at::text);
  ELSE
    INSERT INTO ep_identity_results VALUES ('I-T1 identity_verified_at', 'FAIL', 'null');
  END IF;

  v_setup := api.employee_portal_setup_pin(v_personal_hash_hex, 'sha256:deadbeefcafebabe');

  IF COALESCE(v_setup ->> 'status', '') = 'ok'
     AND (v_setup ->> 'token_id') IS NOT NULL THEN
    INSERT INTO ep_identity_results VALUES ('I-T1c setup_pin after confirm', 'PASS', v_setup ->> 'token_id');
  ELSE
    INSERT INTO ep_identity_results VALUES ('I-T1c setup_pin after confirm', 'FAIL', v_setup::text);
  END IF;

  -- Reset for I-T2
  UPDATE data.employee_portal_tokens
  SET identity_verified_at = NULL,
      identity_challenge_at = NULL,
      identity_attempts = 0,
      identity_locked_until = NULL,
      pin_hash = NULL,
      pin_must_set = true
  WHERE id = v_personal_id;

  v_verify := api.employee_portal_verify_identity_document(v_personal_hash_hex, '99999999R');

  IF COALESCE(v_verify ->> 'status', '') = 'mismatch' THEN
    INSERT INTO ep_identity_results VALUES ('I-T2 verify mismatch', 'PASS', v_verify ->> 'status');
  ELSE
    INSERT INTO ep_identity_results VALUES ('I-T2 verify mismatch', 'FAIL', v_verify::text);
  END IF;

  SELECT identity_verified_at
  INTO v_identity_at
  FROM data.employee_portal_tokens
  WHERE id = v_personal_id;

  IF v_identity_at IS NULL THEN
    INSERT INTO ep_identity_results VALUES ('I-T2 no identity_verified_at', 'PASS', 'null');
  ELSE
    INSERT INTO ep_identity_results VALUES ('I-T2 no identity_verified_at', 'FAIL', v_identity_at::text);
  END IF;

  PERFORM api.log_employee_portal_access_event(
    v_personal_id,
    'e5000000-0000-0000-0000-000000000001'::uuid,
    'e1000000-0000-0000-0000-000000000001'::uuid,
    'identity_verify_failed'::text,
    401::smallint,
    'document_mismatch'::text,
    NULL::inet,
    NULL::text,
    NULL::jsonb
  );

  SELECT count(*)
  INTO v_log_count
  FROM data.employee_portal_access_logs
  WHERE token_id = v_personal_id
    AND action = 'identity_verify_failed'
    AND failure_reason = 'document_mismatch';

  IF v_log_count >= 1 THEN
    INSERT INTO ep_identity_results VALUES ('I-T2 mismatch log action', 'PASS', v_log_count::text);
  ELSE
    INSERT INTO ep_identity_results VALUES ('I-T2 mismatch log action', 'FAIL', '0');
  END IF;

  -- I-T3: reject flow (challenge cleared + log)
  UPDATE data.employee_portal_tokens
  SET identity_verified_at = NULL,
      identity_challenge_at = NULL,
      identity_attempts = 0,
      identity_locked_until = NULL
  WHERE id = v_personal_id;

  v_verify := api.employee_portal_verify_identity_document(v_personal_hash_hex, '12345678Z');
  v_confirm := api.employee_portal_clear_identity_challenge(v_personal_hash_hex);

  IF COALESCE(v_confirm ->> 'status', '') = 'ok' THEN
    INSERT INTO ep_identity_results VALUES ('I-T3 clear challenge', 'PASS', v_confirm ->> 'status');
  ELSE
    INSERT INTO ep_identity_results VALUES ('I-T3 clear challenge', 'FAIL', v_confirm::text);
  END IF;

  PERFORM api.log_employee_portal_access_event(
    v_personal_id,
    'e5000000-0000-0000-0000-000000000001'::uuid,
    'e1000000-0000-0000-0000-000000000001'::uuid,
    'identity_rejected'::text,
    200::smallint,
    NULL::text,
    NULL::inet,
    NULL::text,
    NULL::jsonb
  );

  SELECT count(*)
  INTO v_log_count
  FROM data.employee_portal_access_logs
  WHERE token_id = v_personal_id
    AND action = 'identity_rejected';

  IF v_log_count >= 1 THEN
    INSERT INTO ep_identity_results VALUES ('I-T3 identity_rejected log', 'PASS', v_log_count::text);
  ELSE
    INSERT INTO ep_identity_results VALUES ('I-T3 identity_rejected log', 'FAIL', '0');
  END IF;

  -- I-T7: rate limit 5/15min
  UPDATE data.employee_portal_tokens
  SET identity_verified_at = NULL,
      identity_challenge_at = NULL,
      identity_attempts = 0,
      identity_locked_until = NULL
  WHERE id = v_personal_id;

  FOR v_i IN 1..5 LOOP
    v_verify := api.employee_portal_verify_identity_document(v_personal_hash_hex, '00000000A');
  END LOOP;

  v_verify := api.employee_portal_verify_identity_document(v_personal_hash_hex, '00000000A');

  IF COALESCE(v_verify ->> 'status', '') = 'identity_locked'
     AND (v_verify ->> 'retry_after_seconds') IS NOT NULL THEN
    INSERT INTO ep_identity_results VALUES ('I-T7 identity_locked', 'PASS', v_verify ->> 'retry_after_seconds');
  ELSE
    INSERT INTO ep_identity_results VALUES ('I-T7 identity_locked', 'FAIL', v_verify::text);
  END IF;

  -- setup_pin blocked without identity
  UPDATE data.employee_portal_tokens
  SET identity_verified_at = NULL,
      identity_challenge_at = NULL,
      identity_attempts = 0,
      identity_locked_until = NULL,
      pin_must_set = true,
      pin_hash = NULL
  WHERE id = v_personal_id;

  v_setup := api.employee_portal_setup_pin(v_personal_hash_hex, 'deadbeef');

  IF COALESCE(v_setup ->> 'status', '') = 'identity_required' THEN
    INSERT INTO ep_identity_results VALUES ('I-T1b setup_pin identity_required', 'PASS', v_setup ->> 'status');
  ELSE
    INSERT INTO ep_identity_results VALUES ('I-T1b setup_pin identity_required', 'FAIL', v_setup::text);
  END IF;

  -- I-T4: segon accés amb identitat verificada → no required
  UPDATE data.employee_portal_tokens
  SET identity_verified_at = now(),
      identity_challenge_at = NULL,
      pin_must_set = false,
      pin_hash = 'sha256:existing'
  WHERE id = v_personal_id;

  IF NOT api.employee_portal_identity_required( (
    SELECT identity_verified_at FROM data.employee_portal_tokens WHERE id = v_personal_id
  )) THEN
    INSERT INTO ep_identity_results VALUES ('I-T4 verified skips identity', 'PASS', 'false');
  ELSE
    INSERT INTO ep_identity_results VALUES ('I-T4 verified skips identity', 'FAIL', 'true');
  END IF;

  v_lookup := api.lookup_employee_portal_token_by_hash(v_personal_hash_hex);
  IF COALESCE(v_lookup ->> 'identity_required', 'missing') = 'false' THEN
    INSERT INTO ep_identity_results VALUES ('I-T4 lookup skip identity', 'PASS', v_lookup ->> 'identity_verified_at');
  ELSE
    INSERT INTO ep_identity_results VALUES ('I-T4 lookup skip identity', 'FAIL', v_lookup::text);
  END IF;

  -- I-T5: all tokens require identity (no shared_device exempt)
  v_lookup := api.lookup_employee_portal_token_by_hash(v_shared_hash_hex);
  IF COALESCE(v_lookup ->> 'identity_required', 'missing') = 'true' THEN
    INSERT INTO ep_identity_results VALUES ('I-T5 all tokens require identity', 'PASS', 'true');
  ELSE
    INSERT INTO ep_identity_results VALUES ('I-T5 all tokens require identity', 'FAIL', v_lookup::text);
  END IF;

  -- I-T6: sense document_id → identity_not_configured
  v_verify := api.employee_portal_verify_identity_document(
    v_no_doc_hash_hex,
    '12345678Z'
  );
  IF COALESCE(v_verify ->> 'status', '') = 'identity_not_configured' THEN
    INSERT INTO ep_identity_results VALUES ('I-T6 no document configured', 'PASS', v_verify ->> 'status');
  ELSE
    INSERT INTO ep_identity_results VALUES ('I-T6 no document configured', 'FAIL', v_verify::text);
  END IF;

  -- I-Td1: manager logs inclouen metadata
  PERFORM api.log_employee_portal_access_event(
    v_personal_id,
    'e5000000-0000-0000-0000-000000000001'::uuid,
    'e1000000-0000-0000-0000-000000000001'::uuid,
    'identity_verify_failed'::text,
    401::smallint,
    'document_mismatch'::text,
    NULL::inet,
    NULL::text,
    jsonb_build_object('document_id_last4', '678Z')
  );

  SELECT l.metadata ->> 'document_id_last4'
  INTO v_log_count_text
  FROM data.employee_portal_access_logs l
  WHERE l.token_id = v_personal_id
    AND l.action = 'identity_verify_failed'
    AND l.metadata ->> 'document_id_last4' = '678Z'
  LIMIT 1;

  IF v_log_count_text = '678Z' THEN
    INSERT INTO ep_identity_results VALUES ('I-Td1 logs metadata last4', 'PASS', v_log_count_text);
  ELSE
    INSERT INTO ep_identity_results VALUES ('I-Td1 logs metadata last4', 'FAIL', coalesce(v_log_count_text, 'null'));
  END IF;
END;
$$;

-- EP-ACC-9e: DNI obligatori a create/batch (I-T8, I-T8a)
INSERT INTO auth.users (id, email, role, aud)
VALUES ('e3000000-0000-0000-0000-000000000001', 'ep-identity-mgr@test.com', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES ('e3000000-0000-0000-0000-000000000001', 'ep-identity-mgr@test.com', 'EP Identity Manager')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES (
  'e4000000-0000-0000-0000-000000000001',
  'e1000000-0000-0000-0000-000000000001',
  'e3000000-0000-0000-0000-000000000001',
  'manager',
  true
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.public_sites (id, tenant_id, site_id, slug, name, status)
VALUES (
  'e6000000-0000-0000-0000-000000000099',
  'e1000000-0000-0000-0000-000000000001',
  'e2000000-0000-0000-0000-000000000001',
  'ep-identity-site',
  'EP Identity Portal',
  'published'
)
ON CONFLICT (id) DO UPDATE SET status = EXCLUDED.status, slug = EXCLUDED.slug;

INSERT INTO data.public_domains (id, public_site_id, tenant_id, domain, status)
VALUES (
  'e7000000-0000-0000-0000-000000000099',
  'e6000000-0000-0000-0000-000000000099',
  'e1000000-0000-0000-0000-000000000001',
  'identity.ep9e.test',
  'ssl_active'
)
ON CONFLICT (id) DO NOTHING;

UPDATE data.public_sites
SET primary_domain_id = 'e7000000-0000-0000-0000-000000000099'
WHERE id = 'e6000000-0000-0000-0000-000000000099';

CREATE OR REPLACE FUNCTION pg_temp.ep_identity_set_manager_jwt()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM set_config(
    'request.jwt.claims',
    '{"sub":"e3000000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"e1000000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"e1000000-0000-0000-0000-000000000001":{"global_permissions":["attendance.manage"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"e1000000-0000-0000-0000-000000000001"}', true);
  SET LOCAL ROLE authenticated;
END;
$$;

UPDATE data.employee_portal_token_batch_jobs
SET created_at = now() - interval '2 hours'
WHERE tenant_id = 'e1000000-0000-0000-0000-000000000001';

DO $$
DECLARE
  v_err text;
  v_result jsonb;
  v_batch_id uuid;
  v_item record;
  v_token_count int;
  v_hash bytea := decode('ff112233445566778899aabbccddeeff00112233445566778899aabbcc', 'hex');
BEGIN
  SET LOCAL ROLE postgres;

  UPDATE data.employee_portal_tokens
  SET is_active = false,
      revoked_at = COALESCE(revoked_at, now()),
      revoke_reason = COALESCE(revoke_reason, 'test_cleanup')
  WHERE employee_id = 'e5000000-0000-0000-0000-000000000003'
    AND is_active = true
    AND revoked_at IS NULL
    AND id <> 'e6000000-0000-0000-0000-000000000005';

  PERFORM pg_temp.ep_identity_set_manager_jwt();
  BEGIN
    PERFORM api.create_employee_portal_token(
      p_employee_id => 'e5000000-0000-0000-0000-000000000003'::uuid,
      p_token_hash => v_hash,
      p_label => 'I-T8a',
      p_pin_hash => NULL,
      p_expires_at => NULL,
      p_pin_must_set => true
    );
    SET LOCAL ROLE postgres;
    INSERT INTO ep_identity_results VALUES ('I-T8a create missing document', 'FAIL', 'no exception');
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      SET LOCAL ROLE postgres;
      IF v_err LIKE '%employee_missing_document_id%' THEN
        INSERT INTO ep_identity_results VALUES ('I-T8a create missing document', 'PASS', v_err);
      ELSE
        INSERT INTO ep_identity_results VALUES ('I-T8a create missing document', 'FAIL', v_err);
      END IF;
  END;

  SET LOCAL ROLE postgres;

  SELECT count(*) INTO v_token_count
  FROM data.employee_portal_tokens
  WHERE employee_id = 'e5000000-0000-0000-0000-000000000003'
    AND is_active = true
    AND revoked_at IS NULL
    AND id <> 'e6000000-0000-0000-0000-000000000005';

  IF v_token_count = 0 THEN
    INSERT INTO ep_identity_results VALUES ('I-T8a no token created', 'PASS', '0');
  ELSE
    INSERT INTO ep_identity_results VALUES ('I-T8a no token created', 'FAIL', v_token_count::text);
  END IF;

  PERFORM pg_temp.ep_identity_set_manager_jwt();
  v_result := api.start_employee_portal_token_batch(
    p_idempotency_key => 'identity-batch-no-doc-001',
    p_employee_ids => ARRAY['e5000000-0000-0000-0000-000000000003'::uuid],
    p_force_new => true
  );
  v_batch_id := (v_result ->> 'batch_id')::uuid;

  SET LOCAL ROLE postgres;

  SELECT i.status, i.error_code
  INTO v_item
  FROM data.employee_portal_token_batch_items i
  WHERE i.batch_job_id = v_batch_id
    AND i.employee_id = 'e5000000-0000-0000-0000-000000000003';

  SELECT count(*) INTO v_token_count
  FROM data.employee_portal_tokens
  WHERE employee_id = 'e5000000-0000-0000-0000-000000000003'
    AND is_active = true
    AND revoked_at IS NULL
    AND id <> 'e6000000-0000-0000-0000-000000000005';

  IF v_item.status = 'skipped'
     AND v_item.error_code = 'employee_missing_document_id'
     AND (v_result -> 'summary' ->> 'created')::int = 0
     AND v_token_count = 0 THEN
    INSERT INTO ep_identity_results VALUES ('I-T8 batch missing document', 'PASS', v_item.error_code);
  ELSE
    INSERT INTO ep_identity_results VALUES (
      'I-T8 batch missing document',
      'FAIL',
      coalesce(v_item.status::text, 'null') || ' / tokens=' || v_token_count::text
    );
  END IF;
END;
$$;

DO $$
DECLARE
  v_fail_count int;
  v_fail_details text;
BEGIN
  SELECT count(*), string_agg(test_name || ': ' || details, E'\n')
  INTO v_fail_count, v_fail_details
  FROM ep_identity_results
  WHERE status <> 'PASS';

  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'employee_portal_identity_gate_tests failed (%): %', v_fail_count, v_fail_details;
  END IF;
END;
$$;

SELECT test_name, status, details FROM ep_identity_results ORDER BY test_name;

COMMIT;
