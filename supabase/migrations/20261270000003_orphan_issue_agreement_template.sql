-- Persist preferred agreement template on orphan issue (for prepare_agreement_from_quote later).

DROP FUNCTION IF EXISTS api.issue_orphan_commercial_document(uuid, uuid, boolean, text, uuid);

CREATE OR REPLACE FUNCTION api.issue_orphan_commercial_document(
  p_document_id uuid,
  p_client_op_id uuid DEFAULT NULL,
  p_show_prices boolean DEFAULT NULL,
  p_formalization_mode text DEFAULT NULL,
  p_full_body_template_id uuid DEFAULT NULL,
  p_agreement_template_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_number text;
  v_hash text;
  v_mode text;
  v_line_count int;
  v_payload jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id FOR UPDATE;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.doc_type <> 'quote' OR v_doc.project_id IS NOT NULL THEN
    RAISE EXCEPTION 'not_orphan_quote' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.status = 'issued' THEN
    RETURN v_doc.id;
  END IF;
  IF v_doc.status <> 'draft' THEN
    RAISE EXCEPTION 'document_not_issuable_state:%', v_doc.status USING ERRCODE = 'P0001';
  END IF;
  IF NOT data.can_edit_commercial_pricing(v_doc.tenant_id, NULL) THEN
    RAISE EXCEPTION 'permission_denied:commercial.pricing.edit' USING ERRCODE = 'P0001';
  END IF;

  SELECT count(*) INTO v_line_count
  FROM data.commercial_document_lines WHERE document_id = p_document_id;
  IF v_line_count < 1 THEN
    RAISE EXCEPTION 'orphan_quote_requires_lines' USING ERRCODE = 'P0001';
  END IF;

  PERFORM data.recompute_orphan_quote_totals(p_document_id);
  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;

  IF p_formalization_mode IN ('signed_quote', 'separate_agreement') THEN
    v_mode := p_formalization_mode;
  ELSE
    v_mode := COALESCE(v_doc.formalization_mode, data.resolve_quote_formalization_mode(v_doc.tenant_id));
  END IF;

  IF p_full_body_template_id IS NOT NULL THEN
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

  IF p_agreement_template_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.document_templates t
      WHERE t.id = p_agreement_template_id
        AND t.is_active AND t.template_type = 'html'
        AND lower(COALESCE(t.category, '')) = 'commercial_agreement'
        AND (t.tenant_id = v_doc.tenant_id OR (t.tenant_id IS NULL AND t.is_platform_default))
    ) THEN
      RAISE EXCEPTION 'agreement_template_invalid' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  v_number := data.allocate_commercial_document_number(
    v_doc.tenant_id, 'quote', EXTRACT(YEAR FROM now())::int
  );
  v_hash := encode(
    extensions.digest(
      convert_to(
        v_number || '|quote|' || v_doc.subtotal::text || '|' || v_doc.total::text
        || '|' || COALESCE(v_doc.buyer_snapshot::text, '') || '|' || COALESCE(v_doc.seller_snapshot->>'name', ''),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  UPDATE data.commercial_documents
  SET doc_number = v_number,
      status = 'issued',
      content_hash = v_hash,
      issued_at = now(),
      issued_by = v_uid,
      valid_until = now() + interval '30 days',
      show_prices = COALESCE(p_show_prices, show_prices, true),
      formalization_mode = v_mode,
      full_body_template_id = COALESCE(p_full_body_template_id, full_body_template_id),
      client_op_id = COALESCE(p_client_op_id, client_op_id),
      updated_at = now()
  WHERE id = p_document_id;

  v_payload := jsonb_build_object(
    'doc_type', 'quote',
    'doc_number', v_number,
    'total', v_doc.total,
    'orphan', true
  );
  IF p_agreement_template_id IS NOT NULL THEN
    v_payload := v_payload || jsonb_build_object('agreement_template_id', p_agreement_template_id);
  END IF;

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, content_hash, client_op_id, payload
  ) VALUES (
    v_doc.tenant_id, p_document_id, 'issued', v_uid, v_hash,
    COALESCE(p_client_op_id, extensions.gen_random_uuid()),
    v_payload
  );

  RETURN p_document_id;
END;
$$;

REVOKE ALL ON FUNCTION api.issue_orphan_commercial_document(uuid, uuid, boolean, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.issue_orphan_commercial_document(uuid, uuid, boolean, text, uuid, uuid)
  TO authenticated, service_role;
