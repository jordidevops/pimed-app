-- Entity Timeline — cerca full-text en comentaris (Fase 2)

-- Helper: coincideix amb consulta websearch (català/castellà via config simple)
CREATE OR REPLACE FUNCTION data.entity_comment_matches_search(p_content text, p_search text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    coalesce(trim(p_search), '') = ''
    OR (
      p_content IS NOT NULL
      AND length(trim(p_search)) > 0
      AND to_tsvector('simple', data.humanize_entity_comment_mentions(p_content))
          @@ websearch_to_tsquery('simple', trim(p_search))
    );
$$;

-- Índex GIN per cerca en contingut humanitzat (sense tokens [[@uuid|nom]])
CREATE INDEX IF NOT EXISTS idx_entity_comments_content_fts
  ON data.entity_comments
  USING gin (to_tsvector('simple', data.humanize_entity_comment_mentions(content)))
  WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- get_entity_timeline — paràmetre p_search
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
  p_date_to       timestamptz DEFAULT NULL,
  p_search        text DEFAULT NULL
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
  v_search      text := nullif(trim(coalesce(p_search, '')), '');
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
    WHERE v_search IS NULL
      AND p_include_audit
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
      AND (
        v_search IS NULL
        OR (
          data.entity_comment_matches_search(ec.content, v_search)
          OR EXISTS (
            SELECT 1
            FROM data.entity_comments r
            WHERE r.parent_id = ec.id
              AND r.deleted_at IS NULL
              AND data.entity_comment_matches_search(r.content, v_search)
          )
        )
      )
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

GRANT EXECUTE ON FUNCTION api.get_entity_timeline(
  text, uuid, integer, timestamptz, uuid, boolean, boolean, timestamptz, timestamptz, text
) TO authenticated;
