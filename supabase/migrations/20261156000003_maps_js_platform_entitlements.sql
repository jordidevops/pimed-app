-- =============================================================================
-- Maps JS platform entitlements (trial / limited platform entitlement)
-- =============================================================================

-- Tenant-level entitlement to use a platform-provided Maps JS key.
CREATE TABLE IF NOT EXISTS data.tenant_maps_js_platform_entitlements (
  tenant_id     uuid PRIMARY KEY REFERENCES data.tenants(id) ON DELETE CASCADE,
  activated_at  timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz,
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_tenant_maps_js_platform_entitlements_expires
  ON data.tenant_maps_js_platform_entitlements (expires_at);

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE data.tenant_maps_js_platform_entitlements TO prisma_admin;
GRANT SELECT ON TABLE data.tenant_maps_js_platform_entitlements TO service_role;

-- If the secret exists in vault, this registry entry lets the platform key be
-- managed/rotated via the same secret infra.
INSERT INTO data.platform_secret_registry (secret_key, description, category, rotation_due_at)
VALUES (
  'maps_js_platform_trial_api_key',
  'Maps JS platform trial / limited entitlement key',
  'maps_js',
  now() + interval '365 days'
)
ON CONFLICT (secret_key) DO NOTHING;

-- Service-only secret retrieval helper (decrypt by vault secret name).
CREATE OR REPLACE FUNCTION api.get_maps_js_platform_api_key_service(
  p_accessed_by_fn  text DEFAULT 'unknown',
  p_access_reason   text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_key text;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT decrypted_secret INTO v_key
  FROM vault.decrypted_secrets
  WHERE name = 'maps_js_platform_trial_api_key'
  LIMIT 1;

  RETURN v_key;
END;
$$;

REVOKE ALL ON FUNCTION api.get_maps_js_platform_api_key_service(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_maps_js_platform_api_key_service(text, text) TO service_role;

