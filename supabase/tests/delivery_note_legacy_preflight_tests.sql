-- CF-26 preflight: two full delivery notes on one order are a conflict.
-- Rolls back.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client uuid := '80000000-0000-0000-0000-000000000101';
  v_client_b uuid := '81000000-0000-0000-0000-00000000cf26';
  v_site uuid := '30000000-0000-0000-0000-000000000004';
  v_project uuid := '51000000-0000-0000-0000-00000000cf26';
  v_other_dn uuid := '51000000-0000-0000-0000-00000000cf27';
  v_quote uuid;
  v_dn1 uuid;
  v_dn2 uuid;
  v_multi int;
  v_over int;
  v_nulls int;
  v_cross int;
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
    site_id, client_id, created_by
  ) VALUES (
    v_project, v_tenant, 'work_order', 'CF-26 preflight', 'disposable',
    'active', 'company', v_site, v_client, v_owner
  );

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'Hores preflight', NULL, 'h',
    4, 25, 0, 21, 0, NULL,
    'cf260000-0000-0000-0000-000000000001'::uuid
  );

  v_quote := api.issue_commercial_document(
    v_project, 'quote', true,
    'cf260000-0000-0000-0000-000000000002'::uuid,
    NULL
  );
  PERFORM api.accept_commercial_document(
    v_quote,
    '{"method":"sql_test"}'::jsonb,
    'cf260000-0000-0000-0000-000000000003'::uuid
  );

  v_dn1 := api.issue_commercial_document(
    v_project, 'delivery_note', true,
    'cf260000-0000-0000-0000-000000000004'::uuid,
    NULL
  );
  v_dn2 := '51000000-0000-0000-0000-00000000cf28';
  INSERT INTO data.commercial_documents (
    id, tenant_id, doc_type, doc_number, client_id, project_id, status,
    currency, subtotal, total, show_prices, issued_at, created_by,
    seller_snapshot, buyer_snapshot
  )
  SELECT
    v_dn2, d.tenant_id, 'delivery_note', 'A-PREFLIGHT-DUP', d.client_id, d.project_id,
    'issued', d.currency, d.subtotal, d.total, true, now(), d.created_by,
    d.seller_snapshot, d.buyer_snapshot
  FROM data.commercial_documents d
  WHERE d.id = v_dn1;

  INSERT INTO data.commercial_document_lines (
    tenant_id, document_id, source_project_line_id, kind, name, unit, quantity,
    unit_price, discount_pct, tax_rate, line_subtotal, line_tax, line_total, position
  )
  SELECT
    tenant_id, v_dn2, source_project_line_id, kind, name, unit, quantity,
    unit_price, discount_pct, tax_rate, line_subtotal, line_tax, line_total, position
  FROM data.commercial_document_lines
  WHERE document_id = v_dn1;

  INSERT INTO data.commercial_document_lines (
    tenant_id, document_id, kind, name, unit, quantity,
    unit_price, line_subtotal, line_tax, line_total
  ) VALUES (
    v_tenant, v_dn1, 'service', 'Sense origen', 'u', 1,
    0, 0, 0, 0
  );

  SELECT count(*) INTO v_multi
  FROM api.list_delivery_note_legacy_conflicts(v_tenant)
  WHERE conflict_kind = 'multiple_active_delivery_notes'
    AND project_id = v_project;

  IF v_multi <> 1 THEN
    RAISE EXCEPTION 'expected one multi-DN conflict, got %', v_multi;
  END IF;

  SELECT count(*) INTO v_over
  FROM api.list_delivery_note_legacy_conflicts(v_tenant)
  WHERE conflict_kind = 'delivered_qty_exceeds_project_line'
    AND project_id = v_project;

  IF v_over <> 1 THEN
    RAISE EXCEPTION 'expected one over-delivered line, got %', v_over;
  END IF;

  SELECT count(*) INTO v_nulls
  FROM api.list_delivery_note_legacy_conflicts(v_tenant)
  WHERE conflict_kind = 'null_source_project_line'
    AND document_id = v_dn1;

  IF v_nulls <> 1 THEN
    RAISE EXCEPTION 'expected one null-source conflict, got %', v_nulls;
  END IF;

  INSERT INTO data.contacts (id, tenant_id, kind, display_name)
  VALUES (v_client_b, v_tenant, 'person', 'Client preflight B')
  ON CONFLICT (id) DO NOTHING;

  UPDATE data.commercial_documents
  SET external_invoice_ref = 'F-PREFLIGHT-1'
  WHERE id = v_dn1;

  INSERT INTO data.commercial_documents (
    id, tenant_id, doc_type, doc_number, client_id, status,
    currency, subtotal, total, show_prices, issued_at, external_invoice_ref,
    seller_snapshot, buyer_snapshot, created_by
  ) VALUES (
    v_other_dn, v_tenant, 'delivery_note', 'A-PREFLIGHT-X', v_client_b, 'issued',
    'EUR', 10, 12.10, true, now(), 'F-PREFLIGHT-1',
    '{}'::jsonb, '{}'::jsonb, v_owner
  );

  SELECT count(*) INTO v_cross
  FROM api.list_delivery_note_legacy_conflicts(v_tenant)
  WHERE conflict_kind = 'invoice_ref_cross_client'
    AND detail LIKE 'f-preflight-1%';

  IF v_cross <> 1 THEN
    RAISE EXCEPTION 'expected one cross-client invoice ref, got %', v_cross;
  END IF;

  RAISE NOTICE 'delivery_note_legacy_preflight_tests ok';
END;
$$;

ROLLBACK;
