-- =============================================================================
-- Notification Engine — Worker RPCs (service_role)
-- =============================================================================
-- PostgREST no exposa el schema data (config.toml). Els workers han d'escriure
-- a data.* via RPCs SECURITY DEFINER, igual que create_ai_alert_notification_service.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Lectura de contactes per al worker
-- -----------------------------------------------------------------------------
GRANT SELECT ON api.contacts TO service_role;

-- -----------------------------------------------------------------------------
-- 2. Inserció in-app (idempotent per user+entity+kind)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.insert_in_app_notification_service(
  p_tenant_id         uuid,
  p_user_id           uuid,
  p_kind              text,
  p_title_i18n        jsonb,
  p_body_i18n         jsonb,
  p_deep_link         text DEFAULT NULL,
  p_entity_type       text DEFAULT NULL,
  p_entity_id         uuid DEFAULT NULL,
  p_severity          text DEFAULT 'info'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_id       uuid;
  v_severity text := COALESCE(NULLIF(trim(p_severity), ''), 'info');
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF v_severity NOT IN ('info', 'success', 'warning', 'critical') THEN
    v_severity := 'info';
  END IF;

  INSERT INTO data.notifications (
    tenant_id,
    user_id,
    kind,
    severity,
    title_i18n,
    body_i18n,
    deep_link,
    related_entity_type,
    related_entity_id
  ) VALUES (
    p_tenant_id,
    p_user_id,
    lower(p_kind),
    v_severity,
    p_title_i18n,
    p_body_i18n,
    p_deep_link,
    p_entity_type,
    p_entity_id
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.insert_in_app_notification_service(
  uuid, uuid, text, jsonb, jsonb, text, text, uuid, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.insert_in_app_notification_service(
  uuid, uuid, text, jsonb, jsonb, text, text, uuid, text
) TO service_role;

-- -----------------------------------------------------------------------------
-- 3. Preparar fila de delivery + claim en estat sending
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.prepare_notification_delivery_service(
  p_delivery_id     uuid,
  p_tenant_id       uuid,
  p_event_code      text,
  p_correlation_id  text,
  p_recipient_kind  data.notification_recipient_kind,
  p_recipient_id    uuid,
  p_channel         data.notification_channel,
  p_entity_type     text DEFAULT NULL,
  p_entity_id       uuid DEFAULT NULL,
  p_payload_summary jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_existing_status data.notification_delivery_status;
  v_created_at      timestamptz;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT d.status, d.created_at
  INTO v_existing_status, v_created_at
  FROM data.notification_deliveries d
  WHERE d.id = p_delivery_id
  ORDER BY d.created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    INSERT INTO data.notification_deliveries (
      id,
      tenant_id,
      event_code,
      correlation_id,
      recipient_kind,
      recipient_id,
      channel,
      status,
      entity_type,
      entity_id,
      payload_summary
    ) VALUES (
      p_delivery_id,
      p_tenant_id,
      p_event_code,
      p_correlation_id,
      p_recipient_kind,
      p_recipient_id,
      p_channel,
      'pending',
      p_entity_type,
      p_entity_id,
      COALESCE(p_payload_summary, '{}'::jsonb)
    );
  ELSIF v_existing_status = 'failed' THEN
    UPDATE data.notification_deliveries
    SET status = 'pending',
        error_code = NULL,
        error_message = NULL
    WHERE id = p_delivery_id
      AND created_at = v_created_at;
  END IF;

  UPDATE data.notification_delivery_claims
  SET status = 'sending',
      updated_at = now()
  WHERE tenant_id = p_tenant_id
    AND correlation_id = p_correlation_id
    AND channel = p_channel;
END;
$$;

REVOKE ALL ON FUNCTION api.prepare_notification_delivery_service(
  uuid, uuid, text, text, data.notification_recipient_kind, uuid,
  data.notification_channel, text, uuid, jsonb
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.prepare_notification_delivery_service(
  uuid, uuid, text, text, data.notification_recipient_kind, uuid,
  data.notification_channel, text, uuid, jsonb
) TO service_role;

-- -----------------------------------------------------------------------------
-- 4. Finalitzar delivery + claim
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.complete_notification_delivery_service(
  p_delivery_id         uuid,
  p_tenant_id           uuid,
  p_correlation_id      text,
  p_channel             data.notification_channel,
  p_status              data.notification_delivery_status,
  p_provider            text DEFAULT NULL,
  p_provider_message_id text DEFAULT NULL,
  p_error_code          text DEFAULT NULL,
  p_error_message       text DEFAULT NULL,
  p_operation_log_id    uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_created_at   timestamptz;
  v_claim_status text;
  v_now          timestamptz := now();
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  v_claim_status := CASE WHEN p_status = 'sent' THEN 'sent' ELSE 'failed' END;

  SELECT d.created_at
  INTO v_created_at
  FROM data.notification_deliveries d
  WHERE d.id = p_delivery_id
  ORDER BY d.created_at DESC
  LIMIT 1;

  IF v_created_at IS NOT NULL THEN
    UPDATE data.notification_deliveries
    SET status = p_status,
        provider = p_provider,
        provider_message_id = p_provider_message_id,
        error_code = p_error_code,
        error_message = left(p_error_message, 1000),
        operation_log_id = p_operation_log_id,
        sent_at = CASE WHEN p_status = 'sent' THEN v_now ELSE sent_at END,
        completed_at = v_now
    WHERE id = p_delivery_id
      AND created_at = v_created_at;
  END IF;

  UPDATE data.notification_delivery_claims
  SET status = v_claim_status,
      provider_message_id = p_provider_message_id,
      last_error_code = p_error_code,
      updated_at = v_now
  WHERE tenant_id = p_tenant_id
    AND correlation_id = p_correlation_id
    AND channel = p_channel;
END;
$$;

REVOKE ALL ON FUNCTION api.complete_notification_delivery_service(
  uuid, uuid, text, data.notification_channel, data.notification_delivery_status,
  text, text, text, text, uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.complete_notification_delivery_service(
  uuid, uuid, text, data.notification_channel, data.notification_delivery_status,
  text, text, text, text, uuid
) TO service_role;
