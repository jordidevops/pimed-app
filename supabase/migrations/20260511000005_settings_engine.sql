-- =============================================================================
-- Settings Engine — Cascading Configuration (4 nivells)
--
-- Arquitectura:
--   System (data.system_settings module='defaults')
--     → Tenant (data.tenants.settings)
--       → Site (data.sites.settings)
--         → User/Member (data.tenant_members.settings)
--
--   Merge JSONB esquerra → dreta (dreta sobreescriu). L'operador || de JSONB
--   realitza un merge shallow: cada clau de la dreta substitueix la mateixa clau
--   de l'esquerra, sense recursió de subobjectes.
--
-- Funcions exposades:
--   api.get_effective_settings(p_site_id, p_user_id) → jsonb
--     Retorna el merge final dels 4 nivells per a un context donat.
--
--   api.update_my_member_settings(p_settings) → void
--     Permet a qualsevol membre autenticat actualitzar el seu propi JSONB de
--     preferències a tenant_members. SECURITY DEFINER (bypassa RLS) però
--     restringit a la fila pròpia de l'usuari actiu.
--
--   api.update_tenant_settings(p_settings) → void
--     Owner del tenant pot actualitzar el settings JSONB del tenant.
--
--   api.update_site_settings(p_site_id, p_settings) → void
--     Owner o manager (global o de site) pot actualitzar el settings JSONB del site.
--
-- Seguretat RLS:
--   · data.tenants.settings    → cobert per la policy existent (owner global).
--   · data.sites.settings      → cobert per la policy existent (owner/manager global o local).
--   · data.tenant_members.settings → escriptura via RPC SECURITY DEFINER
--     (la policy UPDATE existent limita a owner/manager; els membres normals usen la RPC).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Columnes settings a tenants, sites i tenant_members
-- ---------------------------------------------------------------------------
ALTER TABLE data.tenants
  ADD COLUMN IF NOT EXISTS settings JSONB NOT NULL DEFAULT '{}';

ALTER TABLE data.sites
  ADD COLUMN IF NOT EXISTS settings JSONB NOT NULL DEFAULT '{}';

ALTER TABLE data.tenant_members
  ADD COLUMN IF NOT EXISTS settings JSONB NOT NULL DEFAULT '{}';

