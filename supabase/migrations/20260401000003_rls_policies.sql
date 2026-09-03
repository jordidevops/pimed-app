-- =============================================================================
-- Migració 3: Row Level Security (RLS) — Arquitectura multi-tenant per usuari
-- =============================================================================
-- Aquesta migració defineix el model real d'autorització de la plataforma:
--
--   1) SISTEMA DUAL DE PERMISOS
--      · Camí ràpid: JWT claims (app_metadata.user_tenants) via Auth Hook.
--      · Fallback: data.user_permissions_cache (per tokens antics o hook inactiu).
--      · Punt únic de lectura: data.jwt_user_tenants().
--
--   2) RLS AMB CONTEXT DE TENANT I SITE
--      · Pertinença al tenant: data.jwt_user_tenants() ? tenant_id::text
--      · Rol global: claim global_role dins user_tenants
--      · Rol de site: mapa user_tenants[tenant].sites[site_id]
--      · Filtre UX de tenant actiu: data.active_tenant_id() via header x-tenant-id
--
--   3) OBJECTIU FUNCIONAL
--      · Usuaris globals (owner/manager/member/viewer) operen a nivell tenant.
--      · Usuaris site-only veuen/editen només recursos del seu site quan aplica.
--
--
-- DISENY DE ROLS (data.tenant_members.role):
--   owner   → propietari. Pot tenir múltiples tenants. Accés i control total.
--   manager → administratiu corporatiu. Pot tenir múltiples tenants assignats.
--             Pot gestionar operacions però no pot eliminar tenants ni canviar pla.
--   member  → gerent del local/ubicació. Veu i edita el seu tenant (CRUD operacional).
--             No pot convidar altres usuaris.
--   viewer  → lectura del seu tenant. No pot escriure res.
--
-- DISENY DE ROLS DE BACKOFFICE (auth.users.app_metadata.role):
--   admin   → superadmin de la plataforma. Accés total via Prisma (BYPASSRLS).
--   support → suport de la plataforma. Pot veure tot però no fer operacions destructives.
--
-- MULTI-TENANT PER USUARI:
--   Un usuari pot tenir files a tenant_members per a múltiples tenants.
--   Exemple: un franquiciat és 'owner' a Restaurant 1, Restaurant 2 i Restaurant 3.
--   El frontend envia la capçalera HTTP 'x-tenant-id' quan l'usuari selecciona
--   un tenant específic al desplegable. Sense header → l'usuari veu tots els seus tenants.
--
-- PATRÓ RLS:
--   SELECT: data.jwt_user_tenants() ? tenant_id::text [+ filtre header si present]
--   WRITE:  rol global del JWT (owner/manager/member) i/o rol de site segons el recurs
--
-- SEGURETAT:
--   - prisma_admin té BYPASSRLS → ignora totes les polítiques.
--     La seguretat del portal admin la garanteix assertAdmin() a les Server Actions.
--   - Les funcions helper usen SECURITY DEFINER per evitar recursió
--     (tenant_members té RLS, però les funcions la salten per poder llegir-la).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Activar RLS a totes les taules de data.*
-- ---------------------------------------------------------------------------
ALTER TABLE data.plans            ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.tenants          ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.profiles         ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.sites            ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.tenant_members   ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.subscriptions    ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.notes            ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.files            ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.storage_usage    ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.audit_logs       ENABLE ROW LEVEL SECURITY;

-- =============================================================================
-- Funcions helper
-- =============================================================================

