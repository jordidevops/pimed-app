-- Client filter: search_commercial_documents(p_client_id) and list_projects_paginated(p_client_id).
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_other_client uuid := '80000000-0000-0000-0000-000000000102';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-000000000cf6';
  v_quote uuid;
  v_count int;
  v_items jsonb;
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
    'Client filter search test',
    'Disposable project for client_id filter',
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
    v_project, NULL, NULL, 'service', 'Linia filtre client', NULL, 'u',
    1, 50, 0, 21, 0, NULL,
    'cf160000-0000-0000-0000-000000000001'::uuid
  );

  v_quote := api.issue_commercial_document(
    v_project, 'quote', true,
    'cf160000-0000-0000-0000-000000000002'::uuid,
    NULL
  );

  SELECT count(*) INTO v_count
  FROM api.search_commercial_documents(
    NULL, ARRAY['quote']::text[], NULL, NULL, NULL, false, NULL, NULL, 50, v_client
  )
  WHERE id = v_quote;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'T1 search with matching p_client_id failed: count=%', v_count;
  END IF;

  SELECT count(*) INTO v_count
  FROM api.search_commercial_documents(
    NULL, ARRAY['quote']::text[], NULL, NULL, NULL, false, NULL, NULL, 50, v_other_client
  )
  WHERE id = v_quote;

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'T2 search with other p_client_id should be 0: count=%', v_count;
  END IF;

  SELECT items INTO v_items
  FROM api.list_projects_paginated(
    v_tenant, 1, 20, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    'created_at', 'desc', NULL, false, v_client
  );

  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_items) e WHERE e->>'id' = v_project::text
  ) THEN
    RAISE EXCEPTION 'T3 list_projects_paginated with matching p_client_id missing project';
  END IF;

  SELECT items INTO v_items
  FROM api.list_projects_paginated(
    v_tenant, 1, 20, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    'created_at', 'desc', NULL, false, v_other_client
  );

  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_items) e WHERE e->>'id' = v_project::text
  ) THEN
    RAISE EXCEPTION 'T4 list_projects_paginated with other p_client_id should exclude project';
  END IF;

  RAISE NOTICE 'client_id filter tests passed';
END;
$$;
