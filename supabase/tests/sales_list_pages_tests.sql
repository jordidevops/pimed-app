-- CF-27 Sales 4: list_sales_delivery_notes_page billing filter + keyset.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-00000000cf80';
  v_dn1 uuid;
  v_dn2 uuid;
  v_draft uuid;
  v_invoice uuid;
  v_items jsonb;
  v_count bigint;
  v_cursor_value text;
  v_cursor_id uuid;
  v_has_more boolean;
  v_billing text;
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
  SELECT v_tenant, d, EXTRACT(YEAR FROM CURRENT_DATE)::int, 8000
  FROM unnest(ARRAY['quote','quote_amendment','delivery_note','invoice']) AS d
  ON CONFLICT (tenant_id, doc_type, year) DO UPDATE
  SET last_value = GREATEST(data.document_number_counters.last_value, EXCLUDED.last_value);

  INSERT INTO data.commercial_document_number_counters (tenant_id, series_id, period_key, last_value)
  SELECT v_tenant, s.id, EXTRACT(YEAR FROM CURRENT_DATE)::int::text, 8000
  FROM data.commercial_document_series s
  WHERE s.tenant_id = v_tenant AND s.active
  ON CONFLICT (tenant_id, series_id, period_key) DO UPDATE
  SET last_value = GREATEST(data.commercial_document_number_counters.last_value, EXCLUDED.last_value);

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by, commercial_regime, service_mode
  ) VALUES (
    v_project, v_tenant, 'work_order', 'CF-27 sales list', 'disposable',
    'active', 'company', v_site, v_client, v_owner, 'consumer', 'execute'
  );

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Hores llista sales', NULL, 'h',
    1, 100, 0, 21, 0, NULL,
    'cf274000-0000-0000-0000-000000000001'::uuid
  );
  PERFORM api.accept_commercial_document(
    api.issue_commercial_document(
      v_project, 'quote', true,
      'cf274000-0000-0000-0000-000000000002'::uuid, NULL
    ),
    '{"method":"sql_test"}'::jsonb,
    'cf274000-0000-0000-0000-000000000003'::uuid
  );
  UPDATE data.projects SET authorized_total = authorized_total + 1000 WHERE id = v_project;

  v_dn1 := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cf274000-0000-0000-0000-000000000004'::uuid, NULL
  );
  PERFORM api.upsert_project_line(
    v_project, (
      SELECT id FROM data.project_lines WHERE project_id = v_project LIMIT 1
    ), NULL, 'service', 'Hores llista sales', NULL, 'h',
    2, 100, 0, 21, 0, NULL,
    'cf274000-0000-0000-0000-000000000005'::uuid
  );
  v_dn2 := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cf274000-0000-0000-0000-000000000006'::uuid, NULL
  );

  v_draft := api.create_invoice_draft_from_delivery_notes(
    ARRAY[v_dn1],
    'cf274000-0000-0000-0000-000000000007'::uuid,
    CURRENT_DATE,
    NULL
  );
  v_invoice := api.issue_invoice(
    v_draft,
    'cf274000-0000-0000-0000-000000000008'::uuid,
    CURRENT_DATE,
    NULL,
    NULL
  );

  SELECT items, total_count INTO v_items, v_count
  FROM api.list_sales_delivery_notes_page(
    NULL, v_project, NULL,
    ARRAY['to_invoice'], NULL,
    NULL, NULL, NULL,
    'issued_at', 'desc', NULL, NULL, 50
  );
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'to_invoice filter expected 1, got %', v_count;
  END IF;
  IF (v_items -> 0 ->> 'id')::uuid IS DISTINCT FROM v_dn2 THEN
    RAISE EXCEPTION 'to_invoice row should be dn2';
  END IF;

  SELECT items, total_count INTO v_items, v_count
  FROM api.list_sales_delivery_notes_page(
    NULL, v_project, NULL,
    ARRAY['invoiced'], NULL,
    NULL, NULL, NULL,
    'issued_at', 'desc', NULL, NULL, 50
  );
  IF v_count <> 1 OR (v_items -> 0 ->> 'id')::uuid IS DISTINCT FROM v_dn1 THEN
    RAISE EXCEPTION 'invoiced filter expected dn1';
  END IF;

  SELECT (items -> 0 ->> 'billing_status') INTO v_billing
  FROM api.list_sales_delivery_notes_page(
    NULL, v_project, NULL, NULL, NULL, NULL, NULL, NULL,
    'issued_at', 'desc', NULL, NULL, 1
  );
  IF v_billing IS NULL THEN
    RAISE EXCEPTION 'billing_status missing on page item';
  END IF;

  SELECT next_cursor_value, next_cursor_id, has_more
  INTO v_cursor_value, v_cursor_id, v_has_more
  FROM api.list_sales_delivery_notes_page(
    NULL, v_project, NULL, NULL, NULL, NULL, NULL, NULL,
    'issued_at', 'desc', NULL, NULL, 1
  );
  IF v_has_more IS NOT TRUE OR v_cursor_id IS NULL THEN
    RAISE EXCEPTION 'keyset should report has_more with cursor';
  END IF;

  SELECT total_count INTO v_count
  FROM api.list_sales_delivery_notes_page(
    NULL, v_project, NULL, NULL, NULL, NULL, NULL, NULL,
    'issued_at', 'desc', v_cursor_value, v_cursor_id, 50
  );
  IF v_count < 1 THEN
    RAISE EXCEPTION 'second page after cursor should still report total_count';
  END IF;

  SELECT total_count INTO v_count
  FROM api.list_sales_invoices_page(
    NULL, v_project, NULL, ARRAY['issued'], NULL,
    NULL, NULL, NULL,
    'issued_at', 'desc', NULL, NULL, 50
  );
  IF v_count < 1 THEN
    RAISE EXCEPTION 'invoice list should include issued invoice';
  END IF;

  BEGIN
    PERFORM api.list_sales_delivery_notes_page(
      NULL, NULL, 'x', NULL, NULL, NULL, NULL, NULL,
      'issued_at', 'desc', NULL, NULL, 10
    );
    RAISE EXCEPTION 'short q should fail';
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      IF SQLERRM IS DISTINCT FROM 'q_too_short' THEN
        RAISE;
      END IF;
  END;

  RAISE NOTICE 'sales_list_pages_tests ok';
END;
$$;

ROLLBACK;