-- ---------------------------------------------------------------------------
-- data.my_tenant_ids()
-- Retorna un array amb els UUID de tots els tenants actius de l'usuari autenticat.
-- S'utilitza en les clàusules USING de totes les polítiques de SELECT.
--
-- SECURITY DEFINER: necessari per evitar recursió infinita.
--   Si tenant_members tingués una política RLS que cridés my_tenant_ids(),
--   s'entraria en un bucle. Amb SECURITY DEFINER executa amb permisos postgres.
-- STABLE: PostgreSQL cachejarà el resultat per tota la query → 1 sola crida per SELECT.
-- COALESCE(..., '{}'): retorna array buit si l'usuari no té cap tenant → cap fila visible.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.my_tenant_ids()
RETURNS uuid[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path = data AS $$
  SELECT COALESCE(ARRAY_AGG(DISTINCT tenant_id), '{}')
  FROM data.tenant_members
  WHERE user_id   = auth.uid()
    AND is_active = true;
$$;

-- ---------------------------------------------------------------------------
-- data.active_tenant_id()
-- Llegeix la capçalera HTTP 'x-tenant-id' enviada pel frontend.
-- PostgREST la exposa via current_setting('request.headers') en format JSON.
-- Retorna NULL si no hi ha capçalera o si no és un UUID vàlid.
--
-- Ús al frontend (supabase-js):
--   supabase.from('notes').select().setHeader('x-tenant-id', tenantId)
--   o a nivell de client: supabase = createClient(url, key, { global: { headers: { 'x-tenant-id': id } } })
--
-- NULL  → les polítiques mostren TOTS els tenants de l'usuari (vista agregada).
-- UUID  → les polítiques filtren a aquell tenant específic.
-- La validació de membresía la fa my_tenant_ids(), no cal fer-la aquí.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.active_tenant_id()
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = data AS $$
BEGIN
  RETURN NULLIF(
    current_setting('request.headers', true)::json->>'x-tenant-id',
    ''
  )::uuid;
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END;
$$;

-- ---------------------------------------------------------------------------
-- data.my_role_in(p_tenant_id)
-- Retorna el rol de l'usuari autenticat en un tenant concret.
-- Retorna NULL si no és membre actiu d'aquell tenant.
-- S'utilitza a les polítiques d'escriptura per verificar permisos per rol.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.my_role_in(p_tenant_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = data AS $$
  SELECT role
  FROM data.tenant_members
  WHERE tenant_id = p_tenant_id
    AND user_id   = auth.uid()
    AND is_active = true
    AND site_id   IS NULL      -- rol global, no de site concret
  LIMIT 1;
$$;

-- ---------------------------------------------------------------------------
-- data.jwt_user_tenants()
-- Extreu l'estructura user_tenants del JWT (via Auth Hook) o de la cache de BD.
--
-- Prioritat:
--   1. JWT claim (hook actiu): auth.jwt()->'app_metadata'->'user_tenants'
--      Zero DB hits. El camí ràpid quan el hook està configurat.
--   2. Cache de BD (fallback): data.user_permissions_cache
--      Un sol lookup per PK. Cobreix tokens antics o hook no actiu.
--   3. Buit '{}': l'usuari no té permisos a cap tenant.
--
-- Estructura JSON resultant:
-- {
--   "<tenant_uuid>": {
--     "global_role": "owner" | "manager" | "member" | "viewer" | null,
--     "sites": { "<site_uuid>": "member" | ... }
--   }
-- }
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.jwt_user_tenants()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = data AS $$
  SELECT COALESCE(
    -- Capa 1: JWT claim (hook actiu, camí sense DB)
    NULLIF(auth.jwt() -> 'app_metadata' -> 'user_tenants', 'null'::jsonb),
    -- Capa 2: Cache de BD (fallback trigger-based)
    (SELECT tenant_data FROM data.user_permissions_cache WHERE user_id = auth.uid()),
    -- Capa 3: Sense permisos
    '{}'::jsonb
  );
$$;

GRANT EXECUTE ON FUNCTION data.jwt_user_tenants TO authenticated;

-- ---------------------------------------------------------------------------
-- data.custom_access_token_hook(event jsonb)
--
-- S'executa en cada login/refresh de sessió (configurat a config.toml).
-- Llegeix data.tenant_members i injecta user_tenants a app_metadata del JWT.
-- Amb això, les polítiques RLS llegeixen permisos del token sense subconsultes.
--
-- SECURITY DEFINER: necessari per llegir data.tenant_members sense RLS.
-- La seguretat la garanteix:
--   1. REVOKE EXECUTE FROM PUBLIC/authenticated/anon
--   2. Supabase Auth crida la funció com a supabase_auth_admin internament.
--
-- Config.toml requerit:
--   [auth.hook.custom_access_token]
--   enabled = true
--   uri     = "pg-functions://postgres/data/custom_access_token_hook"
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.custom_access_token_hook(event jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_user_id      uuid;
  v_claims       jsonb;
  v_user_tenants jsonb := '{}'::jsonb;
  rec            RECORD;
BEGIN
  v_user_id := (event->>'user_id')::uuid;
  v_claims  := COALESCE(event -> 'claims', '{}'::jsonb);

  FOR rec IN
    SELECT tenant_id, site_id, role
    FROM data.tenant_members
    WHERE user_id   = v_user_id
      AND is_active = true
    ORDER BY tenant_id, site_id NULLS FIRST
  LOOP
    IF NOT (v_user_tenants ? rec.tenant_id::text) THEN
      v_user_tenants := jsonb_set(
        v_user_tenants,
        ARRAY[rec.tenant_id::text],
        '{"global_role": null, "sites": {}}'::jsonb
      );
    END IF;

    IF rec.site_id IS NULL THEN
      -- Membresia global (site_id NULL): rol a nivell tenant
      v_user_tenants := jsonb_set(
        v_user_tenants,
        ARRAY[rec.tenant_id::text, 'global_role'],
        to_jsonb(rec.role)
      );
    ELSE
      -- Membresia local (site_id NOT NULL): rol limitat a un site concret
      v_user_tenants := jsonb_set(
        v_user_tenants,
        ARRAY[rec.tenant_id::text, 'sites', rec.site_id::text],
        to_jsonb(rec.role)
      );
    END IF;
  END LOOP;

  v_claims := jsonb_set(
    v_claims,
    '{app_metadata, user_tenants}',
    v_user_tenants
  );

  RETURN jsonb_build_object('claims', v_claims);
END;
$$;

GRANT USAGE   ON SCHEMA data                              TO supabase_auth_admin;
GRANT EXECUTE ON FUNCTION data.custom_access_token_hook  TO supabase_auth_admin;
GRANT SELECT  ON data.tenant_members                     TO supabase_auth_admin;
REVOKE EXECUTE ON FUNCTION data.custom_access_token_hook FROM PUBLIC;

-- =============================================================================
-- plans — lectura pública per a qualsevol usuari autenticat
-- =============================================================================
CREATE POLICY "plans: lectura per autenticats"
  ON data.plans FOR SELECT
  TO authenticated
  USING (is_active = true);

-- =============================================================================
-- sites — RLS per a la nova taula de seus/locals
-- =============================================================================
-- Patrons de visibilitat (user_tenants del JWT):
--   · Pertinença al tenant: jwt_user_tenants() ? tenant_id::text
--   · Rol global:           jwt_user_tenants() -> tenant_id::text ->> 'global_role'
--   · Accés a site concret: jwt_user_tenants() -> tenant_id::text -> 'sites' ? site_id::text

-- SELECT: qualsevol membre del tenant veu els seus sites
CREATE POLICY "sites: veure sites del tenant"
  ON data.sites FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

-- INSERT: només owner i manager globals poden crear sites
CREATE POLICY "sites: owner/manager globals poden crear"
  ON data.sites FOR INSERT
  TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- UPDATE: owner i manager globals poden modificar sites
CREATE POLICY "sites: owner/manager globals poden modificar"
  ON data.sites FOR UPDATE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      -- Rol global owner/manager
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR
      -- Rol local owner/manager sobre aquest site concret
      (data.jwt_user_tenants() -> tenant_id::text -> 'sites' ->> id::text) IN ('owner', 'manager')
    )
  )
  WITH CHECK (
    (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR
      (data.jwt_user_tenants() -> tenant_id::text -> 'sites' ->> id::text) IN ('owner', 'manager')
    )
  );

-- DELETE: només owner global pot eliminar sites
CREATE POLICY "sites: owner global pot eliminar"
  ON data.sites FOR DELETE
  TO authenticated
  USING (
    (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') = 'owner'
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON data.sites TO authenticated;

-- =============================================================================
-- tenants
-- =============================================================================

-- Veure TOTS els propis tenants (o el filtrat per header x-tenant-id)
CREATE POLICY "tenants: veure els propis tenants"
  ON data.tenants FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? id::text
    AND (data.active_tenant_id() IS NULL OR id = data.active_tenant_id())
  );

-- Només owner pot modificar les dades del tenant
CREATE POLICY "tenants: owner pot modificar"
  ON data.tenants FOR UPDATE
  TO authenticated
  USING     ((data.jwt_user_tenants() -> id::text ->> 'global_role') = 'owner')
  WITH CHECK ((data.jwt_user_tenants() -> id::text ->> 'global_role') = 'owner');

-- =============================================================================
-- profiles
-- =============================================================================

-- Cada usuari veu el seu propi perfil
CREATE POLICY "profiles: veure el propi perfil"
  ON data.profiles FOR SELECT
  TO authenticated
  USING (id = auth.uid());

-- Veure els perfils de tots els membres dels teus tenants
CREATE POLICY "profiles: veure membres dels teus tenants"
  ON data.profiles FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM data.tenant_members tm
      WHERE tm.user_id   = data.profiles.id
        AND data.jwt_user_tenants() ? tm.tenant_id::text
        AND (data.active_tenant_id() IS NULL OR tm.tenant_id = data.active_tenant_id())
        AND (
          -- Rol global: pot veure tots els perfils del tenant
          (data.jwt_user_tenants() -> tm.tenant_id::text ->> 'global_role') IS NOT NULL
          OR
          -- Rol només de site: només perfils de membres del(s) seu(s) site(s)
          (tm.site_id IS NOT NULL AND (data.jwt_user_tenants() -> tm.tenant_id::text -> 'sites') ? tm.site_id::text)
        )
        AND tm.is_active = true
    )
  );

