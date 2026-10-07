-- CF-28 F6: customer portal commercial allowlist (data.* getters/lists).
BEGIN;

DO $$
DECLARE
  v_tenant_a uuid := '10000000-0000-0000-0000-000000000004';
  v_tenant_b uuid := '10000000-0000-0000-0000-000000000003';
  v_client_a uuid := '80000000-0000-0000-0000-000000000201';
  v_client_other uuid;
  v_quote uuid := '52000000-0000-0000-0000-000000000903';
  v_list jsonb;
  v_detail jsonb;
  v_found boolean;
BEGIN
  -- Cross-tenant: tenant B + client A → empty
  v_list := data.list_customer_portal_quotes_agreements(
    v_tenant_b, v_client_a, NULL, NULL, 20
  );
  IF jsonb_array_length(v_list) <> 0 THEN
    RAISE EXCEPTION 'FAIL cross-tenant list leaked rows';
  END IF;

  v_detail := data.get_customer_portal_quote_agreement(
    v_tenant_b, v_client_a, v_quote, 'document'
  );
  IF v_detail IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL cross-tenant detail leaked';
  END IF;

  -- Other client same tenant → empty / null
  SELECT id INTO v_client_other
  FROM data.contacts
  WHERE tenant_id = v_tenant_a
    AND id IS DISTINCT FROM v_client_a
  LIMIT 1;

  IF v_client_other IS NOT NULL THEN
    v_list := data.list_customer_portal_quotes_agreements(
      v_tenant_a, v_client_other, NULL, NULL, 20
    );
    SELECT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_list) e WHERE e->>'id' = v_quote::text
    ) INTO v_found;
    IF v_found THEN
      RAISE EXCEPTION 'FAIL cross-client list leaked quote';
    END IF;

    v_detail := data.get_customer_portal_quote_agreement(
      v_tenant_a, v_client_other, v_quote, 'document'
    );
    IF v_detail IS NOT NULL THEN
      RAISE EXCEPTION 'FAIL cross-client detail leaked';
    END IF;
  END IF;

  -- Happy path: owned quote appears; drafts never in list
  v_list := data.list_customer_portal_quotes_agreements(
    v_tenant_a, v_client_a, NULL, NULL, 50
  );
  SELECT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_list) e WHERE e->>'id' = v_quote::text
  ) INTO v_found;
  IF NOT v_found THEN
    RAISE EXCEPTION 'FAIL owned quote missing from list';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(v_list) e
    JOIN data.commercial_documents d ON d.id = (e->>'id')::uuid
    WHERE d.status = 'draft'
  ) INTO v_found;
  IF v_found THEN
    RAISE EXCEPTION 'FAIL draft present in portal list';
  END IF;

  v_detail := data.get_customer_portal_quote_agreement(
    v_tenant_a, v_client_a, v_quote, 'document'
  );
  IF v_detail IS NULL OR v_detail->>'label' IS DISTINCT FROM 'P-2026-9003' THEN
    RAISE EXCEPTION 'FAIL owned quote detail missing/wrong label';
  END IF;
  -- Getter may keep pdf_file_path/pdf_storage_type for edge signing; never DMS/source UUIDs.
  IF v_detail ? 'created_by'
     OR v_detail ? 'pdf_document_id'
     OR v_detail ? 'source_quote_id'
  THEN
    RAISE EXCEPTION 'FAIL detail leaked internal fields';
  END IF;

  -- List respects show_prices (total null when false)
  SELECT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(
      data.list_customer_portal_quotes_agreements(
        v_tenant_a, v_client_a, NULL, NULL, 50
      )
    ) e
    JOIN data.commercial_documents d ON d.id = (e->>'id')::uuid
    WHERE d.show_prices = false
      AND e->>'item_kind' = 'document'
      AND e->>'total' IS NOT NULL
  ) INTO v_found;
  IF v_found THEN
    RAISE EXCEPTION 'FAIL show_prices=false list still exposes total';
  END IF;

  -- show_prices=false on lines helper strips price fields (docs issued are immutable)
  v_detail := data.customer_portal_commercial_lines_json(v_quote, false);
  IF jsonb_array_length(v_detail) > 0
     AND (
       (v_detail->0) ? 'unit_price'
       OR (v_detail->0) ? 'line_total'
     )
  THEN
    RAISE EXCEPTION 'FAIL show_prices=false lines still expose prices';
  END IF;

  v_detail := data.customer_portal_commercial_lines_json(v_quote, true);
  IF jsonb_array_length(v_detail) > 0 AND NOT ((v_detail->0) ? 'line_total') THEN
    RAISE EXCEPTION 'FAIL show_prices=true lines missing line_total';
  END IF;

  -- Invoice collection helper: cancelled → cancelled + zero paid/outstanding
  PERFORM 1 FROM data.customer_portal_invoice_collection(
    v_tenant_a,
    '00000000-0000-0000-0000-000000000001'::uuid,
    100,
    'cancelled'
  ) c
  WHERE c.collection_status = 'cancelled'
    AND c.paid_cents = 0
    AND c.outstanding_cents = 0;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FAIL invoice collection cancelled mapping';
  END IF;

  -- Agreements pending_signature without decision request must not appear
  SELECT EXISTS (
    SELECT 1
    FROM data.commercial_agreements a
    JOIN data.commercial_agreement_versions v ON v.id = a.active_version_id
    WHERE a.tenant_id = v_tenant_a
      AND a.client_id = v_client_a
      AND v.status = 'pending_signature'
      AND NOT EXISTS (
        SELECT 1
        FROM data.commercial_decision_requests r
        WHERE r.agreement_version_id = v.id
          AND r.tenant_id = v_tenant_a
      )
      AND EXISTS (
        SELECT 1
        FROM jsonb_array_elements(
          data.list_customer_portal_quotes_agreements(
            v_tenant_a, v_client_a, NULL, NULL, 50
          )
        ) e
        WHERE e->>'id' = a.id::text
          AND e->>'item_kind' = 'agreement'
      )
  ) INTO v_found;
  IF v_found THEN
    RAISE EXCEPTION 'FAIL pending agreement without send leaked into portal list';
  END IF;

  -- disputed mapping for rejected DN
  IF EXISTS (
    SELECT 1 FROM data.commercial_documents
    WHERE tenant_id = v_tenant_a AND client_id = v_client_a
      AND doc_type = 'delivery_note' AND status = 'rejected'
  ) THEN
    v_list := data.list_customer_portal_delivery_notes(
      v_tenant_a, v_client_a, NULL, NULL, 50
    );
    SELECT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_list) e WHERE e->>'status' = 'disputed'
    ) INTO v_found;
    IF NOT v_found THEN
      RAISE EXCEPTION 'FAIL rejected DN not mapped to disputed';
    END IF;
  END IF;

  -- payment ref mask helper
  IF data.customer_portal_mask_payment_ref('AB12345678') IS DISTINCT FROM '••••5678' THEN
    RAISE EXCEPTION 'FAIL payment ref mask';
  END IF;
  IF data.customer_portal_mask_payment_ref('12') IS DISTINCT FROM '••••' THEN
    RAISE EXCEPTION 'FAIL short payment ref mask';
  END IF;

  RAISE NOTICE 'PASS customer_portal_commercial_read_tests';
END;
$$;

ROLLBACK;
