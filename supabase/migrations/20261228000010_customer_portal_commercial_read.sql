-- CF-28 / F6: customer portal commercial read (CP-Da) — toggles + quotes/agreements list.

-- ---------------------------------------------------------------------------
-- 1. Tenant state toggles (opt-in, default off)
-- ---------------------------------------------------------------------------
ALTER TABLE data.customer_portal_tenant_state
  ADD COLUMN IF NOT EXISTS commercial_quotes_agreements_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS commercial_delivery_notes_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS commercial_invoices_enabled boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN data.customer_portal_tenant_state.commercial_quotes_agreements_enabled IS
  'CF-28: expose quotes/agreements catalogue to nominative portal grants.';
COMMENT ON COLUMN data.customer_portal_tenant_state.commercial_delivery_notes_enabled IS
  'CF-28: expose delivery notes catalogue to nominative portal grants.';
COMMENT ON COLUMN data.customer_portal_tenant_state.commercial_invoices_enabled IS
  'CF-28: expose invoices catalogue to nominative portal grants.';

-- Audit actions for commercial catalogue (partitioned: drop/recreate CHECK).
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
    'commercial_denied'::text
  ]));

CREATE INDEX IF NOT EXISTS idx_commercial_documents_portal_quotes
  ON data.commercial_documents (tenant_id, client_id, issued_at DESC, id DESC)
  WHERE doc_type IN ('quote', 'quote_amendment')
    AND status IN ('issued', 'accepted', 'rejected', 'expired', 'cancelled');

CREATE INDEX IF NOT EXISTS idx_commercial_agreements_portal_client
  ON data.commercial_agreements (tenant_id, client_id, created_at DESC, id DESC);

