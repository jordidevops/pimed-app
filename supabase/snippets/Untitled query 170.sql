-- =============================================================================
-- Migració: Capa de Sites + JWT Claims Auth Hook + RLS optimitzada
--
-- FASE 1 — Esquema: nova taula data.sites, modificació de tenant_members,
--           columna site_id a taules operatives.
-- FASE 2 — Auth Hook + Caché de permisos (sistema dual, veure nota).
-- FASE 3 — RLS: noves polítiques per a data.sites; reescriptura de les
--           polítiques de data.notes i data.file_nodes.
--
-- =============================================================================
-- CONFIGURACIÓ REQUERIDA: supabase/config.toml
-- =============================================================================
-- Afegir (o verificar que ja existeix) el bloc següent al config.toml:
--
--   [auth.hook.custom_access_token]
--   enabled = true
--   uri     = "pg-functions://postgres/data/custom_access_token_hook"
--
-- Requereix Supabase CLI >= v1.142. Compatible amb local (config.toml)
-- i amb cloud (Dashboard -> Authentication -> Hooks, disponible en beta).
-- Despres de modificar config.toml cal fer: supabase stop && supabase start
-- (o supabase db reset en dev per aplicar tambe les migracions).
--
-- =============================================================================
-- SISTEMA DUAL: JWT Hook + Cache de BD
-- =============================================================================
-- Aquesta migració implementa un sistema de dos capes per als permisos:
--
--   CAPA 1 - JWT Claims (Auth Hook, Fase 2a):
--     En cada login/refresh, custom_access_token_hook llegeix tenant_members
--     i injecta app_metadata.user_tenants al JWT. Les policies RLS llegeixen
--     el token directament: zero subconsultes per cada query. Es el cami rapid.
--
--   CAPA 2 - Cache de BD (triggers, Fase 2b):
--     Taula data.user_permissions_cache mantinguda per triggers sobre
--     tenant_members. Mateixa estructura JSON que el JWT claim.
--
-- La funcio data.jwt_user_tenants() intenta primer el JWT; si user_tenants
-- no hi es (hook no actiu, token antic, etc.) fa fallback a la cache de BD.
-- Resultat: el sistema funciona correctament amb o sense el hook actiu,
-- i la cache serveix de pont durant el periode d'adopcio.
-- =============================================================================


