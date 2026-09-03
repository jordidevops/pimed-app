-- =============================================================================
-- Migration: 20260511000008_geocoding_control_plane.sql
-- Propòsit : Control Plane de Geocoding multi-provider amb límits, metering i
--            overage per tenant.
--
-- Conté:
--   1. Catàleg de providers i límits per pla/tenant
--   2. Configuració de provider per tenant (platform vs byo)
--   3. Comptadors de finestres (minute/day/month) per rate limiting
--   4. Ledger append-only d'ús + rollups diari/mensual
--   5. RPCs:
--      · api.check_and_reserve_geocoding
--      · api.log_geocoding_usage
--   6. Auditoria de canvis de configuració
--   7. Extensió de api.tenant_entitlements amb camps de geocoding
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Catàleg de providers + límits
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS data.geocoding_providers (
  provider_key                           text          PRIMARY KEY,
  name                                   text          NOT NULL,
  is_active                              boolean       NOT NULL DEFAULT true,
  default_included_total_requests_month  integer
    CHECK (default_included_total_requests_month IS NULL OR default_included_total_requests_month >= 0),
  default_included_search_requests_month integer
    CHECK (default_included_search_requests_month IS NULL OR default_included_search_requests_month >= 0),
  default_included_reverse_requests_month integer
    CHECK (default_included_reverse_requests_month IS NULL OR default_included_reverse_requests_month >= 0),
  default_rate_limit_per_minute          integer       NOT NULL DEFAULT 60
    CHECK (default_rate_limit_per_minute > 0),
  default_rate_limit_per_day             integer       NOT NULL DEFAULT 5000
    CHECK (default_rate_limit_per_day > 0),
  default_enforce_hard_cap               boolean       NOT NULL DEFAULT false,
  default_allow_overage                  boolean       NOT NULL DEFAULT true,
  default_billable                       boolean       NOT NULL DEFAULT false,
  default_overage_price_per_1000         numeric(12,6) NOT NULL DEFAULT 0
    CHECK (default_overage_price_per_1000 >= 0),
  default_currency                       text          NOT NULL DEFAULT 'EUR',
  metadata                               jsonb         NOT NULL DEFAULT '{}'::jsonb,
  created_at                             timestamptz   NOT NULL DEFAULT now(),
  updated_at                             timestamptz   NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS data.plan_geocoding_limits (
  plan_id                                uuid          NOT NULL REFERENCES data.plans(id) ON DELETE CASCADE,
  provider_key                           text          NOT NULL REFERENCES data.geocoding_providers(provider_key) ON DELETE CASCADE,
  included_total_requests_month          integer
    CHECK (included_total_requests_month IS NULL OR included_total_requests_month >= 0),
  included_search_requests_month         integer
    CHECK (included_search_requests_month IS NULL OR included_search_requests_month >= 0),
  included_reverse_requests_month        integer
    CHECK (included_reverse_requests_month IS NULL OR included_reverse_requests_month >= 0),
  rate_limit_per_minute                  integer       NOT NULL DEFAULT 60
    CHECK (rate_limit_per_minute > 0),
  rate_limit_per_day                     integer       NOT NULL DEFAULT 5000
    CHECK (rate_limit_per_day > 0),
  enforce_hard_cap                       boolean       NOT NULL DEFAULT false,
  allow_overage                          boolean       NOT NULL DEFAULT true,
  billable                               boolean       NOT NULL DEFAULT false,
  overage_price_per_1000                 numeric(12,6) NOT NULL DEFAULT 0
    CHECK (overage_price_per_1000 >= 0),
  currency                               text          NOT NULL DEFAULT 'EUR',
  metadata                               jsonb         NOT NULL DEFAULT '{}'::jsonb,
  created_at                             timestamptz   NOT NULL DEFAULT now(),
  updated_at                             timestamptz   NOT NULL DEFAULT now(),
  PRIMARY KEY (plan_id, provider_key)
);

CREATE TABLE IF NOT EXISTS data.tenant_geocoding_limit_overrides (
  tenant_id                              uuid          NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  provider_key                           text          NOT NULL REFERENCES data.geocoding_providers(provider_key) ON DELETE CASCADE,
  included_total_requests_month          integer
    CHECK (included_total_requests_month IS NULL OR included_total_requests_month >= 0),
  included_search_requests_month         integer
    CHECK (included_search_requests_month IS NULL OR included_search_requests_month >= 0),
  included_reverse_requests_month        integer
    CHECK (included_reverse_requests_month IS NULL OR included_reverse_requests_month >= 0),
  rate_limit_per_minute                  integer       CHECK (rate_limit_per_minute > 0),
  rate_limit_per_day                     integer       CHECK (rate_limit_per_day > 0),
  enforce_hard_cap                       boolean,
  allow_overage                          boolean,
  billable                               boolean,
  overage_price_per_1000                 numeric(12,6)
    CHECK (overage_price_per_1000 IS NULL OR overage_price_per_1000 >= 0),
  currency                               text,
  metadata                               jsonb         NOT NULL DEFAULT '{}'::jsonb,
  created_at                             timestamptz   NOT NULL DEFAULT now(),
  updated_at                             timestamptz   NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, provider_key)
);

CREATE TABLE IF NOT EXISTS data.tenant_geocoding_provider_configs (
  tenant_id                              uuid          NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  provider_key                           text          NOT NULL REFERENCES data.geocoding_providers(provider_key) ON DELETE CASCADE,
  mode                                   text          NOT NULL DEFAULT 'platform'
    CHECK (mode IN ('platform', 'byo')),
  is_enabled                             boolean       NOT NULL DEFAULT true,
  priority                               smallint      NOT NULL DEFAULT 100,
  api_key_secret_ref                     text,
  config                                 jsonb         NOT NULL DEFAULT '{}'::jsonb,
  last_used_at                           timestamptz,
  created_at                             timestamptz   NOT NULL DEFAULT now(),
  updated_at                             timestamptz   NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, provider_key)
);

