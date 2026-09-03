-- =============================================================================
-- Entity Timeline — Fix auth context for get_entity_timeline_for_ai
-- =============================================================================

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

  -- The RPC runs with service_role. Build request claims for p_user_id so
  -- helpers based on auth.jwt()/auth.uid() evaluate the real caller.
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
