-- Humanitza mencions per previews de notificació + delete només autor

CREATE OR REPLACE FUNCTION data.humanize_entity_comment_mentions(p_content text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT regexp_replace(
    coalesce(p_content, ''),
    '\[\[@([0-9a-f-]{8}-[0-9a-f-]{4}-[0-9a-f-]{4}-[0-9a-f-]{4}-[0-9a-f-]{12})\|([^\]]+)\]\]',
    '@\2',
    'gi'
  );
$$;

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

CREATE OR REPLACE FUNCTION api.delete_entity_comment(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_row data.entity_comments%ROWTYPE;
  v_item jsonb;
  v_file_id uuid;
BEGIN
  SELECT * INTO v_row
  FROM data.entity_comments
  WHERE id = p_id AND tenant_id = data.active_tenant_id() AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  -- Només l'autor pot eliminar el seu comentari (independentment de mencions)
  IF v_row.user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(coalesce(v_row.attachments, '[]'::jsonb)) AS t(value)
  LOOP
    v_file_id := (v_item ->> 'file_id')::uuid;
    IF v_file_id IS NULL THEN
      CONTINUE;
    END IF;

    BEGIN
      IF EXISTS (
        SELECT 1
        FROM data.file_nodes fn
        WHERE fn.id = v_file_id
          AND fn.tenant_id = v_row.tenant_id
          AND fn.node_type = 'file'
          AND fn.is_deleted = false
          AND coalesce(fn.metadata ->> 'source', '') = 'entity_comment'
      ) THEN
        PERFORM data.hard_delete_node(v_file_id, v_row.tenant_id);
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        RAISE WARNING 'delete_entity_comment attachment %: %', v_file_id, SQLERRM;
    END;
  END LOOP;

  UPDATE data.entity_comments
  SET deleted_at = now(), content = '', attachments = '[]'::jsonb
  WHERE id = p_id;
END;
$$;
