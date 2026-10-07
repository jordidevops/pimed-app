-- P0: native invoice path; ERP ref ≠ PiMed doc_number; legacy DN ref write deprecated.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-00000000cf60';
  v_quote uuid;
  v_dn1 uuid;
  v_dn2 uuid;
  v_invoice uuid;
  v_doc_number text;
  v_erp text;
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
    v_project, v_tenant, 'work_order', 'P0 invoice native', 'disposable',
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

  -- Legacy write on DN must fail
  BEGIN
    PERFORM api.set_delivery_external_invoice_ref(v_dn1, 'F-LEGACY');
    RAISE EXCEPTION 'set_delivery_external_invoice_ref should be deprecated';
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      IF v_err IS DISTINCT FROM 'external_invoice_ref_deprecated' THEN
        RAISE EXCEPTION 'unexpected deprecate error: %', v_err;
      END IF;
  END;

  -- Native issue with ERP ref (via shim): PiMed number ≠ ERP ref
  v_invoice := (api.register_external_invoice(
    'F-ERP-P0-1', CURRENT_DATE,
    data.commercial_document_total_cents((SELECT total FROM data.commercial_documents WHERE id = v_dn1))
      + data.commercial_document_total_cents((SELECT total FROM data.commercial_documents WHERE id = v_dn2)),
    ARRAY[v_dn1, v_dn2],
    'cf264000-0000-0000-0000-000000000007'::uuid,
    NULL
  )->>'id')::uuid;

  SELECT doc_number INTO v_doc_number
  FROM data.commercial_documents WHERE id = v_invoice;

  IF v_doc_number IS NULL OR v_doc_number = 'F-ERP-P0-1' THEN
    RAISE EXCEPTION 'PiMed doc_number must be series-allocated, not ERP ref (got %)', v_doc_number;
  END IF;

  SELECT r.external_number INTO v_erp
  FROM data.commercial_document_external_refs r
  WHERE r.document_id = v_invoice AND r.provider = 'manual';

  IF v_erp IS DISTINCT FROM 'F-ERP-P0-1' THEN
    RAISE EXCEPTION 'ERP ref missing on invoice, got %', v_erp;
  END IF;

  IF NOT data.delivery_note_is_invoiced(v_dn1) OR NOT data.delivery_note_is_invoiced(v_dn2) THEN
    RAISE EXCEPTION 'delivery notes should be linked to native invoice';
  END IF;

  -- Idempotent retry (same client_op_id + matching totals)
  IF (api.register_external_invoice(
    'F-ERP-P0-1', CURRENT_DATE,
    data.commercial_document_total_cents((SELECT total FROM data.commercial_documents WHERE id = v_dn1))
      + data.commercial_document_total_cents((SELECT total FROM data.commercial_documents WHERE id = v_dn2)),
    ARRAY[v_dn1, v_dn2],
    'cf264000-0000-0000-0000-000000000007'::uuid, NULL
  )->>'id')::uuid IS DISTINCT FROM v_invoice THEN
    RAISE EXCEPTION 'invoice register retry changed the id';
  END IF;

  -- Totals mismatch must raise before issuing (no live invoice with wrong total)
  BEGIN
    PERFORM api.register_external_invoice(
      'F-ERP-BAD', CURRENT_DATE, 999999999,
      ARRAY[v_dn1],
      'cf264000-0000-0000-0000-000000000099'::uuid,
      NULL
    );
    RAISE EXCEPTION 'expected invoice_totals_mismatch';
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      IF v_err IS DISTINCT FROM 'invoice_totals_mismatch' THEN
        RAISE EXCEPTION 'unexpected mismatch error: %', v_err;
      END IF;
  END;

  RAISE NOTICE 'external_invoices_tests (P0 native) ok';
END;
$$;

ROLLBACK;