-- Cada usuari pot actualitzar el seu propi perfil
CREATE POLICY "profiles: actualitzar el propi perfil"
  ON data.profiles FOR UPDATE
  TO authenticated
  USING    (id = auth.uid())
  WITH CHECK (id = auth.uid());

-- =============================================================================
-- tenant_members
-- =============================================================================

-- Veure tots els membres de tots els teus tenants
CREATE POLICY "tenant_members: veure membres dels teus tenants"
  ON data.tenant_members FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      -- Rol global: veu tots els membres del tenant
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IS NOT NULL
      OR
      -- Rol només de site: només membres del mateix site
      (site_id IS NOT NULL AND (data.jwt_user_tenants() -> tenant_id::text -> 'sites') ? site_id::text)
    )
  );

-- owner i manager poden convidar nous membres
CREATE POLICY "tenant_members: owner/manager pot convidar"
  ON data.tenant_members FOR INSERT
  TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- owner i manager poden modificar rols i activar/desactivar membres
CREATE POLICY "tenant_members: owner/manager pot gestionar"
  ON data.tenant_members FOR UPDATE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- =============================================================================
-- subscriptions — owner i manager veuen la subscripció del tenant
-- =============================================================================
CREATE POLICY "subscriptions: owner/manager veuen la subscripció"
  ON data.subscriptions FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- =============================================================================
