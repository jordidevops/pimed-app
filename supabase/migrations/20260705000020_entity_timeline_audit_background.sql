-- Entity Timeline — is_background a audit_logs (Fase 2 anti-soroll)

ALTER TABLE data.audit_logs
  ADD COLUMN IF NOT EXISTS is_background boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN data.audit_logs.is_background IS
  'Events de cron/batch/workers; ocults per defecte a la timeline.';

CREATE INDEX IF NOT EXISTS idx_audit_logs_entity_timeline_foreground
  ON data.audit_logs (tenant_id, entity_type, entity_id, created_at DESC)
  WHERE is_background = false;

-- -----------------------------------------------------------------------------
-- Detecció d'accions en segon pla
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.is_background_audit_action(p_action text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(p_action, '') IN (
    'ASYNC_BATCH_PROCESSED',
    'TASK_DLQ_MOVED',
    'PROJECT_NOTIFICATIONS_SENT',
    'QUEUE_BATCH_PROCESSED',
    'EMAIL_BATCH_PROCESSED',
    'GEOCODING_BATCH_PROCESSED'
  )
  OR coalesce(p_action, '') LIKE '%\_BATCH\_%' ESCAPE '\'
  OR coalesce(p_action, '') LIKE '%\_CRON\_%' ESCAPE '\';
$$;

CREATE OR REPLACE FUNCTION data.trg_audit_logs_set_is_background()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.is_background IS NOT TRUE THEN
    NEW.is_background :=
      data.is_background_audit_action(NEW.action)
      OR coalesce((NEW.payload ->> 'is_background')::boolean, false);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_logs_set_is_background ON data.audit_logs;
CREATE TRIGGER trg_audit_logs_set_is_background
  BEFORE INSERT ON data.audit_logs
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_logs_set_is_background();

-- Retroactiu per events ja existents
UPDATE data.audit_logs al
SET is_background = true
WHERE al.is_background = false
  AND (
    data.is_background_audit_action(al.action)
    OR coalesce((al.payload ->> 'is_background')::boolean, false)
  );

-- -----------------------------------------------------------------------------
-- log_audit_event — paràmetre opcional is_background
-- (la sobrecàrrega de 7 args es elimina a 20260705000021)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.log_audit_event(
  p_tenant_id     uuid,
  p_user_id       uuid,
  p_site_id       uuid,
  p_action        text,
  p_entity_type   text,
  p_entity_id     uuid,
  p_payload       jsonb DEFAULT '{}',
  p_is_background boolean DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  INSERT INTO data.audit_logs (
    tenant_id, user_id, site_id, action, entity_type, entity_id, payload, is_background
  ) VALUES (
    p_tenant_id,
    p_user_id,
    p_site_id,
    p_action,
    p_entity_type,
    p_entity_id,
    p_payload,
    coalesce(
      p_is_background,
      data.is_background_audit_action(p_action),
      coalesce((p_payload ->> 'is_background')::boolean, false)
    )
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING '[audit] log_audit_event error: % — action=%, entity_id=%',
      SQLERRM, p_action, p_entity_id;
END;
$$;

REVOKE ALL ON FUNCTION data.log_audit_event(uuid, uuid, uuid, text, text, uuid, jsonb, boolean) FROM PUBLIC;

-- -----------------------------------------------------------------------------
-- Subscripcions: sense notificar events en segon pla
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.trg_audit_logs_entity_subscriptions()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_actor_name text;
BEGIN
  IF NEW.is_background THEN
    RETURN NEW;
  END IF;

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

-- -----------------------------------------------------------------------------
-- get_entity_timeline — p_include_background (default false)
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
      false AS is_background
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
      al.is_background
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
      false AS is_background
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

-- PostgREST: una sola signatura
DROP FUNCTION IF EXISTS api.get_entity_timeline(
  text, uuid, integer, timestamptz, uuid, boolean, boolean, timestamptz, timestamptz, text, boolean
);
