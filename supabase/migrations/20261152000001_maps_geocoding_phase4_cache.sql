-- =============================================================================
-- Maps Geocoding Fase 4 — cache (Nominatim + Google place_id only), usage summary,
-- abuse alerts (blocked_requests spike). See docs/plans/maps-geocoding-byok §10.
-- S7: never cache Google address/coords content — only place_id.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Result cache
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.geocoding_result_cache (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_key  text NOT NULL REFERENCES data.geocoding_providers(provider_key) ON DELETE CASCADE,
  cache_kind    text NOT NULL
    CHECK (cache_kind IN ('nominatim_result', 'google_place_id')),
  operation     text NOT NULL CHECK (operation IN ('search', 'reverse', 'place_id')),
  query_hash    text NOT NULL,
  language      text NOT NULL DEFAULT 'ca',
  result        jsonb NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL,
  CONSTRAINT geocoding_result_cache_provider_kind_chk CHECK (
    (provider_key = 'nominatim' AND cache_kind = 'nominatim_result')
    OR (provider_key = 'google' AND cache_kind = 'google_place_id')
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_geocoding_result_cache_lookup
  ON data.geocoding_result_cache (provider_key, cache_kind, operation, query_hash, language);

CREATE INDEX IF NOT EXISTS idx_geocoding_result_cache_expires
  ON data.geocoding_result_cache (expires_at);

COMMENT ON TABLE data.geocoding_result_cache IS
  'Fase 4: cache TTL ~30d. Nominatim = resultats complets; Google = només place_id (S7).';

REVOKE ALL ON TABLE data.geocoding_result_cache FROM PUBLIC;
REVOKE ALL ON TABLE data.geocoding_result_cache FROM anon;
REVOKE ALL ON TABLE data.geocoding_result_cache FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE data.geocoding_result_cache TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE data.geocoding_result_cache TO prisma_admin;

-- ---------------------------------------------------------------------------
-- 2) Abuse alert log (log-only persistence; ops / proxy can append)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.geocoding_abuse_alerts (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid REFERENCES data.tenants(id) ON DELETE CASCADE,
  provider_key     text REFERENCES data.geocoding_providers(provider_key) ON DELETE SET NULL,
  usage_date       date NOT NULL,
  blocked_requests integer NOT NULL,
  threshold        integer NOT NULL,
  payload          jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_geocoding_abuse_alerts_created
  ON data.geocoding_abuse_alerts (created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS uq_geocoding_abuse_alerts_day_tenant_provider
  ON data.geocoding_abuse_alerts (tenant_id, provider_key, usage_date);

COMMENT ON TABLE data.geocoding_abuse_alerts IS
  'Fase 4: alerta quan blocked_requests diaris superen el llindar (1 fila/dia/tenant/provider).';

REVOKE ALL ON TABLE data.geocoding_abuse_alerts FROM PUBLIC;
REVOKE ALL ON TABLE data.geocoding_abuse_alerts FROM anon;
REVOKE ALL ON TABLE data.geocoding_abuse_alerts FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE data.geocoding_abuse_alerts TO service_role;
GRANT SELECT ON TABLE data.geocoding_abuse_alerts TO prisma_admin;

-- ---------------------------------------------------------------------------
-- 3) Cache RPCs (service_role)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_geocoding_result_cache(
  p_provider_key text,
  p_cache_kind   text,
  p_operation    text,
  p_query_hash   text,
  p_language     text DEFAULT 'ca'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  DELETE FROM data.geocoding_result_cache
  WHERE expires_at < now()
    AND provider_key = p_provider_key
    AND cache_kind = p_cache_kind
    AND operation = p_operation
    AND query_hash = p_query_hash
    AND language = COALESCE(NULLIF(trim(p_language), ''), 'ca');

  SELECT c.result INTO v_result
  FROM data.geocoding_result_cache c
  WHERE c.provider_key = p_provider_key
    AND c.cache_kind = p_cache_kind
    AND c.operation = p_operation
    AND c.query_hash = p_query_hash
    AND c.language = COALESCE(NULLIF(trim(p_language), ''), 'ca')
    AND c.expires_at >= now()
  LIMIT 1;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION api.upsert_geocoding_result_cache(
  p_provider_key text,
  p_cache_kind   text,
  p_operation    text,
  p_query_hash   text,
  p_language     text,
  p_result       jsonb,
  p_ttl_days     integer DEFAULT 30
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_lang text := COALESCE(NULLIF(trim(p_language), ''), 'ca');
  v_ttl  integer := GREATEST(COALESCE(p_ttl_days, 30), 1);
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_provider_key = 'google' AND p_cache_kind = 'google_place_id' THEN
    -- S7 hard guard: only place_id keys allowed in result
    IF jsonb_typeof(p_result) <> 'object'
       OR (p_result ? 'formatted_address')
       OR (p_result ? 'display_name')
       OR (p_result ? 'lat')
       OR (p_result ? 'lng')
       OR (p_result ? 'results')
    THEN
      RAISE EXCEPTION 'google_place_id cache must not store geocode content (S7)';
    END IF;
    IF NOT (p_result ? 'place_id') AND NOT (p_result ? 'place_ids') THEN
      RAISE EXCEPTION 'google_place_id cache requires place_id or place_ids';
    END IF;
  END IF;

  INSERT INTO data.geocoding_result_cache (
    provider_key, cache_kind, operation, query_hash, language, result, expires_at
  )
  VALUES (
    p_provider_key,
    p_cache_kind,
    p_operation,
    p_query_hash,
    v_lang,
    p_result,
    now() + make_interval(days => v_ttl)
  )
  ON CONFLICT (provider_key, cache_kind, operation, query_hash, language)
  DO UPDATE SET
    result = EXCLUDED.result,
    expires_at = EXCLUDED.expires_at,
    created_at = now();
END;
$$;

REVOKE ALL ON FUNCTION api.get_geocoding_result_cache(text, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.upsert_geocoding_result_cache(text, text, text, text, text, jsonb, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_geocoding_result_cache(text, text, text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION api.upsert_geocoding_result_cache(text, text, text, text, text, jsonb, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 4) Tenant usage summary (owner/manager)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_tenant_geocoding_usage_summary(
  p_tenant_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid;
  v_month_start date := date_trunc('month', now())::date;
  v_today date := CURRENT_DATE;
  v_rows jsonb;
  v_day_blocked integer := 0;
BEGIN
  v_tenant_id := COALESCE(p_tenant_id, data.active_tenant_id());
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'No active tenant';
  END IF;

  IF COALESCE(auth.role(), '') = 'service_role' THEN
    NULL;
  ELSIF NOT (
    data.jwt_user_tenants() ? v_tenant_id::text
    AND (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.provider_key), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      m.provider_key,
      m.total_requests,
      m.search_requests,
      m.reverse_requests,
      m.successful_requests,
      m.blocked_requests,
      m.billable_units,
      m.cost_amount,
      COALESCE(cfg.mode, 'platform') AS mode
    FROM data.geocoding_usage_monthly m
    LEFT JOIN data.tenant_geocoding_provider_configs cfg
      ON cfg.tenant_id = m.tenant_id AND cfg.provider_key = m.provider_key
    WHERE m.tenant_id = v_tenant_id
      AND m.usage_month = v_month_start
  ) x;

  SELECT COALESCE(SUM(d.blocked_requests), 0)::integer
  INTO v_day_blocked
  FROM data.geocoding_usage_daily d
  WHERE d.tenant_id = v_tenant_id
    AND d.usage_date = v_today;

  RETURN jsonb_build_object(
    'tenant_id', v_tenant_id,
    'usage_month', v_month_start,
    'providers', v_rows,
    'today_blocked_requests', v_day_blocked
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_tenant_geocoding_usage_summary(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_tenant_geocoding_usage_summary(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_tenant_geocoding_usage_summary(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 5) Record abuse alert if daily blocked exceeds threshold (idempotent / day)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.maybe_record_geocoding_abuse_alert(
  p_tenant_id    uuid,
  p_provider_key text,
  p_threshold    integer DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_today date := CURRENT_DATE;
  v_blocked integer := 0;
  v_threshold integer := GREATEST(COALESCE(p_threshold, 50), 1);
  v_id uuid;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT COALESCE(d.blocked_requests, 0)
  INTO v_blocked
  FROM data.geocoding_usage_daily d
  WHERE d.tenant_id = p_tenant_id
    AND d.provider_key = p_provider_key
    AND d.usage_date = v_today;

  IF v_blocked < v_threshold THEN
    RETURN jsonb_build_object(
      'alerted', false,
      'blocked_requests', v_blocked,
      'threshold', v_threshold
    );
  END IF;

  INSERT INTO data.geocoding_abuse_alerts (
    tenant_id, provider_key, usage_date, blocked_requests, threshold, payload
  )
  VALUES (
    p_tenant_id,
    p_provider_key,
    v_today,
    v_blocked,
    v_threshold,
    jsonb_build_object('source', 'geocoding-proxy', 'reason', 'blocked_requests_spike')
  )
  ON CONFLICT (tenant_id, provider_key, usage_date)
  DO UPDATE SET
    blocked_requests = EXCLUDED.blocked_requests,
    threshold = EXCLUDED.threshold,
    payload = data.geocoding_abuse_alerts.payload || EXCLUDED.payload
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'alerted', true,
    'alert_id', v_id,
    'blocked_requests', v_blocked,
    'threshold', v_threshold
  );
END;
$$;

REVOKE ALL ON FUNCTION api.maybe_record_geocoding_abuse_alert(uuid, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.maybe_record_geocoding_abuse_alert(uuid, text, integer) TO service_role;
