-- =============================================================================
-- Migració: 20260427000005_hub_and_spoke_core.sql
-- Propòsit : Sistema de Feature Flags / Addons facturables (patró Hub and Spoke)
--            — Capa Hub: catàleg, subscripcions, vistes API, RPC, cron i auditoria
--
-- Conté:
--   1.  data.billing_addons          — Catàleg de mòduls disponibles (el Hub)
--   2.  data.tenant_addons           — Subscripcions actives per tenant
--   3.  RLS sobre ambdues taules
--   4.  Grants a prisma_admin / service_role
--   5.  Seed inicial: addon_custom_domains (vinculat a data.email_configs)
--   6.  api.addons                   — Vista pública del catàleg
--   7.  api.my_tenant_addons         — Vista filtrada per tenant actiu
--   8.  api.addon_billing_proration  — Vista de prorrateig en cancel·lació
--   9.  api.toggle_addon()           — RPC per activar/desactivar un mòdul
--  10.  data.expire_trials()         — Funció de desactivació automàtica de trials
--  11.  pg_cron job                  — Execució horària d'expire_trials
--  12.  data.trg_audit_tenant_addons() — Audit trigger per a cicle de vida d'addons
--
-- Patrons:
--   · RLS via data.jwt_user_tenants() (coherent amb la resta del projecte)
--   · SECURITY DEFINER als triggers i funcions d'escriptura
--   · Audit via data.log_audit_event()
--   · Toggle via RPC (no INSERT/UPDATE directe des del frontend)
--   · Trial cooldown per evitar abusos de períodes de prova
-- =============================================================================


-- ============================================================================
-- 1. data.billing_addons — Catàleg de mòduls disponibles
-- ============================================================================

CREATE TABLE IF NOT EXISTS data.billing_addons (
  id                    text          PRIMARY KEY,
    -- Identificador únic de l'addon. Ex: 'addon_custom_domains'
  name                  text          NOT NULL,
    -- Nom llegible. Ex: 'Dominis Personalitzats d''Email'
  price_monthly         numeric(10,2) NOT NULL DEFAULT 0
    CONSTRAINT chk_price_monthly CHECK (price_monthly >= 0),
    -- Preu mensual base de l'addon (0 = gratuït)
  trial_days            integer       NOT NULL DEFAULT 0
    CONSTRAINT chk_trial_days CHECK (trial_days >= 0),
    -- Dies de prova gratuïta. 0 = sense trial.
  trial_cooldown_months integer       NOT NULL DEFAULT 6
    CONSTRAINT chk_trial_cooldown CHECK (trial_cooldown_months >= 0),
    -- Mesos que han de passar per poder tornar a demanar un trial.
  spoke_config          jsonb         NOT NULL DEFAULT '{}'::jsonb,
    -- Defineix on s'aplica l'addon a les taules de configuració (Spokes).
    -- Ex: {"table": "email_configs", "features": {"custom_domains_enabled": true, "max_custom_domains": 1}}
  created_at            timestamptz   NOT NULL DEFAULT now(),
  updated_at            timestamptz   NOT NULL DEFAULT now()
);

COMMENT ON TABLE data.billing_addons
  IS 'Catàleg de mòduls/addons disponibles. Cada addon defineix el seu preu, trial i com s''aplica als Spokes via spoke_config.';

COMMENT ON COLUMN data.billing_addons.spoke_config
  IS 'JSON amb {table: string, features: {col: value}}. Defineix quina taula de data.* actualitzar i quins valors aplicar quan l''addon s''activa o desactiva.';


-- ============================================================================
-- 2. data.tenant_addons — Subscripcions actives per tenant
-- ============================================================================

