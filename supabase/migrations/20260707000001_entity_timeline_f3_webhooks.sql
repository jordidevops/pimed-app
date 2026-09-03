-- =============================================================================
-- Entity Timeline — Fase 3: Webhooks (taules, PGMQ, triggers, RPCs)
-- =============================================================================

SELECT pgmq.create('webhook_dispatch_queue');

-- -----------------------------------------------------------------------------
-- Taules
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS data.tenant_webhooks (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  label         text NOT NULL,
  endpoint_url  text NOT NULL,
  secret        text NOT NULL,
  events        text[] NOT NULL DEFAULT ARRAY['timeline.comment.created']::text[],
  entity_types  text[],
  is_active     boolean NOT NULL DEFAULT true,
  created_by    uuid REFERENCES data.profiles(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT tenant_webhooks_label_not_empty CHECK (length(trim(label)) > 0),
  CONSTRAINT tenant_webhooks_endpoint_https CHECK (endpoint_url ~* '^https://')
);

CREATE INDEX IF NOT EXISTS idx_tenant_webhooks_tenant_active
  ON data.tenant_webhooks (tenant_id, is_active);

CREATE TABLE IF NOT EXISTS data.webhook_delivery_log (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  webhook_id      uuid NOT NULL REFERENCES data.tenant_webhooks(id) ON DELETE CASCADE,
  event_type      text NOT NULL,
  payload         jsonb NOT NULL DEFAULT '{}'::jsonb,
  status          text NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'delivered', 'failed')),
  attempts        integer NOT NULL DEFAULT 0,
  last_attempt_at timestamptz,
  response_status integer,
  response_body   text,
  error_message   text,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_webhook_delivery_log_webhook_created
  ON data.webhook_delivery_log (webhook_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_webhook_delivery_log_tenant_created
  ON data.webhook_delivery_log (tenant_id, created_at DESC);

ALTER TABLE data.tenant_webhooks ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.webhook_delivery_log ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE data.tenant_webhooks FROM PUBLIC;
REVOKE ALL ON TABLE data.webhook_delivery_log FROM PUBLIC;
GRANT ALL ON TABLE data.tenant_webhooks TO service_role;
GRANT ALL ON TABLE data.webhook_delivery_log TO service_role;

CREATE TRIGGER trg_tenant_webhooks_updated_at
  BEFORE UPDATE ON data.tenant_webhooks
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

-- -----------------------------------------------------------------------------
-- Validació bàsica d'endpoint (SSRF — capa SQL; el worker revalida)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.is_allowed_webhook_endpoint(p_url text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_host text;
BEGIN
  IF p_url IS NULL OR length(trim(p_url)) = 0 THEN
    RETURN false;
  END IF;

  IF p_url !~* '^https://' THEN
    RETURN false;
  END IF;

  v_host := lower(substring(p_url from '^https://([^/:]+)'));

  IF v_host IS NULL OR length(v_host) = 0 THEN
    RETURN false;
  END IF;

  IF v_host IN ('localhost', '127.0.0.1', '0.0.0.0', '::1', 'metadata.google.internal') THEN
    RETURN false;
  END IF;

  IF v_host ~ '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.)' THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$$;

-- -----------------------------------------------------------------------------
-- Autorització settings (owner/manager)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.require_tenant_webhook_admin(p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_role text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  v_role := data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role';

  IF v_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION data.require_tenant_webhook_admin(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.require_tenant_webhook_admin(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- Payload estàndard (schema_version 1)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.build_timeline_webhook_payload(
  p_comment_id  uuid,
  p_event_type  text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_comment record;
  v_author_name text;
BEGIN
  SELECT c.*, p.full_name AS author_full_name
  INTO v_comment
  FROM data.entity_comments c
  LEFT JOIN data.profiles p ON p.id = c.user_id
  WHERE c.id = p_comment_id;

  IF NOT FOUND OR v_comment.deleted_at IS NOT NULL THEN
    RETURN NULL;
  END IF;

  v_author_name := coalesce(v_comment.author_full_name, 'Algú');

  RETURN jsonb_build_object(
    'schema_version', 1,
    'event',          p_event_type,
    'tenant_id',      v_comment.tenant_id,
    'entity_type',    v_comment.entity_type,
    'entity_id',      v_comment.entity_id,
    'entity_label',   data.entity_timeline_entity_label(v_comment.entity_type, v_comment.entity_id),
    'actor', jsonb_build_object(
      'id',   v_comment.user_id,
      'name', v_author_name,
      'type', coalesce(v_comment.actor_type, 'user')
    ),
    'comment', jsonb_build_object(
      'id',                v_comment.id,
      'content',           data.humanize_entity_comment_mentions(v_comment.content),
      'content_raw',       v_comment.content,
      'is_task',           v_comment.is_task,
      'is_ai_context_note', v_comment.is_ai_context_note,
      'resolved_at',       v_comment.resolved_at,
      'mentions',          to_jsonb(coalesce(v_comment.mentions, ARRAY[]::uuid[]))
    ),
    'timestamp',  v_comment.created_at,
    'app_path',   data.entity_timeline_deep_link(
      v_comment.entity_type, v_comment.entity_id, v_comment.id
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION data.build_timeline_webhook_payload(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.build_timeline_webhook_payload(uuid, text) TO service_role;

-- -----------------------------------------------------------------------------
-- Enqueue per comentari + event
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.enqueue_entity_comment_webhook_events(
  p_comment_id  uuid,
  p_event_type  text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
DECLARE
  v_payload   jsonb;
  v_comment   record;
  v_webhook   record;
  v_log_id    uuid;
BEGIN
  v_payload := data.build_timeline_webhook_payload(p_comment_id, p_event_type);
  IF v_payload IS NULL THEN
    RETURN;
  END IF;

  SELECT tenant_id, entity_type INTO v_comment
  FROM data.entity_comments
  WHERE id = p_comment_id;

  FOR v_webhook IN
    SELECT w.*
    FROM data.tenant_webhooks w
    WHERE w.tenant_id = v_comment.tenant_id
      AND w.is_active = true
      AND p_event_type = ANY (w.events)
      AND (
        w.entity_types IS NULL
        OR array_length(w.entity_types, 1) IS NULL
        OR v_comment.entity_type = ANY (w.entity_types)
      )
  LOOP
    BEGIN
      INSERT INTO data.webhook_delivery_log (
        tenant_id, webhook_id, event_type, payload, status
      ) VALUES (
        v_comment.tenant_id,
        v_webhook.id,
        p_event_type,
        v_payload,
        'pending'
      )
      RETURNING id INTO v_log_id;

      PERFORM pgmq.send('webhook_dispatch_queue', jsonb_build_object(
        'task',            'dispatch_webhook',
        'tenant_id',       v_comment.tenant_id,
        'idempotency_key', 'wh:' || v_webhook.id::text || ':' || p_event_type || ':' || p_comment_id::text,
        'delivery_log_id', v_log_id,
        'webhook_id',      v_webhook.id,
        'event_type',      p_event_type
      ));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'enqueue_entity_comment_webhook_events: %', SQLERRM;
    END;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION data.enqueue_entity_comment_webhook_events(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.enqueue_entity_comment_webhook_events(uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION data.trg_entity_comments_enqueue_webhooks()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF TG_OP = 'INSERT' AND NEW.deleted_at IS NULL THEN
    PERFORM data.enqueue_entity_comment_webhook_events(NEW.id, 'timeline.comment.created');
    IF coalesce(array_length(NEW.mentions, 1), 0) > 0 THEN
      PERFORM data.enqueue_entity_comment_webhook_events(NEW.id, 'timeline.mention.created');
    END IF;
  ELSIF TG_OP = 'UPDATE'
    AND NEW.deleted_at IS NULL
    AND NEW.is_task = true
    AND OLD.resolved_at IS NULL
    AND NEW.resolved_at IS NOT NULL THEN
    PERFORM data.enqueue_entity_comment_webhook_events(NEW.id, 'timeline.task.resolved');
  END IF;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'trg_entity_comments_enqueue_webhooks: %', SQLERRM;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_entity_comments_enqueue_webhooks ON data.entity_comments;
CREATE TRIGGER trg_entity_comments_enqueue_webhooks
  AFTER INSERT OR UPDATE OF resolved_at ON data.entity_comments
  FOR EACH ROW EXECUTE FUNCTION data.trg_entity_comments_enqueue_webhooks();

-- -----------------------------------------------------------------------------
-- RPCs UI (api.*)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.list_tenant_webhooks()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  PERFORM data.require_tenant_webhook_admin(v_tenant_id);

  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
      'id',            w.id,
      'label',         w.label,
      'endpoint_url',  w.endpoint_url,
      'events',        to_jsonb(w.events),
      'entity_types',  CASE WHEN w.entity_types IS NULL THEN NULL ELSE to_jsonb(w.entity_types) END,
      'is_active',     w.is_active,
      'secret_hint',   'whsec_…' || right(w.secret, 4),
      'created_at',    w.created_at,
      'updated_at',    w.updated_at
    ) ORDER BY w.created_at DESC)
    FROM data.tenant_webhooks w
    WHERE w.tenant_id = v_tenant_id
  ), '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_tenant_webhooks() TO authenticated;

CREATE OR REPLACE FUNCTION api.upsert_tenant_webhook(
  p_id            uuid DEFAULT NULL,
  p_label         text DEFAULT NULL,
  p_endpoint_url  text DEFAULT NULL,
  p_events        text[] DEFAULT NULL,
  p_entity_types  text[] DEFAULT NULL,
  p_is_active     boolean DEFAULT true,
  p_rotate_secret boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id   uuid := data.active_tenant_id();
  v_user_id     uuid := auth.uid();
  v_secret      text;
  v_row         data.tenant_webhooks%ROWTYPE;
  v_events      text[] := coalesce(p_events, ARRAY['timeline.comment.created']::text[]);
BEGIN
  IF v_tenant_id IS NULL OR v_user_id IS NULL THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  PERFORM data.require_tenant_webhook_admin(v_tenant_id);

  IF p_label IS NULL OR length(trim(p_label)) = 0 THEN
    RAISE EXCEPTION 'label_required';
  END IF;

  IF p_endpoint_url IS NULL OR NOT data.is_allowed_webhook_endpoint(p_endpoint_url) THEN
    RAISE EXCEPTION 'invalid_endpoint_url';
  END IF;

  IF p_id IS NULL THEN
    v_secret := 'whsec_' || replace(gen_random_uuid()::text, '-', '')
      || replace(gen_random_uuid()::text, '-', '');

    INSERT INTO data.tenant_webhooks (
      tenant_id, label, endpoint_url, secret, events, entity_types,
      is_active, created_by
    ) VALUES (
      v_tenant_id, trim(p_label), trim(p_endpoint_url), v_secret,
      v_events, p_entity_types, coalesce(p_is_active, true), v_user_id
    )
    RETURNING * INTO v_row;
  ELSE
    SELECT * INTO v_row
    FROM data.tenant_webhooks
    WHERE id = p_id AND tenant_id = v_tenant_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'webhook_not_found';
    END IF;

    v_secret := CASE
      WHEN p_rotate_secret THEN
        'whsec_' || replace(gen_random_uuid()::text, '-', '')
          || replace(gen_random_uuid()::text, '-', '')
      ELSE v_row.secret
    END;

    UPDATE data.tenant_webhooks SET
      label         = trim(p_label),
      endpoint_url  = trim(p_endpoint_url),
      secret        = v_secret,
      events        = v_events,
      entity_types  = p_entity_types,
      is_active     = coalesce(p_is_active, is_active),
      updated_at    = now()
    WHERE id = p_id
    RETURNING * INTO v_row;
  END IF;

  RETURN jsonb_build_object(
    'id',            v_row.id,
    'label',         v_row.label,
    'endpoint_url',  v_row.endpoint_url,
    'events',        to_jsonb(v_row.events),
    'entity_types',  CASE WHEN v_row.entity_types IS NULL THEN NULL ELSE to_jsonb(v_row.entity_types) END,
    'is_active',     v_row.is_active,
    'secret',        CASE WHEN p_id IS NULL OR p_rotate_secret THEN v_row.secret ELSE NULL END,
    'secret_hint',   'whsec_…' || right(v_row.secret, 4),
    'created_at',    v_row.created_at,
    'updated_at',    v_row.updated_at
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_tenant_webhook(
  uuid, text, text, text[], text[], boolean, boolean
) TO authenticated;

CREATE OR REPLACE FUNCTION api.delete_tenant_webhook(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  PERFORM data.require_tenant_webhook_admin(v_tenant_id);

  DELETE FROM data.tenant_webhooks
  WHERE id = p_id AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'webhook_not_found';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION api.delete_tenant_webhook(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION api.list_webhook_delivery_log(
  p_webhook_id uuid DEFAULT NULL,
  p_limit      integer DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  PERFORM data.require_tenant_webhook_admin(v_tenant_id);

  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
      'id',              l.id,
      'webhook_id',      l.webhook_id,
      'event_type',      l.event_type,
      'status',          l.status,
      'attempts',        l.attempts,
      'response_status', l.response_status,
      'error_message',   l.error_message,
      'created_at',      l.created_at,
      'last_attempt_at', l.last_attempt_at
    ) ORDER BY l.created_at DESC)
    FROM (
      SELECT *
      FROM data.webhook_delivery_log
      WHERE tenant_id = v_tenant_id
        AND (p_webhook_id IS NULL OR webhook_id = p_webhook_id)
      ORDER BY created_at DESC
      LIMIT greatest(1, least(coalesce(p_limit, 20), 100))
    ) l
  ), '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_webhook_delivery_log(uuid, integer) TO authenticated;

CREATE OR REPLACE FUNCTION api.test_tenant_webhook(p_webhook_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_webhook   data.tenant_webhooks%ROWTYPE;
  v_payload   jsonb;
  v_log_id    uuid;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  PERFORM data.require_tenant_webhook_admin(v_tenant_id);

  SELECT * INTO v_webhook
  FROM data.tenant_webhooks
  WHERE id = p_webhook_id AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'webhook_not_found';
  END IF;

  v_payload := jsonb_build_object(
    'schema_version', 1,
    'event',          'timeline.webhook.test',
    'tenant_id',      v_tenant_id,
    'entity_type',    'employee',
    'entity_id',      '00000000-0000-0000-0000-000000000000',
    'entity_label',   'Prova webhook',
    'actor',          jsonb_build_object('id', auth.uid(), 'name', 'Test', 'type', 'user'),
    'comment',        jsonb_build_object(
      'id', '00000000-0000-0000-0000-000000000000',
      'content', 'Això és un payload de prova des de la configuració.',
      'is_task', false
    ),
    'timestamp',      now(),
    'app_path',       '/employees/00000000-0000-0000-0000-000000000000?tab=activity'
  );

  INSERT INTO data.webhook_delivery_log (
    tenant_id, webhook_id, event_type, payload, status
  ) VALUES (
    v_tenant_id, v_webhook.id, 'timeline.webhook.test', v_payload, 'pending'
  )
  RETURNING id INTO v_log_id;

  PERFORM pgmq.send('webhook_dispatch_queue', jsonb_build_object(
    'task',            'dispatch_webhook',
    'tenant_id',       v_tenant_id,
    'idempotency_key', 'wh-test:' || v_webhook.id::text || ':' || v_log_id::text,
    'delivery_log_id', v_log_id,
    'webhook_id',      v_webhook.id,
    'event_type',      'timeline.webhook.test'
  ));

  RETURN v_log_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.test_tenant_webhook(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- RPCs worker (service_role)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.get_webhook_dispatch_context(
  p_webhook_id      uuid,
  p_delivery_log_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_webhook data.tenant_webhooks%ROWTYPE;
  v_log     data.webhook_delivery_log%ROWTYPE;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_webhook FROM data.tenant_webhooks WHERE id = p_webhook_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_log
  FROM data.webhook_delivery_log
  WHERE id = p_delivery_log_id AND webhook_id = p_webhook_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'webhook_id',    v_webhook.id,
    'tenant_id',     v_webhook.tenant_id,
    'endpoint_url',  v_webhook.endpoint_url,
    'secret',        v_webhook.secret,
    'event_type',    v_log.event_type,
    'payload',       v_log.payload,
    'attempts',      v_log.attempts
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_webhook_dispatch_context(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_webhook_dispatch_context(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION api.complete_webhook_delivery(
  p_delivery_log_id uuid,
  p_status          text,
  p_response_status integer DEFAULT NULL,
  p_response_body   text DEFAULT NULL,
  p_error_message   text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_status NOT IN ('delivered', 'failed') THEN
    RAISE EXCEPTION 'invalid_status';
  END IF;

  UPDATE data.webhook_delivery_log SET
    status          = p_status,
    attempts        = attempts + 1,
    last_attempt_at = now(),
    response_status = p_response_status,
    response_body   = left(coalesce(p_response_body, ''), 4000),
    error_message   = left(coalesce(p_error_message, ''), 1000)
  WHERE id = p_delivery_log_id;
END;
$$;

REVOKE ALL ON FUNCTION api.complete_webhook_delivery(uuid, text, integer, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.complete_webhook_delivery(uuid, text, integer, text, text) TO service_role;

-- -----------------------------------------------------------------------------
-- Dispatcher pg_cron → worker
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.invoke_webhook_queue_worker(
  p_batch_size integer DEFAULT 50
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
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RAISE WARNING 'invoke_webhook_queue_worker: pg_net not installed. Skipping.';
    RETURN -2;
  END IF;

  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets WHERE name = 'app_supabase_url' LIMIT 1;

  SELECT decrypted_secret INTO v_service_key
  FROM vault.decrypted_secrets WHERE name = 'app_service_role_key' LIMIT 1;

  IF v_supabase_url IS NULL OR v_service_key IS NULL THEN
    RAISE WARNING 'invoke_webhook_queue_worker: vault secrets not configured. Skipping.';
    RETURN -1;
  END IF;

  BEGIN
    SELECT extensions.http_post(
      url     := v_supabase_url || '/functions/v1/process-webhook-queue',
      headers := jsonb_build_object(
        'Content-Type',  'application/json',
        'Authorization', 'Bearer ' || v_service_key
      ),
      body    := jsonb_build_object('batch_size', COALESCE(p_batch_size, 50)),
      timeout_milliseconds := 30000
    ) INTO v_request_id;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'invoke_webhook_queue_worker: http_post failed: %', SQLERRM;
    RETURN NULL;
  END;

  RETURN v_request_id;
END;
$$;

REVOKE ALL ON FUNCTION data.invoke_webhook_queue_worker(integer) FROM PUBLIC;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('process-webhook-queue-worker')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'process-webhook-queue-worker'
    );

    PERFORM cron.schedule(
      'process-webhook-queue-worker',
      '*/1 * * * *',
      'SELECT data.invoke_webhook_queue_worker(50)'
    );
  END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';
