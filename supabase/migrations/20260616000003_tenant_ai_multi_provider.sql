-- =============================================================================
-- Tenant AI Config — multi-provider (OpenAI, Anthropic, Gemini)
-- =============================================================================

DO $$ BEGIN
  ALTER TYPE data.ai_provider ADD VALUE IF NOT EXISTS 'gemini';
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ---------------------------------------------------------------------------
-- 1) Per-provider credentials
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.tenant_ai_provider_config (
  tenant_id          uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  provider           data.ai_provider NOT NULL,
  model              text NOT NULL,
  base_url           text,
  ai_key_secret_id   uuid,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, provider)
);

CREATE OR REPLACE FUNCTION data.touch_tenant_ai_provider_config_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tenant_ai_provider_config_updated_at ON data.tenant_ai_provider_config;
CREATE TRIGGER trg_tenant_ai_provider_config_updated_at
  BEFORE UPDATE ON data.tenant_ai_provider_config
  FOR EACH ROW EXECUTE FUNCTION data.touch_tenant_ai_provider_config_updated_at();

-- Migrate legacy single-provider columns (if present)
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'data'
      AND table_name = 'tenant_ai_config'
      AND column_name = 'ai_key_secret_id'
  ) THEN
    INSERT INTO data.tenant_ai_provider_config (tenant_id, provider, model, base_url, ai_key_secret_id)
    SELECT tenant_id, provider, model, base_url, ai_key_secret_id
    FROM data.tenant_ai_config
    WHERE ai_key_secret_id IS NOT NULL
    ON CONFLICT (tenant_id, provider) DO UPDATE
      SET model = EXCLUDED.model,
          base_url = EXCLUDED.base_url,
          ai_key_secret_id = EXCLUDED.ai_key_secret_id;
  END IF;
END $$;

ALTER TABLE data.tenant_ai_config
  ADD COLUMN IF NOT EXISTS default_provider data.ai_provider NOT NULL DEFAULT 'openai';

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'data'
      AND table_name = 'tenant_ai_config'
      AND column_name = 'provider'
  ) THEN
    UPDATE data.tenant_ai_config
    SET default_provider = provider
    WHERE default_provider IS DISTINCT FROM provider;
  END IF;
END $$;

ALTER TABLE data.tenant_ai_config
  DROP COLUMN IF EXISTS provider,
  DROP COLUMN IF EXISTS model,
  DROP COLUMN IF EXISTS base_url,
  DROP COLUMN IF EXISTS ai_key_secret_id;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
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
  END IF;
  RETURN 'gpt-4o-mini';
END;
$$;

