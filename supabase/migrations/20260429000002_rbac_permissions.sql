-- =============================================================================
-- Migració: Sistema RBAC — Permisos Granulars per Rol
-- =============================================================================
--
-- QUÈ FA AQUESTA MIGRACIÓ:
--   1. data.get_role_permissions(p_role, p_custom_permissions)
--      Funció IMMUTABLE que calcula els permisos totals d'un rol aplicant
--      herència acumulativa i personalitzacions del tenant.
--
--   2. data.custom_access_token_hook (UPDATE)
--      Ara injecta DUES estructures a app_metadata del JWT:
--        · user_tenants  → estructura original (backward compat, usada per RLS existent)
--        · user_permissions → nova estructura basada en permisos granulars
--
--   3. data.jwt_user_permissions()
--      Funció helper per llegir user_permissions del JWT (o calcular-ho de la BD
--      com a fallback si el token és antic).
--
--   4. data.jwt_has_permission(p_tenant_id, p_permission, p_site_id?)
--      Funció helper per a noves polítiques RLS basades en permisos.
--
-- COMPATIBILITAT ENRERE:
--   · user_tenants (amb global_role / sites) es manté SENSE CANVIS.
--   · Les polítiques RLS existents continuen funcionant sense modificació.
--   · La nova estructura user_permissions és ADDITIVAMENT nova.
--
-- ESTRUCTURA JWT NOVA (app_metadata.user_permissions):
--   {
--     "<tenant_id>": {
--       "global_permissions": ["storage.view", "calendar.view", ...] | ["*"],
--       "sites": {
--         "<site_id>": { "permissions": ["storage.view", ...] | ["*"] }
--       }
--     }
--   }
--
-- PERSONALITZACIÓ PER TENANT:
--   Guardada a data.tenants.metadata->'role_permissions' com a JSONB:
--   { "manager": ["perm.1"], "member": ["perm.1", "perm.2"] }
--   L'owner NO és personalitzable (sempre wildcard '*').
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. data.get_role_permissions
--    Calcula l'array de permisos per a un rol donat, considerant:
--      - Herència acumulativa (viewer ⊆ member ⊆ manager)
--      - Personalitzacions del tenant (substitueixen la base del rol concret)
--      - L'owner retorna ARRAY['*'] sense consultar res més
--    IMMUTABLE: resultat pur dels paràmetres, sense lectura de BD.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.get_role_permissions(
  p_role              text,
  p_custom_perms      jsonb DEFAULT NULL
)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  -- Permisos BASE per cada rol (nous permisos que aporta el rol sobre l'anterior)
  v_viewer_base  text[] := ARRAY[
    'storage.view', 'calendar.view', 'email.view', 'invoices.view',
    'members.view', 'sites.view', 'settings.view'
  ];
  v_member_base  text[] := ARRAY[
    'storage.upload', 'calendar.edit', 'email.send', 'invoices.edit'
  ];
  v_manager_base text[] := ARRAY[
    'storage.delete', 'calendar.manage', 'email.manage', 'invoices.manage',
    'members.invite', 'sites.create', 'settings.manage', 'permissions.manage'
  ];

  v_accumulated  text[] := '{}';
BEGIN
  -- Owner: wildcard total, sense llista
  IF p_role = 'owner' THEN
    RETURN ARRAY['*'];
  END IF;

  -- Capa viewer (tots els rols l'inclouen)
  IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'viewer' THEN
    v_accumulated := v_accumulated ||
      ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'viewer'));
  ELSE
    v_accumulated := v_accumulated || v_viewer_base;
  END IF;

  -- Capa member (member i manager)
  IF p_role IN ('member', 'manager') THEN
    IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'member' THEN
      v_accumulated := v_accumulated ||
        ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'member'));
    ELSE
      v_accumulated := v_accumulated || v_member_base;
    END IF;
  END IF;

  -- Capa manager
  IF p_role = 'manager' THEN
    IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'manager' THEN
      v_accumulated := v_accumulated ||
        ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'manager'));
    ELSE
      v_accumulated := v_accumulated || v_manager_base;
    END IF;
  END IF;

  -- Deduplicació (les dependències ja estan embegudes als conjunts base)
  RETURN ARRAY(SELECT DISTINCT unnest(v_accumulated));
END;
$$;

GRANT EXECUTE ON FUNCTION data.get_role_permissions TO authenticated;
GRANT EXECUTE ON FUNCTION data.get_role_permissions TO supabase_auth_admin;

