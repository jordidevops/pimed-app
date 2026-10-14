-- CS-D8 strangler: allow register_commercial_signing_intent on an accepted quote
-- when a pending/draft agreement version exists (decision-requests may be off).

CREATE OR REPLACE FUNCTION api.register_commercial_signing_intent(
  p_document_id uuid,
  p_session_id uuid,
  p_action text,
  p_client_op_id uuid,
  p_submission_id uuid DEFAULT NULL,
  p_decision_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_id uuid;
  v_req data.commercial_decision_requests%ROWTYPE;
  v_source_quote uuid;
  v_has_pending_agreement boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL OR p_session_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_action NOT IN ('accept', 'reject', 'delivery') THEN
    RAISE EXCEPTION 'invalid_commercial_signing_action' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF p_action = 'delivery' AND v_doc.doc_type <> 'delivery_note' THEN
    RAISE EXCEPTION 'document_not_delivery_note' USING ERRCODE = 'P0001';
  END IF;
  IF p_action IN ('accept', 'reject') AND v_doc.doc_type NOT IN ('quote', 'quote_amendment') THEN
    RAISE EXCEPTION 'document_not_quote' USING ERRCODE = 'P0001';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM data.commercial_agreement_versions v
    WHERE v.source_quote_id = v_doc.id
      AND v.tenant_id = v_doc.tenant_id
      AND v.status IN ('draft', 'pending_signature')
  ) INTO v_has_pending_agreement;

  IF p_decision_request_id IS NOT NULL THEN
    SELECT * INTO v_req
    FROM data.commercial_decision_requests
    WHERE id = p_decision_request_id;
    IF NOT FOUND
       OR v_req.tenant_id IS DISTINCT FROM v_doc.tenant_id
       OR v_req.status <> 'open'
    THEN
      RAISE EXCEPTION 'decision_request_invalid' USING ERRCODE = 'P0001';
    END IF;
    IF v_req.commercial_document_id IS NOT NULL
       AND v_req.commercial_document_id IS DISTINCT FROM p_document_id THEN
      RAISE EXCEPTION 'decision_request_invalid' USING ERRCODE = 'P0001';
    END IF;
    IF v_req.agreement_version_id IS NOT NULL THEN
      SELECT v.source_quote_id INTO v_source_quote
      FROM data.commercial_agreement_versions v
      WHERE v.id = v_req.agreement_version_id;
      IF v_source_quote IS DISTINCT FROM p_document_id THEN
        RAISE EXCEPTION 'decision_request_invalid' USING ERRCODE = 'P0001';
      END IF;
      -- CS-D8: agreement send requires quote already accepted
      IF v_doc.status IS DISTINCT FROM 'accepted' THEN
        RAISE EXCEPTION 'document_not_issuable_state:%', v_doc.status USING ERRCODE = 'P0001';
      END IF;
    ELSIF v_doc.status <> 'issued' THEN
      RAISE EXCEPTION 'document_not_issuable_state:%', v_doc.status USING ERRCODE = 'P0001';
    END IF;
  ELSIF v_doc.status = 'accepted' AND v_has_pending_agreement AND p_action = 'accept' THEN
    -- Strangler presential agreement send after office accept (no decision request).
    NULL;
  ELSIF v_doc.status <> 'issued' THEN
    RAISE EXCEPTION 'document_not_issuable_state:%', v_doc.status USING ERRCODE = 'P0001';
  END IF;

  IF p_action = 'accept' THEN
    PERFORM data.commercial_accept_office_gate(p_document_id);
  END IF;

  SELECT id INTO v_id
  FROM data.commercial_signing_intents
  WHERE tenant_id = v_doc.tenant_id AND client_op_id = p_client_op_id;
  IF v_id IS NOT NULL THEN
    IF p_decision_request_id IS NOT NULL THEN
      UPDATE data.commercial_signing_intents
      SET decision_request_id = COALESCE(decision_request_id, p_decision_request_id)
      WHERE id = v_id AND decision_request_id IS NULL;
      UPDATE data.commercial_decision_requests
      SET active_provider = 'native', updated_at = now()
      WHERE id = p_decision_request_id
        AND COALESCE(active_provider, 'native') = 'native';
    END IF;
    RETURN v_id;
  END IF;

  SELECT id INTO v_id
  FROM data.commercial_signing_intents
  WHERE session_id = p_session_id;
  IF v_id IS NOT NULL THEN
    IF p_decision_request_id IS NOT NULL THEN
      UPDATE data.commercial_signing_intents
      SET decision_request_id = COALESCE(decision_request_id, p_decision_request_id)
      WHERE id = v_id AND decision_request_id IS NULL;
      UPDATE data.commercial_decision_requests
      SET active_provider = 'native', updated_at = now()
      WHERE id = p_decision_request_id
        AND COALESCE(active_provider, 'native') = 'native';
    END IF;
    RETURN v_id;
  END IF;

  INSERT INTO data.commercial_signing_intents (
    tenant_id, document_id, submission_id, session_id, action, client_op_id,
    created_by, decision_request_id
  ) VALUES (
    v_doc.tenant_id, p_document_id, p_submission_id, p_session_id, p_action, p_client_op_id,
    v_uid, p_decision_request_id
  )
  RETURNING id INTO v_id;

  IF p_decision_request_id IS NOT NULL THEN
    UPDATE data.commercial_decision_requests
    SET active_provider = 'native', updated_at = now()
    WHERE id = p_decision_request_id
      AND COALESCE(active_provider, 'native') = 'native';
  END IF;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION api.register_commercial_signing_intent(uuid, uuid, text, uuid, uuid, uuid) IS
  'Registers signing intent. Quote path needs issued; agreement path needs accepted quote (CS-D8).';

REVOKE ALL ON FUNCTION api.register_commercial_signing_intent(uuid, uuid, text, uuid, uuid, uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.register_commercial_signing_intent(uuid, uuid, text, uuid, uuid, uuid)
  TO authenticated, service_role;
