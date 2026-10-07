-- CF-28 / F7 tall 1 (CP-Db): portal pending decision list + read-only get.
-- Accept/decline deferred to later F7 talls.

ALTER TABLE data.customer_report_share_access_logs
  DROP CONSTRAINT IF EXISTS customer_report_share_access_logs_action_check;

ALTER TABLE data.customer_report_share_access_logs
  ADD CONSTRAINT customer_report_share_access_logs_action_check
  CHECK (action = ANY (ARRAY[
    'session_create'::text,
    'report_view'::text,
    'media_download'::text,
    'resolve_denied'::text,
    'session_denied'::text,
    'rate_limited'::text,
    'list_bulletins'::text,
    'invitation_accepted'::text,
    'login_token_requested'::text,
    'login_token_exchanged'::text,
    'handoff_consumed'::text,
    'commercial_list'::text,
    'commercial_denied'::text,
    'commercial_detail'::text,
    'commercial_pdf'::text,
    'commercial_pending'::text
  ]));

-- ---------------------------------------------------------------------------
-- Visibility predicate (module toggle + live target still decidable)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.customer_portal_pending_decision_visible(
  p_tenant_id uuid,
  p_client_account_contact_id uuid,
  p_request data.commercial_decision_requests,
  p_quotes_enabled boolean,
  p_dn_enabled boolean
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_request.tenant_id IS DISTINCT FROM p_tenant_id THEN
    RETURN false;
  END IF;
  IF p_request.client_account_contact_id IS DISTINCT FROM p_client_account_contact_id THEN
    RETURN false;
  END IF;
  IF p_request.status IS DISTINCT FROM 'open' THEN
    RETURN false;
  END IF;
  IF p_request.expires_at <= now() THEN
    RETURN false;
  END IF;
  IF NOT data.commercial_decision_requests_enabled(p_tenant_id) THEN
    RETURN false;
  END IF;

  IF p_request.commercial_document_id IS NOT NULL THEN
    RETURN EXISTS (
      SELECT 1
      FROM data.commercial_documents d
      WHERE d.id = p_request.commercial_document_id
        AND d.tenant_id = p_tenant_id
        AND d.client_id = p_client_account_contact_id
        AND d.status = 'issued'
        AND (
          (d.doc_type IN ('quote', 'quote_amendment') AND p_quotes_enabled)
          OR (d.doc_type = 'delivery_note' AND p_dn_enabled)
        )
    );
  END IF;

  IF p_request.agreement_version_id IS NOT NULL AND p_quotes_enabled THEN
    RETURN EXISTS (
      SELECT 1
      FROM data.commercial_agreement_versions v
      JOIN data.commercial_agreements a ON a.id = v.agreement_id
      WHERE v.id = p_request.agreement_version_id
        AND a.tenant_id = p_tenant_id
        AND a.client_id = p_client_account_contact_id
        AND v.status = 'pending_signature'
        AND a.status IS DISTINCT FROM 'cancelled'
    );
  END IF;

  RETURN false;
END;
$$;

REVOKE ALL ON FUNCTION data.customer_portal_pending_decision_visible(
  uuid, uuid, data.commercial_decision_requests, boolean, boolean
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.customer_portal_pending_decision_visible(
  uuid, uuid, data.commercial_decision_requests, boolean, boolean
) TO service_role;

-- ---------------------------------------------------------------------------
-- Public card projection from immutable snapshot (+ live show_prices)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.customer_portal_pending_decision_card(
  p_request data.commercial_decision_requests,
  p_tenant_name text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_snap jsonb := COALESCE(p_request.snapshot_json, '{}'::jsonb);
  v_show boolean;
  v_doc_type text;
  v_total numeric;
BEGIN
  v_doc_type := COALESCE(v_snap->>'doc_type', v_snap->>'kind');

  IF p_request.commercial_document_id IS NOT NULL THEN
    SELECT d.show_prices, d.doc_type
      INTO v_show, v_doc_type
    FROM data.commercial_documents d
    WHERE d.id = p_request.commercial_document_id;
  ELSE
    v_show := COALESCE((v_snap->>'show_prices')::boolean, true);
  END IF;

  v_show := COALESCE(v_show, true);
  IF v_show THEN
    BEGIN
      v_total := (v_snap->>'total')::numeric;
    EXCEPTION WHEN others THEN
      v_total := NULL;
    END;
  ELSE
    v_total := NULL;
  END IF;

  RETURN jsonb_strip_nulls(jsonb_build_object(
    'request_id', p_request.id,
    'purpose', p_request.purpose,
    'status', p_request.status,
    'expires_at', p_request.expires_at,
    'created_at', p_request.created_at,
    'doc_type', v_doc_type,
    'label', NULLIF(btrim(COALESCE(v_snap->>'doc_number', '')), ''),
    'formalization_mode', v_snap->>'formalization_mode',
    'total', v_total,
    'currency', CASE WHEN v_show THEN v_snap->>'currency' ELSE NULL END,
    'show_prices', v_show,
    'version_no', v_snap->'version_no',
    'tenant_name', NULLIF(btrim(COALESCE(p_tenant_name, '')), ''),
    'expires_soon', (p_request.expires_at <= now() + interval '48 hours')
  ));
END;
$$;

REVOKE ALL ON FUNCTION data.customer_portal_pending_decision_card(
  data.commercial_decision_requests, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.customer_portal_pending_decision_card(
  data.commercial_decision_requests, text
) TO service_role;

CREATE OR REPLACE FUNCTION data.list_customer_portal_pending_decisions(
  p_tenant_id uuid,
  p_client_account_contact_id uuid,
  p_quotes_enabled boolean,
  p_dn_enabled boolean,
  p_limit integer DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_limit integer := GREATEST(1, LEAST(COALESCE(p_limit, 20), 50));
  v_tenant_name text;
  v_items jsonb;
BEGIN
  IF p_tenant_id IS NULL OR p_client_account_contact_id IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;
  IF NOT data.commercial_decision_requests_enabled(p_tenant_id) THEN
    RETURN '[]'::jsonb;
  END IF;
  IF NOT COALESCE(p_quotes_enabled, false) AND NOT COALESCE(p_dn_enabled, false) THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT NULLIF(btrim(t.name), '') INTO v_tenant_name
  FROM data.tenants t
  WHERE t.id = p_tenant_id;

  SELECT COALESCE(
    jsonb_agg(card ORDER BY expires_at ASC, created_at ASC, id ASC),
    '[]'::jsonb
  )
  INTO v_items
  FROM (
    SELECT
      r.id,
      r.expires_at,
      r.created_at,
      data.customer_portal_pending_decision_card(r, v_tenant_name) AS card
    FROM data.commercial_decision_requests r
    WHERE r.tenant_id = p_tenant_id
      AND r.client_account_contact_id = p_client_account_contact_id
      AND r.status = 'open'
      AND r.expires_at > now()
      AND data.customer_portal_pending_decision_visible(
        p_tenant_id, p_client_account_contact_id, r,
        COALESCE(p_quotes_enabled, false),
        COALESCE(p_dn_enabled, false)
      )
    ORDER BY r.expires_at ASC, r.created_at ASC, r.id ASC
    LIMIT v_limit
  ) page;

  RETURN v_items;
END;
$$;

REVOKE ALL ON FUNCTION data.list_customer_portal_pending_decisions(
  uuid, uuid, boolean, boolean, integer
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.list_customer_portal_pending_decisions(
  uuid, uuid, boolean, boolean, integer
) TO service_role;

CREATE OR REPLACE FUNCTION data.count_customer_portal_pending_decisions(
  p_tenant_id uuid,
  p_client_account_contact_id uuid,
  p_quotes_enabled boolean,
  p_dn_enabled boolean
)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_count integer := 0;
BEGIN
  IF p_tenant_id IS NULL OR p_client_account_contact_id IS NULL THEN
    RETURN 0;
  END IF;
  IF NOT data.commercial_decision_requests_enabled(p_tenant_id) THEN
    RETURN 0;
  END IF;
  IF NOT COALESCE(p_quotes_enabled, false) AND NOT COALESCE(p_dn_enabled, false) THEN
    RETURN 0;
  END IF;

  SELECT COUNT(*)::integer
  INTO v_count
  FROM data.commercial_decision_requests r
  WHERE r.tenant_id = p_tenant_id
    AND r.client_account_contact_id = p_client_account_contact_id
    AND r.status = 'open'
    AND r.expires_at > now()
    AND data.customer_portal_pending_decision_visible(
      p_tenant_id, p_client_account_contact_id, r,
      COALESCE(p_quotes_enabled, false),
      COALESCE(p_dn_enabled, false)
    );

  RETURN COALESCE(v_count, 0);
END;
$$;

REVOKE ALL ON FUNCTION data.count_customer_portal_pending_decisions(
  uuid, uuid, boolean, boolean
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.count_customer_portal_pending_decisions(
  uuid, uuid, boolean, boolean
) TO service_role;

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

  IF NOT data.customer_portal_pending_decision_visible(
    p_tenant_id, p_client_account_contact_id, v_req,
    COALESCE(p_quotes_enabled, false),
    COALESCE(p_dn_enabled, false)
  ) THEN
    RETURN NULL;
  END IF;

  SELECT NULLIF(btrim(t.name), ''),
         NULLIF(btrim(COALESCE(t.settings->'branding'->>'logo_url', t.settings->>'logo_url')), '')
    INTO v_tenant_name, v_tenant_logo
  FROM data.tenants t
  WHERE t.id = p_tenant_id;

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
    'has_pdf', (v_req.document_version_id IS NOT NULL),
    'snapshot', v_snap,
    'tenant', jsonb_strip_nulls(jsonb_build_object(
      'name', v_tenant_name,
      'logo_url', v_tenant_logo
    )),
    'label', v_card->>'label',
    'doc_type', v_card->>'doc_type',
    'total', v_card->'total',
    'currency', v_card->>'currency',
    'show_prices', v_card->'show_prices',
    -- Accept/decline wired in later F7 talls; staff never decides.
    'can_decide', false,
    'decide_available', false
  ));
END;
$$;

REVOKE ALL ON FUNCTION data.get_customer_portal_pending_decision(
  uuid, uuid, uuid, boolean, boolean
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.get_customer_portal_pending_decision(
  uuid, uuid, uuid, boolean, boolean
) TO service_role;

-- ---------------------------------------------------------------------------
-- Resolve: list_summary count + list/get pending actions
-- ---------------------------------------------------------------------------
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
  v_ent jsonb;
  v_mode text;
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
  v_staff_user_id uuid;
  v_audit_rid text;
  v_modules jsonb;
  v_pending_count integer := 0;
  v_principal_kind text;
BEGIN
  IF v_action NOT IN (
    'list_documents', 'list_summary',
    'get_quote_or_agreement', 'get_delivery_note', 'get_invoice',
    'list_pending_decisions', 'get_pending_decision'
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
    SET last_seen_at = now() WHERE id = v_sess.id;
    UPDATE data.customer_access_grants
    SET last_seen_at = now() WHERE id = v_grant.id;

    v_actor := 'grant';
    v_tenant_id := v_sess.tenant_id;
    v_client_id := v_grant.client_account_contact_id;
    v_session_id := v_sess.id;
    v_grant_id := v_grant.id;
    v_principal_kind := v_grant.principal_kind;
  ELSE
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
    SET last_seen_at = now() WHERE id = v_staff.id;

    v_actor := 'staff';
    v_tenant_id := v_staff.tenant_id;
    v_client_id := v_staff.client_account_contact_id;
    v_session_id := v_staff.id;
    v_grant_id := NULL;
    v_staff_user_id := v_staff.staff_user_id;
    v_principal_kind := NULL;
  END IF;

  v_ent := data.resolve_portal_entitlements(v_tenant_id);
  v_mode := COALESCE(v_ent ->> 'mode_effective', '');
  v_audit_rid := left(
    COALESCE(p_request_id, '')
      || CASE WHEN v_staff_user_id IS NOT NULL THEN ' staff=' || v_staff_user_id::text ELSE '' END,
    128
  );

  IF v_mode IS DISTINCT FROM 'portal' THEN
    IF v_action = 'list_summary' THEN
      RETURN jsonb_build_object(
        'ok', true,
        'action', v_action,
        'actor_type', v_actor,
        'tenant_id', v_tenant_id,
        'grant_id', v_grant_id,
        'client_account_contact_id', v_client_id,
        'modules', jsonb_build_object(
          'quotes_agreements', false,
          'delivery_notes', false,
          'invoices', false
        ),
        'pending_decisions_count', 0,
        'mode_effective', v_mode
      );
    END IF;

    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, grant_id, session_id, action, http_status,
      failure_reason, ip_address, user_agent, request_id
    ) VALUES (
      v_tenant_id, v_grant_id, v_session_id, 'commercial_denied', 403,
      'mode_not_portal', p_ip_address, left(COALESCE(p_user_agent, ''), 512), v_audit_rid
    );
    RETURN jsonb_build_object('ok', false, 'code', 'module_disabled');
  END IF;

  v_modules := jsonb_build_object(
    'quotes_agreements', v_tstate.commercial_quotes_agreements_enabled,
    'delivery_notes', v_tstate.commercial_delivery_notes_enabled,
    'invoices', v_tstate.commercial_invoices_enabled
  );

  v_pending_count := data.count_customer_portal_pending_decisions(
    v_tenant_id,
    v_client_id,
    v_tstate.commercial_quotes_agreements_enabled,
    v_tstate.commercial_delivery_notes_enabled
  );

  IF v_action = 'list_summary' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'action', v_action,
      'actor_type', v_actor,
      'tenant_id', v_tenant_id,
      'grant_id', v_grant_id,
      'client_account_contact_id', v_client_id,
      'modules', v_modules,
      'pending_decisions_count', v_pending_count,
      'mode_effective', v_mode
    );
  END IF;

  IF v_action = 'list_pending_decisions' THEN
    v_items := data.list_customer_portal_pending_decisions(
      v_tenant_id,
      v_client_id,
      v_tstate.commercial_quotes_agreements_enabled,
      v_tstate.commercial_delivery_notes_enabled,
      p_limit
    );

    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, grant_id, session_id, action, http_status,
      ip_address, user_agent, request_id
    ) VALUES (
      v_tenant_id, v_grant_id, v_session_id, 'commercial_pending', 200,
      p_ip_address, left(COALESCE(p_user_agent, ''), 512), v_audit_rid
    );

    RETURN jsonb_build_object(
      'ok', true,
      'action', v_action,
      'actor_type', v_actor,
      'tenant_id', v_tenant_id,
      'grant_id', v_grant_id,
      'client_account_contact_id', v_client_id,
      'modules', v_modules,
      'pending_decisions_count', v_pending_count,
      'principal_kind', v_principal_kind,
      'items', v_items
    );
  END IF;

  IF v_action = 'get_pending_decision' THEN
    IF p_target_id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'code', 'invalid_target');
    END IF;

    v_detail := data.get_customer_portal_pending_decision(
      v_tenant_id,
      v_client_id,
      p_target_id,
      v_tstate.commercial_quotes_agreements_enabled,
      v_tstate.commercial_delivery_notes_enabled
    );

    IF v_detail IS NULL THEN
      INSERT INTO data.customer_report_share_access_logs (
        tenant_id, grant_id, session_id, action, http_status,
        failure_reason, ip_address, user_agent, request_id
      ) VALUES (
        v_tenant_id, v_grant_id, v_session_id, 'commercial_denied', 404,
        'not_found', p_ip_address, left(COALESCE(p_user_agent, ''), 512), v_audit_rid
      );
      RETURN jsonb_build_object('ok', false, 'code', 'not_found');
    END IF;

    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, grant_id, session_id, action, http_status,
      ip_address, user_agent, request_id
    ) VALUES (
      v_tenant_id, v_grant_id, v_session_id, 'commercial_pending', 200,
      p_ip_address, left(COALESCE(p_user_agent, ''), 512), v_audit_rid
    );

    RETURN jsonb_build_object(
      'ok', true,
      'action', v_action,
      'actor_type', v_actor,
      'tenant_id', v_tenant_id,
      'grant_id', v_grant_id,
      'client_account_contact_id', v_client_id,
      'modules', v_modules,
      'pending_decisions_count', v_pending_count,
      'principal_kind', v_principal_kind,
      'detail', v_detail
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
        'module_disabled', p_ip_address, left(COALESCE(p_user_agent, ''), 512), v_audit_rid
      );
      RETURN jsonb_build_object('ok', false, 'code', 'module_disabled', 'modules', v_modules);
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
      p_ip_address, left(COALESCE(p_user_agent, ''), 512), v_audit_rid
    );

    RETURN jsonb_build_object(
      'ok', true,
      'action', v_action,
      'actor_type', v_actor,
      'kind', v_kind,
      'tenant_id', v_tenant_id,
      'grant_id', v_grant_id,
      'client_account_contact_id', v_client_id,
      'modules', v_modules,
      'pending_decisions_count', v_pending_count,
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
      'module_disabled', p_ip_address, left(COALESCE(p_user_agent, ''), 512), v_audit_rid
    );
    RETURN jsonb_build_object('ok', false, 'code', 'module_disabled', 'modules', v_modules);
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
      'not_found', p_ip_address, left(COALESCE(p_user_agent, ''), 512), v_audit_rid
    );
    RETURN jsonb_build_object('ok', false, 'code', 'not_found');
  END IF;

  INSERT INTO data.customer_report_share_access_logs (
    tenant_id, grant_id, session_id, action, http_status,
    ip_address, user_agent, request_id
  ) VALUES (
    v_tenant_id, v_grant_id, v_session_id, 'commercial_detail', 200,
    p_ip_address, left(COALESCE(p_user_agent, ''), 512), v_audit_rid
  );

  RETURN jsonb_build_object(
    'ok', true,
    'action', v_action,
    'actor_type', v_actor,
    'kind', v_kind,
    'tenant_id', v_tenant_id,
    'grant_id', v_grant_id,
    'client_account_contact_id', v_client_id,
    'modules', v_modules,
    'pending_decisions_count', v_pending_count,
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
