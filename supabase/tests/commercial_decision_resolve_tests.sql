-- CF-28 F4: resolve + apply-by-token for commercial decision access tokens.
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
  v_raw text;
  v_resolve jsonb;
  v_apply jsonb;
  v_status text;
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

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by
  ) VALUES (
    v_project, v_tenant, 'work_order', 'CF28-F4', 'Disposable', 'active', 'company',
    v_site, v_client, v_owner
  );

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'CF28 F4 line', NULL, 'u',
    1, 100, 0, 21, 0, NULL, gen_random_uuid()
  );
  v_quote := api.issue_commercial_document(
    v_project, 'quote', true, gen_random_uuid(), NULL
  );

  INSERT INTO data.documents (tenant_id, title, category, required_permissions, created_by)
  VALUES (v_tenant, 'CF28 F4 render', 'commercial', '{}', v_owner)
  RETURNING id INTO v_render;

  INSERT INTO data.document_versions (
    document_id, version_number, storage_type, file_path_or_url, mime_type, created_by
  ) VALUES (
    v_render, 1, 'native', 'cf28/f4-test.pdf', 'application/pdf', v_owner
  );

  UPDATE data.commercial_documents
  SET rendered_document_id = v_render,
      content_hash = COALESCE(NULLIF(btrim(content_hash), ''), 'cf28-f4-hash-' || id::text),
      formalization_mode = 'signed_quote'
  WHERE id = v_quote;

  v_req := api.create_commercial_decision_request(
    'commercial_document', v_quote, now() + interval '7 days', gen_random_uuid()
  );
  v_delivery_json := api.create_commercial_decision_delivery(
    v_req, 'email', NULL, 'ca', gen_random_uuid()
  );
  IF v_delivery_json->>'raw_token' IS NOT NULL THEN
    RAISE EXCEPTION 'CS-D58: authenticated must not receive raw_token';
  END IF;
  SELECT o.raw_token INTO v_raw
  FROM data.commercial_decision_token_once o
  WHERE o.delivery_id = (v_delivery_json->>'delivery_id')::uuid;
  IF v_raw IS NULL THEN
    RAISE EXCEPTION 'server-side token_once required for resolve test';
  END IF;

  -- Anonymous resolve
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claim', json_build_object('role', 'anon')::text, true);

  v_resolve := api.resolve_commercial_decision_token(v_raw, true);
  IF v_resolve->>'kind' IS DISTINCT FROM 'commercial_decision' THEN
    RAISE EXCEPTION 'expected commercial_decision, got %', v_resolve;
  END IF;
  IF (v_resolve->>'can_decide')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'expected can_decide true: %', v_resolve;
  END IF;
  IF v_resolve->'snapshot' ? 'client_id' THEN
    RAISE EXCEPTION 'public snapshot must not expose client_id';
  END IF;

  v_resolve := api.resolve_commercial_decision_token('not-a-real-token-value-xxxxxxxxxxxx', false);
  IF v_resolve->>'kind' IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'expected not_found for unknown token';
  END IF;

  v_apply := api.apply_commercial_decision_by_token(
    v_raw,
    'declined',
    jsonb_build_object('reason', 'not interested'),
    gen_random_uuid()
  );
  IF v_apply->>'status' IS DISTINCT FROM 'declined'
     AND (v_apply->>'applied')::boolean IS NOT TRUE
  THEN
    -- first-wins: status should be declined when applied
    NULL;
  END IF;
  IF COALESCE(v_apply->>'status', '') NOT IN ('declined') THEN
    RAISE EXCEPTION 'expected declined via token, got %', v_apply;
  END IF;

  SELECT status INTO v_status FROM data.commercial_documents WHERE id = v_quote;
  IF v_status IS DISTINCT FROM 'rejected' THEN
    RAISE EXCEPTION 'quote should be rejected after decline, got %', v_status;
  END IF;

  v_resolve := api.resolve_commercial_decision_token(v_raw, false);
  IF (v_resolve->>'can_decide')::boolean IS TRUE THEN
    RAISE EXCEPTION 'must not allow decide after consume: %', v_resolve;
  END IF;
  IF v_resolve->>'request_status' IS DISTINCT FROM 'declined' THEN
    RAISE EXCEPTION 'resolve should show declined, got %', v_resolve->>'request_status';
  END IF;
  IF v_resolve->'receipt' IS NULL OR v_resolve->'receipt'->>'outcome' IS DISTINCT FROM 'declined' THEN
    RAISE EXCEPTION 'resolve should include receipt: %', v_resolve->'receipt';
  END IF;

  v_resolve := api.get_commercial_decision_receipt(v_raw);
  IF v_resolve->>'kind' IS DISTINCT FROM 'commercial_decision_receipt' THEN
    RAISE EXCEPTION 'expected receipt, got %', v_resolve;
  END IF;
  IF v_resolve ? 'ip_address' OR (v_resolve->'evidence' ? 'ip_address') THEN
    RAISE EXCEPTION 'receipt must not expose ip_address';
  END IF;
  IF v_resolve->>'trace_id' IS NULL THEN
    RAISE EXCEPTION 'receipt missing trace_id';
  END IF;

  RAISE NOTICE 'CF-28 F4 commercial_decision_resolve_tests OK';
END;
$$;

ROLLBACK;
