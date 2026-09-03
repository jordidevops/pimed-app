-- =============================================================================
-- Notification Engine — F1 Worker
-- =============================================================================
-- Routing context RPC, dispatcher pg_cron, cleanup claims.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. RPC: resolve_notification_routing_context
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.resolve_notification_routing_context(
  p_tenant_id      uuid,
  p_event_code     text,
  p_recipient_id   uuid,
  p_recipient_kind data.notification_recipient_kind
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_prefs          jsonb;
  v_catalog        jsonb;
  v_opted_out      text[] := ARRAY[]::text[];
  v_twilio_enabled boolean := false;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT jsonb_build_object(
    'channelsEnabled',  to_jsonb(x.channels_enabled),
    'preferredChannel', x.preferred_channel,
    'quietHours',       x.quiet_hours,
    'locale',           COALESCE(x.locale, 'ca')
  )
  INTO v_prefs
  FROM (
    SELECT channels_enabled, preferred_channel, quiet_hours, locale
    FROM data.notification_preferences
    WHERE tenant_id = p_tenant_id
      AND recipient_kind = p_recipient_kind
      AND recipient_id = p_recipient_id
      AND (event_code = p_event_code OR event_code IS NULL)
    ORDER BY (event_code = p_event_code) DESC, updated_at DESC
    LIMIT 1
  ) AS x;

  SELECT jsonb_build_object(
    'defaultChannels',  to_jsonb(default_channels),
    'requiresLegal',    requires_legal,
    'entityType',       entity_type,
    'deepLinkTemplate', deep_link_template,
    'digestEligible',   digest_eligible
  )
  INTO v_catalog
  FROM data.notification_event_catalog
  WHERE event_code = p_event_code;

  IF p_recipient_kind = 'contact' AND p_recipient_id IS NOT NULL THEN
    SELECT COALESCE(array_agg(DISTINCT c.channel::text), ARRAY[]::text[])
    INTO v_opted_out
    FROM data.contact_notification_consents c
    WHERE c.tenant_id = p_tenant_id
      AND c.contact_id = p_recipient_id
      AND c.opted_out = true
      AND (c.event_code = p_event_code OR c.event_code IS NULL);
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM data.tenant_twilio_config t
    WHERE t.tenant_id = p_tenant_id
      AND t.is_enabled = true
  ) INTO v_twilio_enabled;

  RETURN jsonb_build_object(
    'prefs',            COALESCE(v_prefs, '{}'::jsonb),
    'eventMeta',        COALESCE(v_catalog, '{}'::jsonb),
    'optedOutChannels', to_jsonb(v_opted_out),
    'twilioEnabled',    v_twilio_enabled
  );
END;
$$;

REVOKE ALL ON FUNCTION api.resolve_notification_routing_context(
  uuid, text, uuid, data.notification_recipient_kind
) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.resolve_notification_routing_context(
  uuid, text, uuid, data.notification_recipient_kind
) FROM authenticated;
REVOKE ALL ON FUNCTION api.resolve_notification_routing_context(
  uuid, text, uuid, data.notification_recipient_kind
) FROM anon;
GRANT EXECUTE ON FUNCTION api.resolve_notification_routing_context(
  uuid, text, uuid, data.notification_recipient_kind
) TO service_role;

-- -----------------------------------------------------------------------------
-- 2. Cleanup claims resolts
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.cleanup_notification_delivery_claims()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_deleted integer;
BEGIN
  DELETE FROM data.notification_delivery_claims
  WHERE status IN ('sent', 'failed')
    AND claim_expires_at < now() - interval '7 days';

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION data.cleanup_notification_delivery_claims() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.cleanup_notification_delivery_claims() TO service_role;

-- -----------------------------------------------------------------------------
-- 3. Dispatcher: process-notification-queue
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.invoke_notification_queue_worker(
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
    RAISE WARNING 'invoke_notification_queue_worker: pg_net not installed. Skipping.';
    RETURN -2;
  END IF;

  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets WHERE name = 'app_supabase_url' LIMIT 1;

  SELECT decrypted_secret INTO v_service_key
  FROM vault.decrypted_secrets WHERE name = 'app_service_role_key' LIMIT 1;

  IF v_supabase_url IS NULL OR v_service_key IS NULL THEN
    RAISE WARNING 'invoke_notification_queue_worker: vault secrets not configured. Skipping.';
    RETURN -1;
  END IF;

  BEGIN
    SELECT extensions.http_post(
      url     := v_supabase_url || '/functions/v1/process-notification-queue',
      headers := jsonb_build_object(
        'Content-Type',  'application/json',
        'Authorization', 'Bearer ' || v_service_key
      ),
      body    := jsonb_build_object('batch_size', COALESCE(p_batch_size, 50)),
      timeout_milliseconds := 30000
    ) INTO v_request_id;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'invoke_notification_queue_worker: http_post failed: %', SQLERRM;
    RETURN NULL;
  END;

  RETURN v_request_id;
END;
$$;

REVOKE ALL ON FUNCTION data.invoke_notification_queue_worker(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.invoke_notification_queue_worker(integer) FROM authenticated;
REVOKE ALL ON FUNCTION data.invoke_notification_queue_worker(integer) FROM anon;

COMMENT ON FUNCTION data.invoke_notification_queue_worker IS
  'Dispatcher pg_cron → Edge Function process-notification-queue via pg_net.';

-- -----------------------------------------------------------------------------
-- 4. pg_cron jobs
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('process-notification-queue-worker')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'process-notification-queue-worker'
    );

    PERFORM cron.schedule(
      'process-notification-queue-worker',
      '*/1 * * * *',
      'SELECT data.invoke_notification_queue_worker(50)'
    );

    PERFORM cron.unschedule('notification_delivery_claims_cleanup')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'notification_delivery_claims_cleanup'
    );

    PERFORM cron.schedule(
      'notification_delivery_claims_cleanup',
      '0 4 * * *',
      'SELECT data.cleanup_notification_delivery_claims()'
    );
  END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';
