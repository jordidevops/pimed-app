-- =============================================================================
-- Migration: 20260514000001_domain_verification_queue.sql
-- Sprint 4 — Subdominis, Dominis Propis i Canonicalització
--
-- Propòsit: Infraestructura asíncrona per a la verificació periòdica de dominis
--           propis dels portals públics.
--
-- Conté:
--   1.  RPC  : data.invoke_domain_verification_worker()
--              Dispatcher pg_cron → Edge Function via pg_net
--   2.  pg_cron: schedule cada 5 minuts
--
-- Flux d'estats de domini (implementat al worker Edge Function):
--   pending → (DNS TXT ok) → dns_verified → (SSL ok) → ssl_active
--   any → (fallada) → failed (amb failure_reason)
--
-- La Edge Function process-domain-verification consulta data.public_domains
-- directament (service_role) sense PGMQ intermedi: la BD és la font de veritat
-- dels dominis pendents, eliminant complexitat innecessària per a un worker cron.
--
-- Dependències:
--   · data.public_domains       (20260513000001_public_portal_core.sql)
--   · data.public_domain_events (20260513000001_public_portal_core.sql)
--   · pg_net extension          (present a Supabase)
--   · pg_cron extension         (present a Supabase)
--   · vault.decrypted_secrets   (app_supabase_url, app_service_role_key)
-- =============================================================================


-- =============================================================================
-- 1. RPC: data.invoke_domain_verification_worker(p_batch_size int)
--    Dispatcher pg_cron → Edge Function process-domain-verification via pg_net.
--
--    Patró idèntic a invoke_reminders_queue_worker / invoke_project_events_worker:
--      1. Comprova si hi ha dominis pendents (evita crides innecessàries)
--      2. Crida HTTP POST asíncrona a la Edge Function
--      3. Graceful degradation: -1 si secrets absents, -2 si pg_net absent
--
--    La Edge Function rep p_batch_size per limitar la feina per invocació.
-- =============================================================================

CREATE OR REPLACE FUNCTION data.invoke_domain_verification_worker(
  p_batch_size integer DEFAULT 20
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
  v_pending_count integer;
BEGIN
  -- Guard: pg_net must be installed
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RAISE WARNING
      'invoke_domain_verification_worker: pg_net extension not installed. Skipping.';
    RETURN -2;
  END IF;

  -- Comprova si hi ha dominis que necessiten verificació (evita crides innecessàries)
  SELECT COUNT(*) INTO v_pending_count
  FROM data.public_domains
  WHERE
    status IN ('pending', 'dns_verified')
    OR (
      status = 'failed'
      AND (last_checked_at IS NULL OR last_checked_at < now() - interval '1 hour')
    );

  IF v_pending_count = 0 THEN
    RETURN 0;
  END IF;

  -- Llegeix credencials del Vault
  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'app_supabase_url'
  LIMIT 1;

  SELECT decrypted_secret INTO v_service_key
  FROM vault.decrypted_secrets
  WHERE name = 'app_service_role_key'
  LIMIT 1;

  -- Graceful degradation: sense secrets no cridem la funció (local dev)
  IF v_supabase_url IS NULL OR v_service_key IS NULL THEN
    RAISE WARNING
      'invoke_domain_verification_worker: vault secrets not configured '
      '(app_supabase_url and/or app_service_role_key missing). '
      'Cron invocation skipped.';
    RETURN -1;
  END IF;

  -- HTTP POST asíncrona via pg_net (retorna immediatament amb request_id)
  BEGIN
    SELECT extensions.http_post(
      url     := v_supabase_url || '/functions/v1/process-domain-verification',
      headers := jsonb_build_object(
        'Content-Type',  'application/json',
        'Authorization', 'Bearer ' || v_service_key
      ),
      body    := jsonb_build_object(
        'batch_size', COALESCE(p_batch_size, 20)
      ),
      timeout_milliseconds := 25000
    ) INTO v_request_id;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING
      'invoke_domain_verification_worker: http_post failed: %', SQLERRM;
    RETURN NULL;
  END;

  RETURN v_request_id;
END;
$$;

-- Restricció: helper intern de pg_cron
REVOKE ALL ON FUNCTION data.invoke_domain_verification_worker(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.invoke_domain_verification_worker(integer) FROM authenticated;
REVOKE ALL ON FUNCTION data.invoke_domain_verification_worker(integer) FROM anon;

COMMENT ON FUNCTION data.invoke_domain_verification_worker IS
  'Dispatcher pg_cron → Edge Function process-domain-verification via pg_net. '
  'Comprova si hi ha dominis pendents abans de cridar (evita invocacions buides). '
  'Retorna request_id si èxit, 0 si cap domini pendent, -1 si secrets absents '
  '(dev local), -2 si pg_net absent.';


-- =============================================================================
-- 2. pg_cron: schedule cada 5 minuts
--    Frequència: 5 minuts és adequada per a checks DNS (no cal més freqüència).
--    La verificació SSL pot trigar fins a 24-48h (provisioning Vercel/Caddy).
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN

    -- Elimina schedule existent (idempotència en db reset)
    PERFORM cron.unschedule('process-domain-verification-worker')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'process-domain-verification-worker'
    );

    -- Cada 5 minuts: comprova dominis pendents i invoca el worker
    PERFORM cron.schedule(
      'process-domain-verification-worker',
      '*/5 * * * *',
      'SELECT data.invoke_domain_verification_worker(20)'
    );

  END IF;
END;
$$;
