-- =============================================================================
-- Webhooks — migrar secret plaintext a Vault + tenant_secret_refs
-- =============================================================================

ALTER TABLE data.tenant_webhooks
  ADD COLUMN IF NOT EXISTS secret_id uuid,
  ADD COLUMN IF NOT EXISTS secret_hint_suffix text;

-- Migrar secrets existents al Vault
-- Savepoint per webhook: si un vault.create_secret falla no fa rollback de tots.
DO $$
DECLARE
  v_wh   record;
  v_sid  uuid;
  v_name text;
BEGIN
  FOR v_wh IN
    SELECT * FROM data.tenant_webhooks WHERE secret IS NOT NULL AND secret_id IS NULL
  LOOP
    BEGIN
      v_name := 'webhook_' || v_wh.id::text;
      v_sid := vault.create_secret(v_wh.secret, v_name, 'Webhook HMAC secret');

      UPDATE data.tenant_webhooks
      SET secret_id = v_sid,
          secret_hint_suffix = right(v_wh.secret, 4)
      WHERE id = v_wh.id;

      INSERT INTO data.tenant_secret_refs (
        tenant_id, secret_id, secret_type, provider, label,
        key_version, rotation_status, last_rotated_at, rotation_due_at
      ) VALUES (
        v_wh.tenant_id, v_sid, 'webhook_secret', 'webhook:' || v_wh.id::text,
        v_wh.label, 1, 'active', v_wh.updated_at, v_wh.updated_at + interval '365 days'
      )
      ON CONFLICT (tenant_id, secret_type, provider) DO UPDATE SET
        secret_id = EXCLUDED.secret_id,
        updated_at = now();
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'webhook migration skipped for % (%): %', v_wh.id, v_wh.label, SQLERRM;
    END;
  END LOOP;
END;
$$;

ALTER TABLE data.tenant_webhooks DROP COLUMN IF EXISTS secret;

-- -----------------------------------------------------------------------------
-- list_tenant_webhooks
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
  PERFORM data.require_entity_timeline_feature(v_tenant_id, 'entity_timeline_webhooks');

  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
      'id',            w.id,
      'label',         w.label,
      'endpoint_url',  w.endpoint_url,
      'events',        to_jsonb(w.events),
      'entity_types',  CASE WHEN w.entity_types IS NULL THEN NULL ELSE to_jsonb(w.entity_types) END,
      'is_active',     w.is_active,
      'secret_hint',   'whsec_…' || coalesce(w.secret_hint_suffix, '????'),
      'created_at',    w.created_at,
      'updated_at',    w.updated_at
    ) ORDER BY w.created_at DESC)
    FROM data.tenant_webhooks w
    WHERE w.tenant_id = v_tenant_id
  ), '[]'::jsonb);
END;
$$;

-- -----------------------------------------------------------------------------
-- upsert_tenant_webhook
-- -----------------------------------------------------------------------------
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
SET search_path = data, vault, public
AS $$
DECLARE
  v_tenant_id   uuid := data.active_tenant_id();
  v_user_id     uuid := auth.uid();
  v_secret      text;
  v_secret_id   uuid;
  v_row         data.tenant_webhooks%ROWTYPE;
  v_events      text[] := coalesce(p_events, ARRAY['timeline.comment.created']::text[]);
  v_return_secret text;
  v_provider    text;
