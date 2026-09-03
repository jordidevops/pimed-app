-- Entity Timeline — resum de novetats des de l'última visita (TimelineSummaryBanner)

CREATE OR REPLACE FUNCTION api.get_entity_timeline_visit_summary(
  p_entity_type text,
  p_entity_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_user_id     uuid := auth.uid();
  v_tenant_id   uuid := data.active_tenant_id();
  v_last_seen   timestamptz;
  v_total       integer := 0;
  v_comments    integer := 0;
  v_audit       integer := 0;
  v_tasks_new   integer := 0;
  v_tasks_done  integer := 0;
  v_highlights  jsonb;
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

  SELECT count(*)::integer INTO v_audit
  FROM data.audit_logs al
  WHERE al.tenant_id = v_tenant_id
    AND al.entity_type = p_entity_type
    AND al.entity_id = p_entity_id
    AND NOT al.is_background
    AND (v_last_seen IS NULL OR al.created_at > v_last_seen);

  SELECT count(*)::integer INTO v_comments
  FROM data.entity_comments ec
  WHERE ec.tenant_id = v_tenant_id
    AND ec.entity_type = p_entity_type
    AND ec.entity_id = p_entity_id
    AND ec.parent_id IS NULL
    AND ec.deleted_at IS NULL
    AND (v_last_seen IS NULL OR ec.created_at > v_last_seen);

  SELECT count(*)::integer INTO v_tasks_new
  FROM data.entity_comments ec
  WHERE ec.tenant_id = v_tenant_id
    AND ec.entity_type = p_entity_type
    AND ec.entity_id = p_entity_id
    AND ec.parent_id IS NULL
    AND ec.deleted_at IS NULL
    AND ec.is_task = true
    AND ec.resolved_at IS NULL
    AND (v_last_seen IS NULL OR ec.created_at > v_last_seen);

  SELECT count(*)::integer INTO v_tasks_done
  FROM data.entity_comments ec
  WHERE ec.tenant_id = v_tenant_id
    AND ec.entity_type = p_entity_type
    AND ec.entity_id = p_entity_id
    AND ec.parent_id IS NULL
    AND ec.deleted_at IS NULL
    AND ec.is_task = true
    AND ec.resolved_at IS NOT NULL
    AND (v_last_seen IS NULL OR ec.resolved_at > v_last_seen);

  v_total := coalesce(v_audit, 0) + coalesce(v_comments, 0);

  WITH recent AS (
    SELECT
      'audit_event'::text AS kind,
      al.id,
      al.created_at,
      al.action,
      data.timeline_audit_message_vars(al.action, al.payload) AS message_vars,
      NULL::text AS content,
      false AS is_task,
      NULL::timestamptz AS resolved_at,
      pr.full_name AS actor_name
    FROM data.audit_logs al
    LEFT JOIN data.profiles pr ON pr.id = al.user_id
    WHERE al.tenant_id = v_tenant_id
      AND al.entity_type = p_entity_type
      AND al.entity_id = p_entity_id
      AND NOT al.is_background
      AND (v_last_seen IS NULL OR al.created_at > v_last_seen)

    UNION ALL

    SELECT
      'comment'::text AS kind,
      ec.id,
      ec.created_at,
      NULL::text AS action,
      NULL::jsonb AS message_vars,
      left(trim(ec.content), 120) AS content,
      ec.is_task,
      ec.resolved_at,
      pr.full_name AS actor_name
    FROM data.entity_comments ec
    LEFT JOIN data.profiles pr ON pr.id = ec.user_id
    WHERE ec.tenant_id = v_tenant_id
      AND ec.entity_type = p_entity_type
      AND ec.entity_id = p_entity_id
      AND ec.parent_id IS NULL
      AND ec.deleted_at IS NULL
      AND (v_last_seen IS NULL OR ec.created_at > v_last_seen)
  )
  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'kind', r.kind,
      'action', r.action,
      'message_vars', coalesce(r.message_vars, '{}'::jsonb),
      'content', r.content,
      'is_task', coalesce(r.is_task, false),
      'resolved_at', r.resolved_at,
      'actor_name', r.actor_name,
      'created_at', r.created_at
    )
    ORDER BY r.created_at DESC
  ), '[]'::jsonb)
  INTO v_highlights
  FROM (
    SELECT * FROM recent
    ORDER BY created_at DESC
    LIMIT 5
  ) r;

  RETURN jsonb_build_object(
    'last_seen_at', v_last_seen,
    'total_new', v_total,
    'comments_new', coalesce(v_comments, 0),
    'audit_events_new', coalesce(v_audit, 0),
    'tasks_new', coalesce(v_tasks_new, 0),
    'tasks_resolved_new', coalesce(v_tasks_done, 0),
    'highlights', coalesce(v_highlights, '[]'::jsonb),
    'schema_version', 1
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_entity_timeline_visit_summary(text, uuid) TO authenticated;
