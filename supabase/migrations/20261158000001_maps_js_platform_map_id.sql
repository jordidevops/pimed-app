-- =============================================================================
-- Maps JS platform Map ID (non-secret) in system_settings
-- =============================================================================
-- Map IDs are public client-side identifiers (same GCP project as the API key).
-- Tenant BYOK stores map_id in tenants.settings.maps.map_id.
-- Platform trial stores it here under module 'maps_js'.

INSERT INTO data.system_settings (module, settings)
VALUES (
  'maps_js',
  jsonb_build_object('map_id', null)
)
ON CONFLICT (module) DO NOTHING;
