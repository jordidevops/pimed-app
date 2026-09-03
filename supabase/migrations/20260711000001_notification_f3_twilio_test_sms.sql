-- =============================================================================
-- Notification Engine — F3: RPC send_test_sms
-- Permet a owners/managers enviar un SMS de prova per verificar la configuració
-- Twilio BYO del tenant.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.send_test_sms(p_phone_e164 text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_user_id   uuid := auth.uid();
BEGIN
  IF v_tenant_id IS NULL OR v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  IF NOT (
    data.jwt_user_tenants() ? v_tenant_id::text
    AND (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF COALESCE(trim(p_phone_e164), '') = '' THEN
    RAISE EXCEPTION 'phone_required';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.tenant_twilio_config
    WHERE tenant_id = v_tenant_id AND is_enabled = true
  ) THEN
    RAISE EXCEPTION 'twilio_not_configured';
  END IF;

  RETURN data.enqueue_notification_dispatch(jsonb_build_object(
    'tenantId',       v_tenant_id,
    'eventType',      'NOTIFICATION_TEST',
    'correlationId',  'sms-test:' || v_tenant_id::text || ':' || extract(epoch from now())::bigint::text,
    'recipient',      jsonb_build_object('kind', 'raw_address', 'phoneE164', p_phone_e164),
    'channelOverride', jsonb_build_array('sms'),
    'payload',        jsonb_build_object(
      'summary', 'SMS de prova del motor de notificacions.'
    )
  ));
END;
$$;

REVOKE ALL ON FUNCTION api.send_test_sms(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.send_test_sms(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
