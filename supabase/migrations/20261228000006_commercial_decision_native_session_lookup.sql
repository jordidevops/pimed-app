-- CF-28 F4: service-role lookup of native session linked to a commercial decision token.

CREATE OR REPLACE FUNCTION api.lookup_commercial_decision_native_session(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_hash text;
  v_token data.commercial_decision_access_tokens%ROWTYPE;
  v_req data.commercial_decision_requests%ROWTYPE;
  v_intent data.commercial_signing_intents%ROWTYPE;
  v_session data.document_signing_sessions%ROWTYPE;
BEGIN
  IF p_token IS NULL OR length(btrim(p_token)) < 32 THEN
    RETURN jsonb_build_object('error', 'token_invalid');
  END IF;

  v_hash := encode(extensions.digest(convert_to(btrim(p_token), 'UTF8'), 'sha256'), 'hex');

  SELECT * INTO v_token
  FROM data.commercial_decision_access_tokens t
  WHERE t.token_hash = v_hash
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'token_not_found');
  END IF;
  IF v_token.status <> 'active' THEN
    RETURN jsonb_build_object('error', 'token_not_active', 'status', v_token.status);
  END IF;
  IF v_token.expires_at <= now() THEN
    RETURN jsonb_build_object('error', 'token_expired');
  END IF;

  SELECT * INTO v_req
  FROM data.commercial_decision_requests r
  WHERE r.id = v_token.request_id;
  IF NOT FOUND OR v_req.status <> 'open' THEN
    RETURN jsonb_build_object(
      'error', 'request_not_open',
      'status', COALESCE(v_req.status, 'missing')
    );
  END IF;
  IF v_req.expires_at <= now() THEN
    RETURN jsonb_build_object('error', 'request_expired');
  END IF;

  SELECT * INTO v_intent
  FROM data.commercial_signing_intents i
  WHERE i.decision_request_id = v_req.id
    AND i.session_id IS NOT NULL
  ORDER BY i.created_at DESC
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'native_session_missing');
  END IF;

  SELECT * INTO v_session
  FROM data.document_signing_sessions s
  WHERE s.id = v_intent.session_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'native_session_missing');
  END IF;

  RETURN jsonb_build_object(
    'request_id', v_req.id,
    'token_id', v_token.id,
    'delivery_id', v_token.delivery_id,
    'session_id', v_session.id,
    'signing_token', v_session.signing_token,
    'session_status', v_session.status,
    'tenant_id', v_req.tenant_id,
    'document_version_id', v_req.document_version_id,
    'content_hash', v_req.content_hash
  );
END;
$$;

REVOKE ALL ON FUNCTION api.lookup_commercial_decision_native_session(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.lookup_commercial_decision_native_session(text)
  TO service_role;

NOTIFY pgrst, 'reload schema';
