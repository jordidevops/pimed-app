-- =============================================================================
-- Migració: 20260528000002
-- Propòsit: Corregir accés des d'Edge Functions a taules del schema data.
--
-- Problema arrel:
--   El schema "data" NO és a la llista "schemas" de PostgREST (config.toml: schemas=["api"]).
--   Qualsevol crida via supabase-js amb schema:"data" (createAdminDataClient()) falla amb
--   "Invalid schema: data". Afecta: feature flags, signing_submissions (INSERT), sites, tenants.
--
-- Solució:
--   1. api.is_tenant_feature_enabled(uuid, text)    — wrapper RPC SECURITY DEFINER
--   2. api.tenants                                  — vista mínima per a template variables
--   3. api.create_signing_submission(...)           — RPC SECURITY DEFINER per INSERT segur
--   Tots accessibles per service_role (Edge Functions); invisible per authenticated/anon.
-- =============================================================================


-- ============================================================================
-- 1. api.is_tenant_feature_enabled — wrapper de data.is_feature_enabled
--    Permet als workers consultar feature flags sense exposar data.* a PostgREST.
-- ============================================================================
CREATE OR REPLACE FUNCTION api.is_tenant_feature_enabled(
  p_tenant_id   uuid,
  p_feature_key text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT data.is_feature_enabled(p_tenant_id, p_feature_key);
$$;

REVOKE ALL    ON FUNCTION api.is_tenant_feature_enabled(uuid, text) FROM PUBLIC;
REVOKE ALL    ON FUNCTION api.is_tenant_feature_enabled(uuid, text) FROM authenticated;
REVOKE ALL    ON FUNCTION api.is_tenant_feature_enabled(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION api.is_tenant_feature_enabled(uuid, text) TO service_role;

COMMENT ON FUNCTION api.is_tenant_feature_enabled(uuid, text) IS
  'Wrapper SECURITY DEFINER per a Edge Functions: comprova si una feature flag és activa per a un tenant.
   Delega a data.is_feature_enabled. Accessible únicament per service_role.';


-- ============================================================================
-- 2. api.tenants — vista mínima per a resolució de variables de plantilles
--    Usat per fetchEntityForContext (sign-document-router) per entity_type=tenant.
--    security_invoker=true → service_role bypassa RLS de data.tenants.
-- ============================================================================
CREATE OR REPLACE VIEW api.tenants
  WITH (security_invoker = true) AS
  SELECT
    t.id,
    t.name,
    t.slug,
    t.is_active,
    t.metadata,
    t.created_at,
    t.updated_at
  FROM data.tenants t;

-- Accessible només per service_role (no s'exposa a usuaris finals del portal).
REVOKE ALL   ON api.tenants FROM PUBLIC;
REVOKE ALL   ON api.tenants FROM anon;
REVOKE ALL   ON api.tenants FROM authenticated;
GRANT SELECT ON api.tenants TO service_role;

COMMENT ON VIEW api.tenants IS
  'Vista mínima de tenants per a ús intern de Edge Functions (resolució de variables de plantilles).
   No accessible per usuaris authenticated/anon.';


-- ============================================================================
-- 3. api.create_signing_submission — INSERT segur a data.signing_submissions
--    Permet als workers crear submissions sense accés directe a schema data.
--    Retorna l id de la nova submission.
-- ============================================================================
CREATE OR REPLACE FUNCTION api.create_signing_submission(
  p_tenant_id                   uuid,
  p_source_type                 text,
  p_source_document_id          uuid,
  p_source_document_version_id  uuid,
  p_source_template_locale_id   uuid,
  p_document_title              text,
  p_external_id                 text,
  p_signers                     jsonb,
  p_initiated_by                uuid,
  p_submitted_at                timestamptz DEFAULT NULL,
  p_metadata                    jsonb       DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO data.signing_submissions (
    tenant_id,
    source_type,
    source_document_id,
    source_document_version_id,
    source_template_locale_id,
    document_title,
    status,
    external_id,
    signers,
    initiated_by,
    submitted_at,
    metadata
  )
  VALUES (
    p_tenant_id,
    p_source_type::data.signing_source_type,
    p_source_document_id,
    p_source_document_version_id,
    p_source_template_locale_id,
    p_document_title,
    'pending'::data.signing_submission_status,
    p_external_id,
    p_signers,
    p_initiated_by,
    COALESCE(p_submitted_at, now()),
    p_metadata
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL    ON FUNCTION api.create_signing_submission(uuid, text, uuid, uuid, uuid, text, text, jsonb, uuid, timestamptz, jsonb) FROM PUBLIC;
REVOKE ALL    ON FUNCTION api.create_signing_submission(uuid, text, uuid, uuid, uuid, text, text, jsonb, uuid, timestamptz, jsonb) FROM authenticated;
REVOKE ALL    ON FUNCTION api.create_signing_submission(uuid, text, uuid, uuid, uuid, text, text, jsonb, uuid, timestamptz, jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION api.create_signing_submission(uuid, text, uuid, uuid, uuid, text, text, jsonb, uuid, timestamptz, jsonb) TO service_role;

COMMENT ON FUNCTION api.create_signing_submission(uuid, text, uuid, uuid, uuid, text, text, jsonb, uuid, timestamptz, jsonb) IS
  'Crea una signing_submission a data.signing_submissions. SECURITY DEFINER, service_role only.
   Accessible per Edge Functions sense necessitat d accés directe al schema data.';
