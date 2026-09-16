-- CF-15: search commercial documents by number and line text.
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-000000000cf5';
  v_quote uuid;
  v_found uuid;
  v_count int;
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
  ) VALUES (
    v_project,
    v_tenant,
    'work_order',
    'CF-15 search test',
    'Disposable project for quotes search',
    'active',
    'company',
    v_site,
    v_client,
    v_owner
  )
  ON CONFLICT (id) DO UPDATE SET
    status = 'active',
    client_id = EXCLUDED.client_id,
    updated_at = now();

  DELETE FROM data.commercial_document_events
  WHERE document_id IN (
    SELECT id FROM data.commercial_documents WHERE project_id = v_project
  );
  DELETE FROM data.commercial_document_lines
  WHERE document_id IN (
    SELECT id FROM data.commercial_documents WHERE project_id = v_project
  );
  DELETE FROM data.commercial_documents WHERE project_id = v_project;
  DELETE FROM data.project_lines WHERE project_id = v_project;

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Cablejat especial CF15', NULL, 'u',
    1, 80, 0, 21, 0, NULL,
    'cf150000-0000-0000-0000-000000000001'::uuid
  );

  v_quote := api.issue_commercial_document(
    v_project, 'quote', true,
    'cf150000-0000-0000-0000-000000000002'::uuid,
    NULL
  );

  SELECT id INTO v_found
  FROM api.search_commercial_documents(
    (SELECT doc_number FROM data.commercial_documents WHERE id = v_quote),
    ARRAY['quote']::text[],
    NULL, NULL, NULL, false, NULL, NULL, 50
  )
  LIMIT 1;

  IF v_found IS DISTINCT FROM v_quote THEN
    RAISE EXCEPTION 'T1 search by doc_number failed: found=%', v_found;
  END IF;

  SELECT count(*) INTO v_count
  FROM api.search_commercial_documents(
    'Cablejat especial CF15',
    ARRAY['quote']::text[],
    NULL, NULL, NULL, false, NULL, NULL, 50
  )
  WHERE id = v_quote;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'T2 search by line text failed: count=%', v_count;
  END IF;

  SELECT count(*) INTO v_count
  FROM api.search_commercial_documents(
    'zzzz-no-match-cf15',
    NULL, NULL, NULL, NULL, false, NULL, NULL, 50
  );

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'T3 empty search should return 0: count=%', v_count;
  END IF;

  RAISE NOTICE 'CF-15 search quotes tests passed';
END;
$$;
