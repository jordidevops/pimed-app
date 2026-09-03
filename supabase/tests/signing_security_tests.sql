-- =============================================================================
-- Signing Security Tests
-- =============================================================================
-- Cobertura:
--   T1 api.tenant_signing_status no exposa docuseal_key_secret_id
--   T2 tenant member veu només la seva configuració de signing
--   T3 member pot crear signing_submission; viewer no
--   T4 aïllament cross-tenant de signing_submissions
--   T5 authenticated no pot inserir signing_events directament
--   T6 api.append_signing_event és idempotent per webhook_event_id
-- =============================================================================

BEGIN;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

GRANT SELECT, INSERT ON test_results TO service_role;

-- -----------------------------------------------------------------------------
-- T1: La vista segura no exposa docuseal_key_secret_id
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_secret_exposed boolean := false;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'api'
      AND table_name = 'tenant_signing_status'
      AND column_name = 'docuseal_key_secret_id'
  ) INTO v_secret_exposed;

  IF NOT v_secret_exposed THEN
    INSERT INTO test_results VALUES (
      'T1 tenant_signing_status hides secret reference',
      'PASS',
      'docuseal_key_secret_id not exposed in api view'
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T1 tenant_signing_status hides secret reference',
      'FAIL',
      'docuseal_key_secret_id should not be exposed in api.tenant_signing_status'
    );
  END IF;
END $$;

SET LOCAL ROLE authenticated;

-- -----------------------------------------------------------------------------
-- T2: tenant member només veu configuració del seu tenant
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_own_count   integer := 0;
  v_other_count integer := 0;
BEGIN
  -- Seed deterministic signing config for both tenants
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}},"10000000-0000-0000-0000-000000000002":{"global_role":"owner","sites":{}}}}}',
    true
  );

  INSERT INTO data.tenant_signing_config (tenant_id, mode, signing_credits, is_active)
  VALUES
    ('10000000-0000-0000-0000-000000000001'::uuid, 'platform', 25, true),
    ('10000000-0000-0000-0000-000000000002'::uuid, 'platform', 40, true)
  ON CONFLICT (tenant_id) DO UPDATE
    SET mode = EXCLUDED.mode,
        signing_credits = EXCLUDED.signing_credits,
        is_active = EXCLUDED.is_active,
        updated_at = now();

  -- Tenant 1 member (no membership in tenant 2)
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000004', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000004","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{"30000000-0000-0000-0000-000000000001":"manager"}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT COUNT(*) INTO v_own_count
  FROM api.tenant_signing_status
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'::uuid;

  SELECT COUNT(*) INTO v_other_count
  FROM api.tenant_signing_status
  WHERE tenant_id = '10000000-0000-0000-0000-000000000002'::uuid;

  IF v_own_count = 1 AND v_other_count = 0 THEN
    INSERT INTO test_results VALUES (
      'T2 tenant member sees only own signing config',
      'PASS',
      format('own=%s other=%s', v_own_count, v_other_count)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T2 tenant member sees only own signing config',
      'FAIL',
      format('Expected own=1 and other=0; got own=%s other=%s', v_own_count, v_other_count)
    );
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T3: member pot crear submissió; viewer denegat
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_member_inserted integer := 0;
  v_viewer_denied   boolean := false;
BEGIN
  -- Member insert allowed
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000004', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000004","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  INSERT INTO data.signing_submissions (
    tenant_id,
    source_type,
    status,
    signers,
    initiated_by,
    external_id,
    submitted_at
  )
  VALUES (
    '10000000-0000-0000-0000-000000000001'::uuid,
    'document_existing',
    'pending',
    '[]'::jsonb,
    '20000000-0000-0000-0000-000000000004'::uuid,
    't3-member-' || gen_random_uuid()::text,
    now()
  );

  GET DIAGNOSTICS v_member_inserted = ROW_COUNT;

  -- Viewer insert denied
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000006', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000006","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"viewer","sites":{}}}}}',
    true
  );

  BEGIN
    INSERT INTO data.signing_submissions (
      tenant_id,
      source_type,
      status,
      signers,
      initiated_by,
      external_id,
      submitted_at
    )
    VALUES (
      '10000000-0000-0000-0000-000000000001'::uuid,
      'document_existing',
      'pending',
      '[]'::jsonb,
      '20000000-0000-0000-0000-000000000006'::uuid,
      't3-viewer-' || gen_random_uuid()::text,
      now()
    );
  EXCEPTION
    WHEN OTHERS THEN
      v_viewer_denied := true;
  END;

  IF v_member_inserted = 1 AND v_viewer_denied THEN
    INSERT INTO test_results VALUES (
      'T3 member insert allowed / viewer insert denied',
      'PASS',
      format('member_rows=%s viewer_denied=%s', v_member_inserted, v_viewer_denied)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T3 member insert allowed / viewer insert denied',
      'FAIL',
      format('Expected member_rows=1 and viewer_denied=true; got member_rows=%s viewer_denied=%s', v_member_inserted, v_viewer_denied)
    );
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T4: aïllament cross-tenant de signing_submissions
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_own_count   integer := 0;
  v_other_count integer := 0;
