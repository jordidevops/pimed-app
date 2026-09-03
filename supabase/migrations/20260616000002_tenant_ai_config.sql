-- =============================================================================
-- Tenant AI Config (Fase 6)
-- =============================================================================
-- Objectiu:
--   - Guardar per tenant la configuració d'accés a un LLM (OpenAI/Anthropic)
--   - La API key del tenant s'emmagatzema via Supabase Vault (secret_id opac)
--   - Exposem funcions SECURITY DEFINER per llegir/guardar la config des de:
--       · edge function (generació amb IA)
--       · frontend (settings/ai) amb permisos owner/manager
-- =============================================================================

DO $$ BEGIN
  CREATE TYPE data.ai_provider AS ENUM ('openai', 'anthropic');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ---------------------------------------------------------------------------
-- 1) data.tenant_ai_config
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.tenant_ai_config (
  tenant_id             uuid PRIMARY KEY REFERENCES data.tenants(id) ON DELETE CASCADE,
  provider              data.ai_provider NOT NULL DEFAULT 'openai',
  model                 text NOT NULL DEFAULT 'gpt-4o-mini',
  base_url              text, -- opcional (sobreescriu defaults)
  ai_key_secret_id     uuid,
  is_active             boolean NOT NULL DEFAULT true,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

-- Trigger updated_at (idempotent)
CREATE OR REPLACE FUNCTION data.touch_tenant_ai_config_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tenant_ai_config_updated_at ON data.tenant_ai_config;
CREATE TRIGGER trg_tenant_ai_config_updated_at
  BEFORE UPDATE ON data.tenant_ai_config
  FOR EACH ROW EXECUTE FUNCTION data.touch_tenant_ai_config_updated_at();

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
  END IF;
  RETURN 'https://api.openai.com/v1';
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
  v_row       data.tenant_ai_config%ROWTYPE;
  v_configured boolean := false;
  v_base_url  text;
BEGIN
  -- Owner/manager
  IF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'Access denied: owner or manager role required';
  END IF;

  SELECT * INTO v_row
  FROM data.tenant_ai_config
  WHERE tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'configured', false,
      'provider', 'openai',
      'model', 'gpt-4o-mini',
      'base_url', api.ai_provider_default_base_url('openai'::data.ai_provider)
    );
  END IF;

  v_configured := (v_row.ai_key_secret_id IS NOT NULL) AND v_row.is_active;
  v_base_url := COALESCE(v_row.base_url, api.ai_provider_default_base_url(v_row.provider));

  RETURN jsonb_build_object(
    'configured', v_configured,
    'provider',    v_row.provider,
    'model',       v_row.model,
    'base_url',    v_base_url
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_ai_config_for_tenant TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_ai_config_for_tenant TO service_role;

-- ---------------------------------------------------------------------------
-- 3) api.save_tenant_ai_config
-- ---------------------------------------------------------------------------
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
DECLARE
  v_provider       data.ai_provider;
  v_existing       data.tenant_ai_config%ROWTYPE;
  v_secret_id      uuid;
  v_secret_name    text;
  v_secret_desc    text;
  v_model          text;
  v_base_url       text;
BEGIN
  -- Owner/manager
  IF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'Access denied: owner or manager role required';
  END IF;

  IF p_provider IS NULL THEN
    RAISE EXCEPTION 'provider is required';
  END IF;

  IF lower(p_provider) NOT IN ('openai', 'anthropic') THEN
    RAISE EXCEPTION 'Invalid provider. Must be openai or anthropic';
  END IF;

  v_provider := lower(p_provider)::data.ai_provider;

  IF p_api_key IS NULL OR trim(p_api_key) = '' THEN
    RAISE EXCEPTION 'API key is required';
  END IF;

  v_model := COALESCE(nullif(trim(p_model), ''), 'gpt-4o-mini');
  v_base_url := COALESCE(nullif(trim(p_base_url), ''), api.ai_provider_default_base_url(v_provider));

  v_secret_name := 'ai_' || v_provider::text || '_' || replace(p_tenant_id::text, '-', '');
  v_secret_desc := 'AI API key (' || v_provider::text || ') for tenant ' || p_tenant_id::text;

  SELECT * INTO v_existing
  FROM data.tenant_ai_config
  WHERE tenant_id = p_tenant_id;

  IF FOUND THEN
    IF v_existing.ai_key_secret_id IS NOT NULL THEN
      PERFORM vault.update_secret(v_existing.ai_key_secret_id, p_api_key, v_secret_name, v_secret_desc);
      v_secret_id := v_existing.ai_key_secret_id;
    ELSE
      v_secret_id := vault.create_secret(p_api_key, v_secret_name, v_secret_desc);
    END IF;

    UPDATE data.tenant_ai_config
    SET provider          = v_provider,
        model             = v_model,
        base_url          = v_base_url,
        ai_key_secret_id = v_secret_id,
        is_active         = true
    WHERE tenant_id = p_tenant_id;
  ELSE
    v_secret_id := vault.create_secret(p_api_key, v_secret_name, v_secret_desc);
    INSERT INTO data.tenant_ai_config (
      tenant_id, provider, model, base_url, ai_key_secret_id, is_active
    ) VALUES (
      p_tenant_id, v_provider, v_model, v_base_url, v_secret_id, true
    );
  END IF;

  RETURN jsonb_build_object('success', true, 'configured', true, 'provider', v_provider, 'model', v_model);
END;
$$;

GRANT EXECUTE ON FUNCTION api.save_tenant_ai_config TO authenticated;
GRANT EXECUTE ON FUNCTION api.save_tenant_ai_config TO service_role;

-- ---------------------------------------------------------------------------
-- 4) api.get_ai_api_key_for_generation (per edge function)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_ai_api_key_for_generation(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_row        data.tenant_ai_config%ROWTYPE;
  v_api_key    text;
  v_base_url   text;
BEGIN
  IF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'Access denied: owner or manager role required';
  END IF;

  SELECT * INTO v_row
  FROM data.tenant_ai_config
  WHERE tenant_id = p_tenant_id;

  IF NOT FOUND OR v_row.is_active IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'No AI config enabled for tenant %', p_tenant_id;
  END IF;

  IF v_row.ai_key_secret_id IS NULL THEN
    RAISE EXCEPTION 'No AI API key configured for tenant %', p_tenant_id;
  END IF;

  SELECT decrypted_secret
  INTO v_api_key
  FROM vault.decrypted_secrets
  WHERE id = v_row.ai_key_secret_id;

  IF v_api_key IS NULL THEN
    RAISE EXCEPTION 'AI API key not found in vault for tenant %', p_tenant_id;
  END IF;

  v_base_url := COALESCE(v_row.base_url, api.ai_provider_default_base_url(v_row.provider));

  RETURN jsonb_build_object(
    'provider',  v_row.provider,
    'model',     v_row.model,
    'base_url',  v_base_url,
    'api_key',   v_api_key
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_ai_api_key_for_generation TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_ai_api_key_for_generation TO service_role;

