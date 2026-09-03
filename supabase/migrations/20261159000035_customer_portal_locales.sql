-- =============================================================================
-- Customer portal locales (ca/es/en)
-- - tenant: supported_locales, default_locale (es), allow_client_locale_change
-- - account preferred_locale via existing contacts.preferred_locale
-- - resolve/entitlements expose locale fields; BFF computes ui_locale
-- =============================================================================

ALTER TABLE data.customer_portal_tenant_state
  ADD COLUMN IF NOT EXISTS supported_locales text[] NOT NULL DEFAULT ARRAY['ca','es','en']::text[],
  ADD COLUMN IF NOT EXISTS default_locale text NOT NULL DEFAULT 'es',
  ADD COLUMN IF NOT EXISTS allow_client_locale_change boolean NOT NULL DEFAULT false;

ALTER TABLE data.customer_portal_tenant_state
  DROP CONSTRAINT IF EXISTS customer_portal_tenant_state_supported_locales_chk;
ALTER TABLE data.customer_portal_tenant_state
  ADD CONSTRAINT customer_portal_tenant_state_supported_locales_chk
  CHECK (
    cardinality(supported_locales) >= 1
    AND supported_locales <@ ARRAY['ca','es','en']::text[]
  );

ALTER TABLE data.customer_portal_tenant_state
  DROP CONSTRAINT IF EXISTS customer_portal_tenant_state_default_locale_chk;
ALTER TABLE data.customer_portal_tenant_state
  ADD CONSTRAINT customer_portal_tenant_state_default_locale_chk
  CHECK (default_locale = ANY (supported_locales));

