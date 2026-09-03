-- =============================================================================
-- TCMS-1.1 — Wrappers data.* per admin-portal (prisma_admin no usa schema api)
-- =============================================================================

CREATE OR REPLACE FUNCTION data.sync_portal_entitlements_with_plan(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
  SELECT api.sync_portal_entitlements_with_plan(p_tenant_id);
$$;

CREATE OR REPLACE FUNCTION data.upsert_tenant_portal_entitlements(
  p_tenant_id uuid,
  p_payload   jsonb
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
  SELECT api.upsert_tenant_portal_entitlements(p_tenant_id, p_payload);
$$;

REVOKE ALL ON FUNCTION data.sync_portal_entitlements_with_plan(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.upsert_tenant_portal_entitlements(uuid, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION data.sync_portal_entitlements_with_plan(uuid) TO prisma_admin, service_role;
GRANT EXECUTE ON FUNCTION data.upsert_tenant_portal_entitlements(uuid, jsonb) TO prisma_admin, service_role;
GRANT EXECUTE ON FUNCTION data.resolve_portal_entitlements(uuid) TO prisma_admin;
GRANT EXECUTE ON FUNCTION data.ensure_portal_channel_granted(uuid, text) TO prisma_admin;
