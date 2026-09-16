-- CF-18: link DMS fixture, idempotency, member can call link RPC.
-- Does not convert HTML to PDF (no Gotenberg in TAP).
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_member uuid := '20000000-0000-0000-0000-000000000005';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-000000000c18';
  v_quote uuid;
  v_dms uuid;
  v_dms2 uuid;
  v_linked uuid;
  v_linked_retry uuid;
  v_version_count int;
  v_internal json;
  v_folder uuid;
  v_parent uuid;
  v_parent_name text;
  v_leaf_name text;
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

  INSERT INTO data.tenant_members (tenant_id, user_id, role)
  VALUES (v_tenant, v_member, 'member')
  ON CONFLICT (tenant_id, user_id) WHERE site_id IS NULL DO NOTHING;

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by
  ) VALUES (
    v_project,
    v_tenant,
    'work_order',
    'CF-18 branded pdf test',
    'Disposable project for SQL tests',
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

  ALTER TABLE data.commercial_document_events DISABLE TRIGGER USER;
  ALTER TABLE data.commercial_document_lines DISABLE TRIGGER USER;
  ALTER TABLE data.commercial_documents DISABLE TRIGGER USER;
  DELETE FROM data.commercial_document_events
  WHERE document_id IN (
    SELECT id FROM data.commercial_documents WHERE project_id = v_project
  );
  DELETE FROM data.commercial_document_lines
  WHERE document_id IN (
    SELECT id FROM data.commercial_documents WHERE project_id = v_project
  );
  UPDATE data.commercial_documents
  SET rendered_document_id = NULL, pdf_job_id = NULL
  WHERE project_id = v_project;
  DELETE FROM data.document_versions
  WHERE document_id IN (
    SELECT id FROM data.documents
    WHERE tenant_id = v_tenant
      AND entity_type = 'commercial_document'
      AND entity_id IN (SELECT id FROM data.commercial_documents WHERE project_id = v_project)
  );
  DELETE FROM data.documents
  WHERE tenant_id = v_tenant
    AND entity_type = 'commercial_document'
    AND entity_id IN (SELECT id FROM data.commercial_documents WHERE project_id = v_project);
  DELETE FROM data.commercial_documents WHERE project_id = v_project;
  ALTER TABLE data.commercial_documents ENABLE TRIGGER USER;
  ALTER TABLE data.commercial_document_lines ENABLE TRIGGER USER;
  ALTER TABLE data.commercial_document_events ENABLE TRIGGER USER;
  DELETE FROM data.project_lines WHERE project_id = v_project;

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Base CF-18', NULL, 'u',
    1, 80, 0, 21, 0, NULL,
    'cf180000-0000-0000-0000-000000000001'::uuid
  );

  v_quote := api.issue_commercial_document(
    v_project, 'quote', true,
    'cf180000-0000-0000-0000-000000000002'::uuid,
    NULL
  );

  INSERT INTO data.documents (
    tenant_id, title, entity_type, entity_id, category, required_permissions, created_by
  ) VALUES (
    v_tenant,
    'CF-18 fixture PDF',
    'commercial_document',
    v_quote,
    'commercial',
    '{}',
    v_owner
  )
  RETURNING id INTO v_dms;

  INSERT INTO data.document_versions (
    document_id, version_number, storage_type, file_path_or_url, mime_type, size_bytes, created_by
  ) VALUES (
    v_dms, 1, 'native', v_tenant::text || '/cf18-fixture.pdf', 'application/pdf', 12, v_owner
  );

  PERFORM set_config('request.jwt.claim.sub', v_member::text, true);
  PERFORM set_config(
    'request.jwt.claim',
    json_build_object(
      'sub', v_member,
      'role', 'authenticated',
      'app_metadata', json_build_object(
        'user_tenants', json_build_object(
          v_tenant::text, json_build_object('global_role', 'member', 'sites', json_build_object())
        ),
        'user_permissions', json_build_object(
          v_tenant::text, json_build_object(
            'global_permissions', json_build_array(),
            'sites', json_build_object()
          )
        )
      )
    )::text,
    true
  );

  v_linked := api.link_commercial_rendered_document(
    v_quote,
    v_dms,
    'cf180000-0000-0000-0000-000000000010'::uuid,
    NULL
  );
  IF v_linked IS DISTINCT FROM v_dms THEN
    RAISE EXCEPTION 'member link should return dms id';
  END IF;

  v_linked_retry := api.link_commercial_rendered_document(
    v_quote,
    v_dms,
    'cf180000-0000-0000-0000-000000000010'::uuid,
    NULL
  );
  IF v_linked_retry IS DISTINCT FROM v_dms THEN
    RAISE EXCEPTION 'idempotent link should return same dms id';
  END IF;

  IF (
    SELECT COUNT(*) FROM data.commercial_document_events
    WHERE document_id = v_quote AND event_type = 'pdf_rendered'
  ) <> 1 THEN
    RAISE EXCEPTION 'pdf_rendered should be idempotent on client_op_id';
  END IF;

  INSERT INTO data.documents (
    tenant_id, title, category, required_permissions, created_by
  ) VALUES (
    v_tenant, 'CF-18 other PDF', 'commercial', '{}', v_owner
  )
  RETURNING id INTO v_dms2;

  BEGIN
    PERFORM api.link_commercial_rendered_document(
      v_quote,
      v_dms2,
      'cf180000-0000-0000-0000-000000000011'::uuid,
      NULL
    );
    RAISE EXCEPTION 'second dms id should be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%commercial_render_already_linked%' THEN
      RAISE;
    END IF;
  END;

  v_internal := api.create_commercial_rendered_document_internal(
    v_tenant,
    v_quote,
    'CF-18 regenerated',
    v_tenant::text || '/cf18-v2.pdf',
    'application/pdf',
    24,
    v_owner
  );
  IF (v_internal -> 'document' ->> 'id') IS DISTINCT FROM v_dms::text THEN
    RAISE EXCEPTION 'regenerate should reuse existing dms document';
  END IF;

  SELECT COUNT(*) INTO v_version_count
  FROM data.document_versions
  WHERE document_id = v_dms;
  IF v_version_count <> 2 THEN
    RAISE EXCEPTION 'regenerate should add version, got %', v_version_count;
  END IF;

  IF (
    SELECT rendered_document_id FROM data.commercial_documents WHERE id = v_quote
  ) IS DISTINCT FROM v_dms THEN
    RAISE EXCEPTION 'rendered_document_id not linked';
  END IF;

  SELECT folder_id INTO v_folder FROM data.documents WHERE id = v_dms;
  IF v_folder IS NULL THEN
    RAISE EXCEPTION 'rendered pdf should be filed in a dms folder';
  END IF;

  SELECT parent_id, name INTO v_parent, v_leaf_name
  FROM data.document_folders WHERE id = v_folder;
  IF v_leaf_name IS DISTINCT FROM 'quotes' THEN
    RAISE EXCEPTION 'quotes should use english leaf folder, got %', v_leaf_name;
  END IF;
  IF v_parent IS NULL THEN
    RAISE EXCEPTION 'quotes folder should sit under a client root';
  END IF;

  SELECT name INTO v_parent_name FROM data.document_folders WHERE id = v_parent;
  IF v_parent_name IS NULL OR v_parent_name NOT LIKE '%[80000000]%' THEN
    RAISE EXCEPTION 'client folder should use fixed contact id suffix, got %', v_parent_name;
  END IF;
  IF (
    SELECT entity_type FROM data.document_folders WHERE id = v_parent
  ) IS DISTINCT FROM 'contact'
     OR (
       SELECT entity_id FROM data.document_folders WHERE id = v_parent
     ) IS DISTINCT FROM v_client THEN
    RAISE EXCEPTION 'client folder should be keyed to contact id';
  END IF;

  UPDATE data.contacts SET display_name = 'Nom canviat CF-18' WHERE id = v_client;
  v_internal := api.create_commercial_rendered_document_internal(
    v_tenant,
    v_quote,
    'CF-18 regenerated again',
    v_tenant::text || '/cf18-v3.pdf',
    'application/pdf',
    24,
    v_owner
  );
  IF (SELECT folder_id FROM data.documents WHERE id = v_dms) IS DISTINCT FROM v_folder THEN
    RAISE EXCEPTION 'rerender should reuse the same quotes folder';
  END IF;
  IF (
    SELECT name FROM data.document_folders WHERE id = v_parent
  ) IS DISTINCT FROM v_parent_name THEN
    RAISE EXCEPTION 'client folder name must stay fixed after display_name change';
  END IF;
  UPDATE data.contacts SET display_name = 'Constructora Meridian S.L.' WHERE id = v_client;

  RAISE NOTICE 'CF-18 branded pdf tests passed';
END;
$$;
