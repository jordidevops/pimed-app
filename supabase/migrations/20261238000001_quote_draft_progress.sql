-- Persist orphan quote draft wizard progress (template, formalization, step)
-- so leaving the quote and reopening restores the same screen.

ALTER TABLE data.commercial_documents
  ADD COLUMN IF NOT EXISTS draft_wizard_step text;

ALTER TABLE data.commercial_documents
  DROP CONSTRAINT IF EXISTS commercial_documents_draft_wizard_step_check;

ALTER TABLE data.commercial_documents
  ADD CONSTRAINT commercial_documents_draft_wizard_step_check
  CHECK (
    draft_wizard_step IS NULL
    OR draft_wizard_step IN ('lines', 'template', 'issue')
  );

COMMENT ON COLUMN data.commercial_documents.draft_wizard_step IS
  'Orphan quote draft wizard step: lines, template, or issue.';

CREATE OR REPLACE VIEW api.commercial_documents
WITH (security_invoker = true)
AS SELECT * FROM data.commercial_documents;

GRANT SELECT ON api.commercial_documents TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.set_commercial_quote_draft_progress(
  p_document_id uuid,
  p_full_body_template_id uuid DEFAULT NULL,
  p_set_template boolean DEFAULT false,
  p_formalization_mode text DEFAULT NULL,
  p_wizard_step text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_doc data.commercial_documents%ROWTYPE;
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
  IF v_doc.doc_type NOT IN ('quote', 'quote_amendment') THEN
    RAISE EXCEPTION 'quote_draft_only' USING ERRCODE = 'P0001';
  END IF;
  IF NOT data.can_edit_commercial_pricing(v_doc.tenant_id, NULL) THEN
    RAISE EXCEPTION 'permission_denied:commercial.pricing.edit' USING ERRCODE = 'P0001';
  END IF;

  IF p_set_template AND p_full_body_template_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.document_templates t
      WHERE t.id = p_full_body_template_id
        AND t.is_active AND t.template_type IN ('html', 'docx')
        AND lower(COALESCE(t.category, '')) = 'quote'
        AND (t.tenant_id = v_doc.tenant_id OR (t.tenant_id IS NULL AND t.is_platform_default))
    ) THEN
      RAISE EXCEPTION 'quote_template_invalid' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  IF p_formalization_mode IS NOT NULL
     AND p_formalization_mode NOT IN ('signed_quote', 'separate_agreement') THEN
    RAISE EXCEPTION 'formalization_mode_invalid' USING ERRCODE = 'P0001';
  END IF;

  IF p_wizard_step IS NOT NULL
     AND p_wizard_step NOT IN ('lines', 'template', 'issue') THEN
    RAISE EXCEPTION 'wizard_step_invalid' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.commercial_documents
  SET
    full_body_template_id = CASE
      WHEN p_set_template THEN p_full_body_template_id
      ELSE full_body_template_id
    END,
    formalization_mode = CASE
      WHEN p_formalization_mode IN ('signed_quote', 'separate_agreement') THEN p_formalization_mode
      ELSE formalization_mode
    END,
    draft_wizard_step = CASE
      WHEN p_wizard_step IN ('lines', 'template', 'issue') THEN p_wizard_step
      ELSE draft_wizard_step
    END,
    updated_at = now()
  WHERE id = p_document_id;

  RETURN p_document_id;
END;
$$;

REVOKE ALL ON FUNCTION api.set_commercial_quote_draft_progress(uuid, uuid, boolean, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_commercial_quote_draft_progress(uuid, uuid, boolean, text, text)
  TO authenticated, service_role;
