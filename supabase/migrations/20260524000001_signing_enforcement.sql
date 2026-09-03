-- =============================================================================
-- Migració: Enforçament de seguretat del mòdul de firmes
-- Número:   20260524000001
-- =============================================================================
-- Problemes corregits:
--   1. El tenant podia activar firmes (is_active=true) fins i tot quan:
--      a) admin_disabled=true  →  desactivat per admin-portal
--      b) Feature flag "tenant_signing_enabled" és false
--   2. Un owner/manager podia manipular signing_credits directament via
--      PostgREST (UPDATE a data.tenant_signing_config sense RPC).
--   3. La UI no tenia forma d'obtenir feature_enabled quan encara no existia
--      cap fila a data.tenant_signing_config (tenant nou sense configurar).
--
-- Canvis:
--   · data.is_signing_feature_enabled(uuid)  — helper SECURITY DEFINER
--   · api.get_signing_status(uuid)           — RPC sempre retorna fila (SECDEF)
--   · api.set_tenant_signing_active          — ara SECURITY DEFINER + guards
--   · trg_prevent_credits_modification       — trigger que bloqueja UPDATE
--                                              directe de signing_credits per
--                                              usuaris authenticated
-- =============================================================================


-- ============================================================================
-- 1. Helper: data.is_signing_feature_enabled
--    Comprova si la feature "tenant_signing_enabled" és activa per un tenant.
--    Ordre de prioritat: tenant_override > global_flag.
--    Rollout parcial (0 < pct < 100) es tracta com a desactivat per defecte
--    (la lògica de bucket hash queda als edge functions; aquí volem conservador).
-- ============================================================================
CREATE OR REPLACE FUNCTION data.is_signing_feature_enabled(p_tenant_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT COALESCE(
    -- 1) Override explícit per tenant (prioritat màxima)
    (
      SELECT override_status
        FROM data.tenant_feature_overrides
       WHERE tenant_id  = p_tenant_id
         AND feature_key = 'tenant_signing_enabled'
    ),
    -- 2) Flag global (només si rollout >= 100; rollout parcial = desactivat)
    (
      SELECT is_enabled AND rollout_percentage >= 100
        FROM data.feature_flags
       WHERE key = 'tenant_signing_enabled'
    ),
    -- 3) Default: no disponible
    false
  )
$$;

