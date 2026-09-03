-- migration: 20260515000015_grant_service_role_leads_worker.sql
--
-- Concedeix a service_role accés directe a les taules data.* que necessita
-- el worker process-leads-queue (Edge Function amb createAdminClient).
--
-- Sense aquests GRANTs, el worker rebia "permission denied for table public_leads"
-- i el missatge de la cua leads_notification_queue es retriava fins a anar al DLQ.
--
-- Nota: service_role té BYPASSRLS, però PostgreSQL exigeix GRANTs de taula
-- per separat. Les RLS continuen protegint anon/authenticated.

GRANT USAGE ON SCHEMA data TO service_role;

GRANT SELECT ON data.public_leads   TO service_role;
GRANT SELECT ON data.public_sites   TO service_role;
GRANT SELECT ON data.tenant_members TO service_role;
GRANT SELECT ON data.profiles       TO service_role;
