-- =============================================================================
-- Entity Timeline — adjunts + polish MENTION_CREATED (deep links + cos)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Deep link per entitat (notificacions + UI)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.entity_timeline_deep_link(
  p_entity_type text,
  p_entity_id   uuid,
  p_comment_id  uuid
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_entity_type
    WHEN 'employee' THEN '/employees/' || p_entity_id::text
      || '?tab=activity&comment=' || p_comment_id::text
    WHEN 'contact' THEN '/contacts/' || p_entity_id::text
      || '?comment=' || p_comment_id::text
    WHEN 'project' THEN '/projects/' || p_entity_id::text
      || '?comment=' || p_comment_id::text
    WHEN 'document' THEN '/documents/' || p_entity_id::text
      || '?comment=' || p_comment_id::text
    ELSE '/comments/' || p_entity_id::text || '?comment=' || p_comment_id::text
  END;
$$;

-- -----------------------------------------------------------------------------
-- Validació adjunts (file_nodes confirmats per l'autor)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.normalize_entity_comment_attachments(
  p_attachments jsonb,
  p_tenant_id   uuid,
  p_user_id     uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_item    jsonb;
  v_file_id uuid;
  v_node    record;
  v_result  jsonb := '[]'::jsonb;
  v_count   integer;
BEGIN
  IF p_attachments IS NULL OR p_attachments = 'null'::jsonb THEN
    RETURN '[]'::jsonb;
  END IF;

  v_count := jsonb_array_length(p_attachments);
  IF v_count = 0 THEN
    RETURN '[]'::jsonb;
  END IF;

  IF v_count > 10 THEN
    RAISE EXCEPTION 'too_many_attachments' USING ERRCODE = 'check_violation';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_attachments) AS t(value)
  LOOP
    v_file_id := (v_item ->> 'file_id')::uuid;
    IF v_file_id IS NULL THEN
      RAISE EXCEPTION 'invalid_attachment: missing file_id' USING ERRCODE = 'check_violation';
    END IF;

    SELECT fn.id, fn.name, fn.mime_type, fn.size_bytes
    INTO v_node
    FROM data.file_nodes fn
    WHERE fn.id = v_file_id
      AND fn.tenant_id = p_tenant_id
      AND fn.created_by = p_user_id
      AND fn.processing_status = 'done'
      AND fn.node_type = 'file';

    IF NOT FOUND THEN
      RAISE EXCEPTION 'invalid_attachment: %', v_file_id USING ERRCODE = 'check_violation';
    END IF;

    v_result := v_result || jsonb_build_array(jsonb_build_object(
      'file_id', v_file_id,
      'name', coalesce(nullif(trim(v_item ->> 'name'), ''), v_node.name),
      'mime', coalesce(nullif(trim(v_item ->> 'mime'), ''), v_node.mime_type),
      'size_bytes', coalesce((v_item ->> 'size_bytes')::bigint, v_node.size_bytes)
    ));
  END LOOP;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION data.normalize_entity_comment_attachments(jsonb, uuid, uuid) FROM PUBLIC;

-- -----------------------------------------------------------------------------
-- insert_entity_comment amb adjunts
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.insert_entity_comment(
  p_entity_type   text,
  p_entity_id     uuid,
  p_content       text,
  p_parent_id     uuid DEFAULT NULL,
  p_is_task       boolean DEFAULT false,
  p_site_id       uuid DEFAULT NULL,
  p_attachments   jsonb DEFAULT '[]'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_user_id      uuid := auth.uid();
  v_tenant_id    uuid := data.active_tenant_id();
  v_id           uuid;
  v_mention      uuid;
  v_attachments  jsonb;
BEGIN
  IF v_user_id IS NULL OR v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT data.can_edit_entity(v_user_id, v_tenant_id, p_entity_type, p_entity_id, p_site_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  v_attachments := data.normalize_entity_comment_attachments(
    coalesce(p_attachments, '[]'::jsonb),
    v_tenant_id,
    v_user_id
  );

  IF length(trim(coalesce(p_content, ''))) = 0 AND jsonb_array_length(v_attachments) = 0 THEN
    RAISE EXCEPTION 'content_required' USING ERRCODE = 'check_violation';
  END IF;

  FOREACH v_mention IN ARRAY data.extract_entity_comment_mentions(p_content) LOOP
    IF NOT data.is_active_tenant_member(v_tenant_id, v_mention) THEN
      RAISE EXCEPTION 'invalid_mention: %', v_mention USING ERRCODE = 'check_violation';
    END IF;
  END LOOP;

  INSERT INTO data.entity_comments (
    tenant_id, site_id, entity_type, entity_id, user_id,
    content, parent_id, is_task, attachments
  ) VALUES (
    v_tenant_id, p_site_id, p_entity_type, p_entity_id, v_user_id,
    trim(coalesce(p_content, '')), p_parent_id, coalesce(p_is_task, false), v_attachments
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.insert_entity_comment(
  text, uuid, text, uuid, boolean, uuid, jsonb
) TO authenticated;

-- -----------------------------------------------------------------------------
-- Notificacions: deep_link + autor al payload
-- -----------------------------------------------------------------------------

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
    'content_preview', left(v_comment.content, 200),
    'deep_link',       v_deep_link
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
END;
$$;

-- Catàleg: plantilla genèrica (el motor usa payload.deep_link)
UPDATE data.notification_event_catalog
SET deep_link_template = '/employees/{entity_id}?tab=activity&comment={comment_id}',
    description = 'Menció o resposta en comentari d''entitat (deep_link al payload)'
WHERE event_code = 'MENTION_CREATED';

COMMENT ON COLUMN data.notification_event_catalog.deep_link_template IS
  'Placeholders: {entity_id}, {project_id}, {tenant_id}, {comment_id}. '
  'MENTION_CREATED: preferir payload.deep_link (per entity_type).';

-- -----------------------------------------------------------------------------
-- get_entity_comment_replies — inclou adjunts
-- -----------------------------------------------------------------------------

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
        coalesce(c.attachments, '[]'::jsonb) AS attachments,
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

-- -----------------------------------------------------------------------------
-- get_entity_timeline — adjunts als comentaris
-- -----------------------------------------------------------------------------

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
      al.user_id AS actor_user_id,
      NULL::jsonb AS attachments
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
      ec.user_id AS actor_user_id,
      CASE WHEN ec.deleted_at IS NOT NULL THEN '[]'::jsonb ELSE coalesce(ec.attachments, '[]'::jsonb) END AS attachments
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
              'attachments', coalesce(p.attachments, '[]'::jsonb),
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
