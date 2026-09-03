-- =============================================================================
-- Expose structured address + geo_coordinates columns (added in
-- 20261144000001_maps_geo_coordinates_core.sql) through api.sites and
-- api.contact_sites.
--
-- IMPORTANT: must DROP + CREATE (not CREATE OR REPLACE) because new columns are
-- inserted in the middle of the SELECT list. Postgres rejects OR REPLACE when
-- existing view column names/order would change.
-- Plan: docs/plans/maps-geocoding-byok/README.md §5.1 / §5.1b
-- =============================================================================

-- ─── api.sites ────────────────────────────────────────────────────────────────

DROP VIEW IF EXISTS api.sites;

CREATE VIEW api.sites
  WITH (security_invoker = true) AS
  SELECT
    s.id,
    s.tenant_id,
    s.name,
    s.address,
    s.street,
    s.street_number,
    s.city,
    s.province,
    s.postal_code,
    s.country_code,
    s.geo_coordinates,
    s.is_active,
    s.metadata,
    s.default_email_layout_id,
    s.email_from_name,
    s.email_reply_to,
    s.email_logo_url,
    s.email_tenant_name_fallback,
    s.created_at,
    s.updated_at
  FROM data.sites s;

GRANT SELECT, INSERT, UPDATE ON api.sites TO authenticated;
GRANT SELECT ON api.sites TO service_role;

-- ─── api.contact_sites ────────────────────────────────────────────────────────

DROP VIEW IF EXISTS api.contact_sites;

CREATE VIEW api.contact_sites
  WITH (security_invoker = true)
AS
SELECT
  cs.id,
  cs.tenant_id,
  cs.contact_id,
  cs.name,
  cs.address,
  cs.street,
  cs.street_number,
  cs.city,
  cs.province,
  cs.postal_code,
  cs.country_code,
  cs.geo_coordinates,
  cs.notes,
  cs.is_active,
  cs.created_at,
  cs.updated_at
FROM data.contact_sites cs
WHERE cs.tenant_id = data.active_tenant_id();

GRANT SELECT ON api.contact_sites TO authenticated;
GRANT INSERT, UPDATE, DELETE ON api.contact_sites TO authenticated;