CREATE TABLE IF NOT EXISTS data.tenant_addons (
  id                          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                   uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  addon_id                    text        NOT NULL REFERENCES data.billing_addons(id),
  status                      text        NOT NULL
    CONSTRAINT chk_addon_status CHECK (status IN ('active', 'trial', 'canceled', 'expired')),
    -- active   → pagant i en ús
    -- trial    → en període de prova gratuïta
    -- canceled → desactivat manualment (conserva dades; pot reactivar-se)
    -- expired  → trial caducat automàticament per pg_cron
  started_at                  timestamptz NOT NULL DEFAULT now(),
    -- Data d'inici de l'activació actual (es reinicia en cada reactivació)
  trial_ends_at               timestamptz,
    -- Quan expira el trial. NULL si no és trial.
  trial_available_again_at    timestamptz,
    -- Quan pot tornar a iniciar un trial (NULL = mai ha fet trial o cooldown passat)
  canceled_at                 timestamptz,
    -- Quan es va cancel·lar (per a càlculs de prorrateig)
  stripe_subscription_item_id text,
    -- ID de l'item a Stripe. Opcional per a integració futura.
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),

  -- Una sola fila per tenant + addon. L'status canvia al llarg del temps.
  CONSTRAINT uq_tenant_addon UNIQUE (tenant_id, addon_id)
);

CREATE INDEX IF NOT EXISTS idx_tenant_addons_tenant_id ON data.tenant_addons (tenant_id);
CREATE INDEX IF NOT EXISTS idx_tenant_addons_status    ON data.tenant_addons (status)
  WHERE status IN ('active', 'trial');
  -- Índex parcial per a l'expire_trials cron (evita full-scan)

COMMENT ON TABLE data.tenant_addons
  IS 'Subscripcions de tenants a addons. Una fila per (tenant, addon); l''status canvia de cicle de vida.';

COMMENT ON COLUMN data.tenant_addons.trial_available_again_at
  IS 'Timestamp a partir del qual el tenant pot tornar a demanar un trial. NULL = mai ha caducat (primer trial disponible).';


-- ============================================================================
-- 3. Row Level Security
-- ============================================================================

ALTER TABLE data.billing_addons ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.tenant_addons  ENABLE ROW LEVEL SECURITY;

-- billing_addons: catàleg públic de lectura per a tots els usuaris autenticats.
-- Escriptura reservada a prisma_admin / service_role (bypass RLS).
CREATE POLICY "billing_addons_select_authenticated"
  ON data.billing_addons
  FOR SELECT
  TO authenticated
  USING (true);

-- tenant_addons: cada tenant només veu les seves pròpies subscripcions.
-- L'accés d'escriptura és exclusivament via la RPC api.toggle_addon (SECURITY DEFINER).
CREATE POLICY "tenant_addons_select_own"
  ON data.tenant_addons
  FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );


-- ============================================================================
-- 4. Grants a prisma_admin i service_role
-- ============================================================================

GRANT SELECT, INSERT, UPDATE, DELETE ON data.billing_addons TO prisma_admin, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.tenant_addons  TO prisma_admin, service_role;

-- authenticated: lectura via vistes api.* (no accés directe a data.*)
GRANT SELECT ON data.billing_addons TO authenticated;
GRANT SELECT ON data.tenant_addons  TO authenticated;


-- ============================================================================
-- 5. Seed inicial: addon_custom_domains
--    Vincula el flag custom_domains_enabled de data.email_configs (Spoke)
--    amb el sistema de billing del Hub.
-- ============================================================================

INSERT INTO data.billing_addons (id, name, price_monthly, trial_days, trial_cooldown_months, spoke_config)
VALUES (
  'addon_custom_domains',
  'Dominis Personalitzats d''Email',
  9.99,
  14,
  6,
  '{"table": "email_configs", "features": {"custom_domains_enabled": true, "max_custom_domains": 1}}'::jsonb
)
ON CONFLICT (id) DO NOTHING;


-- ============================================================================
-- 6. api.addons — Vista pública del catàleg (per mostrar al tenant-portal)
-- ============================================================================

CREATE OR REPLACE VIEW api.addons
  WITH (security_invoker = true) AS
  SELECT
    id,
    name,
    price_monthly,
    trial_days,
    trial_cooldown_months,
    -- Exposem spoke_config al frontend per mostrar quines features activa cada addon.
    spoke_config
  FROM data.billing_addons;

GRANT SELECT ON api.addons TO authenticated;

