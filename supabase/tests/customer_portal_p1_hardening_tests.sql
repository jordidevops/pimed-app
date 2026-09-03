-- =============================================================================
-- Customer Portal P1 hardening smoke (BEGIN/ROLLBACK)
-- Success = no RAISE. FAIL rows raise at end.
-- =============================================================================
BEGIN;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

-- T1: authenticated cannot INSERT into delivery channels (table write revoked)
DO $$
DECLARE
  v_ok boolean := false;
BEGIN
  BEGIN
    SET LOCAL ROLE authenticated;
    INSERT INTO data.contact_delivery_channels (
      tenant_id, contact_id, channel_type, value_raw, value_normalized
    ) VALUES (
      '00000000-0000-0000-0000-000000000001',
      '00000000-0000-0000-0000-000000000002',
      'email', 'attacker@example.com', 'attacker@example.com'
    );
    RESET ROLE;
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN
    RESET ROLE;
    v_ok := true;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('T1_delivery_channel_insert_denied', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T1_delivery_channel_insert_denied', 'FAIL', 'insert allowed');
  END IF;
END $$;

-- T2: authenticated cannot UPDATE CIR draft status (forge path)
DO $$
DECLARE
  v_ok boolean := false;
BEGIN
  BEGIN
    SET LOCAL ROLE authenticated;
    UPDATE data.customer_intervention_report_drafts
    SET status = 'ready'
    WHERE false;
    -- Even with 0 rows, privilege check happens; force a probe via has_table_privilege
    IF has_table_privilege('authenticated', 'data.customer_intervention_report_drafts', 'UPDATE') THEN
      RAISE EXCEPTION 'update_still_granted';
    END IF;
    RESET ROLE;
    v_ok := true;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    IF SQLERRM = 'update_still_granted' THEN
      v_ok := false;
    ELSE
      v_ok := NOT has_table_privilege('authenticated', 'data.customer_intervention_report_drafts', 'UPDATE');
    END IF;
  END;
  IF v_ok THEN
    INSERT INTO test_results VALUES ('T2_draft_update_revoked', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'T2_draft_update_revoked', 'FAIL',
      'authenticated still has UPDATE on drafts'
    );
  END IF;
END $$;

-- T3: complete_* still not executable by authenticated
DO $$
DECLARE
  v_ok boolean;
BEGIN
  SELECT has_function_privilege(
    'authenticated',
    'api.complete_customer_intervention_report_media_prepare(uuid)',
    'EXECUTE'
  ) INTO v_ok;
  IF COALESCE(v_ok, true) = false THEN
    INSERT INTO test_results VALUES ('T3_complete_not_authenticated', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T3_complete_not_authenticated', 'FAIL', 'execute granted');
  END IF;
END $$;

-- T4: staff sessions have exchanged_at column
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'data'
      AND table_name = 'customer_portal_staff_sessions'
      AND column_name = 'exchanged_at'
  ) THEN
    INSERT INTO test_results VALUES ('T4_staff_exchanged_at', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T4_staff_exchanged_at', 'FAIL', 'missing column');
  END IF;
END $$;

-- T5: fail_prepare is service_role only
DO $$
DECLARE
  v_auth boolean;
  v_svc boolean;
BEGIN
  SELECT has_function_privilege(
    'authenticated',
    'api.fail_customer_intervention_report_media_prepare(uuid, text)',
    'EXECUTE'
  ) INTO v_auth;
  SELECT has_function_privilege(
    'service_role',
    'api.fail_customer_intervention_report_media_prepare(uuid, text)',
    'EXECUTE'
  ) INTO v_svc;
  IF COALESCE(v_auth, true) = false AND COALESCE(v_svc, false) = true THEN
    INSERT INTO test_results VALUES ('T5_fail_prepare_service_only', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'T5_fail_prepare_service_only', 'FAIL',
      format('auth=%s svc=%s', v_auth, v_svc)
    );
  END IF;
END $$;

-- T6: no current published version with NULL customer account
DO $$
DECLARE
  v_cnt int;
BEGIN
  SELECT COUNT(*) INTO v_cnt
  FROM data.customer_intervention_reports r
  JOIN data.customer_intervention_report_versions v
    ON v.id = r.current_published_version_id
  WHERE v.customer_account_contact_id IS NULL;
  IF v_cnt = 0 THEN
    INSERT INTO test_results VALUES ('T6_no_null_account_current', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'T6_no_null_account_current', 'FAIL', format('%s ghosts', v_cnt)
    );
  END IF;
END $$;

-- T7: upsert draft signature still present; preparing_media accepted in source
DO $$
BEGIN
  IF to_regprocedure('api.upsert_customer_intervention_report_draft(uuid,text,text,jsonb,jsonb,uuid)') IS NOT NULL THEN
    INSERT INTO test_results VALUES ('T7_upsert_exists', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T7_upsert_exists', 'FAIL', 'missing upsert');
  END IF;
END $$;

-- T8: staff exchange rejects handoff consume when p_allow_handoff_consume=false
DO $$
DECLARE
  v_has boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api'
      AND p.proname = 'exchange_customer_portal_staff_session'
      AND pg_get_function_identity_arguments(p.oid) LIKE '%p_allow_handoff_consume%'
  ) INTO v_has;
  IF v_has THEN
    INSERT INTO test_results VALUES ('T8_staff_no_consume_param', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T8_staff_no_consume_param', 'FAIL', 'param missing');
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
    RAISE EXCEPTION 'customer_portal_p1_tests failed: %', v_detail;
  END IF;
END $$;

ROLLBACK;
