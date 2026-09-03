-- =============================================================================
-- Migration: 20260503000002_async_infra.sql
-- Purpose : Infraestructura asíncrona base (PGMQ workers, notificacions, DLQ)
--
-- Depends:
--   20260401000002 (tenants, profiles, tenant_members)
--   20260401000006 (pgmq extension already created)
--   20260423000001 (audit_logs, log_audit_event)
--   20260503000001 (calendar_events — per al RPC d'exemple al final)
--
-- Conté:
--   1.  data.async_tasks         — rastreig opcional de tasques observables
--   2.  data.notifications       — inbox in-app per TenantMember
--   3.  data.processed_messages  — dedup per cua (idempotència)
--   4.  data.dlq_messages        — Dead Letter Queue
--   5.  Trigger updated_at genèric (reutilitzable)
--   6.  Triggers d'audit per async_tasks
--   7.  RLS policies
--   8.  api.async_tasks           (vista security_invoker)
--   9.  api.notifications         (vista security_invoker)
--  10.  api.mark_notification_read(uuid)
--  11.  api.read_queue_batch      (genèrica, service_role only)
--  12.  api.archive_queue_message (genèrica, service_role only)
--  13.  api.set_queue_message_vt  (retry backoff, service_role only)
--  14.  api.check_dedup           (service_role only)
--  15.  api.record_processed      (service_role only)
--  16.  api.move_to_dlq           (service_role only — inserts DLQ + notifica owners)
--  17.  api.log_queue_batch_audit (service_role only)
--  18.  api.create_calendar_event_with_reminders (authenticated, SECURITY DEFINER)
--       Nota: encua a 'reminders_queue', que es crea a la migració 20260503000003.
--       Fix integrat: COALESCE(array_length(p_reminders, 1), 0) per evitar retornar
--       NULL quan p_reminders és un array buit (array_length retorna NULL, no 0).
--
-- Patró de seguretat dels RPCs de worker:
--   Tots els RPCs de worker (11-17) són SECURITY DEFINER i GRANT TO service_role only.
--   Això impedeix que cap usuari autenticat cridi directament funcions de PGMQ.
--
-- Seguretat i aïllament multi-tenant:
--   api.move_to_dlq llegeix tenant_id del payload i l'usa per notificar owners.
--   Tots els workers passen tenant_id explícit al payload — mai es fa bypass JWT.
-- =============================================================================


-- =============================================================================
-- 0. Trigger updated_at genèric
--    Crea o substitueix; idempotent en re-run de migrations de dev.
-- =============================================================================

CREATE OR REPLACE FUNCTION data.trg_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


-- =============================================================================
-- 1. data.async_tasks
--    Rastreig opcional de tasques de fons llargues (export, import, etc.)
--    que l'usuari vol observar (estat, progrés, resultat).
--    La majoria de tasques ràpides (enviar email) NO necessiten registre aquí.
-- =============================================================================

CREATE TABLE data.async_tasks (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid        NOT NULL REFERENCES data.tenants(id)  ON DELETE CASCADE,
  site_id      uuid                 REFERENCES data.sites(id)    ON DELETE SET NULL,
  created_by   uuid                 REFERENCES data.profiles(id) ON DELETE SET NULL,
    -- NULL si la tasca és disparada per pg_cron o service_role sense context d'usuari
  kind         text        NOT NULL,
    -- Ex: 'export_data', 'bulk_import', 'report_generation', 'bulk_send_email'
  status       text        NOT NULL DEFAULT 'queued'
               CHECK (status IN ('queued','running','done','failed')),
  progress_pct smallint    CHECK (progress_pct BETWEEN 0 AND 100),
    -- Opcional: 0..100 per mostrar barra de progrés al frontend
  started_at   timestamptz,
  finished_at  timestamptz,
  result       jsonb,
    -- Ex: {"download_url": "...", "rows_imported": 1200}
  error_text   text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_async_tasks_tenant_status
  ON data.async_tasks (tenant_id, status, created_at DESC);

COMMENT ON TABLE data.async_tasks
  IS 'Rastreig de tasques asíncrones observables per l''usuari. '
     'No registrar tasques ràpides (email, sms): viuen exclusivament a PGMQ.';

-- updated_at trigger
CREATE TRIGGER trg_async_tasks_updated_at
  BEFORE UPDATE ON data.async_tasks
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();


-- =============================================================================
-- 2. data.notifications
--    Inbox in-app per TenantMember (usuaris interns del tenant).
--    Diferent de data.communications (outbound al Contact extern).
-- =============================================================================

CREATE TABLE data.notifications (
  id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id            uuid        NOT NULL REFERENCES data.tenants(id)  ON DELETE CASCADE,
  user_id              uuid        NOT NULL REFERENCES data.profiles(id) ON DELETE CASCADE,
    -- Destinatari de la notificació (membre intern del tenant)
  kind                 text        NOT NULL,
    -- Ex: 'task_complete', 'dlq_error', 'reminder_failed', 'plan_limit_reached'
  severity             text        NOT NULL DEFAULT 'info'
                       CHECK (severity IN ('info','success','warning','critical')),
  title_i18n           jsonb       NOT NULL DEFAULT '{}',
    -- Ex: {"ca": "Tasca completada", "es": "Tarea completada", "en": "Task complete"}
  body_i18n            jsonb                DEFAULT '{}',
  deep_link            text,
    -- Ruta dins l'app: '/projects/uuid', '/admin/dlq', etc.
  related_entity_type  text,
    -- Ex: 'project', 'calendar_event', 'async_task'
  related_entity_id    uuid,
  read_at              timestamptz,
    -- NULL = no llegida. Actualitzada per api.mark_notification_read().
  created_at           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_notifications_user_unread
  ON data.notifications (user_id, tenant_id, created_at DESC)
  WHERE read_at IS NULL;

CREATE INDEX idx_notifications_user_all
  ON data.notifications (user_id, tenant_id, created_at DESC);

COMMENT ON TABLE data.notifications
  IS 'Inbox in-app per membres interns del tenant. '
     'No és data.communications (outbound al Contact extern).';


-- =============================================================================
-- 3. data.processed_messages
--    Dedup per cua. PK = (queue_name, idempotency_key).
--    Retention recomanada: 30 dies (purgar via pg_cron).
-- =============================================================================

CREATE TABLE data.processed_messages (
  queue_name       text        NOT NULL,
  msg_id           bigint      NOT NULL,
    -- El msg_id de PGMQ (referència informativa; no FK perquè PGMQ usa taules dinàmiques)
  idempotency_key  text        NOT NULL,
  processed_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (queue_name, idempotency_key)
);

CREATE INDEX idx_processed_messages_queue_msg
  ON data.processed_messages (queue_name, msg_id);

COMMENT ON TABLE data.processed_messages
  IS 'Dedup de missatges PGMQ processats. '
     'Purgar files > 30 dies via pg_cron (maintenance_queue).';


-- =============================================================================
-- 4. data.dlq_messages
--    Dead Letter Queue: missatges que han fallat maxAttempts vegades.
--    Els owners del tenant reben notificació in-app (severity=critical).
-- =============================================================================

CREATE TABLE data.dlq_messages (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  queue_name       text        NOT NULL,
  original_msg_id  bigint,
  payload          jsonb       NOT NULL,
  attempt_count    smallint    NOT NULL,
  last_error_text  text,
  last_error_at    timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_dlq_messages_queue_created
  ON data.dlq_messages (queue_name, created_at DESC);

COMMENT ON TABLE data.dlq_messages
  IS 'Dead Letter Queue. Missatges arxivats de PGMQ que han fallat el nombre màxim d''intents.';


-- =============================================================================
-- 5. Triggers d'audit per async_tasks
-- =============================================================================

CREATE OR REPLACE FUNCTION data.trg_audit_async_tasks()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      COALESCE(auth.uid(), NEW.created_by),
      NEW.site_id,
      'ASYNC_TASK_CREATED',
      'async_task', NEW.id,
      jsonb_build_object('kind', NEW.kind, 'status', NEW.status)
    );

  ELSIF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      COALESCE(auth.uid(), NEW.created_by),
      NEW.site_id,
      'ASYNC_TASK_STATUS_CHANGED',
      'async_task', NEW.id,
      jsonb_build_object(
        'kind',       NEW.kind,
        'old_status', OLD.status,
        'new_status', NEW.status,
        'error_text', NEW.error_text
      )
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_audit_async_tasks
  AFTER INSERT OR UPDATE ON data.async_tasks
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_async_tasks();


-- =============================================================================
-- 6. Row Level Security
-- =============================================================================

ALTER TABLE data.async_tasks        ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.notifications       ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.processed_messages  ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.dlq_messages        ENABLE ROW LEVEL SECURITY;

-- ── async_tasks ──────────────────────────────────────────────────────────────

-- Lectura per membres del tenant
CREATE POLICY "async_tasks: lectura per membres del tenant"
  ON data.async_tasks FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

-- Cap INSERT/UPDATE/DELETE per authenticated → bloquejat per defecte
-- Escriptura exclusivament via service_role (RPCs dels workers)

CREATE POLICY "async_tasks: service_role full access"
  ON data.async_tasks FOR ALL
  TO service_role
  USING (true) WITH CHECK (true);

-- ── notifications ─────────────────────────────────────────────────────────────

-- Lectura: l'usuari veu ÚNICAMENT les seves pròpies notificacions
CREATE POLICY "notifications: lectura per l'usuari destinatari"
  ON data.notifications FOR SELECT
  TO authenticated
  USING (
    user_id = auth.uid()
    AND data.jwt_user_tenants() ? tenant_id::text
  );

-- mark_notification_read: l'usuari pot actualitzar read_at de les seves notificacions
CREATE POLICY "notifications: marcar llegida pel destinatari"
  ON data.notifications FOR UPDATE
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "notifications: service_role full access"
  ON data.notifications FOR ALL
  TO service_role
  USING (true) WITH CHECK (true);

-- ── processed_messages i dlq_messages ────────────────────────────────────────
-- Taules de sistema: NO accessibles per authenticated (cap política SELECT)
-- Únicament service_role (workers)

CREATE POLICY "processed_messages: service_role full access"
  ON data.processed_messages FOR ALL
  TO service_role
  USING (true) WITH CHECK (true);

CREATE POLICY "dlq_messages: service_role full access"
  ON data.dlq_messages FOR ALL
  TO service_role
  USING (true) WITH CHECK (true);


-- =============================================================================
-- 7. Grants a nivell de taula
-- =============================================================================

GRANT SELECT ON data.async_tasks TO authenticated;
GRANT ALL    ON data.async_tasks TO service_role;

GRANT SELECT, UPDATE ON data.notifications TO authenticated;
GRANT ALL            ON data.notifications TO service_role;

-- processed_messages i dlq_messages: authenticated NO té cap grant (protecció doble)
GRANT ALL ON data.processed_messages TO service_role;
GRANT ALL ON data.dlq_messages       TO service_role;


-- =============================================================================
-- 8. Vista api.async_tasks (security_invoker = true)
-- =============================================================================

CREATE OR REPLACE VIEW api.async_tasks
  WITH (security_invoker = true) AS
  SELECT
    id,
    tenant_id,
    site_id,
    created_by,
    kind,
    status,
    progress_pct,
    started_at,
    finished_at,
    result,
    error_text,
    created_at,
    updated_at
  FROM data.async_tasks;

GRANT SELECT ON api.async_tasks TO authenticated;


-- =============================================================================
-- 9. Vista api.notifications (security_invoker = true)
-- =============================================================================

CREATE OR REPLACE VIEW api.notifications
  WITH (security_invoker = true) AS
  SELECT
    id,
    tenant_id,
    user_id,
    kind,
    severity,
    title_i18n,
    body_i18n,
    deep_link,
    related_entity_type,
    related_entity_id,
    read_at,
    created_at
  FROM data.notifications;

GRANT SELECT ON api.notifications TO authenticated;


-- =============================================================================
-- 10. api.mark_notification_read(p_id uuid)
--     Accessible per authenticated; RLS garanteix que l'usuari és el destinatari.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.mark_notification_read(p_id uuid)
RETURNS void
LANGUAGE sql
SECURITY INVOKER
SET search_path = data, public
AS $$
  UPDATE data.notifications
  SET read_at = now()
  WHERE id = p_id
    AND user_id = auth.uid()
    AND read_at IS NULL;
$$;

GRANT EXECUTE ON FUNCTION api.mark_notification_read(uuid) TO authenticated;


-- =============================================================================
-- 11. api.read_queue_batch
--     Llegeix un lot de missatges de qualsevol cua PGMQ.
--     Genèrica — substitueix pop_deletion_messages, pop_email_messages per als workers nous.
--     GRANT: service_role only.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.read_queue_batch(
  p_queue text,
  p_count int  DEFAULT 10,
  p_vt    int  DEFAULT 60
)
RETURNS TABLE (msg_id bigint, read_ct int, message jsonb)
LANGUAGE sql
SECURITY DEFINER
SET search_path = pgmq, public
AS $$
  SELECT
    m.msg_id,
    m.read_ct::int,
    m.message
  FROM pgmq.read(
    p_queue,
    p_vt,
    LEAST(GREATEST(p_count, 1), 50)
  ) AS m;
$$;

REVOKE ALL   ON FUNCTION api.read_queue_batch(text, int, int) FROM PUBLIC;
REVOKE ALL   ON FUNCTION api.read_queue_batch(text, int, int) FROM authenticated;
REVOKE ALL   ON FUNCTION api.read_queue_batch(text, int, int) FROM anon;
GRANT EXECUTE ON FUNCTION api.read_queue_batch(text, int, int) TO service_role;


-- =============================================================================
-- 12. api.archive_queue_message
--     Arxiva (acknowledge) un missatge processat de qualsevol cua.
--     GRANT: service_role only.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.archive_queue_message(p_queue text, p_msg_id bigint)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pgmq, public
AS $$
  SELECT pgmq.archive(p_queue, p_msg_id);
$$;

REVOKE ALL   ON FUNCTION api.archive_queue_message(text, bigint) FROM PUBLIC;
REVOKE ALL   ON FUNCTION api.archive_queue_message(text, bigint) FROM authenticated;
REVOKE ALL   ON FUNCTION api.archive_queue_message(text, bigint) FROM anon;
GRANT EXECUTE ON FUNCTION api.archive_queue_message(text, bigint) TO service_role;


-- =============================================================================
-- 13. api.set_queue_message_vt
--     Estén el Visibility Timeout d'un missatge per implementar retry amb backoff
--     exponencial sense haver d'arxivar + re-encuar.
--     Requereix pgmq >= 0.14 (disponible a Supabase local CLI).
--     GRANT: service_role only.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.set_queue_message_vt(
  p_queue      text,
  p_msg_id     bigint,
  p_vt_seconds int
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = pgmq, public
AS $$
  SELECT pgmq.set_vt(p_queue, p_msg_id, p_vt_seconds);
$$;

REVOKE ALL   ON FUNCTION api.set_queue_message_vt(text, bigint, int) FROM PUBLIC;
REVOKE ALL   ON FUNCTION api.set_queue_message_vt(text, bigint, int) FROM authenticated;
REVOKE ALL   ON FUNCTION api.set_queue_message_vt(text, bigint, int) FROM anon;
GRANT EXECUTE ON FUNCTION api.set_queue_message_vt(text, bigint, int) TO service_role;


-- =============================================================================
-- 14. api.check_dedup
--     Comprova si un idempotency_key ja ha estat processat per a una cua.
--     GRANT: service_role only.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.check_dedup(p_queue text, p_key text)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM data.processed_messages
    WHERE queue_name = p_queue
      AND idempotency_key = p_key
  );
$$;

REVOKE ALL   ON FUNCTION api.check_dedup(text, text) FROM PUBLIC;
REVOKE ALL   ON FUNCTION api.check_dedup(text, text) FROM authenticated;
REVOKE ALL   ON FUNCTION api.check_dedup(text, text) FROM anon;
GRANT EXECUTE ON FUNCTION api.check_dedup(text, text) TO service_role;


-- =============================================================================
-- 15. api.record_processed
--     Registra un missatge com a processat (per dedup futures).
--     ON CONFLICT DO NOTHING: idempotent.
--     GRANT: service_role only.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.record_processed(
  p_queue  text,
  p_msg_id bigint,
  p_key    text
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = data, public
AS $$
  INSERT INTO data.processed_messages (queue_name, msg_id, idempotency_key)
  VALUES (p_queue, p_msg_id, p_key)
  ON CONFLICT (queue_name, idempotency_key) DO NOTHING;
$$;

REVOKE ALL   ON FUNCTION api.record_processed(text, bigint, text) FROM PUBLIC;
REVOKE ALL   ON FUNCTION api.record_processed(text, bigint, text) FROM authenticated;
REVOKE ALL   ON FUNCTION api.record_processed(text, bigint, text) FROM anon;
GRANT EXECUTE ON FUNCTION api.record_processed(text, bigint, text) TO service_role;


-- =============================================================================
-- 16. api.move_to_dlq
--     Mou un missatge al Dead Letter Queue:
--       a) Insereix a data.dlq_messages
--       b) Notifica tots els owners del tenant amb severity='critical'
--       c) Escriu a data.audit_logs (TASK_DLQ_MOVED)
--     GRANT: service_role only.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.move_to_dlq(
  p_queue          text,
  p_original_msg_id bigint,
  p_payload        jsonb,
  p_attempt_count  smallint,
  p_error          text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid;
BEGIN
  -- a) Inserir a DLQ
  INSERT INTO data.dlq_messages (
    queue_name, original_msg_id, payload, attempt_count, last_error_text, last_error_at
  ) VALUES (
    p_queue, p_original_msg_id, p_payload, p_attempt_count, LEFT(p_error, 2048), now()
  );

  -- b) Notificar owners del tenant (si tenim tenant_id al payload)
  v_tenant_id := (p_payload ->> 'tenant_id')::uuid;

  IF v_tenant_id IS NOT NULL THEN
    INSERT INTO data.notifications (
      tenant_id, user_id, kind, severity,
      title_i18n, body_i18n, deep_link,
      related_entity_type
    )
    SELECT
      v_tenant_id,
      tm.user_id,
      'dlq_error',
      'critical',
      jsonb_build_object(
        'ca', 'Error crític a la cua ' || p_queue,
        'es', 'Error crítico en la cola ' || p_queue,
        'en', 'Critical queue error: ' || p_queue
      ),
      jsonb_build_object(
        'ca', COALESCE(LEFT(p_error, 300), 'Missatge mogut a la cua de fallades'),
        'es', COALESCE(LEFT(p_error, 300), 'Mensaje movido a la cola de fallos'),
        'en', COALESCE(LEFT(p_error, 300), 'Message moved to the dead-letter queue')
      ),
      '/admin/dlq',
      'dlq_message'
    FROM data.tenant_members tm
    WHERE tm.tenant_id = v_tenant_id
      AND tm.role      = 'owner'
      AND tm.site_id   IS NULL
      AND tm.is_active = true;

    -- c) Audit
    PERFORM data.log_audit_event(
      v_tenant_id, NULL, NULL,
      'TASK_DLQ_MOVED',
      'dlq_message', NULL,
      jsonb_build_object(
        'queue_name',      p_queue,
        'original_msg_id', p_original_msg_id,
        'attempt_count',   p_attempt_count,
        'error',           LEFT(p_error, 500)
      )
    );
  END IF;
