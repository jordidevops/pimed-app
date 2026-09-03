-- Entity Timeline — subscripcions a entitat (seguir activitat)

CREATE TABLE data.entity_subscriptions (
  user_id     uuid NOT NULL REFERENCES data.profiles(id) ON DELETE CASCADE,
  tenant_id   uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  entity_type text NOT NULL,
  entity_id   uuid NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (user_id, entity_type, entity_id),

  CONSTRAINT entity_subscriptions_entity_type_check
    CHECK (entity_type IN ('employee', 'contact', 'project', 'document'))
);

CREATE INDEX idx_entity_subscriptions_entity
  ON data.entity_subscriptions (tenant_id, entity_type, entity_id);

ALTER TABLE data.entity_subscriptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY entity_subscriptions_select ON data.entity_subscriptions
  FOR SELECT TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND user_id = auth.uid()
  );

CREATE POLICY entity_subscriptions_insert ON data.entity_subscriptions
  FOR INSERT TO authenticated
  WITH CHECK (
    tenant_id = data.active_tenant_id()
    AND user_id = auth.uid()
    AND data.can_view_entity(auth.uid(), tenant_id, entity_type, entity_id, NULL)
  );

CREATE POLICY entity_subscriptions_delete ON data.entity_subscriptions
  FOR DELETE TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND user_id = auth.uid()
  );

GRANT SELECT, INSERT, DELETE ON data.entity_subscriptions TO authenticated;

