-- =============================================================================
-- CP-A2 tests: shares create/list/revoke, legacy_unresolved block, exchange, kill-switch
-- =============================================================================
BEGIN;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;
GRANT ALL ON TABLE test_results TO service_role;
GRANT ALL ON TABLE test_results TO authenticated;

-- Helper: switch to service_role with JWT claim (auth.role() reads JWT, not bare RESET ROLE).
-- Use SET ROLE (not LOCAL): SET LOCAL inside a function reverts on function exit.
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

SELECT pg_temp.as_authenticated_owner();

-- Ensure published CIR on project 101 (idempotent with CPA1)
DO $$
DECLARE
  v_draft uuid;
  v_ver uuid;
BEGIN
  UPDATE data.projects SET status = 'completed'
  WHERE id = '51000000-0000-0000-0000-000000000101';

  IF NOT EXISTS (
    SELECT 1 FROM data.customer_intervention_reports r
    WHERE r.project_id = '51000000-0000-0000-0000-000000000101'
      AND r.current_published_version_id IS NOT NULL
  ) THEN
    v_draft := api.upsert_customer_intervention_report_draft(
      '51000000-0000-0000-0000-000000000101'::uuid,
      'ca',
      '<p>Share test</p>',
      jsonb_build_object(
        'tenant', jsonb_build_object('name', 'Volt'),
        'checklist_items', jsonb_build_array(jsonb_build_object('label', 'OK'))
      ),
      '[]'::jsonb,
      NULL
    );
    PERFORM api.prepare_customer_intervention_report_media(v_draft);
    v_ver := api.publish_customer_intervention_report(v_draft);
  END IF;
END $$;

-- T1: create share returns secret once; list sees active without hash
DO $$
DECLARE
  v_out jsonb;
  v_secret text;
  v_n int;
  v_hash_visible boolean;
BEGIN
  v_out := api.create_customer_report_share(
    '51000000-0000-0000-0000-000000000101'::uuid,
    '80000000-0000-0000-0000-000000000102'::uuid,
    48,
    NULL, NULL, NULL, NULL
  );
  v_secret := v_out->>'secret';

  SELECT COUNT(*) INTO v_n
  FROM api.list_customer_report_shares('51000000-0000-0000-0000-000000000101'::uuid)
  WHERE id = (v_out->>'share_id')::uuid AND is_active;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'api' AND table_name = 'customer_report_shares'
      AND column_name = 'token_hash'
  ) INTO v_hash_visible;

  IF v_secret ~ '^[0-9a-f]{64}$' AND v_n = 1 AND NOT v_hash_visible THEN
    INSERT INTO test_results VALUES ('T1 create+list secret once', 'PASS', v_out->>'share_id');
  ELSE
    INSERT INTO test_results VALUES (
      'T1 create+list secret once', 'FAIL',
      format('secret_ok=%s n=%s hash_col=%s', v_secret ~ '^[0-9a-f]{64}$', v_n, v_hash_visible)
    );
  END IF;

  -- stash for later tests
  CREATE TEMP TABLE IF NOT EXISTS share_ctx (
    share_id uuid,
    secret text
  ) ON COMMIT DROP;
  DELETE FROM share_ctx;
  INSERT INTO share_ctx VALUES ((v_out->>'share_id')::uuid, v_secret);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T1 create+list secret once', 'FAIL', SQLERRM);
END $$;

-- T2: exchange token → session (service_role path via SET ROLE)
DO $$
DECLARE
  v_secret text;
  v_hash bytea;
  v_ex jsonb;
