-- =============================================================================
-- Migration: 20260503000004_reminders_queue_cron.sql
-- Purpose : Automate process-reminders-queue via pg_cron + pg_net dispatcher
--
-- Depèn de:
--   20260503000003_reminders_queue.sql (cua creada)
--   supabase/functions/process-reminders-queue/ (Edge Function desplegada)
--
-- Pattern: Identical to process-email-queue i process-project-events.
--   1. Funció dispatcher que crida l'Edge Function via pg_net
--   2. pg_cron que crida la funció periòdicament
--   3. Graceful degradation si pg_net o secrets no estan disponibles
-- =============================================================================

-- ============================================================================
-- 1. Funció dispatcher: data.invoke_reminders_queue_worker()
--
-- Crida HTTP asincròna al Worker Edge Function via pg_net.
-- Llegeix URL i clau del Vault (app_supabase_url, app_service_role_key).
-- Retorna -1 si secrets no configurats (local dev), -2 si pg_net absent.
-- ============================================================================

CREATE OR REPLACE FUNCTION data.invoke_reminders_queue_worker(p_batch_size integer DEFAULT 20)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_supabase_url  text;
  v_service_key   text;
  v_request_id    bigint;
BEGIN
  -- Guard: pg_net must be installed
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RAISE WARNING
      'invoke_reminders_queue_worker: pg_net extension not installed. Skipping.';
    RETURN -2;
  END IF;

  -- Read credentials from Vault (same secrets as email/project workers)
  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'app_supabase_url'
  LIMIT 1;

  SELECT decrypted_secret INTO v_service_key
  FROM vault.decrypted_secrets
  WHERE name = 'app_service_role_key'
  LIMIT 1;

  -- Graceful degradation: no secrets -> no HTTP call (local dev)
  IF v_supabase_url IS NULL OR v_service_key IS NULL THEN
    RAISE WARNING
      'invoke_reminders_queue_worker: vault secrets not configured '
      '(app_supabase_url and/or app_service_role_key missing). '
      'Cron invocation skipped.';
    RETURN -1;
  END IF;

  -- Async HTTP POST via pg_net (returns immediately with request_id)
  BEGIN
    SELECT extensions.http_post(
      url     := v_supabase_url || '/functions/v1/process-reminders-queue',
      headers := jsonb_build_object(
        'Content-Type',  'application/json',
        'Authorization', 'Bearer ' || v_service_key
      ),
      body    := jsonb_build_object(
        'batch_size', COALESCE(p_batch_size, 20)
      ),
      timeout_milliseconds := 30000  -- 30s: worker processarà fins 30 recordatoris
    ) INTO v_request_id;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING
      'invoke_reminders_queue_worker: http_post failed: %', SQLERRM;
    RETURN NULL;
  END;

  RETURN v_request_id;
END;
$$;

-- Restrict: internal cron helper only
REVOKE ALL ON FUNCTION data.invoke_reminders_queue_worker(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.invoke_reminders_queue_worker(integer) FROM authenticated;
REVOKE ALL ON FUNCTION data.invoke_reminders_queue_worker(integer) FROM anon;

COMMENT ON FUNCTION data.invoke_reminders_queue_worker IS
  'Dispatcher pg_cron → Edge Function process-reminders-queue via pg_net. '
  'Llegeix credencials del Vault (app_supabase_url, app_service_role_key). '
  'Retorna request_id si èxit, -1 si secrets absents (dev local), -2 si pg_net absent.';


-- ============================================================================
-- 2. pg_cron: schedule cada 1 minut
--
-- Frequencia: cada 1 minut és adequada per recordatoris
-- (missatges amb offset_minutes estan agendats a pgmq amb delay natiu).
-- Ajustar via:
--   SELECT cron.alter_job(
--     job_id   := (SELECT jobid FROM cron.job WHERE jobname = 'process-reminders-queue-worker'),
--     schedule := '*/2 * * * *'   -- each 2 minutes
--   );
-- ============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN

    -- Elimina schedule existent per fer la migració re-executable (db reset)
    PERFORM cron.unschedule('process-reminders-queue-worker')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'process-reminders-queue-worker'
    );

    -- Every 1 minute: invoke the Edge Function to drain the reminders queue.
    PERFORM cron.schedule(
      'process-reminders-queue-worker',
      '*/1 * * * *',
      'SELECT data.invoke_reminders_queue_worker(20)'
    );

  END IF;
END;
$$;
