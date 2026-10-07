-- P0: register_external_invoice must not force PiMed doc_number from ERP ref.
-- Allocates series normally; stores the provided number only on commercial_document_external_refs.
-- Totals mismatch raises before issue (no live invoice with difference_cents).

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
SET search_path = data
AS $$
DECLARE
  v_issued uuid;
  v_number text := btrim(COALESCE(p_invoice_number, ''));
  v_notes_total integer := 0;
BEGIN
  IF v_number = '' OR p_issued_on IS NULL OR p_total_cents IS NULL OR p_total_cents < 0 THEN
    RAISE EXCEPTION 'external_invoice_invalid' USING ERRCODE = 'P0001';
  END IF;

  SELECT COALESCE(SUM(data.commercial_document_total_cents(d.total)), 0)::integer
    INTO v_notes_total
  FROM data.commercial_documents d
  WHERE d.id = ANY (p_delivery_note_ids);

  IF v_notes_total IS DISTINCT FROM p_total_cents THEN
    RAISE EXCEPTION 'invoice_totals_mismatch' USING ERRCODE = 'P0001';
  END IF;

  -- Native path: series allocation + optional ERP ref (never as doc_number).
  v_issued := api.issue_invoice_from_delivery_notes(
    p_delivery_note_ids,
    p_client_op_id,
    p_issued_on,
    p_notes,
    v_number
  );

  RETURN jsonb_build_object(
    'id', v_issued,
    'difference_cents', 0,
    'native_invoice', true
  );
END;
$$;

COMMENT ON FUNCTION api.register_external_invoice(text, date, integer, uuid[], uuid, text) IS
  'P0 shim: native invoice via issue_invoice_from_delivery_notes; p_invoice_number is ERP ref only; totals must match or RAISE invoice_totals_mismatch before issue.';

NOTIFY pgrst, 'reload schema';
