-- Fase B: models suggerits OpenRouter (ús general, no només documents)

UPDATE data.platform_ai_defaults
SET
  suggested_models = ARRAY[
    'openai/gpt-4o-mini',
    'openai/gpt-4o',
    'openai/gpt-4.1-mini',
    'anthropic/claude-sonnet-4',
    'anthropic/claude-3.5-haiku',
    'google/gemini-2.5-flash',
    'google/gemini-2.0-flash',
    'meta-llama/llama-3.3-70b-instruct',
    'mistralai/mistral-small-3.1-24b-instruct'
  ],
  updated_at = now()
WHERE provider = 'openrouter';
