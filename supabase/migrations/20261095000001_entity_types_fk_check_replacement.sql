-- =============================================================================
-- ES-4 follow-up — Replace entity_type CHECKs with FK → data.entity_types
--
-- Scope (safe, 0 orphans today):
--   entity_subscriptions, entity_comment_templates, tenant_role_defaults,
--   documents, entity_comments, entity_timeline_watermarks, document_folders
--
-- Out of scope (orphans): audit_logs, notification_event_catalog
-- external_entity_mappings keeps employee-only CHECK (import scope).
--
-- Capability flags enforced via triggers (supports_subscriptions / timeline / signing).
-- RPCs that hard-coded the timeline quartet now consult the registry.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Capability helper
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.assert_entity_type_capability(
  p_code text,
  p_capability text
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_row data.entity_types%ROWTYPE;
  v_ok boolean := false;
BEGIN
  IF p_code IS NULL OR btrim(p_code) = '' THEN
    RAISE EXCEPTION 'entity_type_required'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT * INTO v_row FROM data.entity_types WHERE code = p_code;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown_entity_type: %', p_code
      USING ERRCODE = 'check_violation';
  END IF;

  v_ok := CASE p_capability
    WHEN 'timeline' THEN v_row.supports_timeline
    WHEN 'documents' THEN v_row.supports_documents
    WHEN 'signing' THEN v_row.supports_signing
    WHEN 'subscriptions' THEN v_row.supports_subscriptions
    ELSE false
  END;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'entity_type_capability_denied: % does not support %', p_code, p_capability
      USING ERRCODE = 'check_violation';
  END IF;
END;
$$;

COMMENT ON FUNCTION data.assert_entity_type_capability(text, text) IS
  'ES-4 follow-up: validate registry code + capability flag (timeline|documents|signing|subscriptions).';

REVOKE ALL ON FUNCTION data.assert_entity_type_capability(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.assert_entity_type_capability(text, text) TO service_role;

CREATE OR REPLACE FUNCTION data.entity_type_supports(
  p_code text,
  p_capability text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT CASE p_capability
    WHEN 'timeline' THEN coalesce(
      (SELECT supports_timeline FROM data.entity_types WHERE code = p_code), false)
    WHEN 'documents' THEN coalesce(
      (SELECT supports_documents FROM data.entity_types WHERE code = p_code), false)
    WHEN 'signing' THEN coalesce(
      (SELECT supports_signing FROM data.entity_types WHERE code = p_code), false)
    WHEN 'subscriptions' THEN coalesce(
      (SELECT supports_subscriptions FROM data.entity_types WHERE code = p_code), false)
    ELSE false
  END;
$$;

GRANT EXECUTE ON FUNCTION data.entity_type_supports(text, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Drop legacy CHECKs + add FKs
-- ---------------------------------------------------------------------------

ALTER TABLE data.entity_subscriptions
  DROP CONSTRAINT IF EXISTS entity_subscriptions_entity_type_check;

ALTER TABLE data.entity_subscriptions
  DROP CONSTRAINT IF EXISTS entity_subscriptions_entity_type_fkey;

ALTER TABLE data.entity_subscriptions
  ADD CONSTRAINT entity_subscriptions_entity_type_fkey
  FOREIGN KEY (entity_type) REFERENCES data.entity_types(code)
  ON UPDATE CASCADE
  ON DELETE RESTRICT;

ALTER TABLE data.entity_comment_templates
  DROP CONSTRAINT IF EXISTS entity_comment_templates_entity_type_check;

ALTER TABLE data.entity_comment_templates
  DROP CONSTRAINT IF EXISTS entity_comment_templates_entity_type_fkey;

-- nullable entity_type allowed (global templates)
ALTER TABLE data.entity_comment_templates
  ADD CONSTRAINT entity_comment_templates_entity_type_fkey
  FOREIGN KEY (entity_type) REFERENCES data.entity_types(code)
  ON UPDATE CASCADE
  ON DELETE RESTRICT;

ALTER TABLE data.tenant_role_defaults
  DROP CONSTRAINT IF EXISTS tenant_role_defaults_entity_type_check;

ALTER TABLE data.tenant_role_defaults
  DROP CONSTRAINT IF EXISTS tenant_role_defaults_entity_type_fkey;

ALTER TABLE data.tenant_role_defaults
  ADD CONSTRAINT tenant_role_defaults_entity_type_fkey
  FOREIGN KEY (entity_type) REFERENCES data.entity_types(code)
  ON UPDATE CASCADE
  ON DELETE RESTRICT;

-- Soft anchors (nullable OK; 0 orphans)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'documents_entity_type_fkey'
  ) THEN
    ALTER TABLE data.documents
      ADD CONSTRAINT documents_entity_type_fkey
      FOREIGN KEY (entity_type) REFERENCES data.entity_types(code)
      ON UPDATE CASCADE
      ON DELETE RESTRICT;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'entity_comments_entity_type_fkey'
  ) THEN
    ALTER TABLE data.entity_comments
      ADD CONSTRAINT entity_comments_entity_type_fkey
      FOREIGN KEY (entity_type) REFERENCES data.entity_types(code)
      ON UPDATE CASCADE
      ON DELETE RESTRICT;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'data' AND table_name = 'entity_timeline_watermarks'
  ) AND NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'entity_timeline_watermarks_entity_type_fkey'
  ) THEN
    ALTER TABLE data.entity_timeline_watermarks
      ADD CONSTRAINT entity_timeline_watermarks_entity_type_fkey
      FOREIGN KEY (entity_type) REFERENCES data.entity_types(code)
      ON UPDATE CASCADE
      ON DELETE RESTRICT;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'document_folders_entity_type_fkey'
  ) THEN
    ALTER TABLE data.document_folders
      ADD CONSTRAINT document_folders_entity_type_fkey
      FOREIGN KEY (entity_type) REFERENCES data.entity_types(code)
      ON UPDATE CASCADE
      ON DELETE RESTRICT;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Capability triggers (keep subscriptions/templates/signing scoped)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.trg_entity_subscriptions_capability()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  PERFORM data.assert_entity_type_capability(NEW.entity_type, 'subscriptions');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_entity_subscriptions_capability ON data.entity_subscriptions;
