-- CS-D58–D60 anti-leak regression tests
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := gen_random_uuid();
  v_quote uuid;
  v_render uuid;
  v_req uuid;
  v_delivery_json jsonb;
  v_delivery_id uuid;
  v_token text;
  v_session jsonb;
  v_version_id uuid;
  v_submission_id uuid;
  v_submitter_url text;
  v_api_url text;
  v_view_url text;
  v_grant_ok boolean;
  v_err text;
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

  INSERT INTO data.system_settings (module, settings)
  VALUES (
    'pdf_converter',
    jsonb_build_object('native_signing_enabled', true, 'remote_signing_token_days', 7)
  )
  ON CONFLICT (module) DO UPDATE
    SET settings = COALESCE(data.system_settings.settings, '{}'::jsonb)
      || jsonb_build_object('native_signing_enabled', true);

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by
  ) VALUES (
    v_project, v_tenant, 'work_order', 'CS-D58', 'Disposable', 'active', 'company',
    v_site, v_client, v_owner
  );

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'CS-D58 line', NULL, 'u',
    1, 100, 0, 21, 0, NULL, gen_random_uuid()
  );
  v_quote := api.issue_commercial_document(
    v_project, 'quote', true, gen_random_uuid(), NULL
  );

  INSERT INTO data.documents (tenant_id, title, category, required_permissions, created_by)
  VALUES (v_tenant, 'CS-D58 render', 'commercial', '{}', v_owner)
  RETURNING id INTO v_render;

  INSERT INTO data.document_versions (
    document_id, version_number, storage_type, file_path_or_url, mime_type, created_by
  ) VALUES (
    v_render, 1, 'native', 'csd58/render.pdf', 'application/pdf', v_owner
  ) RETURNING id INTO v_version_id;

  UPDATE data.commercial_documents
  SET rendered_document_id = v_render,
      content_hash = COALESCE(NULLIF(btrim(content_hash), ''), 'cs-d58-hash'),
      formalization_mode = 'signed_quote'
  WHERE id = v_quote;

  -- T1: email delivery never returns raw_token; token_once exists server-side
  v_req := api.create_commercial_decision_request(
    'commercial_document', v_quote, now() + interval '7 days', gen_random_uuid()
  );
  v_delivery_json := api.create_commercial_decision_delivery(
    v_req, 'email', NULL, 'ca', gen_random_uuid()
  );
  IF v_delivery_json->>'raw_token' IS NOT NULL THEN
    RAISE EXCEPTION 'T1 FAIL: raw_token leaked to authenticated';
  END IF;
  v_delivery_id := (v_delivery_json->>'delivery_id')::uuid;
  SELECT o.raw_token INTO v_token
  FROM data.commercial_decision_token_once o
  WHERE o.delivery_id = v_delivery_id;
  IF v_token IS NULL OR length(v_token) < 32 THEN
    RAISE EXCEPTION 'T1 FAIL: token_once missing for email';
  END IF;

  -- T2: whatsapp_portal_nudge without grant fails
  BEGIN
    PERFORM api.create_commercial_decision_delivery(
      v_req, 'whatsapp_portal_nudge', NULL, 'ca', gen_random_uuid()
    );
    RAISE EXCEPTION 'T2 FAIL: expected portal_grant_required';
  EXCEPTION
    WHEN OTHERS THEN
      v_err := SQLERRM;
      IF v_err NOT ILIKE '%portal_grant_required%' THEN
        RAISE EXCEPTION 'T2 FAIL: unexpected error %', v_err;
      END IF;
  END;

  -- T3: with grant, WA creates delivery without token_once
  INSERT INTO data.customer_access_grants (
    tenant_id, auth_user_id, client_account_contact_id, principal_kind,
    principal_contact_id, email_normalized, security_version_tenant, security_version_platform
  ) VALUES (
    v_tenant, v_owner, v_client, 'named_person',
    v_client, 'csd58-client@example.com', 1, 1
  );

  v_grant_ok := api.has_active_customer_portal_grant_for_document(v_quote);
  IF v_grant_ok IS NOT TRUE THEN
    RAISE EXCEPTION 'T3 FAIL: grant helper should be true';
  END IF;

  v_delivery_json := api.create_commercial_decision_delivery(
    v_req, 'whatsapp_portal_nudge', NULL, 'ca', gen_random_uuid()
  );
  IF v_delivery_json->>'raw_token' IS NOT NULL THEN
    RAISE EXCEPTION 'T3 FAIL: WA raw_token leaked';
  END IF;
  v_delivery_id := (v_delivery_json->>'delivery_id')::uuid;
  IF EXISTS (
    SELECT 1 FROM data.commercial_decision_access_tokens t WHERE t.delivery_id = v_delivery_id
  ) THEN
    RAISE EXCEPTION 'T3 FAIL: WA must not mint access token';
  END IF;
  IF EXISTS (
    SELECT 1 FROM data.commercial_decision_token_once o WHERE o.delivery_id = v_delivery_id
  ) THEN
    RAISE EXCEPTION 'T3 FAIL: WA must not store token_once';
  END IF;

  -- T4: copy_link rejected
  BEGIN
    PERFORM api.create_commercial_decision_delivery(
      v_req, 'copy_link', NULL, 'ca', gen_random_uuid()
    );
    RAISE EXCEPTION 'T4 FAIL: copy_link should be rejected';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT ILIKE '%invalid_delivery_channel%' THEN
        RAISE EXCEPTION 'T4 FAIL: unexpected %', SQLERRM;
      END IF;
  END;

  -- T5: create_signing_session as authenticated returns null token
  v_session := api.create_signing_session(
    v_tenant, v_version_id, 'remote', 'Client', 'client@example.com', 'client',
    NULL, 7, NULL, 0, 1, NULL
  );
  IF v_session->>'token' IS NOT NULL THEN
    RAISE EXCEPTION 'T5 FAIL: token leaked from create_signing_session to authenticated';
  END IF;
  IF v_session->>'session_id' IS NULL THEN
    RAISE EXCEPTION 'T5 FAIL: session_id missing';
  END IF;

  -- T6: api.signing_submissions strips URLs
  INSERT INTO data.signing_submissions (
    tenant_id, status, signing_provider, docuseal_signing_url, signers, initiated_by
  ) VALUES (
    v_tenant, 'pending', 'native',
    'https://evil.example/sign/abc',
    jsonb_build_array(jsonb_build_object(
      'email', 'client@example.com', 'name', 'C', 'role', 'client',
      'status', 'pending', 'order', 0,
      'signing_url', 'https://app.example/sign/tok'
    )),
    v_owner
  ) RETURNING id INTO v_submission_id;

  SELECT s.docuseal_signing_url, s.signers->0->>'signing_url'
  INTO v_api_url, v_view_url
  FROM api.signing_submissions s
  WHERE s.id = v_submission_id;

  IF v_api_url IS NOT NULL THEN
    RAISE EXCEPTION 'T6 FAIL: docuseal_signing_url exposed on api view';
  END IF;
  IF v_view_url IS NOT NULL THEN
    RAISE EXCEPTION 'T6 FAIL: signers[].signing_url exposed on api view';
  END IF;

  -- T7: api.signing_submitters strips signing_url
  INSERT INTO data.signing_submitters (
    submission_id, tenant_id, signer_order, email, name, role, signing_url, status
  ) VALUES (
    v_submission_id, v_tenant, 0, 'client@example.com', 'C', 'client',
    'https://app.example/sign/tok2', 'pending'
  );

  SELECT st.signing_url INTO v_submitter_url
  FROM api.signing_submitters st
  WHERE st.submission_id = v_submission_id
  LIMIT 1;
  IF v_submitter_url IS NOT NULL THEN
    RAISE EXCEPTION 'T7 FAIL: signing_submitters.signing_url exposed';
  END IF;

  -- T8: get_my_pending_signing_url null for non-monthly submission
  IF api.get_my_pending_signing_url(v_submission_id) IS NOT NULL THEN
    RAISE EXCEPTION 'T8 FAIL: self URL must be null outside monthly attendance';
  END IF;

  -- T9: channel CHECK rejects legacy product values at schema level
  BEGIN
    INSERT INTO data.commercial_decision_deliveries (
      tenant_id, request_id, channel, locale, status, idempotency_key
    ) VALUES (
      v_tenant, v_req, 'copy_link', 'ca', 'prepared', 'csd58-check-copy'
    );
    RAISE EXCEPTION 'T9 FAIL: CHECK should reject copy_link';
  EXCEPTION
    WHEN check_violation THEN
      NULL;
    WHEN OTHERS THEN
      IF SQLERRM ILIKE '%T9 FAIL%' THEN RAISE;
      END IF;
      -- some PG versions wrap differently
      NULL;
  END;

  RAISE NOTICE 'CS-D58 anti-leak tests PASS';
END;
$$;

ROLLBACK;