CREATE INDEX IF NOT EXISTS idx_tenant_geo_provider_configs_tenant_priority
  ON data.tenant_geocoding_provider_configs (tenant_id, is_enabled, priority);

COMMENT ON TABLE data.geocoding_providers
  IS 'Catàleg de providers de geocoding i valors per defecte de quota/rate/billing.';

COMMENT ON TABLE data.plan_geocoding_limits
  IS 'Límits i política de billing de geocoding per pla i provider.';

COMMENT ON TABLE data.tenant_geocoding_limit_overrides
  IS 'Overrides per tenant dels límits de geocoding (si un camp és NULL, hereta del pla/provider).';

COMMENT ON TABLE data.tenant_geocoding_provider_configs
  IS 'Configuració per tenant i provider: platform (factura la plataforma) o byo (Bring Your Own key).';

-- ---------------------------------------------------------------------------
-- 2) Comptadors i metering
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS data.geocoding_rate_windows (
  tenant_id      uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  provider_key   text        NOT NULL REFERENCES data.geocoding_providers(provider_key) ON DELETE CASCADE,
  operation      text        NOT NULL CHECK (operation IN ('all', 'search', 'reverse')),
  window_kind    text        NOT NULL CHECK (window_kind IN ('minute', 'day', 'month')),
  window_start   timestamptz NOT NULL,
  request_count  integer     NOT NULL DEFAULT 0 CHECK (request_count >= 0),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, provider_key, operation, window_kind, window_start)
);

CREATE INDEX IF NOT EXISTS idx_geocoding_rate_windows_updated
  ON data.geocoding_rate_windows (updated_at DESC);