COMMENT ON VIEW api.addons
  IS 'Catàleg de mòduls disponibles per a contractació. Lectura pública per a usuaris autenticats.';


-- ============================================================================
-- 7. api.my_tenant_addons — Vista filtrada per tenant actiu
--    Uneix les subscripcions amb el catàleg per donar context complet.
-- ============================================================================

CREATE OR REPLACE VIEW api.my_tenant_addons
  WITH (security_invoker = true) AS
  SELECT
    ta.id,
    ta.tenant_id,
    ta.addon_id,
    ba.name                   AS addon_name,
    ba.price_monthly,
    ba.trial_days,
    ba.spoke_config,
    ta.status,
    ta.started_at,
    ta.trial_ends_at,
    ta.trial_available_again_at,
    ta.canceled_at,
    ta.stripe_subscription_item_id,
    ta.created_at,
    ta.updated_at,
    -- Helpers calculats per al frontend
    (ta.trial_ends_at IS NOT NULL AND ta.trial_ends_at > now() AND ta.status = 'trial')
                              AS trial_is_active,
    -- Indica si el tenant podria iniciar un trial ara
    (
      ba.trial_days > 0
      AND ta.status NOT IN ('active', 'trial')
      AND (ta.trial_available_again_at IS NULL OR ta.trial_available_again_at <= now())
    )                         AS trial_available
  FROM data.tenant_addons ta
  JOIN data.billing_addons ba ON ba.id = ta.addon_id;

GRANT SELECT ON api.my_tenant_addons TO authenticated;

COMMENT ON VIEW api.my_tenant_addons
  IS 'Subscripcions d''addons del tenant actiu. Inclou càlculs d''estat de trial per al frontend.';


-- ============================================================================
-- 8. api.addon_billing_proration — Càlcul de prorrateig per cancel·lació
--    Calcula l'import teòric a facturar quan un addon es cancel·la
--    abans d'acabar el cicle mensual.
--    NOTA: Stripe farà el càlcul definitiu; aquesta vista és informativa
--          per a l'admin-portal i per a reconciliació.
-- ============================================================================

CREATE OR REPLACE VIEW api.addon_billing_proration
  WITH (security_invoker = true) AS
  SELECT
    ta.id,
    ta.tenant_id,
    ta.addon_id,
    ba.name                                         AS addon_name,
    ba.price_monthly,
    ta.status,
    ta.started_at,
    ta.canceled_at,

    -- Inici efectiu dins el mes de cancel·lació:
    -- Si l'addon es va activar en un mes anterior, usem l'inici del mes de cancel·lació.
    GREATEST(ta.started_at, date_trunc('month', ta.canceled_at))
                                                    AS billing_period_start,

    -- Dies usats en el cicle de facturació del mes de cancel·lació
    ROUND(
      EXTRACT(EPOCH FROM (
        ta.canceled_at
        - GREATEST(ta.started_at, date_trunc('month', ta.canceled_at))
      )) / 86400.0,
      2
    )                                               AS days_used,

    -- Nombre de dies del mes de cancel·lació
    EXTRACT(DAY FROM
      (date_trunc('month', ta.canceled_at) + INTERVAL '1 month - 1 day')
    )::integer                                      AS days_in_month,

    -- Import pendent teòric = price_monthly × dies_usats / dies_del_mes
    ROUND(
      ba.price_monthly
      * EXTRACT(EPOCH FROM (
          ta.canceled_at
          - GREATEST(ta.started_at, date_trunc('month', ta.canceled_at))
        )) / 86400.0
      / EXTRACT(DAY FROM
          (date_trunc('month', ta.canceled_at) + INTERVAL '1 month - 1 day')
        ),
      2
    )                                               AS prorated_amount_due

  FROM data.tenant_addons ta
  JOIN data.billing_addons ba ON ba.id = ta.addon_id
  WHERE ta.status      = 'canceled'
    AND ta.canceled_at IS NOT NULL;

-- Visible tant per al tenant-portal (veu les seves dades via RLS) com per a l'admin-portal.
GRANT SELECT ON api.addon_billing_proration TO authenticated;

