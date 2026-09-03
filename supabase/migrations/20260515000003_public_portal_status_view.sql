-- Migration: 20260515000002_public_portal_status_view.sql
-- Descripció: Vista api.my_public_portal_status
--
-- Propòsit:
--   Exposa el flag `public_portal_enabled` del tenant actiu sense necessitar
--   cap fila a `data.public_sites`. Permet al tenant-portal determinar si el
--   mòdul està activat fins i tot quan el tenant no ha creat cap portal encara.
--
-- Depèn de:
--   · data.tenants                              (schema inicial)
--   · data.jwt_user_tenants()                   (schema inicial)
--   · data.public_portal_enabled_for_tenant()   (20260513000002_public_portal_rls.sql)
-- =============================================================================

-- =============================================================================
-- Vista: api.my_public_portal_status
-- Retorna una sola fila per al tenant actiu amb el flag public_portal_enabled.
-- Filtra per jwt_user_tenants() perquè no cal la capçalera x-tenant-id per
-- poder llegir l'estat (operació de lectura benigna).
-- =============================================================================

CREATE OR REPLACE VIEW api.my_public_portal_status
  WITH (security_invoker = true)
AS
SELECT
  t.id                       AS tenant_id,
  t.public_portal_enabled
FROM data.tenants t
WHERE data.jwt_user_tenants() ? t.id::text
  AND (
    data.active_tenant_id() IS NULL
    OR t.id = data.active_tenant_id()
  );

-- Accés de lectura pels membres autenticats (el tenant-portal)
GRANT SELECT ON api.my_public_portal_status TO authenticated;