CREATE OR REPLACE FUNCTION data.customer_portal_locale_fields(
  p_tenant_id uuid,
  p_account_contact_id uuid,
  p_content_locale text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tstate data.customer_portal_tenant_state%ROWTYPE;
  v_preferred text;
BEGIN
  v_tstate := data.ensure_customer_portal_tenant_state(p_tenant_id);

  IF p_account_contact_id IS NOT NULL THEN
    SELECT c.preferred_locale INTO v_preferred
    FROM data.contacts c
    WHERE c.id = p_account_contact_id
      AND c.tenant_id = p_tenant_id;
  END IF;

  RETURN jsonb_build_object(
    'preferred_locale', v_preferred,
    'supported_locales', to_jsonb(v_tstate.supported_locales),
    'default_locale', v_tstate.default_locale,
    'allow_client_locale_change', v_tstate.allow_client_locale_change,
    'content_locale', NULLIF(btrim(COALESCE(p_content_locale, '')), '')
  );
END;
$$;

REVOKE ALL ON FUNCTION data.customer_portal_locale_fields(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.customer_portal_locale_fields(uuid, uuid, text)
  TO service_role;

CREATE OR REPLACE FUNCTION api.set_my_customer_portal_locales(
  p_supported_locales text[] DEFAULT NULL,
  p_default_locale text DEFAULT NULL,
  p_allow_client_locale_change boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_supported text[];
  v_default text;
  v_allow boolean;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  PERFORM data.require_fresh_tenant_permission(v_tenant, 'settings.manage', NULL);
  PERFORM data.ensure_customer_portal_tenant_state(v_tenant);

  SELECT s.supported_locales, s.default_locale, s.allow_client_locale_change
    INTO v_supported, v_default, v_allow
  FROM data.customer_portal_tenant_state s
  WHERE s.tenant_id = v_tenant;

  IF p_supported_locales IS NOT NULL THEN
    SELECT COALESCE(array_agg(DISTINCT x ORDER BY x), ARRAY[]::text[])
      INTO v_supported
    FROM unnest(p_supported_locales) AS x
    WHERE x IN ('ca', 'es', 'en');

    IF cardinality(v_supported) < 1 THEN
      RAISE EXCEPTION 'supported_locales_required' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  v_default := COALESCE(NULLIF(btrim(COALESCE(p_default_locale, '')), ''), v_default, 'es');
  IF NOT (v_default = ANY (v_supported)) THEN
    RAISE EXCEPTION 'default_locale_not_supported' USING ERRCODE = 'P0001';
  END IF;

  IF p_allow_client_locale_change IS NOT NULL THEN
    v_allow := p_allow_client_locale_change;
  END IF;

  UPDATE data.customer_portal_tenant_state
  SET
    supported_locales = v_supported,
    default_locale = v_default,
    allow_client_locale_change = v_allow,
    updated_at = now()
  WHERE tenant_id = v_tenant;

  PERFORM data.log_audit_event_strict(
    v_tenant, auth.uid(), NULL,
    'CUSTOMER_PORTAL_LOCALES_UPDATED',
    'customer_portal_tenant_state', v_tenant,
    jsonb_build_object(
      'supported_locales', to_jsonb(v_supported),
      'default_locale', v_default,
      'allow_client_locale_change', v_allow
    )
  );

  RETURN (SELECT to_jsonb(s) FROM data.customer_portal_tenant_state s WHERE tenant_id = v_tenant);
END;
$$;

REVOKE ALL ON FUNCTION api.set_my_customer_portal_locales(text[], text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_my_customer_portal_locales(text[], text, boolean)
  TO authenticated;

CREATE OR REPLACE FUNCTION api.set_customer_portal_account_locale(
  p_tenant_id uuid,
  p_account_contact_id uuid,
  p_locale text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tstate data.customer_portal_tenant_state%ROWTYPE;
  v_locale text := lower(btrim(COALESCE(p_locale, '')));
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_tenant_id IS NULL OR p_account_contact_id IS NULL THEN
    RAISE EXCEPTION 'account_required' USING ERRCODE = 'P0001';
  END IF;

  IF v_locale NOT IN ('ca', 'es', 'en') THEN
    RAISE EXCEPTION 'invalid_locale' USING ERRCODE = 'P0001';
  END IF;

  v_tstate := data.ensure_customer_portal_tenant_state(p_tenant_id);

  IF NOT v_tstate.allow_client_locale_change THEN
    RAISE EXCEPTION 'client_locale_change_not_allowed' USING ERRCODE = 'P0001';
  END IF;

  IF NOT (v_locale = ANY (v_tstate.supported_locales)) THEN
    RAISE EXCEPTION 'locale_not_supported' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.contacts c
  SET preferred_locale = v_locale, updated_at = now()
  WHERE c.id = p_account_contact_id
    AND c.tenant_id = p_tenant_id
    AND c.is_archived = false;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'account_not_found' USING ERRCODE = 'P0001';
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'account_contact_id', p_account_contact_id,
    'preferred_locale', v_locale
  ) || data.customer_portal_locale_fields(p_tenant_id, p_account_contact_id, NULL);
END;
$$;

REVOKE ALL ON FUNCTION api.set_customer_portal_account_locale(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_customer_portal_account_locale(uuid, uuid, text)
  TO service_role;

-- =============================================================================
-- Locale patches: entitlements + share/grant/staff session resolve payloads
-- =============================================================================

CREATE OR REPLACE FUNCTION data.resolve_portal_entitlements(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant           data.tenants%ROWTYPE;
  v_plan_ent         jsonb;
  v_snapshot         jsonb;
  v_granted          jsonb;
  v_emp_granted      jsonb;
  v_pub_granted      jsonb;
  v_emp_plan         jsonb;
  v_pub_plan         jsonb;
  v_pages_by_site    jsonb;
  v_plan_max_pages   integer;
  v_cp_plan          jsonb;
  v_cp_granted       jsonb;
  v_platform         data.customer_portal_platform_state%ROWTYPE;
  v_tstate           data.customer_portal_tenant_state%ROWTYPE;
  v_cp_included      boolean;
  v_cp_mode_plan     text;
  v_cp_mode_granted  text;
  v_mode_effective   text;
  v_enabled_tenant   boolean;
  v_effective        boolean;
  v_can_shares       boolean;
  v_can_grants       boolean;
BEGIN
  SELECT * INTO v_tenant FROM data.tenants t WHERE t.id = p_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'tenant_not_found:%', p_tenant_id USING ERRCODE = 'P0001';
  END IF;

  v_plan_ent := data.plan_portal_entitlements(v_tenant.plan_id);
  v_plan_max_pages := data.plan_public_max_pages(v_tenant.plan_id, v_plan_ent);

  v_emp_plan := jsonb_build_object(
    'included', COALESCE((v_plan_ent->'employee_portal'->>'included')::boolean, false),
    'cms_tier', COALESCE(v_plan_ent->'employee_portal'->>'cms_tier', 'none')
  );
  v_pub_plan := jsonb_build_object(
    'included', COALESCE((v_plan_ent->'public_portal'->>'included')::boolean, false),
    'cms_tier', COALESCE(v_plan_ent->'public_portal'->>'cms_tier', 'none'),
    'max_pages', v_plan_max_pages
  );
  v_cp_plan := data.merge_customer_portal_entitlements(v_plan_ent->'customer_portal');

  v_snapshot := COALESCE(NULLIF(v_tenant.tenant_portal_entitlements, '{}'::jsonb), NULL);
  IF v_snapshot IS NULL THEN
    v_snapshot := data.tenant_portal_entitlements_from_plan(v_tenant.plan_id);
  END IF;

  -- Legacy overrides remain additive for employee/public cms_tier only (grandfathered)
  IF v_tenant.tenant_portal_overrides->'employee_portal'->>'cms_tier' IS NOT NULL THEN
    v_snapshot := jsonb_set(
      v_snapshot,
      '{employee_portal,cms_tier}',
      to_jsonb(data.max_portal_cms_tier(
        v_snapshot->'employee_portal'->>'cms_tier',
        v_tenant.tenant_portal_overrides->'employee_portal'->>'cms_tier'
      )),
      true
    );
  END IF;
  IF v_tenant.tenant_portal_overrides->'public_portal'->>'cms_tier' IS NOT NULL THEN
    v_snapshot := jsonb_set(
      v_snapshot,
      '{public_portal,cms_tier}',
      to_jsonb(data.max_portal_cms_tier(
        v_snapshot->'public_portal'->>'cms_tier',
        v_tenant.tenant_portal_overrides->'public_portal'->>'cms_tier'
      )),
      true
    );
  END IF;
  IF v_tenant.tenant_portal_overrides ? 'customer_portal' THEN
    v_snapshot := jsonb_set(
      v_snapshot,
      '{customer_portal}',
      data.merge_customer_portal_channel_up(
        v_snapshot->'customer_portal',
        v_tenant.tenant_portal_overrides->'customer_portal'
      ),
      true
    );
  END IF;

  v_granted := jsonb_build_object(
    'employee_portal', jsonb_build_object(
      'included', COALESCE((v_snapshot->'employee_portal'->>'included')::boolean, false),
      'cms_tier', data.max_portal_cms_tier(
        COALESCE(v_snapshot->'employee_portal'->>'cms_tier', 'none'),
        COALESCE(v_emp_plan->>'cms_tier', 'none')
      )
    ),
    'public_portal', jsonb_build_object(
      'included', COALESCE((v_snapshot->'public_portal'->>'included')::boolean, false),
      'cms_tier', data.max_portal_cms_tier(
        COALESCE(v_snapshot->'public_portal'->>'cms_tier', 'none'),
        COALESCE(v_pub_plan->>'cms_tier', 'none')
      ),
      'max_pages', data.merge_portal_max_pages(
        COALESCE((v_snapshot->'public_portal'->>'max_pages')::integer, 0),
        v_plan_max_pages
      )
    ),
    'customer_portal', data.merge_customer_portal_channel_up(
      v_snapshot->'customer_portal',
      v_cp_plan
    )
  );

  v_emp_granted := v_granted->'employee_portal';
  v_pub_granted := v_granted->'public_portal';
  v_cp_granted := v_granted->'customer_portal';

  SELECT COALESCE(
    jsonb_object_agg(ps.id::text, COALESCE(cnt.c, 0)),
    '{}'::jsonb
  )
  INTO v_pages_by_site
  FROM data.public_sites ps
  LEFT JOIN (
    SELECT pp.public_site_id, COUNT(*)::integer AS c
      FROM data.public_pages pp
     WHERE pp.tenant_id = p_tenant_id
     GROUP BY pp.public_site_id
  ) cnt ON cnt.public_site_id = ps.id
  WHERE ps.tenant_id = p_tenant_id;

  SELECT * INTO v_platform FROM data.customer_portal_platform_state WHERE id;
  -- Read-only: never INSERT here (PostgREST GET uses READ ONLY txn)
  v_tstate := data.peek_customer_portal_tenant_state(p_tenant_id);

  v_cp_included := COALESCE((v_cp_granted->>'included')::boolean, false);
  v_cp_mode_plan := COALESCE(v_cp_plan->>'mode', 'share_only');
  IF v_cp_mode_plan NOT IN ('share_only', 'portal') THEN
    v_cp_mode_plan := 'share_only';
  END IF;
  v_cp_mode_granted := COALESCE(v_cp_granted->>'mode', 'share_only');
  IF v_cp_mode_granted NOT IN ('share_only', 'portal') THEN
    v_cp_mode_granted := 'share_only';
  END IF;

  IF v_platform.max_mode = 'share_only' AND v_cp_mode_granted = 'portal' THEN
    v_mode_effective := 'share_only';
  ELSE
    v_mode_effective := v_cp_mode_granted;
  END IF;

  v_enabled_tenant := v_tstate.enabled AND v_platform.enabled;
  v_effective := v_cp_included AND v_enabled_tenant;
  v_can_shares := v_effective
    AND v_tstate.new_share_policy = 'allow'
    AND v_mode_effective IN ('share_only', 'portal');
  v_can_grants := v_effective
    AND v_tstate.new_access_policy = 'allow'
    AND v_mode_effective = 'portal'
    AND v_platform.max_mode = 'portal';

  RETURN jsonb_build_object(
    'tenant_id', p_tenant_id,
    'tenant_portal_entitlements', v_snapshot,
    'employee_portal', jsonb_build_object(
      'included_granted', COALESCE((v_emp_granted->>'included')::boolean, false),
      'included_plan', COALESCE((v_emp_plan->>'included')::boolean, false),
      'included_by_plan', COALESCE((v_emp_granted->>'included')::boolean, false),
      'enabled_by_tenant', v_tenant.employee_portal_enabled,
      'effective', COALESCE((v_emp_granted->>'included')::boolean, false)
                   AND v_tenant.employee_portal_enabled,
      'cms_tier', CASE
        WHEN COALESCE((v_emp_granted->>'included')::boolean, false)
        THEN COALESCE(v_emp_granted->>'cms_tier', 'none')
        ELSE 'none'
      END,
      'cms_tier_granted', COALESCE(v_emp_granted->>'cms_tier', 'none'),
      'cms_tier_plan', COALESCE(v_emp_plan->>'cms_tier', 'none')
    ),
    'public_portal', jsonb_build_object(
      'included_granted', COALESCE((v_pub_granted->>'included')::boolean, false),
      'included_plan', COALESCE((v_pub_plan->>'included')::boolean, false),
      'included_by_plan', COALESCE((v_pub_granted->>'included')::boolean, false),
      'enabled_by_tenant', v_tenant.public_portal_enabled,
      'effective', COALESCE((v_pub_granted->>'included')::boolean, false)
                   AND v_tenant.public_portal_enabled,
      'cms_tier', CASE
        WHEN COALESCE((v_pub_granted->>'included')::boolean, false)
        THEN COALESCE(v_pub_granted->>'cms_tier', 'none')
        ELSE 'none'
      END,
      'cms_tier_granted', COALESCE(v_pub_granted->>'cms_tier', 'none'),
      'cms_tier_plan', COALESCE(v_pub_plan->>'cms_tier', 'none'),
      'max_pages', COALESCE((v_pub_granted->>'max_pages')::integer, 0),
      'max_pages_granted', COALESCE((v_pub_granted->>'max_pages')::integer, 0),
      'max_pages_plan', v_plan_max_pages,
      'pages_used_by_site', COALESCE(v_pages_by_site, '{}'::jsonb)
    ),
    'customer_portal', jsonb_build_object(
      'included_granted', v_cp_included,
      'included_plan', COALESCE((v_cp_plan->>'included')::boolean, false),
      'enabled_by_tenant', v_tstate.enabled,
      'enabled_by_platform', v_platform.enabled,
      'effective', v_effective,
      'mode_granted', v_cp_mode_granted,
      'mode_plan', v_cp_mode_plan,
      'mode_effective', v_mode_effective,
      'platform_max_mode', v_platform.max_mode,
      'can_create_shares', v_can_shares,
      'can_grant_portal_access', v_can_grants,
      'customer_users_limit', v_cp_granted->'customer_users_limit',
      'active_share_guardrail', COALESCE((v_cp_granted->>'active_share_guardrail')::int, 500),
      'customer_mau_alert_threshold', COALESCE((v_cp_granted->>'customer_mau_alert_threshold')::int, 1000),
      'included_email_deliveries_month', COALESCE((v_cp_granted->>'included_email_deliveries_month')::int, 2000),
      'security_version_tenant', v_tstate.security_version,
      'security_version_platform', v_platform.security_version,
      'new_share_policy', v_tstate.new_share_policy,
      'new_access_policy', v_tstate.new_access_policy,
      'existing_access_policy', v_tstate.existing_access_policy,
      'restriction_reason', v_tstate.restriction_reason,
      'restriction_note', v_tstate.restriction_note,
      'bulletin_bcc_emails', to_jsonb(v_tstate.bulletin_bcc_emails),
      'supported_locales', to_jsonb(v_tstate.supported_locales),
      'default_locale', v_tstate.default_locale,
      'allow_client_locale_change', v_tstate.allow_client_locale_change
    )
  );
END;
$$;


GRANT EXECUTE ON FUNCTION data.resolve_portal_entitlements(uuid) TO prisma_admin, service_role, authenticated;

CREATE OR REPLACE FUNCTION api.resolve_customer_portal_share_session(
  p_session_token_hash bytea,
  p_action text DEFAULT 'report_view',
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
  v_sess data.customer_portal_share_sessions%ROWTYPE;
  v_share data.customer_report_shares%ROWTYPE;
  v_platform data.customer_portal_platform_state%ROWTYPE;
  v_tstate data.customer_portal_tenant_state%ROWTYPE;
  v_version data.customer_intervention_report_versions%ROWTYPE;
BEGIN
  IF p_session_token_hash IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  SELECT * INTO v_sess
  FROM data.customer_portal_share_sessions
  WHERE session_token_hash = p_session_token_hash
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  SELECT * INTO v_share FROM data.customer_report_shares WHERE id = v_sess.share_id;
  SELECT * INTO v_platform FROM data.customer_portal_platform_state WHERE id;
  v_tstate := data.ensure_customer_portal_tenant_state(v_sess.tenant_id);

  IF v_sess.revoked_at IS NOT NULL
     OR v_sess.expires_at <= now()
     OR v_share.revoked_at IS NOT NULL
     OR v_share.expires_at <= now()
     OR NOT v_platform.enabled
     OR NOT v_tstate.enabled
     OR v_sess.share_session_version IS DISTINCT FROM v_share.session_version
     OR v_sess.security_version_tenant IS DISTINCT FROM v_tstate.security_version
     OR v_sess.security_version_platform IS DISTINCT FROM v_platform.security_version
  THEN
    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, share_id, session_id, report_version_id, action, http_status,
      failure_reason, ip_address, user_agent, request_id
    ) VALUES (
      v_sess.tenant_id, v_sess.share_id, v_sess.id, v_sess.report_version_id,
      'session_denied', 401, 'session_invalid', p_ip_address,
      left(COALESCE(p_user_agent, ''), 512), p_request_id
    );
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  IF v_share.max_views IS NOT NULL AND v_share.view_count >= v_share.max_views
     AND COALESCE(p_action, 'report_view') = 'report_view' THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  SELECT * INTO v_version
  FROM data.customer_intervention_report_versions
  WHERE id = v_sess.report_version_id;

  UPDATE data.customer_portal_share_sessions
  SET last_seen_at = now()
  WHERE id = v_sess.id;

  IF COALESCE(p_action, 'report_view') = 'report_view' THEN
    -- Idempotent view log by request_id when provided
    IF p_request_id IS NULL OR NOT EXISTS (
      SELECT 1 FROM data.customer_report_share_access_logs l
      WHERE l.session_id = v_sess.id
        AND l.action = 'report_view'
        AND l.request_id = p_request_id
    ) THEN
      INSERT INTO data.customer_report_share_access_logs (
        tenant_id, share_id, session_id, report_version_id, action, http_status,
        ip_address, user_agent, request_id
      ) VALUES (
        v_sess.tenant_id, v_sess.share_id, v_sess.id, v_sess.report_version_id,
        'report_view', 200, p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
      );
      UPDATE data.customer_report_shares
      SET view_count = view_count + 1
      WHERE id = v_share.id;
    END IF;
  ELSIF p_action = 'media_download' THEN
    IF p_request_id IS NULL OR NOT EXISTS (
      SELECT 1 FROM data.customer_report_share_access_logs l
      WHERE l.session_id = v_sess.id
        AND l.action = 'media_download'
        AND l.request_id = p_request_id
    ) THEN
      INSERT INTO data.customer_report_share_access_logs (
        tenant_id, share_id, session_id, report_version_id, action, http_status,
        ip_address, user_agent, request_id
      ) VALUES (
        v_sess.tenant_id, v_sess.share_id, v_sess.id, v_sess.report_version_id,
        'media_download', 200, p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'tenant_id', v_sess.tenant_id,
    'share_id', v_share.id,
    'session_id', v_sess.id,
    'report_version_id', v_version.id,
    'projection', v_version.projection,
    'media_manifest', v_version.media_manifest,
    'locale', v_version.locale,
    'content_digest', v_version.content_digest,
    'client_account_contact_id', v_share.customer_account_contact_id
  ) || data.customer_portal_locale_fields(v_sess.tenant_id, v_share.customer_account_contact_id, v_version.locale);
END;
$$;

REVOKE ALL ON FUNCTION api.resolve_customer_portal_share_session(bytea, text, inet, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.resolve_customer_portal_share_session(bytea, text, inet, text, text)
  TO service_role;

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
      'bulletins', v_bulletins
    ) || data.customer_portal_locale_fields(v_sess.tenant_id, v_grant.client_account_contact_id, NULL);
  END IF;

  IF p_report_version_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'code', 'report_version_required');
  END IF;

  -- Scope: only versions currently published to this grant's client account.
  -- There is no per-version recipient column, so account is the only key.
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

  -- Idempotent per request_id so retries do not inflate the ledger.
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

CREATE OR REPLACE FUNCTION api.exchange_customer_portal_staff_session(
  p_token_hash bytea,
  p_ip_address inet DEFAULT NULL,
  p_user_agent text DEFAULT NULL,
  p_report_version_id uuid DEFAULT NULL,
  p_allow_handoff_consume boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public, extensions
AS $$
DECLARE
  v_sess data.customer_portal_staff_sessions%ROWTYPE;
  v_platform data.customer_portal_platform_state%ROWTYPE;
  v_tstate data.customer_portal_tenant_state%ROWTYPE;
  v_version data.customer_intervention_report_versions%ROWTYPE;
  v_report data.customer_intervention_reports%ROWTYPE;
  v_secret text;
  v_new_hash bytea;
BEGIN
  IF p_token_hash IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  SELECT * INTO v_sess
  FROM data.customer_portal_staff_sessions
  WHERE session_token_hash = p_token_hash
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  SELECT * INTO v_platform FROM data.customer_portal_platform_state WHERE id;
  v_tstate := data.ensure_customer_portal_tenant_state(v_sess.tenant_id);

  IF v_sess.revoked_at IS NOT NULL
     OR v_sess.expires_at <= now()
     OR NOT v_platform.enabled
     OR NOT v_tstate.enabled
     OR v_sess.security_version_tenant IS DISTINCT FROM v_tstate.security_version
     OR v_sess.security_version_platform IS DISTINCT FROM v_platform.security_version
  THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  -- Unconsumed URL handoff: only POST consume may rotate; media/resolve must not burn it.
  IF v_sess.exchanged_at IS NULL THEN
    IF NOT COALESCE(p_allow_handoff_consume, true) THEN
      RETURN jsonb_build_object('ok', false, 'code', 'handoff_not_consumed');
    END IF;

    v_secret := encode(gen_random_bytes(32), 'hex');
    v_new_hash := data.hash_customer_portal_secret(v_secret);

    UPDATE data.customer_portal_staff_sessions
    SET
      session_token_hash = v_new_hash,
      exchanged_at = now(),
      last_seen_at = now()
    WHERE id = v_sess.id;

    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, share_id, session_id, report_version_id, action, http_status,
      ip_address, user_agent
    ) VALUES (
      v_sess.tenant_id, NULL, v_sess.id, v_sess.report_version_id,
      'handoff_consumed', 200, p_ip_address, left(COALESCE(p_user_agent, ''), 512)
    );

    RETURN jsonb_build_object(
      'ok', true,
      'consumed', true,
      'actor_type', 'staff',
      'session_secret', v_secret,
      'session_id', v_sess.id,
      'staff_user_id', v_sess.staff_user_id,
      'tenant_id', v_sess.tenant_id,
      'expires_at', v_sess.expires_at,
      'scope_mode', CASE
        WHEN v_sess.report_version_id IS NOT NULL THEN 'report_version'
        ELSE 'client_account'
      END,
      'report_version_id', v_sess.report_version_id,
      'client_account_contact_id', v_sess.client_account_contact_id,
      'requires_report_version_id', v_sess.report_version_id IS NULL
    ) || data.customer_portal_locale_fields(v_sess.tenant_id, v_sess.client_account_contact_id, NULL);
  END IF;

  UPDATE data.customer_portal_staff_sessions
  SET last_seen_at = now()
  WHERE id = v_sess.id;

  IF v_sess.report_version_id IS NOT NULL THEN
    SELECT * INTO v_version
    FROM data.customer_intervention_report_versions
    WHERE id = v_sess.report_version_id;

    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, share_id, session_id, report_version_id, action, http_status,
      ip_address, user_agent
    ) VALUES (
      v_sess.tenant_id, NULL, v_sess.id, v_sess.report_version_id,
      'report_view', 200, p_ip_address, left(COALESCE(p_user_agent, ''), 512)
    );

    RETURN jsonb_build_object(
      'ok', true,
      'consumed', false,
      'actor_type', 'staff',
      'scope_mode', 'report_version',
      'staff_user_id', v_sess.staff_user_id,
      'session_id', v_sess.id,
      'tenant_id', v_sess.tenant_id,
      'report_version_id', v_version.id,
      'expires_at', v_sess.expires_at,
      'locale', v_version.locale,
      'content_digest', v_version.content_digest,
      'projection', v_version.projection,
      'media_manifest', v_version.media_manifest
    ) || data.customer_portal_locale_fields(
      v_sess.tenant_id,
      COALESCE(v_sess.client_account_contact_id, v_version.customer_account_contact_id),
      v_version.locale
    );
  END IF;

  IF p_report_version_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'consumed', false,
      'actor_type', 'staff',
      'scope_mode', 'client_account',
      'staff_user_id', v_sess.staff_user_id,
      'session_id', v_sess.id,
      'tenant_id', v_sess.tenant_id,
      'client_account_contact_id', v_sess.client_account_contact_id,
      'expires_at', v_sess.expires_at,
      'requires_report_version_id', true,
      'bulletins', COALESCE((
        SELECT jsonb_agg(b ORDER BY b->>'published_at' DESC)
        FROM (
          SELECT jsonb_build_object(
            'report_version_id', v.id,
            'report_id', v.report_id,
            'project_id', v.project_id,
            'version_number', v.version_number,
            'content_digest', v.content_digest,
            'locale', v.locale,
            'published_at', v.published_at,
            'title', COALESCE(
              NULLIF(btrim(COALESCE(v.projection->'intervention'->>'title', '')), ''),
              p.name
            ),
            'media_count', CASE
              WHEN jsonb_typeof(v.media_manifest) = 'array'
              THEN jsonb_array_length(v.media_manifest)
              ELSE 0
            END
          ) AS b
          FROM data.customer_intervention_report_versions v
          JOIN data.customer_intervention_reports r
            ON r.id = v.report_id
           AND r.current_published_version_id = v.id
          LEFT JOIN data.projects p ON p.id = v.project_id
          WHERE v.tenant_id = v_sess.tenant_id
            AND v.customer_account_contact_id = v_sess.client_account_contact_id
          ORDER BY v.published_at DESC
          LIMIT 200
        ) s
      ), '[]'::jsonb)
    ) || data.customer_portal_locale_fields(v_sess.tenant_id, v_sess.client_account_contact_id, NULL);
  END IF;

  SELECT * INTO v_version
  FROM data.customer_intervention_report_versions v
  WHERE v.id = p_report_version_id
    AND v.tenant_id = v_sess.tenant_id
    AND v.customer_account_contact_id = v_sess.client_account_contact_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'code', 'version_out_of_scope');
  END IF;

  SELECT * INTO v_report
  FROM data.customer_intervention_reports r
  WHERE r.id = v_version.report_id
    AND r.current_published_version_id = v_version.id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'code', 'version_not_current');
  END IF;

  INSERT INTO data.customer_report_share_access_logs (
    tenant_id, share_id, session_id, report_version_id, action, http_status,
    ip_address, user_agent
  ) VALUES (
    v_sess.tenant_id, NULL, v_sess.id, v_version.id,
    'report_view', 200, p_ip_address, left(COALESCE(p_user_agent, ''), 512)
  );

  RETURN jsonb_build_object(
    'ok', true,
    'consumed', false,
    'actor_type', 'staff',
    'scope_mode', 'client_account',
    'staff_user_id', v_sess.staff_user_id,
    'session_id', v_sess.id,
    'tenant_id', v_sess.tenant_id,
    'client_account_contact_id', v_sess.client_account_contact_id,
    'report_version_id', v_version.id,
    'expires_at', v_sess.expires_at,
    'locale', v_version.locale,
    'content_digest', v_version.content_digest,
    'projection', v_version.projection,
    'media_manifest', v_version.media_manifest
  ) || data.customer_portal_locale_fields(
    v_sess.tenant_id,
    COALESCE(v_sess.client_account_contact_id, v_version.customer_account_contact_id),
    v_version.locale
  );
END;
$$;

REVOKE ALL ON FUNCTION api.exchange_customer_portal_staff_session(bytea, inet, text, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.exchange_customer_portal_staff_session(bytea, inet, text, uuid, boolean)
  TO service_role;

-- Virtual peek defaults must include locale columns (GET-safe, no INSERT).
CREATE OR REPLACE FUNCTION data.peek_customer_portal_tenant_state(p_tenant_id uuid)
RETURNS data.customer_portal_tenant_state
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_row data.customer_portal_tenant_state%ROWTYPE;
BEGIN
  SELECT * INTO v_row
  FROM data.customer_portal_tenant_state
  WHERE tenant_id = p_tenant_id;

  IF FOUND THEN
    RETURN v_row;
  END IF;

  v_row.tenant_id := p_tenant_id;
  v_row.enabled := true;
  v_row.new_access_policy := 'allow';
  v_row.new_share_policy := 'allow';
  v_row.existing_access_policy := 'allow';
  v_row.restriction_reason := NULL;
  v_row.restriction_note := NULL;
  v_row.restricted_at := NULL;
  v_row.restricted_by := NULL;
  v_row.review_at := NULL;
  v_row.security_version := 1;
  v_row.bulletin_bcc_emails := NULL;
  v_row.supported_locales := ARRAY['ca', 'es', 'en']::text[];
  v_row.default_locale := 'es';
  v_row.allow_client_locale_change := false;
  v_row.updated_at := now();
  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION data.peek_customer_portal_tenant_state(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.peek_customer_portal_tenant_state(uuid)
  TO authenticated, service_role, prisma_admin;
