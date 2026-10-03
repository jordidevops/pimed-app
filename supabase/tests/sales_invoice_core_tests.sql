-- CF-27 Sales 1A: draft/issue/cancel invoices, active link gates.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_other_client uuid := '80000000-0000-0000-0000-00000000cf71';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-00000000cf70';
  v_project2 uuid := '51000000-0000-0000-0000-00000000cf71';
  v_quote uuid;
  v_dn1 uuid;
  v_dn2 uuid;
  v_other uuid;
  v_draft uuid;
  v_invoice uuid;
  v_link_count int;
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

  -- Avoid colliding with seed numbers (e.g. A-2026-0001) when allocate is behind.
  -- Keep last_value within 4 digits: pattern {####} uses lpad(...,4) which truncates.
  INSERT INTO data.document_number_counters (tenant_id, doc_type, year, last_value)
  SELECT v_tenant, d, EXTRACT(YEAR FROM CURRENT_DATE)::int, 6000
  FROM unnest(ARRAY['quote','quote_amendment','delivery_note','invoice']) AS d
  ON CONFLICT (tenant_id, doc_type, year) DO UPDATE
  SET last_value = GREATEST(data.document_number_counters.last_value, EXCLUDED.last_value);

  INSERT INTO data.commercial_document_number_counters (tenant_id, series_id, period_key, last_value)
  SELECT v_tenant, s.id, EXTRACT(YEAR FROM CURRENT_DATE)::int::text, 6000
  FROM data.commercial_document_series s
  WHERE s.tenant_id = v_tenant AND s.active
  ON CONFLICT (tenant_id, series_id, period_key) DO UPDATE
  SET last_value = GREATEST(data.commercial_document_number_counters.last_value, EXCLUDED.last_value);

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by, commercial_regime, service_mode
  ) VALUES (
    v_project, v_tenant, 'work_order', 'CF-27 invoice core', 'disposable',
    'active', 'company', v_site, v_client, v_owner, 'consumer', 'execute'
  );

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Hores factura', NULL, 'h',
    1, 100, 0, 21, 0, NULL,
    'cf270000-0000-0000-0000-000000000001'::uuid
  );
  v_quote := api.issue_commercial_document(
    v_project, 'quote', true,
    'cf270000-0000-0000-0000-000000000002'::uuid, NULL
  );
  PERFORM api.accept_commercial_document(
    v_quote, '{"method":"sql_test"}'::jsonb,
    'cf270000-0000-0000-0000-000000000003'::uuid
  );
  UPDATE data.projects SET authorized_total = authorized_total + 1000 WHERE id = v_project;
  v_dn1 := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cf270000-0000-0000-0000-000000000004'::uuid, NULL
  );

  -- Draft + issue 1 DN
  v_draft := api.create_invoice_draft_from_delivery_notes(
    ARRAY[v_dn1],
    'cf270000-0000-0000-0000-000000000005'::uuid,
    CURRENT_DATE,
    NULL
  );
  IF (SELECT status FROM data.commercial_documents WHERE id = v_draft) IS DISTINCT FROM 'draft' THEN
    RAISE EXCEPTION 'draft status expected';
  END IF;
  IF (SELECT doc_number FROM data.commercial_documents WHERE id = v_draft) IS NOT NULL THEN
    RAISE EXCEPTION 'draft must not have doc_number';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM data.commercial_document_lines
    WHERE document_id = v_draft AND source_commercial_document_line_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'lines must copy source_commercial_document_line_id';
  END IF;

  v_invoice := api.issue_invoice(
    v_draft,
    'cf270000-0000-0000-0000-000000000006'::uuid,
    CURRENT_DATE,
    NULL,
    NULL
  );
  IF (SELECT status FROM data.commercial_documents WHERE id = v_invoice) IS DISTINCT FROM 'issued' THEN
    RAISE EXCEPTION 'issued status expected';
  END IF;
  IF (SELECT doc_number FROM data.commercial_documents WHERE id = v_invoice) IS NULL THEN
    RAISE EXCEPTION 'issued invoice must have doc_number';
  END IF;

  BEGIN
    PERFORM api.record_payment(
      v_dn1, 100, 'cash',
      'cf270000-0000-0000-0000-000000000007'::uuid, NULL, now()
    );
    RAISE EXCEPTION 'invoiced delivery should not be collected directly';
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      IF v_err IS DISTINCT FROM 'delivery_note_invoiced' THEN
        RAISE;
      END IF;
  END;

  BEGIN
    PERFORM api.rectify_delivery_note(
      v_dn1, 'should fail',
      'cf270000-0000-0000-0000-000000000008'::uuid,
      '[]'::jsonb
    );
    RAISE EXCEPTION 'rectify with active invoice should fail';
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      IF v_err IS DISTINCT FROM 'rectify_delivery_invoiced' THEN
        RAISE;
      END IF;
  END;

  -- Cancel releases DN; link history remains
  PERFORM api.cancel_invoice(
    v_invoice,
    'cf270000-0000-0000-0000-000000000009'::uuid
  );
  IF data.delivery_note_is_invoiced(v_dn1) THEN
    RAISE EXCEPTION 'cancel should release active link';
  END IF;
  SELECT COUNT(*) INTO v_link_count
  FROM data.invoice_delivery_notes
  WHERE invoice_id = v_invoice AND released_at IS NOT NULL;
  IF v_link_count <> 1 THEN
    RAISE EXCEPTION 'cancel must keep released link history, got %', v_link_count;
  END IF;

  -- Two DN / two OS same client
  PERFORM api.upsert_project_line(
    v_project, (
      SELECT id FROM data.project_lines WHERE project_id = v_project LIMIT 1
    ), NULL, 'service', 'Hores factura', NULL, 'h',
    2, 100, 0, 21, 0, NULL,
    'cf270000-0000-0000-0000-00000000000a'::uuid
  );
  v_dn2 := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cf270000-0000-0000-0000-00000000000b'::uuid, NULL
  );

  INSERT INTO data.contacts (id, tenant_id, kind, display_name)
  VALUES (v_other_client, v_tenant, 'person', 'Alt client CF27');
  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by, commercial_regime, service_mode
  ) VALUES (
    v_project2, v_tenant, 'work_order', 'CF-27 other client', 'disposable',
    'active', 'company', v_site, v_other_client, v_owner, 'consumer', 'execute'
  );
  PERFORM api.upsert_project_line(
    v_project2, NULL, NULL, 'service', 'Alt', NULL, 'u',
    1, 10, 0, 21, 0, NULL,
    'cf270000-0000-0000-0000-00000000000c'::uuid
  );
  v_other := api.issue_commercial_document(
    v_project2, 'quote', true,
    'cf270000-0000-0000-0000-00000000000d'::uuid, NULL
  );
  PERFORM api.accept_commercial_document(
    v_other, '{"method":"sql_test"}'::jsonb,
    'cf270000-0000-0000-0000-00000000000e'::uuid
  );
  v_other := api.issue_commercial_document(
    v_project2, 'delivery_note', true,
    'cf270000-0000-0000-0000-00000000000f'::uuid, NULL
  );

  BEGIN
    PERFORM api.create_invoice_draft_from_delivery_notes(
      ARRAY[v_dn1, v_other],
      'cf270000-0000-0000-0000-000000000010'::uuid,
      CURRENT_DATE, NULL
    );
    RAISE EXCEPTION 'different clients should fail';
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      IF v_err IS DISTINCT FROM 'invoice_client_mismatch' THEN
        RAISE;
      END IF;
  END;

  v_draft := api.create_invoice_draft_from_delivery_notes(
    ARRAY[v_dn1, v_dn2],
    'cf270000-0000-0000-0000-000000000011'::uuid,
    CURRENT_DATE, NULL
  );
  v_invoice := api.issue_invoice(
    v_draft,
    'cf270000-0000-0000-0000-000000000012'::uuid,
    CURRENT_DATE, NULL, NULL
  );
  IF (SELECT COUNT(*) FROM data.invoice_delivery_notes
      WHERE invoice_id = v_invoice AND released_at IS NULL) <> 2 THEN
    RAISE EXCEPTION 'two active DN links expected';
  END IF;

  BEGIN
    PERFORM api.create_invoice_draft_from_delivery_notes(
      ARRAY[v_dn1],
      'cf270000-0000-0000-0000-000000000013'::uuid,
      CURRENT_DATE, NULL
    );
    RAISE EXCEPTION 'already invoiced DN should fail';
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      IF v_err IS DISTINCT FROM 'delivery_already_invoiced' THEN
        RAISE;
      END IF;
  END;

  RAISE NOTICE 'sales_invoice_core_tests ok';
END;
$$;

ROLLBACK;
