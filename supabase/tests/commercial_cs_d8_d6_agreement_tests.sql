-- CS-D8 / CS-D6: accepted-before-contract, no quote flip on agreement sign,
-- multi-signer peer decline, DocuSeal completed gate.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_project uuid := '51000000-0000-0000-0000-000000000101';
  v_quote uuid;
  v_agreement uuid;
  v_version uuid;
  v_doc uuid;
  v_req uuid;
  v_sub uuid;
  v_group uuid := gen_random_uuid();
  v_sess_issuer uuid := gen_random_uuid();
  v_sess_client uuid := gen_random_uuid();
  v_intent uuid;
  v_apply jsonb;
  v_quote_status text;
  v_version_status text;
  v_req_status text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  PERFORM set_config(
    'request.jwt.claim',
    json_build_object(
      'sub', v_owner,
      'role', 'authenticated',
      'app_metadata', json_build_object(
        'user_tenants', json_build_object(
          v_tenant::text, json_build_object('global_role', 'owner', 'sites', json_build_object())
        ),
        'user_permissions', json_build_object(
          v_tenant::text, json_build_object(
            'global_permissions', json_build_array('*'),
            'sites', json_build_object()
          )
        )
      )
    )::text,
    true
  );
  PERFORM set_config(
    'request.headers',
    json_build_object('x-tenant-id', v_tenant)::text,
    true
  );

  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb)
    || jsonb_build_object(
      'commercial',
      COALESCE(settings->'commercial', '{}'::jsonb)
        || jsonb_build_object('decision_requests_enabled', true)
    )
  WHERE id = v_tenant;

  -- 1) prepare rejects issued (not accepted) ---------------------------------
  v_quote := api.issue_commercial_document(
    v_project, 'quote', true, gen_random_uuid(), NULL, 'separate_agreement', NULL
  );
  BEGIN
    PERFORM api.prepare_agreement_from_quote(
      v_quote,
      '76100000-0000-0000-0000-000000000001'::uuid,
      'none',
      gen_random_uuid()
    );
    RAISE EXCEPTION 'CS-D8 issued quote prepare was allowed';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%quote_not_accepted%' THEN
      RAISE;
    END IF;
  END;

  PERFORM api.accept_commercial_document(
    v_quote, '{"method":"sql_test"}'::jsonb, gen_random_uuid()
  );
  v_agreement := api.prepare_agreement_from_quote(
    v_quote,
    '76100000-0000-0000-0000-000000000001'::uuid,
    'none',
    gen_random_uuid()
  );
  SELECT active_version_id INTO v_version
  FROM data.commercial_agreements WHERE id = v_agreement;

  INSERT INTO data.documents (tenant_id, title, category, required_permissions, created_by)
  VALUES (v_tenant, 'CS-D8 signed stub', 'commercial', '{}', v_owner)
  RETURNING id INTO v_doc;

  UPDATE data.commercial_agreement_versions
  SET status = 'pending_signature', rendered_document_id = v_doc
  WHERE id = v_version;

  -- 2) finalize must not change quote away from accepted ---------------------
  PERFORM data.finalize_commercial_agreement_version(v_version, v_doc, v_owner, CURRENT_DATE);
  SELECT status INTO v_quote_status FROM data.commercial_documents WHERE id = v_quote;
  IF v_quote_status IS DISTINCT FROM 'accepted' THEN
    RAISE EXCEPTION 'CS-D8 finalize flipped quote to %', v_quote_status;
  END IF;

  -- Fresh agreement for apply / multi-signer ---------------------------------
  v_quote := api.issue_commercial_document(
    v_project, 'quote', true, gen_random_uuid(), NULL, 'separate_agreement', NULL
  );
  PERFORM api.accept_commercial_document(
    v_quote, '{"method":"sql_test"}'::jsonb, gen_random_uuid()
  );
  v_agreement := api.prepare_agreement_from_quote(
    v_quote,
    '76100000-0000-0000-0000-000000000001'::uuid,
    'none',
    gen_random_uuid()
  );
  SELECT active_version_id INTO v_version
  FROM data.commercial_agreements WHERE id = v_agreement;

  INSERT INTO data.documents (tenant_id, title, category, required_permissions, created_by)
  VALUES (v_tenant, 'CS-D6 render', 'commercial', '{}', v_owner)
  RETURNING id INTO v_doc;
  INSERT INTO data.document_versions (
    document_id, version_number, storage_type, file_path_or_url, mime_type, created_by
  ) VALUES (
    v_doc, 1, 'native', 'csd6/agreement.pdf', 'application/pdf', v_owner
  );

  UPDATE data.commercial_agreement_versions
  SET status = 'pending_signature',
      rendered_document_id = v_doc,
      content_hash = COALESCE(content_hash, 'cs-d6-hash')
  WHERE id = v_version;

  v_req := api.create_commercial_decision_request(
    'agreement_version', v_version, now() + interval '7 days', gen_random_uuid()
  );

  -- 3) multi-signer: peer declined → request declined, quote stays accepted --
  INSERT INTO data.document_signing_sessions (
    id, tenant_id, document_version_id, signing_token, signing_type, status,
    signer_name, signer_role, operator_user_id, expires_at,
    signing_group_id, signer_order, total_signers
  ) VALUES
  (
    v_sess_issuer, v_tenant, (SELECT id FROM data.document_versions WHERE document_id = v_doc LIMIT 1),
    replace(gen_random_uuid()::text, '-', '') || 'iss',
    'presential', 'signed', 'Issuer', 'issuer', v_owner, now() + interval '7 days',
    v_group, 0, 2
  ),
  (
    v_sess_client, v_tenant, (SELECT id FROM data.document_versions WHERE document_id = v_doc LIMIT 1),
    replace(gen_random_uuid()::text, '-', '') || 'cli',
    'presential', 'declined', 'Client', 'client', v_owner, now() + interval '7 days',
    v_group, 1, 2
  );

  INSERT INTO data.signing_submissions (
    tenant_id, source_type, external_id, status, signing_provider, native_group_id,
    signers, metadata, initiated_by
  ) VALUES (
    v_tenant, 'document_existing', 'cs-d6-' || v_group::text, 'in_progress',
    'native', v_group,
    jsonb_build_array(
      jsonb_build_object('name', 'Issuer', 'role', 'issuer', 'order', 0, 'status', 'completed'),
      jsonb_build_object('name', 'Client', 'role', 'client', 'order', 1, 'status', 'declined')
    ),
    jsonb_build_object(
      'native', true,
      'session_ids', jsonb_build_array(v_sess_issuer, v_sess_client),
      'primary_session_id', v_sess_issuer,
      'commercial_decision_request_id', v_req
    ),
    v_owner
  )
  RETURNING id INTO v_sub;

  v_intent := api.register_commercial_signing_intent(
    v_quote, v_sess_issuer, 'accept', gen_random_uuid(), v_sub, v_req
  );
  IF v_intent IS NULL THEN
    RAISE EXCEPTION 'CS-D6 register intent failed';
  END IF;

  -- Trigger / explicit apply on declined peer (issuer already signed).
  PERFORM data.apply_commercial_signing_intent_for_session(v_sess_client);

  SELECT status INTO v_req_status FROM data.commercial_decision_requests WHERE id = v_req;
  SELECT status INTO v_version_status FROM data.commercial_agreement_versions WHERE id = v_version;
  SELECT status INTO v_quote_status FROM data.commercial_documents WHERE id = v_quote;

  IF v_req_status IS DISTINCT FROM 'declined' THEN
    RAISE EXCEPTION 'CS-D6 expected declined request, got %', v_req_status;
  END IF;
  IF v_version_status IS DISTINCT FROM 'declined' THEN
    RAISE EXCEPTION 'CS-D6 expected declined version, got %', v_version_status;
  END IF;
  IF v_quote_status IS DISTINCT FROM 'accepted' THEN
    RAISE EXCEPTION 'CS-D6 peer decline flipped quote to %', v_quote_status;
  END IF;

  -- 4) DocuSeal apply requires completed submission -------------------------
  v_quote := api.issue_commercial_document(
    v_project, 'quote', true, gen_random_uuid(), NULL, 'separate_agreement', NULL
  );
  PERFORM api.accept_commercial_document(
    v_quote, '{"method":"sql_test"}'::jsonb, gen_random_uuid()
  );
  v_agreement := api.prepare_agreement_from_quote(
    v_quote,
    '76100000-0000-0000-0000-000000000001'::uuid,
    'none',
    gen_random_uuid()
  );
  SELECT active_version_id INTO v_version
  FROM data.commercial_agreements WHERE id = v_agreement;
  UPDATE data.commercial_agreement_versions
  SET status = 'pending_signature',
      rendered_document_id = v_doc,
      content_hash = COALESCE(content_hash, 'cs-d6-ds')
  WHERE id = v_version;
  v_req := api.create_commercial_decision_request(
    'agreement_version', v_version, now() + interval '7 days', gen_random_uuid()
  );

  INSERT INTO data.signing_submissions (
    tenant_id, source_type, external_id, status, signing_provider, signers, metadata
  ) VALUES (
    v_tenant, 'document_existing', 'cs-d6-ds-' || gen_random_uuid()::text, 'in_progress',
    'docuseal',
    jsonb_build_array(
      jsonb_build_object('name', 'Issuer', 'role', 'issuer', 'email', 'a@t.test'),
      jsonb_build_object('name', 'Client', 'role', 'client', 'email', 'c@t.test')
    ),
    jsonb_build_object(
      'commercial_bridge', true,
      'decision_request_id', v_req::text
    )
  )
  RETURNING id INTO v_sub;

  v_apply := data.apply_commercial_decision_from_docuseal_submission(v_sub, 'accepted');
  IF v_apply->>'code' IS DISTINCT FROM 'submission_not_completed' THEN
    RAISE EXCEPTION 'CS-D6 DocuSeal incomplete should fail, got %', v_apply;
  END IF;

  UPDATE data.signing_submissions SET status = 'completed' WHERE id = v_sub;
  v_apply := data.apply_commercial_decision_from_docuseal_submission(v_sub, 'accepted');
  IF COALESCE((v_apply->>'ok')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'CS-D6 DocuSeal completed apply failed: %', v_apply;
  END IF;
  SELECT status INTO v_quote_status FROM data.commercial_documents WHERE id = v_quote;
  IF v_quote_status IS DISTINCT FROM 'accepted' THEN
    RAISE EXCEPTION 'CS-D8 DocuSeal apply flipped quote to %', v_quote_status;
  END IF;

  RAISE NOTICE 'CS-D8/D6 agreement tests passed';
END;
$$;

ROLLBACK;
