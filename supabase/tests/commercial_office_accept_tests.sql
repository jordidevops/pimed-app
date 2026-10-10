-- Office accept without client signature (allow_office_accept).
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
  v_status text;
  v_req_status text;
  v_role text;
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
        || jsonb_build_object(
          'allow_office_accept', false,
          'decision_requests_enabled', true
        )
    )
  WHERE id = v_tenant;

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by
  ) VALUES (
    v_project, v_tenant, 'work_order', 'OfficeAccept', 'Disposable', 'active', 'company',
    v_site, v_client, v_owner
  );

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'OA line', NULL, 'u',
    1, 100, 0, 21, 0, NULL, gen_random_uuid()
  );
  v_quote := api.issue_commercial_document(
    v_project, 'quote', true, gen_random_uuid(), NULL
  );

  BEGIN
    PERFORM api.accept_commercial_document_office(
      v_quote, 'client said yes by phone', gen_random_uuid()
    );
    RAISE EXCEPTION 'expected office_accept_disabled';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%office_accept_disabled%' THEN
        RAISE;
      END IF;
  END;

  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb)
    || jsonb_build_object(
      'commercial',
      COALESCE(settings->'commercial', '{}'::jsonb)
        || jsonb_build_object('allow_office_accept', true)
    )
  WHERE id = v_tenant;

  BEGIN
    PERFORM api.accept_commercial_document_office(v_quote, '   ', gen_random_uuid());
    RAISE EXCEPTION 'expected office_accept_reason_required';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%office_accept_reason_required%' THEN
        RAISE;
      END IF;
  END;

  INSERT INTO data.documents (tenant_id, title, category, required_permissions, created_by)
  VALUES (v_tenant, 'OA quote render', 'commercial', '{}', v_owner)
  RETURNING id INTO v_render;

  INSERT INTO data.document_versions (
    document_id, version_number, storage_type, file_path_or_url, mime_type, created_by
  ) VALUES (
    v_render, 1, 'native', 'oa/test.pdf', 'application/pdf', v_owner
  );

  UPDATE data.commercial_documents
  SET rendered_document_id = v_render,
      content_hash = COALESCE(NULLIF(btrim(content_hash), ''), 'oa-hash-' || id::text)
  WHERE id = v_quote;

  v_req := api.create_commercial_decision_request(
    'commercial_document', v_quote, now() + interval '7 days', gen_random_uuid()
  );

  PERFORM api.accept_commercial_document_office(
    v_quote, 'client confirmed by phone', gen_random_uuid()
  );

  SELECT status INTO v_status FROM data.commercial_documents WHERE id = v_quote;
  IF v_status IS DISTINCT FROM 'accepted' THEN
    RAISE EXCEPTION 'expected accepted, got %', v_status;
  END IF;

  SELECT status INTO v_req_status
  FROM data.commercial_decision_requests WHERE id = v_req;
  IF v_req_status IS DISTINCT FROM 'revoked' THEN
    RAISE EXCEPTION 'expected request revoked, got %', v_req_status;
  END IF;

  SELECT signature->>'role' INTO v_role
  FROM data.commercial_document_events
  WHERE document_id = v_quote AND event_type = 'accepted'
  ORDER BY occurred_at DESC
  LIMIT 1;
  IF v_role IS DISTINCT FROM 'office_accept' THEN
    RAISE EXCEPTION 'expected office_accept role, got %', v_role;
  END IF;

  RAISE NOTICE 'commercial_office_accept_tests OK';
END;
$$;

ROLLBACK;
