-- M2a: Registre de capacitats per model (vision, tools, streaming, …)

CREATE TABLE IF NOT EXISTS data.ai_model_capabilities (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider              data.ai_provider NOT NULL,
  model_id              text NOT NULL,
  vision                boolean NOT NULL DEFAULT false,
  tools                 boolean NOT NULL DEFAULT true,
  tools_with_vision     boolean NOT NULL DEFAULT false,
  streaming             boolean NOT NULL DEFAULT true,
  max_image_size_mb     integer NOT NULL DEFAULT 5,
  supported_image_mimes text[] NOT NULL DEFAULT ARRAY['image/jpeg', 'image/png', 'image/webp'],
  context_window        integer,
  deprecated_at         timestamptz,
  needs_review          boolean NOT NULL DEFAULT false,
  source                text NOT NULL DEFAULT 'platform',
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ai_model_capabilities_provider_model_unique UNIQUE (provider, model_id)
);

CREATE INDEX IF NOT EXISTS idx_ai_model_capabilities_provider
  ON data.ai_model_capabilities (provider)
  WHERE deprecated_at IS NULL;

COMMENT ON TABLE data.ai_model_capabilities IS
  'Metadata de capacitats per model IA (plataforma). Consultat pel xat per validar adjunts i badges UI.';

-- ---------------------------------------------------------------------------
-- Seed — models coneguts (2026-06)
-- ---------------------------------------------------------------------------
INSERT INTO data.ai_model_capabilities (
  provider, model_id, vision, tools, tools_with_vision, streaming, context_window
) VALUES
  -- OpenAI
  ('openai', 'gpt-4o', true, true, true, true, 128000),
  ('openai', 'gpt-4o-mini', true, true, true, true, 128000),
  ('openai', 'gpt-4.1', true, true, true, true, 1047576),
  ('openai', 'gpt-4.1-mini', true, true, true, true, 1047576),
  ('openai', 'gpt-4.1-nano', true, true, true, true, 1047576),
  ('openai', 'o4-mini', true, true, true, true, 200000),
  -- Gemini (IDs API)
  ('gemini', 'gemini-2.0-flash', true, true, true, true, 1048576),
  ('gemini', 'gemini-2.5-flash', true, true, true, true, 1048576),
  ('gemini', 'gemini-2.5-pro', true, true, true, true, 1048576),
  ('gemini', 'gemini-1.5-flash', true, true, true, true, 1048576),
  ('gemini', 'gemini-1.5-pro', true, true, true, true, 2097152),
  -- Anthropic (vision sí; tools al xat encara no al loop)
  ('anthropic', 'claude-sonnet-4-20250514', true, false, false, true, 200000),
  ('anthropic', 'claude-3-5-sonnet-latest', true, false, false, true, 200000),
  ('anthropic', 'claude-3-5-haiku-latest', true, false, false, true, 200000),
  ('anthropic', 'claude-3-opus-latest', true, false, false, true, 200000),
  -- OpenRouter (IDs complets openrouter/model)
  ('openrouter', 'openai/gpt-4o', true, true, true, true, 128000),
  ('openrouter', 'openai/gpt-4o-mini', true, true, true, true, 128000),
  ('openrouter', 'openai/gpt-4.1-mini', true, true, true, true, 1047576),
  ('openrouter', 'google/gemini-2.5-flash', true, true, true, true, 1048576),
  ('openrouter', 'google/gemini-2.0-flash', true, true, true, true, 1048576),
  ('openrouter', 'anthropic/claude-sonnet-4', true, true, true, true, 200000),
  ('openrouter', 'anthropic/claude-3.5-haiku', true, true, true, true, 200000)
ON CONFLICT (provider, model_id) DO UPDATE SET
  vision = EXCLUDED.vision,
  tools = EXCLUDED.tools,
  tools_with_vision = EXCLUDED.tools_with_vision,
  streaming = EXCLUDED.streaming,
  context_window = EXCLUDED.context_window,
  updated_at = now();

-- ---------------------------------------------------------------------------
-- Llista per al portal (membres actius del tenant)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_ai_model_capabilities(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.tenant_members
    WHERE tenant_id = p_tenant_id
      AND user_id = auth.uid()
      AND is_active = true
  ) THEN
    RAISE EXCEPTION 'Access denied: not a tenant member';
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(row_data ORDER BY provider, model_id)
    FROM (
      SELECT jsonb_build_object(
        'provider', c.provider,
        'model_id', c.model_id,
        'vision', c.vision,
        'tools', c.tools,
        'tools_with_vision', c.tools_with_vision,
        'streaming', c.streaming,
        'max_image_size_mb', c.max_image_size_mb,
        'supported_image_mimes', c.supported_image_mimes,
        'context_window', c.context_window,
        'deprecated_at', c.deprecated_at,
        'needs_review', c.needs_review
      ) AS row_data,
      c.provider,
      c.model_id
      FROM data.ai_model_capabilities c
      WHERE c.deprecated_at IS NULL
    ) sub
  ), '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_ai_model_capabilities(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- Resolució per Edge (service_role)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.resolve_ai_model_capabilities_service(
  p_tenant_id uuid,
  p_provider  data.ai_provider,
  p_model_id  text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row   data.ai_model_capabilities%ROWTYPE;
  v_model text := nullif(trim(p_model_id), '');
  v_inner text;
  v_map   data.ai_provider;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF v_model IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_row
  FROM data.ai_model_capabilities c
  WHERE c.provider = p_provider
    AND c.model_id = v_model
    AND c.deprecated_at IS NULL;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'provider', v_row.provider,
      'model_id', v_row.model_id,
      'vision', v_row.vision,
      'tools', v_row.tools,
      'tools_with_vision', v_row.tools_with_vision,
      'streaming', v_row.streaming,
      'max_image_size_mb', v_row.max_image_size_mb,
      'supported_image_mimes', v_row.supported_image_mimes,
      'context_window', v_row.context_window,
      'source', 'registry'
    );
  END IF;

  -- OpenRouter: provar model intern (openai/gpt-4o → openai + gpt-4o)
  IF p_provider = 'openrouter'::data.ai_provider AND position('/' IN v_model) > 0 THEN
    v_inner := split_part(v_model, '/', 2);
    v_map := CASE lower(split_part(v_model, '/', 1))
      WHEN 'google' THEN 'gemini'::data.ai_provider
      WHEN 'anthropic' THEN 'anthropic'::data.ai_provider
      WHEN 'openai' THEN 'openai'::data.ai_provider
      ELSE NULL
    END;

    IF v_map IS NOT NULL AND v_inner <> '' THEN
      SELECT * INTO v_row
      FROM data.ai_model_capabilities c
      WHERE c.provider = v_map
        AND c.model_id = v_inner
        AND c.deprecated_at IS NULL;

      IF FOUND THEN
        RETURN jsonb_build_object(
          'provider', p_provider,
          'model_id', v_model,
          'vision', v_row.vision,
          'tools', v_row.tools,
          'tools_with_vision', v_row.tools_with_vision,
          'streaming', v_row.streaming,
          'max_image_size_mb', v_row.max_image_size_mb,
          'supported_image_mimes', v_row.supported_image_mimes,
          'context_window', v_row.context_window,
          'source', 'registry_alias'
        );
      END IF;
    END IF;
  END IF;

  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION api.resolve_ai_model_capabilities_service(uuid, data.ai_provider, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.resolve_ai_model_capabilities_service(uuid, data.ai_provider, text) TO service_role;