BEGIN
  SELECT secret INTO v_secret FROM share_ctx LIMIT 1;
  v_hash := data.hash_customer_portal_secret(v_secret);

  PERFORM pg_temp.as_service_role();
  v_ex := api.exchange_customer_report_share_token(v_hash, 30, '127.0.0.1'::inet, 'test-agent', '127.0.0.1');
  PERFORM pg_temp.as_authenticated_owner();

  IF (v_ex->>'ok')::boolean AND (v_ex->>'session_secret') ~ '^[0-9a-f]{64}$' THEN
    INSERT INTO test_results VALUES ('T2 exchange share token', 'PASS', v_ex->>'session_id');
    CREATE TEMP TABLE IF NOT EXISTS sess_ctx (session_secret text) ON COMMIT DROP;
    DELETE FROM sess_ctx;
    INSERT INTO sess_ctx VALUES (v_ex->>'session_secret');
  ELSE
    INSERT INTO test_results VALUES ('T2 exchange share token', 'FAIL', v_ex::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 exchange share token', 'FAIL', SQLERRM);
  PERFORM pg_temp.as_authenticated_owner();
END $$;

-- T3: revoke invalidates session_version / resolve
DO $$
DECLARE
  v_share uuid;
  v_sess text;
  v_hash bytea;
  v_res jsonb;
BEGIN
  SELECT share_id INTO v_share FROM share_ctx;
  PERFORM api.revoke_customer_report_share(v_share, 'test revoke');

  SELECT session_secret INTO v_sess FROM sess_ctx;
  v_hash := data.hash_customer_portal_secret(v_sess);

  PERFORM pg_temp.as_service_role();
  v_res := api.resolve_customer_portal_share_session(v_hash, 'report_view', NULL, NULL, 'req-1');
  PERFORM pg_temp.as_authenticated_owner();

  IF (v_res->>'ok') IS DISTINCT FROM 'true' THEN
    INSERT INTO test_results VALUES ('T3 revoke denies session', 'PASS', v_res::text);
  ELSE
    INSERT INTO test_results VALUES ('T3 revoke denies session', 'FAIL', v_res::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 revoke denies session', 'FAIL', SQLERRM);
  PERFORM pg_temp.as_authenticated_owner();
END $$;

-- T4: legacy_unresolved blocks share
DO $$
DECLARE
  v_ok boolean := false;
BEGIN
  -- Fixture rows: postgres (table writes revoked from authenticated in P1).
  RESET ROLE;
  INSERT INTO data.projects (
    id, tenant_id, type, name, status, visibility, site_id, client_id, created_by
  ) VALUES (
    '51000000-0000-0000-0000-00000000a201',
    '10000000-0000-0000-0000-000000000003',
    'work_order', 'CP-A2 unresolved', 'completed', 'company',
    '30000000-0000-0000-0000-000000000004',
    '80000000-0000-0000-0000-000000000101',
    '20000000-0000-0000-0000-000000000002'
  ) ON CONFLICT (id) DO NOTHING;

  INSERT INTO data.customer_intervention_reports (
    tenant_id, project_id, legacy_unresolved, created_by
  ) VALUES (
    '10000000-0000-0000-0000-000000000003',
    '51000000-0000-0000-0000-00000000a201',
    true,
    '20000000-0000-0000-0000-000000000002'
  ) ON CONFLICT (tenant_id, project_id, report_type) DO UPDATE
    SET legacy_unresolved = true;

  PERFORM pg_temp.as_authenticated_owner();

  BEGIN
    PERFORM api.create_customer_report_share(
      '51000000-0000-0000-0000-00000000a201'::uuid,
      '80000000-0000-0000-0000-000000000102'::uuid,
      24, NULL, NULL, NULL, NULL
    );
    v_ok := true;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%legacy_unresolved%' THEN
      INSERT INTO test_results VALUES ('T4 unresolved blocks share', 'PASS', SQLERRM);
    ELSE
      INSERT INTO test_results VALUES ('T4 unresolved blocks share', 'FAIL', SQLERRM);
    END IF;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T4 unresolved blocks share', 'FAIL', 'create succeeded');
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T4 unresolved blocks share', 'FAIL', SQLERRM);
  PERFORM pg_temp.as_authenticated_owner();
END $$;

-- T5: email intent has no secret; fulfill returns secret; fail revokes
DO $$
DECLARE
  v_intent uuid;
  v_ful jsonb;
  v_share uuid;
  v_revoked timestamptz;
BEGIN
  v_intent := api.enqueue_customer_report_share_email(
    '51000000-0000-0000-0000-000000000101'::uuid,
    '83000000-0000-0000-0000-000000000101'::uuid,
    'cpa2-email-1',
    24,
    NULL,
    '80000000-0000-0000-0000-000000000102'::uuid
  );

  PERFORM pg_temp.as_service_role();
  v_ful := api.fulfill_customer_report_share_delivery_intent(v_intent);
  v_share := (v_ful->>'share_id')::uuid;
  PERFORM api.mark_customer_report_share_delivery_result(v_intent, false, 'smtp_timeout');
  SELECT revoked_at INTO v_revoked FROM data.customer_report_shares WHERE id = v_share;
  PERFORM pg_temp.as_authenticated_owner();

  IF v_intent IS NOT NULL
     AND (v_ful->>'secret') ~ '^[0-9a-f]{64}$'
     AND v_revoked IS NOT NULL THEN
    INSERT INTO test_results VALUES ('T5 email intent fulfill+fail revoke', 'PASS', v_intent::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T5 email intent fulfill+fail revoke', 'FAIL',
      format('intent=%s ful=%s revoked=%s', v_intent, v_ful, v_revoked)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 email intent fulfill+fail revoke', 'FAIL', SQLERRM);
  PERFORM pg_temp.as_authenticated_owner();
END $$;

-- T6: entitlements expose can_create_shares
DO $$
DECLARE
  v_ent jsonb;
BEGIN
  v_ent := data.resolve_portal_entitlements('10000000-0000-0000-0000-000000000003'::uuid);
  -- CP-C / CP-B rollout: mode_effective is portal (super-set of share_only)
  IF (v_ent->'customer_portal'->>'can_create_shares')::boolean
     AND (v_ent->'customer_portal'->>'mode_effective') IN ('share_only', 'portal')
     AND (v_ent->'customer_portal'->>'effective')::boolean THEN
    INSERT INTO test_results VALUES ('T6 entitlements customer_portal', 'PASS', v_ent->'customer_portal');
  ELSE
    INSERT INTO test_results VALUES ('T6 entitlements customer_portal', 'FAIL', v_ent::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 entitlements customer_portal', 'FAIL', SQLERRM);
END $$;

-- T7: unknown token → ledger + identical deny
DO $$
DECLARE
  v_ex jsonb;
  v_n int;
  v_fake bytea := data.hash_customer_portal_secret(repeat('ab', 32));
BEGIN
  PERFORM pg_temp.as_service_role();
  v_ex := api.exchange_customer_report_share_token(v_fake, 30, '10.0.0.1'::inet, 'ua', '10.0.0.1');
  SELECT COUNT(*) INTO v_n
  FROM data.customer_portal_unknown_token_ledger
  WHERE ip_address = '10.0.0.1'::inet;
  PERFORM pg_temp.as_authenticated_owner();

  IF (v_ex->>'ok') IS DISTINCT FROM 'true' AND v_n >= 1 THEN
    INSERT INTO test_results VALUES ('T7 unknown token ledger', 'PASS', v_ex::text);
  ELSE
    INSERT INTO test_results VALUES ('T7 unknown token ledger', 'FAIL', format('ex=%s n=%s', v_ex, v_n));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T7 unknown token ledger', 'FAIL', SQLERRM);
  PERFORM pg_temp.as_authenticated_owner();
END $$;

-- T8: stale processing intents are reclaimed; fresh processing is not
DO $$
DECLARE
  v_stale uuid;
  v_fresh uuid;
  v_hit uuid;
BEGIN
  v_stale := api.enqueue_customer_report_share_email(
    '51000000-0000-0000-0000-000000000101'::uuid,
    '83000000-0000-0000-0000-000000000101'::uuid,
    'cpa2-reclaim-stale',
    24,
    NULL,
    '80000000-0000-0000-0000-000000000102'::uuid
  );
  v_fresh := api.enqueue_customer_report_share_email(
    '51000000-0000-0000-0000-000000000101'::uuid,
    '83000000-0000-0000-0000-000000000101'::uuid,
    'cpa2-reclaim-fresh',
    24,
    NULL,
    '80000000-0000-0000-0000-000000000102'::uuid
  );

  -- Direct UPDATE is service/owner only (clients cannot write intents).
  PERFORM pg_temp.as_service_role();
  UPDATE data.customer_report_share_delivery_intents
  SET status = 'processing',
      updated_at = now() - interval '10 minutes'
  WHERE id = v_stale;

  UPDATE data.customer_report_share_delivery_intents
  SET status = 'processing',
      updated_at = now()
  WHERE id = v_fresh;

  SELECT c.id INTO v_hit
  FROM api.claim_customer_report_share_delivery_intents(50, 300) c
  WHERE c.id = v_stale;

  IF v_hit IS DISTINCT FROM v_stale THEN
    INSERT INTO test_results VALUES ('T8 reclaim stale processing', 'FAIL',
      format('stale not claimed: %s', v_hit));
  ELSE
    v_hit := NULL;
    SELECT c.id INTO v_hit
    FROM api.claim_customer_report_share_delivery_intents(50, 300) c
    WHERE c.id = v_fresh;

    IF v_hit IS NOT NULL THEN
      INSERT INTO test_results VALUES ('T8 reclaim stale processing', 'FAIL',
        'fresh processing was claimed');
    ELSE
      INSERT INTO test_results VALUES ('T8 reclaim stale processing', 'PASS', v_stale::text);
    END IF;
  END IF;

  PERFORM pg_temp.as_authenticated_owner();
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T8 reclaim stale processing', 'FAIL', SQLERRM);
  PERFORM pg_temp.as_authenticated_owner();
END $$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT COUNT(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'CP-A2 tests failed: % failures', v_fail;
  END IF;
END $$;

ROLLBACK;