CREATE TABLE IF NOT EXISTS data.geocoding_usage_ledger (
  id               uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid          NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id          uuid          REFERENCES data.sites(id) ON DELETE SET NULL,
  provider_key     text          NOT NULL REFERENCES data.geocoding_providers(provider_key) ON DELETE RESTRICT,
  operation        text          NOT NULL CHECK (operation IN ('search', 'reverse')),
  request_status   text          NOT NULL CHECK (
    request_status IN (
      'success',
      'cached',
      'provider_error',
      'network_error',
      'blocked_rate_limit',
      'blocked_quota',
      'validation_error'
    )
  ),
  cache_hit        boolean       NOT NULL DEFAULT false,
  billing_source   text          NOT NULL DEFAULT 'platform' CHECK (billing_source IN ('platform', 'byo', 'none')),
  billable_units   integer       NOT NULL DEFAULT 0 CHECK (billable_units >= 0),
  unit_price       numeric(12,6) NOT NULL DEFAULT 0 CHECK (unit_price >= 0),
  cost_amount      numeric(14,6) GENERATED ALWAYS AS (billable_units::numeric * unit_price) STORED,
  request_id       text,
  idempotency_key  text,
  payload          jsonb         NOT NULL DEFAULT '{}'::jsonb,
  created_at       timestamptz   NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_geocoding_usage_tenant_idempotency
  ON data.geocoding_usage_ledger (tenant_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_geocoding_usage_tenant_created
  ON data.geocoding_usage_ledger (tenant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_geocoding_usage_tenant_provider_created
  ON data.geocoding_usage_ledger (tenant_id, provider_key, created_at DESC);

CREATE TABLE IF NOT EXISTS data.geocoding_usage_daily (
  tenant_id          uuid          NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  provider_key       text          NOT NULL REFERENCES data.geocoding_providers(provider_key) ON DELETE CASCADE,
  usage_date         date          NOT NULL,
  total_requests     integer       NOT NULL DEFAULT 0,
  search_requests    integer       NOT NULL DEFAULT 0,
  reverse_requests   integer       NOT NULL DEFAULT 0,
  successful_requests integer      NOT NULL DEFAULT 0,
  blocked_requests   integer       NOT NULL DEFAULT 0,
  billable_units     bigint        NOT NULL DEFAULT 0,
  cost_amount        numeric(14,6) NOT NULL DEFAULT 0,
  updated_at         timestamptz   NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, provider_key, usage_date)
);

CREATE TABLE IF NOT EXISTS data.geocoding_usage_monthly (
  tenant_id           uuid          NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  provider_key        text          NOT NULL REFERENCES data.geocoding_providers(provider_key) ON DELETE CASCADE,
  usage_month         date          NOT NULL,
  total_requests      integer       NOT NULL DEFAULT 0,
  search_requests     integer       NOT NULL DEFAULT 0,
  reverse_requests    integer       NOT NULL DEFAULT 0,
  successful_requests integer       NOT NULL DEFAULT 0,
  blocked_requests    integer       NOT NULL DEFAULT 0,
  billable_units      bigint        NOT NULL DEFAULT 0,
  cost_amount         numeric(14,6) NOT NULL DEFAULT 0,
  updated_at          timestamptz   NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, provider_key, usage_month)
);

COMMENT ON TABLE data.geocoding_rate_windows
  IS 'Comptadors de finestres de geocoding (minute/day/month) per enforcement de rate-limit i quota.';

COMMENT ON TABLE data.geocoding_usage_ledger
  IS 'Ledger append-only de peticions geocoding (per auditoria, facturació i analítica).';

COMMENT ON TABLE data.geocoding_usage_daily
  IS 'Agregat diari derivat de geocoding_usage_ledger.';

COMMENT ON TABLE data.geocoding_usage_monthly
  IS 'Agregat mensual derivat de geocoding_usage_ledger.';

-- updated_at
DROP TRIGGER IF EXISTS trg_geocoding_providers_updated_at ON data.geocoding_providers;
CREATE TRIGGER trg_geocoding_providers_updated_at
  BEFORE UPDATE ON data.geocoding_providers
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

DROP TRIGGER IF EXISTS trg_plan_geocoding_limits_updated_at ON data.plan_geocoding_limits;
CREATE TRIGGER trg_plan_geocoding_limits_updated_at
  BEFORE UPDATE ON data.plan_geocoding_limits
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

DROP TRIGGER IF EXISTS trg_tenant_geocoding_limit_overrides_updated_at ON data.tenant_geocoding_limit_overrides;
CREATE TRIGGER trg_tenant_geocoding_limit_overrides_updated_at
  BEFORE UPDATE ON data.tenant_geocoding_limit_overrides
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

DROP TRIGGER IF EXISTS trg_tenant_geocoding_provider_configs_updated_at ON data.tenant_geocoding_provider_configs;
CREATE TRIGGER trg_tenant_geocoding_provider_configs_updated_at
  BEFORE UPDATE ON data.tenant_geocoding_provider_configs
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

DROP TRIGGER IF EXISTS trg_geocoding_usage_daily_updated_at ON data.geocoding_usage_daily;
CREATE TRIGGER trg_geocoding_usage_daily_updated_at
  BEFORE UPDATE ON data.geocoding_usage_daily
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

DROP TRIGGER IF EXISTS trg_geocoding_usage_monthly_updated_at ON data.geocoding_usage_monthly;
CREATE TRIGGER trg_geocoding_usage_monthly_updated_at
  BEFORE UPDATE ON data.geocoding_usage_monthly
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

-- ---------------------------------------------------------------------------
-- 3) Helpers de resolució de límits i increments atòmics
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.get_effective_geocoding_limits(
  p_tenant_id    uuid,
  p_provider_key text
)
RETURNS TABLE (
  provider_key                    text,
  mode                            text,
  is_enabled                      boolean,
  included_total_requests_month   integer,
  included_search_requests_month  integer,
  included_reverse_requests_month integer,
  rate_limit_per_minute           integer,
  rate_limit_per_day              integer,
  enforce_hard_cap                boolean,
  allow_overage                   boolean,
  billable                        boolean,
  overage_price_per_1000          numeric(12,6),
  currency                        text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT
    p_provider_key AS provider_key,
    COALESCE(cfg.mode, 'platform') AS mode,
    (COALESCE(cfg.is_enabled, true) AND COALESCE(gp.is_active, false)) AS is_enabled,
    COALESCE(ovr.included_total_requests_month,   pl.included_total_requests_month,   gp.default_included_total_requests_month)   AS included_total_requests_month,
    COALESCE(ovr.included_search_requests_month,  pl.included_search_requests_month,  gp.default_included_search_requests_month)  AS included_search_requests_month,
    COALESCE(ovr.included_reverse_requests_month, pl.included_reverse_requests_month, gp.default_included_reverse_requests_month) AS included_reverse_requests_month,
    COALESCE(ovr.rate_limit_per_minute, pl.rate_limit_per_minute, gp.default_rate_limit_per_minute, 60) AS rate_limit_per_minute,
    COALESCE(ovr.rate_limit_per_day,    pl.rate_limit_per_day,    gp.default_rate_limit_per_day, 5000) AS rate_limit_per_day,
    COALESCE(ovr.enforce_hard_cap,      pl.enforce_hard_cap,      gp.default_enforce_hard_cap, false)  AS enforce_hard_cap,
    COALESCE(ovr.allow_overage,         pl.allow_overage,         gp.default_allow_overage, true)      AS allow_overage,
    COALESCE(ovr.billable,              pl.billable,              gp.default_billable, false)          AS billable,
    COALESCE(ovr.overage_price_per_1000, pl.overage_price_per_1000, gp.default_overage_price_per_1000, 0) AS overage_price_per_1000,
    COALESCE(ovr.currency, pl.currency, gp.default_currency, 'EUR') AS currency
  FROM data.tenants t
  LEFT JOIN data.geocoding_providers gp
    ON gp.provider_key = p_provider_key
  LEFT JOIN data.plan_geocoding_limits pl
    ON pl.plan_id = t.plan_id
   AND pl.provider_key = p_provider_key
  LEFT JOIN data.tenant_geocoding_limit_overrides ovr
    ON ovr.tenant_id = t.id
   AND ovr.provider_key = p_provider_key
  LEFT JOIN data.tenant_geocoding_provider_configs cfg
    ON cfg.tenant_id = t.id
   AND cfg.provider_key = p_provider_key
  WHERE t.id = p_tenant_id;
$$;

CREATE OR REPLACE FUNCTION data.bump_geocoding_window(
  p_tenant_id    uuid,
  p_provider_key text,
  p_operation    text,
  p_window_kind  text,
  p_window_start timestamptz,
  p_delta        integer
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_count integer;
BEGIN
  INSERT INTO data.geocoding_rate_windows (
    tenant_id,
    provider_key,
    operation,
    window_kind,
    window_start,
    request_count,
    updated_at
  )
  VALUES (
    p_tenant_id,
    p_provider_key,
    p_operation,
    p_window_kind,
    p_window_start,
    p_delta,
    now()
  )
  ON CONFLICT (tenant_id, provider_key, operation, window_kind, window_start)
  DO UPDATE
    SET request_count = data.geocoding_rate_windows.request_count + EXCLUDED.request_count,
        updated_at = now()
  RETURNING request_count INTO v_count;

  RETURN v_count;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4) RPC: check_and_reserve_geocoding
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.check_and_reserve_geocoding(
  p_tenant_id    uuid,
  p_provider_key text,
  p_operation    text,
  p_units        integer DEFAULT 1
)
RETURNS TABLE (
  allowed                boolean,
  reason                 text,
  mode                   text,
  billable               boolean,
  billable_units         integer,
  unit_price             numeric(12,6),
  currency               text,
  minute_used            integer,
  minute_limit           integer,
  day_used               integer,
  day_limit              integer,
  month_used_total       integer,
  month_limit_total      integer,
  month_used_operation   integer,
  month_limit_operation  integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_provider_exists               boolean;
  v_limits                       RECORD;
  v_now                          timestamptz := now();
  v_minute_start                 timestamptz;
  v_day_start                    timestamptz;
  v_month_start                  timestamptz;
  v_allowed                      boolean := true;
  v_reason                       text := 'ok';
  v_billable_units               integer := 0;
  v_unit_price                   numeric(12,6) := 0;
  v_month_limit_operation        integer;
  v_month_limit_total            integer;
  v_total_before                 integer;
BEGIN
  IF p_operation NOT IN ('search', 'reverse') THEN
    RAISE EXCEPTION 'invalid operation: %', p_operation;
  END IF;

  IF p_units IS NULL OR p_units <= 0 THEN
    RAISE EXCEPTION 'p_units must be >= 1';
  END IF;

  SELECT EXISTS (
    SELECT 1
      FROM data.geocoding_providers gp
     WHERE gp.provider_key = p_provider_key
  )
  INTO v_provider_exists;

  IF NOT v_provider_exists THEN
    RETURN QUERY SELECT
      false,
      'provider_not_found',
      NULL::text,
      false,
      0,
      0::numeric(12,6),
      'EUR'::text,
      0,
      0,
      0,
      0,
      0,
      NULL::integer,
      0,
      NULL::integer;
    RETURN;
  END IF;

  SELECT * INTO v_limits
  FROM data.get_effective_geocoding_limits(p_tenant_id, p_provider_key);

  IF NOT FOUND THEN
    RETURN QUERY SELECT
      false,
      'tenant_not_found',
      NULL::text,
      false,
      0,
      0::numeric(12,6),
      'EUR'::text,
      0,
      0,
      0,
      0,
      0,
      NULL::integer,
      0,
      NULL::integer;
    RETURN;
  END IF;

  IF COALESCE(v_limits.is_enabled, false) = false THEN
    RETURN QUERY SELECT
      false,
      'provider_disabled',
      v_limits.mode,
      false,
      0,
      0::numeric(12,6),
      v_limits.currency,
      0,
      v_limits.rate_limit_per_minute,
      0,
      v_limits.rate_limit_per_day,
      0,
      v_limits.included_total_requests_month,
      0,
      CASE
        WHEN p_operation = 'search' THEN v_limits.included_search_requests_month
        ELSE v_limits.included_reverse_requests_month
      END;
    RETURN;
  END IF;

  -- Lock per tenant+provider+operation per evitar races en comptadors de quota/rate.
  PERFORM pg_advisory_xact_lock(
    hashtext('geo:' || p_tenant_id::text || ':' || p_provider_key || ':' || p_operation)
  );

  v_minute_start := date_trunc('minute', v_now);
  v_day_start    := date_trunc('day', v_now);
  v_month_start  := date_trunc('month', v_now);

  minute_used := data.bump_geocoding_window(
    p_tenant_id,
    p_provider_key,
    'all',
    'minute',
    v_minute_start,
    p_units
  );

  day_used := data.bump_geocoding_window(
    p_tenant_id,
    p_provider_key,
    'all',
    'day',
    v_day_start,
    p_units
  );

  month_used_total := data.bump_geocoding_window(
    p_tenant_id,
    p_provider_key,
    'all',
    'month',
    v_month_start,
    p_units
  );

  month_used_operation := data.bump_geocoding_window(
    p_tenant_id,
    p_provider_key,
    p_operation,
    'month',
    v_month_start,
    p_units
  );

  minute_limit := v_limits.rate_limit_per_minute;
  day_limit := v_limits.rate_limit_per_day;
  month_limit_total := v_limits.included_total_requests_month;

  month_limit_operation := CASE
    WHEN p_operation = 'search' THEN v_limits.included_search_requests_month
    ELSE v_limits.included_reverse_requests_month
  END;

  IF minute_used > minute_limit THEN
    v_allowed := false;
    v_reason := 'rate_limit_minute_exceeded';
  ELSIF day_used > day_limit THEN
    v_allowed := false;
    v_reason := 'rate_limit_day_exceeded';
  END IF;

  IF v_allowed THEN
    v_month_limit_operation := COALESCE(month_limit_operation, month_limit_total);
    v_month_limit_total := month_limit_total;

    IF v_month_limit_operation IS NOT NULL
       AND month_used_operation > v_month_limit_operation
       AND COALESCE(v_limits.enforce_hard_cap, false)
       AND NOT COALESCE(v_limits.allow_overage, true) THEN
      v_allowed := false;
      v_reason := 'quota_operation_exceeded';
    ELSIF v_month_limit_total IS NOT NULL
       AND month_used_total > v_month_limit_total
       AND COALESCE(v_limits.enforce_hard_cap, false)
       AND NOT COALESCE(v_limits.allow_overage, true) THEN
      v_allowed := false;
      v_reason := 'quota_total_exceeded';
    END IF;
  END IF;

  v_billable_units := 0;
  IF v_allowed
     AND COALESCE(v_limits.mode, 'platform') = 'platform'
     AND COALESCE(v_limits.billable, false)
     AND month_limit_total IS NOT NULL THEN
    v_total_before := month_used_total - p_units;
    IF v_total_before >= month_limit_total THEN
      v_billable_units := p_units;
    ELSIF month_used_total > month_limit_total THEN
      v_billable_units := month_used_total - month_limit_total;
    END IF;
  END IF;

  IF v_billable_units > 0 THEN
    v_unit_price := COALESCE(v_limits.overage_price_per_1000, 0) / 1000.0;
  END IF;

  allowed := v_allowed;
  reason := v_reason;
  mode := v_limits.mode;
  billable := COALESCE(v_limits.billable, false) AND v_billable_units > 0;
  billable_units := v_billable_units;
  unit_price := v_unit_price;
  currency := COALESCE(v_limits.currency, 'EUR');

  RETURN NEXT;
END;
$$;

REVOKE ALL   ON FUNCTION api.check_and_reserve_geocoding(uuid, text, text, integer) FROM PUBLIC;
REVOKE ALL   ON FUNCTION api.check_and_reserve_geocoding(uuid, text, text, integer) FROM authenticated;
REVOKE ALL   ON FUNCTION api.check_and_reserve_geocoding(uuid, text, text, integer) FROM anon;
GRANT EXECUTE ON FUNCTION api.check_and_reserve_geocoding(uuid, text, text, integer) TO service_role;
GRANT EXECUTE ON FUNCTION api.check_and_reserve_geocoding(uuid, text, text, integer) TO prisma_admin;

-- ---------------------------------------------------------------------------
-- 5) RPC: log_geocoding_usage
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.log_geocoding_usage(
  p_tenant_id       uuid,
  p_provider_key    text,
  p_operation       text,
  p_request_status  text,
  p_cache_hit       boolean DEFAULT false,
  p_billing_source  text DEFAULT 'platform',
  p_billable_units  integer DEFAULT 0,
  p_unit_price      numeric(12,6) DEFAULT 0,
  p_site_id         uuid DEFAULT NULL,
  p_request_id      text DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL,
  p_payload         jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_event_id            uuid;
  v_created_at          timestamptz;
  v_cost                numeric(14,6);
  v_search_inc          integer := CASE WHEN p_operation = 'search' THEN 1 ELSE 0 END;
  v_reverse_inc         integer := CASE WHEN p_operation = 'reverse' THEN 1 ELSE 0 END;
  v_success_inc         integer := CASE WHEN p_request_status IN ('success', 'cached') THEN 1 ELSE 0 END;
  v_blocked_inc         integer := CASE WHEN p_request_status LIKE 'blocked_%' THEN 1 ELSE 0 END;
  v_usage_date          date;
  v_usage_month         date;
BEGIN
  IF p_operation NOT IN ('search', 'reverse') THEN
    RAISE EXCEPTION 'invalid operation: %', p_operation;
  END IF;

  IF p_request_status NOT IN (
    'success',
    'cached',
    'provider_error',
    'network_error',
    'blocked_rate_limit',
    'blocked_quota',
    'validation_error'
  ) THEN
    RAISE EXCEPTION 'invalid request_status: %', p_request_status;
  END IF;

  IF p_billing_source NOT IN ('platform', 'byo', 'none') THEN
    RAISE EXCEPTION 'invalid billing_source: %', p_billing_source;
  END IF;

  IF p_billable_units < 0 THEN
    RAISE EXCEPTION 'p_billable_units must be >= 0';
  END IF;

  IF p_unit_price < 0 THEN
    RAISE EXCEPTION 'p_unit_price must be >= 0';
  END IF;

  INSERT INTO data.geocoding_usage_ledger (
    tenant_id,
    site_id,
    provider_key,
    operation,
    request_status,
    cache_hit,
    billing_source,
    billable_units,
    unit_price,
    request_id,
    idempotency_key,
    payload
  ) VALUES (
    p_tenant_id,
    p_site_id,
    p_provider_key,
    p_operation,
    p_request_status,
    COALESCE(p_cache_hit, false),
    p_billing_source,
    p_billable_units,
    p_unit_price,
    p_request_id,
    p_idempotency_key,
    COALESCE(p_payload, '{}'::jsonb)
  )
  ON CONFLICT (tenant_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL
  DO NOTHING
  RETURNING id, created_at, cost_amount
  INTO v_event_id, v_created_at, v_cost;

  IF v_event_id IS NULL THEN
    SELECT l.id
      INTO v_event_id
      FROM data.geocoding_usage_ledger l
     WHERE l.tenant_id = p_tenant_id
       AND l.idempotency_key = p_idempotency_key
     LIMIT 1;

    RETURN v_event_id;
  END IF;

  v_usage_date := v_created_at::date;
  v_usage_month := date_trunc('month', v_created_at)::date;

  INSERT INTO data.geocoding_usage_daily (
    tenant_id,
    provider_key,
    usage_date,
    total_requests,
    search_requests,
    reverse_requests,
    successful_requests,
    blocked_requests,
    billable_units,
    cost_amount,
    updated_at
  ) VALUES (
    p_tenant_id,
    p_provider_key,
    v_usage_date,
    1,
    v_search_inc,
    v_reverse_inc,
    v_success_inc,
    v_blocked_inc,
    p_billable_units,
    COALESCE(v_cost, 0),
    now()
  )
  ON CONFLICT (tenant_id, provider_key, usage_date)
  DO UPDATE
    SET total_requests      = data.geocoding_usage_daily.total_requests + 1,
        search_requests     = data.geocoding_usage_daily.search_requests + EXCLUDED.search_requests,
        reverse_requests    = data.geocoding_usage_daily.reverse_requests + EXCLUDED.reverse_requests,
        successful_requests = data.geocoding_usage_daily.successful_requests + EXCLUDED.successful_requests,
        blocked_requests    = data.geocoding_usage_daily.blocked_requests + EXCLUDED.blocked_requests,
        billable_units      = data.geocoding_usage_daily.billable_units + EXCLUDED.billable_units,
        cost_amount         = data.geocoding_usage_daily.cost_amount + EXCLUDED.cost_amount,
        updated_at          = now();

  INSERT INTO data.geocoding_usage_monthly (
    tenant_id,
    provider_key,
    usage_month,
    total_requests,
    search_requests,
    reverse_requests,
    successful_requests,
    blocked_requests,
    billable_units,
    cost_amount,
    updated_at
  ) VALUES (
    p_tenant_id,
    p_provider_key,
    v_usage_month,
    1,
    v_search_inc,
    v_reverse_inc,
    v_success_inc,
    v_blocked_inc,
    p_billable_units,
    COALESCE(v_cost, 0),
    now()
  )
  ON CONFLICT (tenant_id, provider_key, usage_month)
  DO UPDATE
    SET total_requests      = data.geocoding_usage_monthly.total_requests + 1,
        search_requests     = data.geocoding_usage_monthly.search_requests + EXCLUDED.search_requests,
        reverse_requests    = data.geocoding_usage_monthly.reverse_requests + EXCLUDED.reverse_requests,
        successful_requests = data.geocoding_usage_monthly.successful_requests + EXCLUDED.successful_requests,
        blocked_requests    = data.geocoding_usage_monthly.blocked_requests + EXCLUDED.blocked_requests,
        billable_units      = data.geocoding_usage_monthly.billable_units + EXCLUDED.billable_units,
        cost_amount         = data.geocoding_usage_monthly.cost_amount + EXCLUDED.cost_amount,
        updated_at          = now();

  RETURN v_event_id;
END;
$$;

REVOKE ALL   ON FUNCTION api.log_geocoding_usage(uuid, text, text, text, boolean, text, integer, numeric, uuid, text, text, jsonb) FROM PUBLIC;
REVOKE ALL   ON FUNCTION api.log_geocoding_usage(uuid, text, text, text, boolean, text, integer, numeric, uuid, text, text, jsonb) FROM authenticated;
REVOKE ALL   ON FUNCTION api.log_geocoding_usage(uuid, text, text, text, boolean, text, integer, numeric, uuid, text, text, jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION api.log_geocoding_usage(uuid, text, text, text, boolean, text, integer, numeric, uuid, text, text, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION api.log_geocoding_usage(uuid, text, text, text, boolean, text, integer, numeric, uuid, text, text, jsonb) TO prisma_admin;

-- ---------------------------------------------------------------------------
-- 6) Auditoria de canvis de configuració
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.trg_audit_tenant_geocoding_provider_configs()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_actor uuid := auth.uid();
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      v_actor,
      NULL,
      'TENANT_GEOCODING_PROVIDER_CONFIG_CREATED',
      'tenant_geocoding_provider_config',
      NULL,
      jsonb_build_object(
        'provider_key', NEW.provider_key,
        'mode', NEW.mode,
        'is_enabled', NEW.is_enabled,
        'priority', NEW.priority
      )
    );
  ELSIF TG_OP = 'UPDATE' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      v_actor,
      NULL,
      'TENANT_GEOCODING_PROVIDER_CONFIG_UPDATED',
      'tenant_geocoding_provider_config',
      NULL,
      jsonb_build_object(
        'provider_key', NEW.provider_key,
        'old', jsonb_build_object(
          'mode', OLD.mode,
          'is_enabled', OLD.is_enabled,
          'priority', OLD.priority,
          'api_key_secret_ref', OLD.api_key_secret_ref
        ),
        'new', jsonb_build_object(
          'mode', NEW.mode,
          'is_enabled', NEW.is_enabled,
          'priority', NEW.priority,
          'api_key_secret_ref', NEW.api_key_secret_ref
        )
      )
    );
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id,
      v_actor,
      NULL,
      'TENANT_GEOCODING_PROVIDER_CONFIG_DELETED',
      'tenant_geocoding_provider_config',
      NULL,
      jsonb_build_object(
        'provider_key', OLD.provider_key,
        'mode', OLD.mode,
        'is_enabled', OLD.is_enabled,
        'priority', OLD.priority
      )
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_tenant_geocoding_provider_configs
  ON data.tenant_geocoding_provider_configs;

CREATE TRIGGER trg_audit_tenant_geocoding_provider_configs
  AFTER INSERT OR UPDATE OR DELETE ON data.tenant_geocoding_provider_configs
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_tenant_geocoding_provider_configs();

CREATE OR REPLACE FUNCTION data.trg_audit_tenant_geocoding_limit_overrides()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_actor uuid := auth.uid();
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      v_actor,
      NULL,
      'TENANT_GEOCODING_LIMIT_OVERRIDE_CREATED',
      'tenant_geocoding_limit_override',
      NULL,
      jsonb_build_object(
        'provider_key', NEW.provider_key,
        'included_total_requests_month', NEW.included_total_requests_month,
        'rate_limit_per_minute', NEW.rate_limit_per_minute,
        'rate_limit_per_day', NEW.rate_limit_per_day,
        'enforce_hard_cap', NEW.enforce_hard_cap,
        'allow_overage', NEW.allow_overage,
        'billable', NEW.billable
      )
    );
  ELSIF TG_OP = 'UPDATE' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      v_actor,
      NULL,
      'TENANT_GEOCODING_LIMIT_OVERRIDE_UPDATED',
      'tenant_geocoding_limit_override',
      NULL,
      jsonb_build_object(
        'provider_key', NEW.provider_key,
        'old', jsonb_build_object(
          'included_total_requests_month', OLD.included_total_requests_month,
          'included_search_requests_month', OLD.included_search_requests_month,
          'included_reverse_requests_month', OLD.included_reverse_requests_month,
          'rate_limit_per_minute', OLD.rate_limit_per_minute,
          'rate_limit_per_day', OLD.rate_limit_per_day,
          'enforce_hard_cap', OLD.enforce_hard_cap,
          'allow_overage', OLD.allow_overage,
          'billable', OLD.billable,
          'overage_price_per_1000', OLD.overage_price_per_1000,
          'currency', OLD.currency
        ),
        'new', jsonb_build_object(
          'included_total_requests_month', NEW.included_total_requests_month,
          'included_search_requests_month', NEW.included_search_requests_month,
          'included_reverse_requests_month', NEW.included_reverse_requests_month,
          'rate_limit_per_minute', NEW.rate_limit_per_minute,
          'rate_limit_per_day', NEW.rate_limit_per_day,
          'enforce_hard_cap', NEW.enforce_hard_cap,
          'allow_overage', NEW.allow_overage,
          'billable', NEW.billable,
          'overage_price_per_1000', NEW.overage_price_per_1000,
          'currency', NEW.currency
        )
      )
    );
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id,
      v_actor,
      NULL,
      'TENANT_GEOCODING_LIMIT_OVERRIDE_DELETED',
      'tenant_geocoding_limit_override',
      NULL,
      jsonb_build_object(
        'provider_key', OLD.provider_key
      )
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_tenant_geocoding_limit_overrides
  ON data.tenant_geocoding_limit_overrides;