-- ---------------------------------------------------------------------------
-- 2. data.custom_access_token_hook (REEMPLAÇA l'anterior)
--    Ara injecta tant user_tenants (backward compat) com user_permissions (nou).
--    Llegeix data.tenants.metadata->'role_permissions' per aplicar personalitzacions.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.custom_access_token_hook(event jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_user_id         uuid;
  v_claims          jsonb;
  v_user_tenants    jsonb := '{}'::jsonb;   -- estructura original (backward compat)
  v_user_perms      jsonb := '{}'::jsonb;   -- nova estructura basada en permisos
  v_custom_perms    jsonb;
  v_permissions     text[];
  rec               RECORD;
BEGIN
  v_user_id := (event->>'user_id')::uuid;
  v_claims  := COALESCE(event -> 'claims', '{}'::jsonb);

  -- Llegeix totes les membresies actives de l'usuari, joinant amb tenants
  -- per obtenir les personalitzacions de permisos del tenant.
  FOR rec IN
    SELECT
      tm.tenant_id,
      tm.site_id,
      tm.role,
      t.metadata -> 'role_permissions' AS custom_perms
    FROM data.tenant_members tm
    JOIN data.tenants t ON t.id = tm.tenant_id
    WHERE tm.user_id   = v_user_id
      AND tm.is_active = true
    ORDER BY tm.tenant_id, tm.site_id NULLS FIRST
  LOOP

    -- -----------------------------------------------------------------------
    -- A) Estructura original user_tenants (backward compat)
    -- -----------------------------------------------------------------------
    IF NOT (v_user_tenants ? rec.tenant_id::text) THEN
      v_user_tenants := jsonb_set(
        v_user_tenants,
        ARRAY[rec.tenant_id::text],
        '{"global_role": null, "sites": {}}'::jsonb
      );
    END IF;

    IF rec.site_id IS NULL THEN
      v_user_tenants := jsonb_set(
        v_user_tenants,
        ARRAY[rec.tenant_id::text, 'global_role'],
        to_jsonb(rec.role)
      );
    ELSE
      v_user_tenants := jsonb_set(
        v_user_tenants,
        ARRAY[rec.tenant_id::text, 'sites', rec.site_id::text],
        to_jsonb(rec.role)
      );
    END IF;

    -- -----------------------------------------------------------------------
    -- B) Nova estructura user_permissions (permisos granulars)
    -- -----------------------------------------------------------------------
    IF NOT (v_user_perms ? rec.tenant_id::text) THEN
      v_user_perms := jsonb_set(
        v_user_perms,
        ARRAY[rec.tenant_id::text],
        '{"global_permissions": [], "sites": {}}'::jsonb
      );
    END IF;

    v_permissions := data.get_role_permissions(rec.role, rec.custom_perms);

    IF rec.site_id IS NULL THEN
      -- Membresia global: injecta global_permissions
      v_user_perms := jsonb_set(
        v_user_perms,
        ARRAY[rec.tenant_id::text, 'global_permissions'],
        to_jsonb(v_permissions)
      );
    ELSE
      -- Membresia de site: injecta permissions dins l'objecte del site
      v_user_perms := jsonb_set(
        v_user_perms,
        ARRAY[rec.tenant_id::text, 'sites', rec.site_id::text],
        jsonb_build_object('permissions', to_jsonb(v_permissions))
      );
    END IF;

  END LOOP;

  -- Injecta les dues estructures a app_metadata
  v_claims := jsonb_set(v_claims, '{app_metadata, user_tenants}',    v_user_tenants);
  v_claims := jsonb_set(v_claims, '{app_metadata, user_permissions}', v_user_perms);

  RETURN jsonb_build_object('claims', v_claims);
END;
$$;

-- Permisos del hook (idèntics als originals, no canvien)
GRANT USAGE   ON SCHEMA data                              TO supabase_auth_admin;
GRANT EXECUTE ON FUNCTION data.custom_access_token_hook  TO supabase_auth_admin;
GRANT SELECT  ON data.tenant_members                     TO supabase_auth_admin;
GRANT SELECT  ON data.tenants                            TO supabase_auth_admin;
REVOKE EXECUTE ON FUNCTION data.custom_access_token_hook FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- 3. data.jwt_user_permissions()
--    Llegeix user_permissions del JWT (Capa 1) o calcula de la BD (Capa 2 fallback).
--    Mateixa filosofia que jwt_user_tenants() però per a la nova estructura.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.jwt_user_permissions()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_jwt_perms   jsonb;
  v_result      jsonb := '{}'::jsonb;
  v_permissions text[];
  rec           RECORD;
