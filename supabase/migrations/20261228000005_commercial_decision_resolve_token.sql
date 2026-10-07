-- CF-28 F4: public resolve + apply-by-token for commercial decision access tokens.

CREATE OR REPLACE FUNCTION api.resolve_commercial_decision_token(
  p_token text,
  p_mark_opened boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_hash text;
  v_token data.commercial_decision_access_tokens%ROWTYPE;
  v_req data.commercial_decision_requests%ROWTYPE;
  v_tenant_name text;
  v_tenant_logo text;
  v_effective_status text;
  v_public_snapshot jsonb;
BEGIN
  IF p_token IS NULL OR length(btrim(p_token)) < 32 THEN
    RETURN jsonb_build_object('kind', 'not_found');
  END IF;

  v_hash := encode(extensions.digest(convert_to(btrim(p_token), 'UTF8'), 'sha256'), 'hex');

  SELECT * INTO v_token
  FROM data.commercial_decision_access_tokens t
  WHERE t.token_hash = v_hash
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('kind', 'not_found');
  END IF;

  SELECT * INTO v_req
  FROM data.commercial_decision_requests r
  WHERE r.id = v_token.request_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('kind', 'not_found');
  END IF;

  SELECT t.name,
         NULLIF(btrim(COALESCE(t.settings->'branding'->>'logo_url', t.settings->>'logo_url')), '')
    INTO v_tenant_name, v_tenant_logo
  FROM data.tenants t
  WHERE t.id = v_req.tenant_id;

  v_effective_status := v_req.status;
  IF v_token.status = 'revoked' THEN
    v_effective_status := 'revoked';
  ELSIF v_token.status = 'expired'
     OR v_token.expires_at <= now()
     OR v_req.expires_at <= now()
  THEN
    IF v_req.status = 'open' THEN
      UPDATE data.commercial_decision_requests
      SET status = 'expired', updated_at = now()
      WHERE id = v_req.id AND status = 'open';
    END IF;
    IF v_token.status = 'active' THEN
      UPDATE data.commercial_decision_access_tokens
      SET status = 'expired'
      WHERE id = v_token.id AND status = 'active';
    END IF;
    v_effective_status := 'expired';
  ELSIF v_token.status = 'consumed' AND v_req.status = 'open' THEN
    v_effective_status := v_req.status;
  END IF;

  IF p_mark_opened
     AND v_token.status = 'active'
     AND v_effective_status = 'open'
  THEN
    IF v_token.opened_at IS NULL THEN
      UPDATE data.commercial_decision_access_tokens
      SET opened_at = now(),
          last_opened_at = now()
      WHERE id = v_token.id;

      INSERT INTO data.commercial_decision_events (
        tenant_id, request_id, event_type, via, content_hash, evidence
      ) VALUES (
        v_req.tenant_id, v_req.id, 'link_opened', 'link', v_req.content_hash,
        jsonb_build_object('token_id', v_token.id, 'delivery_id', v_token.delivery_id)
      );
    ELSE
      UPDATE data.commercial_decision_access_tokens
      SET last_opened_at = now()
      WHERE id = v_token.id;
    END IF;
  END IF;

  -- Public allowlist from immutable snapshot (never expand with live commercial rows).
  v_public_snapshot := jsonb_strip_nulls(jsonb_build_object(
    'kind', v_req.snapshot_json->>'kind',
    'doc_type', v_req.snapshot_json->>'doc_type',
    'doc_number', v_req.snapshot_json->>'doc_number',
    'formalization_mode', v_req.snapshot_json->>'formalization_mode',
    'total', v_req.snapshot_json->'total',
    'currency', v_req.snapshot_json->>'currency',
    'locale', v_req.snapshot_json->>'locale',
    'valid_until', v_req.snapshot_json->>'valid_until',
    'show_prices', v_req.snapshot_json->'show_prices',
    'version_no', v_req.snapshot_json->'version_no',
    'agreement_id', v_req.snapshot_json->>'agreement_id',
    'purpose', v_req.purpose
  ));

  RETURN jsonb_build_object(
    'kind', 'commercial_decision',
    'request_status', v_effective_status,
    'purpose', v_req.purpose,
    'expires_at', LEAST(v_req.expires_at, v_token.expires_at),
    'decided_at', v_req.decided_at,
    'decided_via', v_req.decided_via,
    'active_provider', v_req.active_provider,
    'content_hash', v_req.content_hash,
    'document_version_id', v_req.document_version_id,
    'snapshot', v_public_snapshot,
    'tenant', jsonb_strip_nulls(jsonb_build_object(
      'name', v_tenant_name,
      'logo_url', v_tenant_logo
    )),
    'can_decide', (v_effective_status = 'open' AND v_token.status = 'active')
  );
END;
$$;

REVOKE ALL ON FUNCTION api.resolve_commercial_decision_token(text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.resolve_commercial_decision_token(text, boolean)
  TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION api.apply_commercial_decision_by_token(
  p_token text,
  p_outcome text,
  p_evidence jsonb,
  p_client_op_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_hash text;
  v_token data.commercial_decision_access_tokens%ROWTYPE;
  v_req data.commercial_decision_requests%ROWTYPE;
  v_result jsonb;
  v_evidence jsonb := COALESCE(p_evidence, '{}'::jsonb);
BEGIN
  IF p_token IS NULL OR length(btrim(p_token)) < 32 THEN
    RAISE EXCEPTION 'token_invalid' USING ERRCODE = 'P0001';
  END IF;
  IF p_outcome NOT IN ('accepted', 'declined') THEN
    RAISE EXCEPTION 'invalid_outcome' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;

  v_hash := encode(extensions.digest(convert_to(btrim(p_token), 'UTF8'), 'sha256'), 'hex');

  SELECT * INTO v_token
  FROM data.commercial_decision_access_tokens t
  WHERE t.token_hash = v_hash
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'token_not_found' USING ERRCODE = 'P0001';
  END IF;
  IF v_token.status <> 'active' THEN
    RAISE EXCEPTION 'token_not_active:%', v_token.status USING ERRCODE = 'P0001';
  END IF;
  IF v_token.expires_at <= now() THEN
    UPDATE data.commercial_decision_access_tokens
    SET status = 'expired' WHERE id = v_token.id;
    RAISE EXCEPTION 'token_expired' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_req
  FROM data.commercial_decision_requests r
  WHERE r.id = v_token.request_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'decision_request_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_req.expires_at <= now() AND v_req.status = 'open' THEN
    UPDATE data.commercial_decision_requests
    SET status = 'expired', updated_at = now()
    WHERE id = v_req.id;
    RAISE EXCEPTION 'decision_request_expired' USING ERRCODE = 'P0001';
  END IF;

  v_evidence := v_evidence || jsonb_build_object(
    'token_id', v_token.id,
    'delivery_id', v_token.delivery_id
  );

  v_result := data.apply_commercial_decision_request(
    v_req.id,
    p_outcome,
    'link',
    v_evidence,
    p_client_op_id,
    NULL
  );

  UPDATE data.commercial_decision_access_tokens
  SET status = 'consumed'
  WHERE id = v_token.id AND status = 'active';

  UPDATE data.commercial_decision_access_tokens
  SET status = 'revoked', revoked_at = now()
  WHERE request_id = v_req.id
    AND id <> v_token.id
    AND status = 'active';

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION api.apply_commercial_decision_by_token(text, text, jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.apply_commercial_decision_by_token(text, text, jsonb, uuid)
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
