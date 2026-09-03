-- =============================================================================
-- Migració: Fix GRANTs de service_role per al mòdul DMS + Signing
-- =============================================================================
-- Problema: api.active_documents té security_invoker = true.
-- Quan sign-document-router (adminClient = service_role) consulta la vista,
-- PostgreSQL executa les consultes a data.documents i data.document_versions
-- com a service_role. Com que no hi havia GRANTs explícits, la query fallava
-- amb permission denied, cosa que l'Edge Function tractava com "source_not_found".
--
-- Solució: afegir SELECT a data.documents i data.document_versions per service_role.
-- Segueix el patró ja establert a 20260522000001_dms_templates_signing_core.sql (línia 513-519).
-- =============================================================================

-- service_role necessita SELECT sobre les taules de documents per poder consultar
-- api.active_documents (security_invoker = true) des de les Edge Functions.
GRANT SELECT ON data.documents          TO service_role;
GRANT SELECT ON data.document_versions  TO service_role;
