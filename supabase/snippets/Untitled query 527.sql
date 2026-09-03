-- 1. Donem permís explícit d'ús de l'esquema al Worker
GRANT USAGE ON SCHEMA data TO service_role;

-- 2. Sobreescrivim la vista SENSE "security_invoker = true".
-- Això fa que s'executi com a "Superusuari" intern i cap trigger doni error.
CREATE OR REPLACE VIEW api.worker_email_logs AS 
  SELECT * FROM data.email_logs;

-- 3. Assegurem que només el Worker la pot fer servir
REVOKE ALL ON api.worker_email_logs FROM PUBLIC;
REVOKE ALL ON api.worker_email_logs FROM authenticated;
REVOKE ALL ON api.worker_email_logs FROM anon;
GRANT ALL ON api.worker_email_logs TO service_role;