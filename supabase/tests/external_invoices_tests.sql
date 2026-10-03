-- CF-26: external invoices group delivery notes and split collection FIFO. Rolls back.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_other_client uuid := '80000000-0000-0000-0000-00000000cf61';
  v_project uuid := '51000000-0000-0000-0000-00000000cf60';
  v_other_project uuid := '51000000-0000-0000-0000-00000000cf61';
  v_quote uuid;
  v_dn1 uuid;
  v_dn2 uuid;
  v_other uuid;
  v_result jsonb;
  v_invoice uuid;
  v_pay uuid;
  v_first integer;
  v_second integer;
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
    site_id, client_id, created_by, commercial_regime, service_mode
  ) VALUES (
    v_project, v_tenant, 'work_order', 'CF-26 invoice', 'disposable',
    'active', 'company', v_site, v_client, v_owner, 'consumer', 'execute'
  );

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Hores factura', NULL, 'h',
    1, 100, 0, 21, 0, NULL,
    'cf264000-0000-0000-0000-000000000001'::uuid
  );
  v_quote := api.issue_commercial_document(
    v_project, 'quote', true,
    'cf264000-0000-0000-0000-000000000002'::uuid, NULL
  );
  PERFORM api.accept_commercial_document(
    v_quote, '{"method":"sql_test"}'::jsonb,
    'cf264000-0000-0000-0000-000000000003'::uuid
  );
  UPDATE data.projects SET authorized_total = authorized_total + 1000 WHERE id = v_project;
  v_dn1 := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cf264000-0000-0000-0000-000000000004'::uuid, NULL
  );
  PERFORM api.upsert_project_line(
    v_project, (
      SELECT id FROM data.project_lines WHERE project_id = v_project LIMIT 1
    ), NULL, 'service', 'Hores factura', NULL, 'h',
    2, 100, 0, 21, 0, NULL,
    'cf264000-0000-0000-0000-000000000005'::uuid
  );
  v_dn2 := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cf264000-0000-0000-0000-000000000006'::uuid, NULL
  );

  v_result := api.register_external_invoice(
    'F-CF26-1', CURRENT_DATE, 20000,
    ARRAY[v_dn1, v_dn2],
    'cf264000-0000-0000-0000-000000000007'::uuid,
    NULL
  );
  v_invoice := (v_result->>'id')::uuid;
  IF (v_result->>'difference_cents')::integer = 0 THEN
    RAISE EXCEPTION 'mismatch should be reported, got %', v_result;
  END IF;
  IF (SELECT external_invoice_ref FROM data.commercial_documents WHERE id = v_dn1) IS DISTINCT FROM 'F-CF26-1' THEN
    RAISE EXCEPTION 'delivery note should carry the invoice number';
  END IF;

  IF (api.register_external_invoice(
    'F-CF26-1', CURRENT_DATE, 20000, ARRAY[v_dn1, v_dn2],
    'cf264000-0000-0000-0000-000000000007'::uuid, NULL
  )->>'id')::uuid IS DISTINCT FROM v_invoice THEN
    RAISE EXCEPTION 'invoice register retry changed the id';
  END IF;

  BEGIN
    PERFORM api.record_payment(
      v_dn1, 100, 'cash',
      'cf264000-0000-0000-0000-000000000008'::uuid, NULL, now()
    );
    RAISE EXCEPTION 'invoiced delivery should not be collected directly';
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      IF v_err IS DISTINCT FROM 'delivery_note_invoiced' THEN
        RAISE;
      END IF;
  END;

  v_pay := api.record_invoice_payment(
    v_invoice, 15000, 'transfer', 'TR-1',
    'cf264000-0000-0000-0000-000000000009'::uuid, now()
  );
  SELECT amount_cents INTO v_first FROM data.payments WHERE document_id = v_dn1 AND external_invoice_id = v_invoice;
  SELECT amount_cents INTO v_second FROM data.payments WHERE document_id = v_dn2 AND external_invoice_id = v_invoice;
  IF v_first IS NULL OR v_second IS NULL OR v_first + v_second <> 15000 THEN
    RAISE EXCEPTION 'invoice payment split failed first % second %', v_first, v_second;
  END IF;
  IF (SELECT reference FROM data.payments WHERE id = v_pay) IS DISTINCT FROM 'TR-1' THEN
    RAISE EXCEPTION 'shared reference missing';
  END IF;

  INSERT INTO data.contacts (id, tenant_id, kind, display_name)
  VALUES (v_other_client, v_tenant, 'person', 'Alt client factura');
  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by, commercial_regime, service_mode
  ) VALUES (
    v_other_project, v_tenant, 'work_order', 'CF-26 other client', 'disposable',
    'active', 'company', v_site, v_other_client, v_owner, 'consumer', 'execute'
  );
  PERFORM api.upsert_project_line(
    v_other_project, NULL, NULL, 'service', 'Alt', NULL, 'u',
    1, 10, 0, 21, 0, NULL,
    'cf264000-0000-0000-0000-00000000000a'::uuid
  );
  v_other := api.issue_commercial_document(
    v_other_project, 'quote', true,
    'cf264000-0000-0000-0000-00000000000b'::uuid, NULL
  );
  PERFORM api.accept_commercial_document(
    v_other, '{"method":"sql_test"}'::jsonb,
    'cf264000-0000-0000-0000-00000000000c'::uuid
  );
  v_other := api.issue_commercial_document(
    v_other_project, 'delivery_note', true,
    'cf264000-0000-0000-0000-00000000000d'::uuid, NULL
  );
  BEGIN
    PERFORM api.register_external_invoice(
      'f-cf26-1', CURRENT_DATE, 100,
      ARRAY[v_other],
      'cf264000-0000-0000-0000-00000000000e'::uuid, NULL
    );
    RAISE EXCEPTION 'same invoice number on another client should fail';
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      IF v_err IS DISTINCT FROM 'invoice_number_cross_client' THEN
        RAISE;
      END IF;
  END;

  RAISE NOTICE 'external_invoices_tests ok';
END;
$$;

ROLLBACK;