CREATE OR REPLACE FUNCTION api._assert_ai_manager_access(p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'Access denied: owner or manager role required';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2) api.get_ai_config_for_tenant
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
        'configured', (v_cfg.ai_key_secret_id IS NOT NULL),
        'model', COALESCE(v_cfg.model, api.ai_provider_default_model(v_provider)),
        'base_url', COALESCE(v_cfg.base_url, api.ai_provider_default_base_url(v_provider))
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'default_provider', v_default,
    'is_active', COALESCE(v_row.is_active, true),
    'providers', v_providers,
    'configured', EXISTS (
      SELECT 1
      FROM data.tenant_ai_provider_config pc
      JOIN data.tenant_ai_config tc ON tc.tenant_id = pc.tenant_id
      WHERE pc.tenant_id = p_tenant_id
        AND pc.provider = tc.default_provider
        AND pc.ai_key_secret_id IS NOT NULL
        AND tc.is_active IS DISTINCT FROM false
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_ai_config_for_tenant TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_ai_config_for_tenant TO service_role;

-- ---------------------------------------------------------------------------
-- 3) api.save_tenant_ai_provider_config
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.save_tenant_ai_provider_config(
  p_tenant_id uuid,
  p_provider  text,
  p_api_key   text DEFAULT NULL,
  p_model     text DEFAULT NULL,
  p_base_url  text DEFAULT NULL
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
  PERFORM api._assert_ai_manager_access(p_tenant_id);

  IF p_provider IS NULL THEN
    RAISE EXCEPTION 'provider is required';
  END IF;

  IF lower(p_provider) NOT IN ('openai', 'anthropic', 'gemini') THEN
    RAISE EXCEPTION 'Invalid provider. Must be openai, anthropic or gemini';
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

  IF p_api_key IS NULL OR trim(p_api_key) = '' THEN
    IF NOT FOUND OR v_existing.ai_key_secret_id IS NULL THEN
      RAISE EXCEPTION 'API key is required';
    END IF;

    UPDATE data.tenant_ai_provider_config
    SET model = v_model,
        base_url = v_base_url
    WHERE tenant_id = p_tenant_id
      AND provider = v_provider;

    RETURN jsonb_build_object(
      'success', true,
      'provider', v_provider,
      'configured', true,
      'model', v_model
    );
  END IF;

  IF FOUND THEN
    IF v_existing.ai_key_secret_id IS NOT NULL THEN
      PERFORM vault.update_secret(v_existing.ai_key_secret_id, p_api_key, v_secret_name, v_secret_desc);
      v_secret_id := v_existing.ai_key_secret_id;
    ELSE
      v_secret_id := vault.create_secret(p_api_key, v_secret_name, v_secret_desc);
    END IF;

    INSERT INTO data.tenant_ai_provider_config (
      tenant_id, provider, model, base_url, ai_key_secret_id
    ) VALUES (
      p_tenant_id, v_provider, v_model, v_base_url, v_secret_id
    )
    ON CONFLICT (tenant_id, provider) DO UPDATE
      SET model = EXCLUDED.model,
          base_url = EXCLUDED.base_url,
          ai_key_secret_id = EXCLUDED.ai_key_secret_id;
  ELSE
    v_secret_id := vault.create_secret(p_api_key, v_secret_name, v_secret_desc);
    INSERT INTO data.tenant_ai_provider_config (
      tenant_id, provider, model, base_url, ai_key_secret_id
    ) VALUES (
      p_tenant_id, v_provider, v_model, v_base_url, v_secret_id
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'provider', v_provider,
    'configured', true,
    'model', v_model
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.save_tenant_ai_provider_config TO authenticated;
GRANT EXECUTE ON FUNCTION api.save_tenant_ai_provider_config TO service_role;

-- Backward-compatible alias
CREATE OR REPLACE FUNCTION api.save_tenant_ai_config(
  p_tenant_id uuid,
  p_provider  text,
  p_api_key   text,
  p_model     text DEFAULT NULL,
  p_base_url  text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
BEGIN
  RETURN api.save_tenant_ai_provider_config(
    p_tenant_id, p_provider, p_api_key, p_model, p_base_url
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.save_tenant_ai_config TO authenticated;
GRANT EXECUTE ON FUNCTION api.save_tenant_ai_config TO service_role;

-- ---------------------------------------------------------------------------
-- 4) api.set_tenant_ai_default_provider
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

  IF p_provider IS NULL THEN
    RAISE EXCEPTION 'provider is required';
  END IF;

  IF lower(p_provider) NOT IN ('openai', 'anthropic', 'gemini') THEN
    RAISE EXCEPTION 'Invalid provider. Must be openai, anthropic or gemini';
  END IF;

  v_provider := lower(p_provider)::data.ai_provider;

  INSERT INTO data.tenant_ai_config (tenant_id, default_provider, is_active)
  VALUES (p_tenant_id, v_provider, true)
  ON CONFLICT (tenant_id) DO UPDATE
    SET default_provider = EXCLUDED.default_provider;

  RETURN jsonb_build_object('success', true, 'default_provider', v_provider);
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_tenant_ai_default_provider TO authenticated;
GRANT EXECUTE ON FUNCTION api.set_tenant_ai_default_provider TO service_role;

-- ---------------------------------------------------------------------------
-- 5) api.get_ai_api_key_for_generation
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_ai_api_key_for_generation(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_settings     data.tenant_ai_config%ROWTYPE;
  v_provider_cfg data.tenant_ai_provider_config%ROWTYPE;
  v_api_key      text;
  v_base_url     text;
BEGIN
  PERFORM api._assert_ai_manager_access(p_tenant_id);

  SELECT * INTO v_settings
  FROM data.tenant_ai_config
  WHERE tenant_id = p_tenant_id;

  IF NOT FOUND OR v_settings.is_active IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'No AI config enabled for tenant %', p_tenant_id;
  END IF;

  SELECT * INTO v_provider_cfg
  FROM data.tenant_ai_provider_config
  WHERE tenant_id = p_tenant_id
    AND provider = v_settings.default_provider;

  IF NOT FOUND OR v_provider_cfg.ai_key_secret_id IS NULL THEN
    RAISE EXCEPTION 'No AI API key configured for default provider % (tenant %)',
      v_settings.default_provider, p_tenant_id;
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
    'api_key',   v_api_key
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_ai_api_key_for_generation TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_ai_api_key_for_generation TO service_role;
