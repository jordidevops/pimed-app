-- CF-26: replace an uninvoiced delivery note without moving its payments.

CREATE UNIQUE INDEX IF NOT EXISTS uq_commercial_documents_supersedes_delivery
  ON data.commercial_documents (supersedes_id)
  WHERE doc_type = 'delivery_note' AND supersedes_id IS NOT NULL;

CREATE OR REPLACE FUNCTION data.trg_commercial_document_apply_supersedes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_quote text;
  v_delivery text;
BEGIN
  v_delivery := NULLIF(current_setting('app.commercial_delivery_supersedes_id', true), '');
  IF v_delivery IS NOT NULL THEN
    IF NEW.doc_type <> 'delivery_note' OR NEW.supersedes_id IS NOT NULL THEN
      RAISE EXCEPTION 'invalid_delivery_rectify' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (
      SELECT 1
      FROM data.commercial_documents previous
      WHERE previous.id = v_delivery::uuid
        AND previous.tenant_id = NEW.tenant_id
        AND previous.project_id IS NOT DISTINCT FROM NEW.project_id
        AND previous.doc_type = 'delivery_note'
        AND previous.status = 'cancelled'
    ) THEN
      RAISE EXCEPTION 'superseded_delivery_invalid' USING ERRCODE = 'P0001';
    END IF;
    NEW.supersedes_id := v_delivery::uuid;
    RETURN NEW;
  END IF;

  v_quote := NULLIF(current_setting('app.commercial_supersedes_id', true), '');
  IF v_quote IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.doc_type <> 'quote' OR NEW.supersedes_id IS NOT NULL THEN
    RAISE EXCEPTION 'invalid_quote_reissue' USING ERRCODE = 'P0001';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM data.commercial_documents previous
    WHERE previous.id = v_quote::uuid
      AND previous.tenant_id = NEW.tenant_id
      AND previous.project_id = NEW.project_id
      AND previous.doc_type = 'quote'
      AND (
        previous.status IN ('rejected', 'expired', 'cancelled')
        OR (
          previous.status = 'issued'
          AND previous.valid_until IS NOT NULL
          AND previous.valid_until <= now()
        )
      )
  ) THEN
    RAISE EXCEPTION 'superseded_quote_invalid' USING ERRCODE = 'P0001';
  END IF;

  NEW.supersedes_id := v_quote::uuid;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION api.rectify_delivery_note(
  p_document_id uuid,
  p_reason text,
  p_client_op_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_existing data.commercial_documents%ROWTYPE;
  v_new_id uuid;
  v_paid integer := 0;
  v_new_total integer := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF NULLIF(btrim(COALESCE(p_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'rectify_reason_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = p_document_id
  FOR UPDATE;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_doc.doc_type IS DISTINCT FROM 'delivery_note' THEN
    RAISE EXCEPTION 'document_not_rectifiable' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_existing
  FROM data.commercial_documents
  WHERE tenant_id = v_doc.tenant_id
    AND client_op_id = p_client_op_id;
  IF FOUND THEN
    IF v_existing.doc_type IS DISTINCT FROM 'delivery_note'
       OR v_existing.supersedes_id IS DISTINCT FROM v_doc.id THEN
      RAISE EXCEPTION 'client_op_id_conflict' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_existing.id;
  END IF;

  IF v_doc.status NOT IN ('issued', 'signed', 'accepted') THEN
    RAISE EXCEPTION 'document_not_rectifiable' USING ERRCODE = 'P0001';
  END IF;
  IF NULLIF(btrim(COALESCE(v_doc.external_invoice_ref, '')), '') IS NOT NULL THEN
    RAISE EXCEPTION 'rectify_delivery_invoiced' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM data.commercial_documents newer
    WHERE newer.supersedes_id = v_doc.id
      AND newer.doc_type = 'delivery_note'
  ) THEN
    RAISE EXCEPTION 'document_already_rectified' USING ERRCODE = 'P0001';
  END IF;

  IF v_doc.project_id IS NOT NULL THEN
    PERFORM 1 FROM data.projects WHERE id = v_doc.project_id FOR UPDATE;
  END IF;

  UPDATE data.commercial_documents
  SET status = 'cancelled', updated_at = now()
  WHERE id = v_doc.id;

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, content_hash, payload
  ) VALUES (
    v_doc.tenant_id, v_doc.id, 'cancelled', v_uid, v_doc.content_hash,
    jsonb_build_object('reason', btrim(p_reason), 'rectified', true)
  );

  PERFORM set_config('app.commercial_delivery_supersedes_id', v_doc.id::text, true);
  v_new_id := api.issue_commercial_document(
    v_doc.project_id,
    'delivery_note',
    v_doc.show_prices,
    p_client_op_id,
    NULL
  );
  PERFORM set_config('app.commercial_delivery_supersedes_id', '', true);

  SELECT COALESCE(SUM(p.amount_cents), 0)::integer
  INTO v_paid
  FROM data.payments p
  WHERE p.tenant_id = v_doc.tenant_id
    AND p.document_id IN (
      WITH RECURSIVE chain AS (
        SELECT v_doc.id AS id, v_doc.supersedes_id AS supersedes_id, 1 AS depth
        UNION ALL
        SELECT previous.id, previous.supersedes_id, chain.depth + 1
        FROM data.commercial_documents previous
        JOIN chain ON previous.id = chain.supersedes_id
        WHERE chain.depth < 20
      )
      SELECT chain.id FROM chain
    );

  SELECT data.commercial_document_total_cents(d.total)
  INTO v_new_total
  FROM data.commercial_documents d
  WHERE d.id = v_new_id;

  IF v_paid > COALESCE(v_new_total, 0) THEN
    RAISE EXCEPTION 'rectify_payments_exceed_total' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, content_hash, payload
  ) VALUES (
    v_doc.tenant_id, v_doc.id, 'superseded', v_uid, v_doc.content_hash,
    jsonb_build_object('reason', btrim(p_reason), 'superseded_by_id', v_new_id)
  );

  RETURN v_new_id;
END;
$$;

REVOKE ALL ON FUNCTION api.rectify_delivery_note(uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.rectify_delivery_note(uuid, text, uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.rectify_delivery_note(uuid, text, uuid) IS
  'Cancels an uninvoiced delivery note and issues its replacement. Payments stay on the original and are inherited through supersedes_id.';
