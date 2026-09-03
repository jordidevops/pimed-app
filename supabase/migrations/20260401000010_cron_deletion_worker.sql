-- =============================================================================
-- Migration 10: Automate process-deletion-queue via pg_cron + pg_net
-- =============================================================================
--
-- ARCHITECTURE — Secret management decision
-- ─────────────────────────────────────────
-- The Edge Function requires `Authorization: Bearer <SERVICE_ROLE_KEY>`.
-- We have three options to pass this from pg_cron:
--
--   A. Hardcode in migration  → REJECTED: commits secrets to Git
--   B. Custom GUC (ALTER DATABASE SET app.settings.key = '...')
--      → Not encrypted, visible in pg_dump and config files
--   C. Supabase Vault         → CHOSEN
--      • Already used in this project (BYOS secret_key_id in storage_providers)
--      • Encrypted at rest via pgsodium
--      • Only readable inside SECURITY DEFINER functions
--      • Secrets are provisioned via a one-time manual command (not in Git)
--
-- Two vault secrets are required (provisioned manually — see SETUP INSTRUCTIONS):
--   name: 'app_supabase_url'          value: https://<project-ref>.supabase.co
--   name: 'app_service_role_key'      value: <service_role_key>
--
-- The worker function reads them at runtime via vault.decrypted_secrets.
-- If either secret is missing (e.g. in local dev), it logs a WARNING and
-- returns -1 without crashing — graceful degradation.
--
-- SCHEDULE — every 5 minutes
-- ──────────────────────────
-- The queue is fed by three sources:
--   • api.trash_node(id, force_permanent=true) — user-triggered, any time
--   • data.process_expired_trash()             — daily burst at 03:00 UTC
--   • data.cleanup_pending_uploads()           — every 30 min
--
-- 5 minutes is a good balance: acceptable lag for user-triggered deletions,
-- and sufficient throughput (25 msg × 12 runs/hour = 300 files/hour) for the
-- daily burst. Adjust via: SELECT cron.alter_job(job_id, schedule := '*/2 * * * *');
--
-- Batch size: 25 messages per invocation (default). For high-traffic use,
-- increase by passing `{"batch_size": 50}` in the cron body or editing the
-- cron statement.
--
-- LOCAL DEV NOTE
-- ──────────────
-- pg_net is available in Supabase CLI local setup but cannot route HTTP
-- requests to supabase functions serve (different container network).
-- In local dev: trigger the function manually via:
--   curl -X POST http://127.0.0.1:54321/functions/v1/process-deletion-queue \
--        -H "Authorization: Bearer <service_role_key>" \
--        -H "Content-Type: application/json" \
--        -d '{"batch_size": 10}'
-- =============================================================================


-- ---------------------------------------------------------------------------
-- pg_net: async HTTP from PostgreSQL
-- Available in Supabase Cloud by default. Also present in local CLI ≥ 1.x.
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_net SCHEMA extensions;


-- ---------------------------------------------------------------------------
-- data.invoke_deletion_queue_worker(batch_size)
--
-- Reads the URL and service_role_key from Vault at runtime, then fires an
-- async HTTP POST to the process-deletion-queue Edge Function via pg_net.
--
-- Returns: pg_net request_id (check net._http_response for the result)
--          -1 if secrets are not configured (local dev / pre-setup)
--          -2 if pg_net extension is not available
--
-- Called by: pg_cron every 5 minutes
--
-- Security: SECURITY DEFINER is required to read vault.decrypted_secrets.
--           The function is in the private `data` schema (not exposed via
--           PostgREST) + PUBLIC/authenticated/anon access is revoked.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.invoke_deletion_queue_worker(
  p_batch_size integer DEFAULT 25
)
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
      'invoke_deletion_queue_worker: pg_net extension not installed. Skipping.';
    RETURN -2;
  END IF;

  -- Read credentials from Vault.
  -- vault.decrypted_secrets is only accessible from SECURITY DEFINER functions.
  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'app_supabase_url'
  LIMIT 1;

  SELECT decrypted_secret INTO v_service_key
  FROM vault.decrypted_secrets
  WHERE name = 'app_service_role_key'
  LIMIT 1;

  -- Graceful degradation when secrets are not yet provisioned (e.g. local dev,
  -- fresh environment before one-time setup).
  IF v_supabase_url IS NULL OR v_service_key IS NULL THEN
    RAISE WARNING
      'invoke_deletion_queue_worker: vault secrets not configured '
      '(app_supabase_url and/or app_service_role_key missing). '
      'Run the one-time setup described in migration 20260401000010. Skipping.';
    RETURN -1;
  END IF;

  -- Clamp batch_size to a safe range
  p_batch_size := LEAST(GREATEST(p_batch_size, 1), 50);

  -- Fire async POST request via pg_net.
  -- net.http_post() returns immediately with a request_id; the actual HTTP
  -- call is executed in the background by the pg_net worker.
  -- Responses are stored in net._http_response for observability.
  SELECT extensions.http_post(
    url     := v_supabase_url || '/functions/v1/process-deletion-queue',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || v_service_key
    ),
    body    := jsonb_build_object('batch_size', p_batch_size),
    timeout_milliseconds := 30000   -- 30 s: enough for a 25-file batch
  ) INTO v_request_id;

  RETURN v_request_id;
END;
$$;

-- Restrict: internal cron helper only — same pattern as process_expired_trash
REVOKE ALL ON FUNCTION data.invoke_deletion_queue_worker(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.invoke_deletion_queue_worker(integer) FROM authenticated;
REVOKE ALL ON FUNCTION data.invoke_deletion_queue_worker(integer) FROM anon;


-- ---------------------------------------------------------------------------
-- pg_cron: schedule the worker every 5 minutes
-- Consistent with the conditional pattern used in migration 6.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN

    -- Remove any existing schedule with this name to keep the migration
    -- re-runnable (e.g. after a db reset or re-deployment).
    PERFORM cron.unschedule('process-deletion-queue-worker')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'process-deletion-queue-worker'
    );

    -- Every 5 minutes: invoke the Edge Function to drain the deletion queue.
    -- To change the frequency:
    --   SELECT cron.alter_job(
    --     job_id   := (SELECT jobid FROM cron.job WHERE jobname = 'process-deletion-queue-worker'),
    --     schedule := '*/2 * * * *'   -- every 2 minutes
    --   );
    PERFORM cron.schedule(
      'process-deletion-queue-worker',
      '*/5 * * * *',
      'SELECT data.invoke_deletion_queue_worker(25)'
    );

  END IF;
END;
$$;
