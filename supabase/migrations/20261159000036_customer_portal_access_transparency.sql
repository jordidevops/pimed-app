-- =============================================================================
-- Customer portal P0: account access transparency (grants + staff support)
-- =============================================================================

CREATE OR REPLACE FUNCTION data.customer_portal_account_access_activity(
  p_tenant_id uuid,
  p_account_contact_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_name text;
  v_principals jsonb;
  v_support jsonb;
BEGIN
  IF p_tenant_id IS NULL OR p_account_contact_id IS NULL THEN
    RETURN jsonb_build_object(
      'tenant_display_name', NULL,
      'principals', '[]'::jsonb,
      'support_sessions', '[]'::jsonb
    );
  END IF;

  SELECT t.name INTO v_tenant_name
  FROM data.tenants t
  WHERE t.id = p_tenant_id;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'principal_kind', g.principal_kind,
      'email_normalized', g.email_normalized,
      'display_name', COALESCE(NULLIF(btrim(c.display_name), ''), g.email_normalized),
      'created_at', g.created_at,
      'last_seen_at', g.last_seen_at
    )
    ORDER BY g.created_at DESC
  ), '[]'::jsonb)
  INTO v_principals
  FROM data.customer_access_grants g
  LEFT JOIN data.contacts c ON c.id = g.principal_contact_id
  WHERE g.tenant_id = p_tenant_id
    AND g.client_account_contact_id = p_account_contact_id
    AND g.revoked_at IS NULL;

  -- Client-visible support trail: no staff_user_id / email / name.
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'kind', 'tenant_support',
      'created_at', s.created_at,
      'last_seen_at', s.last_seen_at,
      'expires_at', s.expires_at,
      'active', (s.revoked_at IS NULL AND s.expires_at > now())
    )
    ORDER BY COALESCE(s.last_seen_at, s.created_at) DESC
  ), '[]'::jsonb)
  INTO v_support
  FROM (
    SELECT s.*
    FROM data.customer_portal_staff_sessions s
    WHERE s.tenant_id = p_tenant_id
      AND s.client_account_contact_id = p_account_contact_id
    ORDER BY COALESCE(s.last_seen_at, s.created_at) DESC
    LIMIT 20
  ) s;

  RETURN jsonb_build_object(
    'tenant_display_name', COALESCE(NULLIF(btrim(v_tenant_name), ''), NULL),
    'principals', v_principals,
    'support_sessions', v_support
  );
END;
$$;

