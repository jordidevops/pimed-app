-- CF-28 F2: commercial_decision_requests domain (flag on).
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := gen_random_uuid();
  v_quote uuid;
  v_delivery uuid;
  v_render uuid;
  v_req uuid;
  v_req2 uuid;
  v_op uuid := gen_random_uuid();
  v_delivery_json jsonb;
  v_raw text;
  v_hash_count int;
  v_status text;
  v_result jsonb;
  v_result_b jsonb;
  v_op_a uuid := gen_random_uuid();
  v_op_b uuid := gen_random_uuid();
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
        || jsonb_build_object('decision_requests_enabled', false)
    )
  WHERE id = v_tenant;

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by
  ) VALUES (
    v_project, v_tenant, 'work_order', 'CF28-F2', 'Disposable', 'active', 'company',
    v_site, v_client, v_owner
  );

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'CF28 line', NULL, 'u',
    1, 100, 0, 21, 0, NULL, gen_random_uuid()
  );
  v_quote := api.issue_commercial_document(
    v_project, 'quote', true, gen_random_uuid(), NULL
  );

  BEGIN
    PERFORM api.create_commercial_decision_request(
      'commercial_document', v_quote, now() + interval '7 days', gen_random_uuid()
    );
    RAISE EXCEPTION 'expected decision_requests_disabled';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM NOT LIKE 'decision_requests_disabled%' THEN
      RAISE;
    END IF;
  END;

  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb)
    || jsonb_build_object(
      'commercial',
      COALESCE(settings->'commercial', '{}'::jsonb)
        || jsonb_build_object('decision_requests_enabled', true)
    )
  WHERE id = v_tenant;

  INSERT INTO data.documents (tenant_id, title, category, required_permissions, created_by)
  VALUES (v_tenant, 'CF28 quote render', 'commercial', '{}', v_owner)
  RETURNING id INTO v_render;

  INSERT INTO data.document_versions (
    document_id, version_number, storage_type, file_path_or_url, mime_type, created_by
  ) VALUES (
    v_render, 1, 'native', 'cf28/test.pdf', 'application/pdf', v_owner
  );

  UPDATE data.commercial_documents
  SET rendered_document_id = v_render,
      content_hash = COALESCE(NULLIF(btrim(content_hash), ''), 'cf28-hash-' || id::text)
  WHERE id = v_quote;

  v_req := api.create_commercial_decision_request(
    'commercial_document', v_quote, now() + interval '7 days', v_op
  );
  v_req2 := api.create_commercial_decision_request(
    'commercial_document', v_quote, now() + interval '7 days', v_op
  );
  IF v_req IS DISTINCT FROM v_req2 THEN
    RAISE EXCEPTION 'idempotent create failed: % vs %', v_req, v_req2;
  END IF;

  PERFORM api.create_commercial_decision_request(
    'commercial_document', v_quote, now() + interval '7 days', gen_random_uuid()
  );

  SELECT status INTO v_status
  FROM data.commercial_decision_requests
  WHERE id = v_req;
  IF v_status IS DISTINCT FROM 'superseded' THEN
    RAISE EXCEPTION 'expected superseded previous open, got %', v_status;
  END IF;

  SELECT id INTO v_req
  FROM data.commercial_decision_requests
  WHERE commercial_document_id = v_quote AND status = 'open'
  ORDER BY created_at DESC
  LIMIT 1;

  v_delivery_json := api.create_commercial_decision_delivery(
    v_req, 'email', NULL, 'ca', gen_random_uuid()
  );
  IF v_delivery_json->>'raw_token' IS NOT NULL THEN
    RAISE EXCEPTION 'CS-D58: authenticated must not receive raw_token';
  END IF;

  SELECT o.raw_token INTO v_raw
  FROM data.commercial_decision_token_once o
  WHERE o.delivery_id = (v_delivery_json->>'delivery_id')::uuid;
  IF v_raw IS NULL OR length(v_raw) < 32 THEN
    RAISE EXCEPTION 'server-side token_once missing for email delivery';
  END IF;

  SELECT count(*) INTO v_hash_count
  FROM data.commercial_decision_access_tokens t
  WHERE t.request_id = v_req
    AND t.token_hash = v_raw;
  IF v_hash_count > 0 THEN
    RAISE EXCEPTION 'raw token must not be stored; only sha256 hash';
  END IF;

  v_result := data.apply_commercial_decision_request(
    v_req, 'accepted', 'office',
    jsonb_build_object('method', 'office'),
    v_op_a, v_owner
  );
  v_result_b := data.apply_commercial_decision_request(
    v_req, 'declined', 'office',
    jsonb_build_object('method', 'office', 'reason', 'too late'),
    v_op_b, v_owner
  );
  IF (v_result->>'applied')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'first apply should win: %', v_result;
  END IF;
  IF (v_result_b->>'already_decided')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'second apply should be already_decided: %', v_result_b;
  END IF;
  IF (v_result_b->>'status') IS DISTINCT FROM 'accepted' THEN
    RAISE EXCEPTION 'status must remain accepted, got %', v_result_b->>'status';
  END IF;

  SELECT status INTO v_status FROM data.commercial_documents WHERE id = v_quote;
  IF v_status IS DISTINCT FROM 'accepted' THEN
    RAISE EXCEPTION 'quote should be accepted, got %', v_status;
  END IF;

  v_delivery := api.issue_commercial_document(
    v_project, 'delivery_note', true, gen_random_uuid(), v_quote
  );
  PERFORM api.reject_commercial_document(
    v_delivery,
    jsonb_build_object('method', 'office', 'role', 'office_reject', 'reason', 'damaged'),
    gen_random_uuid()
  );
  SELECT status INTO v_status FROM data.commercial_documents WHERE id = v_delivery;
  IF v_status IS DISTINCT FROM 'rejected' THEN
    RAISE EXCEPTION 'DN should be rejected/disputed, got %', v_status;
  END IF;

  BEGIN
    PERFORM api.create_invoice_draft_from_delivery_notes(
      ARRAY[v_delivery],
      gen_random_uuid()
    );
    RAISE EXCEPTION 'expected invoice_delivery_invalid for disputed DN';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM NOT LIKE 'invoice_delivery_invalid%' THEN
      RAISE;
    END IF;
  END;

  RAISE NOTICE 'CF-28 F2 commercial_decision_requests_tests OK';
END;
$$;

ROLLBACK;
