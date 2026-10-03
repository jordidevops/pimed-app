-- CF-26: advances fill the oldest delivery note; replacements inherit payments.
-- Rolls back.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-00000000cf40';
  v_line uuid;
  v_quote uuid;
  v_dn1 uuid;
  v_dn2 uuid;
  v_old uuid := '51000000-0000-0000-0000-00000000cf41';
  v_new uuid := '51000000-0000-0000-0000-00000000cf42';
  v_pay uuid := '51000000-0000-0000-0000-00000000cf43';
  v_remaining integer;
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
    site_id, client_id, created_by, commercial_regime, service_mode, authorized_total
  ) VALUES (
    v_project, v_tenant, 'work_order', 'CF-26 fifo', 'disposable',
    'active', 'company', v_site, v_client, v_owner, 'consumer', 'execute', 0
  );

  v_line := api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Hores fifo', NULL, 'h',
    2, 100, 0, 21, 0, NULL,
    'cf262000-0000-0000-0000-000000000001'::uuid
  );
  v_quote := api.issue_commercial_document(
    v_project, 'quote', true,
    'cf262000-0000-0000-0000-000000000002'::uuid,
    NULL
  );
  PERFORM api.accept_commercial_document(
    v_quote, '{"method":"sql_test"}'::jsonb,
    'cf262000-0000-0000-0000-000000000003'::uuid
  );
  UPDATE data.projects SET authorized_total = 500 WHERE id = v_project;
  UPDATE data.project_lines SET quantity = 1 WHERE id = v_line;
  PERFORM api.record_payment(
    v_quote, 15000, 'transfer',
    'cf262000-0000-0000-0000-000000000004'::uuid,
    'ADV-FIFO',
    now()
  );

  v_dn1 := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cf262000-0000-0000-0000-000000000005'::uuid,
    NULL
  );
  UPDATE data.project_lines SET quantity = 2 WHERE id = v_line;
  v_dn2 := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cf262000-0000-0000-0000-000000000006'::uuid,
    NULL
  );

  SELECT remaining_cents INTO v_remaining
  FROM data.delivery_balances(v_tenant, ARRAY[v_project])
  WHERE delivery_note_id = v_dn1;
  IF v_remaining <> 0 THEN
    RAISE EXCEPTION 'oldest delivery should be covered by the advance, remaining %', v_remaining;
  END IF;

  SELECT remaining_cents INTO v_remaining
  FROM data.delivery_balances(v_tenant, ARRAY[v_project])
  WHERE delivery_note_id = v_dn2;
  IF v_remaining <> data.commercial_document_total_cents(
       (SELECT total FROM data.commercial_documents WHERE id = v_dn2)
     ) - (15000 - data.commercial_document_total_cents(
       (SELECT total FROM data.commercial_documents WHERE id = v_dn1)
     )) THEN
    RAISE EXCEPTION 'newer delivery should receive only the leftover advance, remaining %', v_remaining;
  END IF;

  IF data.commercial_payment_remaining_cents(v_dn1) <> 0 THEN
    RAISE EXCEPTION 'remaining function disagreed on the oldest delivery';
  END IF;

  INSERT INTO data.commercial_documents (
    id, tenant_id, doc_type, doc_number, client_id, project_id, status,
    currency, subtotal, total, show_prices, issued_at, created_by,
    seller_snapshot, buyer_snapshot
  ) VALUES (
    v_old, v_tenant, 'delivery_note', 'A-FIFO-OLD', v_client, v_project, 'issued',
    'EUR', 100, 100, true, now() - interval '1 day', v_owner,
    '{}'::jsonb, '{}'::jsonb
  );
  INSERT INTO data.payments (
    id, tenant_id, document_id, amount_cents, method, collected_by, client_op_id
  ) VALUES (
    v_pay, v_tenant, v_old, 4000, 'cash', v_owner,
    'cf262000-0000-0000-0000-000000000007'
  );
  INSERT INTO data.commercial_documents (
    id, tenant_id, doc_type, doc_number, client_id, project_id, status,
    supersedes_id, currency, subtotal, total, show_prices, issued_at, created_by,
    seller_snapshot, buyer_snapshot
  ) VALUES (
    v_new, v_tenant, 'delivery_note', 'A-FIFO-NEW', v_client, v_project, 'issued',
    v_old, 'EUR', 80, 80, true, now(), v_owner,
    '{}'::jsonb, '{}'::jsonb
  );
  UPDATE data.commercial_documents SET status = 'cancelled' WHERE id = v_old;

  SELECT inherited_paid_cents INTO v_remaining
  FROM data.delivery_balances(v_tenant, ARRAY[v_project])
  WHERE delivery_note_id = v_new;
  IF v_remaining <> 4000 THEN
    RAISE EXCEPTION 'replacement should inherit 4000, got %', v_remaining;
  END IF;

  RAISE NOTICE 'delivery_balances_fifo_tests ok';
END;
$$;

ROLLBACK;
