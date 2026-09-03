-- OpenRouter com a quart proveïdor BYOK (API compatible OpenAI)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.all_ai_providers()
RETURNS data.ai_provider[]
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT ARRAY['openai', 'anthropic', 'gemini', 'openrouter']::data.ai_provider[];
$$;

CREATE OR REPLACE FUNCTION api.parse_ai_provider(p_provider text)
RETURNS data.ai_provider
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_normalized text := lower(trim(p_provider));
BEGIN
  IF v_normalized IS NULL OR v_normalized = '' THEN
    RAISE EXCEPTION 'provider is required';
  END IF;

  IF v_normalized NOT IN ('openai', 'anthropic', 'gemini', 'openrouter') THEN
    RAISE EXCEPTION 'Invalid provider. Must be openai, anthropic, gemini or openrouter';
  END IF;

  RETURN v_normalized::data.ai_provider;
END;
$$;

CREATE OR REPLACE FUNCTION api.ai_provider_default_base_url(p_provider data.ai_provider)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF p_provider = 'openai' THEN
    RETURN 'https://api.openai.com/v1';
  ELSIF p_provider = 'anthropic' THEN
    RETURN 'https://api.anthropic.com';
  ELSIF p_provider = 'gemini' THEN
    RETURN 'https://generativelanguage.googleapis.com/v1beta';
  ELSIF p_provider = 'openrouter' THEN
    RETURN 'https://openrouter.ai/api/v1';
  END IF;
  RETURN 'https://api.openai.com/v1';
END;
$$;

CREATE OR REPLACE FUNCTION api.ai_provider_default_model(p_provider data.ai_provider)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF p_provider = 'openai' THEN
    RETURN 'gpt-4o-mini';
  ELSIF p_provider = 'anthropic' THEN
    RETURN 'claude-3-5-haiku-latest';
  ELSIF p_provider = 'gemini' THEN
    RETURN 'gemini-2.0-flash';
  ELSIF p_provider = 'openrouter' THEN
    RETURN 'openai/gpt-4o-mini';
  END IF;
  RETURN 'gpt-4o-mini';
END;
$$;

INSERT INTO data.platform_ai_defaults (
  provider,
  suggested_models,
  default_model,
  billing_url,
  temperature,
  max_tokens,
  base_url
) VALUES (
  'openrouter',
  ARRAY[
    'openai/gpt-4o-mini',
    'openai/gpt-4o',
    'anthropic/claude-sonnet-4',
    'google/gemini-2.5-flash'
  ],
  'openai/gpt-4o-mini',
  'https://openrouter.ai/settings/credits',
  0.20,
  4096,
  'https://openrouter.ai/api/v1'
)
ON CONFLICT (provider) DO UPDATE
  SET
    suggested_models = EXCLUDED.suggested_models,
    default_model = EXCLUDED.default_model,
    billing_url = EXCLUDED.billing_url,
    base_url = COALESCE(data.platform_ai_defaults.base_url, EXCLUDED.base_url),
    updated_at = now();

