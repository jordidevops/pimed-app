-- Gemini default: gemini-3.6-flash (substitueix 2.0 / 3.5 com a model de treball)

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
    RETURN 'gemini-3.6-flash';
  ELSIF p_provider = 'openrouter' THEN
    RETURN 'openai/gpt-4o-mini';
  END IF;
  RETURN 'gpt-4o-mini';
END;
$$;

UPDATE data.platform_ai_defaults
SET
  suggested_models = ARRAY[
    'gemini-3.6-flash',
    'gemini-3.5-flash',
    'gemini-3.1-flash-lite',
    'gemini-3-flash-preview'
  ],
  default_model = 'gemini-3.6-flash',
  updated_at = now()
WHERE provider = 'gemini';
