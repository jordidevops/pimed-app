-- CF-26 hub fixes: rectify patches, summary without DN, FIFO clock, scoped list.
-- Rolls back.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-00000000cf60';
  v_project2 uuid := '51000000-0000-0000-0000-00000000cf61';
  v_line uuid;
  v_line2 uuid;
  v_quote uuid;
  v_dn uuid;
  v_dn1 uuid;
  v_dn2 uuid;
  v_new uuid;
  v_preview jsonb;
  v_summary record;
  v_issued1 timestamptz;
  v_issued2 timestamptz;
  v_remaining integer;
  v_qty numeric;
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

  -- Summary with advance and no delivery note yet.
  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by, commercial_regime, service_mode, authorized_total
  ) VALUES (
    v_project, v_tenant, 'work_order', 'CF-26 hub fixes', 'disposable',
    'active', 'company', v_site, v_client, v_owner, 'consumer', 'execute', 242
  );

  v_line := api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Hores hub', NULL, 'h',
    2, 100, 0, 21, 0, NULL,
    'cf266000-0000-0000-0000-000000000001'::uuid
  );
  v_quote := api.issue_commercial_document(
    v_project, 'quote', true,
    'cf266000-0000-0000-0000-000000000002'::uuid, NULL
  );
  PERFORM api.accept_commercial_document(
    v_quote, '{"method":"sql_test"}'::jsonb,
    'cf266000-0000-0000-0000-000000000003'::uuid
  );
  PERFORM api.record_payment(
    v_quote, 5000, 'transfer',
    'cf266000-0000-0000-0000-000000000004'::uuid, 'ADV', now()
  );

  SELECT * INTO v_summary
  FROM api.get_project_delivery_summary(ARRAY[v_project])
  WHERE project_id = v_project;
  IF v_summary.advance_pool_cents <> 5000 OR v_summary.unapplied_advance_cents <> 5000 THEN
    RAISE EXCEPTION 'summary without DN should show advance pool, got % / %',
      v_summary.advance_pool_cents, v_summary.unapplied_advance_cents;
  END IF;
  IF v_summary.billed_cents <> 0 OR v_summary.remaining_cents <> 0 THEN
    RAISE EXCEPTION 'summary without DN should have zero billed/remaining';
  END IF;

  -- FIFO clock: two DNs in the same transaction get distinct issued_at; advance hits the first.
  UPDATE data.project_lines SET quantity = 1 WHERE id = v_line;
  v_dn1 := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cf266000-0000-0000-0000-000000000005'::uuid, NULL
  );
  UPDATE data.project_lines SET quantity = 2 WHERE id = v_line;
  v_dn2 := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cf266000-0000-0000-0000-000000000006'::uuid, NULL
  );

  SELECT issued_at INTO v_issued1 FROM data.commercial_documents WHERE id = v_dn1;
  SELECT issued_at INTO v_issued2 FROM data.commercial_documents WHERE id = v_dn2;
  IF v_issued1 IS NULL OR v_issued2 IS NULL OR v_issued1 >= v_issued2 THEN
    RAISE EXCEPTION 'delivery issued_at must advance within the same TX (% / %)', v_issued1, v_issued2;
  END IF;

  SELECT remaining_cents INTO v_remaining
  FROM data.delivery_balances(v_tenant, ARRAY[v_project])
  WHERE delivery_note_id = v_dn1;
  IF v_remaining <> 7100 THEN
    RAISE EXCEPTION 'oldest DN should receive the 5000 advance first, remaining %', v_remaining;
  END IF;
  SELECT remaining_cents INTO v_remaining
  FROM data.delivery_balances(v_tenant, ARRAY[v_project])
  WHERE delivery_note_id = v_dn2;
  IF v_remaining <> data.commercial_document_total_cents(
       (SELECT total FROM data.commercial_documents WHERE id = v_dn2)
     ) THEN
    RAISE EXCEPTION 'newer DN should get no advance leftover, remaining %', v_remaining;
  END IF;

  -- Rectify with patch A-2 → A-1 (OS quantity down to 1 on the second DN's line space).
  -- Cancel dn2 and lower OS so replacement only covers 1 unit total with dn1 still active.
  -- Simpler A-2→A-3 path: single DN of qty 2, patch OS to 1.
  UPDATE data.commercial_documents SET status = 'cancelled' WHERE id = v_dn1;
  UPDATE data.commercial_documents SET status = 'cancelled' WHERE id = v_dn2;
  UPDATE data.project_lines SET quantity = 2 WHERE id = v_line;
  v_dn := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cf266000-0000-0000-0000-000000000007'::uuid, NULL
  );

  v_preview := api.preview_rectify_delivery_note(
    v_dn,
    jsonb_build_array(jsonb_build_object('project_line_id', v_line, 'quantity', 1))
  );
  IF (v_preview->'lines'->0->>'quantity')::numeric <> 1 THEN
    RAISE EXCEPTION 'preview should show replacement qty 1, got %', v_preview;
  END IF;

  v_new := api.rectify_delivery_note(
    v_dn,
    'Corregir quantitat',
    'cf266000-0000-0000-0000-000000000008'::uuid,
    jsonb_build_array(jsonb_build_object('project_line_id', v_line, 'quantity', 1))
  );

  SELECT quantity INTO v_qty FROM data.project_lines WHERE id = v_line;
  IF v_qty <> 1 THEN
    RAISE EXCEPTION 'rectify patch should set OS quantity to 1, got %', v_qty;
  END IF;
  SELECT quantity INTO v_qty
  FROM data.commercial_document_lines
  WHERE document_id = v_new AND source_project_line_id = v_line;
  IF v_qty <> 1 THEN
    RAISE EXCEPTION 'replacement DN should have qty 1, got %', v_qty;
  END IF;

  -- Scoped list balances: second project should not pollute when filtering the first.
  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by, commercial_regime, service_mode, authorized_total
  ) VALUES (
    v_project2, v_tenant, 'work_order', 'CF-26 other', 'disposable',
    'active', 'company', v_site, v_client, v_owner, 'consumer', 'execute', 121
  );
  v_line2 := api.upsert_project_line(
    v_project2, NULL, NULL, 'service', 'Altra', NULL, 'h',
    1, 100, 0, 21, 0, NULL,
    'cf266000-0000-0000-0000-000000000009'::uuid
  );
  PERFORM api.issue_commercial_document(
    v_project2, 'quote', true,
    'cf266000-0000-0000-0000-00000000000a'::uuid, NULL
  );
  PERFORM api.accept_commercial_document(
    (SELECT id FROM data.commercial_documents
     WHERE project_id = v_project2 AND doc_type = 'quote' LIMIT 1),
    '{"method":"sql_test"}'::jsonb,
    'cf266000-0000-0000-0000-00000000000b'::uuid
  );
  PERFORM api.issue_commercial_document(
    v_project2, 'delivery_note', true,
    'cf266000-0000-0000-0000-00000000000c'::uuid, NULL
  );

  SELECT items INTO v_items
  FROM api.list_delivery_notes_page(
    NULL, v_project, 'all', 'all', NULL, NULL, NULL, false, 50, 0
  );
  IF jsonb_array_length(v_items) < 1 THEN
    RAISE EXCEPTION 'scoped list should return the project delivery note';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(v_items) elem
    WHERE (elem->>'project_id')::uuid IS DISTINCT FROM v_project
  ) THEN
    RAISE EXCEPTION 'scoped list leaked another project';
  END IF;

  RAISE NOTICE 'cf26_hub_fixes_tests ok';
END;
$$;

ROLLBACK;
