-- Optional working title for commercial documents (editable while draft).
-- The page heading must not use the document number or an id fragment as the name.

ALTER TABLE data.commercial_documents
  ADD COLUMN IF NOT EXISTS title text;

COMMENT ON COLUMN data.commercial_documents.title IS
  'Títol de treball opcional. Editable només en esborrany. El número oficial és doc_number.';

CREATE OR REPLACE FUNCTION data.trg_commercial_documents_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.status <> 'draft' THEN
    IF NEW.doc_type IS DISTINCT FROM OLD.doc_type
       OR NEW.doc_number IS DISTINCT FROM OLD.doc_number
       OR NEW.client_id IS DISTINCT FROM OLD.client_id
       OR (
         NEW.project_id IS DISTINCT FROM OLD.project_id
         AND NOT (
           OLD.project_id IS NULL
           AND NEW.project_id IS NOT NULL
           AND COALESCE(current_setting('app.orphan_project_link', true), '') = 'on'
         )
       )
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
       OR NEW.full_body_template_id IS DISTINCT FROM OLD.full_body_template_id
       OR NEW.formalization_mode IS DISTINCT FROM OLD.formalization_mode
       OR NEW.title IS DISTINCT FROM OLD.title
    THEN
      RAISE EXCEPTION 'commercial_document_immutable'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE VIEW api.commercial_documents
  WITH (security_invoker = true) AS
SELECT * FROM data.commercial_documents
WHERE tenant_id = data.active_tenant_id();

GRANT SELECT ON api.commercial_documents TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.set_commercial_document_title(
  p_document_id uuid,
  p_title text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_doc data.commercial_documents%ROWTYPE;
  v_title text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_doc.status <> 'draft' THEN
    RAISE EXCEPTION 'commercial_document_immutable' USING ERRCODE = 'P0001';
  END IF;
  IF NOT data.can_edit_commercial_pricing(v_doc.tenant_id, NULL) THEN
    RAISE EXCEPTION 'permission_denied:commercial.pricing.edit' USING ERRCODE = 'P0001';
  END IF;

  v_title := NULLIF(btrim(COALESCE(p_title, '')), '');
  IF v_title IS NOT NULL AND char_length(v_title) > 120 THEN
    RAISE EXCEPTION 'title_too_long' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.commercial_documents
  SET title = v_title, updated_at = now()
  WHERE id = p_document_id;

  RETURN p_document_id;
END;
$$;

REVOKE ALL ON FUNCTION api.set_commercial_document_title(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_commercial_document_title(uuid, text)
  TO authenticated, service_role;
