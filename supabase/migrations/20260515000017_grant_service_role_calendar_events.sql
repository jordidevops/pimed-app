-- migration: 20260515000017_grant_service_role_calendar_events.sql
--
-- Permet al worker process-leads-queue (service_role) inserir i consultar
-- events a data.calendar_events quan entra un nou lead al public portal.

GRANT SELECT, INSERT ON TABLE data.calendar_events TO service_role;