BEGIN
  -- Seed one submission in tenant 2 (owner context)
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}},"10000000-0000-0000-0000-000000000002":{"global_role":"owner","sites":{}}}}}',
    true
  );

  INSERT INTO data.signing_submissions (
    tenant_id,
    source_type,
    status,
    signers,
    initiated_by,
    external_id,
    submitted_at
  )
  VALUES (
    '10000000-0000-0000-0000-000000000002'::uuid,
    'document_existing',
    'pending',
    '[]'::jsonb,
    '20000000-0000-0000-0000-000000000002'::uuid,
    't4-tenant2-' || gen_random_uuid()::text,
    now()
  );

  -- Tenant 1 member should not see tenant 2 rows
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000004', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000004","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT COUNT(*) INTO v_own_count
  FROM api.signing_submissions
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'::uuid
    AND external_id LIKE 't3-member-%';

  SELECT COUNT(*) INTO v_other_count
  FROM api.signing_submissions
  WHERE tenant_id = '10000000-0000-0000-0000-000000000002'::uuid
    AND external_id LIKE 't4-tenant2-%';

  IF v_own_count >= 1 AND v_other_count = 0 THEN
    INSERT INTO test_results VALUES (
      'T4 cross-tenant isolation for signing_submissions',
      'PASS',
      format('own=%s other=%s', v_own_count, v_other_count)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T4 cross-tenant isolation for signing_submissions',
      'FAIL',
      format('Expected own>=1 and other=0; got own=%s other=%s', v_own_count, v_other_count)
    );
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T5: authenticated no pot inserir events directament
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_submission_id uuid;
  v_insert_denied boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000004', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000004","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT id INTO v_submission_id
  FROM data.signing_submissions
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'::uuid
    AND external_id LIKE 't3-member-%'
  ORDER BY created_at DESC
  LIMIT 1;

  BEGIN
    INSERT INTO data.signing_events (
      submission_id,
      tenant_id,
      event_type,
      event_source,
      webhook_event_id,
      payload
    )
    VALUES (
      v_submission_id,
      '10000000-0000-0000-0000-000000000001'::uuid,
      'manual.event',
      'system',
      't5-direct-' || gen_random_uuid()::text,
      '{}'::jsonb
    );
  EXCEPTION
    WHEN OTHERS THEN
      v_insert_denied := true;
  END;

  IF v_insert_denied THEN
    INSERT INTO test_results VALUES (
      'T5 direct insert on signing_events denied',
      'PASS',
      'insert denied as expected for authenticated role'
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T5 direct insert on signing_events denied',
      'FAIL',
      'authenticated should not insert data.signing_events directly'
    );
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T6: append_signing_event idempotent per webhook_event_id
-- -----------------------------------------------------------------------------
SET LOCAL ROLE service_role;

DO $$
DECLARE
  v_submission_id uuid;
  v_event_1       uuid;
  v_event_2       uuid;
  v_count         integer := 0;
  v_error         text := null;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000004', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000004","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT id INTO v_submission_id
  FROM data.signing_submissions
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'::uuid
    AND external_id LIKE 't3-member-%'
  ORDER BY created_at DESC
  LIMIT 1;

  BEGIN
    SELECT api.append_signing_event(
      v_submission_id,
      'submission.pending',
      'webhook',
      't6-webhook-fixed',
      null,
      null,
      'pending',
      'in_progress',
      '{"source":"signing_security_tests"}'::jsonb
    ) INTO v_event_1;

    SELECT api.append_signing_event(
      v_submission_id,
      'submission.pending',
      'webhook',
      't6-webhook-fixed',
      null,
      null,
      'pending',
      'in_progress',
      '{"source":"signing_security_tests"}'::jsonb
    ) INTO v_event_2;
  EXCEPTION
    WHEN OTHERS THEN
      v_error := SQLERRM;
  END;

  SELECT COUNT(*) INTO v_count
  FROM data.signing_events
  WHERE submission_id = v_submission_id
    AND webhook_event_id = 't6-webhook-fixed';

  IF v_error IS NOT NULL THEN
    INSERT INTO test_results VALUES (
      'T6 append_signing_event idempotency',
      'FAIL',
      format('RPC call failed: %s', v_error)
    );
  ELSIF v_event_1 = v_event_2 AND v_count = 1 THEN
    INSERT INTO test_results VALUES (
      'T6 append_signing_event idempotency',
      'PASS',
      format('event=%s count=%s', v_event_1, v_count)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T6 append_signing_event idempotency',
      'FAIL',
      format('Expected same event id and count=1; got event1=%s event2=%s count=%s', v_event_1, v_event_2, v_count)
    );
  END IF;
END $$;

SELECT test_name, status, details
FROM test_results
ORDER BY test_name;

SELECT
  COUNT(*) FILTER (WHERE status = 'PASS') AS pass_count,
  COUNT(*) FILTER (WHERE status = 'FAIL') AS fail_count,
  COUNT(*)                                 AS total_count
FROM test_results;

ROLLBACK;
