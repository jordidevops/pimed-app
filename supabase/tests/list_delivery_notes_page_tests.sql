-- CF-26: the hub lists every delivery note of an order. Rolls back.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-00000000cf70';
  v_count bigint;
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
    site_id, client_id, created_by, commercial_regime, service_mode
  ) VALUES (
    v_project, v_tenant, 'work_order', 'CF-26 list', 'disposable',
    'active', 'company', v_site, v_client, v_owner, 'consumer', 'execute'
  );
  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Hores llista', NULL, 'h',
    1, 100, 0, 21, 0, NULL,
    'cf265000-0000-0000-0000-000000000001'::uuid
  );
  PERFORM api.accept_commercial_document(
    api.issue_commercial_document(
      v_project, 'quote', true,
      'cf265000-0000-0000-0000-000000000002'::uuid, NULL
    ),
    '{"method":"sql_test"}'::jsonb,
    'cf265000-0000-0000-0000-000000000003'::uuid
  );
  UPDATE data.projects SET authorized_total = authorized_total + 1000 WHERE id = v_project;
  PERFORM api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cf265000-0000-0000-0000-000000000004'::uuid, NULL
  );
  PERFORM api.upsert_project_line(
    v_project, (
      SELECT id FROM data.project_lines WHERE project_id = v_project LIMIT 1
    ), NULL, 'service', 'Hores llista', NULL, 'h',
    2, 100, 0, 21, 0, NULL,
    'cf265000-0000-0000-0000-000000000005'::uuid
  );
  PERFORM api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cf265000-0000-0000-0000-000000000006'::uuid, NULL
  );

  SELECT total_count INTO v_count
  FROM api.list_delivery_notes_page(
    NULL, v_project, 'all', 'all', NULL, NULL, NULL, false, 50, 0
  );
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'page should list both delivery notes, got %', v_count;
  END IF;

  IF (
    SELECT has_open_delivery
    FROM api.get_project_delivery_summary(ARRAY[v_project])
  ) IS NOT TRUE THEN
    RAISE EXCEPTION 'project summary should report an open delivery';
  END IF;

  RAISE NOTICE 'list_delivery_notes_page_tests ok';
END;
$$;

ROLLBACK;
