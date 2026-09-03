-- =============================================================================
-- Migration: 20260515000001_leads_queue.sql
-- Sprint 5 — Ingesta Segura de Leads + Asíncron
--
-- Propòsit: Infraestructura asíncrona per al processament de nous leads captats
--           via el formulari públic del portal.
--
-- Conté:
--   1. PGMQ  : cua leads_notification_queue
--   2. RPC   : UPDATE api.submit_public_lead
--              Afegeix audit log LEAD_SUBMITTED + encuament a leads_notification_queue
--   3. RPC   : data.invoke_leads_queue_worker()
--              Dispatcher pg_cron → Edge Function via pg_net
--   4. pg_cron: schedule cada 2 minuts
--
-- Flux asíncron (implementat a process-leads-queue):
--   lead_submitted → notifica owners/managers del tenant (in-app + email)
--
-- Dependències:
--   · data.public_leads          (20260513000001_public_portal_core.sql)
--   · api.submit_public_lead     (20260513000002_public_portal_rls.sql)
--   · data.log_audit_event()     (Core multi-tenant)
--   · pgmq extension             (present a Supabase)
--   · pg_net extension           (present a Supabase)
--   · pg_cron extension          (present a Supabase)
--   · vault.decrypted_secrets    (app_supabase_url, app_service_role_key)
-- =============================================================================


-- =============================================================================
-- 1. PGMQ: crea la cua leads_notification_queue
--    pgmq.create() és idempotent: no falla si la cua ja existeix.
-- =============================================================================

SELECT pgmq.create('leads_notification_queue');


