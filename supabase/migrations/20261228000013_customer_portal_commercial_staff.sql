-- CF-28 / F6 tall 4: staff client-account sessions use the same commercial allowlist.

CREATE OR REPLACE FUNCTION api.resolve_customer_portal_commercial(
  p_session_token_hash bytea,
  p_action text DEFAULT 'list_documents',
  p_kind text DEFAULT 'quotes_agreements',
  p_cursor_sort timestamptz DEFAULT NULL,
  p_cursor_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 20,
  p_ip_address inet DEFAULT NULL,
  p_user_agent text DEFAULT NULL,
  p_request_id text DEFAULT NULL,
  p_target_id uuid DEFAULT NULL,
  p_item_kind text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sess data.customer_portal_grant_sessions%ROWTYPE;
  v_staff data.customer_portal_staff_sessions%ROWTYPE;
  v_grant data.customer_access_grants%ROWTYPE;
  v_platform data.customer_portal_platform_state%ROWTYPE;
  v_tstate data.customer_portal_tenant_state%ROWTYPE;
  v_action text := COALESCE(NULLIF(btrim(p_action), ''), 'list_documents');
  v_kind text := COALESCE(NULLIF(btrim(p_kind), ''), 'quotes_agreements');
  v_items jsonb := '[]'::jsonb;
  v_detail jsonb;
  v_enabled boolean := false;
  v_actor text := 'grant';
  v_tenant_id uuid;
  v_client_id uuid;
  v_session_id uuid;
  v_grant_id uuid;
BEGIN
  IF v_action NOT IN (
    'list_documents', 'list_summary',
    'get_quote_or_agreement', 'get_delivery_note', 'get_invoice'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid_action');
  END IF;

  IF p_session_token_hash IS NULL OR length(p_session_token_hash) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  SELECT * INTO v_platform FROM data.customer_portal_platform_state WHERE id;

  SELECT * INTO v_sess
  FROM data.customer_portal_grant_sessions
  WHERE session_token_hash = p_session_token_hash
  FOR UPDATE;

  IF FOUND THEN
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
        'session_invalid', p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
      );
      RETURN jsonb_build_object('ok', false, 'code', 'invalid');
    END IF;

    UPDATE data.customer_portal_grant_sessions
    SET last_seen_at = now()
    WHERE id = v_sess.id;

    UPDATE data.customer_access_grants
    SET last_seen_at = now()
    WHERE id = v_grant.id;

    v_actor := 'grant';
    v_tenant_id := v_sess.tenant_id;
    v_client_id := v_grant.client_account_contact_id;
    v_session_id := v_sess.id;
    v_grant_id := v_grant.id;
  ELSE
    -- Staff opaque session (client_account scope only — no universal viewer).
    SELECT * INTO v_staff
    FROM data.customer_portal_staff_sessions
    WHERE session_token_hash = p_session_token_hash
    FOR UPDATE;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'code', 'invalid');
    END IF;

    v_tstate := data.ensure_customer_portal_tenant_state(v_staff.tenant_id);

    IF v_staff.revoked_at IS NOT NULL
       OR v_staff.expires_at <= now()
       OR v_staff.exchanged_at IS NULL
       OR v_staff.client_account_contact_id IS NULL
       OR NOT v_platform.enabled
       OR NOT v_tstate.enabled
       OR v_platform.max_mode <> 'portal'
       OR v_tstate.existing_access_policy <> 'allow'
       OR v_staff.security_version_tenant IS DISTINCT FROM v_tstate.security_version
       OR v_staff.security_version_platform IS DISTINCT FROM v_platform.security_version
    THEN
      INSERT INTO data.customer_report_share_access_logs (
        tenant_id, grant_id, session_id, action, http_status,
        failure_reason, ip_address, user_agent, request_id
      ) VALUES (
        v_staff.tenant_id, NULL, v_staff.id, 'commercial_denied', 401,
        'session_invalid', p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
      );
      RETURN jsonb_build_object('ok', false, 'code', 'invalid');
    END IF;

    UPDATE data.customer_portal_staff_sessions
    SET last_seen_at = now()
    WHERE id = v_staff.id;

    v_actor := 'staff';
    v_tenant_id := v_staff.tenant_id;
    v_client_id := v_staff.client_account_contact_id;
    v_session_id := v_staff.id;
    v_grant_id := NULL;
  END IF;

  IF v_action = 'list_summary' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'action', v_action,
      'actor_type', v_actor,
      'tenant_id', v_tenant_id,
      'grant_id', v_grant_id,
      'client_account_contact_id', v_client_id,
      'modules', jsonb_build_object(
        'quotes_agreements', v_tstate.commercial_quotes_agreements_enabled,
        'delivery_notes', v_tstate.commercial_delivery_notes_enabled,
        'invoices', v_tstate.commercial_invoices_enabled
      )
    );
  END IF;

  IF v_action = 'list_documents' THEN
    IF v_kind = 'quotes_agreements' THEN
      v_enabled := v_tstate.commercial_quotes_agreements_enabled;
    ELSIF v_kind = 'delivery_notes' THEN
      v_enabled := v_tstate.commercial_delivery_notes_enabled;
    ELSIF v_kind = 'invoices' THEN
      v_enabled := v_tstate.commercial_invoices_enabled;
    ELSE
      RETURN jsonb_build_object('ok', false, 'code', 'invalid_kind');
    END IF;

    IF NOT v_enabled THEN
      INSERT INTO data.customer_report_share_access_logs (
        tenant_id, grant_id, session_id, action, http_status,
        failure_reason, ip_address, user_agent, request_id
      ) VALUES (
        v_tenant_id, v_grant_id, v_session_id, 'commercial_denied', 403,
        'module_disabled', p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
      );
      RETURN jsonb_build_object('ok', false, 'code', 'module_disabled');
    END IF;

    IF v_kind = 'quotes_agreements' THEN
      v_items := data.list_customer_portal_quotes_agreements(
        v_tenant_id, v_client_id, p_cursor_sort, p_cursor_id, p_limit
      );
    ELSIF v_kind = 'delivery_notes' THEN
      v_items := data.list_customer_portal_delivery_notes(
        v_tenant_id, v_client_id, p_cursor_sort, p_cursor_id, p_limit
      );
    ELSE
      v_items := data.list_customer_portal_invoices(
        v_tenant_id, v_client_id, p_cursor_sort, p_cursor_id, p_limit
      );
    END IF;

    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, grant_id, session_id, action, http_status,
      ip_address, user_agent, request_id
    ) VALUES (
      v_tenant_id, v_grant_id, v_session_id, 'commercial_list', 200,
      p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
    );

    RETURN jsonb_build_object(
      'ok', true,
      'action', v_action,
      'actor_type', v_actor,
      'kind', v_kind,
      'tenant_id', v_tenant_id,
      'grant_id', v_grant_id,
      'client_account_contact_id', v_client_id,
      'items', v_items
    );
  END IF;

  IF p_target_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid_target');
  END IF;

  IF v_action = 'get_quote_or_agreement' THEN
    v_enabled := v_tstate.commercial_quotes_agreements_enabled;
    v_kind := 'quotes_agreements';
  ELSIF v_action = 'get_delivery_note' THEN
    v_enabled := v_tstate.commercial_delivery_notes_enabled;
    v_kind := 'delivery_notes';
  ELSE
    v_enabled := v_tstate.commercial_invoices_enabled;
    v_kind := 'invoices';
  END IF;

  IF NOT v_enabled THEN
    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, grant_id, session_id, action, http_status,
      failure_reason, ip_address, user_agent, request_id
    ) VALUES (
      v_tenant_id, v_grant_id, v_session_id, 'commercial_denied', 403,
      'module_disabled', p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
    );
    RETURN jsonb_build_object('ok', false, 'code', 'module_disabled');
  END IF;

  IF v_action = 'get_quote_or_agreement' THEN
    v_detail := data.get_customer_portal_quote_agreement(
      v_tenant_id, v_client_id, p_target_id,
      COALESCE(NULLIF(btrim(p_item_kind), ''), 'document')
    );
  ELSIF v_action = 'get_delivery_note' THEN
    v_detail := data.get_customer_portal_delivery_note(
      v_tenant_id, v_client_id, p_target_id
    );
  ELSE
    v_detail := data.get_customer_portal_invoice(
      v_tenant_id, v_client_id, p_target_id
    );
  END IF;

  IF v_detail IS NULL THEN
    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, grant_id, session_id, action, http_status,
      failure_reason, ip_address, user_agent, request_id
    ) VALUES (
      v_tenant_id, v_grant_id, v_session_id, 'commercial_denied', 404,
      'not_found', p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
    );
    RETURN jsonb_build_object('ok', false, 'code', 'not_found');
  END IF;

  INSERT INTO data.customer_report_share_access_logs (
    tenant_id, grant_id, session_id, action, http_status,
    ip_address, user_agent, request_id
  ) VALUES (
    v_tenant_id, v_grant_id, v_session_id, 'commercial_detail', 200,
    p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
  );

  RETURN jsonb_build_object(
    'ok', true,
    'action', v_action,
    'actor_type', v_actor,
    'kind', v_kind,
    'tenant_id', v_tenant_id,
    'grant_id', v_grant_id,
    'client_account_contact_id', v_client_id,
    'detail', v_detail
  );
END;
$$;

REVOKE ALL ON FUNCTION api.resolve_customer_portal_commercial(
  bytea, text, text, timestamptz, uuid, integer, inet, text, text, uuid, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.resolve_customer_portal_commercial(
  bytea, text, text, timestamptz, uuid, integer, inet, text, text, uuid, text
) TO service_role;
