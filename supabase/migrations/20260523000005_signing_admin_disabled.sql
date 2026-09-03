-- =============================================================================
-- Migració: Sistema de desactivació admin + autoactivació per tenant
-- =============================================================================
-- Afegeix:
--   · data.tenant_signing_config.admin_disabled  — admin pot forçar desactivació
--   · api.tenant_signing_status: nous camps admin_disabled + effective_is_active
--   · api.set_tenant_signing_active(p_tenant_id, p_active) — RPC per al tenant portal
--
-- Semàntica:
--   is_active         = activat pel tenant (upsert via RPC)
--   admin_disabled    = forçadament desactivat per admin-portal (bypass RLS, Prisma)
--   effective_is_active = is_active AND NOT admin_disabled
--
-- El sign-document-router comprova effective_is_active.
-- Si admin_disabled=true el tenant veu avís "desactivat pels administadors del portal".
-- =============================================================================

-- 1. Afegir columna admin_disabled
ALTER TABLE data.tenant_signing_config
  ADD COLUMN IF NOT EXISTS admin_disabled boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN data.tenant_signing_config.admin_disabled
  IS 'Quan true, la firma está forçadament desactivada per admin-portal independentment de is_active.';

-- 2. Actualitzar vista api.tenant_signing_status (security_invoker = true)
-- Cal DROP + CREATE perquè s'afegeixen columnes al mig (CREATE OR REPLACE no ho permet)
DROP VIEW IF EXISTS api.tenant_signing_status;
CREATE VIEW api.tenant_signing_status WITH (security_invoker = true) AS
  SELECT
    tenant_id,
    mode,
    signing_credits,
    docuseal_api_url,
    is_active,
    admin_disabled,
    (is_active AND NOT admin_disabled) AS effective_is_active,
    created_at,
    updated_at
    -- docuseal_key_secret_id: EXCLÒS deliberadament
  FROM data.tenant_signing_config;

-- 3. Mantenir grants existents sobre la vista actualitzada
GRANT SELECT ON api.tenant_signing_status TO authenticated;
GRANT SELECT ON api.tenant_signing_status TO service_role;

-- 4. RPC per al tenant portal: activa/desactiva la firma
--    SECURITY INVOKER → corre com l'usuari autenticat (verifica membership via JWT)
--    Crea la fila si no existeix (mode platform, crèdits 0).
--    admin_disabled MAI es toca aquí — reservat a Prisma (admin-portal bypass RLS).
CREATE OR REPLACE FUNCTION api.set_tenant_signing_active(
  p_tenant_id uuid,
  p_active    boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_admin_disabled boolean := false;
BEGIN
  -- Verificar que l'usuari és owner o manager global del tenant
  IF NOT EXISTS (
    SELECT 1 FROM data.tenant_members
    WHERE tenant_id = p_tenant_id
      AND user_id    = auth.uid()
      AND role       IN ('owner', 'manager')
      AND is_active  = true
      AND site_id    IS NULL
  ) THEN
    RAISE EXCEPTION 'insufficient_permissions'
      USING HINT = 'Cal ser owner o manager global del tenant per gestionar la firma';
  END IF;

  -- Upsert: crea la fila si no existeix, o actualitza is_active
  -- Nota: admin_disabled NO es toca (admin-portal ho gestiona per separat via Prisma)
  INSERT INTO data.tenant_signing_config (tenant_id, mode, is_active, signing_credits)
  VALUES (p_tenant_id, 'platform', p_active, 0)
  ON CONFLICT (tenant_id) DO UPDATE
    SET is_active  = EXCLUDED.is_active,
        updated_at = now();

  -- Llegir admin_disabled per calcular l'estat efectiu a retornar
  SELECT admin_disabled
    INTO v_admin_disabled
    FROM data.tenant_signing_config
   WHERE tenant_id = p_tenant_id;

  RETURN jsonb_build_object(
    'is_active',          p_active,
    'admin_disabled',     COALESCE(v_admin_disabled, false),
    'effective_is_active', p_active AND NOT COALESCE(v_admin_disabled, false)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_tenant_signing_active(uuid, boolean) TO authenticated;
