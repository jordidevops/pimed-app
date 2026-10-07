-- CF-28 F4: public receipt (justificant) for decided commercial decision requests.

CREATE OR REPLACE FUNCTION api.get_commercial_decision_receipt(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_hash text;
  v_token data.commercial_decision_access_tokens%ROWTYPE;
  v_req data.commercial_decision_requests%ROWTYPE;
  v_event data.commercial_decision_events%ROWTYPE;
  v_tenant_name text;
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

  IF v_req.status NOT IN ('accepted', 'declined') THEN
    RETURN jsonb_build_object(
      'kind', 'not_ready',
      'request_status', v_req.status
    );
  END IF;

  SELECT * INTO v_event
  FROM data.commercial_decision_events e
  WHERE e.request_id = v_req.id
    AND e.event_type = 'decided'
  ORDER BY e.created_at DESC
  LIMIT 1;

  SELECT t.name INTO v_tenant_name
  FROM data.tenants t
  WHERE t.id = v_req.tenant_id;

  v_public_snapshot := jsonb_strip_nulls(jsonb_build_object(
    'kind', v_req.snapshot_json->>'kind',
    'doc_type', v_req.snapshot_json->>'doc_type',
    'doc_number', v_req.snapshot_json->>'doc_number',
    'formalization_mode', v_req.snapshot_json->>'formalization_mode',
    'total', v_req.snapshot_json->'total',
    'currency', v_req.snapshot_json->>'currency',
    'locale', v_req.snapshot_json->>'locale',
    'version_no', v_req.snapshot_json->'version_no'
  ));

  RETURN jsonb_build_object(
    'kind', 'commercial_decision_receipt',
    'outcome', v_req.status,
    'decided_at', v_req.decided_at,
    'decided_via', v_req.decided_via,
    'provider', COALESCE(v_req.active_provider, v_event.provider, 'native'),
    'content_hash', v_req.content_hash,
    'document_version_id', v_req.document_version_id,
    'trace_id', left(replace(v_req.id::text, '-', ''), 12),
    'signer_name', v_event.signer_name,
    'reason', v_event.reason,
    'snapshot', v_public_snapshot,
    'tenant', jsonb_build_object('name', v_tenant_name),
    'purpose', v_req.purpose
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_commercial_decision_receipt(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_commercial_decision_receipt(text)
  TO anon, authenticated, service_role;

-- Enrich resolve with receipt summary when already decided (no IP/UA).
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
  v_event data.commercial_decision_events%ROWTYPE;
  v_tenant_name text;
  v_tenant_logo text;
  v_effective_status text;
  v_public_snapshot jsonb;
  v_receipt jsonb;
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
  IF v_token.status = 'revoked' AND v_req.status = 'open' THEN
    v_effective_status := 'revoked';
  ELSIF v_token.status = 'expired'
     OR (v_req.status = 'open' AND (v_token.expires_at <= now() OR v_req.expires_at <= now()))
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
    v_effective_status := CASE
      WHEN v_req.status IN ('accepted', 'declined') THEN v_req.status
      ELSE 'expired'
    END;
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

  v_receipt := NULL;
  IF v_effective_status IN ('accepted', 'declined') THEN
    SELECT * INTO v_event
    FROM data.commercial_decision_events e
    WHERE e.request_id = v_req.id
      AND e.event_type = 'decided'
    ORDER BY e.created_at DESC
    LIMIT 1;

    v_receipt := jsonb_strip_nulls(jsonb_build_object(
      'outcome', v_effective_status,
      'decided_at', v_req.decided_at,
      'decided_via', v_req.decided_via,
      'provider', COALESCE(v_req.active_provider, v_event.provider, 'native'),
      'signer_name', v_event.signer_name,
      'reason', v_event.reason,
      'trace_id', left(replace(v_req.id::text, '-', ''), 12),
      'content_hash', v_req.content_hash
    ));
  END IF;

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
    'can_decide', (v_effective_status = 'open' AND v_token.status = 'active'),
    'receipt', v_receipt
  );
END;
$$;

NOTIFY pgrst, 'reload schema';
