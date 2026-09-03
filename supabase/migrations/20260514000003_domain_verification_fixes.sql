-- =============================================================================
-- Migration: 20260514000003_domain_verification_fixes.sql
-- Sprint 4 QA fixes
--
-- Corregeix tres problemes detectats en la revisió de Sprint 4:
--
--   1. ADD COLUMN data.public_domains.check_count (int, default 0)
--      Necessari per al worker per comptar intents i transicionar a 'failed'
--      quan s'exhaureix el límit d'intents. Sense aquest camp el worker mai
--      podia marcar un domini com a 'failed' (lifecycle incomplet).
--
--   2. UPDATE api.resolve_domain_for_portal
--      Restricció: acceptava 'dns_verified' i 'ssl_active'. Ara només 'ssl_active'.
--      Motiu: un domini 'dns_verified' NO té SSL actiu; servir contingut via
--      HTTPS en un domini sense certificat vàlid és incorrecte (criteris d'Sprint 4:
--      "SSL actiu i navegació segura en domini propi").
--
-- Dependències:
--   · data.public_domains           (20260513000001_public_portal_core.sql)
--   · api.portal_site_row           (20260514000002_public_portal_portal_rpcs.sql)
--   · data.public_portal_enabled_for_tenant() (20260513000002_public_portal_rls.sql)
-- =============================================================================


-- =============================================================================
-- 1. ADD COLUMN: data.public_domains.check_count
--    Comptador d'intents de verificació. Increments el worker a cada intent
--    fallit. El worker marca 'failed' quan check_count >= threshold.
--    DEFAULT 0: dominis existents comencen a 0 (no penalitzats).
--    RESET a 0: quan un domini transiciona a dns_verified o ssl_active.
-- =============================================================================

ALTER TABLE data.public_domains
  ADD COLUMN IF NOT EXISTS check_count integer NOT NULL DEFAULT 0;

COMMENT ON COLUMN data.public_domains.check_count
  IS 'Comptador d''intents de verificació DNS/SSL. '
     'El worker incrementa aquest valor a cada intent fallit. '
     'Quan arriba al límit (MAX_CHECK_ATTEMPTS al worker), transiciona a ''failed''. '
     'Es reseteja a 0 en transicionar a dns_verified o ssl_active.';


-- =============================================================================
-- 2. UPDATE: api.resolve_domain_for_portal
--    Canvi: pd.status IN ('dns_verified', 'ssl_active') → pd.status = 'ssl_active'
--    Motiu: un domini dns_verified pot no tenir SSL actiu. Servir contingut via
--    HTTPS sobre un domini sense certificat vàlid és incorrecte per seguretat.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.resolve_domain_for_portal(p_domain text)
RETURNS api.portal_site_row
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_result api.portal_site_row;
BEGIN
  SELECT
    ps.id,
    ps.tenant_id,
    ps.site_id,
    ps.slug,
    ps.name,
    ps.status,
    ps.primary_domain_id,
    pd_primary.domain  AS canonical_domain,
    ps.seo_title,
    ps.seo_description,
    ps.seo_keywords,
    ps.content,
    ps.theme_config,
    ps.created_at,
    ps.updated_at
  INTO v_result
  FROM data.public_domains pd
  JOIN data.public_sites ps ON ps.id = pd.public_site_id
  LEFT JOIN data.public_domains pd_primary
    ON pd_primary.id = ps.primary_domain_id
    AND pd_primary.status = 'ssl_active'
  WHERE pd.domain = lower(trim(p_domain))
    AND pd.status = 'ssl_active'          -- fix: era IN ('dns_verified', 'ssl_active')
    AND ps.status = 'published'
    AND data.public_portal_enabled_for_tenant(ps.tenant_id);

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION api.resolve_domain_for_portal(text) TO anon, authenticated;

COMMENT ON FUNCTION api.resolve_domain_for_portal IS
  'Retorna les dades del site per al SSR del portal públic via custom domain. '
  'SECURITY DEFINER: accessible per anon. '
  'Només accepta dominis ssl_active (certificat TLS vàlid i actiu). '
  'dns_verified sense ssl retorna NULL → 404 al portal. '
  'Retorna NULL si domini no existeix, no és ssl_active, site no publicat o portal no habilitat.';