CREATE TRIGGER trg_entity_subscriptions_capability
  BEFORE INSERT OR UPDATE OF entity_type ON data.entity_subscriptions
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_entity_subscriptions_capability();

CREATE OR REPLACE FUNCTION data.trg_entity_comment_templates_capability()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF NEW.entity_type IS NULL THEN
    RETURN NEW;
  END IF;
  PERFORM data.assert_entity_type_capability(NEW.entity_type, 'timeline');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_entity_comment_templates_capability ON data.entity_comment_templates;
CREATE TRIGGER trg_entity_comment_templates_capability
  BEFORE INSERT OR UPDATE OF entity_type ON data.entity_comment_templates
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_entity_comment_templates_capability();

CREATE OR REPLACE FUNCTION data.trg_tenant_role_defaults_capability()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  PERFORM data.assert_entity_type_capability(NEW.entity_type, 'signing');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tenant_role_defaults_capability ON data.tenant_role_defaults;
CREATE TRIGGER trg_tenant_role_defaults_capability
  BEFORE INSERT OR UPDATE OF entity_type ON data.tenant_role_defaults
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_tenant_role_defaults_capability();

-- ---------------------------------------------------------------------------
-- Update subscription RPC + enqueue helper to use registry
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.set_entity_subscription(
  p_entity_type text,
  p_entity_id   uuid,
  p_subscribed  boolean DEFAULT true
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_user_id   uuid := auth.uid();
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF v_user_id IS NULL OR v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT data.entity_type_supports(p_entity_type, 'subscriptions') THEN
    RAISE EXCEPTION 'invalid_entity_type' USING ERRCODE = '22023';
  END IF;

  IF NOT data.can_view_entity(v_user_id, v_tenant_id, p_entity_type, p_entity_id, NULL) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF coalesce(p_subscribed, true) THEN
    INSERT INTO data.entity_subscriptions (user_id, tenant_id, entity_type, entity_id)
    VALUES (v_user_id, v_tenant_id, p_entity_type, p_entity_id)
    ON CONFLICT (user_id, entity_type, entity_id) DO NOTHING;
    RETURN true;
  END IF;

  DELETE FROM data.entity_subscriptions
  WHERE user_id = v_user_id
    AND tenant_id = v_tenant_id
    AND entity_type = p_entity_type
    AND entity_id = p_entity_id;

  RETURN false;
END;
$$;

CREATE OR REPLACE FUNCTION data.enqueue_entity_subscription_notifications(
  p_tenant_id uuid,
  p_site_id uuid,
  p_entity_type text,
  p_entity_id uuid,
  p_actor_user_id uuid,
  p_activity_kind text,
  p_source_id uuid,
  p_payload jsonb,
  p_exclude_users uuid[] DEFAULT ARRAY[]::uuid[]
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
DECLARE
  v_subscriber uuid;
  v_exclude    uuid[];
BEGIN
  IF NOT data.entity_type_supports(p_entity_type, 'subscriptions') THEN
    RETURN;
  END IF;

  v_exclude := array_append(coalesce(p_exclude_users, ARRAY[]::uuid[]), p_actor_user_id);

  FOR v_subscriber IN
    SELECT es.user_id
    FROM data.entity_subscriptions es
    WHERE es.tenant_id = p_tenant_id
      AND es.entity_type = p_entity_type
      AND es.entity_id = p_entity_id
      AND es.user_id IS DISTINCT FROM p_actor_user_id
      AND NOT (es.user_id = ANY (v_exclude))
      AND data.is_active_tenant_member(p_tenant_id, es.user_id)
      AND data.can_view_entity(es.user_id, p_tenant_id, p_entity_type, p_entity_id, p_site_id)
  LOOP
    BEGIN
      PERFORM data.enqueue_notification_dispatch(jsonb_build_object(
        'tenantId',      p_tenant_id,
        'siteId',        p_site_id,
        'eventType',     'ENTITY_TIMELINE_ACTIVITY',
        'correlationId', 'entity_sub:' || p_activity_kind || ':' || p_source_id::text || ':' || v_subscriber::text,
        'recipient',     jsonb_build_object('kind', 'tenant_member', 'userId', v_subscriber),
        'entityType',    p_entity_type,
        'entityId',      p_entity_id,
        'actorUserId',   p_actor_user_id,
        'payload',       p_payload
      ));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'enqueue_entity_subscription_notifications: %', SQLERRM;
    END;
  END LOOP;
END;
$$;

COMMENT ON TABLE data.entity_types IS
  'Canonical polymorphic entity_type registry. CHECKs on subscriptions/templates/signing '
  'replaced by FK + capability triggers (ES-4 follow-up). audit_logs / notification_event_catalog '
  'remain unconstrained (orphan codes). New polymorphic tables must register a code here.';
