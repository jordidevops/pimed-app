-- =============================================================================
-- Migration: 20260806000001_attendance_queue_capacity.sql
-- Propòsit : Control Horari v3 — Fase 0 (capacitat, catch-up i observabilitat)
--
-- AMBIT: PRODUCCIÓ (i local/staging). No és una migració de prova ni de dades
--        demo. S'aplica a qualsevol entorn on corri el mòdul d'assistència i
--        modifica el comportament operatiu real del worker de recomputació.
--        Les proves de càrrega (attendance_load_test.ts) són scripts apart;
--        aquesta migració defineix la infraestructura que també s'usa en prod.
--
-- Context del problema
-- ------------------
-- Cada fitxatge (api.record_time_punch) encua un missatge a
-- attendance_recompute_queue per recalcular time_entries i time_daily_summaries.
-- Abans d'aquesta migració:
--   · pg_cron cridava invoke_attendance_queue_worker(20) cada minut (batch fix
--     i petit).
--   · Una sola invocació de process-attendance-queue processava com a màxim
--     un lot de missatges.
--   · En pics d'entrada/sortida (molts empleats fitxant en 10–20 min) el
--     backlog creixia i les dades processades quedaven en retard respecte als
--     punches raw — inacceptable per a compliment legal (accés en temps real).
--
-- Què fa aquesta migració
-- ------------------------
--  1. Helpers de profunditat i dimensionament automàtic de lots:
--       · data.attendance_queue_depth()
--       · data.attendance_recompute_batch_size(p_explicit)  → 10–50 segons cua
--       · data.attendance_recompute_max_batches()          → 1–10 segons cua
--     Si la cua és profunda, el sistema entra en "catch-up mode" i processa
--     diversos lots per invocació del worker (fins a 500 recomputes/invocació).
--
--  2. data.resolve_worker_vault_secrets()
--     Unifica la lectura de URL i service_role_key del Vault (noms app_* i
--     noms curts) per al dispatcher pg_net → Edge Function.
--
--  3. data.invoke_attendance_queue_worker(p_batch_size DEFAULT NULL)
--     Reescriu el dispatcher que pg_cron invoca cada minut. Ara:
--       · Calcula batch_size i max_batches dinàmicament.
--       · Envia body JSON { batch_size, max_batches, catch_up } a
--         process-attendance-queue.
--       · Timeout HTTP escalat segons max_batches.
--     Si p_batch_size és NULL (cas del cron), tot és automàtic.
--
--  4. api.get_attendance_queue_health()
--     RPC d'observabilitat (service_role): profunditat PGMQ, edat del missatge
--     més antic, comptador DLQ, estat del cron, recomanació de batch,
--     últims 10 lots (audit_logs ASYNC_BATCH_PROCESSED) i flags alert_* per
--     monitorització/alertes.
--
--  5. GRANT service_role a api.record_time_punch (overload v2)
--     Permet al script de proves de càrrega cridar la RPC amb service_role.
--     En producció el fitxatge real continua sent via authenticated.
--
--  6. pg_cron: reprograma 'process-attendance-queue-worker'
--     De: SELECT data.invoke_attendance_queue_worker(20)
--     A:  SELECT data.invoke_attendance_queue_worker()   -- batch adaptatiu
--
-- Flux en producció (després d'aplicar)
-- -------------------------------------
--   fitxatge → pgmq.send(attendance_recompute_queue)
--        → cada minut: pg_cron → invoke_attendance_queue_worker()
--        → pg_net POST → process-attendance-queue (0..N batches)
--        → api.recompute_attendance_worker per missatge
--        → archive PGMQ + audit ASYNC_BATCH_PROCESSED
--
-- El worker Edge (process-attendance-queue/index.ts) ha de suportar max_batches
-- i catch_up al body; sense aquesta parella Edge+migració el catch-up no opera.
--
-- Què NO fa
-- ---------
--   · No crea dades demo ni seeds.
--   · No substitueix alertes externes (Sentry/PagerDuty); només exposa mètriques.
--   · No afegeix dashboard UI (consulta via RPC o SQL; veure runbook).
--
-- Documentació relacionada
-- ------------------------
--   docs/plans/checkin/plan.md § Fase 0
--   docs/plans/checkin/runbook-attendance-queue.md
--   supabase/tests/attendance_load_test.ts (validació SLO, opcional)
--
-- Depèn de:
--   20260515000018_attendance_core.sql (cua + invoke original)
--   20260503000002_async_infra.sql (PGMQ helpers, dlq_messages, audit)
--   20260727000002_attendance_v2_rpc_reports.sql (record_time_punch v2)
-- =============================================================================

-- ─── Helpers: mida de batch i mode catch-up ───────────────────────────────────

CREATE OR REPLACE FUNCTION data.attendance_queue_depth()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
  SELECT COALESCE(
    (SELECT queue_length::integer FROM pgmq.metrics('attendance_recompute_queue') LIMIT 1),
    0
  );
$$;

COMMENT ON FUNCTION data.attendance_queue_depth IS
  'Profunditat actual de attendance_recompute_queue (0 si buida).';

CREATE OR REPLACE FUNCTION data.attendance_recompute_batch_size(p_explicit integer DEFAULT NULL)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
  SELECT CASE
    WHEN p_explicit IS NOT NULL THEN LEAST(GREATEST(p_explicit, 1), 50)
    ELSE LEAST(GREATEST(data.attendance_queue_depth(), 10), 50)
  END;
$$;

CREATE OR REPLACE FUNCTION data.attendance_recompute_max_batches()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
  SELECT CASE
    WHEN data.attendance_queue_depth() > 500 THEN 10
    WHEN data.attendance_queue_depth() > 200 THEN 8
    WHEN data.attendance_queue_depth() > 100 THEN 5
    WHEN data.attendance_queue_depth() > 50  THEN 3
    WHEN data.attendance_queue_depth() > 20  THEN 2
    ELSE 1
  END;
$$;

-- ─── Vault URL/key (compat app_* i noms curts) ───────────────────────────────

CREATE OR REPLACE FUNCTION data.resolve_worker_vault_secrets()
RETURNS TABLE(supabase_url text, service_role_key text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_url text;
  v_key text;
BEGIN
  SELECT decrypted_secret INTO v_url
  FROM vault.decrypted_secrets
  WHERE name = 'app_supabase_url'
  LIMIT 1;

  IF v_url IS NULL THEN
    SELECT decrypted_secret INTO v_url
    FROM vault.decrypted_secrets
    WHERE name = 'supabase_url'
    LIMIT 1;
  END IF;

  SELECT decrypted_secret INTO v_key
  FROM vault.decrypted_secrets
  WHERE name = 'app_service_role_key'
  LIMIT 1;

  IF v_key IS NULL THEN
    SELECT decrypted_secret INTO v_key
    FROM vault.decrypted_secrets
    WHERE name = 'service_role_key'
    LIMIT 1;
  END IF;

  RETURN QUERY SELECT v_url, v_key;
END;
$$;

-- ─── Dispatcher amb batch adaptatiu + catch-up ───────────────────────────────

CREATE OR REPLACE FUNCTION data.invoke_attendance_queue_worker(
  p_batch_size integer DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
DECLARE
  v_url          text;
  v_key          text;
  v_batch        integer;
  v_max_batches  integer;
  v_request_id   bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RAISE WARNING 'invoke_attendance_queue_worker: pg_net not installed. Skipping.';
    RETURN -2;
  END IF;

  SELECT s.supabase_url, s.service_role_key
  INTO v_url, v_key
  FROM data.resolve_worker_vault_secrets() s;

  IF v_url IS NULL OR v_key IS NULL THEN
    RAISE WARNING 'invoke_attendance_queue_worker: vault secrets not configured. Skipping.';
    RETURN -1;
  END IF;

  v_batch       := data.attendance_recompute_batch_size(p_batch_size);
  v_max_batches := data.attendance_recompute_max_batches();

  BEGIN
    SELECT net.http_post(
      url := v_url || '/functions/v1/process-attendance-queue',
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || v_key,
        'Content-Type',  'application/json'
      ),
      body := jsonb_build_object(
        'batch_size',   v_batch,
        'max_batches',  v_max_batches,
        'catch_up',     v_max_batches > 1
      ),
      timeout_milliseconds := LEAST(120000, 15000 + (v_max_batches * 12000))
    ) INTO v_request_id;
  EXCEPTION WHEN OTHERS THEN
    BEGIN
      SELECT extensions.http_post(
        url := v_url || '/functions/v1/process-attendance-queue',
        headers := jsonb_build_object(
          'Authorization', 'Bearer ' || v_key,
          'Content-Type',  'application/json'
        ),
        body := jsonb_build_object(
          'batch_size',  v_batch,
          'max_batches', v_max_batches,
          'catch_up',    v_max_batches > 1
        ),
        timeout_milliseconds := LEAST(120000, 15000 + (v_max_batches * 12000))
      ) INTO v_request_id;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'invoke_attendance_queue_worker: http_post failed: %', SQLERRM;
      RETURN NULL;
    END;
  END;

  RETURN v_request_id;
END;
$$;

COMMENT ON FUNCTION data.invoke_attendance_queue_worker(integer) IS
  'Dispatcher pg_cron → process-attendance-queue. Batch adaptatiu (10–50) i max_batches '
  'segons profunditat de cua (catch-up fins a 10 batches per invocació).';

REVOKE ALL ON FUNCTION data.invoke_attendance_queue_worker(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.invoke_attendance_queue_worker(integer) FROM authenticated;
REVOKE ALL ON FUNCTION data.invoke_attendance_queue_worker(integer) FROM anon;

-- ─── Observabilitat ─────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.get_attendance_queue_health()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data, pgmq, public
AS $$
DECLARE
  v_metrics      record;
  v_dlq_count    bigint;
  v_archive_cnt  bigint;
  v_recent_audit jsonb;
  v_cron_active  boolean;
  v_batch_size   integer;
  v_max_batches  integer;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'insufficient_privilege'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT
    m.queue_name,
    m.queue_length,
    m.newest_msg_age_sec,
    m.oldest_msg_age_sec,
    m.total_messages,
    m.scrape_time
  INTO v_metrics
  FROM pgmq.metrics('attendance_recompute_queue') m
  LIMIT 1;

  SELECT count(*)::bigint INTO v_dlq_count
  FROM data.dlq_messages
  WHERE queue_name = 'attendance_recompute_queue';

  SELECT count(*)::bigint INTO v_archive_cnt
  FROM pgmq.a_attendance_recompute_queue;

  SELECT COALESCE(jsonb_agg(row_to_json(t)::jsonb ORDER BY t.created_at DESC), '[]'::jsonb)
  INTO v_recent_audit
  FROM (
    SELECT
      al.created_at,
      al.payload->>'queue_name'  AS queue_name,
      (al.payload->>'total')::int      AS total,
      (al.payload->>'succeeded')::int  AS succeeded,
      (al.payload->>'skipped')::int    AS skipped,
      (al.payload->>'retried')::int    AS retried,
      (al.payload->>'dlqed')::int      AS dlqed
    FROM data.audit_logs al
    WHERE al.action = 'ASYNC_BATCH_PROCESSED'
      AND al.payload->>'queue_name' = 'attendance_recompute_queue'
    ORDER BY al.created_at DESC
    LIMIT 10
  ) t;

  SELECT EXISTS (
    SELECT 1 FROM cron.job
    WHERE jobname = 'process-attendance-queue-worker'
      AND active = true
  ) INTO v_cron_active;

  v_batch_size  := data.attendance_recompute_batch_size(NULL);
  v_max_batches := data.attendance_recompute_max_batches();

  RETURN jsonb_build_object(
    'queue_name',           COALESCE(v_metrics.queue_name, 'attendance_recompute_queue'),
    'queue_length',         COALESCE(v_metrics.queue_length, 0),
    'oldest_msg_age_sec',   COALESCE(v_metrics.oldest_msg_age_sec, 0),
    'newest_msg_age_sec',   COALESCE(v_metrics.newest_msg_age_sec, 0),
    'total_messages',       COALESCE(v_metrics.total_messages, 0),
    'metrics_scrape_time',  v_metrics.scrape_time,
    'dlq_count',            v_dlq_count,
    'archive_count',        v_archive_cnt,
    'cron_active',          COALESCE(v_cron_active, false),
    'recommended_batch_size',  v_batch_size,
    'recommended_max_batches', v_max_batches,
    'catch_up_mode',        v_max_batches > 1,
    'alert_backlog',        COALESCE(v_metrics.queue_length, 0) > 200,
    'alert_stale_sec',      COALESCE(v_metrics.oldest_msg_age_sec, 0) > 300,
    'alert_dlq',            v_dlq_count > 0,
    'recent_batches',       v_recent_audit,
    'checked_at',           now()
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_attendance_queue_health() FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_attendance_queue_health() FROM authenticated;
REVOKE ALL ON FUNCTION api.get_attendance_queue_health() FROM anon;
GRANT EXECUTE ON FUNCTION api.get_attendance_queue_health() TO service_role;

-- service_role per proves de càrrega (record_time_punch overload v2)
GRANT EXECUTE ON FUNCTION api.record_time_punch(
  uuid, uuid, text, timestamptz, jsonb, text, text, text, uuid,
  text, boolean, boolean, boolean, text, jsonb
) TO service_role;

-- ─── Cron: batch adaptatiu cada minut ───────────────────────────────────────

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('process-attendance-queue-worker')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'process-attendance-queue-worker'
    );

    PERFORM cron.schedule(
      'process-attendance-queue-worker',
      '*/1 * * * *',
      'SELECT data.invoke_attendance_queue_worker()'
    );
  END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';
