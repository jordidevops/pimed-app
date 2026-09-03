-- =============================================================================
-- Tenant AI — Phase 2: usage ledger, rate limiting, model catalog sync
-- =============================================================================

ALTER TABLE data.tenant_ai_config
  ADD COLUMN IF NOT EXISTS rate_limit_per_hour integer NOT NULL DEFAULT 60,
  ADD COLUMN IF NOT EXISTS rate_limit_per_day integer NOT NULL DEFAULT 500,
  ADD COLUMN IF NOT EXISTS warn_threshold_pct smallint NOT NULL DEFAULT 80,
  ADD COLUMN IF NOT EXISTS hard_block_on_limit boolean NOT NULL DEFAULT true;

ALTER TABLE data.tenant_ai_provider_config
  ADD COLUMN IF NOT EXISTS last_models_sync_at timestamptz;

-- ---------------------------------------------------------------------------
-- Usage ledger
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.ai_usage_ledger (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  user_id            uuid NOT NULL,
  site_id            uuid REFERENCES data.sites(id) ON DELETE SET NULL,
  feature            text NOT NULL,
  provider           data.ai_provider NOT NULL,
  model              text NOT NULL,
  request_status     text NOT NULL CHECK (request_status IN (
    'success', 'provider_error', 'validation_error',
    'blocked_rate_limit', 'blocked_tenant', 'blocked_user', 'blocked_quota'
  )),
  prompt_tokens      integer,
  completion_tokens  integer,
  total_tokens       integer GENERATED ALWAYS AS (
    COALESCE(prompt_tokens, 0) + COALESCE(completion_tokens, 0)
  ) STORED,
  latency_ms         integer,
  error_code         text,
  created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_usage_tenant_created
  ON data.ai_usage_ledger (tenant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_usage_tenant_user_created
  ON data.ai_usage_ledger (tenant_id, user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS data.ai_rate_windows (
  tenant_id      uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  user_id        uuid NOT NULL,
  window_kind    text NOT NULL CHECK (window_kind IN ('hour', 'day')),
  window_start   timestamptz NOT NULL,
  request_count  integer NOT NULL DEFAULT 0 CHECK (request_count >= 0),
  PRIMARY KEY (tenant_id, user_id, window_kind, window_start)
);

CREATE TABLE IF NOT EXISTS data.ai_usage_daily (
  tenant_id           uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  usage_date          date NOT NULL,
  provider            data.ai_provider NOT NULL,
  total_requests      integer NOT NULL DEFAULT 0,
  successful_requests integer NOT NULL DEFAULT 0,
  blocked_requests    integer NOT NULL DEFAULT 0,
  total_tokens        bigint NOT NULL DEFAULT 0,
  updated_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, usage_date, provider)
);

-- ---------------------------------------------------------------------------
-- Extend get_ai_config_for_tenant
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_ai_config_for_tenant(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_row             data.tenant_ai_config%ROWTYPE;
  v_default         data.ai_provider := 'openai';
  v_providers       jsonb := '[]'::jsonb;
  v_provider        data.ai_provider;
  v_cfg             data.tenant_ai_provider_config%ROWTYPE;
BEGIN
  PERFORM api._assert_ai_manager_access(p_tenant_id);

  SELECT * INTO v_row
  FROM data.tenant_ai_config
  WHERE tenant_id = p_tenant_id;

  IF FOUND THEN
    v_default := v_row.default_provider;
  END IF;

  FOREACH v_provider IN ARRAY ARRAY['openai', 'anthropic', 'gemini']::data.ai_provider[] LOOP
    SELECT * INTO v_cfg
    FROM data.tenant_ai_provider_config
    WHERE tenant_id = p_tenant_id
      AND provider = v_provider;

    v_providers := v_providers || jsonb_build_array(
      jsonb_build_object(
        'provider', v_provider,
        'configured', (v_cfg.ai_key_secret_id IS NOT NULL AND v_cfg.key_verified_at IS NOT NULL),
        'has_key', (v_cfg.ai_key_secret_id IS NOT NULL),
        'verified', (v_cfg.key_verified_at IS NOT NULL),
        'key_verified_at', v_cfg.key_verified_at,
        'key_last_error', v_cfg.key_last_error,
        'model', COALESCE(v_cfg.model, api.ai_provider_default_model(v_provider)),
        'base_url', COALESCE(v_cfg.base_url, api.ai_provider_default_base_url(v_provider)),
        'available_models', COALESCE(v_cfg.available_models, '{}'::text[]),
        'last_models_sync_at', v_cfg.last_models_sync_at
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'default_provider', v_default,
    'is_active', COALESCE(v_row.is_active, true),
    'system_prompt', v_row.system_prompt,
    'temperature', COALESCE(v_row.temperature, 0.20),
    'max_tokens', COALESCE(v_row.max_tokens, 4096),
    'default_models', COALESCE(v_row.default_models, '{}'::jsonb),
    'rate_limit_per_hour', COALESCE(v_row.rate_limit_per_hour, 60),
    'rate_limit_per_day', COALESCE(v_row.rate_limit_per_day, 500),
    'warn_threshold_pct', COALESCE(v_row.warn_threshold_pct, 80),
    'hard_block_on_limit', COALESCE(v_row.hard_block_on_limit, true),
    'providers', v_providers,
    'configured', EXISTS (
      SELECT 1
      FROM data.tenant_ai_provider_config pc
      JOIN data.tenant_ai_config tc ON tc.tenant_id = pc.tenant_id
      WHERE pc.tenant_id = p_tenant_id
        AND pc.provider = tc.default_provider
        AND pc.ai_key_secret_id IS NOT NULL
        AND pc.key_verified_at IS NOT NULL
        AND tc.is_active IS DISTINCT FROM false
    )
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- check_and_increment_ai_rate_limit (service_role)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.check_and_increment_ai_rate_limit(
  p_tenant_id uuid,
  p_user_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_cfg            data.tenant_ai_config%ROWTYPE;
  v_hour_limit     integer := 60;
  v_day_limit      integer := 500;
  v_warn_pct       smallint := 80;
  v_hard_block     boolean := true;
  v_hour_start     timestamptz := date_trunc('hour', now());
  v_day_start      timestamptz := date_trunc('day', now());
  v_hour_count     integer := 0;
  v_day_count      integer := 0;
BEGIN
  SELECT * INTO v_cfg
  FROM data.tenant_ai_config
  WHERE tenant_id = p_tenant_id;

  IF FOUND THEN
    v_hour_limit := COALESCE(v_cfg.rate_limit_per_hour, 60);
    v_day_limit := COALESCE(v_cfg.rate_limit_per_day, 500);
    v_warn_pct := COALESCE(v_cfg.warn_threshold_pct, 80);
    v_hard_block := COALESCE(v_cfg.hard_block_on_limit, true);
  END IF;

  SELECT COALESCE(request_count, 0) INTO v_hour_count
  FROM data.ai_rate_windows
  WHERE tenant_id = p_tenant_id
    AND user_id = p_user_id
    AND window_kind = 'hour'
    AND window_start = v_hour_start;

  SELECT COALESCE(request_count, 0) INTO v_day_count
  FROM data.ai_rate_windows
  WHERE tenant_id = p_tenant_id
    AND user_id = p_user_id
    AND window_kind = 'day'
    AND window_start = v_day_start;

  IF v_hard_block AND (
    (v_hour_limit > 0 AND v_hour_count >= v_hour_limit) OR
    (v_day_limit > 0 AND v_day_count >= v_day_limit)
  ) THEN
    RETURN jsonb_build_object(
      'allowed', false,
      'hour_count', v_hour_count,
      'day_count', v_day_count,
      'hour_limit', v_hour_limit,
      'day_limit', v_day_limit,
      'warn_threshold_pct', v_warn_pct,
      'near_limit', true
    );
  END IF;

  INSERT INTO data.ai_rate_windows (tenant_id, user_id, window_kind, window_start, request_count)
  VALUES (p_tenant_id, p_user_id, 'hour', v_hour_start, 1)
  ON CONFLICT (tenant_id, user_id, window_kind, window_start)
  DO UPDATE SET request_count = data.ai_rate_windows.request_count + 1;

  INSERT INTO data.ai_rate_windows (tenant_id, user_id, window_kind, window_start, request_count)
  VALUES (p_tenant_id, p_user_id, 'day', v_day_start, 1)
  ON CONFLICT (tenant_id, user_id, window_kind, window_start)
  DO UPDATE SET request_count = data.ai_rate_windows.request_count + 1;

  v_hour_count := v_hour_count + 1;
  v_day_count := v_day_count + 1;

  RETURN jsonb_build_object(
    'allowed', true,
    'hour_count', v_hour_count,
    'day_count', v_day_count,
    'hour_limit', v_hour_limit,
    'day_limit', v_day_limit,
    'warn_threshold_pct', v_warn_pct,
    'near_limit', (
      (v_day_limit > 0 AND (v_day_count::numeric / v_day_limit::numeric) * 100 >= v_warn_pct) OR
      (v_hour_limit > 0 AND (v_hour_count::numeric / v_hour_limit::numeric) * 100 >= v_warn_pct)
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION api.check_and_increment_ai_rate_limit(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.check_and_increment_ai_rate_limit(uuid, uuid) FROM authenticated;
REVOKE ALL ON FUNCTION api.check_and_increment_ai_rate_limit(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION api.check_and_increment_ai_rate_limit(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- log_ai_usage (service_role)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.log_ai_usage(
  p_tenant_id         uuid,
  p_user_id           uuid,
  p_feature           text,
  p_provider          text,
  p_model             text,
  p_request_status    text,
  p_prompt_tokens     integer DEFAULT NULL,
  p_completion_tokens integer DEFAULT NULL,
  p_latency_ms        integer DEFAULT NULL,
  p_error_code        text DEFAULT NULL,
  p_site_id           uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_event_id   uuid;
  v_created_at timestamptz;
  v_provider   data.ai_provider;
  v_tokens     bigint;
  v_success    integer := CASE WHEN p_request_status = 'success' THEN 1 ELSE 0 END;
  v_blocked    integer := CASE WHEN p_request_status LIKE 'blocked_%' THEN 1 ELSE 0 END;
BEGIN
  IF lower(p_provider) NOT IN ('openai', 'anthropic', 'gemini') THEN
    RAISE EXCEPTION 'Invalid provider';
  END IF;

  v_provider := lower(p_provider)::data.ai_provider;
  v_tokens := COALESCE(p_prompt_tokens, 0) + COALESCE(p_completion_tokens, 0);

  INSERT INTO data.ai_usage_ledger (
    tenant_id, user_id, site_id, feature, provider, model,
    request_status, prompt_tokens, completion_tokens, latency_ms, error_code
  ) VALUES (
    p_tenant_id, p_user_id, p_site_id, p_feature, v_provider, p_model,
    p_request_status, p_prompt_tokens, p_completion_tokens, p_latency_ms, p_error_code
  )
  RETURNING id, created_at INTO v_event_id, v_created_at;

  INSERT INTO data.ai_usage_daily (
    tenant_id, usage_date, provider,
    total_requests, successful_requests, blocked_requests, total_tokens
  ) VALUES (
    p_tenant_id, v_created_at::date, v_provider,
    1, v_success, v_blocked, v_tokens
  )
  ON CONFLICT (tenant_id, usage_date, provider) DO UPDATE
    SET total_requests = data.ai_usage_daily.total_requests + 1,
        successful_requests = data.ai_usage_daily.successful_requests + EXCLUDED.successful_requests,
        blocked_requests = data.ai_usage_daily.blocked_requests + EXCLUDED.blocked_requests,
        total_tokens = data.ai_usage_daily.total_tokens + EXCLUDED.total_tokens,
        updated_at = now();

  RETURN v_event_id;
END;
$$;

REVOKE ALL ON FUNCTION api.log_ai_usage(uuid, uuid, text, text, text, text, integer, integer, integer, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.log_ai_usage(uuid, uuid, text, text, text, text, integer, integer, integer, text, uuid) FROM authenticated;
REVOKE ALL ON FUNCTION api.log_ai_usage(uuid, uuid, text, text, text, text, integer, integer, integer, text, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION api.log_ai_usage(uuid, uuid, text, text, text, text, integer, integer, integer, text, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- persist_tenant_ai_provider_models (service_role)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.persist_tenant_ai_provider_models(
  p_tenant_id uuid,
  p_provider  text,
  p_models    text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_provider data.ai_provider;
BEGIN
  IF lower(p_provider) NOT IN ('openai', 'anthropic', 'gemini') THEN
    RAISE EXCEPTION 'Invalid provider';
  END IF;

  v_provider := lower(p_provider)::data.ai_provider;

  INSERT INTO data.tenant_ai_provider_config (tenant_id, provider, model, available_models, last_models_sync_at)
  VALUES (
    p_tenant_id,
    v_provider,
    api.ai_provider_default_model(v_provider),
    COALESCE(p_models, '{}'::text[]),
    now()
  )
  ON CONFLICT (tenant_id, provider) DO UPDATE
    SET available_models = COALESCE(EXCLUDED.available_models, '{}'::text[]),
        last_models_sync_at = now();

  RETURN jsonb_build_object(
    'success', true,
    'provider', v_provider,
    'models', COALESCE(p_models, '{}'::text[]),
    'synced_at', now()
  );
END;
$$;

REVOKE ALL ON FUNCTION api.persist_tenant_ai_provider_models(uuid, text, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.persist_tenant_ai_provider_models(uuid, text, text[]) FROM authenticated;
REVOKE ALL ON FUNCTION api.persist_tenant_ai_provider_models(uuid, text, text[]) FROM anon;
GRANT EXECUTE ON FUNCTION api.persist_tenant_ai_provider_models(uuid, text, text[]) TO service_role;

-- ---------------------------------------------------------------------------
-- get_ai_usage_stats (authenticated owner/manager)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_ai_usage_stats(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_cfg           data.tenant_ai_config%ROWTYPE;
  v_hour_start    timestamptz := date_trunc('hour', now());
  v_day_start     timestamptz := date_trunc('day', now());
  v_hour_count    integer := 0;
  v_day_count     integer := 0;
  v_daily         jsonb := '[]'::jsonb;
  v_by_provider   jsonb := '[]'::jsonb;
  v_summary       jsonb;
BEGIN
  PERFORM api._assert_ai_manager_access(p_tenant_id);

  SELECT * INTO v_cfg
  FROM data.tenant_ai_config
  WHERE tenant_id = p_tenant_id;

  SELECT COALESCE(SUM(request_count), 0) INTO v_hour_count
  FROM data.ai_rate_windows
  WHERE tenant_id = p_tenant_id
    AND window_kind = 'hour'
    AND window_start = v_hour_start;

  SELECT COALESCE(SUM(request_count), 0) INTO v_day_count
  FROM data.ai_rate_windows
  WHERE tenant_id = p_tenant_id
    AND window_kind = 'day'
    AND window_start = v_day_start;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'date', usage_date,
      'requests', total_requests,
      'tokens', total_tokens,
      'blocked', blocked_requests,
      'provider', provider
    ) ORDER BY usage_date DESC
  ), '[]'::jsonb)
  INTO v_daily
  FROM (
    SELECT usage_date, provider,
           SUM(total_requests) AS total_requests,
           SUM(total_tokens) AS total_tokens,
           SUM(blocked_requests) AS blocked_requests
    FROM data.ai_usage_daily
    WHERE tenant_id = p_tenant_id
      AND usage_date >= (current_date - interval '30 days')
    GROUP BY usage_date, provider
  ) d;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'provider', provider,
      'requests', total_requests,
      'tokens', total_tokens,
      'blocked', blocked_requests
    )
  ), '[]'::jsonb)
  INTO v_by_provider
  FROM (
    SELECT provider,
           SUM(total_requests) AS total_requests,
           SUM(total_tokens) AS total_tokens,
           SUM(blocked_requests) AS blocked_requests
    FROM data.ai_usage_daily
    WHERE tenant_id = p_tenant_id
      AND usage_date >= (current_date - interval '30 days')
    GROUP BY provider
  ) p;

  v_summary := jsonb_build_object(
    'hour_count', v_hour_count,
    'day_count', v_day_count,
    'hour_limit', COALESCE(v_cfg.rate_limit_per_hour, 60),
    'day_limit', COALESCE(v_cfg.rate_limit_per_day, 500),
    'warn_threshold_pct', COALESCE(v_cfg.warn_threshold_pct, 80),
    'total_requests_30d', (
      SELECT COALESCE(SUM(total_requests), 0)
      FROM data.ai_usage_daily
      WHERE tenant_id = p_tenant_id
        AND usage_date >= (current_date - interval '30 days')
    ),
    'total_tokens_30d', (
      SELECT COALESCE(SUM(total_tokens), 0)
      FROM data.ai_usage_daily
      WHERE tenant_id = p_tenant_id
        AND usage_date >= (current_date - interval '30 days')
    ),
    'blocked_requests_30d', (
      SELECT COALESCE(SUM(blocked_requests), 0)
      FROM data.ai_usage_daily
      WHERE tenant_id = p_tenant_id
        AND usage_date >= (current_date - interval '30 days')
    )
  );

  RETURN jsonb_build_object(
    'summary', v_summary,
    'daily', v_daily,
    'by_provider', v_by_provider
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_ai_usage_stats(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_ai_usage_stats(uuid) TO service_role;
