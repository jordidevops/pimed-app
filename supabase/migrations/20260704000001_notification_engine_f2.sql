-- =============================================================================
-- Notification Engine — F2
-- UI settings RPCs, LEAD_RECEIVED, signing via motor, push BYO service RPC
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Catàleg: nous esdeveniments F2
-- -----------------------------------------------------------------------------
INSERT INTO data.notification_event_catalog (
  event_code, category, entity_type, deep_link_template,
  default_channels, requires_legal, digest_eligible, description
) VALUES
  (
    'LEAD_RECEIVED', 'operations', 'public_lead', '/public-portal',
    '{in_app,push,email}', false, false,
    'Nou lead al portal públic (owners/managers)'
  ),
  (
    'NOTIFICATION_TEST', 'system', 'system', NULL,
    '{in_app,push,email}', false, false,
    'Notificació de prova des de configuració'
  )
ON CONFLICT (event_code) DO NOTHING;

UPDATE data.notification_event_catalog
SET deep_link_template = '/public-portal'
WHERE event_code = 'LEAD_RECEIVED';

-- -----------------------------------------------------------------------------
-- 2. Vista catàleg (UI)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.notification_event_catalog
  WITH (security_invoker = true) AS
SELECT
  event_code,
  category,
  entity_type,
  deep_link_template,
  default_channels,
  requires_legal,
  digest_eligible,
  description
FROM data.notification_event_catalog;

