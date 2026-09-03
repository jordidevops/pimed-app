-- =============================================================================
-- Migration: 20260514000002_public_portal_portal_rpcs.sql
-- Sprint 4 — Subdominis, Dominis Propis i Canonicalització
--
-- Propòsit: Correccions de disseny d'accés anon al portal públic SSR.
--           Les vistes existents (api.public_sites, api.public_sites_full)
--           no servien per a reads anon amb content/theme_config. Solució:
--           RPCs SECURITY DEFINER que exposen el mínim necessari per al SSR.
--
-- Conté:
--   1.  RPC (SECURITY DEFINER): api.resolve_site_for_portal(p_slug text)
--       Retorna les dades del site per al SSR via slug (subdomini del sistema).
--       Inclou content, theme_config i canonical_domain (si ssl_active).
--
--   2.  RPC (SECURITY DEFINER): api.resolve_domain_for_portal(p_domain text)
--       Busca un site a partir d'un custom domain verificat.
--       Retorna les mateixes dades que resolve_site_for_portal.
--
--   3.  GRANT: accessible per anon (portal SSR sense autenticació).
--
-- Per què SECURITY DEFINER i no vista?
--   · Les vistes existents amb security_invoker = true apliquen la RLS de l'usuari
--     (anon) que accedeix, però el filtre WHERE usa active_tenant_id() → NULL per
--     a anon sense header x-tenant-id. Resultat: zero files per a anon.
--   · SECURITY DEFINER executa com a postgres i evita la RLS de la vista,
--     aplicant la validació de negoci manualment (published + portal_enabled).
--   · No exposem mai: verification_token, failure_reason, dades de membres, etc.
--
-- Dependències:
--   · data.public_sites         (20260513000001)
--   · data.public_domains       (20260513000001)
--   · data.public_portal_enabled_for_tenant() (20260513000002)
-- =============================================================================


-- =============================================================================
-- 1. RPC: api.resolve_site_for_portal(p_slug text)
--    Lookup per slug → retorna les dades del site per al SSR.
--    Accessible per anon (portal público SSR).
--    SECURITY DEFINER per evitar restriccions de RLS en lectura anon.
-- =============================================================================

CREATE TYPE api.portal_site_row AS (
  id               uuid,
  tenant_id        uuid,
  site_id          uuid,
  slug             text,
  name             text,
  status           text,
  primary_domain_id uuid,
  canonical_domain  text,
  seo_title        text,
  seo_description  text,
  seo_keywords     text[],
  content          jsonb,
  theme_config     jsonb,
  created_at       timestamptz,
  updated_at       timestamptz
);

CREATE OR REPLACE FUNCTION api.resolve_site_for_portal(p_slug text)
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
    -- Nom del domini canònic (si ssl_active i és el primary del site)
    pd.domain,
    ps.seo_title,
    ps.seo_description,
    ps.seo_keywords,
    ps.content,
    ps.theme_config,
    ps.created_at,
    ps.updated_at
  INTO v_result
  FROM data.public_sites ps
  LEFT JOIN data.public_domains pd
    ON pd.id = ps.primary_domain_id
    AND pd.status = 'ssl_active'
  WHERE ps.slug = lower(trim(p_slug))
    AND ps.status = 'published'
    AND data.public_portal_enabled_for_tenant(ps.tenant_id);

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION api.resolve_site_for_portal(text) TO anon, authenticated;

COMMENT ON FUNCTION api.resolve_site_for_portal IS
  'Retorna les dades del site per al SSR del portal públic via slug. '
  'SECURITY DEFINER: accessible per anon. Aplica validació de negoci manual '
  '(published + public_portal_enabled). Inclou canonical_domain si ssl_active. '
  'Retorna NULL si el site no existeix, no és published o el portal no està habilitat.';


-- =============================================================================
-- 2. RPC: api.resolve_domain_for_portal(p_domain text)
--    Lookup per custom domain → retorna les dades del site per al SSR.
--    Accessible per anon (portal públic amb domini propi).
--    SECURITY DEFINER per accedir a data.public_domains (no accessible per anon).
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
    AND pd.status IN ('dns_verified', 'ssl_active')
    AND ps.status = 'published'
    AND data.public_portal_enabled_for_tenant(ps.tenant_id);

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION api.resolve_domain_for_portal(text) TO anon, authenticated;

COMMENT ON FUNCTION api.resolve_domain_for_portal IS
  'Retorna les dades del site per al SSR del portal públic via custom domain. '
  'SECURITY DEFINER: accessible per anon. Busca dominis dns_verified o ssl_active. '
  'Aplica validació de negoci manual (published + public_portal_enabled). '
  'Retorna NULL si el domini no existeix, no és verificat o el portal no està habilitat.';
