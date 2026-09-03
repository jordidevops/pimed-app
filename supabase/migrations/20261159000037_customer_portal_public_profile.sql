-- =============================================================================
-- Customer portal public profile (footer / Art.13 contact) + settings RPC
-- =============================================================================

ALTER TABLE data.customer_portal_tenant_state
  ADD COLUMN IF NOT EXISTS public_display_name text,
  ADD COLUMN IF NOT EXISTS public_support_email text,
  ADD COLUMN IF NOT EXISTS public_support_phone text,
  ADD COLUMN IF NOT EXISTS public_address text,
  ADD COLUMN IF NOT EXISTS public_website_url text,
  ADD COLUMN IF NOT EXISTS public_privacy_url text;

COMMENT ON COLUMN data.customer_portal_tenant_state.public_display_name IS
  'Customer-portal footer / branding. NULL = inherit tenant.name';
COMMENT ON COLUMN data.customer_portal_tenant_state.public_support_email IS
  'Support email shown to clients. NULL = inherit site email_reply_to';
COMMENT ON COLUMN data.customer_portal_tenant_state.public_address IS
  'Postal address shown to clients. NULL = inherit primary site address';

CREATE OR REPLACE FUNCTION data.customer_portal_org_defaults(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_name text;
  v_email text;
  v_address text;
  v_site record;
BEGIN
  SELECT t.name INTO v_name FROM data.tenants t WHERE t.id = p_tenant_id;

  SELECT s.email_reply_to, s.email_from_name, s.street, s.street_number,
         s.postal_code, s.city, s.province, s.country_code, s.address
    INTO v_site
  FROM data.sites s
  WHERE s.tenant_id = p_tenant_id
    AND COALESCE(s.is_active, true) = true
  ORDER BY s.created_at ASC
  LIMIT 1;

  IF FOUND THEN
    v_email := NULLIF(btrim(COALESCE(v_site.email_reply_to, '')), '');
    v_address := NULLIF(btrim(COALESCE(
      NULLIF(btrim(COALESCE(v_site.address, '')), ''),
      concat_ws(
        ', ',
        NULLIF(btrim(concat_ws(' ', v_site.street, v_site.street_number)), ''),
        NULLIF(btrim(concat_ws(' ', v_site.postal_code, v_site.city)), ''),
        NULLIF(btrim(COALESCE(v_site.province, '')), ''),
        NULLIF(btrim(COALESCE(v_site.country_code, '')), '')
      )
    )), '');
  END IF;

  RETURN jsonb_build_object(
    'display_name', NULLIF(btrim(COALESCE(v_name, '')), ''),
    'support_email', v_email,
    'support_phone', NULL,
    'address', v_address,
    'website_url', NULL,
    'privacy_url', NULL
  );
END;
$$;

REVOKE ALL ON FUNCTION data.customer_portal_org_defaults(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.customer_portal_org_defaults(uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.customer_portal_public_profile(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tstate data.customer_portal_tenant_state%ROWTYPE;
  v_defaults jsonb;
BEGIN
  v_tstate := data.peek_customer_portal_tenant_state(p_tenant_id);
  v_defaults := data.customer_portal_org_defaults(p_tenant_id);

  RETURN jsonb_build_object(
    'display_name', COALESCE(
      NULLIF(btrim(COALESCE(v_tstate.public_display_name, '')), ''),
      v_defaults->>'display_name'
    ),
    'support_email', COALESCE(
      NULLIF(btrim(COALESCE(v_tstate.public_support_email, '')), ''),
      v_defaults->>'support_email'
    ),
    'support_phone', COALESCE(
      NULLIF(btrim(COALESCE(v_tstate.public_support_phone, '')), ''),
      v_defaults->>'support_phone'
    ),
    'address', COALESCE(
      NULLIF(btrim(COALESCE(v_tstate.public_address, '')), ''),
      v_defaults->>'address'
    ),
    'website_url', COALESCE(
      NULLIF(btrim(COALESCE(v_tstate.public_website_url, '')), ''),
      v_defaults->>'website_url'
    ),
    'privacy_url', COALESCE(
      NULLIF(btrim(COALESCE(v_tstate.public_privacy_url, '')), ''),
      v_defaults->>'privacy_url'
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION data.customer_portal_public_profile(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.customer_portal_public_profile(uuid)
  TO authenticated, service_role;

-- Expose tenant_profile on every resolve that already merges locale fields.
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

  v_preferred := NULL;
  IF p_account_contact_id IS NOT NULL THEN
    SELECT c.preferred_locale INTO v_preferred
    FROM data.contacts c
    WHERE c.id = p_account_contact_id AND c.tenant_id = p_tenant_id;
  END IF;

  RETURN jsonb_build_object(
    'preferred_locale', v_preferred,
    'supported_locales', to_jsonb(v_tstate.supported_locales),
    'default_locale', v_tstate.default_locale,
    'allow_client_locale_change', v_tstate.allow_client_locale_change,
    'content_locale', p_content_locale,
    'tenant_profile', data.customer_portal_public_profile(p_tenant_id)
  );
END;
$$;

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
  v_profile jsonb;
  v_principals jsonb;
  v_support jsonb;
BEGIN
  IF p_tenant_id IS NULL OR p_account_contact_id IS NULL THEN
    RETURN jsonb_build_object(
      'tenant_display_name', NULL,
      'tenant_profile', '{}'::jsonb,
      'principals', '[]'::jsonb,
      'support_sessions', '[]'::jsonb
    );
  END IF;

  v_profile := data.customer_portal_public_profile(p_tenant_id);

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
    'tenant_display_name', v_profile->>'display_name',
    'tenant_profile', v_profile,
    'principals', v_principals,
    'support_sessions', v_support
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.get_my_customer_portal_public_profile()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_tstate data.customer_portal_tenant_state%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  PERFORM data.require_fresh_tenant_permission(v_tenant, 'settings.manage', NULL);
  v_tstate := data.ensure_customer_portal_tenant_state(v_tenant);

  RETURN jsonb_build_object(
    'stored', jsonb_build_object(
      'display_name', v_tstate.public_display_name,
      'support_email', v_tstate.public_support_email,
      'support_phone', v_tstate.public_support_phone,
      'address', v_tstate.public_address,
      'website_url', v_tstate.public_website_url,
      'privacy_url', v_tstate.public_privacy_url
    ),
    'defaults', data.customer_portal_org_defaults(v_tenant),
    'effective', data.customer_portal_public_profile(v_tenant)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_my_customer_portal_public_profile() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_my_customer_portal_public_profile() TO authenticated;

CREATE OR REPLACE FUNCTION api.set_my_customer_portal_public_profile(
  p_display_name text DEFAULT NULL,
  p_support_email text DEFAULT NULL,
  p_support_phone text DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_website_url text DEFAULT NULL,
  p_privacy_url text DEFAULT NULL,
  p_clear_unset boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  PERFORM data.require_fresh_tenant_permission(v_tenant, 'settings.manage', NULL);
  PERFORM data.ensure_customer_portal_tenant_state(v_tenant);

  UPDATE data.customer_portal_tenant_state
  SET
    public_display_name = CASE
      WHEN p_clear_unset AND p_display_name IS NULL THEN NULL
      WHEN p_display_name IS NOT NULL THEN NULLIF(btrim(p_display_name), '')
      ELSE public_display_name
    END,
    public_support_email = CASE
      WHEN p_clear_unset AND p_support_email IS NULL THEN NULL
      WHEN p_support_email IS NOT NULL THEN NULLIF(btrim(lower(p_support_email)), '')
      ELSE public_support_email
    END,
    public_support_phone = CASE
      WHEN p_clear_unset AND p_support_phone IS NULL THEN NULL
      WHEN p_support_phone IS NOT NULL THEN NULLIF(btrim(p_support_phone), '')
      ELSE public_support_phone
    END,
    public_address = CASE
      WHEN p_clear_unset AND p_address IS NULL THEN NULL
      WHEN p_address IS NOT NULL THEN NULLIF(btrim(p_address), '')
      ELSE public_address
    END,
    public_website_url = CASE
      WHEN p_clear_unset AND p_website_url IS NULL THEN NULL
      WHEN p_website_url IS NOT NULL THEN NULLIF(btrim(p_website_url), '')
      ELSE public_website_url
    END,
    public_privacy_url = CASE
      WHEN p_clear_unset AND p_privacy_url IS NULL THEN NULL
      WHEN p_privacy_url IS NOT NULL THEN NULLIF(btrim(p_privacy_url), '')
      ELSE public_privacy_url
    END,
    updated_at = now()
  WHERE tenant_id = v_tenant;

  RETURN api.get_my_customer_portal_public_profile();
END;
$$;

REVOKE ALL ON FUNCTION api.set_my_customer_portal_public_profile(text, text, text, text, text, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_my_customer_portal_public_profile(text, text, text, text, text, text, boolean)
  TO authenticated;
