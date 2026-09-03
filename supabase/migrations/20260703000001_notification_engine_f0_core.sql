-- =============================================================================
-- Notification Engine — F0 Core
-- =============================================================================
-- Enums, taules, claims, particions, quotes, PGMQ, RPCs d'entrada i idempotència.
-- Worker + routing context → migració F1.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Enums
-- -----------------------------------------------------------------------------
DO $$ BEGIN
  CREATE TYPE data.notification_recipient_kind AS ENUM (
    'tenant_member',
    'contact',
    'raw_address'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE data.notification_channel AS ENUM (
    'in_app', 'push', 'email', 'sms', 'whatsapp'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE data.notification_delivery_status AS ENUM (
    'pending', 'queued', 'sent', 'delivered', 'failed', 'skipped', 'cancelled'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- -----------------------------------------------------------------------------
-- 2. Credencials Twilio BYO
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.tenant_twilio_config (
  tenant_id                uuid PRIMARY KEY REFERENCES data.tenants(id) ON DELETE CASCADE,
  account_sid              text NOT NULL,
  auth_token_secret_id     uuid NOT NULL,
  sms_from_number          text,
  whatsapp_from_number     text,
  messaging_service_sid    text,
  is_enabled               boolean NOT NULL DEFAULT false,
  is_verified              boolean NOT NULL DEFAULT false,
  last_verified_at         timestamptz,
  last_error_code          text,
  last_error_at            timestamptz,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE data.tenant_twilio_config IS
  'Credencials Twilio BYO per tenant. Auth token al Vault (auth_token_secret_id).';

-- -----------------------------------------------------------------------------
-- 3. Catàleg d'esdeveniments i preferències
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.notification_event_catalog (
  event_code          text PRIMARY KEY,
  category            text NOT NULL,
  entity_type         text NOT NULL,
  deep_link_template  text,
  default_channels    data.notification_channel[] NOT NULL DEFAULT '{in_app}',
  requires_legal      boolean NOT NULL DEFAULT false,
  digest_eligible     boolean NOT NULL DEFAULT false,
  description         text
);

COMMENT ON COLUMN data.notification_event_catalog.entity_type IS
  'Tipus d''entitat per deep links i Timeline.';

CREATE TABLE IF NOT EXISTS data.notification_preferences (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  recipient_kind    data.notification_recipient_kind NOT NULL,
  recipient_id      uuid,
  raw_email         text,
  raw_phone_e164    text,
  event_code        text REFERENCES data.notification_event_catalog(event_code),
  channels_enabled  data.notification_channel[] NOT NULL,
  preferred_channel data.notification_channel,
  quiet_hours       jsonb,
  locale            text DEFAULT 'ca',
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT notification_preferences_subject_chk CHECK (
    (recipient_kind = 'tenant_member' AND recipient_id IS NOT NULL)
    OR (recipient_kind = 'contact' AND recipient_id IS NOT NULL)
    OR (recipient_kind = 'raw_address' AND (raw_email IS NOT NULL OR raw_phone_e164 IS NOT NULL))
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_notification_preferences_member_event
  ON data.notification_preferences (tenant_id, recipient_kind, recipient_id, event_code)
  WHERE recipient_kind = 'tenant_member' AND event_code IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_notification_preferences_member_global
  ON data.notification_preferences (tenant_id, recipient_kind, recipient_id)
  WHERE recipient_kind = 'tenant_member' AND event_code IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_notification_preferences_contact_event
  ON data.notification_preferences (tenant_id, recipient_kind, recipient_id, event_code)
  WHERE recipient_kind = 'contact' AND event_code IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_notification_preferences_contact_global
  ON data.notification_preferences (tenant_id, recipient_kind, recipient_id)
  WHERE recipient_kind = 'contact' AND event_code IS NULL;

-- -----------------------------------------------------------------------------
-- 4. Opt-out contactes externs
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.contact_notification_consents (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  contact_id        uuid NOT NULL REFERENCES data.contacts(id) ON DELETE CASCADE,
  channel           data.notification_channel NOT NULL,
  event_code        text REFERENCES data.notification_event_catalog(event_code),
  opted_out         boolean NOT NULL DEFAULT false,
  opted_out_at      timestamptz,
  opted_out_source  text,
  opted_out_reason  text,
  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_contact_consents_event_specific
  ON data.contact_notification_consents (tenant_id, contact_id, channel, event_code)
  WHERE event_code IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_contact_consents_event_global
  ON data.contact_notification_consents (tenant_id, contact_id, channel)
  WHERE event_code IS NULL;

-- -----------------------------------------------------------------------------
-- 5. Claims (idempotència) + historial particionat
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.notification_delivery_claims (
  tenant_id           uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  correlation_id      text NOT NULL,
  channel             data.notification_channel NOT NULL,
  delivery_id         uuid NOT NULL,
  claim_token         uuid NOT NULL DEFAULT gen_random_uuid(),
  status              text NOT NULL DEFAULT 'claimed'
                      CHECK (status IN ('claimed', 'sending', 'sent', 'failed')),
  claimed_at          timestamptz NOT NULL DEFAULT now(),
  claim_expires_at    timestamptz NOT NULL DEFAULT (now() + interval '90 seconds'),
  provider_message_id text,
  last_error_code     text,
  updated_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, correlation_id, channel)
);

CREATE INDEX IF NOT EXISTS idx_delivery_claims_cleanup
  ON data.notification_delivery_claims (claim_expires_at)
  WHERE status IN ('sent', 'failed');

CREATE TABLE IF NOT EXISTS data.notification_deliveries (
  id                  uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  event_code          text NOT NULL,
  correlation_id      text NOT NULL,
  recipient_kind      data.notification_recipient_kind NOT NULL,
  recipient_id        uuid,
  channel             data.notification_channel NOT NULL,
  status              data.notification_delivery_status NOT NULL DEFAULT 'pending',
  provider            text,
  provider_message_id text,
  error_code          text,
  error_message       text,
  payload_summary     jsonb NOT NULL DEFAULT '{}'::jsonb,
  entity_type         text,
  entity_id           uuid,
  digest_group_key    text,
  operation_log_id    uuid REFERENCES data.tenant_operation_logs(id) ON DELETE SET NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  sent_at             timestamptz,
  completed_at        timestamptz,
  delivered_at        timestamptz,
  PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

CREATE TABLE IF NOT EXISTS data.notification_deliveries_2026_q2
  PARTITION OF data.notification_deliveries
  FOR VALUES FROM ('2026-04-01') TO ('2026-07-01');

CREATE TABLE IF NOT EXISTS data.notification_deliveries_2026_q3
  PARTITION OF data.notification_deliveries
  FOR VALUES FROM ('2026-07-01') TO ('2026-10-01');

CREATE TABLE IF NOT EXISTS data.notification_deliveries_default
  PARTITION OF data.notification_deliveries DEFAULT;

CREATE INDEX IF NOT EXISTS idx_notification_deliveries_tenant_created
  ON data.notification_deliveries (tenant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_notification_deliveries_provider_message_id
  ON data.notification_deliveries (provider, provider_message_id)
  WHERE provider_message_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_notification_deliveries_pending
  ON data.notification_deliveries (status, created_at)
  WHERE status IN ('pending', 'failed');

-- -----------------------------------------------------------------------------
-- 6. Push BYO + quotes
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.tenant_push_config (
  tenant_id                    uuid PRIMARY KEY REFERENCES data.tenants(id) ON DELETE CASCADE,
  onesignal_app_id             text,
  onesignal_rest_key_secret_id uuid,
  is_enabled                   boolean NOT NULL DEFAULT false,
  created_at                   timestamptz NOT NULL DEFAULT now(),
  updated_at                   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE data.tenant_push_config IS
  'Opcional BYO OneSignal. Sense fila activa → env global de plataforma.';

CREATE TABLE IF NOT EXISTS data.tenant_notification_quotas (
  tenant_id           uuid PRIMARY KEY REFERENCES data.tenants(id) ON DELETE CASCADE,
  daily_sms_limit     integer,
  monthly_sms_limit   integer,
  daily_email_limit   integer,
  updated_at          timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS data.tenant_notification_usage_daily (
  usage_date         date NOT NULL,
  tenant_id          uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  channel            data.notification_channel NOT NULL,
  sent_count         integer NOT NULL DEFAULT 0,
  failed_count       integer NOT NULL DEFAULT 0,
  cancelled_count    integer NOT NULL DEFAULT 0,
  updated_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (usage_date, tenant_id, channel)
);

CREATE TABLE IF NOT EXISTS data.tenant_notification_usage_monthly (
  usage_month        date NOT NULL,
  tenant_id          uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  channel            data.notification_channel NOT NULL,
  sent_count         integer NOT NULL DEFAULT 0,
  failed_count       integer NOT NULL DEFAULT 0,
  cancelled_count    integer NOT NULL DEFAULT 0,
  updated_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (usage_month, tenant_id, channel)
);

-- -----------------------------------------------------------------------------
-- 7. Gestió de particions
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.create_notification_deliveries_partition(p_quarter_start date)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_quarter_end date := (p_quarter_start + interval '3 months')::date;
  v_table_name text := 'notification_deliveries_'
    || to_char(p_quarter_start, 'YYYY')
    || '_q'
    || to_char(p_quarter_start, 'Q');
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'data' AND c.relname = v_table_name
  ) THEN
    EXECUTE format(
      'CREATE TABLE data.%I PARTITION OF data.notification_deliveries FOR VALUES FROM (%L) TO (%L)',
      v_table_name,
      p_quarter_start,
      v_quarter_end
    );
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION data.reconcile_notification_deliveries_default(p_limit int DEFAULT 5000)
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  v_moved int := 0;
  v_q date;
BEGIN
  FOR v_q IN
    SELECT DISTINCT date_trunc('quarter', d.created_at)::date
    FROM data.notification_deliveries_default d
    LIMIT 16
  LOOP
    PERFORM data.create_notification_deliveries_partition(v_q);
  END LOOP;

  WITH pulled AS (
    SELECT ctid, *
    FROM data.notification_deliveries_default
    ORDER BY created_at
    LIMIT GREATEST(p_limit, 1)
  ),
  deleted AS (
    DELETE FROM data.notification_deliveries_default d
    USING pulled p
    WHERE d.ctid = p.ctid
    RETURNING p.*
  )
  INSERT INTO data.notification_deliveries (
    id, tenant_id, event_code, correlation_id, recipient_kind, recipient_id,
    channel, status, provider, provider_message_id, error_code, error_message,
    payload_summary, entity_type, entity_id, digest_group_key, operation_log_id,
    created_at, sent_at, completed_at, delivered_at
  )
  SELECT
    id, tenant_id, event_code, correlation_id, recipient_kind, recipient_id,
    channel, status, provider, provider_message_id, error_code, error_message,
    payload_summary, entity_type, entity_id, digest_group_key, operation_log_id,
    created_at, sent_at, completed_at, delivered_at
  FROM deleted;

  GET DIAGNOSTICS v_moved = ROW_COUNT;
  RETURN v_moved;
END;
$$;

SELECT data.create_notification_deliveries_partition(date_trunc('quarter', now())::date);
SELECT data.create_notification_deliveries_partition(date_trunc('quarter', now() + interval '3 months')::date);

-- -----------------------------------------------------------------------------
-- 8. RPC: claim_notification_delivery
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.claim_notification_delivery(
  p_tenant_id      uuid,
  p_correlation_id text,
  p_channel        data.notification_channel,
  p_delivery_id    uuid
)
RETURNS TABLE (
  acquired    boolean,
  delivery_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_delivery_id uuid;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  INSERT INTO data.notification_delivery_claims (
    tenant_id, correlation_id, channel, delivery_id,
    claim_token, status, claimed_at, claim_expires_at, updated_at
  )
  VALUES (
    p_tenant_id, p_correlation_id, p_channel, p_delivery_id,
    gen_random_uuid(), 'claimed', now(), now() + interval '90 seconds', now()
  )
  ON CONFLICT (tenant_id, correlation_id, channel)
  DO UPDATE SET
    claim_token      = gen_random_uuid(),
    status           = 'claimed',
    claimed_at       = now(),
    claim_expires_at = now() + interval '90 seconds',
    updated_at       = now()
  WHERE
    data.notification_delivery_claims.claim_expires_at < now()
    OR data.notification_delivery_claims.status = 'failed'
  RETURNING data.notification_delivery_claims.delivery_id
  INTO v_delivery_id;

  IF v_delivery_id IS NOT NULL THEN
    RETURN QUERY SELECT true, v_delivery_id;
  ELSE
    RETURN QUERY SELECT false, NULL::uuid;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION api.claim_notification_delivery(uuid, text, data.notification_channel, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.claim_notification_delivery(uuid, text, data.notification_channel, uuid) FROM authenticated;
REVOKE ALL ON FUNCTION api.claim_notification_delivery(uuid, text, data.notification_channel, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION api.claim_notification_delivery(uuid, text, data.notification_channel, uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 9. RPC: increment_notification_usage
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.increment_notification_usage(
  p_tenant_id uuid,
  p_channel   data.notification_channel
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_daily_limit    integer;
  v_monthly_limit  integer;
  v_today          date := current_date;
  v_month_start    date := date_trunc('month', now())::date;
  v_ok             boolean := false;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_channel NOT IN ('sms', 'email') THEN
    RETURN true;
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('notif_quota:' || p_tenant_id::text || ':' || p_channel::text, 0)
  );

  SELECT
    CASE WHEN p_channel = 'sms' THEN daily_sms_limit
         WHEN p_channel = 'email' THEN daily_email_limit
         ELSE NULL END,
    CASE WHEN p_channel = 'sms' THEN monthly_sms_limit ELSE NULL END
  INTO v_daily_limit, v_monthly_limit
  FROM data.tenant_notification_quotas
  WHERE tenant_id = p_tenant_id;

  INSERT INTO data.tenant_notification_usage_daily (usage_date, tenant_id, channel, sent_count)
  VALUES (v_today, p_tenant_id, p_channel, 0)
  ON CONFLICT (usage_date, tenant_id, channel) DO NOTHING;

  IF p_channel = 'sms' THEN
    INSERT INTO data.tenant_notification_usage_monthly (usage_month, tenant_id, channel, sent_count)
    VALUES (v_month_start, p_tenant_id, p_channel, 0)
    ON CONFLICT (usage_month, tenant_id, channel) DO NOTHING;
  END IF;

  IF p_channel = 'sms' AND v_monthly_limit IS NOT NULL THEN
    UPDATE data.tenant_notification_usage_monthly
    SET sent_count = sent_count + 1, updated_at = now()
    WHERE usage_month = v_month_start
      AND tenant_id = p_tenant_id
      AND channel = p_channel
      AND sent_count < v_monthly_limit;

    IF NOT FOUND THEN
      RETURN false;
    END IF;
  END IF;

  UPDATE data.tenant_notification_usage_daily
  SET sent_count = sent_count + 1, updated_at = now()
  WHERE usage_date = v_today
    AND tenant_id = p_tenant_id
    AND channel = p_channel
    AND (v_daily_limit IS NULL OR sent_count < v_daily_limit)
  RETURNING true INTO v_ok;

  IF v_ok THEN
    RETURN true;
  END IF;

  IF p_channel = 'sms' AND v_monthly_limit IS NOT NULL THEN
    UPDATE data.tenant_notification_usage_monthly
    SET sent_count = GREATEST(sent_count - 1, 0), updated_at = now()
    WHERE usage_month = v_month_start
      AND tenant_id = p_tenant_id
      AND channel = p_channel;
  END IF;

  RETURN false;
END;
$$;

REVOKE ALL ON FUNCTION api.increment_notification_usage(uuid, data.notification_channel) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.increment_notification_usage(uuid, data.notification_channel) FROM authenticated;
REVOKE ALL ON FUNCTION api.increment_notification_usage(uuid, data.notification_channel) FROM anon;
GRANT EXECUTE ON FUNCTION api.increment_notification_usage(uuid, data.notification_channel) TO service_role;

-- -----------------------------------------------------------------------------
-- 10. RPC: upsert_tenant_twilio_config
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.upsert_tenant_twilio_config(
  p_tenant_id             uuid,
  p_account_sid           text,
  p_auth_token            text,
  p_sms_from_number       text DEFAULT NULL,
  p_whatsapp_from_number  text DEFAULT NULL,
  p_messaging_service_sid text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_secret_id uuid;
  v_existing  uuid;
BEGIN
  IF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT auth_token_secret_id INTO v_existing
  FROM data.tenant_twilio_config WHERE tenant_id = p_tenant_id;

  IF v_existing IS NOT NULL THEN
    PERFORM vault.update_secret(
      v_existing, p_auth_token,
      'twilio_' || p_tenant_id::text, 'Twilio auth token (BYO)'
    );
    v_secret_id := v_existing;
  ELSE
    BEGIN
      v_secret_id := vault.create_secret(
        p_auth_token,
        'twilio_' || p_tenant_id::text, 'Twilio auth token (BYO)'
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'No s''ha pogut crear el secret al Vault: %', SQLERRM;
    END;
  END IF;

  BEGIN
    INSERT INTO data.tenant_twilio_config (
      tenant_id, account_sid, auth_token_secret_id,
      sms_from_number, whatsapp_from_number, messaging_service_sid,
      is_enabled, updated_at
    ) VALUES (
      p_tenant_id, p_account_sid, v_secret_id,
      p_sms_from_number, p_whatsapp_from_number, p_messaging_service_sid,
      true, now()
    )
    ON CONFLICT (tenant_id) DO UPDATE SET
      account_sid = EXCLUDED.account_sid,
      auth_token_secret_id = EXCLUDED.auth_token_secret_id,
      sms_from_number = EXCLUDED.sms_from_number,
      whatsapp_from_number = EXCLUDED.whatsapp_from_number,
      messaging_service_sid = EXCLUDED.messaging_service_sid,
      is_enabled = true,
      updated_at = now();
  EXCEPTION WHEN OTHERS THEN
    IF v_existing IS NULL THEN
      PERFORM vault.delete_secret(v_secret_id);
    END IF;
    RAISE;
  END;
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_tenant_twilio_config TO authenticated;
GRANT EXECUTE ON FUNCTION api.upsert_tenant_twilio_config TO service_role;

-- -----------------------------------------------------------------------------
-- 11. RPC: get_tenant_twilio_credentials_service
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_tenant_twilio_credentials_service(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_row record;
  v_token text;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_row FROM data.tenant_twilio_config
  WHERE tenant_id = p_tenant_id AND is_enabled = true;

  IF NOT FOUND THEN RETURN NULL; END IF;

  SELECT decrypted_secret INTO v_token
  FROM vault.decrypted_secrets WHERE id = v_row.auth_token_secret_id;

  RETURN jsonb_build_object(
    'account_sid', v_row.account_sid,
    'auth_token', v_token,
    'sms_from_number', v_row.sms_from_number,
    'whatsapp_from_number', v_row.whatsapp_from_number,
    'messaging_service_sid', v_row.messaging_service_sid
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_tenant_twilio_credentials_service(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_tenant_twilio_credentials_service(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION api.get_tenant_twilio_credentials_service(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION api.get_tenant_twilio_credentials_service(uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 12. PGMQ + api.enqueue_notification
-- -----------------------------------------------------------------------------
SELECT pgmq.create('notification_dispatch_queue');

CREATE OR REPLACE FUNCTION api.enqueue_notification(payload jsonb)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_msg_id     bigint;
  v_normalized jsonb;
  v_tenant_id  text;
BEGIN
  IF auth.role() NOT IN ('authenticated', 'service_role') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF (payload ->> 'tenantId') IS NULL OR (payload ->> 'eventType') IS NULL THEN
    RAISE EXCEPTION 'enqueue_notification: tenantId i eventType són obligatoris';
  END IF;

  v_tenant_id := payload ->> 'tenantId';
  v_normalized := payload;

  IF (payload ->> 'tenant_id') IS NULL THEN
    v_normalized := v_normalized || jsonb_build_object('tenant_id', v_tenant_id);
  END IF;

  IF (payload ->> 'task') IS NULL THEN
    v_normalized := v_normalized || jsonb_build_object('task', 'dispatch_notification');
  END IF;

  IF (payload ->> 'idempotency_key') IS NULL AND (payload ->> 'correlationId') IS NOT NULL THEN
    v_normalized := v_normalized || jsonb_build_object(
      'idempotency_key', payload ->> 'correlationId'
    );
  END IF;

  SELECT pgmq.send('notification_dispatch_queue', v_normalized) INTO v_msg_id;
  RETURN v_msg_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.enqueue_notification(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION api.enqueue_notification(jsonb) TO service_role;

-- -----------------------------------------------------------------------------
-- 13. Seed catàleg d'esdeveniments
-- -----------------------------------------------------------------------------
INSERT INTO data.notification_event_catalog (
  event_code, category, entity_type, deep_link_template,
  default_channels, requires_legal, digest_eligible, description
) VALUES
  ('TASK_ASSIGNED', 'operations', 'task', '/tasks/{entity_id}',
   '{in_app,push}', false, false, 'Tasca assignada a un membre'),
  ('MENTION_CREATED', 'operations', 'entity_comment', '/comments/{entity_id}',
   '{in_app,push,email}', false, true, 'Menció en un comentari'),
  ('INVOICE_GENERATED', 'billing', 'invoice', '/invoices/{entity_id}',
   '{email}', true, false, 'Factura generada per a contacte'),
  ('QUOTE_SENT', 'billing', 'quote', '/quotes/{entity_id}',
   '{email}', false, false, 'Pressupost enviat'),
  ('INTERVENTION_DISPATCHED', 'operations', 'intervention', '/interventions/{entity_id}',
   '{sms,email}', false, false, 'Intervenció assignada/despatxada'),
  ('SIGNING_REMINDER', 'operations', 'signing_request', '/signing/{entity_id}',
   '{email,push}', false, false, 'Recordatori de signatura'),
  ('DLQ_ERROR', 'system', 'system', '/admin/dlq',
   '{in_app,email}', false, false, 'Error crític a cua asíncrona')
ON CONFLICT (event_code) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 14. RLS
-- -----------------------------------------------------------------------------
ALTER TABLE data.notification_deliveries ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS notification_deliveries_tenant_read ON data.notification_deliveries;
CREATE POLICY notification_deliveries_tenant_read
  ON data.notification_deliveries
  FOR SELECT TO authenticated
  USING (tenant_id = data.active_tenant_id());

ALTER TABLE data.notification_preferences ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS notification_preferences_tenant_read ON data.notification_preferences;
CREATE POLICY notification_preferences_tenant_read
  ON data.notification_preferences
  FOR SELECT TO authenticated
  USING (tenant_id = data.active_tenant_id());

DROP POLICY IF EXISTS notification_preferences_tenant_write ON data.notification_preferences;
CREATE POLICY notification_preferences_tenant_write
  ON data.notification_preferences
  FOR ALL TO authenticated
  USING (tenant_id = data.active_tenant_id())
  WITH CHECK (tenant_id = data.active_tenant_id());

REVOKE ALL ON data.notification_delivery_claims FROM authenticated, anon;

-- -----------------------------------------------------------------------------
-- 15. Grants service_role (Edge Functions)
-- -----------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE ON data.notification_delivery_claims TO service_role;
GRANT SELECT, INSERT, UPDATE ON data.notification_deliveries TO service_role;
GRANT SELECT ON data.notification_event_catalog TO service_role, authenticated;
GRANT SELECT ON data.notification_preferences TO service_role, authenticated;
GRANT SELECT ON data.contact_notification_consents TO service_role;
GRANT SELECT ON data.tenant_twilio_config TO service_role;
GRANT SELECT ON data.tenant_push_config TO service_role;
GRANT SELECT ON data.tenant_notification_quotas TO service_role;
GRANT SELECT, INSERT, UPDATE ON data.tenant_notification_usage_daily TO service_role;
GRANT SELECT, INSERT, UPDATE ON data.tenant_notification_usage_monthly TO service_role;
GRANT SELECT ON data.contacts TO service_role;
GRANT SELECT ON data.profiles TO service_role;

-- -----------------------------------------------------------------------------
-- 16. pg_cron: particions + reconcile DEFAULT
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('notification_deliveries_partition_rollover')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'notification_deliveries_partition_rollover'
    );

    PERFORM cron.schedule(
      'notification_deliveries_partition_rollover',
      '0 3 1 1,4,7,10 *',
      $cron$SELECT data.create_notification_deliveries_partition(
        date_trunc('quarter', now() + interval '3 months')::date
      );$cron$
    );

    PERFORM cron.unschedule('notification_deliveries_default_reconcile')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'notification_deliveries_default_reconcile'
    );

    PERFORM cron.schedule(
      'notification_deliveries_default_reconcile',
      '*/15 * * * *',
      $cron$SELECT data.reconcile_notification_deliveries_default(5000);$cron$
    );
  END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';