END;
$$;

REVOKE ALL   ON FUNCTION api.move_to_dlq(text, bigint, jsonb, smallint, text) FROM PUBLIC;
REVOKE ALL   ON FUNCTION api.move_to_dlq(text, bigint, jsonb, smallint, text) FROM authenticated;
REVOKE ALL   ON FUNCTION api.move_to_dlq(text, bigint, jsonb, smallint, text) FROM anon;
GRANT EXECUTE ON FUNCTION api.move_to_dlq(text, bigint, jsonb, smallint, text) TO service_role;


-- =============================================================================
-- 17. api.log_queue_batch_audit
--     Escriu un resum del batch a data.audit_logs (ASYNC_BATCH_PROCESSED).
--     tenant_id = NULL perquè un batch pot afectar múltiples tenants.
--     GRANT: service_role only.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.log_queue_batch_audit(
  p_queue_name text,
  p_total      int,
  p_succeeded  int,
  p_skipped    int,
  p_retried    int,
  p_dlqed      int
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = data, public
AS $$
  INSERT INTO data.audit_logs (
    tenant_id, user_id, site_id,
    action, entity_type, entity_id, payload
  ) VALUES (
    NULL, NULL, NULL,
    'ASYNC_BATCH_PROCESSED',
    'queue_batch', NULL,
    jsonb_build_object(
      'queue_name',  p_queue_name,
      'total',       p_total,
      'succeeded',   p_succeeded,
      'skipped',     p_skipped,
      'retried',     p_retried,
      'dlqed',       p_dlqed,
      'processed_at', now()
    )
  );
$$;

REVOKE ALL   ON FUNCTION api.log_queue_batch_audit(text, int, int, int, int, int) FROM PUBLIC;
REVOKE ALL   ON FUNCTION api.log_queue_batch_audit(text, int, int, int, int, int) FROM authenticated;
REVOKE ALL   ON FUNCTION api.log_queue_batch_audit(text, int, int, int, int, int) FROM anon;
GRANT EXECUTE ON FUNCTION api.log_queue_batch_audit(text, int, int, int, int, int) TO service_role;


-- =============================================================================
-- 18. api.create_calendar_event_with_reminders
--
--     RPC transaccional CQRS: crea un calendar_event + encua recordatoris a
--     'reminders_queue' en una sola transacció atòmica.
--
--     NOTA: la cua 'reminders_queue' es crea a la migració 20260503000003.
--           La funció compila sense la cua; falla a runtime fins que la cua existeixi.
--
--     FIX: COALESCE(array_length(p_reminders, 1), 0) per retornar 0 (no NULL)
--          quan p_reminders és un array buit. array_length() retorna NULL per
--          arrays buits en PostgreSQL, cosa que trencava la resposta JSON.
--
--     p_reminders: array de JSONB amb la forma:
--       [{ "offset_minutes": 60, "channel": "email" }, ...]
-- =============================================================================

CREATE OR REPLACE FUNCTION api.create_calendar_event_with_reminders(
  p_tenant_id    uuid,
  p_entity_type  text,
  p_entity_id    uuid,
  p_title        text,
  p_start_at     timestamptz,
  p_site_id      uuid          DEFAULT NULL,
  p_end_at       timestamptz   DEFAULT NULL,
  p_description  text          DEFAULT NULL,
  p_all_day      boolean       DEFAULT false,
  p_color        text          DEFAULT NULL,
  p_metadata     jsonb         DEFAULT NULL,
  p_reminders    jsonb[]       DEFAULT ARRAY[]::jsonb[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
DECLARE
  v_user_id  uuid := auth.uid();
  v_event_id uuid;
  r          jsonb;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  -- Comprova permís calendar.edit (el mínimo per crear events)
  IF NOT data.jwt_has_permission(p_tenant_id, 'calendar.edit', p_site_id) THEN
    RAISE EXCEPTION 'forbidden: calendar.edit permission required for tenant %', p_tenant_id;
  END IF;

  -- 1. Crear l'event de calendari
  INSERT INTO data.calendar_events (
    tenant_id, site_id, entity_type, entity_id,
    title, description, start_at, end_at, all_day,
    color, metadata, required_permissions, owner_id
  ) VALUES (
    p_tenant_id, p_site_id, p_entity_type, p_entity_id,
    p_title, p_description, p_start_at, p_end_at, COALESCE(p_all_day, false),
    p_color, p_metadata, ARRAY['calendar.view'], v_user_id
  ) RETURNING id INTO v_event_id;

  -- Nota: el trigger trg_audit_calendar_events escriu CALENDAR_EVENT_CREATED a audit_logs.

  -- 2. Encuar recordatoris a 'reminders_queue' (creat a 20260503000003)
  FOREACH r IN ARRAY p_reminders LOOP
    PERFORM pgmq.send(
      'reminders_queue',
      jsonb_build_object(
        'task',             'materialize_reminder',
        'tenant_id',        p_tenant_id,
        'site_id',          p_site_id,
        'actor_user_id',    v_user_id,
        'entity_type',      'calendar_event',
        'entity_id',        v_event_id,
        'idempotency_key',  'rem-' || v_event_id || '-' || COALESCE(r->>'offset_minutes', '0'),
        'payload',          r,
        'enqueued_at',      now()
      )
    );
  END LOOP;

  -- FIX: COALESCE evita retornar NULL quan p_reminders és buit
  -- (array_length retorna NULL per a arrays buits, no 0)
  RETURN jsonb_build_object(
    'event_id',    v_event_id,
    'reminders',   COALESCE(array_length(p_reminders, 1), 0)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_calendar_event_with_reminders(
  uuid, text, uuid, text, timestamptz, uuid, timestamptz, text, boolean, text, jsonb, jsonb[]
) TO authenticated;

COMMENT ON FUNCTION api.create_calendar_event_with_reminders IS
  'Crea un event de calendari i encua els seus recordatoris a reminders_queue '
  '(migració 20260503000003) en una sola transacció atòmica. '
  'Patró canònic per a qualsevol mòdul que crea events amb recordatoris. '
  'FIX integrat: reminders count retorna 0 (no NULL) per arrays buits '
  '(array_length() retorna NULL en PostgreSQL per arrays buits).';