CREATE TRIGGER trg_audit_tenant_geocoding_limit_overrides
  AFTER INSERT OR UPDATE OR DELETE ON data.tenant_geocoding_limit_overrides
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_tenant_geocoding_limit_overrides();

-- ---------------------------------------------------------------------------
-- 7) Seed base provider (Nominatim)
-- ---------------------------------------------------------------------------

INSERT INTO data.geocoding_providers (
  provider_key,
  name,
  is_active,
  default_included_total_requests_month,
  default_rate_limit_per_minute,
  default_rate_limit_per_day,
  default_enforce_hard_cap,
  default_allow_overage,
  default_billable,
  default_overage_price_per_1000,
  default_currency,
  metadata
)
VALUES (
  'nominatim',
  'OpenStreetMap Nominatim',
  true,
  NULL,
  30,
  1000,
  false,
  false,
  false,
  0,
  'EUR',
  jsonb_build_object(
    'kind', 'geocoding',
    'notes', 'Free provider; metering enabled for abuse control and observability.'
  )
)
ON CONFLICT (provider_key)
DO UPDATE SET
  name = EXCLUDED.name,
  is_active = EXCLUDED.is_active,
  default_rate_limit_per_minute = EXCLUDED.default_rate_limit_per_minute,
  default_rate_limit_per_day = EXCLUDED.default_rate_limit_per_day,
  default_enforce_hard_cap = EXCLUDED.default_enforce_hard_cap,
  default_allow_overage = EXCLUDED.default_allow_overage,
  default_billable = EXCLUDED.default_billable,
  default_overage_price_per_1000 = EXCLUDED.default_overage_price_per_1000,
  default_currency = EXCLUDED.default_currency,
  metadata = EXCLUDED.metadata;

