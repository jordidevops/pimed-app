-- Maps: unblock Google BYO (included=0 + hard_cap blocked every call),
-- clear map API keys → Nominatim fallback, and respect tenant maps.provider preference.

-- ---------------------------------------------------------------------------
-- 1) Soften Google provider defaults (BYO pays Google directly)
-- ---------------------------------------------------------------------------
UPDATE data.geocoding_providers
SET
  default_enforce_hard_cap = false,
  default_allow_overage = true,
  default_billable = false,
  updated_at = now()
WHERE provider_key = 'google';

-- ---------------------------------------------------------------------------
-- 2) BYO never applies platform monthly hard-caps (rate limits still apply)
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
    CASE
      WHEN COALESCE(cfg.mode, 'platform') = 'byo' THEN false
      ELSE COALESCE(ovr.enforce_hard_cap, pl.enforce_hard_cap, gp.default_enforce_hard_cap, false)
    END AS enforce_hard_cap,
    CASE
      WHEN COALESCE(cfg.mode, 'platform') = 'byo' THEN true
      ELSE COALESCE(ovr.allow_overage, pl.allow_overage, gp.default_allow_overage, true)
    END AS allow_overage,
    CASE
      WHEN COALESCE(cfg.mode, 'platform') = 'byo' THEN false
      ELSE COALESCE(ovr.billable, pl.billable, gp.default_billable, false)
    END AS billable,
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

-- ---------------------------------------------------------------------------
-- 3) Clear active (+ pending) map API key → detach provider config
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.clear_tenant_map_api_key(
  p_tenant_id uuid,
  p_key_type  text  -- 'geocoding' | 'routes' | 'maps_js'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_secret_type text;
  v_provider text := 'google';
BEGIN
  IF COALESCE(auth.role(), '') = 'service_role' THEN
    NULL;
  ELSIF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_key_type = 'geocoding' THEN
    v_secret_type := 'geocoding_api_key';

    UPDATE data.tenant_geocoding_provider_configs
    SET api_key_secret_id = NULL,
        pending_api_key_secret_id = NULL,
        pending_expires_at = NULL,
        mode = 'platform',
        updated_at = now()
    WHERE tenant_id = p_tenant_id AND provider_key = v_provider;

  ELSIF p_key_type = 'routes' THEN
    v_secret_type := 'routes_api_key';

    UPDATE data.tenant_routes_provider_configs
    SET api_key_secret_id = NULL,
        pending_api_key_secret_id = NULL,
        pending_expires_at = NULL,
        is_enabled = false,
        updated_at = now()
    WHERE tenant_id = p_tenant_id AND provider_key = v_provider;

  ELSIF p_key_type = 'maps_js' THEN
    v_secret_type := 'maps_js_api_key';

  ELSE
    RAISE EXCEPTION 'invalid_key_type';
  END IF;

  UPDATE data.tenant_secret_refs
  SET rotation_status = 'revoked', updated_at = now()
  WHERE tenant_id = p_tenant_id
    AND secret_type = v_secret_type
    AND provider IN (v_provider, v_provider || '_pending')
    AND rotation_status <> 'revoked';

  RETURN jsonb_build_object('ok', true, 'key_type', p_key_type, 'status', 'cleared');
END;
$$;

REVOKE ALL ON FUNCTION api.clear_tenant_map_api_key(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.clear_tenant_map_api_key(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION api.clear_tenant_map_api_key(uuid, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 4) Resolve provider respects tenants.settings.maps.provider
--    'openstreetmap' → Nominatim; 'google' / missing → Google BYO when available
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.resolve_effective_geocoding_provider(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_mode text;
  v_nominatim_active boolean;
  v_pref text;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT lower(nullif(trim(t.settings #>> '{maps,provider}'), ''))
  INTO v_pref
  FROM data.tenants t
  WHERE t.id = p_tenant_id;

  -- Prefer Google BYO unless tenant explicitly chose OpenStreetMap.
  IF COALESCE(v_pref, 'google') <> 'openstreetmap' THEN
    SELECT c.mode INTO v_mode
      FROM data.tenant_geocoding_provider_configs c
      JOIN data.geocoding_providers p ON p.provider_key = c.provider_key
     WHERE c.tenant_id = p_tenant_id
       AND c.provider_key = 'google'
       AND c.is_enabled = true
       AND c.mode = 'byo'
       AND c.api_key_secret_id IS NOT NULL
       AND p.is_active = true
     ORDER BY c.priority ASC, c.created_at ASC
     LIMIT 1;

    IF FOUND THEN
      RETURN jsonb_build_object('provider_key', 'google', 'mode', 'byo');
    END IF;
  END IF;

  SELECT p.is_active INTO v_nominatim_active
  FROM data.geocoding_providers p
  WHERE p.provider_key = 'nominatim';

  IF COALESCE(v_nominatim_active, false) THEN
    SELECT c.mode INTO v_mode
    FROM data.tenant_geocoding_provider_configs c
    WHERE c.tenant_id = p_tenant_id
      AND c.provider_key = 'nominatim'
      AND c.is_enabled = true
    ORDER BY c.priority ASC
    LIMIT 1;

    RETURN jsonb_build_object(
      'provider_key', 'nominatim',
      'mode', COALESCE(v_mode, 'platform')
    );
  END IF;

  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION api.resolve_effective_geocoding_provider(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.resolve_effective_geocoding_provider(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 5) Settings registry: maps (tenant-scoped preference blob)
-- ---------------------------------------------------------------------------
INSERT INTO data.settings_registry
  (setting_key, scope, required_permission, owner_only, is_active, description)
VALUES
  ('maps', 'tenant', 'settings.manage', false, true,
   'Maps preferences (provider: google | openstreetmap)')
ON CONFLICT (setting_key) DO UPDATE SET
  scope = EXCLUDED.scope,
  required_permission = EXCLUDED.required_permission,
  description = EXCLUDED.description,
  is_active = true,
  updated_at = now();
