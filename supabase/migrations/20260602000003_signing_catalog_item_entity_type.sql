-- ============================================================================
-- Migration: 20260602000003_signing_catalog_item_entity_type
-- Purpose:   Add 'catalog_item' to entity_type CHECK constraint on
--            data.tenant_role_defaults to allow catalog items as role entities
--            in document signing workflows.
-- ============================================================================

-- Drop the existing auto-generated CHECK constraint and recreate with catalog_item
ALTER TABLE data.tenant_role_defaults
  DROP CONSTRAINT IF EXISTS tenant_role_defaults_entity_type_check;

ALTER TABLE data.tenant_role_defaults
  ADD CONSTRAINT tenant_role_defaults_entity_type_check
  CHECK (entity_type IN (
    'employee', 'contact', 'user', 'person',
    'site', 'asset', 'tenant', 'catalog_item'
  ));

COMMENT ON COLUMN data.tenant_role_defaults.entity_type
  IS 'Tipus d''entitat assignada al rol: employee, contact, user, person, site, asset, tenant, catalog_item.';
