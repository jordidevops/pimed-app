-- Entity Timeline — bloc IA (Fase 2)
-- memory score, RPC per tools IA, is_ai_context_note al composer

-- -----------------------------------------------------------------------------
-- data.compute_entity_memory_score — prioritza context per al model
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.compute_entity_memory_score(
  p_viewer_user_id  uuid,
  p_kind            text,
  p_created_at      timestamptz,
  p_is_ai_context_note boolean,
  p_is_task         boolean,
  p_resolved_at     timestamptz,
  p_mentions        uuid[],
  p_actor_type      text,
  p_action          text
)
RETURNS integer
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_score integer := 0;
BEGIN
  IF coalesce(p_is_ai_context_note, false) THEN
    v_score := v_score + 100;
  END IF;

  IF coalesce(p_is_task, false) THEN
    IF p_resolved_at IS NOT NULL THEN
      v_score := v_score + 30;
    ELSE
      v_score := v_score + 50;
    END IF;
  END IF;

  IF p_viewer_user_id IS NOT NULL
    AND p_mentions IS NOT NULL
    AND p_viewer_user_id = ANY(p_mentions) THEN
    v_score := v_score + 40;
  END IF;

  IF coalesce(p_actor_type, 'user') IN ('automation', 'ai', 'system') THEN
    v_score := v_score + 20;
  END IF;

  IF p_created_at IS NOT NULL AND p_created_at > (now() - interval '7 days') THEN
    v_score := v_score + 10;
  END IF;

  IF p_kind = 'audit_event' AND p_action IS NOT NULL THEN
    IF p_action IN (
      'EMPLOYEE_TERMINATED',
      'EMPLOYEE_DELETED',
      'CONTACT_DELETED',
      'SIGNING_SUBMISSION_COMPLETED',
      'SIGNING_SUBMISSION_DECLINED',
      'SIGNING_SUBMISSION_EXPIRED'
    ) OR p_action LIKE 'SIGNING_SUBMISSION_%' THEN
      v_score := v_score + 25;
    END IF;
  END IF;

  RETURN v_score;
END;
$$;

REVOKE ALL ON FUNCTION data.compute_entity_memory_score(
  uuid, text, timestamptz, boolean, boolean, timestamptz, uuid[], text, text
) FROM PUBLIC;