-- =============================================================================
-- 2. UPDATE: api.submit_public_lead
--    Afegeix dos passos al final del flux (després de l'upsert):
--      a) audit log LEAD_SUBMITTED (sense PII al payload)
--      b) encuament a leads_notification_queue per processament asíncron
--
--    El pgmq.send() és transaccional: si alguna cosa falla, reverteix.
--    Si la cua no existeix (migracions desordenades), la funció retorna igualment
--    el lead_id gràcies al EXCEPTION block.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.submit_public_lead(
  p_public_site_id  uuid,
  p_idempotency_key text,
  p_name            text    DEFAULT NULL,
  p_email           text    DEFAULT NULL,
  p_phone           text    DEFAULT NULL,
  p_message         text    DEFAULT NULL,
  p_source_url      text    DEFAULT NULL,
  p_source_page_slug text   DEFAULT NULL,
  p_metadata        jsonb   DEFAULT '{}'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_id          uuid;
  v_tenant_id   uuid;
  v_site_status text;
  v_enabled     bool;
  v_is_new      bool;
BEGIN
  -- 1. Obté el tenant i valida que el site és públic i el mòdul actiu
  SELECT ps.tenant_id, ps.status, t.public_portal_enabled
  INTO v_tenant_id, v_site_status, v_enabled
  FROM data.public_sites ps
  JOIN data.tenants t ON t.id = ps.tenant_id
  WHERE ps.id = p_public_site_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found'
      USING HINT = 'El portal públic no existeix.';
  END IF;

  IF v_site_status <> 'published' THEN
    RAISE EXCEPTION 'site_not_published'
      USING HINT = 'El portal públic no accepta submissions en aquest moment.';
  END IF;

  IF NOT COALESCE(v_enabled, false) THEN
    RAISE EXCEPTION 'module_not_enabled'
      USING HINT = 'El portal públic no accepta submissions en aquest moment.';
  END IF;

  -- 2. Valida que hi ha almenys un camp de contacte
  IF COALESCE(trim(p_name), '') = ''
    AND COALESCE(trim(p_email), '') = ''
    AND COALESCE(trim(p_phone), '') = ''
    AND COALESCE(trim(p_message), '') = ''
  THEN
    RAISE EXCEPTION 'empty_lead'
      USING HINT = 'Cal proporcionar almenys nom, email, telèfon o missatge.';
  END IF;

  -- 3. Upsert amb deduplicació per idempotency_key (scoped al tenant)
  INSERT INTO data.public_leads (
    public_site_id,
    tenant_id,
    idempotency_key,
    name,
    email,
    phone,
    message,
    source_url,
    source_page_slug,
    metadata,
    status
  ) VALUES (
    p_public_site_id,
    v_tenant_id,
    p_idempotency_key,
    nullif(trim(p_name), ''),
    nullif(lower(trim(p_email)), ''),
    nullif(trim(p_phone), ''),
    nullif(trim(p_message), ''),
    p_source_url,
    p_source_page_slug,
    COALESCE(p_metadata, '{}'),
    'new'
  )
  ON CONFLICT (tenant_id, idempotency_key) DO UPDATE
    -- no-op real: manté el valor existent. Amb DO UPDATE, RETURNING retorna
    -- sempre la fila (inserida o existent), eliminant la race condition de DO NOTHING.
    SET idempotency_key = data.public_leads.idempotency_key
  RETURNING id, (xmax = 0) INTO v_id, v_is_new;

  -- Si era duplicat (idempotency_key ja existia), retorna l'id sense re-encuar
  IF NOT v_is_new THEN
    RETURN v_id;
  END IF;

  -- 4. Audit log: LEAD_SUBMITTED (payload sense PII — no email/nom/telèfon)
  PERFORM data.log_audit_event(
    'LEAD_SUBMITTED',
    'public_lead',
    v_id,
    jsonb_build_object(
      'public_site_id',   p_public_site_id,
      'tenant_id',        v_tenant_id,
      'has_name',         (COALESCE(trim(p_name), '') <> ''),
      'has_email',        (COALESCE(trim(p_email), '') <> ''),
      'has_phone',        (COALESCE(trim(p_phone), '') <> ''),
      'has_message',      (COALESCE(trim(p_message), '') <> ''),
      'source_page_slug', p_source_page_slug,
      'idempotency_key',  p_idempotency_key
    )
  );

  -- 5. Encua notificació asíncrona (fire-and-forget: errors no bloquegen el flux)
  BEGIN
    PERFORM pgmq.send(
      'leads_notification_queue',
      jsonb_build_object(
        'task',             'lead_submitted',
        'tenant_id',        v_tenant_id,
        'idempotency_key',  'lead-notify-' || v_id,
        'enqueued_at',      now(),
        'payload', jsonb_build_object(
          'lead_id',          v_id,
          'public_site_id',   p_public_site_id,
          'source_page_slug', p_source_page_slug,
          'has_email',        (COALESCE(trim(p_email), '') <> ''),
          'has_phone',        (COALESCE(trim(p_phone), '') <> '')
        )
      )
    );
  EXCEPTION WHEN OTHERS THEN
    -- La cua pot no estar disponible en dev local sense PGMQ configurat.
    -- No bloquejem el flux principal.
    RAISE WARNING 'submit_public_lead: pgmq.send failed (leads_notification_queue): %', SQLERRM;
  END;

  RETURN v_id;
END;
$$;

-- Manté el grant existent
GRANT EXECUTE ON FUNCTION api.submit_public_lead(uuid, text, text, text, text, text, text, text, jsonb) TO anon, authenticated;

COMMENT ON FUNCTION api.submit_public_lead IS
  'Captura un lead des del formulari públic del portal. '
  'SECURITY DEFINER: accessible per anon. '
  'Inclou deduplicació per idempotency_key, audit log LEAD_SUBMITTED '
  '(sense PII), i encuament a leads_notification_queue per notificar el tenant.';


-- =============================================================================
-- 3. RPC: data.invoke_leads_queue_worker(p_batch_size int)
--    Dispatcher pg_cron → Edge Function process-leads-queue via pg_net.
--    Patró idèntic a invoke_reminders_queue_worker.
-- =============================================================================

CREATE OR REPLACE FUNCTION data.invoke_leads_queue_worker(
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
      'invoke_leads_queue_worker: pg_net extension not installed. Skipping.';
    RETURN -2;
  END IF;

  -- Comprova si hi ha missatges pendents a la cua (evita crides innecessàries)
  SELECT count(*)::integer INTO v_pending_count
  FROM pgmq.q_leads_notification_queue;

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
      'invoke_leads_queue_worker: vault secrets not configured '
      '(app_supabase_url and/or app_service_role_key missing). '
      'Cron invocation skipped.';
    RETURN -1;
  END IF;

  -- HTTP POST asíncrona via pg_net
  BEGIN
    SELECT extensions.http_post(
      url     := v_supabase_url || '/functions/v1/process-leads-queue',
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
      'invoke_leads_queue_worker: http_post failed: %', SQLERRM;
    RETURN NULL;
  END;

  RETURN v_request_id;
END;
$$;

REVOKE ALL ON FUNCTION data.invoke_leads_queue_worker(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.invoke_leads_queue_worker(integer) FROM authenticated;
REVOKE ALL ON FUNCTION data.invoke_leads_queue_worker(integer) FROM anon;

COMMENT ON FUNCTION data.invoke_leads_queue_worker IS
  'Dispatcher pg_cron → Edge Function process-leads-queue via pg_net. '
  'Comprova si hi ha missatges pendents a leads_notification_queue abans de cridar. '
  'Retorna request_id si èxit, 0 si cap missatge, -1 si secrets absents '
  '(dev local), -2 si pg_net absent.';


-- =============================================================================
-- 4. pg_cron: schedule cada 2 minuts
--    Freqüència de 2 min per minimitzar el retard en notificació al tenant.
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN

    -- Elimina schedule existent (idempotència en db reset)
    PERFORM cron.unschedule('process-leads-queue-worker')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'process-leads-queue-worker'
    );

    -- Cada 2 minuts
    PERFORM cron.schedule(
      'process-leads-queue-worker',
      '*/2 * * * *',
      'SELECT data.invoke_leads_queue_worker(20)'
    );

  END IF;
END;
$$;