REVOKE ALL ON FUNCTION data.customer_portal_account_access_activity(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.customer_portal_account_access_activity(uuid, uuid)
  TO service_role;

-- Tenant UI: staff session history for an account (includes staff identity).
CREATE OR REPLACE FUNCTION api.list_customer_portal_staff_sessions_for_account(
  p_client_account_contact_id uuid,
  p_limit integer DEFAULT 30
)
RETURNS TABLE (
  id uuid,
  staff_user_id uuid,
  staff_display_name text,
  staff_email text,
  scope_mode text,
  report_version_id uuid,
  created_at timestamptz,
  expires_at timestamptz,
  last_seen_at timestamptz,
  revoked_at timestamptz,
  exchanged_at timestamptz,
  is_active boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_lim integer := GREATEST(1, LEAST(COALESCE(p_limit, 30), 100));
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_client_account_contact_id IS NULL THEN
    RAISE EXCEPTION 'client_account_required' USING ERRCODE = 'P0001';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.contacts c
    WHERE c.id = p_client_account_contact_id AND c.tenant_id = v_tenant
  ) THEN
    RAISE EXCEPTION 'client_account_not_found' USING ERRCODE = 'P0001';
  END IF;

  -- Same gates as opening staff preview / managing portal access.
  BEGIN
    PERFORM data.require_fresh_tenant_permission(
      v_tenant, 'field_service.reports.preview_as_customer', NULL::uuid
    );
  EXCEPTION
    WHEN insufficient_privilege THEN
      PERFORM data.require_fresh_tenant_permission(
        v_tenant, 'contacts.portal.manage', NULL::uuid
      );
  END;

  RETURN QUERY
  SELECT
    s.id,
    s.staff_user_id,
    COALESCE(NULLIF(btrim(p.full_name), ''), p.email, s.staff_user_id::text) AS staff_display_name,
    p.email AS staff_email,
    CASE
      WHEN s.report_version_id IS NOT NULL THEN 'report_version'
      ELSE 'client_account'
    END AS scope_mode,
    s.report_version_id,
    s.created_at,
    s.expires_at,
    s.last_seen_at,
    s.revoked_at,
    s.exchanged_at,
    (s.revoked_at IS NULL AND s.expires_at > now()) AS is_active
  FROM data.customer_portal_staff_sessions s
  LEFT JOIN data.profiles p ON p.id = s.staff_user_id
  WHERE s.tenant_id = v_tenant
    AND s.client_account_contact_id = p_client_account_contact_id
  ORDER BY s.created_at DESC
  LIMIT v_lim;
END;
$$;

REVOKE ALL ON FUNCTION api.list_customer_portal_staff_sessions_for_account(uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_customer_portal_staff_sessions_for_account(uuid, integer)
  TO authenticated;

-- Include access_activity on grant list_bulletins (patch from 00035 body).
CREATE OR REPLACE FUNCTION api.resolve_customer_portal_grant_session(
  p_session_token_hash bytea,
  p_action text DEFAULT 'list_bulletins',
  p_report_version_id uuid DEFAULT NULL,
  p_ip_address inet DEFAULT NULL,
  p_user_agent text DEFAULT NULL,
  p_request_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_sess data.customer_portal_grant_sessions%ROWTYPE;
  v_grant data.customer_access_grants%ROWTYPE;
  v_platform data.customer_portal_platform_state%ROWTYPE;
  v_tstate data.customer_portal_tenant_state%ROWTYPE;
  v_version data.customer_intervention_report_versions%ROWTYPE;
  v_action text := COALESCE(NULLIF(btrim(p_action), ''), 'list_bulletins');
  v_bulletins jsonb;
BEGIN
  IF v_action NOT IN ('list_bulletins', 'report_view', 'media_download') THEN
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
      v_sess.tenant_id, v_sess.grant_id, v_sess.id, 'session_denied', 401,
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

  IF v_action = 'list_bulletins' THEN
    v_bulletins := data.list_customer_portal_bulletins_for_grant(v_grant.id);

    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, grant_id, session_id, action, http_status,
      ip_address, user_agent, request_id
    ) VALUES (
      v_sess.tenant_id, v_grant.id, v_sess.id, 'list_bulletins', 200,
      p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
    );

    RETURN jsonb_build_object(
      'ok', true,
      'action', v_action,
      'tenant_id', v_sess.tenant_id,
      'grant_id', v_grant.id,
      'session_id', v_sess.id,
      'expires_at', v_sess.expires_at,
      'actor_type', 'customer',
      'client_account_contact_id', v_grant.client_account_contact_id,
      'principal_kind', v_grant.principal_kind,
      'principal_contact_id', v_grant.principal_contact_id,
      'bulletins', v_bulletins,
      'access_activity', data.customer_portal_account_access_activity(
        v_sess.tenant_id, v_grant.client_account_contact_id
      )
    ) || data.customer_portal_locale_fields(v_sess.tenant_id, v_grant.client_account_contact_id, NULL);
  END IF;

  IF p_report_version_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'code', 'report_version_required');
  END IF;

  SELECT v.* INTO v_version
  FROM data.customer_intervention_report_versions v
  JOIN data.customer_intervention_reports r ON r.id = v.report_id
  WHERE v.id = p_report_version_id
    AND v.tenant_id = v_grant.tenant_id
    AND r.current_published_version_id = v.id
    AND v.customer_account_contact_id = v_grant.client_account_contact_id;

  IF NOT FOUND THEN
    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, grant_id, session_id, report_version_id, action, http_status,
      failure_reason, ip_address, user_agent, request_id
    ) VALUES (
      v_sess.tenant_id, v_grant.id, v_sess.id, p_report_version_id,
      'resolve_denied', 404, 'out_of_scope',
      p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
    );
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  IF p_request_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM data.customer_report_share_access_logs l
    WHERE l.session_id = v_sess.id
      AND l.action = v_action
      AND l.request_id = p_request_id
  ) THEN
    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, grant_id, session_id, report_version_id, action, http_status,
      ip_address, user_agent, request_id
    ) VALUES (
      v_sess.tenant_id, v_grant.id, v_sess.id, v_version.id, v_action, 200,
      p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'action', v_action,
    'tenant_id', v_sess.tenant_id,
    'grant_id', v_grant.id,
    'session_id', v_sess.id,
    'expires_at', v_sess.expires_at,
    'actor_type', 'customer',
    'report_version_id', v_version.id,
    'project_id', v_version.project_id,
    'locale', v_version.locale,
    'content_digest', v_version.content_digest,
    'projection', CASE WHEN v_action = 'report_view' THEN v_version.projection ELSE NULL END,
    'media_manifest', v_version.media_manifest
  ) || data.customer_portal_locale_fields(v_sess.tenant_id, v_grant.client_account_contact_id, v_version.locale);
END;
$$;

REVOKE ALL ON FUNCTION api.resolve_customer_portal_grant_session(bytea, text, uuid, inet, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.resolve_customer_portal_grant_session(bytea, text, uuid, inet, text, text)
  TO service_role;