COMMENT ON VIEW api.addon_billing_proration
  IS 'Import teòric pendent per addons cancel·lats antes d''acabar el cicle mensual. '
     'Informatiu per a l''admin-portal; Stripe fa el càlcul definitiu.';


-- ============================================================================
-- 9. api.toggle_addon() — RPC principal per activar/desactivar un addon
--
--    Lògica de negoci:
--      · p_enable = true:
--          - Si l'addon té trial i no s'ha usat mai (o cooldown passat) → 'trial'
--          - Altrament → 'active'
--          - Si ja estava 'active' o 'trial' → no-op (idempotent)
--      · p_enable = false:
--          - Canvia a 'canceled' i registra canceled_at
--          - Si ja estava 'canceled' o 'expired' → no-op
--
--    Seguretat:
--      · SECURITY DEFINER: escriu a data.tenant_addons saltant RLS
--      · Comprovació manual de rol: owner o manager del tenant actiu
--      · tenant_id sempre des de data.active_tenant_id() (header x-tenant-id)
-- ============================================================================

CREATE OR REPLACE FUNCTION api.toggle_addon(
  p_addon_id text,
  p_enable   boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data, public
AS $$
DECLARE
  v_tenant_id      uuid;
  v_user_role      text;
  v_addon          data.billing_addons%ROWTYPE;
  v_existing       data.tenant_addons%ROWTYPE;
  v_new_status     text;
  v_trial_ends_at  timestamptz;
  v_result         jsonb;
BEGIN
  -- ------------------------------------------------------------------
  -- 1. Contexte de tenant (obligatori per a aquesta operació)
  -- ------------------------------------------------------------------
  v_tenant_id := data.active_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Cal la capçalera x-tenant-id per gestionar addons.'
      USING ERRCODE = 'P0002';
  END IF;

  -- ------------------------------------------------------------------
  -- 2. Verificació de permisos: owner o manager global
  -- ------------------------------------------------------------------
  v_user_role := data.my_role_in(v_tenant_id);
  IF v_user_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'Permisos insuficients. Cal rol owner o manager per gestionar addons.'
      USING ERRCODE = '42501';
  END IF;

  -- ------------------------------------------------------------------
  -- 3. Carregar l'addon del catàleg
  -- ------------------------------------------------------------------
  SELECT * INTO v_addon FROM data.billing_addons WHERE id = p_addon_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Addon no trobat: %', p_addon_id
      USING ERRCODE = 'P0002';
  END IF;

  -- ------------------------------------------------------------------
  -- 4. Estat actual de la subscripció del tenant (si existeix)
  -- ------------------------------------------------------------------
  SELECT * INTO v_existing
    FROM data.tenant_addons
   WHERE tenant_id = v_tenant_id
     AND addon_id  = p_addon_id;

  -- ------------------------------------------------------------------
  -- 5. Activació
  -- ------------------------------------------------------------------
  IF p_enable THEN

    -- Idempotent: si ja està actiu o en trial, retornem l'estat actual
    IF v_existing.id IS NOT NULL AND v_existing.status IN ('active', 'trial') THEN
      SELECT jsonb_build_object(
        'tenant_id',               tenant_id,
        'addon_id',                addon_id,
        'status',                  status,
        'started_at',              started_at,
        'trial_ends_at',           trial_ends_at,
        'trial_available_again_at', trial_available_again_at
      ) INTO v_result
        FROM data.tenant_addons
       WHERE tenant_id = v_tenant_id AND addon_id = p_addon_id;
      RETURN v_result;
    END IF;

    -- Determinar el nou estat: trial o active
    IF v_addon.trial_days > 0
       AND (
         v_existing.id IS NULL                              -- mai ha subscrit
         OR (
           v_existing.trial_available_again_at IS NOT NULL
           AND v_existing.trial_available_again_at <= now() -- cooldown superat
         )
         OR (
           v_existing.trial_available_again_at IS NULL
           AND v_existing.status IN ('canceled', 'expired') -- caducat sense cooldown registrat (no hauria de passar, però safe)
         )
       ) THEN
      v_new_status    := 'trial';
      v_trial_ends_at := now() + (v_addon.trial_days || ' days')::interval;
    ELSE
      v_new_status    := 'active';
      v_trial_ends_at := NULL;
    END IF;

    IF v_existing.id IS NULL THEN
      -- Primera subscripció
      INSERT INTO data.tenant_addons (
        tenant_id, addon_id, status, started_at, trial_ends_at,
        trial_available_again_at, canceled_at
      ) VALUES (
        v_tenant_id, p_addon_id, v_new_status, now(), v_trial_ends_at,
        NULL, NULL
      );
    ELSE
      -- Reactivació (estava 'canceled' o 'expired')
      UPDATE data.tenant_addons
         SET status                   = v_new_status,
             started_at               = now(),
             trial_ends_at            = v_trial_ends_at,
             canceled_at              = NULL,
             updated_at               = now()
       WHERE tenant_id = v_tenant_id
         AND addon_id  = p_addon_id;
    END IF;

  -- ------------------------------------------------------------------
  -- 6. Desactivació
  -- ------------------------------------------------------------------
  ELSE

    -- Si no existeix o ja estava desactivat, no-op
    IF v_existing.id IS NULL OR v_existing.status IN ('canceled', 'expired') THEN
      IF v_existing.id IS NULL THEN
        RETURN jsonb_build_object(
          'tenant_id', v_tenant_id,
          'addon_id',  p_addon_id,
          'status',    'not_subscribed'
        );
      END IF;
      SELECT jsonb_build_object(
        'tenant_id',  tenant_id,
        'addon_id',   addon_id,
        'status',     status,
        'canceled_at', canceled_at
      ) INTO v_result
        FROM data.tenant_addons
       WHERE tenant_id = v_tenant_id AND addon_id = p_addon_id;
      RETURN v_result;
    END IF;

    UPDATE data.tenant_addons
       SET status      = 'canceled',
           canceled_at = now(),
           updated_at  = now()
     WHERE tenant_id = v_tenant_id
       AND addon_id  = p_addon_id
       AND status IN ('active', 'trial');

  END IF;

  -- ------------------------------------------------------------------
  -- 7. Retornar l'estat final
  -- ------------------------------------------------------------------
  SELECT jsonb_build_object(
    'tenant_id',               tenant_id,
    'addon_id',                addon_id,
    'status',                  status,
    'started_at',              started_at,
    'trial_ends_at',           trial_ends_at,
    'trial_available_again_at', trial_available_again_at,
    'canceled_at',             canceled_at
  ) INTO v_result
    FROM data.tenant_addons
   WHERE tenant_id = v_tenant_id AND addon_id = p_addon_id;

  RETURN v_result;
END;
$$;

-- Accessible per qualsevol usuari autenticat (la funció comprova permisos internament)
GRANT EXECUTE ON FUNCTION api.toggle_addon(text, boolean) TO authenticated;

COMMENT ON FUNCTION api.toggle_addon(text, boolean)
  IS 'Activa (true) o desactiva (false) un addon per al tenant actiu. '
     'Si l''addon té dies de trial i el cooldown ha passat, inicia un trial; altrament, activa directament. '
     'Requereix rol owner o manager. Usa la capçalera x-tenant-id per al context de tenant.';


-- ============================================================================
-- 10. data.expire_trials() — Desactivació automàtica de trials caducats
--
--     Crida aquesta funció periòdicament (via pg_cron) per caducar
--     tots els trials que hagin superat trial_ends_at.
--     El trigger sync_addon_to_spoke s'encarregarà de desactivar
--     les features als Spokes corresponents automàticament.
-- ============================================================================

CREATE OR REPLACE FUNCTION data.expire_trials()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_count integer := 0;
BEGIN
  UPDATE data.tenant_addons ta
     SET status                   = 'expired',
         -- Registra quan el tenant podrà tornar a demanar un trial
         trial_available_again_at = now() + (ba.trial_cooldown_months || ' months')::interval,
         updated_at               = now()
    FROM data.billing_addons ba
   WHERE ta.addon_id      = ba.id
     AND ta.status        = 'trial'
     AND ta.trial_ends_at < now();

  GET DIAGNOSTICS v_count = ROW_COUNT;

  IF v_count > 0 THEN
    RAISE NOTICE '[expire_trials] % trial(s) caducat(s) a %', v_count, now();
  END IF;

  RETURN v_count;
END;
$$;

-- Privat: la crida pg_cron com a superuser. No necessita grant a authenticated.
REVOKE ALL ON FUNCTION data.expire_trials() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.expire_trials() TO service_role;

COMMENT ON FUNCTION data.expire_trials()
  IS 'Caduca tots els trials amb trial_ends_at < now(). '
     'Actualitza status a expired i calcula trial_available_again_at. '
     'El trigger sync_addon_to_spoke aplica automàticament els canvis als Spokes.';


-- ============================================================================
-- 11. pg_cron — Programar expire_trials() cada hora (0 minuts de cada hora)
--     El job s'executa com a rol postgres (superuser), que pot cridar
--     funcions SECURITY DEFINER del schema data.
-- ============================================================================

DO $$
BEGIN
  -- Evitar duplicats si la migració es torna a executar (ex: db reset + re-apply)
  IF NOT EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'expire_addon_trials'
  ) THEN
    PERFORM cron.schedule(
      'expire_addon_trials',          -- nom del job
      '0 * * * *',                    -- cada hora en punt
      'SELECT data.expire_trials();'
    );
    RAISE NOTICE '[pg_cron] Job expire_addon_trials programat correctament.';
  END IF;
