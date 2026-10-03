-- CF-27 Sales 1B: invoice payment + allocations ledger.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-00000000cf72';
  v_quote uuid;
  v_dn1 uuid;
  v_dn2 uuid;
  v_draft uuid;
  v_invoice uuid;
  v_pay jsonb;
  v_pay2 jsonb;
  v_payment_id uuid;
  v_alloc_sum integer;
  v_remaining integer;
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
  SELECT v_tenant, d, EXTRACT(YEAR FROM CURRENT_DATE)::int, 7000
  FROM unnest(ARRAY['quote','quote_amendment','delivery_note','invoice']) AS d
  ON CONFLICT (tenant_id, doc_type, year) DO UPDATE
  SET last_value = GREATEST(data.document_number_counters.last_value, EXCLUDED.last_value);

  INSERT INTO data.commercial_document_number_counters (tenant_id, series_id, period_key, last_value)
  SELECT v_tenant, s.id, EXTRACT(YEAR FROM CURRENT_DATE)::int::text, 7000
  FROM data.commercial_document_series s
  WHERE s.tenant_id = v_tenant AND s.active
  ON CONFLICT (tenant_id, series_id, period_key) DO UPDATE
  SET last_value = GREATEST(data.commercial_document_number_counters.last_value, EXCLUDED.last_value);

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by, commercial_regime, service_mode
  ) VALUES (
    v_project, v_tenant, 'work_order', 'CF-27 allocations', 'disposable',
    'active', 'company', v_site, v_client, v_owner, 'consumer', 'execute'
  );

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Hores alloc', NULL, 'h',
    1, 100, 0, 21, 0, NULL,
    'cf271000-0000-0000-0000-000000000001'::uuid
  );
  v_quote := api.issue_commercial_document(
    v_project, 'quote', true,
    'cf271000-0000-0000-0000-000000000002'::uuid, NULL
  );
  PERFORM api.accept_commercial_document(
    v_quote, '{"method":"sql_test"}'::jsonb,
    'cf271000-0000-0000-0000-000000000003'::uuid
  );
  UPDATE data.projects SET authorized_total = authorized_total + 1000 WHERE id = v_project;
  v_dn1 := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cf271000-0000-0000-0000-000000000004'::uuid, NULL
  );
  PERFORM api.upsert_project_line(
    v_project, (
      SELECT id FROM data.project_lines WHERE project_id = v_project LIMIT 1
    ), NULL, 'service', 'Hores alloc', NULL, 'h',
    2, 100, 0, 21, 0, NULL,
    'cf271000-0000-0000-0000-000000000005'::uuid
  );
  v_dn2 := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cf271000-0000-0000-0000-000000000006'::uuid, NULL
  );

  -- Quote advance still reduces remaining via balances
  PERFORM api.record_payment(
    v_quote, 5000, 'transfer',
    'cf271000-0000-0000-0000-000000000007'::uuid, 'ADV', now()
  );

  v_draft := api.create_invoice_draft_from_delivery_notes(
    ARRAY[v_dn1, v_dn2],
    'cf271000-0000-0000-0000-000000000008'::uuid,
    CURRENT_DATE, NULL
  );
  v_invoice := api.issue_invoice(
    v_draft,
    'cf271000-0000-0000-0000-000000000009'::uuid,
    CURRENT_DATE, NULL, NULL
  );

  BEGIN
    PERFORM api.record_payment(
      v_dn1, 100, 'cash',
      'cf271000-0000-0000-0000-00000000000a'::uuid, NULL, now()
    );
    RAISE EXCEPTION 'invoiced DN direct payment should fail';
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      IF v_err IS DISTINCT FROM 'delivery_note_invoiced' THEN
        RAISE;
      END IF;
  END;

  v_pay := api.record_invoice_payment(
    v_invoice, 10000, 'transfer', 'TR-ALLOC',
    'cf271000-0000-0000-0000-00000000000b'::uuid, now()
  );
  v_payment_id := (v_pay->>'payment_id')::uuid;

  IF (SELECT COUNT(*) FROM data.payments WHERE id = v_payment_id) <> 1 THEN
    RAISE EXCEPTION 'exactly one invoice payment row expected';
  END IF;
  IF (SELECT document_id FROM data.payments WHERE id = v_payment_id) IS DISTINCT FROM v_invoice THEN
    RAISE EXCEPTION 'payment must sit on invoice document';
  END IF;

  SELECT COALESCE(SUM(amount_cents), 0)::integer INTO v_alloc_sum
  FROM data.payment_allocations WHERE payment_id = v_payment_id;
  IF v_alloc_sum <> 10000 THEN
    RAISE EXCEPTION 'allocations must sum to payment, got %', v_alloc_sum;
  END IF;

  -- Retry same client_op_id → same payment
  v_pay2 := api.record_invoice_payment(
    v_invoice, 10000, 'transfer', 'TR-ALLOC',
    'cf271000-0000-0000-0000-00000000000b'::uuid, now()
  );
  IF (v_pay2->>'payment_id')::uuid IS DISTINCT FROM v_payment_id
     OR COALESCE((v_pay2->>'idempotent')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'idempotent retry failed: %', v_pay2;
  END IF;
  IF (SELECT COUNT(*) FROM data.payments WHERE document_id = v_invoice) <> 1 THEN
    RAISE EXCEPTION 'retry must not create extra payments';
  END IF;

  SELECT remaining_cents INTO v_remaining
  FROM data.delivery_balances(v_tenant, ARRAY[v_project])
  WHERE delivery_note_id = v_dn1;
  IF v_remaining IS NULL THEN
    RAISE EXCEPTION 'balance missing for dn1';
  END IF;

  BEGIN
    PERFORM api.record_invoice_payment(
      v_invoice, 999999, 'transfer', NULL,
      'cf271000-0000-0000-0000-00000000000c'::uuid, now()
    );
    RAISE EXCEPTION 'overpay should fail';
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      IF v_err IS DISTINCT FROM 'payment_exceeds_remaining' THEN
        RAISE;
      END IF;
  END;

  -- Cancel blocked when invoice has payment
  BEGIN
    PERFORM api.cancel_invoice(
      v_invoice,
      'cf271000-0000-0000-0000-00000000000d'::uuid
    );
    RAISE EXCEPTION 'cancel with invoice payment should fail';
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      IF v_err IS DISTINCT FROM 'invoice_has_payments' THEN
        RAISE;
      END IF;
  END;

  RAISE NOTICE 'sales_payment_allocations_tests ok';
END;
$$;

ROLLBACK;
