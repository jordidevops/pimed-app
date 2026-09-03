-- Bump tenants still on older Gemini Flash defaults to 3.6 (platform ja és 3.6).
-- No cal re-seed: només actualitza model desat al tenant si encara era 2.0 / 3.5.

UPDATE data.tenant_ai_provider_config
SET
  model = 'gemini-3.6-flash',
  updated_at = now()
WHERE provider = 'gemini'
  AND model IN ('gemini-2.0-flash', 'gemini-3.5-flash');