-- notes — CRUD amb visibilitat per site
-- =============================================================================
-- Lògica de visibilitat per site_id:
--   · site_id IS NULL  → nota global del Tenant: visible per a TOTS els membres.
--   · site_id NOT NULL → nota de site: visible si l'usuari té rol global O accés al site.

-- SELECT: membres del tenant veuen notes globals + notes dels sites als quals tenen accés
CREATE POLICY "notes: veure notes dels teus tenants"
  ON data.notes FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      -- Recurs global del Tenant: visible per a tots els membres
      site_id IS NULL
      OR
      -- L'usuari té rol global: accés a tots els sites del Tenant
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IS NOT NULL
      OR
      -- L'usuari té accés específic al site d'aquesta nota
      (data.jwt_user_tenants() -> tenant_id::text -> 'sites') ? site_id::text
    )
  );

-- INSERT: owner/manager/member poden crear notes (globals o de site)
CREATE POLICY "notes: owner/manager/member poden crear"
  ON data.notes FOR INSERT
  TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND created_by = auth.uid()
    AND (
      -- Rol global amb permisos d'escriptura
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager', 'member')
      OR
      -- Nota de site: l'usuari té rol d'escriptura en aquell site
      (
        site_id IS NOT NULL
        AND (data.jwt_user_tenants() -> tenant_id::text -> 'sites' ->> site_id::text)
              IN ('owner', 'manager', 'member')
      )
    )
  );