-- ---------------------------------------------------------------------------
-- get_ai_config_for_tenant — inclou openrouter
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
-- RPCs — validació via parse_ai_provider
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.set_tenant_ai_default_provider(
  p_tenant_id uuid,
  p_provider  text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_provider data.ai_provider;
BEGIN
  PERFORM api._assert_ai_manager_access(p_tenant_id);
  v_provider := api.parse_ai_provider(p_provider);

  INSERT INTO data.tenant_ai_config (tenant_id, default_provider, is_active)
  VALUES (p_tenant_id, v_provider, true)
  ON CONFLICT (tenant_id) DO UPDATE
    SET default_provider = EXCLUDED.default_provider;

  RETURN jsonb_build_object('success', true, 'default_provider', v_provider);
END;
$$;

CREATE OR REPLACE FUNCTION api.update_tenant_ai_provider_meta(
  p_tenant_id uuid,
  p_provider  text,
  p_model     text DEFAULT NULL,
  p_base_url  text DEFAULT NULL,
  p_available_models text[] DEFAULT NULL
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
    tenant_id, provider, model, base_url, available_models
  ) VALUES (
    p_tenant_id, v_provider, v_model, v_base_url, COALESCE(p_available_models, '{}'::text[])
  )
  ON CONFLICT (tenant_id, provider) DO UPDATE
    SET model = EXCLUDED.model,
        base_url = EXCLUDED.base_url,
        available_models = COALESCE(p_available_models, data.tenant_ai_provider_config.available_models);

  RETURN jsonb_build_object('success', true, 'provider', v_provider, 'model', v_model);
END;
$$;

CREATE OR REPLACE FUNCTION api.save_tenant_ai_provider_generation_settings(
  p_tenant_id     uuid,
  p_provider      text,
  p_system_prompt text DEFAULT NULL,
  p_temperature   numeric DEFAULT NULL,
  p_max_tokens    integer DEFAULT NULL,
  p_use_platform_defaults boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_provider data.ai_provider;
BEGIN
  PERFORM api._assert_ai_manager_access(p_tenant_id);
  v_provider := api.parse_ai_provider(p_provider);

  IF p_use_platform_defaults THEN
    UPDATE data.tenant_ai_provider_config
    SET
      system_prompt = NULL,
      temperature = NULL,
      max_tokens = NULL,
      updated_at = now()
    WHERE tenant_id = p_tenant_id
      AND provider = v_provider;

    IF NOT FOUND THEN
      INSERT INTO data.tenant_ai_provider_config (
        tenant_id, provider, model, system_prompt, temperature, max_tokens
      )
      VALUES (
        p_tenant_id,
        v_provider,
        api.ai_provider_default_model(v_provider),
        NULL,
        NULL,
        NULL
      );
    END IF;

    RETURN jsonb_build_object('ok', true, 'reset', true);
  END IF;

  IF p_temperature IS NOT NULL AND (p_temperature < 0 OR p_temperature > 1) THEN
    RAISE EXCEPTION 'temperature must be between 0 and 1';
  END IF;

  IF p_max_tokens IS NOT NULL AND (p_max_tokens < 1 OR p_max_tokens > 128000) THEN
    RAISE EXCEPTION 'max_tokens must be between 1 and 128000';
  END IF;

  INSERT INTO data.tenant_ai_provider_config (
    tenant_id, provider, model, system_prompt, temperature, max_tokens
  )
  VALUES (
    p_tenant_id,
    v_provider,
    api.ai_provider_default_model(v_provider),
    NULLIF(trim(p_system_prompt), ''),
    p_temperature,
    p_max_tokens
  )
  ON CONFLICT (tenant_id, provider) DO UPDATE
  SET
    system_prompt = EXCLUDED.system_prompt,
    temperature = EXCLUDED.temperature,
    max_tokens = EXCLUDED.max_tokens,
    updated_at = now();

  RETURN jsonb_build_object('ok', true);
END;
$$;

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
  v_provider := api.parse_ai_provider(p_provider);

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

CREATE OR REPLACE FUNCTION api.delete_tenant_ai_provider_key(
  p_tenant_id uuid,
  p_provider  text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_provider data.ai_provider;
  v_row      data.tenant_ai_provider_config%ROWTYPE;
BEGIN
  v_provider := api.parse_ai_provider(p_provider);

  SELECT * INTO v_row
  FROM data.tenant_ai_provider_config
  WHERE tenant_id = p_tenant_id
    AND provider = v_provider;

  IF NOT FOUND OR v_row.ai_key_secret_id IS NULL THEN
    RETURN jsonb_build_object('success', true, 'deleted', false);
  END IF;

  DELETE FROM vault.secrets WHERE id = v_row.ai_key_secret_id;

  UPDATE data.tenant_ai_provider_config
  SET ai_key_secret_id = NULL,
      key_verified_at = NULL,
      key_last_error = NULL
  WHERE tenant_id = p_tenant_id
    AND provider = v_provider;

  RETURN jsonb_build_object('success', true, 'deleted', true, 'provider', v_provider);
END;
$$;

CREATE OR REPLACE FUNCTION api.save_tenant_ai_provider_secret(
  p_tenant_id uuid,
  p_provider  text,
  p_api_key   text,
  p_model     text DEFAULT NULL,
  p_base_url  text DEFAULT NULL,
  p_available_models text[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_provider       data.ai_provider;
  v_existing       data.tenant_ai_provider_config%ROWTYPE;
  v_secret_id      uuid;
  v_secret_name    text;
  v_secret_desc    text;
  v_model          text;
  v_base_url       text;
BEGIN
  IF p_api_key IS NULL OR trim(p_api_key) = '' THEN
    RAISE EXCEPTION 'API key is required';
  END IF;

  v_provider := api.parse_ai_provider(p_provider);
  v_model := COALESCE(nullif(trim(p_model), ''), api.ai_provider_default_model(v_provider));
  v_base_url := COALESCE(nullif(trim(p_base_url), ''), api.ai_provider_default_base_url(v_provider));

  v_secret_name := 'ai_' || v_provider::text || '_' || replace(p_tenant_id::text, '-', '');
  v_secret_desc := 'AI API key (' || v_provider::text || ') for tenant ' || p_tenant_id::text;

  INSERT INTO data.tenant_ai_config (tenant_id, default_provider, is_active)
  VALUES (p_tenant_id, v_provider, true)
  ON CONFLICT (tenant_id) DO NOTHING;

  SELECT * INTO v_existing
  FROM data.tenant_ai_provider_config
  WHERE tenant_id = p_tenant_id
    AND provider = v_provider;

  IF FOUND AND v_existing.ai_key_secret_id IS NOT NULL THEN
    PERFORM vault.update_secret(v_existing.ai_key_secret_id, p_api_key, v_secret_name, v_secret_desc);
    v_secret_id := v_existing.ai_key_secret_id;
  ELSE
    v_secret_id := vault.create_secret(p_api_key, v_secret_name, v_secret_desc);
  END IF;

  INSERT INTO data.tenant_ai_provider_config (
    tenant_id, provider, model, base_url, ai_key_secret_id, available_models,
    key_verified_at, key_last_error
  ) VALUES (
    p_tenant_id, v_provider, v_model, v_base_url, v_secret_id,
    COALESCE(p_available_models, '{}'::text[]),
    now(), NULL
  )
  ON CONFLICT (tenant_id, provider) DO UPDATE
    SET model = EXCLUDED.model,
        base_url = EXCLUDED.base_url,
        ai_key_secret_id = EXCLUDED.ai_key_secret_id,
        available_models = COALESCE(p_available_models, data.tenant_ai_provider_config.available_models),
        key_verified_at = now(),
        key_last_error = NULL;

  RETURN jsonb_build_object(
    'success', true,
    'provider', v_provider,
    'configured', true,
    'model', v_model,
    'key_verified_at', now()
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.save_platform_ai_provider_secret(
  p_provider  text,
  p_api_key   text,
  p_model     text DEFAULT NULL,
  p_base_url  text DEFAULT NULL,
  p_available_models text[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_provider    data.ai_provider;
  v_existing    data.platform_ai_defaults%ROWTYPE;
  v_secret_id   uuid;
  v_secret_name text;
  v_secret_desc text;
  v_model       text;
  v_base_url    text;
BEGIN
  IF p_api_key IS NULL OR trim(p_api_key) = '' THEN
    RAISE EXCEPTION 'API key is required';
  END IF;

  v_provider := api.parse_ai_provider(p_provider);

  SELECT * INTO v_existing FROM data.platform_ai_defaults WHERE provider = v_provider;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'platform_ai_defaults row not found for %', v_provider;
  END IF;

  v_model := COALESCE(nullif(trim(p_model), ''), v_existing.default_model, api.ai_provider_default_model(v_provider));
  v_base_url := COALESCE(nullif(trim(p_base_url), ''), v_existing.base_url, api.ai_provider_default_base_url(v_provider));

  v_secret_name := 'ai_platform_' || v_provider::text;
  v_secret_desc := 'Platform AI API key (' || v_provider::text || ')';

  IF v_existing.ai_key_secret_id IS NOT NULL THEN
    PERFORM vault.update_secret(v_existing.ai_key_secret_id, p_api_key, v_secret_name, v_secret_desc);
    v_secret_id := v_existing.ai_key_secret_id;
  ELSE
    v_secret_id := vault.create_secret(p_api_key, v_secret_name, v_secret_desc);
  END IF;

  UPDATE data.platform_ai_defaults
  SET
    default_model = v_model,
    base_url = v_base_url,
    ai_key_secret_id = v_secret_id,
    available_models = COALESCE(p_available_models, available_models, '{}'::text[]),
    key_verified_at = now(),
    key_last_error = NULL,
    updated_at = now()
  WHERE provider = v_provider;

  RETURN jsonb_build_object(
    'success', true,
    'provider', v_provider,
    'configured', true,
    'model', v_model,
    'key_verified_at', now()
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.delete_platform_ai_provider_key(p_provider text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_provider data.ai_provider;
  v_row      data.platform_ai_defaults%ROWTYPE;
BEGIN
  v_provider := api.parse_ai_provider(p_provider);

  SELECT * INTO v_row FROM data.platform_ai_defaults WHERE provider = v_provider;

  IF NOT FOUND OR v_row.ai_key_secret_id IS NULL THEN
    RETURN jsonb_build_object('success', true, 'deleted', false);
  END IF;

  DELETE FROM vault.secrets WHERE id = v_row.ai_key_secret_id;

  UPDATE data.platform_ai_defaults
  SET
    ai_key_secret_id = NULL,
    key_verified_at = NULL,
    key_last_error = NULL,
    available_models = '{}'::text[],
    last_models_sync_at = NULL,
    updated_at = now()
  WHERE provider = v_provider;

  RETURN jsonb_build_object('success', true, 'deleted', true, 'provider', v_provider);
END;
$$;

CREATE OR REPLACE FUNCTION api.get_platform_ai_api_key_for_sync(p_provider text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_provider data.ai_provider;
  v_row      data.platform_ai_defaults%ROWTYPE;
  v_secret   text;
BEGIN
  v_provider := api.parse_ai_provider(p_provider);

  SELECT * INTO v_row FROM data.platform_ai_defaults WHERE provider = v_provider;

  IF NOT FOUND OR v_row.ai_key_secret_id IS NULL OR v_row.key_verified_at IS NULL THEN
    RAISE EXCEPTION 'Platform provider % is not configured with a verified key', v_provider;
  END IF;

  SELECT decrypted_secret INTO v_secret
  FROM vault.decrypted_secrets
  WHERE id = v_row.ai_key_secret_id;

  IF v_secret IS NULL OR trim(v_secret) = '' THEN
    RAISE EXCEPTION 'Could not decrypt platform API key for %', v_provider;
  END IF;

  RETURN jsonb_build_object(
    'provider', v_provider,
    'api_key', v_secret,
    'base_url', COALESCE(v_row.base_url, api.ai_provider_default_base_url(v_provider)),
    'model', COALESCE(v_row.default_model, api.ai_provider_default_model(v_provider))
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.persist_platform_ai_provider_models(
  p_provider text,
  p_models   text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_provider data.ai_provider;
BEGIN
  v_provider := api.parse_ai_provider(p_provider);

  UPDATE data.platform_ai_defaults
  SET
    available_models = COALESCE(p_models, '{}'::text[]),
    last_models_sync_at = now(),
    updated_at = now()
  WHERE provider = v_provider;

  RETURN jsonb_build_object(
    'success', true,
    'provider', v_provider,
    'models', COALESCE(p_models, '{}'::text[]),
    'synced_at', now()
  );
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
  v_provider := api.parse_ai_provider(p_provider);

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

CREATE OR REPLACE FUNCTION api.get_admin_tenant_ai_summary(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_cfg       data.tenant_ai_config%ROWTYPE;
  v_stats     jsonb;
  v_providers jsonb := '[]'::jsonb;
  v_provider  data.ai_provider;
  v_all       data.ai_provider[] := api.all_ai_providers();
  v_pc        data.tenant_ai_provider_config%ROWTYPE;
BEGIN
  SELECT * INTO v_cfg FROM data.tenant_ai_config WHERE tenant_id = p_tenant_id;

  FOREACH v_provider IN ARRAY v_all LOOP
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

CREATE OR REPLACE FUNCTION api.record_tenant_ai_key_verification_error(
  p_tenant_id uuid,
  p_provider  text,
  p_error     text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_provider data.ai_provider;
BEGIN
  v_provider := api.parse_ai_provider(p_provider);

  INSERT INTO data.tenant_ai_provider_config (tenant_id, provider, model, key_last_error)
  VALUES (
    p_tenant_id,
    v_provider,
    api.ai_provider_default_model(v_provider),
    left(p_error, 500)
  )
  ON CONFLICT (tenant_id, provider) DO UPDATE
    SET key_last_error = left(p_error, 500);
END;
$$;