BEGIN
  -- Capa 1: JWT claim (hook actiu → zero DB hits)
  v_jwt_perms := NULLIF(
    auth.jwt() -> 'app_metadata' -> 'user_permissions',
    'null'::jsonb
  );
  IF v_jwt_perms IS NOT NULL AND v_jwt_perms <> '{}'::jsonb THEN
    RETURN v_jwt_perms;
  END IF;

  -- Capa 2: Calcula de la BD (fallback per tokens antics o hook inactiu)
  FOR rec IN
    SELECT
      tm.tenant_id,
      tm.site_id,
      tm.role,
      t.metadata -> 'role_permissions' AS custom_perms
    FROM data.tenant_members tm
    JOIN data.tenants t ON t.id = tm.tenant_id
    WHERE tm.user_id   = auth.uid()
      AND tm.is_active = true
    ORDER BY tm.tenant_id, tm.site_id NULLS FIRST
  LOOP
    IF NOT (v_result ? rec.tenant_id::text) THEN
      v_result := jsonb_set(
        v_result,
        ARRAY[rec.tenant_id::text],
        '{"global_permissions": [], "sites": {}}'::jsonb
      );
    END IF;

    v_permissions := data.get_role_permissions(rec.role, rec.custom_perms);

    IF rec.site_id IS NULL THEN
      v_result := jsonb_set(
        v_result,
        ARRAY[rec.tenant_id::text, 'global_permissions'],
        to_jsonb(v_permissions)
      );
    ELSE
      v_result := jsonb_set(
        v_result,
        ARRAY[rec.tenant_id::text, 'sites', rec.site_id::text],
        jsonb_build_object('permissions', to_jsonb(v_permissions))
      );
    END IF;
  END LOOP;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION data.jwt_user_permissions TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. data.jwt_has_permission(p_tenant_id, p_permission, p_site_id?)
--    Helper per a noves polítiques RLS basades en permisos.
--
--    Lògica:
--      · Si p_site_id IS NULL → comprova global_permissions del tenant.
--      · Si p_site_id IS NOT NULL → comprova global_permissions (herència)
--        O els permissions del site concret.
--      · El wildcard '*' sempre retorna true.
--
--    Ús en RLS:
--      USING ( data.jwt_has_permission(tenant_id, 'invoices.view') )
--      USING ( data.jwt_has_permission(tenant_id, 'calendar.edit', site_id) )
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.jwt_has_permission(
  p_tenant_id  uuid,
  p_permission text,
  p_site_id    uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT CASE
    -- Wildcard global (owner)
    WHEN (data.jwt_user_permissions() -> p_tenant_id::text -> 'global_permissions') @> '["*"]'::jsonb
      THEN true
    -- Context global: comprova només global_permissions
    WHEN p_site_id IS NULL THEN
      (data.jwt_user_permissions() -> p_tenant_id::text -> 'global_permissions') ? p_permission
    -- Context de site: comprova global (herència) O site concret
    ELSE
      (data.jwt_user_permissions() -> p_tenant_id::text -> 'global_permissions') ? p_permission
      OR
      -- Wildcard de site (si el site té rol owner)
      (data.jwt_user_permissions() -> p_tenant_id::text -> 'sites' -> p_site_id::text -> 'permissions') @> '["*"]'::jsonb
      OR
      (data.jwt_user_permissions() -> p_tenant_id::text -> 'sites' -> p_site_id::text -> 'permissions') ? p_permission
  END;
$$;

GRANT EXECUTE ON FUNCTION data.jwt_has_permission TO authenticated;

-- ---------------------------------------------------------------------------
-- NOTA: Les polítiques RLS existents segueixen usant jwt_user_tenants() i
-- global_role/sites sense canvis. Les noves polítiques poden usar
-- data.jwt_has_permission() per a control granular.
--
-- Exemple de nova política:
--   CREATE POLICY "invoices: veure factures"
--     ON data.invoices FOR SELECT TO authenticated
--     USING ( data.jwt_has_permission(tenant_id, 'invoices.view') );
--
--   CREATE POLICY "calendar: editar esdeveniments de site"
--     ON data.calendar_events FOR UPDATE TO authenticated
--     USING ( data.jwt_has_permission(tenant_id, 'calendar.edit', site_id) );
-- ---------------------------------------------------------------------------
