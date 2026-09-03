-- =============================================================================
-- Notification Engine — F3 (parcial): digest push per esdeveniments digest_eligible
-- =============================================================================
-- Agrupa push per digest_group_key = event_code:entity_id:recipient_id
-- dins una finestra fixa (5 min des del primer esdeveniment del bucket).
-- in_app i email continuen immediats al worker.
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.notification_digest_buckets (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  group_key       text NOT NULL,
  event_code      text NOT NULL,
  recipient_id    uuid NOT NULL,
  recipient_kind  data.notification_recipient_kind NOT NULL DEFAULT 'tenant_member',
  entity_type     text,
  entity_id       uuid,
  site_id         uuid,
  item_count      integer NOT NULL DEFAULT 1 CHECK (item_count > 0),
  latest_payload  jsonb NOT NULL DEFAULT '{}'::jsonb,
  flush_after     timestamptz NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT notification_digest_buckets_unique UNIQUE (tenant_id, group_key)
);

CREATE INDEX IF NOT EXISTS notification_digest_buckets_flush_after_idx
  ON data.notification_digest_buckets (flush_after);

ALTER TABLE data.notification_digest_buckets ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE data.notification_digest_buckets FROM PUBLIC;
GRANT ALL ON TABLE data.notification_digest_buckets TO service_role;

-- -----------------------------------------------------------------------------
-- Acumular esdeveniment digest-eligible (finestra fixa des del primer item)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.accumulate_notification_digest(
  p_tenant_id       uuid,
  p_event_code      text,
  p_recipient_id    uuid,
  p_recipient_kind  data.notification_recipient_kind DEFAULT 'tenant_member',
  p_entity_type     text DEFAULT NULL,
  p_entity_id       uuid DEFAULT NULL,
  p_site_id         uuid DEFAULT NULL,
  p_group_key       text DEFAULT NULL,
  p_payload         jsonb DEFAULT '{}'::jsonb,
  p_window_seconds  integer DEFAULT 300
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_group_key text;
  v_flush_after timestamptz;
  v_count integer;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  v_group_key := COALESCE(
    NULLIF(trim(p_group_key), ''),
    p_event_code || ':' || COALESCE(p_entity_id::text, '') || ':' || p_recipient_id::text
  );

  v_flush_after := now() + make_interval(secs => GREATEST(p_window_seconds, 60));

  INSERT INTO data.notification_digest_buckets (
    tenant_id,
    group_key,
    event_code,
    recipient_id,
    recipient_kind,
    entity_type,
    entity_id,
    site_id,
    item_count,
    latest_payload,
    flush_after
  ) VALUES (
    p_tenant_id,
    v_group_key,
    p_event_code,
    p_recipient_id,
    p_recipient_kind,
    p_entity_type,
    p_entity_id,
    p_site_id,
    1,
    COALESCE(p_payload, '{}'::jsonb),
    v_flush_after
  )
  ON CONFLICT (tenant_id, group_key) DO UPDATE SET
    item_count     = data.notification_digest_buckets.item_count + 1,
    latest_payload = EXCLUDED.latest_payload,
    updated_at     = now()
  RETURNING item_count, flush_after
  INTO v_count, v_flush_after;

  RETURN jsonb_build_object(
    'groupKey',    v_group_key,
    'itemCount',   v_count,
    'flushAfter',  v_flush_after
  );
END;
$$;

REVOKE ALL ON FUNCTION api.accumulate_notification_digest(
  uuid, text, uuid, data.notification_recipient_kind, text, uuid, uuid, text, jsonb, integer
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.accumulate_notification_digest(
  uuid, text, uuid, data.notification_recipient_kind, text, uuid, uuid, text, jsonb, integer
) TO service_role;

-- -----------------------------------------------------------------------------
-- Flush buckets madurs → retorna files per al worker (push agrupat)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.flush_notification_digests(p_limit integer DEFAULT 50)
RETURNS TABLE (
  tenant_id       uuid,
  event_code      text,
  recipient_id    uuid,
  recipient_kind  data.notification_recipient_kind,
  entity_type     text,
  entity_id       uuid,
  site_id         uuid,
  group_key       text,
  item_count      integer,
  latest_payload  jsonb,
  correlation_id  text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  RETURN QUERY
  WITH due AS (
    SELECT b.*
    FROM data.notification_digest_buckets b
    WHERE b.flush_after <= now()
    ORDER BY b.flush_after ASC
    LIMIT GREATEST(COALESCE(p_limit, 50), 1)
    FOR UPDATE SKIP LOCKED
  ),
  deleted AS (
    DELETE FROM data.notification_digest_buckets b
    USING due d
    WHERE b.id = d.id
    RETURNING
      d.tenant_id,
      d.event_code,
      d.recipient_id,
      d.recipient_kind,
      d.entity_type,
      d.entity_id,
      d.site_id,
      d.group_key,
      d.item_count,
      d.latest_payload,
      'digest:' || d.group_key || ':' || d.id::text AS correlation_id
  )
  SELECT * FROM deleted;
END;
$$;

REVOKE ALL ON FUNCTION api.flush_notification_digests(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.flush_notification_digests(integer) TO service_role;

NOTIFY pgrst, 'reload schema';
