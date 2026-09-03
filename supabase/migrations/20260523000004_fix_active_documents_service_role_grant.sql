-- =============================================================================
-- Migració: Grant SELECT on api.active_documents TO service_role
-- =============================================================================
-- Problema: sign-document-router (adminClient = service_role) rep error
--   "permission denied for view active_documents"
--
-- Causa: les migracions documents_core i documents_backend_extras feien
--   GRANT SELECT ON api.active_documents TO authenticated
-- però mai a service_role. PostgREST comprova el grant sobre la vista ABANS
-- d'executar-la, per tant falla amb permission denied.
--
-- La migració 20260523000003 ja va afegir els grants sobre data.documents i
-- data.document_versions (necessaris per security_invoker = true). Aquesta
-- migració afegeix el grant que faltava sobre la vista api.* en si mateixa,
-- seguint el patró de 20260522000001_dms_templates_signing_core.sql (línies 714-719).
-- =============================================================================

GRANT SELECT ON api.active_documents TO service_role;
