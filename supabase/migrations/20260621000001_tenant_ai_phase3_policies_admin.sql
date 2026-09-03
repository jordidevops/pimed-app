-- =============================================================================
-- Tenant AI — Phase 3: user policies, platform defaults, admin visibility
-- =============================================================================

-- ---------------------------------------------------------------------------
-- platform_ai_defaults (control plane)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.platform_ai_defaults (
  provider           data.ai_provider PRIMARY KEY,
  suggested_models   text[] NOT NULL DEFAULT '{}',
  default_model      text NOT NULL,
  billing_url        text NOT NULL,
  system_prompt      text,
  temperature        numeric(3,2) NOT NULL DEFAULT 0.20,
  max_tokens         integer NOT NULL DEFAULT 4096,
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT platform_ai_defaults_temperature_check
    CHECK (temperature >= 0 AND temperature <= 1),
  CONSTRAINT platform_ai_defaults_max_tokens_check
    CHECK (max_tokens > 0 AND max_tokens <= 128000)
);

INSERT INTO data.platform_ai_defaults (
  provider, suggested_models, default_model, billing_url, temperature, max_tokens
) VALUES
  (
    'openai',
    ARRAY['gpt-4o-mini', 'gpt-4o', 'gpt-4.1-mini'],
    'gpt-4o-mini',
    'https://platform.openai.com/settings/organization/billing',
    0.20,
    4096
  ),
  (
    'anthropic',
    ARRAY['claude-3-5-haiku-latest', 'claude-3-5-sonnet-latest', 'claude-sonnet-4-20250514'],
    'claude-3-5-haiku-latest',
    'https://console.anthropic.com/settings/billing',
    0.20,
    4096
  ),
  (
    'gemini',
    ARRAY['gemini-2.0-flash', 'gemini-1.5-pro', 'gemini-2.5-flash-preview-05-20'],
    'gemini-2.0-flash',
    'https://aistudio.google.com/app/plan_and_billing',
    0.20,
    4096
  )
ON CONFLICT (provider) DO NOTHING;

