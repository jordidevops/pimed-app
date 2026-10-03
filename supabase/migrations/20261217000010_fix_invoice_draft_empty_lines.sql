-- CF-27/CF-26 UAT: draft from DN without lines left orphan (total 0); cancel only allowed issued.
-- 1) Reject draft create when DNs have no lines / totals would mismatch after recompute.
-- 2) Allow cancel_invoice on draft (release links) so orphan drafts can be discarded.

CREATE OR REPLACE FUNCTION api.create_invoice_draft_from_delivery_notes(
  p_delivery_note_ids uuid[],
  p_client_op_id uuid,
  p_issued_on date DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tenant uuid := data.active_tenant_id();
  v_existing uuid;
  v_client uuid;
  v_project uuid;
  v_projects uuid[] := ARRAY[]::uuid[];
  v_invoice_id uuid;
  v_dn data.commercial_documents%ROWTYPE;
  v_first data.commercial_documents%ROWTYPE;
  v_id_item uuid;
  v_sorted uuid[];
  v_pos int := 0;
  v_line record;
  v_line_count int := 0;
  v_inv_total integer := 0;
  v_dn_total integer := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;
  PERFORM data.assert_invoice_permission(v_tenant, 'invoices.edit');
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_delivery_note_ids IS NULL OR cardinality(p_delivery_note_ids) = 0 THEN
    RAISE EXCEPTION 'invoice_delivery_notes_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT id INTO v_existing
  FROM data.commercial_documents
  WHERE tenant_id = v_tenant
    AND client_op_id = p_client_op_id;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  SELECT ARRAY_AGG(DISTINCT x ORDER BY x)
  INTO v_sorted
  FROM unnest(p_delivery_note_ids) AS x;

  PERFORM 1
  FROM data.commercial_documents d
  WHERE d.id = ANY (v_sorted)
  ORDER BY d.id
  FOR UPDATE;

  FOREACH v_id_item IN ARRAY v_sorted LOOP
    SELECT * INTO v_dn FROM data.commercial_documents WHERE id = v_id_item;
    IF NOT FOUND
       OR v_dn.tenant_id IS DISTINCT FROM v_tenant
       OR NOT (data.jwt_user_tenants() ? v_dn.tenant_id::text) THEN
      RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
    END IF;
    IF v_dn.doc_type IS DISTINCT FROM 'delivery_note'
       OR v_dn.status NOT IN ('issued', 'signed', 'accepted')
       OR v_dn.client_id IS NULL THEN
      RAISE EXCEPTION 'invoice_delivery_invalid' USING ERRCODE = 'P0001';
    END IF;
    IF data.delivery_note_is_invoiced(v_dn.id) THEN
      RAISE EXCEPTION 'delivery_already_invoiced' USING ERRCODE = 'P0001';
    END IF;
    IF v_client IS NULL THEN
      v_client := v_dn.client_id;
      v_first := v_dn;
    ELSIF v_dn.client_id IS DISTINCT FROM v_client THEN
      RAISE EXCEPTION 'invoice_client_mismatch' USING ERRCODE = 'P0001';
    END IF;
    IF v_dn.project_id IS NOT NULL AND NOT (v_dn.project_id = ANY (v_projects)) THEN
      v_projects := v_projects || v_dn.project_id;
    END IF;
  END LOOP;

  SELECT COUNT(*)::int INTO v_line_count
  FROM data.commercial_document_lines cdl
  WHERE cdl.document_id = ANY (v_sorted);
  IF v_line_count = 0 THEN
    RAISE EXCEPTION 'invoice_delivery_notes_empty_lines' USING ERRCODE = 'P0001';
  END IF;

  IF cardinality(v_projects) = 1 THEN
    v_project := v_projects[1];
  ELSE
    v_project := NULL;
  END IF;

  INSERT INTO data.commercial_documents (
    tenant_id, doc_type, doc_number, client_id, project_id, contact_site_id,
    status, seller_snapshot, buyer_snapshot, service_address_snapshot,
    terms_text, locale, currency, subtotal, tax_breakdown, total,
    show_prices, issued_on, client_op_id, created_by, formalization_mode
  ) VALUES (
    v_tenant,
    'invoice',
    NULL,
    v_client,
    v_project,
    v_first.contact_site_id,
    'draft',
    v_first.seller_snapshot,
    v_first.buyer_snapshot,
    v_first.service_address_snapshot,
    NULLIF(btrim(COALESCE(p_notes, '')), ''),
    v_first.locale,
    v_first.currency,
    0, '[]'::jsonb, 0,
    true,
    p_issued_on,
    p_client_op_id,
    v_uid,
    'signed_quote'
  ) RETURNING id INTO v_invoice_id;

  INSERT INTO data.invoice_delivery_notes (invoice_id, delivery_note_id, tenant_id)
  SELECT v_invoice_id, dn_id, v_tenant
  FROM unnest(v_sorted) AS dn_id;

  FOR v_line IN
    SELECT cdl.*
    FROM unnest(v_sorted) AS dn_id
    JOIN data.commercial_document_lines cdl ON cdl.document_id = dn_id
    ORDER BY array_position(v_sorted, dn_id), cdl.position, cdl.created_at
  LOOP
    INSERT INTO data.commercial_document_lines (
      tenant_id, document_id, source_project_line_id, source_commercial_document_line_id,
      catalog_item_id, kind, name, description, unit, quantity, unit_price,
      discount_pct, tax_rate, tax_category, line_subtotal, line_tax, line_total, position
    ) VALUES (
      v_tenant, v_invoice_id, v_line.source_project_line_id, v_line.id,
      v_line.catalog_item_id, v_line.kind, v_line.name, v_line.description, v_line.unit,
      v_line.quantity, v_line.unit_price, v_line.discount_pct, v_line.tax_rate,
      v_line.tax_category, v_line.line_subtotal, v_line.line_tax, v_line.line_total, v_pos
    );
    v_pos := v_pos + 1;
  END LOOP;

  PERFORM data.recompute_commercial_document_totals(v_invoice_id);

  SELECT ROUND(COALESCE(total, 0) * 100)::integer INTO v_inv_total
  FROM data.commercial_documents WHERE id = v_invoice_id;

  SELECT COALESCE(SUM(ROUND(COALESCE(d.total, 0) * 100))::integer, 0) INTO v_dn_total
  FROM data.commercial_documents d
  WHERE d.id = ANY (v_sorted);

  IF v_inv_total IS DISTINCT FROM v_dn_total THEN
    RAISE EXCEPTION 'invoice_totals_mismatch: invoice=% dn=%', v_inv_total, v_dn_total
      USING ERRCODE = 'P0001';
  END IF;

  RETURN v_invoice_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.cancel_invoice(
  p_invoice_id uuid,
  p_client_op_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tenant uuid := data.active_tenant_id();
  v_doc data.commercial_documents%ROWTYPE;
  v_event_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;
  PERFORM data.assert_invoice_permission(v_tenant, 'invoices.edit');
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT id INTO v_event_id
  FROM data.commercial_document_events
  WHERE tenant_id = v_tenant
    AND client_op_id = p_client_op_id;
  IF v_event_id IS NOT NULL THEN
    RETURN p_invoice_id;
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = p_invoice_id
  FOR UPDATE;
  IF NOT FOUND
     OR v_doc.tenant_id IS DISTINCT FROM v_tenant
     OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  -- Draft discard + issued cancel (same release of active DN links).
  IF v_doc.doc_type IS DISTINCT FROM 'invoice'
     OR v_doc.status NOT IN ('draft', 'issued') THEN
    RAISE EXCEPTION 'invoice_not_cancellable' USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1 FROM data.payments p
    WHERE p.tenant_id = v_doc.tenant_id
      AND p.document_id = v_doc.id
  ) THEN
    RAISE EXCEPTION 'invoice_has_payments' USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1 FROM data.commercial_document_external_refs r
    WHERE r.document_id = v_doc.id
      AND r.synced_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'invoice_externally_synced' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.commercial_documents
  SET status = 'cancelled', updated_at = now()
  WHERE id = v_doc.id;

  UPDATE data.invoice_delivery_notes
  SET released_at = now()
  WHERE invoice_id = v_doc.id
    AND released_at IS NULL;

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, content_hash, client_op_id, payload
  ) VALUES (
    v_doc.tenant_id,
    v_doc.id,
    'invoice_cancelled',
    v_uid,
    v_doc.content_hash,
    p_client_op_id,
    jsonb_build_object('doc_number', v_doc.doc_number, 'previous_status', v_doc.status)
  );

  RETURN v_doc.id;
END;
$$;

NOTIFY pgrst, 'reload schema';