-- =============================================================================
-- FASE 1: ESQUEMA DE DADES
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. Nova taula data.sites
--    Representa una seu/local/restaurant dins d'un Tenant (Organització/Franquícia).
--    Un Tenant pot tenir N sites; un site pertany a un sol Tenant.
-- ---------------------------------------------------------------------------
CREATE TABLE data.sites (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  name        text        NOT NULL,
  address     text,
  is_active   boolean     NOT NULL DEFAULT true,
  metadata    jsonb,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_sites_tenant_id ON data.sites (tenant_id);

-- Reutilitza el trigger set_updated_at existent
CREATE TRIGGER trg_sites_updated_at
  BEFORE UPDATE ON data.sites
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

COMMENT ON TABLE data.sites
  IS 'Seus/locals fisics d''un Tenant. Un Tenant (franquicia) pot tenir N sites (restaurants).';


-- ---------------------------------------------------------------------------
-- 2. Modificar data.tenant_members
--
--    Afegim site_id: NULL significa rol global al Tenant (ex: owner/manager corporatiu).
--    NOT NULL significa rol limitat a un site concret (ex: gerent del Restaurant Gràcia).
--
--    Eliminem UNIQUE(tenant_id, user_id) i el substituïm per dos índexs parcials:
--    · Un sol rol global per usuari per tenant (on site_id IS NULL)
--    · Un sol rol per site per usuari (on site_id IS NOT NULL)
--
--    Motiu: UNIQUE(tenant_id, user_id, site_id) no funciona perquè PostgreSQL
--    tracta NULL ≠ NULL en índexs únics, permetent múltiples files amb site_id NULL.
-- ---------------------------------------------------------------------------
ALTER TABLE data.tenant_members
  ADD COLUMN site_id uuid REFERENCES data.sites(id) ON DELETE CASCADE;

-- Eliminar restricció antiga (nom generat per PostgreSQL)
ALTER TABLE data.tenant_members
  DROP CONSTRAINT IF EXISTS tenant_members_tenant_id_user_id_key;

-- Rol global únic per usuari i tenant
CREATE UNIQUE INDEX uq_tenant_members_global
  ON data.tenant_members (tenant_id, user_id)
  WHERE site_id IS NULL;

-- Rol de site únic per usuari, tenant i site
CREATE UNIQUE INDEX uq_tenant_members_site
  ON data.tenant_members (tenant_id, user_id, site_id)
  WHERE site_id IS NOT NULL;

COMMENT ON COLUMN data.tenant_members.site_id
  IS 'NULL = rol global al Tenant. NOT NULL = rol limitat al site indicat.';


-- ---------------------------------------------------------------------------
-- 3. Afegir columna site_id a les taules operatives
--
--    NULL → recurs global del Tenant (ex: manual de procediments corporatiu).
--    NOT NULL → recurs d'un site concret (ex: menú del Restaurant Gràcia).
--
--    ON DELETE SET NULL: si s'elimina el site, el recurs passa a ser global.
-- ---------------------------------------------------------------------------

-- Notes: contingut operatiu que pot ser global o específic d'un site
ALTER TABLE data.notes
  ADD COLUMN site_id uuid REFERENCES data.sites(id) ON DELETE SET NULL;

-- File nodes: arxius/carpetes que poden pertànyer a un site o ser globals
ALTER TABLE data.file_nodes
  ADD COLUMN site_id uuid REFERENCES data.sites(id) ON DELETE SET NULL;

-- Audit logs: contextualitzar cada acció auditada al site on va passar
ALTER TABLE data.audit_logs
  ADD COLUMN site_id uuid REFERENCES data.sites(id) ON DELETE SET NULL;

-- Share links: via node_id ja porta el context, però site_id permet filtres directes
ALTER TABLE data.share_links
  ADD COLUMN site_id uuid REFERENCES data.sites(id) ON DELETE SET NULL;

-- Storage egress logs: granularitat de facturació per site
ALTER TABLE data.storage_egress_logs
  ADD COLUMN site_id uuid REFERENCES data.sites(id) ON DELETE SET NULL;


-- ---------------------------------------------------------------------------
-- 4. Actualitzar les funcions helper existents per compatibilitat
-- ---------------------------------------------------------------------------

-- data.my_tenant_ids(): DISTINCT per evitar duplicats
-- Motiu: un usuari pot tenir rol global + rol de site en el mateix Tenant,
-- generant dues files a tenant_members amb el mateix tenant_id.
CREATE OR REPLACE FUNCTION data.my_tenant_ids()
RETURNS uuid[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path = data AS $$
  SELECT COALESCE(ARRAY_AGG(DISTINCT tenant_id), '{}')
  FROM data.tenant_members
  WHERE user_id   = auth.uid()
    AND is_active = true;
$$;

-- data.my_role_in(): filtrar exclusivament pels rols globals (site_id IS NULL)
-- Motiu: les politiques d'escriptura han de verificar el rol corporatiu global,
-- no el d'un site especific. Un gerent de site no pot modificar el Tenant.
CREATE OR REPLACE FUNCTION data.my_role_in(p_tenant_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = data AS $$
  SELECT role
  FROM data.tenant_members
  WHERE tenant_id = p_tenant_id
    AND user_id   = auth.uid()
    AND is_active = true
    AND site_id   IS NULL
  LIMIT 1;
$$;


-- =============================================================================
-- FASE 2a: AUTH HOOK — Custom Access Token JWT Claims
-- (veure capçalera per a la configuració config.toml)
-- =============================================================================


-- =============================================================================
-- FASE 2b: CACHE DE PERMISOS (fallback si el hook JWT no esta actiu)
--
-- Taula data.user_permissions_cache: manté la mateixa estructura JSON
-- que el JWT claim. S'actualitza automàticament via trigger cada cop que
-- tenant_members es modifica (INSERT / UPDATE / DELETE).
--
-- Quan usar-la:
--   - Durant el desplegament inicial (tokens sense el claim encara vigents)
--   - En entorns sense el hook configurat
--   - La funció jwt_user_tenants() fa fallback automàtic aquí
-- =============================================================================

CREATE TABLE data.user_permissions_cache (
  user_id     uuid        PRIMARY KEY REFERENCES data.profiles(id) ON DELETE CASCADE,
  tenant_data jsonb       NOT NULL DEFAULT '{}',
  updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE data.user_permissions_cache
  IS 'Cache de permisos per usuari. Mateixa estructura que app_metadata.user_tenants del JWT. '
     'Mantinguda per trigger sobre tenant_members. Usada com a fallback si el hook JWT no esta actiu.';

GRANT SELECT ON data.user_permissions_cache TO authenticated;
GRANT SELECT ON data.user_permissions_cache TO supabase_auth_admin;

-- Funcio que recalcula i persisteix els permisos d'un usuari concret.
-- Cridada des del trigger; unica font de veritat per al contingut de la cache.
CREATE OR REPLACE FUNCTION data.rebuild_user_permissions_cache(p_user_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = data AS $$
DECLARE
  v_user_tenants jsonb := '{}';
  rec            RECORD;
BEGIN
  FOR rec IN
    SELECT tenant_id, site_id, role
    FROM data.tenant_members
    WHERE user_id   = p_user_id
      AND is_active = true
    ORDER BY tenant_id, site_id NULLS FIRST
  LOOP
    IF NOT (v_user_tenants ? rec.tenant_id::text) THEN
      v_user_tenants := jsonb_set(
        v_user_tenants,
        ARRAY[rec.tenant_id::text],
        '{"global_role": null, "sites": {}}'
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
  END LOOP;

  INSERT INTO data.user_permissions_cache (user_id, tenant_data, updated_at)
  VALUES (p_user_id, v_user_tenants, now())
  ON CONFLICT (user_id) DO UPDATE
    SET tenant_data = EXCLUDED.tenant_data,
        updated_at  = now();
END;
$$;

-- Trigger function: detecta l'usuari afectat i delega a rebuild_user_permissions_cache.
CREATE OR REPLACE FUNCTION data.trg_refresh_permissions_cache()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = data AS $$
BEGIN
  PERFORM data.rebuild_user_permissions_cache(COALESCE(NEW.user_id, OLD.user_id));
  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_tenant_members_refresh_cache
  AFTER INSERT OR UPDATE OR DELETE ON data.tenant_members
  FOR EACH ROW EXECUTE FUNCTION data.trg_refresh_permissions_cache();

-- Backfill inicial: poblar la cache per als membres que ja existien
DO $$
DECLARE
  v_user_id uuid;
BEGIN
  FOR v_user_id IN
    SELECT DISTINCT user_id FROM data.tenant_members WHERE is_active = true
  LOOP
    PERFORM data.rebuild_user_permissions_cache(v_user_id);
  END LOOP;
END;
$$;


-- =============================================================================
-- FASE 2: AUTH HOOK — Custom Access Token JWT Claims
--
-- La funció custom_access_token_hook s'executa en cada login/refresh de sessió.
-- Llegeix data.tenant_members i construeix el claim user_tenants que s'injecta
-- a app_metadata del JWT. Amb això, les polítiques RLS poden llegir els permisos
-- directament del token sense fer subconsultes a la BD per cada query.
--
-- Estructura resultant al JWT (app_metadata.user_tenants):
-- {
--   "<tenant_uuid>": {
--     "global_role": "owner" | "manager" | "member" | "viewer" | null,
--     "sites": {
--       "<site_uuid>": "owner" | "manager" | "member" | "viewer"
--     }
--   }
-- }
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 5. Funcio helper: extreu user_tenants del JWT o de la cache de BD
--
--    Prioritat:
--      1. JWT claim (hook actiu): auth.jwt()->'app_metadata'->'user_tenants'
--         Zero DB hits. El cami rapid quan el hook esta configurat.
--      2. Cache de BD (fallback): data.user_permissions_cache
--         Un sol lookup per PK. Cobreix tokens antics o hook no actiu.
--      3. Buit '{}': l'usuari no te permisos a cap tenant.
--
--    Usada en totes les politiques RLS de Fase 3.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.jwt_user_tenants()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = data AS $$
  SELECT COALESCE(
    -- Capa 1: JWT claim (hook actiu, cami sense DB)
    NULLIF(auth.jwt() -> 'app_metadata' -> 'user_tenants', 'null'::jsonb),
    -- Capa 2: Cache de BD (fallback trigger-based)
    (SELECT tenant_data FROM data.user_permissions_cache WHERE user_id = auth.uid()),
    -- Capa 3: Sense permisos
    '{}'::jsonb
  );
$$;

GRANT EXECUTE ON FUNCTION data.jwt_user_tenants TO authenticated;


-- ---------------------------------------------------------------------------
-- 6. Auth Hook: data.custom_access_token_hook(event jsonb)
--
--    Signatura i valors de retorn definits per Supabase Auth Hooks:
--    · Rep:    { "user_id": "uuid", "claims": { JWT claims actuals } }
--    · Retorna: { "claims": { JWT claims modificats } }
--
--    SECURITY DEFINER: necessari per llegir data.tenant_members sense RLS.
--    La seguretat la garanteix:
--      1. REVOKE EXECUTE FROM PUBLIC/authenticated/anon
--      2. Supabase Auth crida la funció com a supabase_auth_admin internament.
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
  v_claims  := event -> 'claims';

  -- Llegir totes les membresies actives de l'usuari i construir l'estructura
  FOR rec IN
    SELECT tenant_id, site_id, role
    FROM data.tenant_members
    WHERE user_id   = v_user_id
      AND is_active = true
    ORDER BY tenant_id, site_id NULLS FIRST
  LOOP
    -- Inicialitzar l'objecte del Tenant si és la primera membresia d'aquest tenant
    IF NOT (v_user_tenants ? rec.tenant_id::text) THEN
      v_user_tenants := jsonb_set(
        v_user_tenants,
        ARRAY[rec.tenant_id::text],
        '{"global_role": null, "sites": {}}'::jsonb
      );
    END IF;

    IF rec.site_id IS NULL THEN
      -- Rol global del Tenant (owner/manager/member/viewer corporatiu)
      v_user_tenants := jsonb_set(
        v_user_tenants,
        ARRAY[rec.tenant_id::text, 'global_role'],
        to_jsonb(rec.role)
      );
    ELSE
      -- Rol específic d'un site (gerent de local, operari, etc.)
      v_user_tenants := jsonb_set(
        v_user_tenants,
        ARRAY[rec.tenant_id::text, 'sites', rec.site_id::text],
        to_jsonb(rec.role)
      );
    END IF;
  END LOOP;

  -- Injectar user_tenants a app_metadata del JWT
  v_claims := jsonb_set(
    v_claims,
    '{app_metadata, user_tenants}',
    v_user_tenants
  );

  RETURN jsonb_build_object('claims', v_claims);
END;
$$;

-- Permetre a Supabase Auth cridar el hook
GRANT USAGE  ON SCHEMA data                             TO supabase_auth_admin;
GRANT EXECUTE ON FUNCTION data.custom_access_token_hook TO supabase_auth_admin;
GRANT SELECT  ON data.tenant_members                    TO supabase_auth_admin;

-- Bloquejar execució directa per qualsevol altre rol
REVOKE EXECUTE ON FUNCTION data.custom_access_token_hook FROM PUBLIC;


-- =============================================================================
-- FASE 3: ACTUALITZACIÓ DE POLÍTIQUES RLS
--
-- Patró nou (basat en JWT claims, sense subconsultes):
--   · Pertinença al tenant:  data.jwt_user_tenants() ? tenant_id::text
--   · Rol global:            data.jwt_user_tenants() -> tenant_id::text ->> 'global_role'
--   · Accés a site concret:  data.jwt_user_tenants() -> tenant_id::text -> 'sites' ? site_id::text
--   · Rol en un site:        data.jwt_user_tenants() -> tenant_id::text -> 'sites' ->> site_id::text
--   · Filtre UX actiu:       data.active_tenant_id() (llegeix header HTTP x-tenant-id)
--
-- Lògica d'accés per site_id en recursos operatius:
--   · site_id IS NULL  → recurs global del Tenant, visible per a TOTS els membres.
--   · site_id NOT NULL → recurs de site: visible si l'usuari té rol global O accés al site.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 7. RLS per a data.sites (nova taula)
-- ---------------------------------------------------------------------------
ALTER TABLE data.sites ENABLE ROW LEVEL SECURITY;

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
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  )
  WITH CHECK (
    (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- DELETE: només owner global pot eliminar sites
CREATE POLICY "sites: owner global pot eliminar"
  ON data.sites FOR DELETE
  TO authenticated
  USING (
    (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') = 'owner'
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON data.sites TO authenticated;


-- ---------------------------------------------------------------------------
-- 8. Reescriure RLS de data.notes
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "notes: veure notes dels teus tenants"      ON data.notes;
DROP POLICY IF EXISTS "notes: owner/manager/member poden crear"   ON data.notes;
DROP POLICY IF EXISTS "notes: autor o owner/manager pot editar"   ON data.notes;
DROP POLICY IF EXISTS "notes: autor o owner/manager pot eliminar" ON data.notes;

-- SELECT: veure notes dels teus tenants (amb filtre de site si escau)
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

-- INSERT: owner/manager/member poden crear notes
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
      -- Nota de site específic: l'usuari té rol d'escriptura en aquell site
      (
        site_id IS NOT NULL
        AND (data.jwt_user_tenants() -> tenant_id::text -> 'sites' ->> site_id::text)
              IN ('owner', 'manager', 'member')
      )
    )
  );

-- UPDATE: l'autor pot editar les seves notes; owner/manager globals qualsevol
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

-- DELETE: l'autor o owner/manager globals poden eliminar
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


-- ---------------------------------------------------------------------------
-- 9. Reescriure RLS de data.file_nodes
--
--    La política de SELECT manté la crida a data.can_access_via_permissions()
--    (definida a la migració 20260413000010_acl_node_permissions) per al sistema
--    d'ACL per node. El filtre de site s'afegeix dins del bloc de nodes actius.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "file_nodes: veure nodes dels teus tenants"    ON data.file_nodes;
DROP POLICY IF EXISTS "file_nodes: owner/manager/member poden crear" ON data.file_nodes;
DROP POLICY IF EXISTS "file_nodes: actualitzar nodes del repositori" ON data.file_nodes;
DROP POLICY IF EXISTS "file_nodes: no delete directe"                ON data.file_nodes;

-- SELECT
CREATE POLICY "file_nodes: veure nodes dels teus tenants"
  ON data.file_nodes FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      -- Nodes esborrats: visibles a la vista trash sense filtre de site
      is_deleted = true
      OR (
        is_deleted = false
        AND (
          processing_status IN ('none', 'done', 'processing', 'error')
          OR (processing_status = 'pending' AND created_by = auth.uid())
        )
        AND data.can_access_via_permissions(
          id, is_restricted, created_by, ancestor_paths, tenant_id
        )
        AND (
          -- Node global del Tenant: visible per a tots els membres
          site_id IS NULL
          OR
          -- Rol global: accés a tots els sites del Tenant
          (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IS NOT NULL
          OR
          -- Accés específic al site del node
          (data.jwt_user_tenants() -> tenant_id::text -> 'sites') ? site_id::text
        )
      )
    )
  );

-- INSERT: owner/manager/member global, o rol d'escriptura en el site destí
CREATE POLICY "file_nodes: owner/manager/member poden crear"
  ON data.file_nodes FOR INSERT
  TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND created_by = auth.uid()
    AND namespace = 'repository'
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager', 'member')
      OR
      (
        site_id IS NOT NULL
        AND (data.jwt_user_tenants() -> tenant_id::text -> 'sites' ->> site_id::text)
              IN ('owner', 'manager', 'member')
      )
    )
  );

-- UPDATE: l'autor o owner/manager globals, namespace 'repository'
CREATE POLICY "file_nodes: actualitzar nodes del repositori"
  ON data.file_nodes FOR UPDATE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND namespace = 'repository'
    AND (
      created_by = auth.uid()
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  )
  WITH CHECK (
    namespace = 'repository'
  );

-- DELETE: continua prohibit per authenticated (via funcions SECURITY DEFINER)
CREATE POLICY "file_nodes: no delete directe"
  ON data.file_nodes FOR DELETE
  TO authenticated
  USING (false);
