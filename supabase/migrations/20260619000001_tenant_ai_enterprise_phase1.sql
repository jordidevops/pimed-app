-- =============================================================================
-- Tenant AI — Enterprise Phase 1
--   · Globals: system_prompt, temperature, max_tokens, default_models
--   · Per-provider: key_verified_at, key_last_error, available_models
--   · Secrets: save/delete via service_role only (Edge Functions)
--   · REVOKE plaintext key retrieval from authenticated
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Columns
-- ---------------------------------------------------------------------------
ALTER TABLE data.tenant_ai_config
  ADD COLUMN IF NOT EXISTS system_prompt text,
  ADD COLUMN IF NOT EXISTS temperature numeric(3,2) NOT NULL DEFAULT 0.20,
  ADD COLUMN IF NOT EXISTS max_tokens integer NOT NULL DEFAULT 4096,
  ADD COLUMN IF NOT EXISTS default_models jsonb NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE data.tenant_ai_config
  DROP CONSTRAINT IF EXISTS tenant_ai_config_temperature_check;
ALTER TABLE data.tenant_ai_config
  ADD CONSTRAINT tenant_ai_config_temperature_check
  CHECK (temperature >= 0 AND temperature <= 1);

ALTER TABLE data.tenant_ai_config
  DROP CONSTRAINT IF EXISTS tenant_ai_config_max_tokens_check;
ALTER TABLE data.tenant_ai_config
  ADD CONSTRAINT tenant_ai_config_max_tokens_check
  CHECK (max_tokens > 0 AND max_tokens <= 128000);

ALTER TABLE data.tenant_ai_provider_config
  ADD COLUMN IF NOT EXISTS available_models text[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS key_verified_at timestamptz,
  ADD COLUMN IF NOT EXISTS key_last_error text;

-- Existing keys (pre-migration) treated as verified
UPDATE data.tenant_ai_provider_config
SET key_verified_at = COALESCE(key_verified_at, updated_at)
WHERE ai_key_secret_id IS NOT NULL
  AND key_verified_at IS NULL;

-- ---------------------------------------------------------------------------
-- 2) api.get_ai_config_for_tenant — extended metadata (no secrets)
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
        'available_models', COALESCE(v_cfg.available_models, '{}'::text[])
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
-- 3) api.update_tenant_ai_provider_meta — model/base_url without touching Vault
-- ---------------------------------------------------------------------------
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
  PERFORM api._assert_ai_manager_access(p_tenant_id);

  IF lower(p_provider) NOT IN ('openai', 'anthropic', 'gemini') THEN
    RAISE EXCEPTION 'Invalid provider';
  END IF;

  v_provider := lower(p_provider)::data.ai_provider;
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

GRANT EXECUTE ON FUNCTION api.update_tenant_ai_provider_meta TO authenticated;
GRANT EXECUTE ON FUNCTION api.update_tenant_ai_provider_meta TO service_role;

-- ---------------------------------------------------------------------------
-- 4) api.save_tenant_ai_provider_secret — service_role only (Edge after verify)
-- ---------------------------------------------------------------------------
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

  IF lower(p_provider) NOT IN ('openai', 'anthropic', 'gemini') THEN
    RAISE EXCEPTION 'Invalid provider';
  END IF;

  v_provider := lower(p_provider)::data.ai_provider;
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

REVOKE ALL ON FUNCTION api.save_tenant_ai_provider_secret(uuid, text, text, text, text, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.save_tenant_ai_provider_secret(uuid, text, text, text, text, text[]) FROM authenticated;
REVOKE ALL ON FUNCTION api.save_tenant_ai_provider_secret(uuid, text, text, text, text, text[]) FROM anon;
GRANT EXECUTE ON FUNCTION api.save_tenant_ai_provider_secret(uuid, text, text, text, text, text[]) TO service_role;

-- ---------------------------------------------------------------------------
-- 5) api.delete_tenant_ai_provider_key — service_role only
-- ---------------------------------------------------------------------------
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
  IF lower(p_provider) NOT IN ('openai', 'anthropic', 'gemini') THEN
    RAISE EXCEPTION 'Invalid provider';
  END IF;

  v_provider := lower(p_provider)::data.ai_provider;

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

REVOKE ALL ON FUNCTION api.delete_tenant_ai_provider_key(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.delete_tenant_ai_provider_key(uuid, text) FROM authenticated;
REVOKE ALL ON FUNCTION api.delete_tenant_ai_provider_key(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION api.delete_tenant_ai_provider_key(uuid, text) TO service_role;

-- Record verification failure without persisting key (Edge calls via service_role)
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
  IF lower(p_provider) NOT IN ('openai', 'anthropic', 'gemini') THEN
    RAISE EXCEPTION 'Invalid provider';
  END IF;

  v_provider := lower(p_provider)::data.ai_provider;

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

REVOKE ALL ON FUNCTION api.record_tenant_ai_key_verification_error(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.record_tenant_ai_key_verification_error(uuid, text, text) FROM authenticated;
REVOKE ALL ON FUNCTION api.record_tenant_ai_key_verification_error(uuid, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION api.record_tenant_ai_key_verification_error(uuid, text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 6) api.get_ai_api_key_for_generation — service_role only (Edge after auth)
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
  v_api_key      text;
  v_base_url     text;
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

  IF NOT FOUND OR v_provider_cfg.ai_key_secret_id IS NULL THEN
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

  v_base_url := COALESCE(
    v_provider_cfg.base_url,
    api.ai_provider_default_base_url(v_provider_cfg.provider)
  );

  RETURN jsonb_build_object(
    'provider',  v_provider_cfg.provider,
    'model',     v_provider_cfg.model,
    'base_url',  v_base_url,
    'api_key',   v_api_key,
    'system_prompt', v_settings.system_prompt,
    'temperature', COALESCE(v_settings.temperature, 0.20),
    'max_tokens', COALESCE(v_settings.max_tokens, 4096)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_ai_api_key_for_generation(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_ai_api_key_for_generation(uuid, text) FROM authenticated;
REVOKE ALL ON FUNCTION api.get_ai_api_key_for_generation(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION api.get_ai_api_key_for_generation(uuid, text) TO service_role;

-- Drop old single-arg overload if present
DROP FUNCTION IF EXISTS api.get_ai_api_key_for_generation(uuid);

-- ---------------------------------------------------------------------------
-- 7) Revoke key save via authenticated RPC (keys only through Edge)
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION api.save_tenant_ai_provider_config(uuid, text, text, text, text) FROM authenticated;
REVOKE ALL ON FUNCTION api.save_tenant_ai_config(uuid, text, text, text, text) FROM authenticated;
