-- =============================================================================
-- Migration: 20260609000002_document_pdf_jobs.sql
-- Purpose : Cua de generació PDF (patró email_logs)
--
-- Conté:
--   1. Enum data.pdf_job_status
--   2. Taula data.document_pdf_jobs    — estat dels treballs de conversió
--   3. Taula data.document_pdf_events  — timeline append-only per job
--   4. RLS + índexs
--   5. Vistes api.document_pdf_jobs + api.document_pdf_events
--   6. PGMQ: cua document_pdf_queue
--   7. pg_cron: job document_pdf_queue cada 1 minut
--   8. RPC api.create_pdf_job          — crea job + encua a PGMQ (SECURITY DEFINER)
--   9. RPC api.get_pdf_job_status      — estat per frontend (autenticat)
--  10. RPC api.retry_pdf_dead_letters  — reintentar DLQ (substitueix el placeholder de Fase 1)
--  11. RPC api.cancel_pdf_job          — cancel·lar job pendent
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Enum pdf_job_status
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'pdf_job_status' AND typnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'data')) THEN
    CREATE TYPE data.pdf_job_status AS ENUM (
      'queued', 'processing', 'completed', 'failed', 'skipped', 'dead_letter'
    );
  END IF;
END$$;

-- ---------------------------------------------------------------------------
-- 2. data.document_pdf_jobs
-- ---------------------------------------------------------------------------

CREATE TABLE data.document_pdf_jobs (
  id                    uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid          NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  status                data.pdf_job_status NOT NULL DEFAULT 'queued',

  -- Font del document
  source_type           text          NOT NULL CHECK (source_type IN ('template_locale', 'document_existing')),
  source_ref_id         uuid,           -- template_locale_id o document_version_id
  template_type         text          CHECK (template_type IN ('html', 'docx')),
  document_title        text,

  -- Fitxer intermediate (HTML/DOCX renderitzat per a reintent)
  intermediate_path     text,           -- Storage path (documents bucket)
  intermediate_size_bytes bigint,

  -- Resultat
  result_document_id    uuid          REFERENCES data.documents(id)         ON DELETE SET NULL,
  result_version_id     uuid,           -- FK a document_versions (no FK directa per evitar circ)

  -- Perfil de sortida
  output_profile        text          NOT NULL DEFAULT 'pdf'
                        CHECK (output_profile IN ('pdf', 'pdfa2b', 'pdfa3b')),

  -- Prioritat i reintentos
  priority              int           NOT NULL DEFAULT 0,
  attempt_count         int           NOT NULL DEFAULT 0,
  max_retries           int           NOT NULL DEFAULT 5,
  next_retry_at         timestamptz,
  is_dead_letter        boolean       NOT NULL DEFAULT false,

  -- Errors
  last_error_code       text,           -- gotenberg_unreachable | timeout | conversion_error
  last_error_message    text,

  -- Mètriques
  duration_ms           int,
  gotenberg_url_used    text,
  size_input_bytes      bigint,
  size_output_bytes     bigint,

  -- Context
  created_by            uuid          REFERENCES data.profiles(id) ON DELETE SET NULL,
  folder_id             uuid,
  metadata              jsonb         DEFAULT '{}'::jsonb,

  -- Idempotència
  idempotency_key       text          NOT NULL,

  -- Locking operatiu (complement al VT de PGMQ)
  locked_at             timestamptz,
  locked_by             text,

  -- Timestamps
  created_at            timestamptz   NOT NULL DEFAULT now(),
  updated_at            timestamptz   NOT NULL DEFAULT now(),
  completed_at          timestamptz,

  UNIQUE (tenant_id, idempotency_key)
);

CREATE TRIGGER trg_document_pdf_jobs_updated_at
  BEFORE UPDATE ON data.document_pdf_jobs
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

-- Índexs operatius
CREATE INDEX idx_pdf_jobs_tenant_status ON data.document_pdf_jobs (tenant_id, status);
CREATE INDEX idx_pdf_jobs_dead_letter   ON data.document_pdf_jobs (tenant_id) WHERE is_dead_letter;
CREATE INDEX idx_pdf_jobs_retry         ON data.document_pdf_jobs (next_retry_at) WHERE status = 'failed';
CREATE INDEX idx_pdf_jobs_created_at    ON data.document_pdf_jobs (created_at DESC);

