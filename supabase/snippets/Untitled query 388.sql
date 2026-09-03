-- 1. Donem permís al Worker per interactuar amb les vistes d'Email
GRANT ALL ON api.email_logs TO service_role;
GRANT ALL ON api.email_configs TO service_role;
GRANT ALL ON api.email_templates TO service_role;
GRANT ALL ON api.email_domains TO service_role;

-- 2. Creem la vista per a la configuració global (system_settings)
CREATE OR REPLACE VIEW api.system_settings 
  WITH (security_invoker = true) AS 
  SELECT * FROM data.system_settings;

-- 3. Donem permís al Worker i a l'Admin per llegir/editar la configuració
GRANT ALL ON api.system_settings TO service_role, prisma_admin;