-- Tall 1 OS UX: immutable, idempotent quote reissue chain.

CREATE UNIQUE INDEX IF NOT EXISTS uq_commercial_documents_supersedes_quote
  ON data.commercial_documents (supersedes_id)
  WHERE doc_type = 'quote' AND supersedes_id IS NOT NULL;

-- The existing issuer owns all snapshot and line generation. A transaction-
-- local link lets the reissue RPC reuse it while setting supersedes_id before
-- the immutable document changes from draft to issued.
CREATE OR REPLACE FUNCTION data.trg_commercial_document_apply_supersedes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_raw text;
BEGIN
  v_raw := NULLIF(current_setting('app.commercial_supersedes_id', true), '');
  IF v_raw IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.doc_type <> 'quote' OR NEW.supersedes_id IS NOT NULL THEN
    RAISE EXCEPTION 'invalid_quote_reissue'
      USING ERRCODE = 'P0001';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM data.commercial_documents previous
    WHERE previous.id = v_raw::uuid
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
    RAISE EXCEPTION 'superseded_quote_invalid'
      USING ERRCODE = 'P0001';
  END IF;

  NEW.supersedes_id := v_raw::uuid;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_commercial_document_apply_supersedes
  ON data.commercial_documents;
CREATE TRIGGER trg_commercial_document_apply_supersedes
  BEFORE INSERT ON data.commercial_documents
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_commercial_document_apply_supersedes();

REVOKE ALL ON FUNCTION data.trg_commercial_document_apply_supersedes()
  FROM PUBLIC;

-- supersedes_id is trace metadata and becomes immutable at issuance too.
CREATE OR REPLACE FUNCTION data.trg_commercial_documents_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.status <> 'draft' THEN
    IF NEW.doc_type IS DISTINCT FROM OLD.doc_type
       OR NEW.doc_number IS DISTINCT FROM OLD.doc_number
       OR NEW.client_id IS DISTINCT FROM OLD.client_id
       OR NEW.project_id IS DISTINCT FROM OLD.project_id
       OR NEW.parent_document_id IS DISTINCT FROM OLD.parent_document_id
       OR NEW.supersedes_id IS DISTINCT FROM OLD.supersedes_id
       OR NEW.seller_snapshot IS DISTINCT FROM OLD.seller_snapshot
       OR NEW.buyer_snapshot IS DISTINCT FROM OLD.buyer_snapshot
       OR NEW.service_address_snapshot IS DISTINCT FROM OLD.service_address_snapshot
       OR NEW.terms_text IS DISTINCT FROM OLD.terms_text
       OR NEW.locale IS DISTINCT FROM OLD.locale
       OR NEW.currency IS DISTINCT FROM OLD.currency
       OR NEW.subtotal IS DISTINCT FROM OLD.subtotal
       OR NEW.tax_breakdown IS DISTINCT FROM OLD.tax_breakdown
       OR NEW.total IS DISTINCT FROM OLD.total
       OR NEW.valid_until IS DISTINCT FROM OLD.valid_until
       OR NEW.show_prices IS DISTINCT FROM OLD.show_prices
       OR NEW.content_hash IS DISTINCT FROM OLD.content_hash
    THEN
      RAISE EXCEPTION 'commercial_document_immutable'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION api.reissue_commercial_quote(
  p_previous_document_id uuid,
  p_client_op_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_previous data.commercial_documents%ROWTYPE;
  v_existing data.commercial_documents%ROWTYPE;
  v_new_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT *
  INTO v_previous
  FROM data.commercial_documents
  WHERE id = p_previous_document_id;

  IF NOT FOUND
     OR NOT (data.jwt_user_tenants() ? v_previous.tenant_id::text) THEN
    RAISE EXCEPTION 'quote_not_found_or_access_denied'
      USING ERRCODE = 'P0001';
  END IF;

  IF v_previous.doc_type <> 'quote'
     OR NOT (
       v_previous.status IN ('rejected', 'expired', 'cancelled')
       OR (
         v_previous.status = 'issued'
         AND v_previous.valid_until IS NOT NULL
         AND v_previous.valid_until <= now()
       )
     ) THEN
    RAISE EXCEPTION 'quote_not_reissuable' USING ERRCODE = 'P0001';
  END IF;

  SELECT *
  INTO v_existing
  FROM data.commercial_documents
  WHERE tenant_id = v_previous.tenant_id
    AND client_op_id = p_client_op_id;

  IF FOUND THEN
    IF v_existing.doc_type <> 'quote'
       OR v_existing.project_id IS DISTINCT FROM v_previous.project_id
       OR v_existing.supersedes_id IS DISTINCT FROM v_previous.id THEN
      RAISE EXCEPTION 'client_op_id_conflict' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_existing.id;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM data.commercial_documents current_quote
    WHERE current_quote.tenant_id = v_previous.tenant_id
      AND current_quote.project_id = v_previous.project_id
      AND current_quote.doc_type = 'quote'
      AND current_quote.id <> v_previous.id
      AND current_quote.status = 'issued'
      AND (
        current_quote.valid_until IS NULL
        OR current_quote.valid_until > now()
      )
  ) THEN
    RAISE EXCEPTION 'active_quote_already_exists' USING ERRCODE = 'P0001';
  END IF;

  PERFORM set_config(
    'app.commercial_supersedes_id',
    v_previous.id::text,
    true
  );

  v_new_id := api.issue_commercial_document(
    v_previous.project_id,
    'quote',
    COALESCE(v_previous.show_prices, true),
    p_client_op_id,
    NULL
  );

  PERFORM set_config('app.commercial_supersedes_id', '', true);

  IF NOT EXISTS (
    SELECT 1
    FROM data.commercial_documents issued
    WHERE issued.id = v_new_id
      AND issued.supersedes_id = v_previous.id
  ) THEN
    RAISE EXCEPTION 'quote_reissue_link_failed' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO data.commercial_document_events (
    tenant_id,
    document_id,
    event_type,
    actor_id,
    client_op_id,
    payload
  ) VALUES (
    v_previous.tenant_id,
    v_previous.id,
    'superseded',
    v_uid,
    extensions.gen_random_uuid(),
    jsonb_build_object('superseded_by_id', v_new_id)
  );

  RETURN v_new_id;
END;
$$;

REVOKE ALL ON FUNCTION api.reissue_commercial_quote(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.reissue_commercial_quote(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION api.reissue_commercial_quote(uuid, uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.reissue_commercial_quote(uuid, uuid) IS
  'Idempotently issues a new quote linked to a terminal quote via supersedes_id.';