-- -----------------------------------------------------------------------------
-- api.get_entity_timeline_for_ai — lectura per tools IA (service_role)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.get_entity_timeline_for_ai(
  p_tenant_id       uuid,
  p_user_id         uuid,
  p_entity_type     text,
  p_entity_id       uuid,
  p_limit           integer DEFAULT 20,
  p_include_audit   boolean DEFAULT true,
  p_date_from       timestamptz DEFAULT NULL,
  p_date_to         timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_limit integer := LEAST(GREATEST(coalesce(p_limit, 20), 1), 50);
  v_items jsonb;
  v_user_tenants jsonb;
BEGIN
  IF p_tenant_id IS NULL OR p_user_id IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT upc.tenant_data INTO v_user_tenants
  FROM data.user_permissions_cache upc
  WHERE upc.user_id = p_user_id;

  IF v_user_tenants IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  -- Runtime auth in this RPC is executed under service_role.
  -- We emulate the caller claims so helper functions that depend on auth.jwt()/auth.uid()
  -- (can_view_entity, can_access_project) evaluate permissions for p_user_id instead.
  PERFORM set_config('request.jwt.claim.sub', p_user_id::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', p_user_id::text,
      'app_metadata', jsonb_build_object('user_tenants', v_user_tenants)
    )::text,
    true
  );
  IF NOT data.can_view_entity(p_user_id, p_tenant_id, p_entity_type, p_entity_id, NULL) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  WITH raw AS (
    SELECT
      'audit_event'::text AS kind,
      al.id,
      al.created_at,
      al.action,
      data.timeline_audit_message_key(al.action) AS message_key,
      data.timeline_audit_message_vars(al.action, al.payload) AS message_vars,
      NULL::text AS content,
      false AS is_ai_context_note,
      false AS is_task,
      NULL::timestamptz AS resolved_at,
      NULL::uuid[] AS mentions,
      'user'::text AS actor_type,
      pr.full_name AS actor_name,
      data.compute_entity_memory_score(
        p_user_id, 'audit_event', al.created_at,
        false, false, NULL, NULL, 'user', al.action
      ) AS memory_score
    FROM data.audit_logs al
    LEFT JOIN data.profiles pr ON pr.id = al.user_id
    WHERE p_include_audit
      AND al.tenant_id = p_tenant_id
      AND al.entity_type = p_entity_type
      AND al.entity_id = p_entity_id
      AND NOT al.is_background
      AND (p_date_from IS NULL OR al.created_at >= p_date_from)
      AND (p_date_to IS NULL OR al.created_at <= p_date_to)

    UNION ALL

    SELECT
      'comment'::text AS kind,
      ec.id,
      ec.created_at,
      NULL::text AS action,
      NULL::text AS message_key,
      NULL::jsonb AS message_vars,
      ec.content,
      ec.is_ai_context_note,
      ec.is_task,
      ec.resolved_at,
      ec.mentions,
      ec.actor_type,
      pr.full_name AS actor_name,
      data.compute_entity_memory_score(
        p_user_id, 'comment', ec.created_at,
        ec.is_ai_context_note, ec.is_task, ec.resolved_at,
        ec.mentions, ec.actor_type, NULL
      ) AS memory_score
    FROM data.entity_comments ec
    LEFT JOIN data.profiles pr ON pr.id = ec.user_id
    WHERE ec.tenant_id = p_tenant_id
      AND ec.entity_type = p_entity_type
      AND ec.entity_id = p_entity_id
      AND ec.parent_id IS NULL
      AND ec.deleted_at IS NULL
      AND (p_date_from IS NULL OR ec.created_at >= p_date_from)
      AND (p_date_to IS NULL OR ec.created_at <= p_date_to)
  ),
  ranked AS (
    SELECT *
    FROM raw
    ORDER BY memory_score DESC, created_at DESC
    LIMIT v_limit
  )
  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'kind', r.kind,
      'id', r.id,
      'created_at', r.created_at,
      'memory_score', r.memory_score,
      'actor_name', r.actor_name,
      'action', r.action,
      'message_key', r.message_key,
      'message_vars', coalesce(r.message_vars, '{}'::jsonb),
      'content', r.content,
      'is_ai_context_note', coalesce(r.is_ai_context_note, false),
      'is_task', coalesce(r.is_task, false),
      'resolved_at', r.resolved_at
    )
    ORDER BY r.memory_score DESC, r.created_at DESC
  ), '[]'::jsonb)
  INTO v_items
  FROM ranked r;

  RETURN jsonb_build_object(
    'entity_type', p_entity_type,
    'entity_id', p_entity_id,
    'items', v_items,
    'schema_version', 1
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_entity_timeline_for_ai(
  uuid, uuid, text, uuid, integer, boolean, timestamptz, timestamptz
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_entity_timeline_for_ai(
  uuid, uuid, text, uuid, integer, boolean, timestamptz, timestamptz
) TO service_role;

-- -----------------------------------------------------------------------------
-- insert_entity_comment — p_is_ai_context_note
-- -----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS api.insert_entity_comment(text, uuid, text, uuid, boolean, uuid, jsonb, timestamptz);

CREATE OR REPLACE FUNCTION api.insert_entity_comment(
  p_entity_type          text,
  p_entity_id            uuid,
  p_content              text,
  p_parent_id            uuid DEFAULT NULL,
  p_is_task              boolean DEFAULT false,
  p_site_id              uuid DEFAULT NULL,
  p_attachments          jsonb DEFAULT '[]'::jsonb,
  p_due_date             timestamptz DEFAULT NULL,
  p_is_ai_context_note   boolean DEFAULT false
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
  v_is_task      boolean := coalesce(p_is_task, false);
  v_due_date     timestamptz;
  v_ai_note      boolean := coalesce(p_is_ai_context_note, false);
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

  v_due_date := CASE WHEN v_is_task THEN p_due_date ELSE NULL END;

  FOREACH v_mention IN ARRAY data.extract_entity_comment_mentions(p_content) LOOP
    IF NOT data.is_active_tenant_member(v_tenant_id, v_mention) THEN
      RAISE EXCEPTION 'invalid_mention: %', v_mention USING ERRCODE = 'check_violation';
    END IF;
  END LOOP;

  INSERT INTO data.entity_comments (
    tenant_id, site_id, entity_type, entity_id, user_id,
    content, parent_id, is_task, attachments, due_date, is_ai_context_note
  ) VALUES (
    v_tenant_id, p_site_id, p_entity_type, p_entity_id, v_user_id,
    trim(coalesce(p_content, '')), p_parent_id, v_is_task, v_attachments, v_due_date, v_ai_note
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.insert_entity_comment(
  text, uuid, text, uuid, boolean, uuid, jsonb, timestamptz, boolean
) TO authenticated;

-- -----------------------------------------------------------------------------
-- get_entity_timeline — exposa is_ai_context_note als comentaris (badge UI)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.get_entity_timeline(
  p_entity_type         text,
  p_entity_id           uuid,
  p_limit               integer DEFAULT 30,
  p_cursor              timestamptz DEFAULT NULL,
  p_cursor_id           uuid DEFAULT NULL,
  p_include_audit       boolean DEFAULT true,
  p_tasks_only          boolean DEFAULT false,
  p_date_from           timestamptz DEFAULT NULL,
  p_date_to             timestamptz DEFAULT NULL,
  p_search              text DEFAULT NULL,
  p_open_tasks_only     boolean DEFAULT false,
  p_include_background  boolean DEFAULT false
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
    WHERE p_include_audit
      AND NOT p_tasks_only
      AND NOT COALESCE(p_open_tasks_only, false)
      AND al.tenant_id = v_tenant_id
      AND al.entity_type = p_entity_type
      AND al.entity_id = p_entity_id
      AND (COALESCE(p_include_background, false) OR NOT al.is_background)
      AND (v_last_seen IS NULL OR al.created_at > v_last_seen)
    UNION ALL
    SELECT ec.created_at
    FROM data.entity_comments ec
    WHERE ec.tenant_id = v_tenant_id
      AND ec.entity_type = p_entity_type
      AND ec.entity_id = p_entity_id
      AND ec.parent_id IS NULL
      AND data.entity_comment_passes_task_filters(
        ec.is_task, ec.resolved_at, p_tasks_only, p_open_tasks_only
      )
      AND (v_last_seen IS NULL OR ec.created_at > v_last_seen)
  ) u;

  WITH pinned_rows AS (
    SELECT
      'comment'::text AS kind,
      ec.id,
      ec.created_at,
      NULL::text AS action,
      NULL::jsonb AS payload,
      ec.content,
      ec.is_task,
      ec.resolved_at,
      ec.due_date,
      ec.reply_count AS replies_count,
      false AS deleted,
      ec.user_id AS actor_user_id,
      coalesce(ec.attachments, '[]'::jsonb) AS attachments,
      ec.pinned_at,
      ec.mentions,
      coalesce(ec.mentions_read, '{}'::jsonb) AS mentions_read,
      false AS is_background,
      ec.is_ai_context_note
    FROM data.entity_comments ec
    WHERE p_cursor IS NULL
      AND ec.tenant_id = v_tenant_id
      AND ec.entity_type = p_entity_type
      AND ec.entity_id = p_entity_id
      AND ec.parent_id IS NULL
      AND ec.deleted_at IS NULL
      AND ec.pinned_at IS NOT NULL
      AND data.entity_comment_passes_task_filters(
        ec.is_task, ec.resolved_at, p_tasks_only, p_open_tasks_only
      )
      AND (p_date_from IS NULL OR ec.created_at >= p_date_from)
      AND (p_date_to IS NULL OR ec.created_at <= p_date_to)
      AND (
        v_search IS NULL
        OR data.entity_comment_matches_search(ec.content, v_search)
        OR EXISTS (
          SELECT 1
          FROM data.entity_comments r
          WHERE r.parent_id = ec.id
            AND r.deleted_at IS NULL
            AND data.entity_comment_matches_search(r.content, v_search)
        )
      )
  ),
  stream_rows AS (
    SELECT
      'audit_event'::text AS kind,
      al.id,
      al.created_at,
      al.action,
      al.payload,
      NULL::text AS content,
      NULL::boolean AS is_task,
      NULL::timestamptz AS resolved_at,
      NULL::timestamptz AS due_date,
      NULL::integer AS replies_count,
      false AS deleted,
      al.user_id AS actor_user_id,
      NULL::jsonb AS attachments,
      NULL::timestamptz AS pinned_at,
      NULL::uuid[] AS mentions,
      NULL::jsonb AS mentions_read,
      al.is_background,
      false AS is_ai_context_note
    FROM data.audit_logs al
    WHERE v_search IS NULL
      AND p_include_audit
      AND NOT p_tasks_only
      AND NOT COALESCE(p_open_tasks_only, false)
      AND al.tenant_id = v_tenant_id
      AND al.entity_type = p_entity_type
      AND al.entity_id = p_entity_id
      AND (COALESCE(p_include_background, false) OR NOT al.is_background)
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
      ec.due_date,
      ec.reply_count AS replies_count,
      ec.deleted_at IS NOT NULL AS deleted,
      ec.user_id AS actor_user_id,
      CASE WHEN ec.deleted_at IS NOT NULL THEN '[]'::jsonb ELSE coalesce(ec.attachments, '[]'::jsonb) END AS attachments,
      NULL::timestamptz AS pinned_at,
      ec.mentions,
      coalesce(ec.mentions_read, '{}'::jsonb) AS mentions_read,
      false AS is_background,
      ec.is_ai_context_note
    FROM data.entity_comments ec
    WHERE ec.tenant_id = v_tenant_id
      AND ec.entity_type = p_entity_type
      AND ec.entity_id = p_entity_id
      AND ec.parent_id IS NULL
      AND ec.pinned_at IS NULL
      AND data.entity_comment_passes_task_filters(
        ec.is_task, ec.resolved_at, p_tasks_only, p_open_tasks_only
      )
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
  unpinned_filtered AS (
    SELECT *
    FROM stream_rows s
    WHERE p_cursor IS NULL
       OR (s.created_at, s.id) < (p_cursor, coalesce(p_cursor_id, s.id))
    ORDER BY s.created_at DESC, s.id DESC
    LIMIT v_limit + 1
  ),
  page AS (
    SELECT * FROM pinned_rows
    UNION ALL
    SELECT u.*
    FROM (
      SELECT *
      FROM unpinned_filtered
      ORDER BY created_at DESC, id DESC
      LIMIT v_limit
    ) u
  ),
  extra AS (
    SELECT f.created_at, f.id
    FROM unpinned_filtered f
    ORDER BY f.created_at DESC, f.id DESC
    OFFSET v_limit
    LIMIT 1
  )
  SELECT
    COALESCE((
      SELECT jsonb_agg(item ORDER BY
        CASE WHEN (item ->> 'pinned_at') IS NOT NULL THEN 0 ELSE 1 END,
        item ->> 'pinned_at' DESC NULLS LAST,
        item ->> 'created_at' DESC
      )
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
              'is_background', coalesce(p.is_background, false),
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
              'due_date', p.due_date,
              'replies_count', coalesce(p.replies_count, 0),
              'deleted', p.deleted,
              'pinned_at', p.pinned_at,
              'is_ai_context_note', coalesce(p.is_ai_context_note, false),
              'mentions_read', CASE
                WHEN coalesce(p.is_task, false)
                  AND coalesce(cardinality(p.mentions), 0) > 0 THEN
                  data.build_mention_read_status(p.mentions, coalesce(p.mentions_read, '{}'::jsonb))
                ELSE '[]'::jsonb
              END,
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
    (SELECT count(*) > v_limit FROM unpinned_filtered),
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
  text, uuid, integer, timestamptz, uuid, boolean, boolean, timestamptz, timestamptz, text, boolean, boolean
) TO authenticated;