-- ---------------------------------------------------------------------------
-- 8) Extensió de api.tenant_entitlements
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW api.tenant_entitlements AS
SELECT
  t.id                                                                    AS tenant_id,
  t.name                                                                  AS tenant_name,
  t.slug,
  t.is_active,
  t.storage_blocked,
  t.storage_blocked_reason,
  -- Plan
  p.id                                                                    AS plan_id,
  p.name                                                                  AS plan_name,
  p.display_name                                                          AS plan_display_name,
  p.max_members,
  p.max_storage_mb                                                        AS plan_max_storage_mb,
  p.features_jsonb                                                        AS plan_features,
  -- Admin overrides
  tsl.internal_quota_gb,
  tsl.internal_max_file_mb,
  tsl.internal_allowed_mimes,
  -- Effective quota
  CASE
    WHEN tsl.internal_quota_gb IS NOT NULL
      THEN (tsl.internal_quota_gb * 1024 * 1024 * 1024)::bigint
    ELSE COALESCE(p.max_storage_mb::bigint * 1024 * 1024, 0)
  END                                                                     AS effective_quota_bytes,
  -- Drive (file_nodes) usage
  COALESCE(su.committed_bytes, 0) + COALESCE(su.reserved_bytes, 0)       AS drive_used_bytes,
  COALESCE(su.file_count, 0)                                              AS file_count,
  -- Documents (DMS) usage
  COALESCE(su.documents_committed_bytes, 0)
    + COALESCE(su.documents_reserved_bytes, 0)                            AS documents_used_bytes,
  COALESCE(su.documents_file_count, 0)                                    AS documents_file_count,
  -- Grand total (Drive + Documents) — backward-compatible column name
  COALESCE(su.committed_bytes, 0)           + COALESCE(su.reserved_bytes, 0)
  + COALESCE(su.documents_committed_bytes, 0) + COALESCE(su.documents_reserved_bytes, 0)
                                                                          AS storage_used_bytes,
  -- Monthly egress
  COALESCE((
    SELECT SUM(el.size_bytes)
      FROM data.storage_egress_logs el
     WHERE el.tenant_id = t.id
       AND el.created_at >= date_trunc('month', now())
  ), 0)                                                                   AS monthly_egress_bytes,
  -- Active BYOS drive count
  (
    SELECT COUNT(*)
      FROM data.storage_providers sp
     WHERE sp.tenant_id = t.id
       AND sp.provider_type <> 'supabase'
       AND sp.is_active = true
  )                                                                       AS byos_drive_count,
  -- Geocoding (provider principal del tenant)
  COALESCE(geo_cfg.provider_key, 'nominatim')                            AS geocoding_provider_key,
  geo_limits.mode                                                         AS geocoding_mode,
  geo_limits.is_enabled                                                   AS geocoding_provider_enabled,
  geo_limits.included_total_requests_month                               AS geocoding_included_total_requests_month,
  geo_limits.included_search_requests_month                              AS geocoding_included_search_requests_month,
  geo_limits.included_reverse_requests_month                             AS geocoding_included_reverse_requests_month,
  geo_limits.rate_limit_per_minute                                       AS geocoding_rate_limit_per_minute,
  geo_limits.rate_limit_per_day                                          AS geocoding_rate_limit_per_day,
  geo_limits.enforce_hard_cap                                            AS geocoding_enforce_hard_cap,
  geo_limits.allow_overage                                               AS geocoding_allow_overage,
  geo_limits.billable                                                    AS geocoding_billable,
  geo_limits.overage_price_per_1000                                      AS geocoding_overage_price_per_1000,
  geo_limits.currency                                                    AS geocoding_currency,
  COALESCE(gum.total_requests, 0)                                        AS geocoding_monthly_requests,
  COALESCE(gum.billable_units, 0)                                        AS geocoding_monthly_billable_units,
  COALESCE(gum.cost_amount, 0)                                           AS geocoding_monthly_cost_amount