EXCEPTION
  -- Si pg_cron no és disponible (entorn sense l'extensió), continuem sense error
  WHEN undefined_table OR undefined_function THEN
    RAISE WARNING '[pg_cron] No disponible en aquest entorn. El job expire_addon_trials no s''ha programat.';
END;
$$;


-- ============================================================================
-- 12. Audit trigger — Cicle de vida dels addons
--
--     Accions registrades:
--       ADDON_ACTIVATED       → status canvia a 'active'
--       ADDON_TRIAL_STARTED   → status canvia a 'trial'
--       ADDON_CANCELED        → status canvia a 'canceled'
--       ADDON_EXPIRED         → status canvia a 'expired'
-- ============================================================================

CREATE OR REPLACE FUNCTION data.trg_audit_tenant_addons()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_action text;
BEGIN
  -- Determinar l'acció basada en el nou estat
  v_action := CASE NEW.status
    WHEN 'active'   THEN 'ADDON_ACTIVATED'
    WHEN 'trial'    THEN 'ADDON_TRIAL_STARTED'
    WHEN 'canceled' THEN 'ADDON_CANCELED'
    WHEN 'expired'  THEN 'ADDON_EXPIRED'
    ELSE NULL
  END;

  IF v_action IS NULL THEN
    RETURN NEW;
  END IF;

  -- En INSERT, sempre auditem. En UPDATE, només si l'status ha canviat.
  IF TG_OP = 'UPDATE' AND OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  PERFORM data.log_audit_event(
    p_tenant_id   => NEW.tenant_id,
    p_user_id     => COALESCE(auth.uid(), NULL),
      -- NULL quan és pg_cron (expire_trials); el payload dona context suficient
    p_site_id     => NULL,
    p_action      => v_action,
    p_entity_type => 'tenant_addon',
    p_entity_id   => NEW.id,
    p_payload     => jsonb_build_object(
      'addon_id',       NEW.addon_id,
      'status_new',     NEW.status,
      'status_old',     CASE WHEN TG_OP = 'UPDATE' THEN OLD.status ELSE NULL END,
      'started_at',     NEW.started_at,
      'trial_ends_at',  NEW.trial_ends_at,
      'canceled_at',    NEW.canceled_at
    )
  );

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_tenant_addons
  AFTER INSERT OR UPDATE OF status
  ON data.tenant_addons
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_audit_tenant_addons();

COMMENT ON FUNCTION data.trg_audit_tenant_addons()
  IS 'Registra els canvis de cicle de vida dels addons a data.audit_logs.';