-- UPDATE: l'autor o owner/manager globals
CREATE POLICY "notes: autor o owner/manager pot editar"
  ON data.notes FOR UPDATE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      created_by = auth.uid()
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      created_by = auth.uid()
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  );

-- DELETE: l'autor o owner/manager globals
CREATE POLICY "notes: autor o owner/manager pot eliminar"
  ON data.notes FOR DELETE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      created_by = auth.uid()
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  );

-- =============================================================================
-- files
-- =============================================================================

-- Tots els rols veuen els fitxers dels seus tenants
CREATE POLICY "files: veure fitxers dels teus tenants"
  ON data.files FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

-- owner, manager i member poden registrar fitxers (viewer no pot pujar)
CREATE POLICY "files: owner/manager/member poden pujar"
  ON data.files FOR INSERT
  TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager', 'member')
    AND uploaded_by = auth.uid()
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

-- L'uploader pot eliminar els seus fitxers. owner/manager poden eliminar qualsevol.
CREATE POLICY "files: uploader o owner/manager pot eliminar"
  ON data.files FOR DELETE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      uploaded_by = auth.uid()
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  );

-- =============================================================================
-- storage_usage — owner i manager veuen l'ús d'emmagatzematge
-- =============================================================================
CREATE POLICY "storage_usage: owner/manager veuen l'ús"
  ON data.storage_usage FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- =============================================================================
-- audit_logs — owner i manager veuen els logs del tenant
-- =============================================================================
CREATE POLICY "audit_logs: owner/manager veuen logs"
  ON data.audit_logs FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- =============================================================================
-- Grants de taula base per al rol `authenticated`
-- =============================================================================
-- Amb security_invoker = true a les vistes api.*, PostgreSQL accedeix a les
-- taules data.* COM el rol authenticated. Per tant, authenticated necessita:
--   1. USAGE al schema data (per referenciar-lo)
--   2. Els privilegis de taula que corresponen a cada operació
-- El RLS s'aplica per sobre d'aquests grants i limita les files visibles.
-- =============================================================================
GRANT USAGE ON SCHEMA data TO authenticated;

GRANT SELECT                         ON data.plans          TO authenticated;
GRANT SELECT                         ON data.tenants        TO authenticated;
GRANT UPDATE                         ON data.tenants        TO authenticated;
GRANT SELECT                         ON data.profiles       TO authenticated;
GRANT UPDATE                         ON data.profiles       TO authenticated;
GRANT SELECT                         ON data.sites          TO authenticated;
GRANT INSERT, UPDATE, DELETE         ON data.sites          TO authenticated;
GRANT SELECT                         ON data.tenant_members TO authenticated;
GRANT INSERT, UPDATE                 ON data.tenant_members TO authenticated;
GRANT SELECT                         ON data.subscriptions  TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.notes          TO authenticated;
GRANT SELECT, INSERT, DELETE         ON data.files          TO authenticated;
GRANT SELECT                         ON data.storage_usage  TO authenticated;
GRANT SELECT                         ON data.audit_logs     TO authenticated;
