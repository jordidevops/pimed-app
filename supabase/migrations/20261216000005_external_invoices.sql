-- CF-26: one external invoice groups 1..N delivery notes of the same client.

CREATE TABLE IF NOT EXISTS data.external_invoices (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  client_id           uuid        NOT NULL REFERENCES data.contacts(id) ON DELETE RESTRICT,
  invoice_number      text        NOT NULL,
  invoice_number_key  text        GENERATED ALWAYS AS (lower(btrim(invoice_number))) STORED,
  issued_on           date        NOT NULL,
  total_cents         integer     NOT NULL CHECK (total_cents >= 0),
  file_node_id        uuid,
  notes               text,
  created_by          uuid        REFERENCES data.profiles(id) ON DELETE SET NULL,
  client_op_id        uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT external_invoices_number_nonempty CHECK (length(btrim(invoice_number)) > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_external_invoices_tenant_number
  ON data.external_invoices (tenant_id, invoice_number_key);

CREATE UNIQUE INDEX IF NOT EXISTS uq_external_invoices_tenant_client_op
  ON data.external_invoices (tenant_id, client_op_id)
  WHERE client_op_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_external_invoices_tenant_client
  ON data.external_invoices (tenant_id, client_id, issued_on DESC);

CREATE TABLE IF NOT EXISTS data.external_invoice_delivery_notes (
  invoice_id        uuid        NOT NULL REFERENCES data.external_invoices(id) ON DELETE CASCADE,
  delivery_note_id  uuid        NOT NULL REFERENCES data.commercial_documents(id) ON DELETE RESTRICT,
  tenant_id         uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  created_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (invoice_id, delivery_note_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_external_invoice_one_delivery
  ON data.external_invoice_delivery_notes (delivery_note_id);

ALTER TABLE data.payments
  ADD COLUMN IF NOT EXISTS external_invoice_id uuid
  REFERENCES data.external_invoices(id) ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS idx_payments_external_invoice
  ON data.payments (external_invoice_id)
  WHERE external_invoice_id IS NOT NULL;

ALTER TABLE data.external_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.external_invoice_delivery_notes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ei_select ON data.external_invoices;
CREATE POLICY ei_select ON data.external_invoices FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

DROP POLICY IF EXISTS eidn_select ON data.external_invoice_delivery_notes;
CREATE POLICY eidn_select ON data.external_invoice_delivery_notes FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

REVOKE ALL ON data.external_invoices FROM PUBLIC, anon, authenticated;
REVOKE ALL ON data.external_invoice_delivery_notes FROM PUBLIC, anon, authenticated;
GRANT SELECT ON data.external_invoices TO authenticated;
GRANT SELECT ON data.external_invoice_delivery_notes TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.external_invoices TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.external_invoice_delivery_notes TO service_role;

CREATE OR REPLACE VIEW api.external_invoices
  WITH (security_invoker = true) AS
SELECT * FROM data.external_invoices
WHERE tenant_id = data.active_tenant_id();

CREATE OR REPLACE VIEW api.external_invoice_delivery_notes
  WITH (security_invoker = true) AS
SELECT * FROM data.external_invoice_delivery_notes
WHERE tenant_id = data.active_tenant_id();

GRANT SELECT ON api.external_invoices TO authenticated, service_role;
GRANT SELECT ON api.external_invoice_delivery_notes TO authenticated, service_role;

CREATE OR REPLACE VIEW api.payments
  WITH (security_invoker = true) AS
SELECT * FROM data.payments
WHERE tenant_id = data.active_tenant_id();

GRANT SELECT ON api.payments TO authenticated, service_role;

-- Gate: refuse backfill when the same invoice number is used by different clients
-- (unique on tenant+number would fail). Progressive multi-DN projects are allowed;
-- clone cleanup is manual via remediate_legacy_duplicate_delivery_notes.
DO $$
DECLARE
  v_cross text;
BEGIN
  SELECT string_agg(format('%s (%s clients)', r.invoice_ref, r.client_count), ', ')
  INTO v_cross
  FROM (
    SELECT
      lower(btrim(dn.external_invoice_ref)) AS invoice_ref,
      count(DISTINCT dn.client_id)::int AS client_count
    FROM data.commercial_documents dn
    WHERE dn.doc_type = 'delivery_note'
      AND dn.status IN ('issued', 'signed', 'accepted')
      AND NULLIF(btrim(COALESCE(dn.external_invoice_ref, '')), '') IS NOT NULL
    GROUP BY lower(btrim(dn.external_invoice_ref))
    HAVING count(DISTINCT dn.client_id) > 1
  ) r;

  IF v_cross IS NOT NULL THEN
    RAISE EXCEPTION 'external_invoice_backfill_blocked: invoice_ref_cross_client: %', v_cross
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;

INSERT INTO data.external_invoices (
  tenant_id, client_id, invoice_number, issued_on, total_cents
)
SELECT
  grouped.tenant_id,
  grouped.client_id,
  grouped.invoice_number,
  CURRENT_DATE,
  grouped.total_cents
FROM (
  SELECT
    dn.tenant_id,
    dn.client_id,
    lower(btrim(dn.external_invoice_ref)) AS invoice_key,
    min(btrim(dn.external_invoice_ref)) AS invoice_number,
    SUM(data.commercial_document_total_cents(dn.total))::integer AS total_cents
  FROM data.commercial_documents dn
  WHERE dn.doc_type = 'delivery_note'
    AND dn.client_id IS NOT NULL
    AND NULLIF(btrim(COALESCE(dn.external_invoice_ref, '')), '') IS NOT NULL
  GROUP BY dn.tenant_id, dn.client_id, lower(btrim(dn.external_invoice_ref))
) grouped
WHERE NOT EXISTS (
  SELECT 1
  FROM data.external_invoices existing
  WHERE existing.tenant_id = grouped.tenant_id
    AND existing.invoice_number_key = grouped.invoice_key
);

INSERT INTO data.external_invoice_delivery_notes (invoice_id, delivery_note_id, tenant_id)
SELECT invoice.id, dn.id, dn.tenant_id
FROM data.commercial_documents dn
JOIN data.external_invoices invoice
  ON invoice.tenant_id = dn.tenant_id
 AND invoice.client_id = dn.client_id
 AND invoice.invoice_number_key = lower(btrim(dn.external_invoice_ref))
WHERE dn.doc_type = 'delivery_note'
  AND NULLIF(btrim(COALESCE(dn.external_invoice_ref, '')), '') IS NOT NULL
ON CONFLICT (delivery_note_id) DO NOTHING;

CREATE OR REPLACE FUNCTION api.register_external_invoice(
  p_invoice_number text,
  p_issued_on date,
  p_total_cents integer,
  p_delivery_note_ids uuid[],
  p_client_op_id uuid,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tenant uuid;
  v_client uuid;
  v_number text := btrim(COALESCE(p_invoice_number, ''));
  v_existing data.external_invoices%ROWTYPE;
  v_id uuid;
  v_notes_total integer := 0;
  v_dn data.commercial_documents%ROWTYPE;
  v_id_item uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF v_number = '' OR p_issued_on IS NULL OR p_total_cents IS NULL OR p_total_cents < 0 THEN
    RAISE EXCEPTION 'external_invoice_invalid' USING ERRCODE = 'P0001';
  END IF;
  IF p_delivery_note_ids IS NULL OR cardinality(p_delivery_note_ids) = 0 THEN
    RAISE EXCEPTION 'external_invoice_delivery_notes_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_existing
  FROM data.external_invoices
  WHERE client_op_id = p_client_op_id
    AND data.jwt_user_tenants() ? tenant_id::text;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'id', v_existing.id,
      'difference_cents', v_existing.total_cents - (
        SELECT COALESCE(SUM(data.commercial_document_total_cents(d.total)), 0)::integer
        FROM data.external_invoice_delivery_notes link
        JOIN data.commercial_documents d ON d.id = link.delivery_note_id
        WHERE link.invoice_id = v_existing.id
      )
    );
  END IF;

  PERFORM 1
  FROM data.commercial_documents d
  WHERE d.id = ANY (p_delivery_note_ids)
  FOR UPDATE;

  FOREACH v_id_item IN ARRAY p_delivery_note_ids LOOP
    SELECT * INTO v_dn FROM data.commercial_documents WHERE id = v_id_item;
    IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_dn.tenant_id::text) THEN
      RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
    END IF;
    IF v_dn.doc_type IS DISTINCT FROM 'delivery_note'
       OR v_dn.status NOT IN ('issued', 'signed', 'accepted')
       OR v_dn.client_id IS NULL THEN
      RAISE EXCEPTION 'external_invoice_delivery_invalid' USING ERRCODE = 'P0001';
    END IF;
    IF v_tenant IS NULL THEN
      v_tenant := v_dn.tenant_id;
      v_client := v_dn.client_id;
    ELSIF v_dn.tenant_id IS DISTINCT FROM v_tenant OR v_dn.client_id IS DISTINCT FROM v_client THEN
      RAISE EXCEPTION 'external_invoice_client_mismatch' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (
      SELECT 1 FROM data.external_invoice_delivery_notes link
      WHERE link.delivery_note_id = v_dn.id
    ) OR NULLIF(btrim(COALESCE(v_dn.external_invoice_ref, '')), '') IS NOT NULL THEN
      RAISE EXCEPTION 'delivery_already_invoiced' USING ERRCODE = 'P0001';
    END IF;
    v_notes_total := v_notes_total + data.commercial_document_total_cents(v_dn.total);
  END LOOP;

  IF EXISTS (
    SELECT 1
    FROM data.external_invoices existing
    WHERE existing.tenant_id = v_tenant
      AND existing.invoice_number_key = lower(v_number)
      AND existing.client_id IS DISTINCT FROM v_client
  ) THEN
    RAISE EXCEPTION 'invoice_number_cross_client' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM data.external_invoices existing
    WHERE existing.tenant_id = v_tenant
      AND existing.invoice_number_key = lower(v_number)
  ) THEN
    RAISE EXCEPTION 'external_invoice_number_taken' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO data.external_invoices (
    tenant_id, client_id, invoice_number, issued_on, total_cents, notes, created_by, client_op_id
  ) VALUES (
    v_tenant, v_client, v_number, p_issued_on, p_total_cents,
    NULLIF(btrim(COALESCE(p_notes, '')), ''), v_uid, p_client_op_id
  ) RETURNING id INTO v_id;

  INSERT INTO data.external_invoice_delivery_notes (invoice_id, delivery_note_id, tenant_id)
  SELECT v_id, dn_id, v_tenant
  FROM unnest(p_delivery_note_ids) AS dn_id;

  UPDATE data.commercial_documents
  SET external_invoice_ref = v_number, updated_at = now()
  WHERE id = ANY (p_delivery_note_ids);

  RETURN jsonb_build_object(
    'id', v_id,
    'difference_cents', p_total_cents - v_notes_total
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.unlink_delivery_note_from_invoice(p_delivery_note_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_link data.external_invoice_delivery_notes%ROWTYPE;
  v_invoice data.external_invoices%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_link
  FROM data.external_invoice_delivery_notes
  WHERE delivery_note_id = p_delivery_note_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT * INTO v_invoice
  FROM data.external_invoices
  WHERE id = v_link.invoice_id
  FOR UPDATE;
  IF NOT (data.jwt_user_tenants() ? v_invoice.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF EXISTS (
    SELECT 1 FROM data.payments p WHERE p.external_invoice_id = v_invoice.id
  ) THEN
    RAISE EXCEPTION 'invoice_has_payments' USING ERRCODE = 'P0001';
  END IF;

  DELETE FROM data.external_invoice_delivery_notes WHERE delivery_note_id = p_delivery_note_id;
  UPDATE data.commercial_documents
  SET external_invoice_ref = NULL, updated_at = now()
  WHERE id = p_delivery_note_id
    AND lower(btrim(COALESCE(external_invoice_ref, ''))) = v_invoice.invoice_number_key;

  IF NOT EXISTS (
    SELECT 1 FROM data.external_invoice_delivery_notes WHERE invoice_id = v_invoice.id
  ) THEN
    DELETE FROM data.external_invoices WHERE id = v_invoice.id;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION api.record_invoice_payment(
  p_invoice_id uuid,
  p_amount_cents integer,
  p_method text,
  p_reference text,
  p_client_op_id uuid,
  p_occurred_at timestamptz DEFAULT now()
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_invoice data.external_invoices%ROWTYPE;
  v_existing uuid;
  v_first uuid;
  v_left integer;
  v_slice integer;
  v_row record;
  v_open integer := 0;
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

  SELECT * INTO v_invoice FROM data.external_invoices WHERE id = p_invoice_id FOR UPDATE;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_invoice.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT id INTO v_existing
  FROM data.payments
  WHERE tenant_id = v_invoice.tenant_id AND client_op_id = p_client_op_id;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  PERFORM 1
  FROM data.commercial_documents d
  JOIN data.external_invoice_delivery_notes link ON link.delivery_note_id = d.id
  WHERE link.invoice_id = v_invoice.id
  FOR UPDATE;

  SELECT COALESCE(SUM(b.remaining_cents), 0)::integer
  INTO v_open
  FROM data.delivery_balances(v_invoice.tenant_id, NULL) b
  JOIN data.external_invoice_delivery_notes link ON link.delivery_note_id = b.delivery_note_id
  WHERE link.invoice_id = v_invoice.id;
  IF p_amount_cents > v_open THEN
    RAISE EXCEPTION 'payment_exceeds_remaining' USING ERRCODE = 'P0001';
  END IF;

  v_left := p_amount_cents;
  FOR v_row IN
    SELECT d.id, b.remaining_cents
    FROM data.external_invoice_delivery_notes link
    JOIN data.commercial_documents d ON d.id = link.delivery_note_id
    JOIN data.delivery_balances(v_invoice.tenant_id, NULL) b ON b.delivery_note_id = d.id
    WHERE link.invoice_id = v_invoice.id
    ORDER BY COALESCE(d.issued_at, d.created_at), d.id
  LOOP
    v_slice := LEAST(v_left, v_row.remaining_cents);
    IF v_slice <= 0 THEN
      CONTINUE;
    END IF;
    INSERT INTO data.payments (
      tenant_id, document_id, amount_cents, method, reference,
      collected_by, occurred_at, client_op_id, external_invoice_id
    ) VALUES (
      v_invoice.tenant_id,
      v_row.id,
      v_slice,
      p_method,
      NULLIF(btrim(COALESCE(p_reference, '')), ''),
      v_uid,
      COALESCE(p_occurred_at, now()),
      CASE WHEN v_first IS NULL THEN p_client_op_id ELSE gen_random_uuid() END,
      v_invoice.id
    ) RETURNING id INTO v_existing;
    IF v_first IS NULL THEN
      v_first := v_existing;
    END IF;
    v_left := v_left - v_slice;
    EXIT WHEN v_left = 0;
  END LOOP;

  RETURN v_first;
END;
$$;

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
    IF NULLIF(btrim(COALESCE(v_doc.external_invoice_ref, '')), '') IS NOT NULL
       OR EXISTS (
         SELECT 1 FROM data.external_invoice_delivery_notes link
         WHERE link.delivery_note_id = v_doc.id
       ) THEN
      RAISE EXCEPTION 'delivery_note_invoiced' USING ERRCODE = 'P0001';
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
  v_ref text := NULLIF(btrim(COALESCE(p_ref, '')), '');
  v_invoice data.external_invoices%ROWTYPE;
  v_found boolean := false;
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

  IF v_ref IS NULL THEN
    PERFORM api.unlink_delivery_note_from_invoice(v_doc.id);
    UPDATE data.commercial_documents
    SET external_invoice_ref = NULL, updated_at = now()
    WHERE id = v_doc.id;
    RETURN;
  END IF;

  SELECT * INTO v_invoice
  FROM data.external_invoices
  WHERE tenant_id = v_doc.tenant_id
    AND invoice_number_key = lower(v_ref);
  v_found := FOUND;
  IF v_found AND v_invoice.client_id IS DISTINCT FROM v_doc.client_id THEN
    RAISE EXCEPTION 'invoice_number_cross_client' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (
    SELECT 1 FROM data.external_invoice_delivery_notes link
    WHERE link.delivery_note_id = v_doc.id
      AND (NOT v_found OR link.invoice_id IS DISTINCT FROM v_invoice.id)
  ) THEN
    RAISE EXCEPTION 'delivery_already_invoiced' USING ERRCODE = 'P0001';
  END IF;

  IF NOT v_found THEN
    IF v_doc.client_id IS NULL THEN
      RAISE EXCEPTION 'external_invoice_delivery_invalid' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO data.external_invoices (
      tenant_id, client_id, invoice_number, issued_on, total_cents, created_by
    ) VALUES (
      v_doc.tenant_id,
      v_doc.client_id,
      v_ref,
      CURRENT_DATE,
      data.commercial_document_total_cents(v_doc.total),
      v_uid
    ) RETURNING * INTO v_invoice;
  END IF;

  INSERT INTO data.external_invoice_delivery_notes (invoice_id, delivery_note_id, tenant_id)
  VALUES (v_invoice.id, v_doc.id, v_doc.tenant_id)
  ON CONFLICT (delivery_note_id) DO NOTHING;

  UPDATE data.commercial_documents
  SET external_invoice_ref = v_ref, updated_at = now()
  WHERE id = v_doc.id;
END;
$$;

REVOKE ALL ON FUNCTION api.register_external_invoice(text, date, integer, uuid[], uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.unlink_delivery_note_from_invoice(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.record_invoice_payment(uuid, integer, text, text, uuid, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.register_external_invoice(text, date, integer, uuid[], uuid, text)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.unlink_delivery_note_from_invoice(uuid)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.record_invoice_payment(uuid, integer, text, text, uuid, timestamptz)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.register_external_invoice(text, date, integer, uuid[], uuid, text) IS
  'Groups active delivery notes of one client under an external invoice number. difference_cents is a warning, not a blocker.';

NOTIFY pgrst, 'reload schema';