-- -----------------------------------------------------------------------------
-- Deep link sense comment (events audit)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.entity_timeline_entity_link(
  p_entity_type text,
  p_entity_id   uuid
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_entity_type
    WHEN 'employee' THEN '/employees/' || p_entity_id::text || '?tab=activity'
    WHEN 'contact'  THEN '/contacts/' || p_entity_id::text || '#contact-activity'
    WHEN 'project'  THEN '/projects/' || p_entity_id::text || '#project-activity'
    WHEN 'document' THEN '/documents/' || p_entity_id::text || '#document-activity'
    ELSE '/comments/' || p_entity_id::text
  END;
$$;

-- -----------------------------------------------------------------------------
-- Notificacions a subscriptors
-- -----------------------------------------------------------------------------

INSERT INTO data.notification_event_catalog (
  event_code, category, entity_type, deep_link_template,
  default_channels, requires_legal, digest_eligible, description
) VALUES (
  'ENTITY_TIMELINE_ACTIVITY',
  'operations',
  'entity_comment',
  '/employees/{entity_id}?tab=activity',
  '{in_app,push,email}',
  false,
  true,
  'Nova activitat a una entitat que segueixes (comentari o event del sistema)'
)
ON CONFLICT (event_code) DO NOTHING;

CREATE OR REPLACE FUNCTION data.enqueue_entity_subscription_notifications(
  p_tenant_id       uuid,
  p_site_id         uuid,
  p_entity_type     text,
  p_entity_id       uuid,
  p_actor_user_id   uuid,
  p_activity_kind   text,
  p_source_id       uuid,
  p_payload         jsonb,
  p_exclude_users   uuid[] DEFAULT ARRAY[]::uuid[]
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
  IF p_entity_type NOT IN ('employee', 'contact', 'project', 'document') THEN
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

REVOKE ALL ON FUNCTION data.enqueue_entity_subscription_notifications(
  uuid, uuid, text, uuid, uuid, text, uuid, jsonb, uuid[]
) FROM PUBLIC;

-- Ampliar notificacions de comentari: subscriptors (només arrels)
CREATE OR REPLACE FUNCTION data.enqueue_entity_comment_notifications(p_comment_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
DECLARE
  v_comment       record;
  v_parent_author uuid;
  v_recipient     uuid;
  v_author_name   text;
  v_deep_link     text;
  v_base_payload  jsonb;
BEGIN
  SELECT c.*, p.full_name AS author_full_name
  INTO v_comment
  FROM data.entity_comments c
  LEFT JOIN data.profiles p ON p.id = c.user_id
  WHERE c.id = p_comment_id;

  IF NOT FOUND OR v_comment.deleted_at IS NOT NULL THEN
    RETURN;
  END IF;

  v_author_name := coalesce(v_comment.author_full_name, 'Algú');
  v_deep_link := data.entity_timeline_deep_link(
    v_comment.entity_type,
    v_comment.entity_id,
    v_comment.id
  );

  v_base_payload := jsonb_build_object(
    'comment_id',      v_comment.id,
    'entity_type',     v_comment.entity_type,
    'entity_id',       v_comment.entity_id,
    'author_id',       v_comment.user_id,
    'author_name',     v_author_name,
    'content_preview', left(data.humanize_entity_comment_mentions(v_comment.content), 200),
    'deep_link',       v_deep_link,
    'entity_label',    data.entity_timeline_entity_label(v_comment.entity_type, v_comment.entity_id),
    'activity_kind',   'comment'
  );

  FOREACH v_recipient IN ARRAY v_comment.mentions LOOP
    IF v_recipient IS DISTINCT FROM v_comment.user_id
       AND data.is_active_tenant_member(v_comment.tenant_id, v_recipient) THEN
      BEGIN
        PERFORM data.enqueue_notification_dispatch(jsonb_build_object(
          'tenantId',      v_comment.tenant_id,
          'siteId',        v_comment.site_id,
          'eventType',     'MENTION_CREATED',
          'correlationId', 'mention:' || p_comment_id::text || ':' || v_recipient::text,
          'recipient',     jsonb_build_object('kind', 'tenant_member', 'userId', v_recipient),
          'entityType',    v_comment.entity_type,
          'entityId',      v_comment.entity_id,
          'actorUserId',   v_comment.user_id,
          'payload',       v_base_payload
        ));
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'enqueue_entity_comment_notifications mention: %', SQLERRM;
      END;
    END IF;
  END LOOP;

  IF v_comment.parent_id IS NOT NULL THEN
    SELECT user_id INTO v_parent_author
    FROM data.entity_comments
    WHERE id = v_comment.parent_id;

    IF v_parent_author IS NOT NULL
       AND v_parent_author IS DISTINCT FROM v_comment.user_id
       AND NOT (v_parent_author = ANY (v_comment.mentions))
       AND data.is_active_tenant_member(v_comment.tenant_id, v_parent_author) THEN
      BEGIN
        PERFORM data.enqueue_notification_dispatch(jsonb_build_object(
          'tenantId',      v_comment.tenant_id,
          'siteId',        v_comment.site_id,
          'eventType',     'MENTION_CREATED',
          'correlationId', 'reply:' || p_comment_id::text || ':' || v_parent_author::text,
          'recipient',     jsonb_build_object('kind', 'tenant_member', 'userId', v_parent_author),
          'entityType',    v_comment.entity_type,
          'entityId',      v_comment.entity_id,
          'actorUserId',   v_comment.user_id,
          'payload',       v_base_payload || jsonb_build_object('is_reply', true)
        ));
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'enqueue_entity_comment_notifications reply: %', SQLERRM;
      END;
    END IF;
  END IF;

  IF v_comment.parent_id IS NULL THEN
    PERFORM data.enqueue_entity_subscription_notifications(
      v_comment.tenant_id,
      v_comment.site_id,
      v_comment.entity_type,
      v_comment.entity_id,
      v_comment.user_id,
      'comment',
      v_comment.id,
      v_base_payload,
      coalesce(v_comment.mentions, ARRAY[]::uuid[])
    );
  END IF;
END;
$$;

-- Trigger audit → subscriptors
CREATE OR REPLACE FUNCTION data.trg_audit_logs_entity_subscriptions()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_actor_name text;
BEGIN
  IF NEW.entity_type NOT IN ('employee', 'contact', 'project', 'document')
     OR NEW.entity_id IS NULL
     OR NEW.tenant_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT p.full_name INTO v_actor_name
  FROM data.profiles p
  WHERE p.id = NEW.user_id;

  PERFORM data.enqueue_entity_subscription_notifications(
    NEW.tenant_id,
    NEW.site_id,
    NEW.entity_type,
    NEW.entity_id,
    NEW.user_id,
    'audit',
    NEW.id,
    jsonb_build_object(
      'activity_kind', 'audit',
      'audit_id',      NEW.id,
      'action',        NEW.action,
      'entity_type',   NEW.entity_type,
      'entity_id',     NEW.entity_id,
      'entity_label',  data.entity_timeline_entity_label(NEW.entity_type, NEW.entity_id),
      'deep_link',     data.entity_timeline_entity_link(NEW.entity_type, NEW.entity_id),
      'actor_name',    coalesce(v_actor_name, 'Sistema')
    ),
    ARRAY[]::uuid[]
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_logs_entity_subscriptions ON data.audit_logs;
CREATE TRIGGER trg_audit_logs_entity_subscriptions
  AFTER INSERT ON data.audit_logs
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_logs_entity_subscriptions();

-- -----------------------------------------------------------------------------
-- RPCs
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.get_entity_subscription_status(
  p_entity_type text,
  p_entity_id   uuid
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

  IF NOT data.can_view_entity(v_user_id, v_tenant_id, p_entity_type, p_entity_id, NULL) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM data.entity_subscriptions es
    WHERE es.user_id = v_user_id
      AND es.tenant_id = v_tenant_id
      AND es.entity_type = p_entity_type
      AND es.entity_id = p_entity_id
  );
END;
$$;

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

  IF p_entity_type NOT IN ('employee', 'contact', 'project', 'document') THEN
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

GRANT EXECUTE ON FUNCTION api.get_entity_subscription_status(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.set_entity_subscription(text, uuid, boolean) TO authenticated;