FROM       data.tenants               t
LEFT JOIN  data.plans                 p   ON p.id          = t.plan_id
LEFT JOIN  data.storage_usage         su  ON su.tenant_id  = t.id
LEFT JOIN  data.tenant_storage_limits tsl ON tsl.tenant_id = t.id
LEFT JOIN LATERAL (
  SELECT c.provider_key
    FROM data.tenant_geocoding_provider_configs c
   WHERE c.tenant_id = t.id
     AND c.is_enabled = true
   ORDER BY c.priority ASC, c.created_at ASC
   LIMIT 1
) geo_cfg ON true
LEFT JOIN LATERAL data.get_effective_geocoding_limits(
  t.id,
  COALESCE(geo_cfg.provider_key, 'nominatim')
) geo_limits ON true
LEFT JOIN data.geocoding_usage_monthly gum
  ON gum.tenant_id = t.id
 AND gum.provider_key = COALESCE(geo_cfg.provider_key, 'nominatim')
 AND gum.usage_month = date_trunc('month', now())::date;

GRANT SELECT ON api.tenant_entitlements TO service_role;
GRANT SELECT ON api.tenant_entitlements TO prisma_admin;

-- ---------------------------------------------------------------------------
-- 9) Grants
-- ---------------------------------------------------------------------------

