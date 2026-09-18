-- AI composer: restore provider/platform prompt COALESCE, UUID-free RAISES,
-- and platform feature instructions (editable without republishing the app).

-- ---------------------------------------------------------------------------
-- get_ai_api_key_for_generation — vault path (20260725) + COALESCE (20260625)
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
      v_provider_cfg.system_prompt,
      v_platform.system_prompt,
      v_settings.system_prompt
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

-- ---------------------------------------------------------------------------
-- Feature-level JSON instructions (composer tasks). Not the chat tools appendix.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.platform_ai_feature_prompts (
  feature       text PRIMARY KEY,
  title         text NOT NULL,
  instructions  text NOT NULL,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT platform_ai_feature_prompts_feature_chk
    CHECK (feature ~ '^[a-z][a-z0-9_.]*$'),
  CONSTRAINT platform_ai_feature_prompts_instructions_chk
    CHECK (length(trim(instructions)) > 0)
);

ALTER TABLE data.platform_ai_feature_prompts ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE data.platform_ai_feature_prompts FROM PUBLIC;
REVOKE ALL ON TABLE data.platform_ai_feature_prompts FROM anon;
REVOKE ALL ON TABLE data.platform_ai_feature_prompts FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE data.platform_ai_feature_prompts TO service_role;

INSERT INTO data.platform_ai_feature_prompts (feature, title, instructions)
VALUES
  (
    'commercial.price_sheet',
    'Compositor de full de preus',
    $seed$Retorna NOMÉS JSON amb { "mode": "append"|"replace", "lines": [{ "catalog_item_id": uuid|null, "name": string, "kind": "service"|"product", "quantity": number, "unit": string, "unit_price": number, "discount_pct": number, "tax_rate": number }], "checklist_name": string|null }. Usa catalog_item_id només si és un UUID de la llista. No inventis UUIDs. No posis preu 0 a línies lliures.$seed$
  ),
  (
    'catalog.pricing_template',
    'Servei habitual',
    $seed$Retorna NOMÉS JSON { "name": string, "description": string, "category": string, "lines": [{ "catalog_item_id": uuid|null, "name": string, "quantity": number }], "checklist_names": string[] }. catalog_item_id només si és un UUID de la llista. No inventis UUIDs.$seed$
  ),
  (
    'field.checklist_template',
    'Plantilla de checklist',
    $seed$Retorna NOMÉS JSON { "name": string, "kind": "todo"|"review", "items": [{ "title": string, "required": boolean, "response_type": "checkbox"|"single_choice" }] }. No incloguis review_point_id. Prefereix kind=todo i response_type=checkbox. No marquis la plantilla com a publicada.$seed$
  )
ON CONFLICT (feature) DO NOTHING;

CREATE OR REPLACE FUNCTION api.get_platform_ai_feature_prompts()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'feature', feature,
      'title', title,
      'instructions', instructions,
      'updated_at', updated_at
    ) ORDER BY feature
  ), '[]'::jsonb)
  INTO v_result
  FROM data.platform_ai_feature_prompts;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION api.get_platform_ai_feature_prompt(p_feature text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_instructions text;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT instructions INTO v_instructions
  FROM data.platform_ai_feature_prompts
  WHERE feature = p_feature;

  RETURN v_instructions;
END;
$$;

CREATE OR REPLACE FUNCTION api.upsert_platform_ai_feature_prompt(
  p_feature       text,
  p_title         text,
  p_instructions  text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_feature IS NULL OR p_feature !~ '^[a-z][a-z0-9_.]*$' THEN
    RAISE EXCEPTION 'invalid_feature';
  END IF;

  IF p_title IS NULL OR length(trim(p_title)) = 0 THEN
    RAISE EXCEPTION 'title_required';
  END IF;

  IF p_instructions IS NULL OR length(trim(p_instructions)) = 0 THEN
    RAISE EXCEPTION 'instructions_required';
  END IF;

  INSERT INTO data.platform_ai_feature_prompts (
    feature, title, instructions, updated_at
  ) VALUES (
    p_feature, trim(p_title), trim(p_instructions), now()
  )
  ON CONFLICT (feature) DO UPDATE
    SET title = EXCLUDED.title,
        instructions = EXCLUDED.instructions,
        updated_at = now();

  RETURN jsonb_build_object('success', true, 'feature', p_feature);
END;
$$;

REVOKE ALL ON FUNCTION api.get_platform_ai_feature_prompts() FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_platform_ai_feature_prompts() FROM authenticated;
REVOKE ALL ON FUNCTION api.get_platform_ai_feature_prompts() FROM anon;
GRANT EXECUTE ON FUNCTION api.get_platform_ai_feature_prompts() TO service_role;

REVOKE ALL ON FUNCTION api.get_platform_ai_feature_prompt(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_platform_ai_feature_prompt(text) FROM authenticated;
REVOKE ALL ON FUNCTION api.get_platform_ai_feature_prompt(text) FROM anon;
GRANT EXECUTE ON FUNCTION api.get_platform_ai_feature_prompt(text) TO service_role;

REVOKE ALL ON FUNCTION api.upsert_platform_ai_feature_prompt(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.upsert_platform_ai_feature_prompt(text, text, text) FROM authenticated;
REVOKE ALL ON FUNCTION api.upsert_platform_ai_feature_prompt(text, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION api.upsert_platform_ai_feature_prompt(text, text, text) TO service_role;
