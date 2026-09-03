-- Creem una vista a l'esquema 'api' amb TOTES les columnes de data.email_logs
CREATE OR REPLACE VIEW api.worker_email_logs 
  WITH (security_invoker = true) AS 
  SELECT * FROM data.email_logs;

-- Revoquem permisos a tothom (Frontend, usuaris anònims, etc.)
REVOKE ALL ON api.worker_email_logs FROM PUBLIC;
REVOKE ALL ON api.worker_email_logs FROM authenticated;
REVOKE ALL ON api.worker_email_logs FROM anon;

-- Donem permís exclusiu al Worker (service_role)
GRANT ALL ON api.worker_email_logs TO service_role;