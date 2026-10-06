-- Native signing hub: single-signer presential must complete signing_submissions.
-- Regression for create_signing_session dropping signing_group_id when total_signers=1
-- and on_native_signer_completed skipping with no_signing_group.
BEGIN;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

DO $$
DECLARE
  v_tenant   uuid := '10000000-0000-0000-0000-000000000004'; -- Riera
  v_owner    uuid;
  v_group    uuid := gen_random_uuid();
  v_session  uuid;
  v_sub      uuid;
  v_version  uuid := gen_random_uuid();
  v_doc      uuid := gen_random_uuid();
  v_result   uuid := gen_random_uuid();
  v_created  jsonb;
  v_hub      jsonb;
  v_status   text;
  v_sess_gid uuid;
  v_signer_st text;
BEGIN
  SELECT tm.user_id INTO v_owner
  FROM data.tenant_members tm
  WHERE tm.tenant_id = v_tenant
    AND tm.role = 'owner'
    AND tm.is_active = true
  LIMIT 1;

  IF v_owner IS NULL THEN
    INSERT INTO test_results VALUES (
      'native_hub_single_signer setup',
      'FAIL',
      'No owner on Riera tenant'
    );
    RETURN;
  END IF;

  -- Ensure native signing is on for create_signing_session
  INSERT INTO data.system_settings (module, settings)
  VALUES (
    'pdf_converter',
    jsonb_build_object('native_signing_enabled', true, 'remote_signing_token_days', 7)
  )
  ON CONFLICT (module) DO UPDATE
    SET settings = COALESCE(data.system_settings.settings, '{}'::jsonb)
      || jsonb_build_object('native_signing_enabled', true);

  -- Minimal document + version (paths unused by this RPC path)
  INSERT INTO data.documents (id, tenant_id, title, created_by)
  VALUES (v_doc, v_tenant, 'Hub single-signer test', v_owner);

  INSERT INTO data.document_versions (
    id, document_id, version_number, file_path_or_url, storage_type, created_by
  ) VALUES (
    v_version, v_doc, 1, 'tests/hub-single.pdf', 'native', v_owner
  );

  INSERT INTO data.document_versions (
    id, document_id, version_number, file_path_or_url, storage_type, created_by
  ) VALUES (
    v_result, v_doc, 2, 'tests/hub-single-signed.pdf', 'native', v_owner
  );

  PERFORM set_config('request.jwt.claim.role', 'service_role', true);
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  PERFORM set_config(
    'request.jwt.claim',
    json_build_object('role', 'service_role', 'sub', v_owner)::text,
    true
  );

  -- T1: create_signing_session keeps group id even with total_signers = 1
  v_created := api.create_signing_session(
    v_tenant,
    v_version,
    'presential',
    'Client Test',
    'client@example.com',
    'client_accept',
    NULL,
    NULL,
    v_group,
    0,
    1
  );

  v_session := (v_created->>'session_id')::uuid;
  v_sess_gid := NULLIF(v_created->>'signing_group_id', '')::uuid;

  SELECT signing_group_id INTO v_sess_gid
  FROM data.document_signing_sessions
  WHERE id = v_session;

  IF v_sess_gid IS DISTINCT FROM v_group THEN
    INSERT INTO test_results VALUES (
      'T1 create_signing_session persists group for 1 signer',
      'FAIL',
      format('expected %s got %s', v_group, v_sess_gid)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T1 create_signing_session persists group for 1 signer',
      'PASS',
      v_session::text
    );
  END IF;

  -- Hub row as the router would create it
  v_sub := api.create_signing_submission(
    v_tenant,
    'document_existing',
    v_doc,
    v_version,
    NULL,
    'Hub single-signer test',
    'native-test-' || v_session::text,
    jsonb_build_array(jsonb_build_object(
      'name', 'Client Test',
      'email', 'client@example.com',
      'role', 'client_accept',
      'order', 0,
      'status', 'pending'
    )),
    v_owner,
    now(),
    jsonb_build_object(
      'native', true,
      'signing_type', 'presential',
      'primary_session_id', v_session,
      'session_ids', jsonb_build_array(v_session)
    ),
    'native',
    v_group,
    'app_manual'
  );

  -- Simulate stamp finalize
  UPDATE data.document_signing_sessions
     SET status = 'signed',
         result_version_id = v_result,
         timestamps = jsonb_build_object('signed_at', now()),
         updated_at = now()
   WHERE id = v_session;

  v_hub := api.on_native_signer_completed(v_session, v_result, NULL, now());

  IF COALESCE((v_hub->>'skipped')::boolean, false) THEN
    INSERT INTO test_results VALUES (
      'T2 on_native_signer_completed does not skip',
      'FAIL',
      v_hub::text
    );
  ELSIF (v_hub->>'status') IS DISTINCT FROM 'completed'
     OR (v_hub->>'all_signed')::boolean IS DISTINCT FROM true THEN
    INSERT INTO test_results VALUES (
      'T2 on_native_signer_completed completes hub',
      'FAIL',
      v_hub::text
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T2 on_native_signer_completed completes hub',
      'PASS',
      v_hub->>'submission_id'
    );
  END IF;

  SELECT status, signers->0->>'status'
    INTO v_status, v_signer_st
  FROM data.signing_submissions
  WHERE id = v_sub;

  IF v_status IS DISTINCT FROM 'completed' OR v_signer_st IS DISTINCT FROM 'completed' THEN
    INSERT INTO test_results VALUES (
      'T3 submission + signer status completed',
      'FAIL',
      format('status=%s signer=%s', v_status, v_signer_st)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T3 submission + signer status completed',
      'PASS',
      v_sub::text
    );
  END IF;

  -- T4: legacy path — session without group, hub linked only via metadata
  DECLARE
    v_legacy_group uuid := gen_random_uuid();
    v_legacy_sess  uuid := gen_random_uuid();
    v_legacy_sub   uuid;
    v_legacy_hub   jsonb;
  BEGIN
    INSERT INTO data.document_signing_sessions (
      id, tenant_id, document_version_id, signing_token, signing_type,
      status, signer_name, signer_email, signer_role,
      operator_user_id, expires_at, signing_group_id, signer_order, total_signers
    ) VALUES (
      v_legacy_sess, v_tenant, v_version,
      replace(gen_random_uuid()::text, '-', '') || 'legacy',
      'presential', 'signed', 'Legacy Client', 'legacy@example.com', 'client_accept',
      v_owner, now() + interval '7 days', NULL, 0, 1
    );

    v_legacy_sub := api.create_signing_submission(
      v_tenant,
      'document_existing',
      v_doc,
      v_version,
      NULL,
      'Legacy hub test',
      'native-legacy-' || v_legacy_sess::text,
      jsonb_build_array(jsonb_build_object(
        'name', 'Legacy Client',
        'email', 'legacy@example.com',
        'role', 'client_accept',
        'order', 0,
        'status', 'pending'
      )),
      v_owner,
      now(),
      jsonb_build_object(
        'native', true,
        'signing_type', 'presential',
        'primary_session_id', v_legacy_sess,
        'session_ids', jsonb_build_array(v_legacy_sess)
      ),
      'native',
      v_legacy_group,
      'app_manual'
    );

    UPDATE data.document_signing_sessions
       SET result_version_id = v_result,
           timestamps = jsonb_build_object('signed_at', now())
     WHERE id = v_legacy_sess;

    v_legacy_hub := api.on_native_signer_completed(v_legacy_sess, v_result, NULL, now());

    IF COALESCE((v_legacy_hub->>'skipped')::boolean, false)
       OR (v_legacy_hub->>'status') IS DISTINCT FROM 'completed' THEN
      INSERT INTO test_results VALUES (
        'T4 metadata fallback completes legacy single-signer',
        'FAIL',
        v_legacy_hub::text
      );
    ELSE
      INSERT INTO test_results VALUES (
        'T4 metadata fallback completes legacy single-signer',
        'PASS',
        v_legacy_hub->>'submission_id'
      );
    END IF;
  END;

EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES (
    'native_hub_single_signer',
    'FAIL',
    SQLERRM
  );
END;
$$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT COUNT(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'native_signing_hub_single_signer_tests failed: % FAIL', v_fail;
  END IF;
END;
$$;

ROLLBACK;
