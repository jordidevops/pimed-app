-- sidebar_nav settings keys + clear RPCs (key removal for reliable reset)
-- Cascade (app-side): user.sidebar_nav ?? tenant.sidebar_nav_tenant ?? platform default

INSERT INTO data.settings_registry (setting_key, scope, required_permission, owner_only, is_active, description)
VALUES
  (
    'sidebar_nav',
    'user',
    NULL,
    false,
    true,
    'Personalització del menú lateral del portal (layout per membership)'
  ),
  (
    'sidebar_nav_tenant',
    'tenant',
    'settings.manage',
    false,
    true,
    'Menú lateral per defecte de l''organització (fallback per a membres sense override)'
  )
ON CONFLICT (setting_key) DO UPDATE
SET
  scope = EXCLUDED.scope,
  required_permission = EXCLUDED.required_permission,
  owner_only = EXCLUDED.owner_only,
  is_active = EXCLUDED.is_active,
  description = EXCLUDED.description,
  updated_at = now();

-- ---------------------------------------------------------------------------
-- api.clear_my_member_setting — remove a single key from member settings
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.clear_my_member_setting(
  p_setting_key text,
  p_tenant_id   UUID DEFAULT NULL
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
BEGIN
  v_tenant_id := COALESCE(p_tenant_id, data.active_tenant_id());

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'No active tenant: pass p_tenant_id or set x-tenant-id header';
  END IF;

  IF p_setting_key IS NULL OR length(trim(p_setting_key)) = 0 THEN
    RAISE EXCEPTION 'p_setting_key is required';
  END IF;

  IF NOT (data.jwt_user_tenants() ? v_tenant_id::text) THEN
    RAISE EXCEPTION 'Access denied for tenant %', v_tenant_id;
  END IF;

  PERFORM data.assert_setting_write_access(v_tenant_id, 'user', p_setting_key, NULL);

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
  SET settings = COALESCE(settings, '{}'::jsonb) - p_setting_key
  WHERE id = v_target_member_id;
END;
$$;

REVOKE ALL ON FUNCTION api.clear_my_member_setting(text, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.clear_my_member_setting(text, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- api.clear_tenant_setting — remove a single key from tenant settings
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.clear_tenant_setting(
  p_setting_key text,
  p_tenant_id   UUID DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id UUID;
BEGIN
  v_tenant_id := COALESCE(p_tenant_id, data.active_tenant_id());

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'No active tenant: pass p_tenant_id or set x-tenant-id header';
  END IF;

  IF p_setting_key IS NULL OR length(trim(p_setting_key)) = 0 THEN
    RAISE EXCEPTION 'p_setting_key is required';
  END IF;

  PERFORM data.assert_setting_write_access(v_tenant_id, 'tenant', p_setting_key, NULL);

  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb) - p_setting_key
  WHERE id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Tenant % not found', v_tenant_id;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION api.clear_tenant_setting(text, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.clear_tenant_setting(text, UUID) TO authenticated;
