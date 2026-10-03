-- CF-26: delivery notes are progressive. Rolls back.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-00000000cf30';
  v_line uuid;
  v_quote uuid;
  v_dn1 uuid;
  v_dn2 uuid;
  v_preview jsonb;
  v_qty numeric;
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
    v_project, v_tenant, 'work_order', 'CF-26 progressive', 'disposable',
    'active', 'company', v_site, v_client, v_owner
  );
  UPDATE data.projects
  SET commercial_regime = 'consumer', service_mode = 'execute'
  WHERE id = v_project;

  v_line := api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Hores', NULL, 'h',
    4, 25, 0, 21, 0, NULL,
    'cf261000-0000-0000-0000-000000000001'::uuid
  );

  v_quote := api.issue_commercial_document(
    v_project, 'quote', true,
    'cf261000-0000-0000-0000-000000000002'::uuid,
    NULL
  );
  PERFORM api.accept_commercial_document(
    v_quote,
    '{"method":"sql_test"}'::jsonb,
    'cf261000-0000-0000-0000-000000000003'::uuid
  );

  v_dn1 := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cf261000-0000-0000-0000-000000000004'::uuid,
    NULL
  );

  SELECT quantity INTO v_qty
  FROM data.commercial_document_lines
  WHERE document_id = v_dn1 AND source_project_line_id = v_line;
  IF v_qty <> 4 THEN
    RAISE EXCEPTION 'first delivery expected qty 4, got %', v_qty;
  END IF;

  UPDATE data.project_lines SET quantity = 6 WHERE id = v_line;

  v_preview := api.preview_delivery_note(v_project);
  IF (v_preview->'lines'->0->>'quantity')::numeric <> 2 THEN
    RAISE EXCEPTION 'preview expected pending qty 2, got %', v_preview;
  END IF;

  BEGIN
    PERFORM api.issue_commercial_document(
      v_project, 'delivery_note', true,
      'cf261000-0000-0000-0000-000000000005'::uuid,
      NULL
    );
    RAISE EXCEPTION 'second delivery should exceed authorized total';
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      IF v_err IS DISTINCT FROM 'delivery_note_exceeds_authorized_total' THEN
        RAISE;
      END IF;
  END;

  UPDATE data.projects
  SET authorized_total = authorized_total + 1000
  WHERE id = v_project;

  v_dn2 := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cf261000-0000-0000-0000-000000000006'::uuid,
    NULL
  );
  SELECT quantity INTO v_qty
  FROM data.commercial_document_lines
  WHERE document_id = v_dn2 AND source_project_line_id = v_line;
  IF v_qty <> 2 THEN
    RAISE EXCEPTION 'second delivery expected qty 2, got %', v_qty;
  END IF;

  BEGIN
    PERFORM api.issue_commercial_document(
      v_project, 'delivery_note', true,
      'cf261000-0000-0000-0000-000000000007'::uuid,
      NULL
    );
    RAISE EXCEPTION 'third delivery should be empty';
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      IF v_err IS DISTINCT FROM 'nothing_to_deliver' THEN
        RAISE;
      END IF;
  END;

  BEGIN
    DELETE FROM data.project_lines WHERE id = v_line;
    RAISE EXCEPTION 'delivered line should not be deletable';
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      IF v_err IS DISTINCT FROM 'project_line_already_delivered' THEN
        RAISE;
      END IF;
  END;

  BEGIN
    UPDATE data.project_lines SET quantity = 5 WHERE id = v_line;
    RAISE EXCEPTION 'quantity below delivered should be rejected';
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      IF v_err IS DISTINCT FROM 'project_line_already_delivered' THEN
        RAISE;
      END IF;
  END;

  RAISE NOTICE 'delivery_note_progressive_issue_tests ok';
END;
$$;

ROLLBACK;
