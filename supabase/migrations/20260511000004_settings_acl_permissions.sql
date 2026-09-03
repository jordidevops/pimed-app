-- =============================================================================
-- Settings Engine hardening + Key-level ACL
--
-- Objectius:
--   1) Corregir exposició de lectura a api.get_effective_settings()
--   2) Corregir resolució de user settings per site (preferir fila de site)
--   3) Introduir ACL per clau de configuració (permission/owner_only)
--   4) Aplicar ACL a les RPC d'escriptura (tenant/site/user)
--
-- Notes de compatibilitat:
--   - Les RPC mantenen signatures existents.
--   - L'update passa a mode PATCH (merge shallow): settings = settings || p_settings
--   - Si una clau no està registrada a data.settings_registry, s'aplica permís
--     per defecte segons scope:
--       · tenant/site -> settings.manage
--       · user        -> l'usuari pot editar les seves preferències
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Catàleg de claus de configuració (ACL per clau)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.settings_registry (
  setting_key          text PRIMARY KEY,
  scope                text NOT NULL CHECK (scope IN ('tenant', 'site', 'user')),
  required_permission  text,
  owner_only           boolean NOT NULL DEFAULT false,
  is_active            boolean NOT NULL DEFAULT true,
  description          text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION data.touch_settings_registry_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_settings_registry_updated_at ON data.settings_registry;
CREATE TRIGGER trg_settings_registry_updated_at
  BEFORE UPDATE ON data.settings_registry
  FOR EACH ROW EXECUTE FUNCTION data.touch_settings_registry_updated_at();

ALTER TABLE data.settings_registry ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "settings_registry: service role full access" ON data.settings_registry;
CREATE POLICY "settings_registry: service role full access"
  ON data.settings_registry FOR ALL TO service_role
  USING (true) WITH CHECK (true);

GRANT SELECT ON data.settings_registry TO authenticated;
GRANT ALL    ON data.settings_registry TO prisma_admin, service_role;

-- Seeds inicials (idempotents) per demostrar ACL per clau.
INSERT INTO data.settings_registry (setting_key, scope, required_permission, owner_only, description)
VALUES
  ('default_event_start_time',       'tenant', 'settings.manage', false, 'Hora d''inici per defecte d''esdeveniments'),
  ('default_event_duration_minutes', 'tenant', 'settings.manage', false, 'Durada per defecte d''esdeveniments'),
  ('default_language',               'tenant', 'settings.manage', false, 'Idioma per defecte del tenant'),
  ('week_starts_on',                 'tenant', 'settings.manage', false, 'Dia inicial de setmana'),
  ('storage_hard_quota_gb',          'tenant', null,              true,  'Quota dura de storage (nomes owner)'),
  ('email_from_name',                'site',   'email.manage',    false, 'Nom remitent de correu del site'),
  ('email_reply_to',                 'site',   'email.manage',    false, 'Reply-to del site'),
  ('theme',                          'user',   null,              false, 'Tema de l''usuari'),
  ('calendar_default_view',          'user',   null,              false, 'Vista per defecte de calendari')
ON CONFLICT (setting_key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2) Helper central d'autorització per clau
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.assert_setting_write_access(
  p_tenant_id    uuid,
  p_scope        text,
  p_setting_key  text,
  p_site_id      uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_rule            data.settings_registry%ROWTYPE;
  v_permission      text;
  v_global_role     text;
  v_site_role       text;
  v_has_permission  boolean;
BEGIN
  IF p_scope NOT IN ('tenant', 'site', 'user') THEN
    RAISE EXCEPTION 'Invalid settings scope: %', p_scope;
  END IF;

  IF p_scope = 'site' AND p_site_id IS NULL THEN
    RAISE EXCEPTION 'site scope requires p_site_id';
  END IF;

  IF NOT (data.jwt_user_tenants() ? p_tenant_id::text) THEN
    RAISE EXCEPTION 'User is not member of tenant %', p_tenant_id;
  END IF;

  v_global_role := data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role';
  IF p_site_id IS NOT NULL THEN
    v_site_role := data.jwt_user_tenants() -> p_tenant_id::text -> 'sites' ->> p_site_id::text;
  END IF;

  SELECT * INTO v_rule
  FROM data.settings_registry
  WHERE setting_key = p_setting_key
    AND is_active = true;

  IF FOUND THEN
    IF v_rule.scope <> p_scope THEN
      RAISE EXCEPTION 'Setting key % cannot be written at scope %', p_setting_key, p_scope;
    END IF;

    IF v_rule.owner_only THEN
      IF p_scope = 'site' THEN
        IF COALESCE(v_global_role, '') <> 'owner' AND COALESCE(v_site_role, '') <> 'owner' THEN
          RAISE EXCEPTION 'Setting key % requires owner role', p_setting_key;
        END IF;
      ELSE
        IF COALESCE(v_global_role, '') <> 'owner' THEN
          RAISE EXCEPTION 'Setting key % requires owner role', p_setting_key;
        END IF;
      END IF;
      RETURN;
    END IF;

    -- Si hi ha permís explícit a registre, l'apliquem.
    -- Si no n'hi ha i scope != user, per defecte settings.manage.
    v_permission := CASE
      WHEN v_rule.required_permission IS NOT NULL THEN v_rule.required_permission
      WHEN p_scope IN ('tenant', 'site') THEN 'settings.manage'
      ELSE NULL
    END;

    IF v_permission IS NOT NULL THEN
      v_has_permission := data.jwt_has_permission(
        p_tenant_id,
        v_permission,
        CASE WHEN p_scope = 'site' THEN p_site_id ELSE NULL END
      );

      IF NOT COALESCE(v_has_permission, false) THEN
        RAISE EXCEPTION 'Insufficient permission % for setting key %', v_permission, p_setting_key;
      END IF;
    END IF;

    RETURN;
  END IF;

  -- Clau no registrada: fallback segur per no trencar compatibilitat
  IF p_scope IN ('tenant', 'site') THEN
    v_has_permission := data.jwt_has_permission(
      p_tenant_id,
      'settings.manage',
      CASE WHEN p_scope = 'site' THEN p_site_id ELSE NULL END
    );

    IF NOT COALESCE(v_has_permission, false) THEN
      RAISE EXCEPTION 'Insufficient permission settings.manage for key %', p_setting_key;
    END IF;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION data.assert_setting_write_access(uuid, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.assert_setting_write_access(uuid, text, text, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3) Harden de lectura: api.get_effective_settings
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

  -- No permet llegir settings d'un altre usuari
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

    -- Sense rol global ni rol local sobre el site -> no accés a context de site
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
    -- Context de site: preferim fila de site; fallback a fila global
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
-- 4) ACL + PATCH a api.update_my_member_settings
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

  -- Preferim fila global; si no existeix, fem fallback a la primera fila del tenant.
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
-- 5) ACL + PATCH a api.update_tenant_settings
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
-- 6) ACL + PATCH a api.update_site_settings
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
