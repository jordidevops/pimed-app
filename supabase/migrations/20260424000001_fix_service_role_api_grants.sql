-- =============================================================================
-- Fix: grants de service_role sobre vistes api.* usades per Edge Functions
-- =============================================================================
-- Problema: manage-email-domain usa createAdminClient() (service_role + schema api)
-- però api.email_domains i api.tenant_members no tenien grants per a service_role,
-- causant "permission denied for view email_domains" (HTTP 500).
-- =============================================================================

-- api.email_domains: la funció manage-email-domain necessita SELECT, INSERT,
-- UPDATE i DELETE (INSERT per l'alta d'un domini nou)
GRANT SELECT, INSERT, UPDATE, DELETE ON api.email_domains TO service_role;

-- api.tenant_members: la funció manage-email-domain comprova si l'usuari és
-- owner/manager del tenant del domini (SELECT only)
GRANT SELECT ON api.tenant_members TO service_role;
