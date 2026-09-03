-- =============================================================================
-- Migration: 20260602000002_fix_role_defaults_and_system_settings_security.sql
-- Purpose:
--   1) Fix 403 on api.tenant_role_defaults (security_invoker view over data table)
--   2) Remove SECURITY DEFINER behavior from api.system_settings view
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) tenant_role_defaults grants for security_invoker access
-- -----------------------------------------------------------------------------
-- api.tenant_role_defaults is defined with security_invoker=true, so caller
-- privileges on data.tenant_role_defaults are required in addition to RLS.
GRANT USAGE ON SCHEMA data TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.tenant_role_defaults TO authenticated;

-- -----------------------------------------------------------------------------
-- 2) Harden api.system_settings view (avoid SECURITY DEFINER view in exposed api)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.system_settings
WITH (security_invoker = true)
AS
SELECT *
FROM data.system_settings;

REVOKE ALL ON api.system_settings FROM PUBLIC;
GRANT SELECT ON api.system_settings TO anon, authenticated;
GRANT ALL ON api.system_settings TO service_role;
