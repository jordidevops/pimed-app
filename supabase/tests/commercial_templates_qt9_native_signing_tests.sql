-- QT-9: native signing payload on commercial events; delivery conformity;
-- remote completion via signing intent trigger. SQL tests still accept method=sql_test.
-- Uses fresh project ids so reruns do not hit append-only commercial rows.
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project_a uuid := gen_random_uuid();
  v_project_b uuid := gen_random_uuid();
  v_quote uuid;
  v_quote2 uuid;
  v_delivery uuid;
  v_payload jsonb;
  v_status text;
  v_method text;
  v_session uuid := gen_random_uuid();
  v_intent uuid;
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

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by
  ) VALUES
    (v_project_a, v_tenant, 'work_order', 'QT-9 A', 'Disposable', 'active', 'company', v_site, v_client, v_owner),
    (v_project_b, v_tenant, 'work_order', 'QT-9 B', 'Disposable', 'active', 'company', v_site, v_client, v_owner);

  PERFORM api.upsert_project_line(
    v_project_a, NULL, NULL, 'service', 'QT-9 A line', NULL, 'u',
    1, 80, 0, 21, 0, NULL, gen_random_uuid()
  );
  v_quote := api.issue_commercial_document(
    v_project_a, 'quote', true, gen_random_uuid(), NULL
  );

  PERFORM api.accept_commercial_document(
    v_quote,
    '{"method":"sql_test"}'::jsonb,
    gen_random_uuid()
  );
  SELECT signature ->> 'method' INTO v_method
  FROM data.commercial_document_events
  WHERE document_id = v_quote AND event_type = 'accepted';
  IF v_method IS DISTINCT FROM 'sql_test' THEN
    RAISE EXCEPTION 'QT-9 sql_test accept regression failed: %', v_method;
  END IF;

  v_delivery := api.issue_commercial_document(
    v_project_a, 'delivery_note', true, gen_random_uuid(), v_quote
  );
  PERFORM api.sign_commercial_delivery_note(
    v_delivery,
    jsonb_build_object(
      'method', 'native',
      'signing_submission_id', '33333333-3333-3333-3333-333333333333',
      'signing_session_id', '44444444-4444-4444-4444-444444444444'
    ),
    gen_random_uuid()
  );
  SELECT status INTO v_status FROM data.commercial_documents WHERE id = v_delivery;
  IF v_status IS DISTINCT FROM 'signed' THEN
    RAISE EXCEPTION 'QT-9 delivery status expected signed, got %', v_status;
  END IF;
  SELECT payload INTO v_payload
  FROM data.commercial_document_events
  WHERE document_id = v_delivery AND event_type = 'signed';
  IF v_payload ->> 'signing_session_id' IS DISTINCT FROM '44444444-4444-4444-4444-444444444444' THEN
    RAISE EXCEPTION 'QT-9 delivery event missing session id: %', v_payload;
  END IF;

  PERFORM api.upsert_project_line(
    v_project_b, NULL, NULL, 'service', 'QT-9 B line', NULL, 'u',
    1, 40, 0, 21, 0, NULL, gen_random_uuid()
  );
  v_quote2 := api.issue_commercial_document(
    v_project_b, 'quote', true, gen_random_uuid(), NULL
  );

  PERFORM api.reject_commercial_document(
    v_quote2,
    jsonb_build_object(
      'method', 'native',
      'signing_submission_id', '11111111-1111-1111-1111-111111111111',
      'signing_session_id', '22222222-2222-2222-2222-222222222222'
    ),
    gen_random_uuid()
  );
  SELECT payload INTO v_payload
  FROM data.commercial_document_events
  WHERE document_id = v_quote2 AND event_type = 'rejected';
  IF v_payload ->> 'signing_submission_id' IS DISTINCT FROM '11111111-1111-1111-1111-111111111111'
     OR v_payload ->> 'signing_session_id' IS DISTINCT FROM '22222222-2222-2222-2222-222222222222'
     OR v_payload ->> 'rejected_content_hash' IS NULL THEN
    RAISE EXCEPTION 'QT-9 reject payload missing signing refs: %', v_payload;
  END IF;

  v_quote2 := api.reissue_commercial_quote(v_quote2, gen_random_uuid());

  INSERT INTO data.document_signing_sessions (
    id, tenant_id, document_version_id, signing_token, signing_type, status,
    signer_name, signer_role, operator_user_id, expires_at
  ) VALUES (
    v_session, v_tenant, gen_random_uuid(),
    'qt9token' || replace(gen_random_uuid()::text, '-', ''),
    'remote', 'pending', 'Client QT-9', 'client_accept', v_owner, now() + interval '7 days'
  );

  v_intent := api.register_commercial_signing_intent(
    v_quote2, v_session, 'accept', gen_random_uuid(), gen_random_uuid()
  );
  IF v_intent IS NULL THEN
    RAISE EXCEPTION 'QT-9 register intent returned null';
  END IF;

  UPDATE data.document_signing_sessions
  SET status = 'signed'
  WHERE id = v_session;

  SELECT status INTO v_status FROM data.commercial_documents WHERE id = v_quote2;
  IF v_status IS DISTINCT FROM 'accepted' THEN
    RAISE EXCEPTION 'QT-9 trigger did not accept quote, status=%', v_status;
  END IF;
  SELECT payload INTO v_payload
  FROM data.commercial_document_events
  WHERE document_id = v_quote2 AND event_type = 'accepted'
  ORDER BY occurred_at DESC
  LIMIT 1;
  IF v_payload ->> 'signing_session_id' IS DISTINCT FROM v_session::text THEN
    RAISE EXCEPTION 'QT-9 trigger payload missing session: %', v_payload;
  END IF;

  RAISE NOTICE 'commercial templates QT-9 native signing tests passed';
END;
$$;