-- ---------------------------------------------------------------------------
-- 3. data.document_pdf_events (timeline append-only)
-- ---------------------------------------------------------------------------

CREATE TABLE data.document_pdf_events (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id      uuid        NOT NULL REFERENCES data.document_pdf_jobs(id) ON DELETE CASCADE,
  event_type  text        NOT NULL
              CHECK (event_type IN (
                'queued', 'processing_started', 'completed',
                'failed', 'retry_scheduled', 'skipped', 'dead_letter'
              )),
  payload     jsonb       DEFAULT '{}'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_pdf_events_job_id    ON data.document_pdf_events (job_id);
CREATE INDEX idx_pdf_events_created_at ON data.document_pdf_events (created_at DESC);

-- ---------------------------------------------------------------------------
-- 4. RLS
-- ---------------------------------------------------------------------------

ALTER TABLE data.document_pdf_jobs   ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.document_pdf_events ENABLE ROW LEVEL SECURITY;

-- service_role: accés total (worker edge functions)
CREATE POLICY "service_role full access on document_pdf_jobs"
  ON data.document_pdf_jobs FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY "service_role full access on document_pdf_events"
  ON data.document_pdf_events FOR ALL TO service_role USING (true) WITH CHECK (true);

-- Membres autenticats: només llegir els jobs del seu tenant
CREATE POLICY "tenant members read pdf_jobs"
  ON data.document_pdf_jobs FOR SELECT TO authenticated
  USING (
    tenant_id IN (
      SELECT tenant_id FROM data.tenant_members
       WHERE user_id = auth.uid() AND is_active = true
    )
  );

CREATE POLICY "tenant members read pdf_events"
  ON data.document_pdf_events FOR SELECT TO authenticated
  USING (
    job_id IN (
      SELECT j.id FROM data.document_pdf_jobs j
       WHERE j.tenant_id IN (
         SELECT tenant_id FROM data.tenant_members
          WHERE user_id = auth.uid() AND is_active = true
       )
    )
  );

GRANT SELECT ON data.document_pdf_jobs   TO authenticated;
GRANT SELECT ON data.document_pdf_events TO authenticated;
GRANT ALL    ON data.document_pdf_jobs   TO service_role;
GRANT ALL    ON data.document_pdf_events TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Vistes api
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW api.document_pdf_jobs
WITH (security_invoker = true)
AS
SELECT
  id, tenant_id, status, source_type, source_ref_id, template_type, document_title,
  result_document_id, result_version_id, output_profile,
  priority, attempt_count, max_retries, next_retry_at, is_dead_letter,
  last_error_code, last_error_message, duration_ms,
  size_input_bytes, size_output_bytes,
  created_by, folder_id, metadata, idempotency_key,
  created_at, updated_at, completed_at
FROM data.document_pdf_jobs;

CREATE OR REPLACE VIEW api.document_pdf_events
WITH (security_invoker = true)
AS
SELECT id, job_id, event_type, payload, created_at
FROM data.document_pdf_events;

GRANT SELECT ON api.document_pdf_jobs   TO authenticated;
GRANT SELECT ON api.document_pdf_events TO authenticated;
GRANT SELECT, INSERT, UPDATE ON api.document_pdf_jobs TO service_role;
GRANT SELECT, INSERT        ON api.document_pdf_events TO service_role;

-- ---------------------------------------------------------------------------
-- 6. PGMQ: crear cua document_pdf_queue
-- ---------------------------------------------------------------------------

SELECT pgmq.create('document_pdf_queue');

-- ---------------------------------------------------------------------------
-- 7. Dispatcher + pg_cron: processar cua cada minut
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.invoke_document_pdf_queue_worker(p_batch_size integer DEFAULT 20)
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
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RAISE WARNING
      'invoke_document_pdf_queue_worker: pg_net extension not installed. Skipping.';
    RETURN -2;
  END IF;

  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'app_supabase_url'
  LIMIT 1;

  SELECT decrypted_secret INTO v_service_key
  FROM vault.decrypted_secrets
  WHERE name = 'app_service_role_key'
  LIMIT 1;

  IF v_supabase_url IS NULL OR v_service_key IS NULL THEN
    RAISE WARNING
      'invoke_document_pdf_queue_worker: vault secrets not configured. Cron invocation skipped.';
    RETURN -1;
  END IF;

  BEGIN
    SELECT extensions.http_post(
      url     := v_supabase_url || '/functions/v1/process-document-pdf-queue',
      headers := jsonb_build_object(
        'Content-Type',  'application/json',
        'Authorization', 'Bearer ' || v_service_key
      ),
      body    := jsonb_build_object(
        'batch_size', COALESCE(p_batch_size, 20)
      ),
      timeout_milliseconds := 30000
    ) INTO v_request_id;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING
      'invoke_document_pdf_queue_worker: http_post failed: %', SQLERRM;
    RETURN NULL;
  END;

  RETURN v_request_id;
END;
$$;

REVOKE ALL ON FUNCTION data.invoke_document_pdf_queue_worker(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.invoke_document_pdf_queue_worker(integer) FROM authenticated;
REVOKE ALL ON FUNCTION data.invoke_document_pdf_queue_worker(integer) FROM anon;

COMMENT ON FUNCTION data.invoke_document_pdf_queue_worker IS
  'Dispatcher pg_cron → Edge Function process-document-pdf-queue via pg_net.';

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN

    PERFORM cron.unschedule('document_pdf_queue')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'document_pdf_queue'
    );

    PERFORM cron.schedule(
      'document_pdf_queue',
      '* * * * *',
      'SELECT data.invoke_document_pdf_queue_worker(20)'
    );

  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 8. RPC api.create_pdf_job — crea job + encua a PGMQ
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.create_pdf_job(
  p_tenant_id       uuid,
  p_source_type     text,
  p_source_ref_id   uuid,
  p_template_type   text,
  p_document_title  text,
  p_output_profile  text DEFAULT 'pdf',
  p_folder_id       uuid DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL,
  p_priority        int  DEFAULT 0,
  p_metadata        jsonb DEFAULT '{}'::jsonb,
  p_intermediate_path text DEFAULT NULL,
  p_intermediate_size_bytes bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_user_id     uuid;
  v_job_id      uuid;
  v_idem_key    text;
  v_max_retries int;
  v_existing    uuid;
BEGIN
  -- Verificar usuari autenticat (service_role via Edge Functions: auth.role())
  v_user_id := auth.uid();
  IF v_user_id IS NULL AND COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  -- Verificar membresia al tenant (skip per service_role; el router ja valida)
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.tenant_members
       WHERE tenant_id = p_tenant_id AND user_id = v_user_id AND is_active = true
         AND role IN ('owner', 'manager')
    ) THEN
      RAISE EXCEPTION 'Forbidden: requires owner or manager role';
    END IF;
  END IF;

  -- Generar idempotency_key si no s'envia
  v_idem_key := COALESCE(p_idempotency_key, 'pdf-' || gen_random_uuid()::text);

  -- Dedup: si ja existeix un job amb la mateixa clau i no ha fallat, retornar-lo
  SELECT id INTO v_existing
    FROM data.document_pdf_jobs
   WHERE tenant_id = p_tenant_id AND idempotency_key = v_idem_key
     AND status NOT IN ('failed', 'dead_letter')
   LIMIT 1;

  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object('job_id', v_existing, 'idempotent_replay', true);
  END IF;

  -- Llegir max_retries de system_settings
  SELECT COALESCE(
    (settings -> 'retry' ->> 'max_attempts')::int, 5
  ) INTO v_max_retries
  FROM data.system_settings WHERE module = 'pdf_converter';

  -- Crear job
  INSERT INTO data.document_pdf_jobs (
    tenant_id, status, source_type, source_ref_id, template_type, document_title,
    output_profile, priority, max_retries, created_by, folder_id, metadata,
    idempotency_key, intermediate_path, intermediate_size_bytes
  ) VALUES (
    p_tenant_id, 'queued', p_source_type, p_source_ref_id, p_template_type, p_document_title,
    p_output_profile, p_priority, v_max_retries, v_user_id, p_folder_id, p_metadata,
    v_idem_key, p_intermediate_path, p_intermediate_size_bytes
  )
  RETURNING id INTO v_job_id;

  -- Event queued
  INSERT INTO data.document_pdf_events (job_id, event_type, payload)
  VALUES (v_job_id, 'queued', jsonb_build_object('tenant_id', p_tenant_id));

  -- Encuar a PGMQ
  PERFORM pgmq.send(
    'document_pdf_queue',
    jsonb_build_object(
      'task',             'convert_to_pdf',
      'tenant_id',        p_tenant_id::text,
      'idempotency_key',  v_idem_key,
      'payload',          jsonb_build_object('job_id', v_job_id)
    )
  );

  RETURN jsonb_build_object('job_id', v_job_id, 'idempotent_replay', false);
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_pdf_job(uuid,text,uuid,text,text,text,uuid,text,int,jsonb,text,bigint) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 9. RPC api.get_pdf_job_status — per frontend (polling + realtime fallback)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.get_pdf_job_status(
  p_job_id   uuid,
  p_tenant_id uuid
)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT jsonb_build_object(
    'id',                j.id,
    'status',            j.status,
    'attempt_count',     j.attempt_count,
    'max_retries',       j.max_retries,
    'is_dead_letter',    j.is_dead_letter,
    'last_error_code',   j.last_error_code,
    'last_error_message',j.last_error_message,
    'result_document_id',j.result_document_id,
    'result_version_id', j.result_version_id,
    'duration_ms',       j.duration_ms,
    'completed_at',      j.completed_at,
    'created_at',        j.created_at,
    'updated_at',        j.updated_at
  )
  FROM data.document_pdf_jobs j
 WHERE j.id = p_job_id
   AND j.tenant_id = p_tenant_id
   AND j.tenant_id IN (
     SELECT tenant_id FROM data.tenant_members
      WHERE user_id = auth.uid() AND is_active = true
   )
$$;

GRANT EXECUTE ON FUNCTION api.get_pdf_job_status(uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 10. RPC api.retry_pdf_dead_letters — substitueix el placeholder de Fase 1
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.retry_pdf_dead_letters(
  p_tenant_id uuid DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_count int := 0;
  v_job   record;
BEGIN
  FOR v_job IN
    SELECT id, tenant_id, idempotency_key, source_type, source_ref_id,
           template_type, document_title, output_profile, priority, folder_id, metadata
      FROM data.document_pdf_jobs
     WHERE is_dead_letter = true
       AND (p_tenant_id IS NULL OR tenant_id = p_tenant_id)
  LOOP
    UPDATE data.document_pdf_jobs
       SET status         = 'queued',
           is_dead_letter = false,
           attempt_count  = 0,
           next_retry_at  = NULL,
           last_error_code    = NULL,
           last_error_message = NULL,
           updated_at     = now()
     WHERE id = v_job.id;

    INSERT INTO data.document_pdf_events (job_id, event_type, payload)
    VALUES (v_job.id, 'queued', jsonb_build_object('reason', 'admin_retry_dead_letters'));

    PERFORM pgmq.send(
      'document_pdf_queue',
      jsonb_build_object(
        'task',            'convert_to_pdf',
        'tenant_id',       v_job.tenant_id::text,
        'idempotency_key', v_job.idempotency_key || '-retry-' || extract(epoch from now())::text,
        'payload',         jsonb_build_object('job_id', v_job.id)
      )
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION api.retry_pdf_dead_letters(uuid) TO service_role, authenticated;

-- ---------------------------------------------------------------------------
-- 11. RPC api.cancel_pdf_job
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.cancel_pdf_job(
  p_job_id    uuid,
  p_tenant_id uuid
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM data.tenant_members
     WHERE tenant_id = p_tenant_id AND user_id = v_user_id AND is_active = true
       AND role IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;

  UPDATE data.document_pdf_jobs
     SET status = 'skipped', updated_at = now()
   WHERE id = p_job_id AND tenant_id = p_tenant_id
     AND status IN ('queued', 'failed');

  RETURN FOUND;
END;
$$;

GRANT EXECUTE ON FUNCTION api.cancel_pdf_job(uuid, uuid) TO authenticated;
