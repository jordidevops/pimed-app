-- Fix: listing tenants for the org switcher must ignore x-tenant-id.
-- Before: active_tenant_id() filtered my_tenant to a single row, which hid the
-- selector (tenants.length === 1) and trapped users on whichever tenant was
-- stored in sessionStorage (often Beta Startup after a local db reset).

DROP POLICY IF EXISTS "tenants: veure els propis tenants" ON data.tenants;

CREATE POLICY "tenants: veure els propis tenants"
  ON data.tenants FOR SELECT
  TO authenticated
  USING (data.jwt_user_tenants() ? id::text);

COMMENT ON POLICY "tenants: veure els propis tenants" ON data.tenants IS
  'Retorna TOTS els tenants de l''usuari (jwt_user_tenants). '
  'No filtra per x-tenant-id: el selector d''organització ha de veure''ls tots. '
  'El filtre de tenant actiu aplica a taules de domini, no al catàleg de tenants.';
