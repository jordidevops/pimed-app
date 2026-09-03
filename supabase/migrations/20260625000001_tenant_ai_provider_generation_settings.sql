-- Tenant AI: paràmetres de generació per proveïdor (override sobre platform_ai_defaults)

ALTER TABLE data.tenant_ai_provider_config
  ADD COLUMN IF NOT EXISTS system_prompt text,
  ADD COLUMN IF NOT EXISTS temperature numeric(3,2),
  ADD COLUMN IF NOT EXISTS max_tokens integer;

ALTER TABLE data.tenant_ai_provider_config
  DROP CONSTRAINT IF EXISTS tenant_ai_provider_config_temperature_check;

ALTER TABLE data.tenant_ai_provider_config
  ADD CONSTRAINT tenant_ai_provider_config_temperature_check
  CHECK (temperature IS NULL OR (temperature >= 0 AND temperature <= 1));

ALTER TABLE data.tenant_ai_provider_config
  DROP CONSTRAINT IF EXISTS tenant_ai_provider_config_max_tokens_check;

ALTER TABLE data.tenant_ai_provider_config
  ADD CONSTRAINT tenant_ai_provider_config_max_tokens_check
  CHECK (max_tokens IS NULL OR (max_tokens > 0 AND max_tokens <= 128000));

-- ---------------------------------------------------------------------------
-- get_ai_config_for_tenant — paràmetres efectius + defaults de plataforma
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
  v_cfg_found       boolean;
BEGIN
  PERFORM api._assert_ai_manager_access(p_tenant_id);

  SELECT * INTO v_row
  FROM data.tenant_ai_config
  WHERE tenant_id = p_tenant_id;

  IF FOUND THEN
    v_default := v_row.default_provider;
  END IF;

  FOREACH v_provider IN ARRAY ARRAY['openai', 'anthropic', 'gemini']::data.ai_provider[] LOOP
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
-- get_ai_api_key_for_generation — resol paràmetres per proveïdor
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_ai_api_key_for_generation(
  p_tenant_id uuid,
  p_provider  text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_settings     data.tenant_ai_config%ROWTYPE;
  v_target       data.ai_provider;
  v_provider_cfg data.tenant_ai_provider_config%ROWTYPE;
  v_platform     data.platform_ai_defaults%ROWTYPE;
  v_api_key      text;
  v_base_url     text;
  v_cfg_found    boolean := true;
BEGIN
  SELECT * INTO v_settings
  FROM data.tenant_ai_config
  WHERE tenant_id = p_tenant_id;

  IF NOT FOUND OR v_settings.is_active IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'No AI config enabled for tenant %', p_tenant_id;
  END IF;

  v_target := COALESCE(
    NULLIF(lower(trim(p_provider)), '')::data.ai_provider,
    v_settings.default_provider
  );

  SELECT * INTO v_provider_cfg
  FROM data.tenant_ai_provider_config
  WHERE tenant_id = p_tenant_id
    AND provider = v_target;

  IF NOT FOUND THEN
    v_cfg_found := false;
  END IF;

  IF NOT v_cfg_found OR v_provider_cfg.ai_key_secret_id IS NULL THEN
    RAISE EXCEPTION 'No AI API key configured for provider % (tenant %)', v_target, p_tenant_id;
  END IF;

  IF v_provider_cfg.key_verified_at IS NULL THEN
    RAISE EXCEPTION 'AI API key for provider % is not verified (tenant %)', v_target, p_tenant_id;
  END IF;

  SELECT decrypted_secret
  INTO v_api_key
  FROM vault.decrypted_secrets
  WHERE id = v_provider_cfg.ai_key_secret_id;

  IF v_api_key IS NULL THEN
    RAISE EXCEPTION 'AI API key not found in vault for tenant %', p_tenant_id;
  END IF;

  SELECT * INTO v_platform
  FROM data.platform_ai_defaults
  WHERE provider = v_target;

  v_base_url := COALESCE(
    v_provider_cfg.base_url,
    api.ai_provider_default_base_url(v_provider_cfg.provider)
  );

  RETURN jsonb_build_object(
    'provider',  v_provider_cfg.provider,
    'model',     v_provider_cfg.model,
    'base_url',  v_base_url,
    'api_key',   v_api_key,
    'system_prompt', COALESCE(v_provider_cfg.system_prompt, v_platform.system_prompt, v_settings.system_prompt),
    'temperature', COALESCE(v_provider_cfg.temperature, v_platform.temperature, v_settings.temperature, 0.20),
    'max_tokens', COALESCE(v_provider_cfg.max_tokens, v_platform.max_tokens, v_settings.max_tokens, 4096)
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- save_tenant_ai_provider_generation_settings
-- ---------------------------------------------------------------------------
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

  IF p_provider IS NULL THEN
    RAISE EXCEPTION 'provider is required';
  END IF;

  IF lower(p_provider) NOT IN ('openai', 'anthropic', 'gemini') THEN
    RAISE EXCEPTION 'Invalid provider. Must be openai, anthropic or gemini';
  END IF;

  v_provider := lower(p_provider)::data.ai_provider;

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

GRANT EXECUTE ON FUNCTION api.save_tenant_ai_provider_generation_settings(
  uuid, text, text, numeric, integer, boolean
) TO authenticated;
GRANT EXECUTE ON FUNCTION api.save_tenant_ai_provider_generation_settings(
  uuid, text, text, numeric, integer, boolean
) TO service_role;