-- ---------------------------------------------------------------------------
-- 2. Seed: mòdul 'defaults' a data.system_settings
--    Conté els valors de fàbrica de la plataforma per a tot el sistema.
--    Exemple de claus útils: default_event_start_time, default_language, etc.
-- ---------------------------------------------------------------------------
INSERT INTO data.system_settings (module, settings)
VALUES ('defaults', '{
  "default_event_start_time": "09:00",
  "default_event_duration_minutes": 60,
  "default_language": "ca",
  "week_starts_on": 1
}'::jsonb)
ON CONFLICT (module) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. api.get_effective_settings(p_site_id, p_user_id)
--    Retorna el merge dels 4 nivells en ordre ascendent de prioritat.
--    SECURITY DEFINER per poder llegir data.* des de context autenticat.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_effective_settings(
  p_site_id   UUID DEFAULT NULL,
  p_user_id   UUID DEFAULT NULL,
  p_tenant_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id       UUID;
  v_system_settings JSONB := '{}';
  v_tenant_settings JSONB := '{}';
  v_site_settings   JSONB := '{}';
  v_user_settings   JSONB := '{}';
BEGIN
  -- -------------------------------------------------------------------------
  -- Determinar tenant_id de context
  -- -------------------------------------------------------------------------
  IF p_site_id IS NOT NULL THEN
    -- Prioritat: site_id → llegim el tenant del site
    SELECT tenant_id INTO v_tenant_id
    FROM data.sites
    WHERE id = p_site_id;
  ELSE
    -- Fallback: p_tenant_id explícit o capçalera x-tenant-id
    v_tenant_id := COALESCE(p_tenant_id, data.active_tenant_id());
  END IF;

  -- -------------------------------------------------------------------------
  -- Nivell 1: System defaults
  -- -------------------------------------------------------------------------
  SELECT COALESCE(settings, '{}')
  INTO v_system_settings
  FROM data.system_settings
  WHERE module = 'defaults';

  v_system_settings := COALESCE(v_system_settings, '{}');

  -- -------------------------------------------------------------------------
  -- Nivell 2: Tenant settings
  -- -------------------------------------------------------------------------
  IF v_tenant_id IS NOT NULL THEN
    SELECT COALESCE(settings, '{}')
    INTO v_tenant_settings
    FROM data.tenants
    WHERE id = v_tenant_id;
  END IF;

  v_tenant_settings := COALESCE(v_tenant_settings, '{}');

  -- -------------------------------------------------------------------------
  -- Nivell 3: Site settings
  -- -------------------------------------------------------------------------
  IF p_site_id IS NOT NULL THEN
    SELECT COALESCE(settings, '{}')
    INTO v_site_settings
    FROM data.sites
    WHERE id = p_site_id;
  END IF;

  v_site_settings := COALESCE(v_site_settings, '{}');

  -- -------------------------------------------------------------------------
  -- Nivell 4: User/member settings
  -- Busquem la fila de tenant_members per a (user_id, tenant_id):
  --   · Primer intentem la fila global (site_id IS NULL)
  --   · Si no existeix i hi ha un site de context, busquem la fila de site
  -- -------------------------------------------------------------------------
  IF p_user_id IS NOT NULL AND v_tenant_id IS NOT NULL THEN
    SELECT COALESCE(tm.settings, '{}')
    INTO v_user_settings
    FROM data.tenant_members tm
    WHERE tm.user_id   = p_user_id
      AND tm.tenant_id = v_tenant_id
    ORDER BY tm.site_id NULLS FIRST  -- preferim la fila global (site_id IS NULL)
    LIMIT 1;
  END IF;

  v_user_settings := COALESCE(v_user_settings, '{}');

  -- -------------------------------------------------------------------------
  -- Merge final: System || Tenant || Site || User
  -- -------------------------------------------------------------------------
  RETURN v_system_settings || v_tenant_settings || v_site_settings || v_user_settings;
END;
$$;

REVOKE ALL ON FUNCTION api.get_effective_settings(UUID, UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_effective_settings(UUID, UUID, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. api.update_my_member_settings(p_settings)
--    Permet a qualsevol membre autenticat actualitzar el seu propi settings JSONB
--    a data.tenant_members (fila global, site_id IS NULL).
--    SECURITY DEFINER per passar la RLS d'UPDATE (que limita a owner/manager).
--    Restricció interna: auth.uid() = tm.user_id (l'usuari SEMPRE edita el seu propi).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.update_my_member_settings(
  p_settings  JSONB,
  p_tenant_id UUID DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_user_id   UUID := auth.uid();
  v_tenant_id UUID;
BEGIN
  v_tenant_id := COALESCE(p_tenant_id, data.active_tenant_id());

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'No active tenant: pass p_tenant_id or set x-tenant-id header';
  END IF;

  UPDATE data.tenant_members
  SET settings = p_settings
  WHERE user_id   = v_user_id
    AND tenant_id = v_tenant_id
    AND site_id IS NULL;  -- fila de membresia global

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Member record not found for user % in tenant %', v_user_id, v_tenant_id;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION api.update_my_member_settings(JSONB, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.update_my_member_settings(JSONB, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. api.update_tenant_settings(p_settings)
--    Permet a l'owner del tenant actualitzar el settings JSONB del tenant.
--    (La policy existent ja ho permet via UPDATE directe, però exposem RPC per
--    consistència amb el patró del motor i per limitar a la clau 'settings'.)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.update_tenant_settings(
  p_settings  JSONB,
  p_tenant_id UUID DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id UUID;
  v_role      TEXT;
BEGIN
  v_tenant_id := COALESCE(p_tenant_id, data.active_tenant_id());

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'No active tenant: pass p_tenant_id or set x-tenant-id header';
  END IF;

  v_role := (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role');

  IF v_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'Insufficient permissions: owner or manager required';
  END IF;

  UPDATE data.tenants
  SET settings = p_settings
  WHERE id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Tenant % not found', v_tenant_id;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION api.update_tenant_settings(JSONB, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.update_tenant_settings(JSONB, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. api.update_site_settings(p_site_id, p_settings)
--    Permet a owner o manager (global o de site) actualitzar el settings JSONB
--    d'un site concret.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.update_site_settings(
  p_site_id  UUID,
  p_settings JSONB
)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id UUID;
  v_global_role TEXT;
  v_site_role   TEXT;
BEGIN
  SELECT tenant_id INTO v_tenant_id
  FROM data.sites
  WHERE id = p_site_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Site % not found', p_site_id;
  END IF;

  v_global_role := (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role');
  v_site_role   := (data.jwt_user_tenants() -> v_tenant_id::text -> 'sites' ->> p_site_id::text);

  IF COALESCE(v_global_role, '') NOT IN ('owner', 'manager')
     AND COALESCE(v_site_role, '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'Insufficient permissions: owner or manager required for site %', p_site_id;
  END IF;

  UPDATE data.sites
  SET settings = p_settings
  WHERE id = p_site_id;
END;
$$;

REVOKE ALL ON FUNCTION api.update_site_settings(UUID, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.update_site_settings(UUID, JSONB) TO authenticated;