-- Concedim EXECUTE perquè pugui ser cridat des de vistes security_invoker
GRANT EXECUTE ON FUNCTION data.is_signing_feature_enabled(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION data.is_signing_feature_enabled(uuid) TO service_role;


-- ============================================================================
-- 2. RPC: api.get_signing_status
--    Retorna SEMPRE una fila amb l'estat complet de firmes per a un tenant.
--    Si no existeix fila a tenant_signing_config, retorna defaults segurs.
--    Inclou: feature_enabled, can_activate, credits, effective_is_active.
--
--    Ús: useSigningConfig hook, SigningPage, DocumentOrchestrator.
-- ============================================================================
CREATE OR REPLACE FUNCTION api.get_signing_status(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_cfg            data.tenant_signing_config%ROWTYPE;
  v_feat_enabled   boolean;
  v_admin_disabled boolean;
  v_is_active      boolean;
  v_effective      boolean;
BEGIN
  -- Verificar accés: cal ser membre del tenant
  IF NOT (data.jwt_user_tenants() ? p_tenant_id::text) THEN
    RAISE EXCEPTION 'insufficient_permissions'
      USING HINT = 'Cal ser membre del tenant per consultar l''estat de firmes';
  END IF;

  -- Llegir configuració del tenant (pot no existir)
  SELECT * INTO v_cfg
    FROM data.tenant_signing_config
   WHERE tenant_id = p_tenant_id;

  -- Valors per defecte si no hi ha fila
  v_admin_disabled := COALESCE(v_cfg.admin_disabled, false);
  v_is_active      := COALESCE(v_cfg.is_active, false);
  v_effective      := v_is_active AND NOT v_admin_disabled;

  -- Llegir feature flag (SECURITY DEFINER, accedeix a data.feature_flags)
  v_feat_enabled := data.is_signing_feature_enabled(p_tenant_id);

  RETURN jsonb_build_object(
    'tenant_id',          p_tenant_id,
    'mode',               COALESCE(v_cfg.mode::text, 'platform'),
    'signing_credits',    COALESCE(v_cfg.signing_credits, 0),
    'docuseal_api_url',   v_cfg.docuseal_api_url,
    'is_active',          v_is_active,
    'admin_disabled',     v_admin_disabled,
    'effective_is_active', v_effective,
    'feature_enabled',    v_feat_enabled,
    -- can_activate = el tenant pot activar/desactivar la firma
    -- Fals si admin l'ha bloquejat o si el feature flag no hi és
    'can_activate',       v_feat_enabled AND NOT v_admin_disabled
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_signing_status(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_signing_status(uuid) TO service_role;


-- ============================================================================
-- 3. Corregir api.set_tenant_signing_active
--    Ara SECURITY DEFINER per poder llegir data.feature_flags.
--    Guards addicionals:
--      · Bloqueja p_active=true si admin_disabled=true
--      · Bloqueja p_active=true si feature flag és false
-- ============================================================================
CREATE OR REPLACE FUNCTION api.set_tenant_signing_active(
  p_tenant_id uuid,
  p_active    boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_admin_disabled boolean := false;
  v_feat_enabled   boolean;
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

  -- Llegir estat actual de admin_disabled (pot no existir fila)
  SELECT admin_disabled
    INTO v_admin_disabled
    FROM data.tenant_signing_config
   WHERE tenant_id = p_tenant_id;

  -- Guard 1: admin ha desactivat el tenant → no es pot activar
  IF p_active AND COALESCE(v_admin_disabled, false) THEN
    RAISE EXCEPTION 'signing_admin_disabled'
      USING HINT = 'La firma digital ha estat desactivada pels administradors del portal. Contacta amb el suport per restablir l''accés.';
  END IF;

  -- Guard 2: feature flag global no disponible → no es pot activar
  v_feat_enabled := data.is_signing_feature_enabled(p_tenant_id);
  IF p_active AND NOT v_feat_enabled THEN
    RAISE EXCEPTION 'signing_feature_disabled'
      USING HINT = 'La funcionalitat de firma digital no és disponible en aquests moments.';
  END IF;

  -- Upsert: crea la fila si no existeix, o actualitza is_active.
  -- admin_disabled i signing_credits MAI es toquen aquí.
  INSERT INTO data.tenant_signing_config (tenant_id, mode, is_active, signing_credits)
  VALUES (p_tenant_id, 'platform', p_active, 0)
  ON CONFLICT (tenant_id) DO UPDATE
    SET is_active  = EXCLUDED.is_active,
        updated_at = now();

  RETURN jsonb_build_object(
    'is_active',           p_active,
    'admin_disabled',      COALESCE(v_admin_disabled, false),
    'effective_is_active', p_active AND NOT COALESCE(v_admin_disabled, false),
    'feature_enabled',     v_feat_enabled
  );
END;
$$;

-- Mantenim el GRANT existent (SECURITY DEFINER no requereix canvis addicionals)
GRANT EXECUTE ON FUNCTION api.set_tenant_signing_active(uuid, boolean) TO authenticated;


-- ============================================================================
-- 4. Trigger: data.prevent_direct_credits_modification
--    Bloqueja que un usuari authenticated modifiqui signing_credits directament
--    via PostgREST (UPDATE a data.tenant_signing_config).
--    Les funcions SECURITY DEFINER (consume/compensate_signing_credit) no es
--    veuen afectades perquè current_user és el owner de la funció (postgres),
--    no 'authenticated'.
--    El servei admin-portal (service_role) tampoc es veu afectat.
-- ============================================================================
CREATE OR REPLACE FUNCTION data.prevent_direct_credits_modification()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF NEW.signing_credits IS DISTINCT FROM OLD.signing_credits
     AND current_user = 'authenticated'
  THEN
    RAISE EXCEPTION 'signing_credits_readonly'
      USING HINT = 'Els crèdits de signatura es gestionen exclusivament per la plataforma. Usa les RPCs oficials.';
  END IF;
  RETURN NEW;
END;
$$;

-- Crear trigger (DROP IF EXISTS primer per idempotència en re-execució)
DROP TRIGGER IF EXISTS trg_prevent_credits_modification ON data.tenant_signing_config;
CREATE TRIGGER trg_prevent_credits_modification
  BEFORE UPDATE ON data.tenant_signing_config
  FOR EACH ROW EXECUTE FUNCTION data.prevent_direct_credits_modification();


-- ============================================================================
-- 5. Actualitzar api.tenant_signing_status per incloure feature_enabled
--    (compatibilitat cap enrere per codi que consulti la vista directament)
-- ============================================================================
DROP VIEW IF EXISTS api.tenant_signing_status;
CREATE VIEW api.tenant_signing_status WITH (security_invoker = true) AS
  SELECT
    c.tenant_id,
    c.mode,
    c.signing_credits,
    c.docuseal_api_url,
    c.is_active,
    c.admin_disabled,
    (c.is_active AND NOT c.admin_disabled)        AS effective_is_active,
    data.is_signing_feature_enabled(c.tenant_id)  AS feature_enabled,
    (
      data.is_signing_feature_enabled(c.tenant_id)
      AND NOT c.admin_disabled
    )                                              AS can_activate,
    c.created_at,
    c.updated_at
    -- docuseal_key_secret_id: EXCLÒS deliberadament
  FROM data.tenant_signing_config c;

GRANT SELECT ON api.tenant_signing_status TO authenticated;
GRANT SELECT ON api.tenant_signing_status TO service_role;
