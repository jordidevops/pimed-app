-- CF-27 Sales 5: prepare + finalize commercial export batch.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-00000000cf81';
  v_dn uuid;
  v_draft uuid;
  v_invoice uuid;
  v_prep jsonb;
  v_fin jsonb;
  v_claim jsonb;
  v_batch uuid;
  v_review jsonb;
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
  SELECT v_tenant, d, EXTRACT(YEAR FROM CURRENT_DATE)::int, 9000
  FROM unnest(ARRAY['quote','quote_amendment','delivery_note','invoice']) AS d
  ON CONFLICT (tenant_id, doc_type, year) DO UPDATE
  SET last_value = GREATEST(data.document_number_counters.last_value, EXCLUDED.last_value);

  INSERT INTO data.commercial_document_number_counters (tenant_id, series_id, period_key, last_value)
  SELECT v_tenant, s.id, EXTRACT(YEAR FROM CURRENT_DATE)::int::text, 9000
  FROM data.commercial_document_series s
  WHERE s.tenant_id = v_tenant AND s.active
  ON CONFLICT (tenant_id, series_id, period_key) DO UPDATE
  SET last_value = GREATEST(data.commercial_document_number_counters.last_value, EXCLUDED.last_value);

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by, commercial_regime, service_mode
  ) VALUES (
    v_project, v_tenant, 'work_order', 'CF-27 export', 'disposable',
    'active', 'company', v_site, v_client, v_owner, 'consumer', 'execute'
  );

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Export line', NULL, 'h',
    1, 100, 0, 21, 0, NULL,
    'cf275000-0000-0000-0000-000000000001'::uuid
  );
  PERFORM api.accept_commercial_document(
    api.issue_commercial_document(
      v_project, 'quote', true,
      'cf275000-0000-0000-0000-000000000002'::uuid, NULL
    ),
    '{"method":"sql_test"}'::jsonb,
    'cf275000-0000-0000-0000-000000000003'::uuid
  );
  UPDATE data.projects SET authorized_total = authorized_total + 1000 WHERE id = v_project;
  v_dn := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cf275000-0000-0000-0000-000000000004'::uuid, NULL
  );
  v_draft := api.create_invoice_draft_from_delivery_notes(
    ARRAY[v_dn],
    'cf275000-0000-0000-0000-000000000005'::uuid,
    CURRENT_DATE,
    NULL
  );
  v_invoice := api.issue_invoice(
    v_draft,
    'cf275000-0000-0000-0000-000000000006'::uuid,
    CURRENT_DATE,
    NULL,
    NULL
  );

  v_review := api.upsert_accounting_review(
    v_invoice, 'reviewed', 'ok for export',
    'cf275000-0000-0000-0000-000000000007'::uuid
  );
  IF v_review ->> 'status' IS DISTINCT FROM 'reviewed' THEN
    RAISE EXCEPTION 'review upsert failed: %', v_review;
  END IF;

  v_prep := api.prepare_commercial_export_batch(
    CURRENT_DATE - 1, CURRENT_DATE + 1, NULL, NULL
  );
  IF v_prep ->> 'status' IS DISTINCT FROM 'preparing' THEN
    RAISE EXCEPTION 'prepare expected preparing, got %', v_prep;
  END IF;
  IF COALESCE((v_prep ->> 'row_count')::int, 0) < 1 THEN
    RAISE EXCEPTION 'prepare should include issued invoice, got %', v_prep;
  END IF;
  v_batch := (v_prep ->> 'batch_id')::uuid;

  v_fin := api.finalize_commercial_export_batch(v_batch);
  IF v_fin ->> 'status' IS DISTINCT FROM 'ready' THEN
    RAISE EXCEPTION 'finalize expected ready, got %', v_fin;
  END IF;
  IF NULLIF(v_fin ->> 'checksum', '') IS NULL THEN
    RAISE EXCEPTION 'finalize must set checksum';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.commercial_document_events
    WHERE document_id = v_invoice AND event_type = 'included_in_export'
  ) THEN
    RAISE EXCEPTION 'included_in_export event missing';
  END IF;

  v_claim := api.claim_commercial_export_batch(v_batch);
  IF v_claim -> 'package' -> 'files' ->> 'invoices.csv' IS NULL THEN
    RAISE EXCEPTION 'claim package missing invoices.csv';
  END IF;
  IF position(v_invoice::text IN (v_claim -> 'package' -> 'files' ->> 'invoices.csv')) = 0 THEN
    RAISE EXCEPTION 'invoices.csv should contain invoice id';
  END IF;

  RAISE NOTICE 'sales_accountant_exports_tests ok';
END;
$$;

ROLLBACK;
