-- CF-28 / F7 tall 2: portal decline + get decide flags / receipt / PDF handles.

-- ---------------------------------------------------------------------------
-- get: open (decide flags + PDF handles) or decided receipt
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.get_customer_portal_pending_decision(
  p_tenant_id uuid,
  p_client_account_contact_id uuid,
  p_request_id uuid,
  p_quotes_enabled boolean,
  p_dn_enabled boolean
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_req data.commercial_decision_requests%ROWTYPE;
  v_tenant_name text;
  v_tenant_logo text;
  v_card jsonb;
  v_snap jsonb;
  v_pdf record;
  v_event data.commercial_decision_events%ROWTYPE;
  v_decide_available boolean := false;
  v_account_name text;
BEGIN
  IF p_tenant_id IS NULL
     OR p_client_account_contact_id IS NULL
     OR p_request_id IS NULL
  THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_req
  FROM data.commercial_decision_requests r
  WHERE r.id = p_request_id
    AND r.tenant_id = p_tenant_id
    AND r.client_account_contact_id = p_client_account_contact_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF NOT data.commercial_decision_requests_enabled(p_tenant_id) THEN
    RETURN NULL;
  END IF;

  SELECT NULLIF(btrim(t.name), ''),
         NULLIF(btrim(COALESCE(t.settings->'branding'->>'logo_url', t.settings->>'logo_url')), '')
    INTO v_tenant_name, v_tenant_logo
  FROM data.tenants t
  WHERE t.id = p_tenant_id;

  SELECT NULLIF(btrim(COALESCE(c.display_name, c.legal_name, c.email)), '')
    INTO v_account_name
  FROM data.contacts c
  WHERE c.id = p_client_account_contact_id
    AND c.tenant_id = p_tenant_id;

  IF v_req.status IN ('accepted', 'declined') THEN
    SELECT * INTO v_event
    FROM data.commercial_decision_events e
    WHERE e.request_id = v_req.id
      AND e.event_type = 'decided'
    ORDER BY e.created_at DESC
    LIMIT 1;

    v_card := data.customer_portal_pending_decision_card(v_req, v_tenant_name);
    v_snap := jsonb_strip_nulls(jsonb_build_object(
      'kind', v_req.snapshot_json->>'kind',
      'doc_type', v_req.snapshot_json->>'doc_type',
      'doc_number', v_req.snapshot_json->>'doc_number',
      'formalization_mode', v_req.snapshot_json->>'formalization_mode',
      'total', v_card->'total',
      'currency', v_card->>'currency',
      'locale', v_req.snapshot_json->>'locale',
      'valid_until', v_req.snapshot_json->>'valid_until',
      'show_prices', v_card->'show_prices',
      'version_no', v_req.snapshot_json->'version_no',
      'purpose', v_req.purpose
    ));

    RETURN jsonb_strip_nulls(jsonb_build_object(
      'request_id', v_req.id,
      'purpose', v_req.purpose,
      'status', v_req.status,
      'expires_at', v_req.expires_at,
      'created_at', v_req.created_at,
      'decided_at', v_req.decided_at,
      'decided_via', v_req.decided_via,
      'active_provider', v_req.active_provider,
      'content_hash', v_req.content_hash,
      'document_version_id', v_req.document_version_id,
      'has_pdf', (v_req.document_version_id IS NOT NULL),
      'snapshot', v_snap,
      'tenant', jsonb_strip_nulls(jsonb_build_object(
        'name', v_tenant_name,
        'logo_url', v_tenant_logo
      )),
      'account_name', v_account_name,
      'label', v_card->>'label',
      'doc_type', v_card->>'doc_type',
      'total', v_card->'total',
      'currency', v_card->>'currency',
      'show_prices', v_card->'show_prices',
      'can_decide', false,
      'decide_available', false,
      'receipt', jsonb_strip_nulls(jsonb_build_object(
        'outcome', v_req.status,
        'decided_at', v_req.decided_at,
        'decided_via', v_req.decided_via,
        'signer_name', v_event.signer_name,
        'reason', v_event.reason,
        'trace_id', left(replace(v_req.id::text, '-', ''), 12)
      ))
    ));
  END IF;

  IF NOT data.customer_portal_pending_decision_visible(
    p_tenant_id, p_client_account_contact_id, v_req,
    COALESCE(p_quotes_enabled, false),
    COALESCE(p_dn_enabled, false)
  ) THEN
    RETURN NULL;
  END IF;

  -- Decline available now; accept (native pad) arrives in F7 tall 3.
  -- DocuSeal stays link/provider-only until F8.
  v_decide_available := (
    COALESCE(v_req.active_provider, 'native') = 'native'
  );

  SELECT * INTO v_pdf
  FROM data.customer_portal_latest_pdf_version(v_req.rendered_document_id);

  -- Prefer pinned request version when present.
  IF v_req.document_version_id IS NOT NULL THEN
    SELECT
      dv.id AS document_version_id,
      dv.document_id,
      dv.storage_type,
      dv.file_path_or_url
      INTO v_pdf
    FROM data.document_versions dv
    WHERE dv.id = v_req.document_version_id;
  END IF;

  v_card := data.customer_portal_pending_decision_card(v_req, v_tenant_name);
  v_snap := jsonb_strip_nulls(jsonb_build_object(
    'kind', v_req.snapshot_json->>'kind',
    'doc_type', v_req.snapshot_json->>'doc_type',
    'doc_number', v_req.snapshot_json->>'doc_number',
    'formalization_mode', v_req.snapshot_json->>'formalization_mode',
    'total', v_card->'total',
    'currency', v_card->>'currency',
    'locale', v_req.snapshot_json->>'locale',
    'valid_until', v_req.snapshot_json->>'valid_until',
    'show_prices', v_card->'show_prices',
    'version_no', v_req.snapshot_json->'version_no',
    'purpose', v_req.purpose
  ));

  RETURN jsonb_strip_nulls(jsonb_build_object(
    'request_id', v_req.id,
    'purpose', v_req.purpose,
    'status', v_req.status,
    'expires_at', v_req.expires_at,
    'created_at', v_req.created_at,
    'expires_soon', v_card->'expires_soon',
    'active_provider', v_req.active_provider,
    'content_hash', v_req.content_hash,
    'document_version_id', v_req.document_version_id,
    'has_pdf', (COALESCE(v_pdf.document_version_id, v_req.document_version_id) IS NOT NULL),
    'pdf_version_id', COALESCE(v_pdf.document_version_id, v_req.document_version_id),
    'pdf_storage_type', v_pdf.storage_type,
    'pdf_file_path', v_pdf.file_path_or_url,
    'snapshot', v_snap,
    'tenant', jsonb_strip_nulls(jsonb_build_object(
      'name', v_tenant_name,
      'logo_url', v_tenant_logo
    )),
    'account_name', v_account_name,
    'label', v_card->>'label',
    'doc_type', v_card->>'doc_type',
    'total', v_card->'total',
    'currency', v_card->>'currency',
    'show_prices', v_card->'show_prices',
    'can_decide', false,
    'decide_available', v_decide_available,
    'accept_available', false,
    'decline_available', v_decide_available
  ));
END;
$$;

-- ---------------------------------------------------------------------------
-- Decline (grant session only) → apply via portal
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.apply_customer_portal_pending_decision(
  p_session_token_hash bytea,
  p_request_id uuid,
  p_outcome text,
  p_evidence jsonb DEFAULT '{}'::jsonb,
  p_client_op_id uuid DEFAULT NULL,
  p_ip_address inet DEFAULT NULL,
  p_user_agent text DEFAULT NULL,
  p_audit_request_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sess data.customer_portal_grant_sessions%ROWTYPE;
  v_grant data.customer_access_grants%ROWTYPE;
  v_platform data.customer_portal_platform_state%ROWTYPE;
  v_tstate data.customer_portal_tenant_state%ROWTYPE;
  v_ent jsonb;
  v_mode text;
  v_req data.commercial_decision_requests%ROWTYPE;
  v_evidence jsonb := COALESCE(p_evidence, '{}'::jsonb);
  v_result jsonb;
  v_principal_name text;
  v_actor_name text;
  v_actor_role text;
  v_audit_rid text;
  v_op uuid;
BEGIN
  IF COALESCE(NULLIF(btrim(p_outcome), ''), '') IS DISTINCT FROM 'declined' THEN
    -- Accept is F7 tall 3 (native stamp pipeline).
    RETURN jsonb_build_object('ok', false, 'code', 'outcome_not_supported');
  END IF;

  IF p_session_token_hash IS NULL OR length(p_session_token_hash) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;
  IF p_request_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid_target');
  END IF;

  v_op := COALESCE(p_client_op_id, gen_random_uuid());
  v_audit_rid := left(COALESCE(p_audit_request_id, v_op::text), 128);

  SELECT * INTO v_platform FROM data.customer_portal_platform_state WHERE id;

  SELECT * INTO v_sess
  FROM data.customer_portal_grant_sessions
  WHERE session_token_hash = p_session_token_hash
  FOR UPDATE;

  IF NOT FOUND THEN
    -- Staff preview must not decide.
    RETURN jsonb_build_object('ok', false, 'code', 'forbidden');
  END IF;

  SELECT * INTO v_grant FROM data.customer_access_grants WHERE id = v_sess.grant_id;
  v_tstate := data.ensure_customer_portal_tenant_state(v_sess.tenant_id);

  IF v_sess.revoked_at IS NOT NULL
     OR v_sess.expires_at <= now()
     OR v_grant.id IS NULL
     OR v_grant.revoked_at IS NOT NULL
     OR NOT v_platform.enabled
     OR NOT v_tstate.enabled
     OR v_platform.max_mode <> 'portal'
     OR v_tstate.existing_access_policy <> 'allow'
     OR v_sess.session_version IS DISTINCT FROM v_grant.session_version
     OR v_sess.security_version_tenant IS DISTINCT FROM v_tstate.security_version
     OR v_sess.security_version_platform IS DISTINCT FROM v_platform.security_version
  THEN
    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, grant_id, session_id, action, http_status,
      failure_reason, ip_address, user_agent, request_id
    ) VALUES (
      v_sess.tenant_id, v_sess.grant_id, v_sess.id, 'commercial_denied', 401,
      'session_invalid', p_ip_address, left(COALESCE(p_user_agent, ''), 512), v_audit_rid
    );
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  v_ent := data.resolve_portal_entitlements(v_sess.tenant_id);
  v_mode := COALESCE(v_ent ->> 'mode_effective', '');
  IF v_mode IS DISTINCT FROM 'portal' THEN
    RETURN jsonb_build_object('ok', false, 'code', 'module_disabled');
  END IF;

  IF NOT data.commercial_decision_requests_enabled(v_sess.tenant_id) THEN
    RETURN jsonb_build_object('ok', false, 'code', 'module_disabled');
  END IF;

  UPDATE data.customer_portal_grant_sessions
  SET last_seen_at = now() WHERE id = v_sess.id;
  UPDATE data.customer_access_grants
  SET last_seen_at = now() WHERE id = v_grant.id;

  SELECT * INTO v_req
  FROM data.commercial_decision_requests r
  WHERE r.id = p_request_id
  FOR UPDATE;

  IF NOT FOUND
     OR v_req.tenant_id IS DISTINCT FROM v_sess.tenant_id
     OR v_req.client_account_contact_id IS DISTINCT FROM v_grant.client_account_contact_id
  THEN
    RETURN jsonb_build_object('ok', false, 'code', 'not_found');
  END IF;

  IF v_req.status IS DISTINCT FROM 'open' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'applied', false,
      'already_decided', true,
      'status', v_req.status,
      'request_id', v_req.id,
      'decided_via', v_req.decided_via,
      'decided_at', v_req.decided_at
    );
  END IF;

  IF NOT data.customer_portal_pending_decision_visible(
    v_sess.tenant_id,
    v_grant.client_account_contact_id,
    v_req,
    v_tstate.commercial_quotes_agreements_enabled,
    v_tstate.commercial_delivery_notes_enabled
  ) THEN
    RETURN jsonb_build_object('ok', false, 'code', 'not_found');
  END IF;

  IF COALESCE(v_req.active_provider, 'native') IS DISTINCT FROM 'native' THEN
    RETURN jsonb_build_object('ok', false, 'code', 'provider_not_supported');
  END IF;

  SELECT NULLIF(btrim(COALESCE(c.display_name, c.legal_name,
    NULLIF(btrim(CONCAT_WS(' ', c.given_name, c.family_name)), ''),
    c.email)), '')
    INTO v_principal_name
  FROM data.contacts c
  WHERE c.id = v_grant.principal_contact_id
    AND c.tenant_id = v_sess.tenant_id;

  v_actor_name := NULLIF(btrim(COALESCE(v_evidence->>'actor_name', '')), '');
  v_actor_role := NULLIF(btrim(COALESCE(v_evidence->>'actor_role', '')), '');

  IF v_grant.principal_kind = 'shared_mailbox' THEN
    IF v_actor_name IS NULL OR char_length(v_actor_name) < 2 THEN
      RETURN jsonb_build_object('ok', false, 'code', 'actor_name_required');
    END IF;
    IF v_actor_role IS NULL OR char_length(v_actor_role) < 2 THEN
      RETURN jsonb_build_object('ok', false, 'code', 'actor_role_required');
    END IF;
    v_evidence := v_evidence || jsonb_build_object(
      'signer_name', v_actor_name,
      'signer_role', v_actor_role,
      'principal_kind', 'shared_mailbox',
      'principal_contact_id', v_grant.principal_contact_id,
      'acting_for_account_contact_id', v_grant.client_account_contact_id
    );
  ELSE
    -- Nominative: identity from resolved principal; optional role confirmation only.
    v_evidence := v_evidence || jsonb_build_object(
      'signer_name', COALESCE(v_principal_name, 'client'),
      'signer_role', COALESCE(v_actor_role, v_evidence->>'signer_role'),
      'principal_kind', 'named_person',
      'principal_contact_id', v_grant.principal_contact_id
    );
  END IF;

  v_evidence := v_evidence || jsonb_build_object(
    'grant_id', v_grant.id,
    'session_id', v_sess.id,
    'ip_address', p_ip_address,
    'user_agent', left(COALESCE(p_user_agent, ''), 512),
    'via', 'portal'
  );

  BEGIN
    v_result := data.apply_commercial_decision_request(
      v_req.id,
      'declined',
      'portal',
      v_evidence,
      v_op,
      NULL
    );
  EXCEPTION WHEN others THEN
    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, grant_id, session_id, action, http_status,
      failure_reason, ip_address, user_agent, request_id
    ) VALUES (
      v_sess.tenant_id, v_grant.id, v_sess.id, 'commercial_denied', 409,
      left(SQLERRM, 200), p_ip_address, left(COALESCE(p_user_agent, ''), 512), v_audit_rid
    );
    RETURN jsonb_build_object('ok', false, 'code', 'apply_failed', 'message', SQLERRM);
  END;

  INSERT INTO data.customer_report_share_access_logs (
    tenant_id, grant_id, session_id, action, http_status,
    ip_address, user_agent, request_id
  ) VALUES (
    v_sess.tenant_id, v_grant.id, v_sess.id, 'commercial_pending', 200,
    p_ip_address, left(COALESCE(p_user_agent, ''), 512), v_audit_rid
  );

  RETURN jsonb_build_object(
    'ok', true,
    'request_id', v_result->>'request_id',
    'status', v_result->>'status',
    'applied', COALESCE((v_result->>'applied')::boolean, false),
    'already_decided', COALESCE((v_result->>'already_decided')::boolean, false),
    'decided_via', CASE
      WHEN COALESCE((v_result->>'applied')::boolean, false) THEN 'portal'
      ELSE (SELECT decided_via FROM data.commercial_decision_requests WHERE id = v_req.id)
    END,
    'decided_at', (SELECT decided_at FROM data.commercial_decision_requests WHERE id = v_req.id)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.apply_customer_portal_pending_decision(
  bytea, uuid, text, jsonb, uuid, inet, text, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.apply_customer_portal_pending_decision(
  bytea, uuid, text, jsonb, uuid, inet, text, text
) TO service_role;

NOTIFY pgrst, 'reload schema';
