-- CF-11: register commercial document "sent" events (idempotent via client_op_id).
-- Send failures must not re-issue documents; only append an audit event when share succeeds.

CREATE OR REPLACE FUNCTION api.record_commercial_document_sent(
  p_document_id uuid,
  p_channel text,
  p_client_op_id uuid,
  p_device text DEFAULT NULL,
  p_payload jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_event_id uuid;
  v_channel text := nullif(trim(coalesce(p_channel, '')), '');
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF v_channel IS NULL THEN
    RAISE EXCEPTION 'channel_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT id INTO v_event_id
  FROM data.commercial_document_events
  WHERE tenant_id = v_doc.tenant_id AND client_op_id = p_client_op_id;
  IF v_event_id IS NOT NULL THEN
    RETURN v_event_id;
  END IF;

  IF v_doc.status = 'draft' THEN
    RAISE EXCEPTION 'document_not_sent_state:%', v_doc.status USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, channel, device,
    content_hash, client_op_id, payload
  ) VALUES (
    v_doc.tenant_id, p_document_id, 'sent', v_uid, v_channel, p_device,
    v_doc.content_hash, p_client_op_id,
    coalesce(p_payload, '{}'::jsonb) || jsonb_build_object('doc_number', v_doc.doc_number)
  )
  RETURNING id INTO v_event_id;

  RETURN v_event_id;
END;
$$;

REVOKE ALL ON FUNCTION api.record_commercial_document_sent(uuid, text, uuid, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.record_commercial_document_sent(uuid, text, uuid, text, jsonb)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.record_commercial_document_sent(uuid, text, uuid, text, jsonb) IS
  'CF-11: append sent event for an issued commercial document; idempotent by client_op_id.';