-- ---------------------------------------------------------------------------
-- 2. Settings RPCs (settings.manage; set requires mode portal)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_my_customer_portal_commercial_settings()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_tstate data.customer_portal_tenant_state%ROWTYPE;
  v_ent jsonb;
  v_mode text;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_tstate := data.ensure_customer_portal_tenant_state(v_tenant);
  v_ent := data.resolve_portal_entitlements(v_tenant);
  v_mode := COALESCE(v_ent ->> 'mode_effective', '');

  RETURN jsonb_build_object(
    'quotes_agreements_enabled', v_tstate.commercial_quotes_agreements_enabled,
    'delivery_notes_enabled', v_tstate.commercial_delivery_notes_enabled,
    'invoices_enabled', v_tstate.commercial_invoices_enabled,
    'mode_effective', v_mode,
    'can_configure', (v_mode = 'portal')
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_my_customer_portal_commercial_settings() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_my_customer_portal_commercial_settings() TO authenticated;

CREATE OR REPLACE FUNCTION api.set_my_customer_portal_commercial_settings(
  p_quotes_agreements_enabled boolean DEFAULT NULL,
  p_delivery_notes_enabled boolean DEFAULT NULL,
  p_invoices_enabled boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_ent jsonb;
  v_mode text;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  PERFORM data.require_fresh_tenant_permission(v_tenant, 'settings.manage', NULL);
  PERFORM data.ensure_customer_portal_tenant_state(v_tenant);

  v_ent := data.resolve_portal_entitlements(v_tenant);
  v_mode := COALESCE(v_ent ->> 'mode_effective', '');
  IF v_mode IS DISTINCT FROM 'portal' THEN
    RAISE EXCEPTION 'commercial_portal_requires_portal_mode' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.customer_portal_tenant_state
  SET
    commercial_quotes_agreements_enabled = COALESCE(
      p_quotes_agreements_enabled, commercial_quotes_agreements_enabled
    ),
    commercial_delivery_notes_enabled = COALESCE(
      p_delivery_notes_enabled, commercial_delivery_notes_enabled
    ),
    commercial_invoices_enabled = COALESCE(
      p_invoices_enabled, commercial_invoices_enabled
    ),
    updated_at = now()
  WHERE tenant_id = v_tenant;

  PERFORM data.log_audit_event_strict(
    v_tenant, auth.uid(), NULL,
    'CUSTOMER_PORTAL_COMMERCIAL_SETTINGS_UPDATED',
    'customer_portal_tenant_state', v_tenant,
    jsonb_build_object(
      'quotes_agreements_enabled', p_quotes_agreements_enabled,
      'delivery_notes_enabled', p_delivery_notes_enabled,
      'invoices_enabled', p_invoices_enabled
    )
  );

  RETURN api.get_my_customer_portal_commercial_settings();
END;
$$;

REVOKE ALL ON FUNCTION api.set_my_customer_portal_commercial_settings(boolean, boolean, boolean)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_my_customer_portal_commercial_settings(boolean, boolean, boolean)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Private list (service_role only)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.list_customer_portal_quotes_agreements(
  p_tenant_id uuid,
  p_client_account_contact_id uuid,
  p_cursor_sort timestamptz DEFAULT NULL,
  p_cursor_id uuid DEFAULT NULL,
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
  v_items jsonb;
BEGIN
  IF p_tenant_id IS NULL OR p_client_account_contact_id IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  WITH docs AS (
    SELECT
      'document'::text AS item_kind,
      d.id,
      d.doc_type,
      d.doc_number AS label,
      d.status,
      COALESCE(d.issued_at, d.created_at) AS sort_date,
      d.total,
      d.currency,
      d.valid_until,
      NULL::text AS agreement_kind
    FROM data.commercial_documents d
    WHERE d.tenant_id = p_tenant_id
      AND d.client_id = p_client_account_contact_id
      AND d.doc_type IN ('quote', 'quote_amendment')
      AND d.status IN ('issued', 'accepted', 'rejected', 'expired', 'cancelled')

    UNION ALL

    SELECT
      'agreement'::text AS item_kind,
      a.id,
      'agreement'::text AS doc_type,
      COALESCE(a.kind, 'specific') AS label,
      COALESCE(v.status, a.status) AS status,
      COALESCE(v.updated_at, a.created_at) AS sort_date,
      NULL::numeric AS total,
      NULL::text AS currency,
      v.ends_on::timestamptz AS valid_until,
      a.kind AS agreement_kind
    FROM data.commercial_agreements a
    LEFT JOIN data.commercial_agreement_versions v
      ON v.id = a.active_version_id
    WHERE a.tenant_id = p_tenant_id
      AND a.client_id = p_client_account_contact_id
      AND a.status IS DISTINCT FROM 'cancelled'
      AND v.status IN ('pending_signature', 'signed', 'declined')
  ),
  page AS (
    SELECT *
    FROM docs
    WHERE (
      p_cursor_sort IS NULL
      OR (sort_date, id) < (p_cursor_sort, p_cursor_id)
    )
    ORDER BY sort_date DESC NULLS LAST, id DESC
    LIMIT v_limit
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'item_kind', item_kind,
        'id', id,
        'doc_type', doc_type,
        'label', label,
        'status', status,
        'sort_date', sort_date,
        'total', total,
        'currency', currency,
        'valid_until', valid_until,
        'agreement_kind', agreement_kind
      )
      ORDER BY sort_date DESC NULLS LAST, id DESC
    ),
    '[]'::jsonb
  )
  INTO v_items
  FROM page;

  RETURN v_items;
END;
$$;

REVOKE ALL ON FUNCTION data.list_customer_portal_quotes_agreements(uuid, uuid, timestamptz, uuid, integer)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.list_customer_portal_quotes_agreements(uuid, uuid, timestamptz, uuid, integer)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Session resolver for commercial catalogue
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
  p_request_id text DEFAULT NULL
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
  v_action text := COALESCE(NULLIF(btrim(p_action), ''), 'list_documents');
  v_kind text := COALESCE(NULLIF(btrim(p_kind), ''), 'quotes_agreements');
  v_items jsonb := '[]'::jsonb;
  v_enabled boolean := false;
BEGIN
  IF v_action NOT IN ('list_documents', 'list_summary') THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid_action');
  END IF;

  IF p_session_token_hash IS NULL OR length(p_session_token_hash) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  SELECT * INTO v_sess
  FROM data.customer_portal_grant_sessions
  WHERE session_token_hash = p_session_token_hash
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  SELECT * INTO v_grant FROM data.customer_access_grants WHERE id = v_sess.grant_id;
  SELECT * INTO v_platform FROM data.customer_portal_platform_state WHERE id;
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

  IF v_action = 'list_summary' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'action', v_action,
      'tenant_id', v_sess.tenant_id,
      'grant_id', v_grant.id,
      'client_account_contact_id', v_grant.client_account_contact_id,
      'modules', jsonb_build_object(
        'quotes_agreements', v_tstate.commercial_quotes_agreements_enabled,
        'delivery_notes', v_tstate.commercial_delivery_notes_enabled,
        'invoices', v_tstate.commercial_invoices_enabled
      )
    );
  END IF;

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
      v_sess.tenant_id, v_grant.id, v_sess.id, 'commercial_denied', 403,
      'module_disabled', p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
    );
    RETURN jsonb_build_object('ok', false, 'code', 'module_disabled');
  END IF;

  IF v_kind = 'quotes_agreements' THEN
    v_items := data.list_customer_portal_quotes_agreements(
      v_sess.tenant_id,
      v_grant.client_account_contact_id,
      p_cursor_sort,
      p_cursor_id,
      p_limit
    );
  ELSE
    -- Delivery notes / invoices list in later F6 slices.
    v_items := '[]'::jsonb;
  END IF;

  INSERT INTO data.customer_report_share_access_logs (
    tenant_id, grant_id, session_id, action, http_status,
    ip_address, user_agent, request_id
  ) VALUES (
    v_sess.tenant_id, v_grant.id, v_sess.id, 'commercial_list', 200,
    p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
  );

  RETURN jsonb_build_object(
    'ok', true,
    'action', v_action,
    'kind', v_kind,
    'tenant_id', v_sess.tenant_id,
    'grant_id', v_grant.id,
    'client_account_contact_id', v_grant.client_account_contact_id,
    'items', v_items
  );
END;
$$;

REVOKE ALL ON FUNCTION api.resolve_customer_portal_commercial(
  bytea, text, text, timestamptz, uuid, integer, inet, text, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.resolve_customer_portal_commercial(
  bytea, text, text, timestamptz, uuid, integer, inet, text, text
) TO service_role;
