-- CF-26: the delivery hub lists every note, not only the latest. Rolls back.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-00000000cf71';
  v_line uuid;
  v_quote uuid;
  v_dn1 uuid;
  v_dn2 uuid;
  v_items jsonb;
  v_count bigint;
  v_row jsonb;
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
    v_project, v_tenant, 'work_order', 'CF-26 hub', 'disposable',
    'active', 'company', v_site, v_client, v_owner, 'consumer', 'execute'
  );

  v_line := api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Servei hub', NULL, 'u',
    1, 100, 0, 21, 0, NULL,
    'cf266100-0000-0000-0000-000000000001'::uuid
  );
  v_quote := api.issue_commercial_document(
    v_project, 'quote', true,
    'cf266100-0000-0000-0000-000000000002'::uuid, NULL
  );
  PERFORM api.accept_commercial_document(
    v_quote, '{"method":"sql_test"}'::jsonb,
    'cf266100-0000-0000-0000-000000000003'::uuid
  );
  PERFORM api.record_payment(
    v_quote, 3000, 'transfer',
    'cf266100-0000-0000-0000-000000000004'::uuid,
    'ADV-26', now()
  );
  v_dn1 := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cf266100-0000-0000-0000-000000000005'::uuid, NULL
  );

  SELECT items, total_count INTO v_items, v_count
  FROM api.list_delivery_notes_page(
    v_client, v_project, 'open', 'all', NULL, NULL, NULL, false, 50, 0
  );
  v_row := v_items -> 0;
  IF v_count <> 1 OR (v_row->>'id') IS DISTINCT FROM v_dn1::text THEN
    RAISE EXCEPTION 'first note missing from the hub: %', v_items;
  END IF;
  IF (v_row->>'collection_status') IS DISTINCT FROM 'partial'
     OR (v_row->>'advance_applied_cents')::bigint <> 3000 THEN
    RAISE EXCEPTION 'advance should apply to the first note: %', v_row;
  END IF;

  UPDATE data.projects SET authorized_total = authorized_total + 1000 WHERE id = v_project;
  PERFORM api.upsert_project_line(
    v_project, v_line, NULL, 'service', 'Servei hub', NULL, 'u',
    2, 100, 0, 21, 0, NULL,
    'cf266100-0000-0000-0000-000000000006'::uuid
  );
  v_dn2 := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cf266100-0000-0000-0000-000000000007'::uuid, NULL
  );
  -- now() no canvia dins d'una transacció; sense això el desempat és per id.
  UPDATE data.commercial_documents
  SET issued_at = clock_timestamp() - interval '2 minutes'
  WHERE id = v_dn1;
  UPDATE data.commercial_documents
  SET issued_at = clock_timestamp() - interval '1 minute'
  WHERE id = v_dn2;

  SELECT items, total_count INTO v_items, v_count
  FROM api.list_delivery_notes_page(
    NULL, v_project, 'all', 'all', NULL, NULL, NULL, false, 50, 0
  );
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'hub should list both notes, got %', v_count;
  END IF;

  PERFORM api.record_payment(
    v_dn1, 1000, 'cash',
    'cf266100-0000-0000-0000-000000000008'::uuid, 'DN1', now()
  );
  SELECT items INTO v_items
  FROM api.list_delivery_notes_page(
    NULL, v_project, 'all', 'all', NULL, NULL, NULL, false, 50, 0
  );
  SELECT value INTO v_row FROM jsonb_array_elements(v_items) value WHERE value->>'id' = v_dn1::text;
  IF (v_row->>'direct_paid_cents')::bigint <> 1000 THEN
    RAISE EXCEPTION 'payment stays on the first note: %', v_row;
  END IF;
  SELECT value INTO v_row FROM jsonb_array_elements(v_items) value WHERE value->>'id' = v_dn2::text;
  IF (v_row->>'direct_paid_cents')::bigint <> 0
     OR (v_row->>'advance_applied_cents')::bigint <> 0 THEN
    RAISE EXCEPTION 'second note should not absorb the first payment or advance: dn1=% dn2=%',
      (SELECT value FROM jsonb_array_elements(v_items) value WHERE value->>'id' = v_dn1::text),
      v_row;
  END IF;

  PERFORM api.record_payment(
    v_dn1, data.commercial_payment_remaining_cents(v_dn1), 'card',
    'cf266100-0000-0000-0000-000000000009'::uuid, 'FULL1', now()
  );
  PERFORM api.record_payment(
    v_dn2, data.commercial_payment_remaining_cents(v_dn2), 'card',
    'cf266100-0000-0000-0000-00000000000a'::uuid, 'FULL2', now()
  );
  SELECT total_count INTO v_count
  FROM api.list_delivery_notes_page(
    NULL, v_project, 'open', 'all', NULL, NULL, NULL, false, 50, 0
  );
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'open filter should hide paid notes, got %', v_count;
  END IF;
  SELECT total_count INTO v_count
  FROM api.list_delivery_notes_page(
    NULL, v_project, 'paid', 'all', NULL, NULL, NULL, false, 50, 0
  );
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'paid filter should show both notes, got %', v_count;
  END IF;

  RAISE NOTICE 'list_delivery_notes_page hub tests ok';
END;
$$;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_project uuid := '51000000-0000-0000-0000-00000000cf71';
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
  SET LOCAL ROLE authenticated;

  SELECT total_count INTO v_count
  FROM api.list_delivery_notes_page(
    NULL, v_project, 'all', 'all', NULL, NULL, NULL, false, 50, 0
  );
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'authenticated caller should see both notes, got %', v_count;
  END IF;
END;
$$;

ROLLBACK;
