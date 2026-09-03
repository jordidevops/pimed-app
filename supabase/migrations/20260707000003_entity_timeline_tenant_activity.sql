-- =============================================================================
-- Entity Timeline — Fase 3.4: Timeline agregada tenant («activitat avui»)
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_entity_comments_tenant_roots_recent
  ON data.entity_comments (tenant_id, created_at DESC)
  WHERE parent_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_audit_logs_tenant_recent_foreground
  ON data.audit_logs (tenant_id, created_at DESC)
  WHERE entity_type IN ('employee', 'contact', 'project', 'document')
    AND is_background = false;

-- Feed agregat cross-entitat per owner/manager (dashboard «Activitat avui»)
CREATE OR REPLACE FUNCTION api.get_tenant_timeline_activity(
  p_limit               integer DEFAULT 25,
  p_cursor              timestamptz DEFAULT NULL,
  p_cursor_id           uuid DEFAULT NULL,
  p_since               timestamptz DEFAULT NULL,
  p_include_background  boolean DEFAULT false,
  p_include_audit       boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_user_id       uuid := auth.uid();
  v_tenant_id     uuid := data.active_tenant_id();
  v_limit         integer := LEAST(GREATEST(coalesce(p_limit, 25), 1), 50);
  v_since         timestamptz := coalesce(p_since, date_trunc('day', now()));
  v_is_privileged boolean;
  v_items         jsonb;
  v_has_more      boolean := false;
  v_next_cursor   timestamptz;
  v_next_id       uuid;
BEGIN
  IF v_user_id IS NULL OR v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  v_is_privileged := (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role')
    IN ('owner', 'manager');

  IF NOT v_is_privileged THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  WITH stream AS (
    SELECT
      'comment'::text AS kind,
      ec.id,
      ec.created_at,
      ec.entity_type,
      ec.entity_id,
      ec.site_id,
      CASE WHEN ec.deleted_at IS NOT NULL THEN NULL ELSE ec.content END AS content,
      ec.is_task,
      ec.resolved_at,
      ec.deleted_at IS NOT NULL AS deleted,
      ec.user_id AS actor_user_id,
      NULL::text AS action,
      NULL::jsonb AS payload,
      false AS is_background
    FROM data.entity_comments ec
    WHERE ec.tenant_id = v_tenant_id
      AND ec.parent_id IS NULL
      AND ec.created_at >= v_since
      AND ec.entity_type IN ('employee', 'contact', 'project', 'document')

    UNION ALL

    SELECT
      'audit_event'::text AS kind,
      al.id,
      al.created_at,
      al.entity_type,
      al.entity_id,
      al.site_id,
      NULL::text AS content,
      NULL::boolean AS is_task,
      NULL::timestamptz AS resolved_at,
      false AS deleted,
      al.user_id AS actor_user_id,
      al.action,
      al.payload,
      al.is_background
    FROM data.audit_logs al
    WHERE coalesce(p_include_audit, true)
      AND al.tenant_id = v_tenant_id
      AND al.created_at >= v_since
      AND al.entity_type IN ('employee', 'contact', 'project', 'document')
      AND (coalesce(p_include_background, false) OR NOT coalesce(al.is_background, false))
  ),
  visible AS (
    SELECT s.*
    FROM stream s
    WHERE data.can_view_entity(
      v_user_id, v_tenant_id, s.entity_type, s.entity_id, s.site_id
    )
  ),
  filtered AS (
    SELECT *
    FROM visible v
    WHERE p_cursor IS NULL
       OR (v.created_at, v.id) < (p_cursor, coalesce(p_cursor_id, v.id))
    ORDER BY v.created_at DESC, v.id DESC
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
    coalesce((
      SELECT jsonb_agg(item ORDER BY item ->> 'created_at' DESC, item ->> 'id' DESC)
      FROM (
        SELECT
          CASE WHEN p.kind = 'audit_event' THEN
            jsonb_build_object(
              'kind', 'audit_event',
              'id', p.id,
              'created_at', p.created_at,
              'entity_type', p.entity_type,
              'entity_id', p.entity_id,
              'entity_label', coalesce(
                data.entity_timeline_entity_label(p.entity_type, p.entity_id),
                p.entity_type
              ),
              'deep_link', data.entity_timeline_entity_link(p.entity_type, p.entity_id),
              'action', p.action,
              'message_key', data.timeline_audit_message_key(p.action),
              'message_vars', data.timeline_audit_message_vars(p.action, p.payload),
              'is_background', coalesce(p.is_background, false),
              'actor', (
                SELECT jsonb_build_object(
                  'id', pr.id,
                  'full_name', pr.full_name,
                  'avatar_url', pr.avatar_url
                )
                FROM data.profiles pr
                WHERE pr.id = p.actor_user_id
              )
            )
          ELSE
            jsonb_build_object(
              'kind', 'comment',
              'id', p.id,
              'created_at', p.created_at,
              'entity_type', p.entity_type,
              'entity_id', p.entity_id,
              'entity_label', coalesce(
                data.entity_timeline_entity_label(p.entity_type, p.entity_id),
                p.entity_type
              ),
              'deep_link', data.entity_timeline_deep_link(p.entity_type, p.entity_id, p.id),
              'content', left(
                data.humanize_entity_comment_mentions(coalesce(p.content, '')),
                200
              ),
              'is_task', coalesce(p.is_task, false),
              'resolved_at', p.resolved_at,
              'deleted', p.deleted,
              'author', (
                SELECT jsonb_build_object(
                  'id', pr.id,
                  'full_name', pr.full_name,
                  'avatar_url', pr.avatar_url
                )
                FROM data.profiles pr
                WHERE pr.id = p.actor_user_id
              )
            )
          END AS item
        FROM page p
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
      'since', v_since,
      'schema_version', 1
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_tenant_timeline_activity(
  integer, timestamptz, uuid, timestamptz, boolean, boolean
) TO authenticated;
