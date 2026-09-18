-- Treat empty system_prompt / generation params as absent in COALESCE
-- (admin textarea saved as '' was masking platform/legacy prompts).

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
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_settings
  FROM data.tenant_ai_config
  WHERE tenant_id = p_tenant_id;

  IF NOT FOUND OR v_settings.is_active IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'No AI config enabled';
  END IF;

  v_target := COALESCE(
    NULLIF(lower(trim(p_provider)), '')::data.ai_provider,
    v_settings.default_provider
  );

  SELECT * INTO v_provider_cfg
  FROM data.tenant_ai_provider_config
  WHERE tenant_id = p_tenant_id AND provider = v_target;

  IF NOT FOUND OR v_provider_cfg.ai_key_secret_id IS NULL THEN
    RAISE EXCEPTION 'No AI API key configured for provider %', v_target;
  END IF;

  IF v_provider_cfg.key_verified_at IS NULL THEN
    RAISE EXCEPTION 'AI API key for provider % is not verified', v_target;
  END IF;

  v_api_key := api.get_tenant_secret(
    p_tenant_id, 'ai_api_key', v_target::text,
    'get_ai_api_key_for_generation', 'ai_completion'
  );

  IF v_api_key IS NULL THEN
    SELECT decrypted_secret INTO v_api_key
    FROM vault.decrypted_secrets WHERE id = v_provider_cfg.ai_key_secret_id;
    PERFORM data.log_secret_access(
      p_tenant_id, 'ai_api_key', v_target::text,
      'get_ai_api_key_for_generation', 'ai_completion'
    );
  END IF;

  IF v_api_key IS NULL THEN
    RAISE EXCEPTION 'AI API key not found in vault';
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
    'system_prompt', COALESCE(
      NULLIF(btrim(v_provider_cfg.system_prompt), ''),
      NULLIF(btrim(v_platform.system_prompt), ''),
      NULLIF(btrim(v_settings.system_prompt), '')
    ),
    'temperature', COALESCE(
      v_provider_cfg.temperature,
      v_platform.temperature,
      v_settings.temperature,
      0.20
    ),
    'max_tokens', COALESCE(
      v_provider_cfg.max_tokens,
      v_platform.max_tokens,
      v_settings.max_tokens,
      4096
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_ai_api_key_for_generation(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_ai_api_key_for_generation(uuid, text) FROM authenticated;
REVOKE ALL ON FUNCTION api.get_ai_api_key_for_generation(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION api.get_ai_api_key_for_generation(uuid, text) TO service_role;
