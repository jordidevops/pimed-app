-- CF-28 F3: link signing intents to decision requests; list open request helper.

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
  IF v_doc.status <> 'issued' THEN
    RAISE EXCEPTION 'document_not_issuable_state:%', v_doc.status USING ERRCODE = 'P0001';
  END IF;
  IF p_action = 'delivery' AND v_doc.doc_type <> 'delivery_note' THEN
    RAISE EXCEPTION 'document_not_delivery_note' USING ERRCODE = 'P0001';
  END IF;
  IF p_action IN ('accept', 'reject') AND v_doc.doc_type NOT IN ('quote', 'quote_amendment') THEN
    RAISE EXCEPTION 'document_not_quote' USING ERRCODE = 'P0001';
  END IF;
  IF p_action = 'accept' THEN
    PERFORM data.commercial_accept_office_gate(p_document_id);
  END IF;

  IF p_decision_request_id IS NOT NULL THEN
    SELECT * INTO v_req
    FROM data.commercial_decision_requests
    WHERE id = p_decision_request_id;
    IF NOT FOUND
       OR v_req.tenant_id IS DISTINCT FROM v_doc.tenant_id
       OR v_req.commercial_document_id IS DISTINCT FROM p_document_id
       OR v_req.status <> 'open'
    THEN
      RAISE EXCEPTION 'decision_request_invalid' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  SELECT id INTO v_id
  FROM data.commercial_signing_intents
  WHERE tenant_id = v_doc.tenant_id AND client_op_id = p_client_op_id;
  IF v_id IS NOT NULL THEN
    IF p_decision_request_id IS NOT NULL THEN
      UPDATE data.commercial_signing_intents
      SET decision_request_id = COALESCE(decision_request_id, p_decision_request_id)
      WHERE id = v_id AND decision_request_id IS NULL;
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
    WHERE id = p_decision_request_id AND active_provider IS NULL;
  END IF;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.register_commercial_signing_intent(uuid, uuid, text, uuid, uuid, uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.register_commercial_signing_intent(uuid, uuid, text, uuid, uuid, uuid)
  TO authenticated, service_role;

-- Keep old 5-arg overload callable (defaults decision_request_id)
CREATE OR REPLACE FUNCTION api.register_commercial_signing_intent(
  p_document_id uuid,
  p_session_id uuid,
  p_action text,
  p_client_op_id uuid,
  p_submission_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  RETURN api.register_commercial_signing_intent(
    p_document_id, p_session_id, p_action, p_client_op_id, p_submission_id, NULL
  );
END;
$$;

REVOKE ALL ON FUNCTION api.register_commercial_signing_intent(uuid, uuid, text, uuid, uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.register_commercial_signing_intent(uuid, uuid, text, uuid, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.get_open_commercial_decision_request(p_target_document_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_req data.commercial_decision_requests%ROWTYPE;
  v_delivery data.commercial_decision_deliveries%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_req
  FROM data.commercial_decision_requests r
  WHERE r.commercial_document_id = p_target_document_id
    AND r.status = 'open'
    AND data.jwt_user_tenants() ? r.tenant_id::text
  ORDER BY r.created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_delivery
  FROM data.commercial_decision_deliveries d
  WHERE d.request_id = v_req.id
  ORDER BY d.created_at DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'id', v_req.id,
    'status', v_req.status,
    'purpose', v_req.purpose,
    'expires_at', v_req.expires_at,
    'active_provider', v_req.active_provider,
    'decided_at', v_req.decided_at,
    'decided_via', v_req.decided_via,
    'latest_delivery', CASE WHEN v_delivery.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id', v_delivery.id,
      'channel', v_delivery.channel,
      'status', v_delivery.status,
      'recipient_masked', v_delivery.recipient_masked,
      'created_at', v_delivery.created_at,
      'error_code', v_delivery.error_code
    ) END
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_open_commercial_decision_request(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_open_commercial_decision_request(uuid)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
