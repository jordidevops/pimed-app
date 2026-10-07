-- CF-28 F8 tall 1: DocuSeal ↔ commercial decision bridge (no tenant URL exposure).
-- Prerequisites: CS-D58–D60 (20261229000001+), commercial decision domain.

CREATE INDEX IF NOT EXISTS idx_signing_submissions_commercial_decision
  ON data.signing_submissions ((metadata->>'decision_request_id'))
  WHERE metadata ? 'decision_request_id';

-- ---------------------------------------------------------------------------
-- Bind submission → open request (sets active_provider=docuseal)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.bind_commercial_decision_docuseal_submission(
  p_request_id uuid,
  p_submission_id uuid,
  p_client_op_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_req data.commercial_decision_requests%ROWTYPE;
  v_sub data.signing_submissions%ROWTYPE;
  v_op uuid := COALESCE(p_client_op_id, gen_random_uuid());
BEGIN
  IF p_request_id IS NULL OR p_submission_id IS NULL THEN
    RAISE EXCEPTION 'invalid_bind_args' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_req
  FROM data.commercial_decision_requests
  WHERE id = p_request_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'decision_request_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_uid IS NOT NULL AND NOT (data.jwt_user_tenants() ? v_req.tenant_id::text) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;
  -- service_role (auth.uid null) allowed for Edge bind after DocuSeal create

  IF v_req.status <> 'open' THEN
    RAISE EXCEPTION 'decision_request_not_open' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_sub
  FROM data.signing_submissions
  WHERE id = p_submission_id
  FOR UPDATE;
  IF NOT FOUND OR v_sub.tenant_id IS DISTINCT FROM v_req.tenant_id THEN
    RAISE EXCEPTION 'submission_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  UPDATE data.signing_submissions
  SET metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
        'decision_request_id', v_req.id::text,
        'commercial_bridge', true
      ),
      updated_at = now()
  WHERE id = v_sub.id;

  UPDATE data.commercial_decision_requests
  SET active_provider = 'docuseal',
      updated_at = now()
  WHERE id = v_req.id;

  INSERT INTO data.commercial_decision_events (
    tenant_id, request_id, event_type, via, actor_id, content_hash, client_op_id, evidence
  ) VALUES (
    v_req.tenant_id, v_req.id, 'provider_bound', 'office', v_uid, v_req.content_hash, v_op,
    jsonb_build_object(
      'provider', 'docuseal',
      'submission_id', v_sub.id,
      'external_id', v_sub.external_id
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'request_id', v_req.id,
    'submission_id', v_sub.id,
    'active_provider', 'docuseal'
  );
END;
$$;

REVOKE ALL ON FUNCTION api.bind_commercial_decision_docuseal_submission(uuid, uuid, uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.bind_commercial_decision_docuseal_submission(uuid, uuid, uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Apply commercial decision from DocuSeal submission (webhook)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.apply_commercial_decision_from_docuseal_submission(
  p_submission_id uuid,
  p_outcome text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sub data.signing_submissions%ROWTYPE;
  v_request_id uuid;
  v_req data.commercial_decision_requests%ROWTYPE;
  v_evidence jsonb;
  v_op uuid;
  v_result jsonb;
BEGIN
  IF p_outcome NOT IN ('accepted', 'declined') THEN
    RAISE EXCEPTION 'invalid_decision_outcome' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_sub
  FROM data.signing_submissions
  WHERE id = p_submission_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'code', 'submission_not_found');
  END IF;

  IF NOT COALESCE((v_sub.metadata->>'commercial_bridge')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'code', 'not_commercial_bridge');
  END IF;

  BEGIN
    v_request_id := NULLIF(btrim(COALESCE(v_sub.metadata->>'decision_request_id', '')), '')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid_decision_request_id');
  END;

  IF v_request_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'code', 'missing_decision_request_id');
  END IF;

  SELECT * INTO v_req
  FROM data.commercial_decision_requests
  WHERE id = v_request_id;
  IF NOT FOUND OR v_req.tenant_id IS DISTINCT FROM v_sub.tenant_id THEN
    RETURN jsonb_build_object('ok', false, 'code', 'decision_request_not_found');
  END IF;

  -- Stable idempotency key per submission+outcome (webhook retries)
  v_op := (
    SELECT uuid_in(
      overlay(
        overlay(md5('commercial-docuseal:' || p_submission_id::text || ':' || p_outcome)
          placing '4' from 13)
        placing '8' from 17)::cstring
    )
  );

  v_evidence := jsonb_strip_nulls(jsonb_build_object(
    'method', 'docuseal',
    'provider', 'docuseal',
    'provider_submission_id', v_sub.id,
    'docuseal_submission_id', v_sub.docuseal_submission_id,
    'signer_name', v_sub.signers->0->>'name',
    'signer_email', v_sub.signers->0->>'email',
    'result_document_version_id', v_sub.result_document_version_id
  ));

  v_result := data.apply_commercial_decision_request(
    v_request_id,
    p_outcome,
    'provider',
    v_evidence,
    v_op,
    NULL
  );

  RETURN jsonb_build_object(
    'ok', true,
    'request_id', v_request_id,
    'result', v_result
  );
END;
$$;

REVOKE ALL ON FUNCTION data.apply_commercial_decision_from_docuseal_submission(uuid, text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.apply_commercial_decision_from_docuseal_submission(uuid, text)
  TO service_role;

CREATE OR REPLACE FUNCTION api.apply_commercial_decision_from_docuseal_submission(
  p_submission_id uuid,
  p_outcome text
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT data.apply_commercial_decision_from_docuseal_submission(p_submission_id, p_outcome);
$$;

REVOKE ALL ON FUNCTION api.apply_commercial_decision_from_docuseal_submission(uuid, text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.apply_commercial_decision_from_docuseal_submission(uuid, text)
  TO service_role;

-- ---------------------------------------------------------------------------
-- Recipient continue URL (token bearer only — CS-D58)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.resolve_commercial_docuseal_continue(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_hash text;
  v_token data.commercial_decision_access_tokens%ROWTYPE;
  v_req data.commercial_decision_requests%ROWTYPE;
  v_url text;
BEGIN
  IF p_token IS NULL OR length(btrim(p_token)) < 32 THEN
    RETURN jsonb_build_object('ok', false, 'code', 'not_found');
  END IF;

  v_hash := encode(extensions.digest(convert_to(btrim(p_token), 'UTF8'), 'sha256'), 'hex');

  SELECT * INTO v_token
  FROM data.commercial_decision_access_tokens t
  WHERE t.token_hash = v_hash
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'code', 'not_found');
  END IF;

  SELECT * INTO v_req
  FROM data.commercial_decision_requests r
  WHERE r.id = v_token.request_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'code', 'not_found');
  END IF;

  IF v_token.status <> 'active'
     OR v_token.expires_at <= now()
     OR v_req.status <> 'open'
     OR v_req.expires_at <= now()
  THEN
    RETURN jsonb_build_object('ok', false, 'code', 'not_open');
  END IF;

  IF COALESCE(v_req.active_provider, '') IS DISTINCT FROM 'docuseal' THEN
    RETURN jsonb_build_object('ok', false, 'code', 'provider_not_docuseal');
  END IF;

  SELECT NULLIF(btrim(ss.docuseal_signing_url), '')
    INTO v_url
  FROM data.signing_submissions ss
  WHERE ss.tenant_id = v_req.tenant_id
    AND ss.metadata->>'decision_request_id' = v_req.id::text
    AND COALESCE((ss.metadata->>'commercial_bridge')::boolean, false)
    AND ss.status IN ('pending', 'in_progress', 'opened', 'viewed')
  ORDER BY ss.created_at DESC
  LIMIT 1;

  IF v_url IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'code', 'provider_pending');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'request_id', v_req.id,
    'redirect_url', v_url
  );
END;
$$;

REVOKE ALL ON FUNCTION api.resolve_commercial_docuseal_continue(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.resolve_commercial_docuseal_continue(text)
  TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Resolve token: provider_continue_available (no URL)
-- ---------------------------------------------------------------------------
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
  v_provider_continue boolean := false;
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

  v_provider_continue := (
    v_effective_status = 'open'
    AND v_token.status = 'active'
    AND COALESCE(v_req.active_provider, '') = 'docuseal'
    AND EXISTS (
      SELECT 1
      FROM data.signing_submissions ss
      WHERE ss.tenant_id = v_req.tenant_id
        AND ss.metadata->>'decision_request_id' = v_req.id::text
        AND COALESCE((ss.metadata->>'commercial_bridge')::boolean, false)
        AND ss.status IN ('pending', 'in_progress', 'opened', 'viewed')
        AND NULLIF(btrim(ss.docuseal_signing_url), '') IS NOT NULL
    )
  );

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
    'provider_continue_available', v_provider_continue,
    'receipt', v_receipt
  );
END;
$$;

NOTIFY pgrst, 'reload schema';
