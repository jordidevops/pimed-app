-- Fase 4 follow-up: abuse-alert is_new, broader cache expiry purge, stronger S7 guard,
-- usage summary includes cache_hits.

-- ---------------------------------------------------------------------------
-- Stronger S7 guard + opportunistic purge of expired rows
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
  v_lang text := COALESCE(NULLIF(trim(p_language), ''), 'ca');
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  -- Opportunistic batch purge (expired rows for any key), capped.
  DELETE FROM data.geocoding_result_cache c
  WHERE c.ctid IN (
    SELECT x.ctid
    FROM data.geocoding_result_cache x
    WHERE x.expires_at < now()
    LIMIT 200
  );

  SELECT c.result INTO v_result
  FROM data.geocoding_result_cache c
  WHERE c.provider_key = p_provider_key
    AND c.cache_kind = p_cache_kind
    AND c.operation = p_operation
    AND c.query_hash = p_query_hash
    AND c.language = v_lang
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
  v_keys text[];
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_provider_key = 'google' AND p_cache_kind = 'google_place_id' THEN
    IF jsonb_typeof(p_result) <> 'object' THEN
      RAISE EXCEPTION 'google_place_id cache must be a JSON object (S7)';
    END IF;

    SELECT array_agg(k) INTO v_keys
    FROM jsonb_object_keys(p_result) AS k;

    -- Allow only place_id / place_ids keys (S7).
    IF EXISTS (
      SELECT 1
      FROM unnest(COALESCE(v_keys, ARRAY[]::text[])) AS k(key)
      WHERE k.key NOT IN ('place_id', 'place_ids')
    ) THEN
      RAISE EXCEPTION 'google_place_id cache allows only place_id/place_ids keys (S7)';
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

-- ---------------------------------------------------------------------------
-- Abuse alert: is_new only on first insert of the day (avoid log spam)
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
  v_is_new boolean := false;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  v_blocked := COALESCE(
    (
      SELECT d.blocked_requests
      FROM data.geocoding_usage_daily d
      WHERE d.tenant_id = p_tenant_id
        AND d.provider_key = p_provider_key
        AND d.usage_date = v_today
    ),
    0
  );

  IF v_blocked < v_threshold THEN
    RETURN jsonb_build_object(
      'alerted', false,
      'is_new', false,
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
  RETURNING id, (xmax = 0) INTO v_id, v_is_new;

  RETURN jsonb_build_object(
    'alerted', true,
    'is_new', COALESCE(v_is_new, false),
    'alert_id', v_id,
    'blocked_requests', v_blocked,
    'threshold', v_threshold
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- Usage summary: include cache_hits for the month
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
  v_cache_hits integer := 0;
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

  SELECT COUNT(*)::integer
  INTO v_cache_hits
  FROM data.geocoding_usage_ledger l
  WHERE l.tenant_id = v_tenant_id
    AND l.created_at >= v_month_start::timestamptz
    AND (l.cache_hit = true OR l.request_status = 'cached');

  RETURN jsonb_build_object(
    'tenant_id', v_tenant_id,
    'usage_month', v_month_start,
    'providers', v_rows,
    'today_blocked_requests', v_day_blocked,
    'cache_hits', v_cache_hits
  );
END;
$$;
