-- Fix: update_tenant_ai_provider_meta was called from save-tenant-api-key via
-- service_role (admin client). _assert_ai_manager_access() reads jwt_user_tenants()
-- which is empty without a user JWT → 500 on "Desar {provider}" without new API key.
-- Align with save_tenant_ai_provider_secret: Edge validates auth; RPC is service_role only.

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

REVOKE ALL ON FUNCTION api.update_tenant_ai_provider_meta(uuid, text, text, text, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.update_tenant_ai_provider_meta(uuid, text, text, text, text[]) FROM authenticated;
REVOKE ALL ON FUNCTION api.update_tenant_ai_provider_meta(uuid, text, text, text, text[]) FROM anon;
GRANT EXECUTE ON FUNCTION api.update_tenant_ai_provider_meta(uuid, text, text, text, text[]) TO service_role;

COMMENT ON FUNCTION api.update_tenant_ai_provider_meta IS
  'Actualitza model/base_url d''un proveïdor sense tocar Vault. Només service_role (Edge després d''auth).';
