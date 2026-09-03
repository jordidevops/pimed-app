-- Fix EA-0: recreate api.assets with new columns (partial apply recovery)
DROP RULE IF EXISTS "api_assets_insert" ON api.assets;
DROP RULE IF EXISTS "api_assets_update" ON api.assets;
DROP RULE IF EXISTS "api_assets_delete" ON api.assets;
DROP VIEW IF EXISTS api.assets;

CREATE VIEW api.assets
  WITH (security_invoker = true) AS
SELECT
  a.id,
  a.tenant_id,
  a.site_id,
  a.location_id,
  a.name,
  a.serial_number,
  a.asset_tag,
  a.status,
  a.metadata,
  a.asset_type_id,
  a.requires_calibration,
  a.calibration_due_on,
  a.blocks_dispatch_if_missing,
  a.created_at,
  a.updated_at,
  l.name AS location_name
FROM data.assets a
LEFT JOIN data.locations l ON l.id = a.location_id;

GRANT SELECT ON api.assets TO authenticated;

CREATE RULE "api_assets_insert" AS ON INSERT TO api.assets
  DO INSTEAD
  INSERT INTO data.assets (
    tenant_id, site_id, location_id, name,
    serial_number, asset_tag, status, metadata,
    asset_type_id, requires_calibration, calibration_due_on, blocks_dispatch_if_missing
  )
  VALUES (
    NEW.tenant_id,
    NEW.site_id,
    NEW.location_id,
    NEW.name,
    NEW.serial_number,
    NEW.asset_tag,
    COALESCE(NEW.status, 'operational'),
    NEW.metadata,
    NEW.asset_type_id,
    COALESCE(NEW.requires_calibration, false),
    NEW.calibration_due_on,
    COALESCE(NEW.blocks_dispatch_if_missing, false)
  );

CREATE RULE "api_assets_update" AS ON UPDATE TO api.assets
  DO INSTEAD
  UPDATE data.assets SET
    site_id = NEW.site_id,
    location_id = NEW.location_id,
    name = NEW.name,
    serial_number = NEW.serial_number,
    asset_tag = NEW.asset_tag,
    status = NEW.status,
    metadata = NEW.metadata,
    asset_type_id = NEW.asset_type_id,
    requires_calibration = COALESCE(NEW.requires_calibration, false),
    calibration_due_on = NEW.calibration_due_on,
    blocks_dispatch_if_missing = COALESCE(NEW.blocks_dispatch_if_missing, false),
    updated_at = now()
  WHERE id = OLD.id;

CREATE RULE "api_assets_delete" AS ON DELETE TO api.assets
  DO INSTEAD
  DELETE FROM data.assets WHERE id = OLD.id;

GRANT INSERT, UPDATE, DELETE ON api.assets TO authenticated;

NOTIFY pgrst, 'reload schema';
