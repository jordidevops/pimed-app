-- CF-17: remaining cap, quote advances, idempotency, payment_link ref, external invoice.
-- Kept as one statement so `supabase db query --file` can execute it.
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-000000000c17';
  v_quote uuid;
  v_delivery uuid;
  v_pay uuid;
  v_pay_retry uuid;
  v_remaining integer;
  v_invoice text;
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

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by
  ) VALUES (
    v_project,
    v_tenant,
    'work_order',
    'CF-17 partial payment test',
    'Disposable project for SQL tests',
    'active',
    'company',
    v_site,
    v_client,
    v_owner
  )
  ON CONFLICT (id) DO UPDATE SET
    status = 'active',
    client_id = EXCLUDED.client_id,
    updated_at = now();

  DELETE FROM data.payments
  WHERE document_id IN (
    SELECT id FROM data.commercial_documents WHERE project_id = v_project
  );
  DELETE FROM data.commercial_document_events
  WHERE document_id IN (
    SELECT id FROM data.commercial_documents WHERE project_id = v_project
  );
  DELETE FROM data.commercial_document_lines
  WHERE document_id IN (
    SELECT id FROM data.commercial_documents WHERE project_id = v_project
  );
  DELETE FROM data.commercial_documents WHERE project_id = v_project;
  DELETE FROM data.project_lines WHERE project_id = v_project;

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Base CF-17', NULL, 'u',
    1, 100, 0, 21, 0, NULL,
    'cf170000-0000-0000-0000-000000000001'::uuid
  );

  v_quote := api.issue_commercial_document(
    v_project, 'quote', true,
    'cf170000-0000-0000-0000-000000000002'::uuid,
    NULL
  );

  BEGIN
    PERFORM api.record_payment(
      v_quote, 1000, 'cash',
      'cf170000-0000-0000-0000-000000000003'::uuid,
      NULL,
      now()
    );
    RAISE EXCEPTION 'T1 issued quote should not be collectable';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%payment_document_not_collectable%' THEN
      RAISE;
    END IF;
  END;

  PERFORM api.accept_commercial_document(
    v_quote,
    '{"method":"sql_test"}'::jsonb,
    'cf170000-0000-0000-0000-000000000004'::uuid
  );

  PERFORM api.record_payment(
    v_quote, 3000, 'transfer',
    'cf170000-0000-0000-0000-000000000005'::uuid,
    'ADV-17',
    now()
  );

  v_delivery := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cf170000-0000-0000-0000-000000000006'::uuid,
    NULL
  );

  v_remaining := data.commercial_payment_remaining_cents(v_delivery);
  IF v_remaining <> data.commercial_document_total_cents(
       (SELECT total FROM data.commercial_documents WHERE id = v_delivery)
     ) - 3000 THEN
    RAISE EXCEPTION 'T2 quote advance did not reduce delivery remaining: %', v_remaining;
  END IF;

  BEGIN
    PERFORM api.record_payment(
      v_delivery, 1000, 'payment_link',
      'cf170000-0000-0000-0000-000000000007'::uuid,
      NULL,
      now()
    );
    RAISE EXCEPTION 'T3 payment_link without reference should fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%payment_link_reference_required%' THEN
      RAISE;
    END IF;
  END;

  v_pay := api.record_payment(
    v_delivery, 2000, 'card',
    'cf170000-0000-0000-0000-000000000008'::uuid,
    'POS-17',
    now()
  );
  v_pay_retry := api.record_payment(
    v_delivery, 99999, 'card',
    'cf170000-0000-0000-0000-000000000008'::uuid,
    'POS-17',
    now()
  );
  IF v_pay IS DISTINCT FROM v_pay_retry THEN
    RAISE EXCEPTION 'T4 idempotent retry must return the original payment';
  END IF;

  v_remaining := data.commercial_payment_remaining_cents(v_delivery);
  IF v_remaining <> data.commercial_document_total_cents(
       (SELECT total FROM data.commercial_documents WHERE id = v_delivery)
     ) - 5000 THEN
    RAISE EXCEPTION 'T5 remaining after partials: %', v_remaining;
  END IF;

  BEGIN
    PERFORM api.record_payment(
      v_delivery, v_remaining + 1, 'cash',
      'cf170000-0000-0000-0000-000000000009'::uuid,
      NULL,
      now()
    );
    RAISE EXCEPTION 'T6 sequential overpay did not fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%payment_exceeds_remaining%' THEN
      RAISE;
    END IF;
  END;

  PERFORM api.record_payment(
    v_delivery, v_remaining, 'cash',
    'cf170000-0000-0000-0000-00000000000a'::uuid,
    NULL,
    now()
  );

  IF data.commercial_payment_remaining_cents(v_delivery) <> 0 THEN
    RAISE EXCEPTION 'T7 delivery should be fully allocated';
  END IF;
  IF data.commercial_payment_remaining_cents(v_quote) <> 0 THEN
    RAISE EXCEPTION 'T8 quote remaining must cap at delivery remaining';
  END IF;

  BEGIN
    PERFORM api.record_payment(
      v_quote, 1, 'cash',
      'cf170000-0000-0000-0000-00000000000b'::uuid,
      NULL,
      now()
    );
    RAISE EXCEPTION 'T9 extra quote payment after delivery settled';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%payment_exceeds_remaining%' THEN
      RAISE;
    END IF;
  END;

  PERFORM api.set_delivery_external_invoice_ref(v_delivery, '  F-2026-017  ');
  SELECT external_invoice_ref INTO v_invoice
  FROM data.commercial_documents
  WHERE id = v_delivery;
  IF v_invoice IS DISTINCT FROM 'F-2026-017' THEN
    RAISE EXCEPTION 'T10 external invoice ref not saved: %', v_invoice;
  END IF;
END;
$$;
