-- Platform AI: claus API (Vault), models disponibles i defaults actualitzats

ALTER TABLE data.platform_ai_defaults
  ADD COLUMN IF NOT EXISTS base_url text,
  ADD COLUMN IF NOT EXISTS ai_key_secret_id uuid,
  ADD COLUMN IF NOT EXISTS key_verified_at timestamptz,
  ADD COLUMN IF NOT EXISTS key_last_error text,
  ADD COLUMN IF NOT EXISTS available_models text[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS last_models_sync_at timestamptz;

-- Models suggerits actualitzats
UPDATE data.platform_ai_defaults
SET
  suggested_models = ARRAY['gpt-4o-mini', 'gpt-4o', 'gpt-4.1-mini'],
  default_model = 'gpt-4o-mini',
  updated_at = now()
WHERE provider = 'openai';

UPDATE data.platform_ai_defaults
SET
  suggested_models = ARRAY['claude-sonnet-4-20250514', 'claude-3-5-haiku-latest', 'claude-3-7-sonnet-20250219'],
  default_model = 'claude-3-5-haiku-latest',
  updated_at = now()
WHERE provider = 'anthropic';

UPDATE data.platform_ai_defaults
SET
  suggested_models = ARRAY['gemini-3.5-flash', 'gemini-3.1-flash-lite', 'gemini-3-flash-preview'],
  default_model = 'gemini-3.5-flash',
  updated_at = now()
WHERE provider = 'gemini';

-- ---------------------------------------------------------------------------
-- get_platform_ai_defaults — inclou estat de clau (sense secrets)
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
      'base_url', base_url,
      'has_key', (ai_key_secret_id IS NOT NULL),
      'configured', (ai_key_secret_id IS NOT NULL AND key_verified_at IS NOT NULL),
      'key_verified_at', key_verified_at,
      'key_last_error', key_last_error,
      'available_models', COALESCE(available_models, '{}'::text[]),
      'last_models_sync_at', last_models_sync_at,
      'updated_at', updated_at
    ) ORDER BY provider
  ), '[]'::jsonb)
  INTO v_result
  FROM data.platform_ai_defaults;

  RETURN v_result;
END;
$$;

-- ---------------------------------------------------------------------------
-- save_platform_ai_provider_secret — service_role (Edge després de verificar)
-- ---------------------------------------------------------------------------
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

  IF lower(p_provider) NOT IN ('openai', 'anthropic', 'gemini') THEN
    RAISE EXCEPTION 'Invalid provider';
  END IF;

  v_provider := lower(p_provider)::data.ai_provider;

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

REVOKE ALL ON FUNCTION api.save_platform_ai_provider_secret(text, text, text, text, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.save_platform_ai_provider_secret(text, text, text, text, text[]) FROM authenticated;
REVOKE ALL ON FUNCTION api.save_platform_ai_provider_secret(text, text, text, text, text[]) FROM anon;
GRANT EXECUTE ON FUNCTION api.save_platform_ai_provider_secret(text, text, text, text, text[]) TO service_role;

-- ---------------------------------------------------------------------------
-- delete_platform_ai_provider_key
-- ---------------------------------------------------------------------------
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
  IF lower(p_provider) NOT IN ('openai', 'anthropic', 'gemini') THEN
    RAISE EXCEPTION 'Invalid provider';
  END IF;

  v_provider := lower(p_provider)::data.ai_provider;

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

REVOKE ALL ON FUNCTION api.delete_platform_ai_provider_key(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.delete_platform_ai_provider_key(text) FROM authenticated;
REVOKE ALL ON FUNCTION api.delete_platform_ai_provider_key(text) FROM anon;
GRANT EXECUTE ON FUNCTION api.delete_platform_ai_provider_key(text) TO service_role;

-- ---------------------------------------------------------------------------
-- get_platform_ai_api_key_for_sync — service_role
-- ---------------------------------------------------------------------------
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
  IF lower(p_provider) NOT IN ('openai', 'anthropic', 'gemini') THEN
    RAISE EXCEPTION 'Invalid provider';
  END IF;

  v_provider := lower(p_provider)::data.ai_provider;

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

REVOKE ALL ON FUNCTION api.get_platform_ai_api_key_for_sync(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_platform_ai_api_key_for_sync(text) FROM authenticated;
REVOKE ALL ON FUNCTION api.get_platform_ai_api_key_for_sync(text) FROM anon;
GRANT EXECUTE ON FUNCTION api.get_platform_ai_api_key_for_sync(text) TO service_role;

-- ---------------------------------------------------------------------------
-- persist_platform_ai_provider_models
-- ---------------------------------------------------------------------------
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
  IF lower(p_provider) NOT IN ('openai', 'anthropic', 'gemini') THEN
    RAISE EXCEPTION 'Invalid provider';
  END IF;

  v_provider := lower(p_provider)::data.ai_provider;

  UPDATE data.platform_ai_defaults
  SET
    available_models = COALESCE(p_models, '{}'::text[]),
    last_models_sync_at = now(),
    updated_at = now()
  WHERE provider = v_provider;

  RETURN jsonb_build_object(
    'success', true,
    'provider', v_provider,
    'count', COALESCE(array_length(p_models, 1), 0)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.persist_platform_ai_provider_models(text, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.persist_platform_ai_provider_models(text, text[]) FROM authenticated;
REVOKE ALL ON FUNCTION api.persist_platform_ai_provider_models(text, text[]) FROM anon;
GRANT EXECUTE ON FUNCTION api.persist_platform_ai_provider_models(text, text[]) TO service_role;

-- ---------------------------------------------------------------------------
-- record_platform_ai_key_verification_error
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.record_platform_ai_key_verification_error(
  p_provider text,
  p_error    text
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

  UPDATE data.platform_ai_defaults
  SET key_last_error = left(p_error, 500), updated_at = now()
  WHERE provider = v_provider;
END;
$$;

REVOKE ALL ON FUNCTION api.record_platform_ai_key_verification_error(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.record_platform_ai_key_verification_error(text, text) FROM authenticated;
REVOKE ALL ON FUNCTION api.record_platform_ai_key_verification_error(text, text) FROM anon;
GRANT EXECUTE ON FUNCTION api.record_platform_ai_key_verification_error(text, text) TO service_role;
