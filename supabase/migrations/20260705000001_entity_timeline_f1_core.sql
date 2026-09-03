-- =============================================================================
-- Entity Timeline — Fase 1 (core schema, RPCs, notificacions MENTION_CREATED)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Helpers RBAC per entitat (D17)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.is_active_tenant_member(
  p_tenant_id uuid,
  p_user_id   uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM data.tenant_members tm
    WHERE tm.tenant_id = p_tenant_id
      AND tm.user_id = p_user_id
      AND tm.is_active = true
  );
$$;

CREATE OR REPLACE FUNCTION data.can_view_entity(
  p_user_id     uuid,
  p_tenant_id   uuid,
  p_entity_type text,
  p_entity_id   uuid,
  p_site_id     uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT CASE
    WHEN NOT (data.jwt_user_tenants() ? p_tenant_id::text) THEN false
    WHEN p_entity_type = 'employee' THEN EXISTS (
      SELECT 1 FROM data.employees e
      WHERE e.id = p_entity_id AND e.tenant_id = p_tenant_id
    )
    WHEN p_entity_type = 'contact' THEN EXISTS (
      SELECT 1 FROM data.contacts c
      WHERE c.id = p_entity_id AND c.tenant_id = p_tenant_id
    )
    WHEN p_entity_type = 'project' THEN data.can_access_project(p_entity_id)
    WHEN p_entity_type = 'document' THEN EXISTS (
      SELECT 1 FROM data.documents d
      WHERE d.id = p_entity_id AND d.tenant_id = p_tenant_id
    )
    ELSE false
  END;
$$;

CREATE OR REPLACE FUNCTION data.can_edit_entity(
  p_user_id     uuid,
  p_tenant_id   uuid,
  p_entity_type text,
  p_entity_id   uuid,
  p_site_id     uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT CASE
    WHEN NOT data.can_view_entity(p_user_id, p_tenant_id, p_entity_type, p_entity_id, p_site_id) THEN false
    WHEN p_entity_type = 'employee' THEN
      (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR data.jwt_has_permission(p_tenant_id, 'hr.manage', p_site_id)
      OR data.is_active_tenant_member(p_tenant_id, p_user_id)
    WHEN p_entity_type = 'contact' THEN
      (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role')
        IN ('owner', 'manager', 'member')
    WHEN p_entity_type = 'project' THEN
      data.can_access_project(p_entity_id)
      AND (
        (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
        OR data.is_active_tenant_member(p_tenant_id, p_user_id)
      )
    WHEN p_entity_type = 'document' THEN
      data.can_view_entity(p_user_id, p_tenant_id, p_entity_type, p_entity_id, p_site_id)
    ELSE false
  END;
$$;

REVOKE ALL ON FUNCTION data.is_active_tenant_member(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.can_view_entity(uuid, uuid, text, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.can_edit_entity(uuid, uuid, text, uuid, uuid) FROM PUBLIC;

-- -----------------------------------------------------------------------------
-- 2. Taules
-- -----------------------------------------------------------------------------

CREATE TABLE data.entity_comments (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id             uuid REFERENCES data.sites(id) ON DELETE SET NULL,
  entity_type         text NOT NULL,
  entity_id           uuid NOT NULL,
  user_id             uuid REFERENCES data.profiles(id),
  actor_type          text NOT NULL DEFAULT 'user'
                      CHECK (actor_type IN ('user', 'ai', 'automation', 'system')),
  actor_metadata      jsonb NOT NULL DEFAULT '{}',
  content             text NOT NULL,
  parent_id           uuid,
  mentions            uuid[] NOT NULL DEFAULT '{}',
  attachments         jsonb NOT NULL DEFAULT '[]',
  visibility          text NOT NULL DEFAULT 'internal'
                      CHECK (visibility IN ('internal', 'tenant_member', 'contact')),
  is_task             boolean NOT NULL DEFAULT false,
  is_ai_context_note  boolean NOT NULL DEFAULT false,
  due_date            timestamptz,
  resolved_at         timestamptz,
  resolved_by         uuid REFERENCES data.profiles(id),
  pinned_at           timestamptz,
  pinned_by           uuid REFERENCES data.profiles(id),
  edited_at           timestamptz,
  revision_count      integer NOT NULL DEFAULT 0,
  reply_count         integer NOT NULL DEFAULT 0,
  deleted_at          timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT entity_comments_content_not_empty
    CHECK (length(trim(content)) > 0 OR deleted_at IS NOT NULL),

  CONSTRAINT entity_comments_no_self_parent
    CHECK (parent_id IS NULL OR parent_id <> id),

  CONSTRAINT entity_comments_user_required_for_human
    CHECK (actor_type = 'user' AND user_id IS NOT NULL OR actor_type <> 'user')
);

ALTER TABLE data.entity_comments
  ADD CONSTRAINT entity_comments_parent_fk
  FOREIGN KEY (parent_id) REFERENCES data.entity_comments(id) ON DELETE RESTRICT;

CREATE INDEX idx_entity_comments_timeline
  ON data.entity_comments (tenant_id, entity_type, entity_id, created_at DESC)
  WHERE deleted_at IS NULL AND parent_id IS NULL;

CREATE INDEX idx_entity_comments_roots_all
  ON data.entity_comments (tenant_id, entity_type, entity_id, created_at DESC)
  WHERE parent_id IS NULL;

CREATE INDEX idx_entity_comments_replies
  ON data.entity_comments (parent_id, created_at ASC)
  WHERE deleted_at IS NULL;

CREATE INDEX idx_entity_comments_mentions_gin
  ON data.entity_comments USING gin (mentions);

CREATE INDEX idx_entity_comments_open_tasks
  ON data.entity_comments (tenant_id, entity_type, entity_id)
  WHERE is_task = true AND resolved_at IS NULL AND deleted_at IS NULL;

CREATE INDEX idx_entity_comments_ai_context
  ON data.entity_comments (tenant_id, entity_type, entity_id, created_at DESC)
  WHERE is_ai_context_note = true AND deleted_at IS NULL;

CREATE TABLE data.entity_timeline_watermarks (
  user_id      uuid NOT NULL REFERENCES data.profiles(id) ON DELETE CASCADE,
  tenant_id    uuid NOT NULL,
  entity_type  text NOT NULL,
  entity_id    uuid NOT NULL,
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, entity_type, entity_id)
);

CREATE INDEX idx_entity_timeline_watermarks_tenant
  ON data.entity_timeline_watermarks (tenant_id, entity_type, entity_id);

CREATE TABLE data.entity_comment_revisions (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  comment_id     uuid NOT NULL REFERENCES data.entity_comments(id) ON DELETE CASCADE,
  tenant_id      uuid NOT NULL,
  user_id        uuid REFERENCES data.profiles(id),
  content_before text NOT NULL,
  edited_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_entity_comment_revisions_comment
  ON data.entity_comment_revisions (comment_id, edited_at DESC);

CREATE INDEX IF NOT EXISTS idx_audit_logs_entity_timeline
  ON data.audit_logs (tenant_id, entity_type, entity_id, created_at DESC);

-- -----------------------------------------------------------------------------
-- 3. Triggers i funcions auxiliars
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.extract_entity_comment_mentions(p_content text)
RETURNS uuid[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT COALESCE(
    array_agg(DISTINCT (m)[1]::uuid),
    '{}'::uuid[]
  )
  FROM regexp_matches(
    coalesce(p_content, ''),
    '\[\[@([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\|[^\]]*\]\]',
    'g'
  ) AS m;
$$;

CREATE OR REPLACE FUNCTION data.entity_comments_parent_must_be_root()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.parent_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.entity_comments p
      WHERE p.id = NEW.parent_id
        AND p.parent_id IS NULL
        AND p.tenant_id = NEW.tenant_id
        AND p.entity_type = NEW.entity_type
        AND p.entity_id = NEW.entity_id
        AND p.deleted_at IS NULL
    ) THEN
      RAISE EXCEPTION 'parent_id must reference a root comment on the same entity';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION data.trg_entity_comments_extract_mentions()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.mentions := data.extract_entity_comment_mentions(NEW.content);
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION data.entity_comments_update_reply_count()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'INSERT' AND NEW.parent_id IS NOT NULL THEN
    UPDATE data.entity_comments
    SET reply_count = reply_count + 1
    WHERE id = NEW.parent_id;
  ELSIF TG_OP = 'UPDATE'
    AND NEW.deleted_at IS NOT NULL
    AND OLD.deleted_at IS NULL
    AND NEW.parent_id IS NOT NULL THEN
    UPDATE data.entity_comments
    SET reply_count = GREATEST(reply_count - 1, 0)
    WHERE id = NEW.parent_id;
  END IF;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION data.trg_entity_comments_revisions()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.content IS DISTINCT FROM OLD.content AND OLD.deleted_at IS NULL THEN
    INSERT INTO data.entity_comment_revisions (
      comment_id, tenant_id, user_id, content_before
    ) VALUES (
      OLD.id, OLD.tenant_id, auth.uid(), OLD.content
    );
    NEW.revision_count := OLD.revision_count + 1;
    NEW.edited_at := now();
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION data.trg_entity_comments_audit_task_resolved()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF NEW.is_task
     AND OLD.resolved_at IS NULL
     AND NEW.resolved_at IS NOT NULL
     AND NEW.deleted_at IS NULL THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      auth.uid(),
      NEW.site_id,
      'COMMENT_TASK_RESOLVED',
      NEW.entity_type,
      NEW.entity_id,
      jsonb_build_object(
        'comment_id', NEW.id,
        'task_preview', left(NEW.content, 120),
        'resolved_by', NEW.resolved_by
      )
    );
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_entity_comments_updated_at
  BEFORE UPDATE ON data.entity_comments
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

CREATE TRIGGER trg_entity_comments_parent_must_be_root
  BEFORE INSERT OR UPDATE OF parent_id ON data.entity_comments
  FOR EACH ROW EXECUTE FUNCTION data.entity_comments_parent_must_be_root();

CREATE TRIGGER trg_entity_comments_extract_mentions
  BEFORE INSERT OR UPDATE OF content ON data.entity_comments
  FOR EACH ROW EXECUTE FUNCTION data.trg_entity_comments_extract_mentions();

CREATE TRIGGER trg_entity_comments_reply_count
  AFTER INSERT OR UPDATE OF deleted_at ON data.entity_comments
  FOR EACH ROW EXECUTE FUNCTION data.entity_comments_update_reply_count();

CREATE TRIGGER trg_entity_comments_revisions
  BEFORE UPDATE OF content ON data.entity_comments
  FOR EACH ROW EXECUTE FUNCTION data.trg_entity_comments_revisions();

CREATE TRIGGER trg_entity_comments_audit_task_resolved
  AFTER UPDATE OF resolved_at ON data.entity_comments
  FOR EACH ROW EXECUTE FUNCTION data.trg_entity_comments_audit_task_resolved();

-- -----------------------------------------------------------------------------
-- 4. Notificacions asíncrones (D6)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.enqueue_entity_comment_notifications(p_comment_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
DECLARE
  v_comment record;
  v_parent_author uuid;
  v_recipient uuid;
BEGIN
  SELECT * INTO v_comment FROM data.entity_comments WHERE id = p_comment_id;
  IF NOT FOUND OR v_comment.deleted_at IS NOT NULL THEN
    RETURN;
  END IF;

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
          'payload',       jsonb_build_object(
            'comment_id',   v_comment.id,
            'entity_type',  v_comment.entity_type,
            'entity_id',    v_comment.entity_id,
            'author_id',    v_comment.user_id,
            'content_preview', left(v_comment.content, 200)
          )
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
          'payload',       jsonb_build_object(
            'comment_id',   v_comment.id,
            'entity_type',  v_comment.entity_type,
            'entity_id',    v_comment.entity_id,
            'author_id',    v_comment.user_id,
            'is_reply',     true,
            'content_preview', left(v_comment.content, 200)
          )
        ));
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'enqueue_entity_comment_notifications reply: %', SQLERRM;
      END;
    END IF;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION data.trg_entity_comments_enqueue_notifications()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  PERFORM data.enqueue_entity_comment_notifications(NEW.id);
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_entity_comments_enqueue_notifications
  AFTER INSERT ON data.entity_comments
  FOR EACH ROW EXECUTE FUNCTION data.trg_entity_comments_enqueue_notifications();

REVOKE ALL ON FUNCTION data.enqueue_entity_comment_notifications(uuid) FROM PUBLIC;

-- -----------------------------------------------------------------------------
-- 5. Humanització audit
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.timeline_audit_message_vars(
  p_action  text,
  p_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_changes jsonb;
BEGIN
  CASE p_action
    WHEN 'EMPLOYEE_CREATED' THEN
      RETURN jsonb_build_object('name', coalesce(p_payload ->> 'full_name', p_payload ->> 'name'));
    WHEN 'EMPLOYEE_UPDATED' THEN
      IF p_payload ? 'changes' THEN
        RETURN jsonb_build_object(
          'changes', p_payload -> 'changes',
          'change_count', jsonb_array_length(p_payload -> 'changes')
        );
      END IF;
      RETURN jsonb_build_object('changes', '[]'::jsonb, 'change_count', 0);
    WHEN 'EMPLOYEE_TERMINATED' THEN
      RETURN jsonb_build_object(
        'name', coalesce(p_payload ->> 'full_name', p_payload ->> 'name'),
        'ends_on', p_payload ->> 'ends_on'
      );
    WHEN 'CONTACT_CREATED', 'CONTACT_ARCHIVED', 'CONTACT_UNARCHIVED' THEN
      RETURN jsonb_build_object('name', coalesce(p_payload ->> 'display_name', p_payload ->> 'name'));
    WHEN 'CONTACT_UPDATED' THEN
      IF p_payload ? 'changes' THEN
        RETURN jsonb_build_object(
          'changes', p_payload -> 'changes',
          'change_count', jsonb_array_length(p_payload -> 'changes')
        );
      END IF;
      RETURN jsonb_build_object('changes', '[]'::jsonb, 'change_count', 0);
    WHEN 'COMMENT_TASK_RESOLVED' THEN
      RETURN jsonb_build_object(
        'task_preview', p_payload ->> 'task_preview',
        'resolver_id', p_payload ->> 'resolved_by'
      );
    WHEN 'PROJECT_STATUS_CHANGED' THEN
      RETURN jsonb_build_object(
        'old', coalesce(p_payload ->> 'old_status', p_payload #>> '{old,status}'),
        'new', coalesce(p_payload ->> 'new_status', p_payload #>> '{new,status}')
      );
    ELSE
      RETURN jsonb_build_object('action', p_action);
  END CASE;
END;
$$;

CREATE OR REPLACE FUNCTION data.timeline_audit_message_key(p_action text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_action
    WHEN 'EMPLOYEE_CREATED' THEN 'timeline.audit.EMPLOYEE_CREATED'
    WHEN 'EMPLOYEE_UPDATED' THEN 'timeline.audit.EMPLOYEE_UPDATED'
    WHEN 'EMPLOYEE_TERMINATED' THEN 'timeline.audit.EMPLOYEE_TERMINATED'
    WHEN 'EMPLOYEE_DELETED' THEN 'timeline.audit.EMPLOYEE_DELETED'
    WHEN 'CONTACT_CREATED' THEN 'timeline.audit.CONTACT_CREATED'
    WHEN 'CONTACT_UPDATED' THEN 'timeline.audit.CONTACT_UPDATED'
    WHEN 'CONTACT_ARCHIVED' THEN 'timeline.audit.CONTACT_ARCHIVED'
    WHEN 'CONTACT_UNARCHIVED' THEN 'timeline.audit.CONTACT_UNARCHIVED'
    WHEN 'COMMENT_TASK_RESOLVED' THEN 'timeline.audit.TASK_RESOLVED'
    WHEN 'PROJECT_STATUS_CHANGED' THEN 'timeline.audit.PROJECT_STATUS'
    ELSE 'timeline.audit.GENERIC'
  END;
$$;

-- -----------------------------------------------------------------------------
-- 6. RLS
-- -----------------------------------------------------------------------------

ALTER TABLE data.entity_comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.entity_timeline_watermarks ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.entity_comment_revisions ENABLE ROW LEVEL SECURITY;

CREATE POLICY entity_comments_select ON data.entity_comments
  FOR SELECT TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND data.can_view_entity(auth.uid(), tenant_id, entity_type, entity_id, site_id)
  );

CREATE POLICY entity_comments_insert ON data.entity_comments
  FOR INSERT TO authenticated
  WITH CHECK (
    tenant_id = data.active_tenant_id()
    AND user_id = auth.uid()
    AND actor_type = 'user'
    AND data.can_edit_entity(auth.uid(), tenant_id, entity_type, entity_id, site_id)
  );

CREATE POLICY entity_comments_update ON data.entity_comments
  FOR UPDATE TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND (
      user_id = auth.uid()
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
    AND data.can_edit_entity(auth.uid(), tenant_id, entity_type, entity_id, site_id)
  )
  WITH CHECK (
    tenant_id = data.active_tenant_id()
    AND data.can_edit_entity(auth.uid(), tenant_id, entity_type, entity_id, site_id)
  );

CREATE POLICY entity_timeline_watermarks_self ON data.entity_timeline_watermarks
  FOR ALL TO authenticated
  USING (user_id = auth.uid() AND tenant_id = data.active_tenant_id())
  WITH CHECK (user_id = auth.uid() AND tenant_id = data.active_tenant_id());

CREATE POLICY entity_comment_revisions_select ON data.entity_comment_revisions
  FOR SELECT TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND EXISTS (
      SELECT 1 FROM data.entity_comments ec
      WHERE ec.id = entity_comment_revisions.comment_id
        AND data.can_view_entity(auth.uid(), ec.tenant_id, ec.entity_type, ec.entity_id, ec.site_id)
    )
  );

GRANT SELECT, INSERT, UPDATE ON data.entity_comments TO authenticated;
GRANT SELECT, INSERT, UPDATE ON data.entity_timeline_watermarks TO authenticated;
GRANT SELECT ON data.entity_comment_revisions TO authenticated;

-- -----------------------------------------------------------------------------
-- 7. RPCs api.*
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.search_tenant_members_for_mention(
  p_query text DEFAULT '',
  p_limit integer DEFAULT 10
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_user_id   uuid := auth.uid();
BEGIN
  IF v_tenant_id IS NULL OR v_user_id IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(row_to_json(x)::jsonb)
    FROM (
      SELECT DISTINCT ON (p.id)
        p.id,
        p.full_name,
        p.avatar_url
      FROM data.tenant_members tm
      JOIN data.profiles p ON p.id = tm.user_id
      WHERE tm.tenant_id = v_tenant_id
        AND tm.is_active = true
        AND (
          p_query IS NULL OR trim(p_query) = ''
          OR p.full_name ILIKE '%' || trim(p_query) || '%'
        )
      ORDER BY p.id, p.full_name
      LIMIT LEAST(GREATEST(p_limit, 1), 25)
    ) x
  ), '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION api.insert_entity_comment(
  p_entity_type   text,
  p_entity_id     uuid,
  p_content       text,
  p_parent_id     uuid DEFAULT NULL,
  p_is_task       boolean DEFAULT false,
  p_site_id       uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_user_id   uuid := auth.uid();
  v_tenant_id uuid := data.active_tenant_id();
  v_id        uuid;
  v_mention   uuid;
BEGIN
  IF v_user_id IS NULL OR v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT data.can_edit_entity(v_user_id, v_tenant_id, p_entity_type, p_entity_id, p_site_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF length(trim(p_content)) = 0 THEN
    RAISE EXCEPTION 'content_required' USING ERRCODE = 'check_violation';
  END IF;

  FOREACH v_mention IN ARRAY data.extract_entity_comment_mentions(p_content) LOOP
    IF NOT data.is_active_tenant_member(v_tenant_id, v_mention) THEN
      RAISE EXCEPTION 'invalid_mention: %', v_mention USING ERRCODE = 'check_violation';
    END IF;
  END LOOP;

  INSERT INTO data.entity_comments (
    tenant_id, site_id, entity_type, entity_id, user_id,
    content, parent_id, is_task
  ) VALUES (
    v_tenant_id, p_site_id, p_entity_type, p_entity_id, v_user_id,
    trim(p_content), p_parent_id, coalesce(p_is_task, false)
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.update_entity_comment(
  p_id       uuid,
  p_content  text,
  p_is_task  boolean DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_row data.entity_comments%ROWTYPE;
BEGIN
  SELECT * INTO v_row
  FROM data.entity_comments
  WHERE id = p_id AND tenant_id = data.active_tenant_id() AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_row.user_id IS DISTINCT FROM auth.uid()
     AND (data.jwt_user_tenants() -> v_row.tenant_id::text ->> 'global_role') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  UPDATE data.entity_comments
  SET
    content  = trim(p_content),
    is_task  = coalesce(p_is_task, is_task)
  WHERE id = p_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.delete_entity_comment(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_row data.entity_comments%ROWTYPE;
BEGIN
  SELECT * INTO v_row
  FROM data.entity_comments
  WHERE id = p_id AND tenant_id = data.active_tenant_id() AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_row.user_id IS DISTINCT FROM auth.uid()
     AND (data.jwt_user_tenants() -> v_row.tenant_id::text ->> 'global_role') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  UPDATE data.entity_comments
  SET deleted_at = now(), content = ''
  WHERE id = p_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.resolve_entity_comment_task(
  p_id       uuid,
  p_resolved boolean DEFAULT true
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
BEGIN
  UPDATE data.entity_comments
  SET
    resolved_at = CASE WHEN p_resolved THEN now() ELSE NULL END,
    resolved_by = CASE WHEN p_resolved THEN auth.uid() ELSE NULL END
  WHERE id = p_id
    AND tenant_id = data.active_tenant_id()
    AND is_task = true
    AND deleted_at IS NULL;
END;
$$;

CREATE OR REPLACE FUNCTION api.get_entity_comment_replies(
  p_comment_id uuid,
  p_limit      integer DEFAULT 50,
  p_offset     integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_root data.entity_comments%ROWTYPE;
BEGIN
  SELECT * INTO v_root FROM data.entity_comments WHERE id = p_comment_id;
  IF NOT FOUND THEN
    RETURN '[]'::jsonb;
  END IF;

  IF NOT data.can_view_entity(auth.uid(), v_root.tenant_id, v_root.entity_type, v_root.entity_id, v_root.site_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(row_to_json(x)::jsonb ORDER BY x.created_at ASC)
    FROM (
      SELECT
        c.id,
        c.created_at,
        c.deleted_at IS NOT NULL AS deleted,
        CASE WHEN c.deleted_at IS NOT NULL THEN NULL ELSE c.content END AS content,
        c.is_task,
        c.resolved_at,
        c.revision_count,
        jsonb_build_object(
          'id', p.id,
          'full_name', p.full_name,
          'avatar_url', p.avatar_url,
          'actor_type', c.actor_type
        ) AS author
      FROM data.entity_comments c
      LEFT JOIN data.profiles p ON p.id = c.user_id
      WHERE c.parent_id = p_comment_id
      ORDER BY c.created_at ASC
      LIMIT LEAST(GREATEST(p_limit, 1), 100)
      OFFSET GREATEST(p_offset, 0)
    ) x
  ), '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION api.get_entity_comment_revisions(p_comment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_comment data.entity_comments%ROWTYPE;
BEGIN
  SELECT * INTO v_comment FROM data.entity_comments WHERE id = p_comment_id;
  IF NOT FOUND THEN
    RETURN '[]'::jsonb;
  END IF;

  IF NOT (
    v_comment.user_id = auth.uid()
    OR (data.jwt_user_tenants() -> v_comment.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(row_to_json(r)::jsonb ORDER BY r.edited_at DESC)
    FROM (
      SELECT id, user_id, content_before, edited_at
      FROM data.entity_comment_revisions
      WHERE comment_id = p_comment_id
      ORDER BY edited_at DESC
    ) r
  ), '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION api.mark_entity_timeline_seen(
  p_entity_type text,
  p_entity_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_user_id   uuid := auth.uid();
  v_tenant_id uuid := data.active_tenant_id();
  v_last_seen timestamptz;
BEGIN
  IF v_user_id IS NULL OR v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT data.can_view_entity(v_user_id, v_tenant_id, p_entity_type, p_entity_id, NULL) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  INSERT INTO data.entity_timeline_watermarks (
    user_id, tenant_id, entity_type, entity_id, last_seen_at
  ) VALUES (
    v_user_id, v_tenant_id, p_entity_type, p_entity_id, now()
  )
  ON CONFLICT (user_id, entity_type, entity_id)
  DO UPDATE SET last_seen_at = now()
  RETURNING last_seen_at INTO v_last_seen;

  RETURN jsonb_build_object('last_seen_at', v_last_seen);
END;
$$;

CREATE OR REPLACE FUNCTION api.get_entity_timeline(
  p_entity_type   text,
  p_entity_id     uuid,
  p_limit         integer DEFAULT 30,
  p_cursor        timestamptz DEFAULT NULL,
  p_cursor_id     uuid DEFAULT NULL,
  p_include_audit boolean DEFAULT true,
  p_tasks_only    boolean DEFAULT false,
  p_date_from     timestamptz DEFAULT NULL,
  p_date_to       timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_user_id     uuid := auth.uid();
  v_tenant_id   uuid := data.active_tenant_id();
  v_limit       integer := LEAST(GREATEST(coalesce(p_limit, 30), 1), 100);
  v_last_seen   timestamptz;
  v_unread      integer := 0;
  v_items       jsonb;
  v_has_more    boolean := false;
  v_next_cursor timestamptz;
  v_next_id     uuid;
BEGIN
  IF v_user_id IS NULL OR v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT data.can_view_entity(v_user_id, v_tenant_id, p_entity_type, p_entity_id, NULL) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT w.last_seen_at INTO v_last_seen
  FROM data.entity_timeline_watermarks w
  WHERE w.user_id = v_user_id
    AND w.entity_type = p_entity_type
    AND w.entity_id = p_entity_id;

  SELECT count(*)::integer INTO v_unread
  FROM (
    SELECT al.created_at
    FROM data.audit_logs al
    WHERE p_include_audit AND NOT p_tasks_only
      AND al.tenant_id = v_tenant_id
      AND al.entity_type = p_entity_type
      AND al.entity_id = p_entity_id
      AND (v_last_seen IS NULL OR al.created_at > v_last_seen)
    UNION ALL
    SELECT ec.created_at
    FROM data.entity_comments ec
    WHERE ec.tenant_id = v_tenant_id
      AND ec.entity_type = p_entity_type
      AND ec.entity_id = p_entity_id
      AND ec.parent_id IS NULL
      AND (NOT p_tasks_only OR ec.is_task = true)
      AND (v_last_seen IS NULL OR ec.created_at > v_last_seen)
  ) u;

  WITH combined AS (
    SELECT
      'audit_event'::text AS kind,
      al.id,
      al.created_at,
      al.action,
      al.payload,
      NULL::text AS content,
      NULL::boolean AS is_task,
      NULL::timestamptz AS resolved_at,
      NULL::integer AS replies_count,
      false AS deleted,
      al.user_id AS actor_user_id
    FROM data.audit_logs al
    WHERE p_include_audit
      AND NOT p_tasks_only
      AND al.tenant_id = v_tenant_id
      AND al.entity_type = p_entity_type
      AND al.entity_id = p_entity_id
      AND (p_date_from IS NULL OR al.created_at >= p_date_from)
      AND (p_date_to IS NULL OR al.created_at <= p_date_to)

    UNION ALL

    SELECT
      'comment'::text AS kind,
      ec.id,
      ec.created_at,
      NULL::text AS action,
      NULL::jsonb AS payload,
      CASE WHEN ec.deleted_at IS NOT NULL THEN NULL ELSE ec.content END AS content,
      ec.is_task,
      ec.resolved_at,
      ec.reply_count AS replies_count,
      ec.deleted_at IS NOT NULL AS deleted,
      ec.user_id AS actor_user_id
    FROM data.entity_comments ec
    WHERE ec.tenant_id = v_tenant_id
      AND ec.entity_type = p_entity_type
      AND ec.entity_id = p_entity_id
      AND ec.parent_id IS NULL
      AND (NOT p_tasks_only OR ec.is_task = true)
      AND (p_date_from IS NULL OR ec.created_at >= p_date_from)
      AND (p_date_to IS NULL OR ec.created_at <= p_date_to)
  ),
  filtered AS (
    SELECT *
    FROM combined c
    WHERE p_cursor IS NULL
       OR (c.created_at, c.id) < (p_cursor, coalesce(p_cursor_id, c.id))
    ORDER BY c.created_at DESC, c.id DESC
    LIMIT v_limit + 1
  ),
  page AS (
    SELECT * FROM filtered LIMIT v_limit
  ),
  extra AS (
    SELECT f.created_at, f.id
    FROM filtered f
    ORDER BY f.created_at DESC, f.id DESC
    OFFSET v_limit
    LIMIT 1
  )
  SELECT
    COALESCE((
      SELECT jsonb_agg(item ORDER BY item ->> 'created_at' DESC)
      FROM (
        SELECT
          CASE WHEN p.kind = 'audit_event' THEN
            jsonb_build_object(
              'kind', 'audit_event',
              'id', p.id,
              'created_at', p.created_at,
              'action', p.action,
              'message_key', data.timeline_audit_message_key(p.action),
              'message_vars', data.timeline_audit_message_vars(p.action, p.payload),
              'payload', coalesce(p.payload, '{}'::jsonb),
              'actor', jsonb_build_object(
                'id', pr.id,
                'full_name', pr.full_name,
                'avatar_url', pr.avatar_url
              )
            )
          ELSE
            jsonb_build_object(
              'kind', 'comment',
              'id', p.id,
              'created_at', p.created_at,
              'content', p.content,
              'is_task', coalesce(p.is_task, false),
              'resolved_at', p.resolved_at,
              'replies_count', coalesce(p.replies_count, 0),
              'deleted', p.deleted,
              'author', jsonb_build_object(
                'id', pr.id,
                'full_name', pr.full_name,
                'avatar_url', pr.avatar_url,
                'actor_type', 'user'
              )
            )
          END AS item
        FROM page p
        LEFT JOIN data.profiles pr ON pr.id = p.actor_user_id
      ) rows
    ), '[]'::jsonb),
    (SELECT count(*) > v_limit FROM filtered),
    (SELECT e.created_at FROM extra e),
    (SELECT e.id FROM extra e)
  INTO v_items, v_has_more, v_next_cursor, v_next_id;

  RETURN jsonb_build_object(
    'items', v_items,
    'page', jsonb_build_object(
      'has_more', coalesce(v_has_more, false),
      'next_cursor', v_next_cursor,
      'next_cursor_id', v_next_id,
      'unread_since_last_visit', coalesce(v_unread, 0),
      'schema_version', 1
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.search_tenant_members_for_mention(text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION api.insert_entity_comment(text, uuid, text, uuid, boolean, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.update_entity_comment(uuid, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION api.delete_entity_comment(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.resolve_entity_comment_task(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_entity_comment_replies(uuid, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_entity_comment_revisions(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.mark_entity_timeline_seen(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_entity_timeline(text, uuid, integer, timestamptz, uuid, boolean, boolean, timestamptz, timestamptz) TO authenticated;
