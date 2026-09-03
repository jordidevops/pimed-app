-- =============================================================================
-- Migració: 20260523000002_restore_settings_acl.sql
-- Objectiu: restaurar controls ACL en funcions de settings que van quedar
--           sobreescrites per versions més permissives.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- api.get_effective_settings (hardened)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_effective_settings(
  p_site_id   UUID DEFAULT NULL,
  p_user_id   UUID DEFAULT NULL,
  p_tenant_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id       UUID;
  v_auth_user_id    UUID := auth.uid();
  v_target_user_id  UUID;
  v_global_role     text;
  v_site_role       text;
  v_system_settings JSONB := '{}';
  v_tenant_settings JSONB := '{}';
  v_site_settings   JSONB := '{}';
  v_user_settings   JSONB := '{}';
BEGIN
  IF v_auth_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF p_user_id IS NULL THEN
    v_target_user_id := v_auth_user_id;
  ELSIF p_user_id <> v_auth_user_id THEN
    RAISE EXCEPTION 'Cannot read settings for another user';
  ELSE
    v_target_user_id := p_user_id;
  END IF;

  IF p_site_id IS NOT NULL THEN
    SELECT tenant_id INTO v_tenant_id
    FROM data.sites
    WHERE id = p_site_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Site % not found', p_site_id;
    END IF;
  ELSE
    v_tenant_id := COALESCE(p_tenant_id, data.active_tenant_id());
  END IF;

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'No active tenant: pass p_tenant_id or set x-tenant-id header';
  END IF;

  IF NOT (data.jwt_user_tenants() ? v_tenant_id::text) THEN
    RAISE EXCEPTION 'Access denied for tenant %', v_tenant_id;
  END IF;

  IF p_site_id IS NOT NULL THEN
    v_global_role := data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role';
    v_site_role   := data.jwt_user_tenants() -> v_tenant_id::text -> 'sites' ->> p_site_id::text;

    IF COALESCE(v_global_role, '') = '' AND COALESCE(v_site_role, '') = '' THEN
      RAISE EXCEPTION 'Access denied for site %', p_site_id;
    END IF;
  END IF;

  SELECT COALESCE(settings, '{}')
  INTO v_system_settings
  FROM data.system_settings
  WHERE module = 'defaults';

  SELECT COALESCE(settings, '{}')
  INTO v_tenant_settings
  FROM data.tenants
  WHERE id = v_tenant_id;

  IF p_site_id IS NOT NULL THEN
    SELECT COALESCE(settings, '{}')
    INTO v_site_settings
    FROM data.sites
    WHERE id = p_site_id;
  END IF;

  IF p_site_id IS NOT NULL THEN
    SELECT COALESCE(tm.settings, '{}')
    INTO v_user_settings
    FROM data.tenant_members tm
    WHERE tm.user_id   = v_target_user_id
      AND tm.tenant_id = v_tenant_id
      AND (tm.site_id = p_site_id OR tm.site_id IS NULL)
    ORDER BY CASE
      WHEN tm.site_id = p_site_id THEN 0
      WHEN tm.site_id IS NULL THEN 1
      ELSE 2
    END
    LIMIT 1;
  ELSE
    SELECT COALESCE(tm.settings, '{}')
    INTO v_user_settings
    FROM data.tenant_members tm
    WHERE tm.user_id   = v_target_user_id
      AND tm.tenant_id = v_tenant_id
      AND tm.site_id IS NULL
    LIMIT 1;
  END IF;

  RETURN
    COALESCE(v_system_settings, '{}') ||
    COALESCE(v_tenant_settings, '{}') ||
    COALESCE(v_site_settings, '{}') ||
    COALESCE(v_user_settings, '{}');
END;
$$;

REVOKE ALL ON FUNCTION api.get_effective_settings(UUID, UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_effective_settings(UUID, UUID, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- api.update_my_member_settings (ACL + merge semantics)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.update_my_member_settings(
  p_settings  JSONB,
  p_tenant_id UUID DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_user_id          UUID := auth.uid();
  v_tenant_id        UUID;
  v_target_member_id UUID;
  v_key              text;
BEGIN
  v_tenant_id := COALESCE(p_tenant_id, data.active_tenant_id());

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'No active tenant: pass p_tenant_id or set x-tenant-id header';
  END IF;

  IF jsonb_typeof(p_settings) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'p_settings must be a JSON object';
  END IF;

  IF NOT (data.jwt_user_tenants() ? v_tenant_id::text) THEN
    RAISE EXCEPTION 'Access denied for tenant %', v_tenant_id;
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(p_settings)
  LOOP
    PERFORM data.assert_setting_write_access(v_tenant_id, 'user', v_key, NULL);
  END LOOP;

  SELECT tm.id
  INTO v_target_member_id
  FROM data.tenant_members tm
  WHERE tm.user_id = v_user_id
    AND tm.tenant_id = v_tenant_id
  ORDER BY (tm.site_id IS NULL) DESC, tm.site_id NULLS LAST, tm.joined_at
  LIMIT 1;

  IF v_target_member_id IS NULL THEN
    RAISE EXCEPTION 'Member record not found for user % in tenant %', v_user_id, v_tenant_id;
  END IF;

  UPDATE data.tenant_members
  SET settings = COALESCE(settings, '{}') || p_settings
  WHERE id = v_target_member_id;
END;
$$;

REVOKE ALL ON FUNCTION api.update_my_member_settings(JSONB, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.update_my_member_settings(JSONB, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- api.update_tenant_settings (ACL)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.update_tenant_settings(
  p_settings  JSONB,
  p_tenant_id UUID DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id UUID;
  v_key       text;
BEGIN
  v_tenant_id := COALESCE(p_tenant_id, data.active_tenant_id());

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'No active tenant: pass p_tenant_id or set x-tenant-id header';
  END IF;

  IF jsonb_typeof(p_settings) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'p_settings must be a JSON object';
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(p_settings)
  LOOP
    PERFORM data.assert_setting_write_access(v_tenant_id, 'tenant', v_key, NULL);
  END LOOP;

  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}') || p_settings
  WHERE id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Tenant % not found', v_tenant_id;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION api.update_tenant_settings(JSONB, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.update_tenant_settings(JSONB, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- api.update_site_settings (ACL)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.update_site_settings(
  p_site_id  UUID,
  p_settings JSONB
)
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id UUID;
  v_key       text;
BEGIN
  IF jsonb_typeof(p_settings) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'p_settings must be a JSON object';
  END IF;

  SELECT tenant_id
  INTO v_tenant_id
  FROM data.sites
  WHERE id = p_site_id;

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Site % not found', p_site_id;
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(p_settings)
  LOOP
    PERFORM data.assert_setting_write_access(v_tenant_id, 'site', v_key, p_site_id);
  END LOOP;

  UPDATE data.sites
  SET settings = COALESCE(settings, '{}') || p_settings
  WHERE id = p_site_id;
END;
$$;

REVOKE ALL ON FUNCTION api.update_site_settings(UUID, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.update_site_settings(UUID, JSONB) TO authenticated;