-- ---------------------------------------------------------------------------
-- tenant_ai_user_policy
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.tenant_ai_user_policy (
  tenant_id             uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  user_id               uuid NOT NULL,
  policy                text NOT NULL DEFAULT 'allow'
    CHECK (policy IN ('allow', 'warn_only', 'block')),
  custom_hourly_limit   integer CHECK (custom_hourly_limit IS NULL OR custom_hourly_limit > 0),
  custom_daily_limit    integer CHECK (custom_daily_limit IS NULL OR custom_daily_limit > 0),
  notes                 text,
  updated_by            uuid,
  updated_at            timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_tenant_ai_user_policy_tenant
  ON data.tenant_ai_user_policy (tenant_id);

-- ---------------------------------------------------------------------------
-- Owner-only assertion
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api._assert_ai_owner_access(p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') = 'owner'
  ) THEN
    RAISE EXCEPTION 'Access denied: owner role required';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Extend get_ai_config_for_tenant — billing_url + suggested_models from platform
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
  v_platform        data.platform_ai_defaults%ROWTYPE;
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

    SELECT * INTO v_platform
    FROM data.platform_ai_defaults
    WHERE provider = v_provider;

    v_providers := v_providers || jsonb_build_array(
      jsonb_build_object(
        'provider', v_provider,
        'configured', (v_cfg.ai_key_secret_id IS NOT NULL AND v_cfg.key_verified_at IS NOT NULL),
        'has_key', (v_cfg.ai_key_secret_id IS NOT NULL),
        'verified', (v_cfg.key_verified_at IS NOT NULL),
        'key_verified_at', v_cfg.key_verified_at,
        'key_last_error', v_cfg.key_last_error,
        'model', COALESCE(v_cfg.model, v_platform.default_model, api.ai_provider_default_model(v_provider)),
        'base_url', COALESCE(v_cfg.base_url, api.ai_provider_default_base_url(v_provider)),
        'available_models', COALESCE(v_cfg.available_models, '{}'::text[]),
        'last_models_sync_at', v_cfg.last_models_sync_at,
        'suggested_models', COALESCE(v_platform.suggested_models, '{}'::text[]),
        'billing_url', COALESCE(v_platform.billing_url, '')
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
-- get_ai_user_access — current user or service_role (edge)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_ai_user_access(p_tenant_id uuid, p_user_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_user_id       uuid := COALESCE(p_user_id, auth.uid());
  v_policy        data.tenant_ai_user_policy%ROWTYPE;
  v_cfg           data.tenant_ai_config%ROWTYPE;
  v_configured    boolean := false;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF auth.uid() IS NOT NULL AND auth.uid() <> v_user_id THEN
    IF NOT (
      data.jwt_user_tenants() ? p_tenant_id::text
      AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    ) THEN
      RAISE EXCEPTION 'Access denied';
    END IF;
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.tenant_members
      WHERE tenant_id = p_tenant_id
        AND user_id = v_user_id
        AND is_active = true
    ) THEN
      RAISE EXCEPTION 'Access denied: not a tenant member';
    END IF;
  END IF;

  SELECT * INTO v_cfg
  FROM data.tenant_ai_config
  WHERE tenant_id = p_tenant_id;

  SELECT EXISTS (
    SELECT 1
    FROM data.tenant_ai_provider_config pc
    JOIN data.tenant_ai_config tc ON tc.tenant_id = pc.tenant_id
    WHERE pc.tenant_id = p_tenant_id
      AND pc.provider = COALESCE(v_cfg.default_provider, 'openai'::data.ai_provider)
      AND pc.ai_key_secret_id IS NOT NULL
      AND pc.key_verified_at IS NOT NULL
      AND COALESCE(tc.is_active, true) = true
  ) INTO v_configured;

  SELECT * INTO v_policy
  FROM data.tenant_ai_user_policy
  WHERE tenant_id = p_tenant_id
    AND user_id = v_user_id;

  RETURN jsonb_build_object(
    'configured', v_configured,
    'policy', COALESCE(v_policy.policy, 'allow'),
    'custom_hourly_limit', v_policy.custom_hourly_limit,
    'custom_daily_limit', v_policy.custom_daily_limit,
    'blocked', COALESCE(v_policy.policy, 'allow') = 'block',
    'warn_only', COALESCE(v_policy.policy, 'allow') = 'warn_only'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_ai_user_access(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_ai_user_access(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- get_tenant_ai_user_policies — owner lists members + policies
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_tenant_ai_user_policies(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  PERFORM api._assert_ai_owner_access(p_tenant_id);

  SELECT COALESCE(jsonb_agg(row_data ORDER BY email), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT jsonb_build_object(
      'user_id', m.user_id,
      'email', p.email,
      'full_name', p.full_name,
      'role', m.role,
      'policy', COALESCE(pol.policy, 'allow'),
      'custom_hourly_limit', pol.custom_hourly_limit,
      'custom_daily_limit', pol.custom_daily_limit,
      'notes', pol.notes,
      'updated_at', pol.updated_at
    ) AS row_data,
    p.email
    FROM (
      SELECT DISTINCT ON (tm.user_id)
        tm.user_id,
        tm.role
      FROM data.tenant_members tm
      WHERE tm.tenant_id = p_tenant_id
        AND tm.is_active = true
        AND tm.site_id IS NULL
      ORDER BY tm.user_id, tm.joined_at ASC
    ) m
    INNER JOIN data.profiles p ON p.id = m.user_id
    LEFT JOIN data.tenant_ai_user_policy pol
      ON pol.tenant_id = p_tenant_id AND pol.user_id = m.user_id
  ) sub;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_tenant_ai_user_policies(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_tenant_ai_user_policies(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- set_tenant_ai_user_policy — owner
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.set_tenant_ai_user_policy(
  p_tenant_id           uuid,
  p_user_id             uuid,
  p_policy              text,
  p_custom_hourly_limit integer DEFAULT NULL,
  p_custom_daily_limit  integer DEFAULT NULL,
  p_notes               text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  PERFORM api._assert_ai_owner_access(p_tenant_id);

  IF lower(p_policy) NOT IN ('allow', 'warn_only', 'block') THEN
    RAISE EXCEPTION 'Invalid policy';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.tenant_members
    WHERE tenant_id = p_tenant_id AND user_id = p_user_id AND is_active = true
  ) THEN
    RAISE EXCEPTION 'User is not an active tenant member';
  END IF;

  INSERT INTO data.tenant_ai_user_policy (
    tenant_id, user_id, policy,
    custom_hourly_limit, custom_daily_limit, notes, updated_by
  ) VALUES (
    p_tenant_id, p_user_id, lower(p_policy),
    p_custom_hourly_limit, p_custom_daily_limit, p_notes, auth.uid()
  )
  ON CONFLICT (tenant_id, user_id) DO UPDATE
    SET policy = EXCLUDED.policy,
        custom_hourly_limit = EXCLUDED.custom_hourly_limit,
        custom_daily_limit = EXCLUDED.custom_daily_limit,
        notes = EXCLUDED.notes,
        updated_by = auth.uid(),
        updated_at = now();

  RETURN jsonb_build_object('success', true, 'user_id', p_user_id, 'policy', lower(p_policy));
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_tenant_ai_user_policy(uuid, uuid, text, integer, integer, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- delete_tenant_ai_user_policy — revert to default allow
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.delete_tenant_ai_user_policy(
  p_tenant_id uuid,
  p_user_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  PERFORM api._assert_ai_owner_access(p_tenant_id);

  DELETE FROM data.tenant_ai_user_policy
  WHERE tenant_id = p_tenant_id AND user_id = p_user_id;

  RETURN jsonb_build_object('success', true, 'user_id', p_user_id);
END;
$$;

GRANT EXECUTE ON FUNCTION api.delete_tenant_ai_user_policy(uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- check_and_increment_ai_rate_limit — respect custom user limits
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
  v_user_pol       data.tenant_ai_user_policy%ROWTYPE;
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

  SELECT * INTO v_user_pol
  FROM data.tenant_ai_user_policy
  WHERE tenant_id = p_tenant_id AND user_id = p_user_id;

  IF FOUND THEN
    IF v_user_pol.custom_hourly_limit IS NOT NULL THEN
      v_hour_limit := v_user_pol.custom_hourly_limit;
    END IF;
    IF v_user_pol.custom_daily_limit IS NOT NULL THEN
      v_day_limit := v_user_pol.custom_daily_limit;
    END IF;
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

-- ---------------------------------------------------------------------------
-- get_ai_usage_stats — add top_users
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

REVOKE ALL ON FUNCTION api._get_ai_usage_stats_internal(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api._get_ai_usage_stats_internal(uuid) TO service_role;

CREATE OR REPLACE FUNCTION api.get_ai_usage_stats(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  PERFORM api._assert_ai_manager_access(p_tenant_id);
  RETURN api._get_ai_usage_stats_internal(p_tenant_id);
END;
$$;

-- ---------------------------------------------------------------------------
-- Admin: tenant AI summary (service_role from admin-portal)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_admin_tenant_ai_summary(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_cfg     data.tenant_ai_config%ROWTYPE;
  v_stats   jsonb;
  v_providers jsonb := '[]'::jsonb;
  v_provider data.ai_provider;
  v_pc      data.tenant_ai_provider_config%ROWTYPE;
BEGIN
  SELECT * INTO v_cfg FROM data.tenant_ai_config WHERE tenant_id = p_tenant_id;

  FOREACH v_provider IN ARRAY ARRAY['openai', 'anthropic', 'gemini']::data.ai_provider[] LOOP
    SELECT * INTO v_pc
    FROM data.tenant_ai_provider_config
    WHERE tenant_id = p_tenant_id AND provider = v_provider;

    v_providers := v_providers || jsonb_build_array(
      jsonb_build_object(
        'provider', v_provider,
        'has_key', (v_pc.ai_key_secret_id IS NOT NULL),
        'verified', (v_pc.key_verified_at IS NOT NULL),
        'key_verified_at', v_pc.key_verified_at,
        'key_last_error', v_pc.key_last_error,
        'model', v_pc.model,
        'last_models_sync_at', v_pc.last_models_sync_at
      )
    );
  END LOOP;

  SELECT api._get_ai_usage_stats_internal(p_tenant_id) INTO v_stats;

  RETURN jsonb_build_object(
    'tenant_id', p_tenant_id,
    'default_provider', COALESCE(v_cfg.default_provider, 'openai'),
    'is_active', COALESCE(v_cfg.is_active, true),
    'rate_limit_per_hour', COALESCE(v_cfg.rate_limit_per_hour, 60),
    'rate_limit_per_day', COALESCE(v_cfg.rate_limit_per_day, 500),
    'warn_threshold_pct', COALESCE(v_cfg.warn_threshold_pct, 80),
    'hard_block_on_limit', COALESCE(v_cfg.hard_block_on_limit, true),
    'providers', v_providers,
    'usage', v_stats
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_admin_tenant_ai_summary(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_admin_tenant_ai_summary(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION api.get_admin_tenant_ai_summary(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION api.get_admin_tenant_ai_summary(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- Admin: platform defaults read/write (service_role)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_platform_ai_defaults()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'provider', provider,
      'suggested_models', suggested_models,
      'default_model', default_model,
      'billing_url', billing_url,
      'system_prompt', system_prompt,
      'temperature', temperature,
      'max_tokens', max_tokens,
      'updated_at', updated_at
    ) ORDER BY provider
  ), '[]'::jsonb)
  INTO v_result
  FROM data.platform_ai_defaults;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION api.upsert_platform_ai_defaults(
  p_provider          text,
  p_suggested_models  text[],
  p_default_model     text,
  p_billing_url       text,
  p_system_prompt     text DEFAULT NULL,
  p_temperature       numeric DEFAULT 0.20,
  p_max_tokens        integer DEFAULT 4096
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

  INSERT INTO data.platform_ai_defaults (
    provider, suggested_models, default_model, billing_url,
    system_prompt, temperature, max_tokens, updated_at
  ) VALUES (
    v_provider, COALESCE(p_suggested_models, '{}'), p_default_model, p_billing_url,
    p_system_prompt, COALESCE(p_temperature, 0.20), COALESCE(p_max_tokens, 4096), now()
  )
  ON CONFLICT (provider) DO UPDATE
    SET suggested_models = EXCLUDED.suggested_models,
        default_model = EXCLUDED.default_model,
        billing_url = EXCLUDED.billing_url,
        system_prompt = EXCLUDED.system_prompt,
        temperature = EXCLUDED.temperature,
        max_tokens = EXCLUDED.max_tokens,
        updated_at = now();

  RETURN jsonb_build_object('success', true, 'provider', v_provider);
END;
$$;

REVOKE ALL ON FUNCTION api.get_platform_ai_defaults() FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_platform_ai_defaults() FROM authenticated;
REVOKE ALL ON FUNCTION api.get_platform_ai_defaults() FROM anon;
GRANT EXECUTE ON FUNCTION api.get_platform_ai_defaults() TO service_role;

REVOKE ALL ON FUNCTION api.upsert_platform_ai_defaults(text, text[], text, text, text, numeric, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.upsert_platform_ai_defaults(text, text[], text, text, text, numeric, integer) FROM authenticated;
REVOKE ALL ON FUNCTION api.upsert_platform_ai_defaults(text, text[], text, text, text, numeric, integer) FROM anon;
GRANT EXECUTE ON FUNCTION api.upsert_platform_ai_defaults(text, text[], text, text, text, numeric, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- Admin: override tenant AI limits
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.admin_update_tenant_ai_limits(
  p_tenant_id           uuid,
  p_rate_limit_per_hour integer DEFAULT NULL,
  p_rate_limit_per_day  integer DEFAULT NULL,
  p_warn_threshold_pct  smallint DEFAULT NULL,
  p_hard_block_on_limit boolean DEFAULT NULL,
  p_is_active           boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  INSERT INTO data.tenant_ai_config (tenant_id)
  VALUES (p_tenant_id)
  ON CONFLICT (tenant_id) DO NOTHING;

  UPDATE data.tenant_ai_config
  SET rate_limit_per_hour = COALESCE(p_rate_limit_per_hour, rate_limit_per_hour),
      rate_limit_per_day = COALESCE(p_rate_limit_per_day, rate_limit_per_day),
      warn_threshold_pct = COALESCE(p_warn_threshold_pct, warn_threshold_pct),
      hard_block_on_limit = COALESCE(p_hard_block_on_limit, hard_block_on_limit),
      is_active = COALESCE(p_is_active, is_active),
      updated_at = now()
  WHERE tenant_id = p_tenant_id;

  RETURN jsonb_build_object('success', true, 'tenant_id', p_tenant_id);
END;
$$;

REVOKE ALL ON FUNCTION api.admin_update_tenant_ai_limits(uuid, integer, integer, smallint, boolean, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.admin_update_tenant_ai_limits(uuid, integer, integer, smallint, boolean, boolean) FROM authenticated;
REVOKE ALL ON FUNCTION api.admin_update_tenant_ai_limits(uuid, integer, integer, smallint, boolean, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION api.admin_update_tenant_ai_limits(uuid, integer, integer, smallint, boolean, boolean) TO service_role;
