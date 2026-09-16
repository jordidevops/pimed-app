-- CF-17: honest partial payments (no Stripe / no Holded API).
-- Caps over-collection, serializes payment writes per project, and allows a
-- text-only external invoice reference on issued delivery notes.

CREATE OR REPLACE FUNCTION data.commercial_document_total_cents(p_total numeric)
RETURNS integer
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT GREATEST(0, ROUND(COALESCE(p_total, 0) * 100)::integer);
$$;

REVOKE ALL ON FUNCTION data.commercial_document_total_cents(numeric) FROM PUBLIC;

CREATE OR REPLACE FUNCTION data.commercial_payment_remaining_cents(p_document_id uuid)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_doc data.commercial_documents%ROWTYPE;
  v_paid bigint := 0;
  v_advances bigint := 0;
  v_delivery data.commercial_documents%ROWTYPE;
  v_delivery_paid bigint := 0;
  v_remaining bigint := 0;
BEGIN
  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = p_document_id;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  SELECT COALESCE(SUM(p.amount_cents), 0)
  INTO v_paid
  FROM data.payments p
  WHERE p.tenant_id = v_doc.tenant_id
    AND p.document_id = v_doc.id;

  IF v_doc.doc_type = 'delivery_note' THEN
    SELECT COALESCE(SUM(p.amount_cents), 0)
    INTO v_advances
    FROM data.payments p
    JOIN data.commercial_documents d ON d.id = p.document_id
    WHERE d.tenant_id = v_doc.tenant_id
      AND v_doc.project_id IS NOT NULL
      AND d.project_id = v_doc.project_id
      AND d.doc_type IN ('quote', 'quote_amendment')
      AND d.status IN ('accepted', 'signed');
    v_remaining := data.commercial_document_total_cents(v_doc.total)
      - v_paid
      - v_advances;
  ELSIF v_doc.doc_type IN ('quote', 'quote_amendment') THEN
    v_remaining := data.commercial_document_total_cents(v_doc.total) - v_paid;
    SELECT * INTO v_delivery
    FROM data.commercial_documents d
    WHERE d.tenant_id = v_doc.tenant_id
      AND v_doc.project_id IS NOT NULL
      AND d.project_id = v_doc.project_id
      AND d.doc_type = 'delivery_note'
      AND d.status IN ('issued', 'signed', 'accepted')
    ORDER BY d.created_at DESC
    LIMIT 1;
    IF FOUND THEN
      SELECT COALESCE(SUM(p.amount_cents), 0)
      INTO v_delivery_paid
      FROM data.payments p
      WHERE p.tenant_id = v_delivery.tenant_id
        AND p.document_id = v_delivery.id;
      SELECT COALESCE(SUM(p.amount_cents), 0)
      INTO v_advances
      FROM data.payments p
      JOIN data.commercial_documents d ON d.id = p.document_id
      WHERE d.tenant_id = v_doc.tenant_id
        AND d.project_id = v_doc.project_id
        AND d.doc_type IN ('quote', 'quote_amendment')
        AND d.status IN ('accepted', 'signed');
      v_remaining := LEAST(
        v_remaining,
        data.commercial_document_total_cents(v_delivery.total)
          - v_delivery_paid
          - v_advances
      );
    END IF;
  ELSE
    RETURN 0;
  END IF;

  RETURN GREATEST(0, v_remaining)::integer;
END;
$$;

REVOKE ALL ON FUNCTION data.commercial_payment_remaining_cents(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.commercial_payment_remaining_cents(uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.record_payment(
  p_document_id uuid,
  p_amount_cents integer,
  p_method text,
  p_client_op_id uuid,
  p_reference text DEFAULT NULL,
  p_occurred_at timestamptz DEFAULT now()
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_id uuid;
  v_remaining integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_amount_cents IS NULL OR p_amount_cents <= 0 THEN
    RAISE EXCEPTION 'invalid_amount' USING ERRCODE = 'P0001';
  END IF;
  IF p_method NOT IN ('cash', 'card', 'transfer', 'bizum', 'payment_link') THEN
    RAISE EXCEPTION 'invalid_payment_method' USING ERRCODE = 'P0001';
  END IF;
  IF p_method = 'payment_link'
     AND NULLIF(btrim(COALESCE(p_reference, '')), '') IS NULL THEN
    RAISE EXCEPTION 'payment_link_reference_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = p_document_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_doc.project_id IS NOT NULL THEN
    PERFORM 1
    FROM data.commercial_documents d
    WHERE d.tenant_id = v_doc.tenant_id
      AND d.project_id = v_doc.project_id
    FOR UPDATE;
  ELSE
    PERFORM 1
    FROM data.commercial_documents d
    WHERE d.id = v_doc.id
    FOR UPDATE;
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = p_document_id;

  SELECT id INTO v_id
  FROM data.payments
  WHERE tenant_id = v_doc.tenant_id
    AND client_op_id = p_client_op_id;
  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  IF v_doc.doc_type = 'delivery_note' THEN
    IF v_doc.status NOT IN ('issued', 'signed', 'accepted') THEN
      RAISE EXCEPTION 'payment_document_not_collectable' USING ERRCODE = 'P0001';
    END IF;
  ELSIF v_doc.doc_type IN ('quote', 'quote_amendment') THEN
    IF v_doc.status NOT IN ('accepted', 'signed') THEN
      RAISE EXCEPTION 'payment_document_not_collectable' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    RAISE EXCEPTION 'payment_document_not_collectable' USING ERRCODE = 'P0001';
  END IF;

  v_remaining := data.commercial_payment_remaining_cents(v_doc.id);
  IF p_amount_cents > v_remaining THEN
    RAISE EXCEPTION 'payment_exceeds_remaining' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO data.payments (
    tenant_id, document_id, amount_cents, method, reference,
    collected_by, occurred_at, client_op_id
  ) VALUES (
    v_doc.tenant_id, p_document_id, p_amount_cents, p_method,
    NULLIF(btrim(COALESCE(p_reference, '')), ''),
    v_uid, COALESCE(p_occurred_at, now()), p_client_op_id
  ) RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.record_payment(uuid, integer, text, uuid, text, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.record_payment(uuid, integer, text, uuid, text, timestamptz)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.set_delivery_external_invoice_ref(
  p_document_id uuid,
  p_ref text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = p_document_id
  FOR UPDATE;

  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_doc.doc_type IS DISTINCT FROM 'delivery_note' THEN
    RAISE EXCEPTION 'external_invoice_not_a_delivery' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.status NOT IN ('issued', 'signed', 'accepted') THEN
    RAISE EXCEPTION 'payment_document_not_collectable' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.commercial_documents
  SET external_invoice_ref = NULLIF(btrim(COALESCE(p_ref, '')), ''),
      updated_at = now()
  WHERE id = p_document_id;
END;
$$;

REVOKE ALL ON FUNCTION api.set_delivery_external_invoice_ref(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_delivery_external_invoice_ref(uuid, text)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