GRANT SELECT ON api.notification_event_catalog TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. Encuat leads → motor (per owner/manager)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.enqueue_lead_received_notifications(
  p_tenant_id        uuid,
  p_lead_id          uuid,
  p_public_site_id   uuid,
  p_site_name        text DEFAULT 'Portal públic',
  p_skip_owners      boolean DEFAULT false
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
DECLARE
  v_member   record;
  v_count    integer := 0;
  v_site     text := COALESCE(NULLIF(trim(p_site_name), ''), 'Portal públic');
BEGIN
  IF p_skip_owners THEN
    RETURN 0;
  END IF;

  FOR v_member IN
    SELECT tm.user_id
    FROM data.tenant_members tm
    WHERE tm.tenant_id = p_tenant_id
      AND tm.role IN ('owner', 'manager')
      AND tm.site_id IS NULL
      AND tm.is_active = true
  LOOP
    BEGIN
      PERFORM data.enqueue_notification_dispatch(jsonb_build_object(
        'tenantId',       p_tenant_id,
        'eventType',      'LEAD_RECEIVED',
        'correlationId',  'lead:' || p_lead_id::text || ':notify:' || v_member.user_id::text,
        'recipient',      jsonb_build_object('kind', 'tenant_member', 'userId', v_member.user_id),
        'entityType',     'public_lead',
        'entityId',       p_lead_id,
        'payload',        jsonb_build_object(
          'site_name',      v_site,
          'public_site_id', p_public_site_id,
          'summary',        'Nou lead a ' || v_site
        )
      ));
      v_count := v_count + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'enqueue_lead_received_notifications: %', SQLERRM;
    END;
  END LOOP;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION data.enqueue_lead_received_notifications(uuid, uuid, uuid, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.enqueue_lead_received_notifications(uuid, uuid, uuid, text, boolean) TO service_role;

-- -----------------------------------------------------------------------------
-- 4. submit_public_lead: owners via motor + postprocess a leads_queue
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.submit_public_lead(
  p_public_site_id   uuid,
  p_idempotency_key  text,
  p_name             text    DEFAULT NULL,
  p_email            text    DEFAULT NULL,
  p_phone            text    DEFAULT NULL,
  p_message          text    DEFAULT NULL,
  p_source_url       text    DEFAULT NULL,
  p_source_page_slug text    DEFAULT NULL,
  p_metadata         jsonb   DEFAULT '{}'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_id              uuid;
  v_tenant_id       uuid;
  v_site_status     text;
  v_enabled         bool;
  v_lock_key        bigint;
  v_site_name       text;
  v_ack_copy        text;
  v_skip_owners     boolean := false;
BEGIN
  SELECT ps.tenant_id, ps.status, t.public_portal_enabled, ps.name, ps.lead_ack_copy_email
  INTO v_tenant_id, v_site_status, v_enabled, v_site_name, v_ack_copy
  FROM data.public_sites ps
  JOIN data.tenants t ON t.id = ps.tenant_id
  WHERE ps.id = p_public_site_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found' USING HINT = 'El portal públic no existeix.';
  END IF;

  IF v_site_status <> 'published' THEN
    RAISE EXCEPTION 'site_not_published'
      USING HINT = 'El portal públic no accepta submissions en aquest moment.';
  END IF;

  IF NOT COALESCE(v_enabled, false) THEN
    RAISE EXCEPTION 'module_not_enabled'
      USING HINT = 'El portal públic no accepta submissions en aquest moment.';
  END IF;

  IF COALESCE(trim(p_name), '') = ''
    AND COALESCE(trim(p_email), '') = ''
    AND COALESCE(trim(p_phone), '') = ''
    AND COALESCE(trim(p_message), '') = ''
  THEN
    RAISE EXCEPTION 'empty_lead'
      USING HINT = 'Cal proporcionar almenys nom, email, telèfon o missatge.';
  END IF;

  v_skip_owners := COALESCE(NULLIF(trim(v_ack_copy), ''), '') <> '';

  v_lock_key := hashtextextended(v_tenant_id::text || ':' || p_idempotency_key, 0);
  PERFORM pg_advisory_xact_lock(v_lock_key);

  INSERT INTO data.public_leads (
    public_site_id, tenant_id, idempotency_key,
    name, email, phone, message, source_url, source_page_slug, metadata, status
  ) VALUES (
    p_public_site_id, v_tenant_id, p_idempotency_key,
    nullif(trim(p_name), ''),
    nullif(lower(trim(p_email)), ''),
    nullif(trim(p_phone), ''),
    nullif(trim(p_message), ''),
    p_source_url, p_source_page_slug,
    COALESCE(p_metadata, '{}'), 'new'
  )
  ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT id INTO v_id
    FROM data.public_leads
    WHERE tenant_id = v_tenant_id AND idempotency_key = p_idempotency_key;

    IF v_id IS NULL THEN
      RAISE EXCEPTION 'idempotency_lookup_failed';
    END IF;

    RETURN v_id;
  END IF;

  PERFORM data.log_audit_event(
    v_tenant_id, NULL, NULL,
    'LEAD_SUBMITTED', 'public_lead', v_id,
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

  PERFORM data.enqueue_lead_received_notifications(
    v_tenant_id, v_id, p_public_site_id, v_site_name, v_skip_owners
  );

  BEGIN
    PERFORM pgmq.send(
      'leads_notification_queue',
      jsonb_build_object(
        'task',            'lead_postprocess',
        'tenant_id',       v_tenant_id,
        'idempotency_key', 'lead-postprocess-' || v_id,
        'enqueued_at',     now(),
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
    RAISE WARNING 'submit_public_lead: lead_postprocess enqueue failed: %', SQLERRM;
  END;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.submit_public_lead(uuid, text, text, text, text, text, text, text, jsonb)
  TO anon, authenticated;

-- -----------------------------------------------------------------------------
-- 5. Preferències de l'usuari actual
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_my_notification_preferences()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_user_id   uuid := auth.uid();
  v_tenant_id uuid := data.active_tenant_id();
  v_events    jsonb := '[]'::jsonb;
  v_row       record;
BEGIN
  IF v_user_id IS NULL OR v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  FOR v_row IN
    SELECT
      c.event_code,
      c.description,
      c.default_channels,
      c.deep_link_template,
      p.channels_enabled AS custom_channels,
      p.locale,
      (p.id IS NOT NULL) AS has_custom
    FROM data.notification_event_catalog c
    LEFT JOIN data.notification_preferences p
      ON p.tenant_id = v_tenant_id
     AND p.recipient_kind = 'tenant_member'
     AND p.recipient_id = v_user_id
     AND p.event_code IS NOT DISTINCT FROM c.event_code
    WHERE c.event_code NOT IN ('DLQ_ERROR', 'NOTIFICATION_TEST')
      AND c.default_channels && ARRAY['in_app', 'push', 'email']::data.notification_channel[]
    ORDER BY c.category, c.event_code
  LOOP
    v_events := v_events || jsonb_build_array(jsonb_build_object(
      'event_code',       v_row.event_code,
      'description',      v_row.description,
      'default_channels', to_jsonb(v_row.default_channels),
      'channels_enabled', to_jsonb(
        COALESCE(v_row.custom_channels, v_row.default_channels)
      ),
      'has_custom',       v_row.has_custom,
      'deep_link_template', v_row.deep_link_template
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'tenant_id', v_tenant_id,
    'user_id',   v_user_id,
    'locale',    COALESCE(
      (SELECT locale FROM data.notification_preferences
       WHERE tenant_id = v_tenant_id
         AND recipient_kind = 'tenant_member'
         AND recipient_id = v_user_id
         AND event_code IS NULL
       LIMIT 1),
      'ca'
    ),
    'events', v_events
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_my_notification_preferences() TO authenticated;

CREATE OR REPLACE FUNCTION api.upsert_my_notification_preference(
  p_event_code        text,
  p_channels_enabled  data.notification_channel[],
  p_locale            text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_user_id   uuid := auth.uid();
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF v_user_id IS NULL OR v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.notification_event_catalog WHERE event_code = p_event_code
  ) THEN
    RAISE EXCEPTION 'unknown_event_code';
  END IF;

  INSERT INTO data.notification_preferences (
    tenant_id, recipient_kind, recipient_id, event_code,
    channels_enabled, locale
  ) VALUES (
    v_tenant_id, 'tenant_member', v_user_id, p_event_code,
    p_channels_enabled, COALESCE(NULLIF(trim(p_locale), ''), 'ca')
  )
  ON CONFLICT (tenant_id, recipient_kind, recipient_id, event_code)
  WHERE recipient_kind = 'tenant_member' AND event_code IS NOT NULL
  DO UPDATE SET
    channels_enabled = EXCLUDED.channels_enabled,
    locale = COALESCE(EXCLUDED.locale, data.notification_preferences.locale),
    updated_at = now();
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_my_notification_preference(text, data.notification_channel[], text)
  TO authenticated;

-- -----------------------------------------------------------------------------
-- 6. Notificació de prova
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.send_test_notification(
  p_channels data.notification_channel[] DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
DECLARE
  v_user_id   uuid := auth.uid();
  v_tenant_id uuid := data.active_tenant_id();
  v_channels  data.notification_channel[];
BEGIN
  IF v_user_id IS NULL OR v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.tenant_members
    WHERE tenant_id = v_tenant_id AND user_id = v_user_id AND is_active = true
  ) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  v_channels := COALESCE(
    p_channels,
    ARRAY['in_app', 'push', 'email']::data.notification_channel[]
  );

  RETURN data.enqueue_notification_dispatch(jsonb_build_object(
    'tenantId',       v_tenant_id,
    'eventType',      'NOTIFICATION_TEST',
    'correlationId',  'test:' || v_user_id::text || ':' || extract(epoch from now())::bigint::text,
    'recipient',      jsonb_build_object('kind', 'tenant_member', 'userId', v_user_id),
    'channelOverride', to_jsonb(v_channels),
    'payload',        jsonb_build_object(
      'summary', 'Aquesta és una notificació de prova del motor de notificacions.'
    )
  ));
END;
$$;

GRANT EXECUTE ON FUNCTION api.send_test_notification(data.notification_channel[]) TO authenticated;

-- -----------------------------------------------------------------------------
-- 7. Twilio BYO — lectura estat (sense secrets)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_tenant_twilio_config()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_row       data.tenant_twilio_config%ROWTYPE;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_active_tenant';
  END IF;

  IF NOT (
    data.jwt_user_tenants() ? v_tenant_id::text
    AND (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_row FROM data.tenant_twilio_config WHERE tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('configured', false);
  END IF;

  RETURN jsonb_build_object(
    'configured',            true,
    'account_sid',           v_row.account_sid,
    'sms_from_number',       v_row.sms_from_number,
    'whatsapp_from_number',  v_row.whatsapp_from_number,
    'messaging_service_sid', v_row.messaging_service_sid,
    'is_enabled',            v_row.is_enabled,
    'is_verified',           v_row.is_verified,
    'last_verified_at',      v_row.last_verified_at,
    'last_error_code',       v_row.last_error_code,
    'last_error_at',         v_row.last_error_at
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_tenant_twilio_config() TO authenticated;

-- -----------------------------------------------------------------------------
-- 8. Push BYO — upsert + lectura estat + service credentials
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.upsert_tenant_push_config(
  p_onesignal_app_id  text,
  p_rest_api_key      text,
  p_is_enabled        boolean DEFAULT true
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_secret_id uuid;
  v_existing  uuid;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_active_tenant';
  END IF;

  IF NOT (
    data.jwt_user_tenants() ? v_tenant_id::text
    AND (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT onesignal_rest_key_secret_id INTO v_existing
  FROM data.tenant_push_config WHERE tenant_id = v_tenant_id;

  IF v_existing IS NOT NULL THEN
    PERFORM vault.update_secret(
      v_existing, p_rest_api_key,
      'onesignal_' || v_tenant_id::text, 'OneSignal REST API key (BYO)'
    );
    v_secret_id := v_existing;
  ELSE
    v_secret_id := vault.create_secret(
      p_rest_api_key,
      'onesignal_' || v_tenant_id::text, 'OneSignal REST API key (BYO)'
    );
  END IF;

  INSERT INTO data.tenant_push_config (
    tenant_id, onesignal_app_id, onesignal_rest_key_secret_id, is_enabled, updated_at
  ) VALUES (
    v_tenant_id, p_onesignal_app_id, v_secret_id, COALESCE(p_is_enabled, true), now()
  )
  ON CONFLICT (tenant_id) DO UPDATE SET
    onesignal_app_id = EXCLUDED.onesignal_app_id,
    onesignal_rest_key_secret_id = EXCLUDED.onesignal_rest_key_secret_id,
    is_enabled = EXCLUDED.is_enabled,
    updated_at = now();
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_tenant_push_config(text, text, boolean) TO authenticated;

CREATE OR REPLACE FUNCTION api.get_tenant_push_config()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_row       data.tenant_push_config%ROWTYPE;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_active_tenant';
  END IF;

  IF NOT (
    data.jwt_user_tenants() ? v_tenant_id::text
    AND (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_row FROM data.tenant_push_config WHERE tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('configured', false, 'platform_fallback', true);
  END IF;

  RETURN jsonb_build_object(
    'configured',         true,
    'onesignal_app_id',   v_row.onesignal_app_id,
    'is_enabled',         v_row.is_enabled,
    'has_rest_key',       v_row.onesignal_rest_key_secret_id IS NOT NULL,
    'platform_fallback',  false
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_tenant_push_config() TO authenticated;

CREATE OR REPLACE FUNCTION api.get_tenant_push_config_service(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_row record;
  v_key text;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_row
  FROM data.tenant_push_config
  WHERE tenant_id = p_tenant_id AND is_enabled = true;

  IF NOT FOUND OR v_row.onesignal_app_id IS NULL OR v_row.onesignal_rest_key_secret_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT decrypted_secret INTO v_key
  FROM vault.decrypted_secrets
  WHERE id = v_row.onesignal_rest_key_secret_id;

  IF v_key IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'appId', v_row.onesignal_app_id,
    'restApiKey', v_key,
    'source', 'tenant'
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_tenant_push_config_service(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_tenant_push_config_service(uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 9. Signing → motor de notificacions (email via plantilla)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.enqueue_signing_notification(
  p_submission_id  uuid,
  p_signer_order   integer,
  p_reason         text DEFAULT 'manual'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_submitter       data.signing_submitters%ROWTYPE;
  v_submission      data.signing_submissions%ROWTYPE;
  v_total           bigint;
  v_event_type      text;
  v_idempotency_key text;
  v_msg_id          bigint;
BEGIN
  SELECT * INTO v_submitter
  FROM data.signing_submitters
  WHERE submission_id = p_submission_id AND signer_order = p_signer_order;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'submitter_not_found';
  END IF;

  SELECT * INTO v_submission FROM data.signing_submissions WHERE id = p_submission_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'submission_not_found';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF NOT (data.jwt_user_tenants() ? v_submission.tenant_id::text) THEN
      RAISE EXCEPTION 'forbidden';
    END IF;
  END IF;

  IF v_submitter.signing_url IS NULL THEN
    RAISE EXCEPTION 'no_signing_url';
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM data.signing_submitters WHERE submission_id = p_submission_id;

  v_event_type := CASE WHEN p_signer_order = 0
    THEN 'signing.request.initial'
    ELSE 'signing.request.next_signer'
  END;

  v_idempotency_key := CASE
    WHEN p_reason = 'manual'
      THEN 'signing-notif-' || v_submitter.id::text || '-manual-' || extract(epoch from now())::bigint::text
    ELSE 'signing-notif-' || v_submitter.id::text || '-auto'
  END;

  v_msg_id := data.enqueue_notification_dispatch(jsonb_build_object(
    'tenantId',       v_submission.tenant_id,
    'eventType',      'SIGNING_REMINDER',
    'correlationId',  v_idempotency_key,
    'recipient',      jsonb_build_object('kind', 'raw_address', 'email', v_submitter.email),
    'entityType',     'signing_request',
    'entityId',       p_submission_id,
    'channelOverride', jsonb_build_array('email'),
    'payload',        jsonb_build_object(
      'email_event_type',   v_event_type,
      'summary',            'Sol·licitud de signatura: ' || COALESCE(v_submission.document_title, ''),
      'template_variables', jsonb_build_object(
        'signer_name',    v_submitter.name,
        'signer_email',   v_submitter.email,
        'signer_role',    COALESCE(v_submitter.role, ''),
        'document_title', COALESCE(v_submission.document_title, ''),
        'signing_url',    v_submitter.signing_url,
        'current_order',  p_signer_order + 1,
        'total_signers',  v_total
      )
    )
  ));

  UPDATE data.signing_submitters
  SET
    notified_at  = now(),
    status       = CASE WHEN status = 'pending' THEN 'sent' ELSE status END,
    updated_at   = now()
  WHERE id = v_submitter.id;

  UPDATE data.signing_submissions
  SET
    last_notification_at = now(),
    next_signer_index    = p_signer_order + 1,
    first_email_sent_at  = COALESCE(first_email_sent_at, now()),
    updated_at           = now()
  WHERE id = p_submission_id;

  PERFORM data.log_audit_event(
    v_submission.tenant_id, COALESCE(auth.uid(), NULL), NULL,
    'SIGNING_NOTIFICATION_SENT', 'signing_submitter', v_submitter.id,
    jsonb_build_object(
      'submission_id', p_submission_id,
      'signer_order',  p_signer_order,
      'email',         v_submitter.email,
      'event_type',    v_event_type,
      'reason',        p_reason,
      'queue_msg_id',  v_msg_id
    )
  );

  RETURN v_submitter.id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.enqueue_signing_notification(uuid, integer, text)
  TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 10. Twilio status callback — actualitzar delivery per MessageSid
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.complete_notification_delivery_by_provider_message(
  p_provider            text,
  p_provider_message_id text,
  p_status              data.notification_delivery_status,
  p_error_code          text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row record;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT id, created_at, tenant_id, correlation_id, channel
  INTO v_row
  FROM data.notification_deliveries
  WHERE provider = p_provider
    AND provider_message_id = p_provider_message_id
  ORDER BY created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  UPDATE data.notification_deliveries
  SET status = p_status,
      error_code = COALESCE(p_error_code, error_code),
      delivered_at = CASE WHEN p_status = 'delivered' THEN now() ELSE delivered_at END,
      completed_at = COALESCE(completed_at, now())
  WHERE id = v_row.id AND created_at = v_row.created_at;

  UPDATE data.notification_delivery_claims
  SET status = CASE WHEN p_status IN ('sent', 'delivered') THEN 'sent' ELSE 'failed' END,
      last_error_code = p_error_code,
      updated_at = now()
  WHERE tenant_id = v_row.tenant_id
    AND correlation_id = v_row.correlation_id
    AND channel = v_row.channel;
END;
$$;

REVOKE ALL ON FUNCTION api.complete_notification_delivery_by_provider_message(text, text, data.notification_delivery_status, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.complete_notification_delivery_by_provider_message(text, text, data.notification_delivery_status, text) TO service_role;

NOTIFY pgrst, 'reload schema';
