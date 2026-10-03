-- CF-26: rectify a delivery note without moving payments. Rolls back.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-00000000cf50';
  v_line uuid;
  v_quote uuid;
  v_dn uuid;
  v_new uuid;
  v_retry uuid;
  v_err text;
  v_status text;
  v_inherited integer;
  v_op uuid := 'cf263000-0000-0000-0000-000000000010';
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
    v_project, v_tenant, 'work_order', 'CF-26 rectify', 'disposable',
    'active', 'company', v_site, v_client, v_owner, 'consumer', 'execute'
  );

  v_line := api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Hores rectify', NULL, 'h',
    1, 100, 0, 21, 0, NULL,
    'cf263000-0000-0000-0000-000000000001'::uuid
  );
  v_quote := api.issue_commercial_document(
    v_project, 'quote', true,
    'cf263000-0000-0000-0000-000000000002'::uuid, NULL
  );
  PERFORM api.accept_commercial_document(
    v_quote, '{"method":"sql_test"}'::jsonb,
    'cf263000-0000-0000-0000-000000000003'::uuid
  );
  v_dn := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cf263000-0000-0000-0000-000000000004'::uuid, NULL
  );
  PERFORM api.record_payment(
    v_dn, 4000, 'cash',
    'cf263000-0000-0000-0000-000000000005'::uuid, NULL, now()
  );

  v_new := api.rectify_delivery_note(v_dn, 'Quantitat mal anotada', v_op);
  v_retry := api.rectify_delivery_note(v_dn, 'Quantitat mal anotada', v_op);
  IF v_new IS DISTINCT FROM v_retry THEN
    RAISE EXCEPTION 'rectify retry returned a different document';
  END IF;

  SELECT status INTO v_status FROM data.commercial_documents WHERE id = v_dn;
  IF v_status IS DISTINCT FROM 'cancelled' THEN
    RAISE EXCEPTION 'original should be cancelled, got %', v_status;
  END IF;
  IF (SELECT supersedes_id FROM data.commercial_documents WHERE id = v_new) IS DISTINCT FROM v_dn THEN
    RAISE EXCEPTION 'replacement does not point at the original';
  END IF;
  IF (SELECT document_id FROM data.payments WHERE document_id = v_dn) IS NULL THEN
    RAISE EXCEPTION 'payment was moved off the original';
  END IF;

  SELECT inherited_paid_cents INTO v_inherited
  FROM data.delivery_balances(v_tenant, ARRAY[v_project])
  WHERE delivery_note_id = v_new;
  IF v_inherited <> 4000 THEN
    RAISE EXCEPTION 'replacement should inherit 4000, got %', v_inherited;
  END IF;

  BEGIN
    UPDATE data.commercial_documents
    SET external_invoice_ref = 'F-RECTIFY'
    WHERE id = v_new;
    PERFORM api.rectify_delivery_note(
      v_new, 'Facturat',
      'cf263000-0000-0000-0000-000000000012'::uuid
    );
    RAISE EXCEPTION 'invoiced delivery should not be rectifiable';
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      IF v_err IS DISTINCT FROM 'rectify_delivery_invoiced' THEN
        RAISE;
      END IF;
  END;

  UPDATE data.project_lines SET unit_price = 1 WHERE id = v_line;
  BEGIN
    PERFORM api.rectify_delivery_note(
      v_new, 'Preu corregit per sota del cobrat',
      'cf263000-0000-0000-0000-000000000013'::uuid
    );
    RAISE EXCEPTION 'payments above the replacement total should fail';
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      IF v_err IS DISTINCT FROM 'rectify_payments_exceed_total' THEN
        RAISE;
      END IF;
  END;

  RAISE NOTICE 'rectify_delivery_note_tests ok';
END;
$$;

ROLLBACK;
