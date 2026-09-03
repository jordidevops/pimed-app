-- S0: enabled_models a get_ai_config, meta RPC, límit tokens/dia editable, stats

-- ---------------------------------------------------------------------------
-- get_ai_config_for_tenant — enabled_models + rate_limit_tokens_per_day
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
  v_all             data.ai_provider[] := api.all_ai_providers();
  v_cfg             data.tenant_ai_provider_config%ROWTYPE;
  v_platform        data.platform_ai_defaults%ROWTYPE;
  v_cfg_found       boolean;
BEGIN
  PERFORM api._assert_ai_manager_access(p_tenant_id);

  SELECT * INTO v_row
  FROM data.tenant_ai_config
  WHERE tenant_id = p_tenant_id;

  IF FOUND THEN
    v_default := v_row.default_provider;
  END IF;

  FOREACH v_provider IN ARRAY v_all LOOP
    v_cfg_found := false;
    SELECT * INTO v_cfg
    FROM data.tenant_ai_provider_config
    WHERE tenant_id = p_tenant_id
      AND provider = v_provider;

    IF FOUND THEN
      v_cfg_found := true;
    END IF;

    SELECT * INTO v_platform
    FROM data.platform_ai_defaults
    WHERE provider = v_provider;

    v_providers := v_providers || jsonb_build_array(
      jsonb_build_object(
        'provider', v_provider,
        'configured', (
          v_cfg_found
          AND v_cfg.ai_key_secret_id IS NOT NULL
          AND v_cfg.key_verified_at IS NOT NULL
        ),
        'has_key', (v_cfg_found AND v_cfg.ai_key_secret_id IS NOT NULL),
        'verified', (v_cfg_found AND v_cfg.key_verified_at IS NOT NULL),
        'key_verified_at', CASE WHEN v_cfg_found THEN v_cfg.key_verified_at ELSE NULL END,
        'key_last_error', CASE WHEN v_cfg_found THEN v_cfg.key_last_error ELSE NULL END,
        'model', COALESCE(
          CASE WHEN v_cfg_found THEN v_cfg.model ELSE NULL END,
          v_platform.default_model,
          api.ai_provider_default_model(v_provider)
        ),
        'base_url', COALESCE(
          CASE WHEN v_cfg_found THEN v_cfg.base_url ELSE NULL END,
          api.ai_provider_default_base_url(v_provider)
        ),
        'available_models', COALESCE(
          CASE WHEN v_cfg_found THEN v_cfg.available_models ELSE NULL END,
          '{}'::text[]
        ),
        'enabled_models', COALESCE(
          CASE WHEN v_cfg_found THEN v_cfg.enabled_models ELSE NULL END,
          '{}'::text[]
        ),
        'last_models_sync_at', CASE WHEN v_cfg_found THEN v_cfg.last_models_sync_at ELSE NULL END,
        'suggested_models', COALESCE(v_platform.suggested_models, '{}'::text[]),
        'billing_url', COALESCE(v_platform.billing_url, ''),
        'system_prompt', COALESCE(
          CASE WHEN v_cfg_found THEN v_cfg.system_prompt ELSE NULL END,
          v_platform.system_prompt,
          v_row.system_prompt
        ),
        'temperature', COALESCE(
          CASE WHEN v_cfg_found THEN v_cfg.temperature ELSE NULL END,
          v_platform.temperature,
          v_row.temperature,
          0.20
        ),
        'max_tokens', COALESCE(
          CASE WHEN v_cfg_found THEN v_cfg.max_tokens ELSE NULL END,
          v_platform.max_tokens,
          v_row.max_tokens,
          4096
        ),
        'platform_system_prompt', v_platform.system_prompt,
        'platform_temperature', COALESCE(v_platform.temperature, 0.20),
        'platform_max_tokens', COALESCE(v_platform.max_tokens, 4096),
        'system_prompt_override', CASE WHEN v_cfg_found THEN v_cfg.system_prompt ELSE NULL END,
        'temperature_override', CASE WHEN v_cfg_found THEN v_cfg.temperature ELSE NULL END,
        'max_tokens_override', CASE WHEN v_cfg_found THEN v_cfg.max_tokens ELSE NULL END
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
    'rate_limit_tokens_per_day', COALESCE(v_row.rate_limit_tokens_per_day, 500000),
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
-- update_tenant_ai_provider_meta — enabled_models
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.update_tenant_ai_provider_meta(uuid, text, text, text, text[]);

CREATE OR REPLACE FUNCTION api.update_tenant_ai_provider_meta(
  p_tenant_id        uuid,
  p_provider         text,
  p_model            text DEFAULT NULL,
  p_base_url         text DEFAULT NULL,
  p_available_models text[] DEFAULT NULL,
  p_enabled_models   text[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_provider data.ai_provider;
  v_model    text;
  v_base_url text;
BEGIN
  v_provider := api.parse_ai_provider(p_provider);
  v_model := COALESCE(nullif(trim(p_model), ''), api.ai_provider_default_model(v_provider));
  v_base_url := COALESCE(nullif(trim(p_base_url), ''), api.ai_provider_default_base_url(v_provider));

  INSERT INTO data.tenant_ai_config (tenant_id, default_provider, is_active)
  VALUES (p_tenant_id, v_provider, true)
  ON CONFLICT (tenant_id) DO NOTHING;

  INSERT INTO data.tenant_ai_provider_config (
    tenant_id, provider, model, base_url, available_models, enabled_models
  ) VALUES (
    p_tenant_id, v_provider, v_model, v_base_url,
    COALESCE(p_available_models, '{}'::text[]),
    COALESCE(p_enabled_models, '{}'::text[])
  )
  ON CONFLICT (tenant_id, provider) DO UPDATE
    SET model = EXCLUDED.model,
        base_url = EXCLUDED.base_url,
        available_models = COALESCE(p_available_models, data.tenant_ai_provider_config.available_models),
        enabled_models = COALESCE(p_enabled_models, data.tenant_ai_provider_config.enabled_models),
        updated_at = now();

  RETURN jsonb_build_object('success', true, 'provider', v_provider, 'model', v_model);
END;
$$;

REVOKE ALL ON FUNCTION api.update_tenant_ai_provider_meta(uuid, text, text, text, text[], text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.update_tenant_ai_provider_meta(uuid, text, text, text, text[], text[]) FROM authenticated;
REVOKE ALL ON FUNCTION api.update_tenant_ai_provider_meta(uuid, text, text, text, text[], text[]) FROM anon;
GRANT EXECUTE ON FUNCTION api.update_tenant_ai_provider_meta(uuid, text, text, text, text[], text[]) TO service_role;

-- ---------------------------------------------------------------------------
-- set_tenant_ai_tokens_daily_limit — manager/owner
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.set_tenant_ai_tokens_daily_limit(
  p_tenant_id                  uuid,
  p_rate_limit_tokens_per_day  integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  PERFORM api._assert_ai_manager_access(p_tenant_id);

  IF p_rate_limit_tokens_per_day IS NULL OR p_rate_limit_tokens_per_day <= 0 THEN
    RAISE EXCEPTION 'rate_limit_tokens_per_day must be positive';
  END IF;

  INSERT INTO data.tenant_ai_config (tenant_id, rate_limit_tokens_per_day)
  VALUES (p_tenant_id, p_rate_limit_tokens_per_day)
  ON CONFLICT (tenant_id) DO UPDATE
    SET rate_limit_tokens_per_day = EXCLUDED.rate_limit_tokens_per_day,
        updated_at = now();

  RETURN jsonb_build_object(
    'success', true,
    'rate_limit_tokens_per_day', p_rate_limit_tokens_per_day
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_tenant_ai_tokens_daily_limit(uuid, integer) TO authenticated;

-- ---------------------------------------------------------------------------
-- _get_ai_usage_stats_internal — tokens avui vs límit diari
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api._get_ai_usage_stats_internal(p_tenant_id uuid)
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
  v_tokens_today  bigint := 0;
  v_daily         jsonb := '[]'::jsonb;
  v_by_provider   jsonb := '[]'::jsonb;
  v_top_users     jsonb := '[]'::jsonb;
  v_summary       jsonb;
BEGIN
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

  SELECT COALESCE(SUM(
    COALESCE(prompt_tokens, 0) + COALESCE(completion_tokens, 0)
  ), 0) INTO v_tokens_today
  FROM data.ai_usage_ledger
  WHERE tenant_id = p_tenant_id
    AND created_at >= v_day_start
    AND request_status = 'success';

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

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'user_id', user_id,
      'email', email,
      'full_name', full_name,
      'requests', requests,
      'tokens', tokens,
      'blocked', blocked
    ) ORDER BY requests DESC
  ), '[]'::jsonb)
  INTO v_top_users
  FROM (
    SELECT
      l.user_id,
      p.email,
      p.full_name,
      COUNT(*)::integer AS requests,
      COALESCE(SUM(l.total_tokens), 0)::bigint AS tokens,
      COUNT(*) FILTER (WHERE l.request_status LIKE 'blocked_%')::integer AS blocked
    FROM data.ai_usage_ledger l
    LEFT JOIN data.profiles p ON p.id = l.user_id
    WHERE l.tenant_id = p_tenant_id
      AND l.created_at >= (now() - interval '30 days')
    GROUP BY l.user_id, p.email, p.full_name
    ORDER BY COUNT(*) DESC
    LIMIT 20
  ) u;

  v_summary := jsonb_build_object(
    'hour_count', v_hour_count,
    'day_count', v_day_count,
    'hour_limit', COALESCE(v_cfg.rate_limit_per_hour, 60),
    'day_limit', COALESCE(v_cfg.rate_limit_per_day, 500),
    'tokens_today', v_tokens_today,
    'tokens_day_limit', COALESCE(v_cfg.rate_limit_tokens_per_day, 500000),
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
    'by_provider', v_by_provider,
    'top_users', v_top_users
  );
END;
$$;
