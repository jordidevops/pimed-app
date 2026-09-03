-- =============================================================================
-- Migration: 20260503000003_reminders_queue.sql
-- Purpose : Crea la PGMQ reminders_queue per als recordatoris de events de calendari.
--
-- Depèn de:
--   20260503000002_async_infra.sql (api.create_calendar_event_with_reminders
--                                   encua a aquesta cua)
--
-- Nota: pgmq.create() és idempotent a partir de PGMQ >= 1.x (Supabase CLI local).
--       Si la cua ja existeix, no retorna error.
-- =============================================================================

SELECT pgmq.create('reminders_queue');