BEGIN
  IF v_tenant_id IS NULL OR v_user_id IS NULL THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  PERFORM data.require_tenant_webhook_admin(v_tenant_id);
  PERFORM data.require_entity_timeline_feature(v_tenant_id, 'entity_timeline_webhooks');

  IF p_label IS NULL OR length(trim(p_label)) = 0 THEN
    RAISE EXCEPTION 'label_required';
  END IF;

  IF p_endpoint_url IS NULL OR NOT data.is_allowed_webhook_endpoint(p_endpoint_url) THEN
    RAISE EXCEPTION 'invalid_endpoint_url';
  END IF;

  IF p_id IS NULL THEN
    v_secret := 'whsec_' || replace(gen_random_uuid()::text, '-', '')
      || replace(gen_random_uuid()::text, '-', '');
    v_return_secret := v_secret;

    INSERT INTO data.tenant_webhooks (
      tenant_id, label, endpoint_url, events, entity_types,
      is_active, created_by, secret_hint_suffix
    ) VALUES (
      v_tenant_id, trim(p_label), trim(p_endpoint_url),
      v_events, p_entity_types, coalesce(p_is_active, true), v_user_id,
      right(v_secret, 4)
    )
    RETURNING * INTO v_row;

    v_provider := 'webhook:' || v_row.id::text;
    v_secret_id := vault.create_secret(
      v_secret, 'webhook_' || v_row.id::text, 'Webhook HMAC: ' || trim(p_label)
    );

    UPDATE data.tenant_webhooks SET secret_id = v_secret_id WHERE id = v_row.id;
    v_row.secret_id := v_secret_id;

    INSERT INTO data.tenant_secret_refs (
      tenant_id, secret_id, secret_type, provider, label,
      key_version, rotation_status, last_rotated_at, rotation_due_at, created_by
    ) VALUES (
      v_tenant_id, v_secret_id, 'webhook_secret', v_provider, trim(p_label),
      1, 'active', now(), now() + interval '365 days', v_user_id
    );
  ELSE
    SELECT * INTO v_row
    FROM data.tenant_webhooks
    WHERE id = p_id AND tenant_id = v_tenant_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'webhook_not_found';
    END IF;

    v_provider := 'webhook:' || v_row.id::text;

    IF p_rotate_secret THEN
      v_secret := 'whsec_' || replace(gen_random_uuid()::text, '-', '')
        || replace(gen_random_uuid()::text, '-', '');
      v_return_secret := v_secret;

      PERFORM api.rotate_tenant_secret(
        v_tenant_id, 'webhook_secret', v_provider, v_secret
      );

      SELECT secret_id INTO v_secret_id
      FROM data.tenant_secret_refs
      WHERE tenant_id = v_tenant_id
        AND secret_type = 'webhook_secret'
        AND provider = v_provider;

      UPDATE data.tenant_webhooks
      SET secret_id = v_secret_id
      WHERE id = p_id;
    ELSE
      v_secret_id := v_row.secret_id;
    END IF;

    UPDATE data.tenant_webhooks SET
      label         = trim(p_label),
      endpoint_url  = trim(p_endpoint_url),
      events        = v_events,
      entity_types  = p_entity_types,
      is_active     = coalesce(p_is_active, is_active),
      secret_hint_suffix = CASE WHEN p_rotate_secret THEN right(v_secret, 4) ELSE secret_hint_suffix END,
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
    'secret',        v_return_secret,
    'secret_hint',   'whsec_…' || coalesce(v_row.secret_hint_suffix, '????'),
    'created_at',    v_row.created_at,
    'updated_at',    v_row.updated_at
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- get_webhook_dispatch_context
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_webhook_dispatch_context(
  p_webhook_id      uuid,
  p_delivery_log_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_webhook data.tenant_webhooks%ROWTYPE;
  v_log     data.webhook_delivery_log%ROWTYPE;
  v_secret  text;
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

  v_secret := api.get_tenant_secret(
    v_webhook.tenant_id,
    'webhook_secret',
    'webhook:' || v_webhook.id::text,
    'get_webhook_dispatch_context',
    'webhook_dispatch'
  );

  IF v_secret IS NULL AND v_webhook.secret_id IS NOT NULL THEN
    SELECT decrypted_secret INTO v_secret
    FROM vault.decrypted_secrets WHERE id = v_webhook.secret_id;
    PERFORM data.log_secret_access(
      v_webhook.tenant_id, 'webhook_secret', 'webhook:' || v_webhook.id::text,
      'get_webhook_dispatch_context', 'webhook_dispatch'
    );
  END IF;

  RETURN jsonb_build_object(
    'webhook_id',    v_webhook.id,
    'tenant_id',     v_webhook.tenant_id,
    'endpoint_url',  v_webhook.endpoint_url,
    'secret',        v_secret,
    'event_type',    v_log.event_type,
    'payload',       v_log.payload,
    'attempts',      v_log.attempts
  );
END;
$$;
