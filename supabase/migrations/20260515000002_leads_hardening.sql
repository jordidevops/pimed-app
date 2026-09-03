-- =============================================================================
-- Migration: 20260515000002_leads_hardening.sql
-- Sprint 5 hardening: concurrencia, anti-duplicats i cost del dispatcher
--
-- Conté:
--   1) Rework api.submit_public_lead amb lock transaccional d'idempotencia
--      (evita write amplification de ON CONFLICT DO UPDATE)
--   2) Rework data.invoke_leads_queue_worker per usar EXISTS en lloc de COUNT(*)
--   3) Dedupe + index únic parcial per notifications lead_received
-- =============================================================================


-- =============================================================================
-- 1) api.submit_public_lead: idempotencia robusta sense UPDATE innecessari
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
  v_lock_key    bigint;
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

  -- 3. Serialitza només per clau d'idempotència per evitar carreres amb DO NOTHING
  --    i també evitar UPDATE no-op en duplicats.
  v_lock_key := hashtextextended(v_tenant_id::text || ':' || p_idempotency_key, 0);
  PERFORM pg_advisory_xact_lock(v_lock_key);

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
  ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
  RETURNING id INTO v_id;

  -- Duplicat: la fila ja existeix i, amb el lock, és visible en aquest punt.
  IF v_id IS NULL THEN
    SELECT id INTO v_id
    FROM data.public_leads
    WHERE tenant_id = v_tenant_id
      AND idempotency_key = p_idempotency_key;

    IF v_id IS NULL THEN
      RAISE EXCEPTION 'idempotency_lookup_failed'
        USING HINT = 'No s''ha pogut resoldre la clau d''idempotència.';
    END IF;

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

  -- 5. Encua notificació asíncrona (fire-and-forget)
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
    RAISE WARNING 'submit_public_lead: pgmq.send failed (leads_notification_queue): %', SQLERRM;
  END;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.submit_public_lead(uuid, text, text, text, text, text, text, text, jsonb) TO anon, authenticated;


-- =============================================================================
-- 2) data.invoke_leads_queue_worker: EXISTS en lloc de COUNT(*)
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
  v_supabase_url text;
  v_service_key  text;
  v_request_id   bigint;
  v_has_pending  boolean;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RAISE WARNING
      'invoke_leads_queue_worker: pg_net extension not installed. Skipping.';
    RETURN -2;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM pgmq.q_leads_notification_queue
    LIMIT 1
  ) INTO v_has_pending;

  IF NOT v_has_pending THEN
    RETURN 0;
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
      'invoke_leads_queue_worker: vault secrets not configured '
      '(app_supabase_url and/or app_service_role_key missing). '
      'Cron invocation skipped.';
    RETURN -1;
  END IF;

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


-- =============================================================================
-- 3) Notificacions lead_received: dedupe i index únic parcial
-- =============================================================================

WITH ranked AS (
  SELECT
    id,
    row_number() OVER (
      PARTITION BY tenant_id, user_id, kind, related_entity_type, related_entity_id
      ORDER BY created_at DESC, id DESC
    ) AS rn
  FROM data.notifications
  WHERE kind = 'lead_received'
    AND related_entity_type = 'public_lead'
    AND related_entity_id IS NOT NULL
)
DELETE FROM data.notifications n
USING ranked r
WHERE n.id = r.id
  AND r.rn > 1;

CREATE UNIQUE INDEX IF NOT EXISTS uidx_notifications_lead_received_unique
  ON data.notifications (tenant_id, user_id, kind, related_entity_type, related_entity_id)
  WHERE kind = 'lead_received'
    AND related_entity_type = 'public_lead'
    AND related_entity_id IS NOT NULL;
