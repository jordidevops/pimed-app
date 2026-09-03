-- =============================================================================
-- Migration: 20260515000014_public_pages_full_anon_fix.sql
-- Propòsit:
--   Restaurar lectura anon de api.public_pages_full per al public-portal SSR.
--   La migració 20260515000011 va recrear la vista només per authenticated,
--   fet que provoca 404 a rutes com /<slug>/<locale>/<pageSlug>.
-- =============================================================================

CREATE OR REPLACE VIEW api.public_pages_full
  WITH (security_invoker = true)
AS
SELECT
  pp.id,
  pp.public_site_id,
  pp.tenant_id,
  pp.slug,
  pp.title,
  pp.status,
  pp.content,
  pp.translations,
  pp.seo_title,
  pp.seo_description,
  pp.sort_order,
  pp.created_at,
  pp.updated_at
FROM data.public_pages pp
WHERE (data.active_tenant_id() IS NULL OR pp.tenant_id = data.active_tenant_id());

GRANT SELECT ON api.public_pages_full TO authenticated, anon;