-- service_role (Edge Functions)
GRANT SELECT, INSERT, UPDATE ON data.geocoding_rate_windows       TO service_role;
GRANT SELECT, INSERT         ON data.geocoding_usage_ledger       TO service_role;
GRANT SELECT, INSERT, UPDATE ON data.geocoding_usage_daily        TO service_role;
GRANT SELECT, INSERT, UPDATE ON data.geocoding_usage_monthly      TO service_role;
GRANT SELECT                 ON data.geocoding_providers          TO service_role;
GRANT SELECT                 ON data.plan_geocoding_limits        TO service_role;
GRANT SELECT                 ON data.tenant_geocoding_limit_overrides TO service_role;
GRANT SELECT                 ON data.tenant_geocoding_provider_configs TO service_role;
GRANT EXECUTE ON FUNCTION data.get_effective_geocoding_limits(uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION data.bump_geocoding_window(uuid, text, text, text, timestamptz, integer) TO service_role;

-- prisma_admin (backoffice)
GRANT SELECT, INSERT, UPDATE, DELETE ON data.geocoding_providers               TO prisma_admin;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.plan_geocoding_limits             TO prisma_admin;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.tenant_geocoding_limit_overrides  TO prisma_admin;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.tenant_geocoding_provider_configs TO prisma_admin;
GRANT SELECT                         ON data.geocoding_rate_windows             TO prisma_admin;
GRANT SELECT                         ON data.geocoding_usage_ledger             TO prisma_admin;
GRANT SELECT                         ON data.geocoding_usage_daily              TO prisma_admin;
GRANT SELECT                         ON data.geocoding_usage_monthly            TO prisma_admin;
GRANT EXECUTE ON FUNCTION data.get_effective_geocoding_limits(uuid, text) TO prisma_admin;
GRANT EXECUTE ON FUNCTION data.bump_geocoding_window(uuid, text, text, text, timestamptz, integer) TO prisma_admin;
