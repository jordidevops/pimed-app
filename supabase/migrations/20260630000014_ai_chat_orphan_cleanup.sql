-- Lifecycle M2c: TTL 90 dies per adjunts ai-chat orfes (quota + neteja Storage)

-- ---------------------------------------------------------------------------
-- 1) Extreure fileIds d'un payload de missatge (attachments + user_parts)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.extract_ai_chat_attachment_ids_from_payload(p_payload jsonb)
RETURNS SETOF uuid
LANGUAGE sql
STABLE
SET search_path = data, public
AS $$
  WITH attachment_items AS (
    SELECT elem
    FROM jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(p_payload -> 'attachments') = 'array'
          THEN p_payload -> 'attachments'
        ELSE '[]'::jsonb
      END
    ) AS elem
    UNION ALL
    SELECT elem
    FROM jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(p_payload -> 'user_parts') = 'array'
          THEN p_payload -> 'user_parts'
        ELSE '[]'::jsonb
      END
    ) AS elem
    WHERE elem ->> 'type' IN ('image', 'file')
  )
  SELECT DISTINCT (elem ->> 'fileId')::uuid
  FROM attachment_items
  WHERE elem ->> 'fileId' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
$$;

REVOKE ALL ON FUNCTION data.extract_ai_chat_attachment_ids_from_payload(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.extract_ai_chat_attachment_ids_from_payload(jsonb) FROM authenticated;
REVOKE ALL ON FUNCTION data.extract_ai_chat_attachment_ids_from_payload(jsonb) FROM anon;

-- ---------------------------------------------------------------------------
-- 2) Esborrar adjunts orfes (cron / service_role)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.cleanup_orphan_ai_chat_attachments(
  p_ttl_days    integer DEFAULT 90,
  p_batch_limit integer DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_ttl_days    integer := GREATEST(COALESCE(p_ttl_days, 90), 1);
  v_batch_limit integer := LEAST(GREATEST(COALESCE(p_batch_limit, 200), 1), 1000);
  v_candidate   record;
  v_deleted     integer := 0;
  v_errors      integer := 0;
  v_candidates  integer := 0;
BEGIN
  FOR v_candidate IN
    SELECT fn.id, fn.tenant_id
    FROM data.file_nodes fn
    WHERE fn.node_type = 'file'
      AND fn.is_deleted = false
      AND fn.processing_status = 'done'
      AND COALESCE(fn.metadata ->> 'source', '') = 'ai-chat'
      AND fn.created_at < now() - make_interval(days => v_ttl_days)
      AND NOT EXISTS (
        SELECT 1
        FROM data.ai_conversation_messages m
        INNER JOIN data.ai_conversations c ON c.id = m.conversation_id
        CROSS JOIN LATERAL data.extract_ai_chat_attachment_ids_from_payload(m.payload) AS ref(file_id)
        WHERE m.tenant_id = fn.tenant_id
          AND c.status IN ('active', 'archived')
          AND ref.file_id = fn.id
      )
    ORDER BY fn.created_at ASC
    LIMIT v_batch_limit
  LOOP
    v_candidates := v_candidates + 1;

    BEGIN
      PERFORM data.hard_delete_node(v_candidate.id, v_candidate.tenant_id);
      v_deleted := v_deleted + 1;
    EXCEPTION
      WHEN OTHERS THEN
        v_errors := v_errors + 1;
        RAISE WARNING 'cleanup_orphan_ai_chat_attachments: failed % (%): %',
          v_candidate.id, v_candidate.tenant_id, SQLERRM;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ttl_days', v_ttl_days,
    'batch_limit', v_batch_limit,
    'candidates', v_candidates,
    'deleted', v_deleted,
    'errors', v_errors
  );
END;
$$;

REVOKE ALL ON FUNCTION data.cleanup_orphan_ai_chat_attachments(integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.cleanup_orphan_ai_chat_attachments(integer, integer) FROM authenticated;
REVOKE ALL ON FUNCTION data.cleanup_orphan_ai_chat_attachments(integer, integer) FROM anon;

CREATE OR REPLACE FUNCTION api.run_ai_chat_orphan_cleanup_service(
  p_ttl_days    integer DEFAULT 90,
  p_batch_limit integer DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  RETURN data.cleanup_orphan_ai_chat_attachments(p_ttl_days, p_batch_limit);
END;
$$;

REVOKE ALL ON FUNCTION api.run_ai_chat_orphan_cleanup_service(integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.run_ai_chat_orphan_cleanup_service(integer, integer) TO service_role;

COMMENT ON FUNCTION data.cleanup_orphan_ai_chat_attachments IS
  'Esborra file_nodes source=ai-chat sense referència en converses active/archived i més antics que TTL. Crida hard_delete_node (quota + trash_deletion_queue).';

-- ---------------------------------------------------------------------------
-- 3) delete_ai_conversation — mateix criteri d''extracció (attachments + user_parts)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.delete_ai_conversation(p_conversation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid;
  v_user_id   uuid := auth.uid();
  v_file_id   uuid;
  v_deleted_files integer := 0;
BEGIN
  SELECT c.tenant_id
  INTO v_tenant_id
  FROM data.ai_conversations c
  WHERE c.id = p_conversation_id
    AND c.user_id = v_user_id
    AND c.tenant_id = data.active_tenant_id()
    AND c.status <> 'deleted';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Conversation not found';
  END IF;

  FOR v_file_id IN
    SELECT DISTINCT ref.file_id
    FROM data.ai_conversation_messages m
    CROSS JOIN LATERAL data.extract_ai_chat_attachment_ids_from_payload(m.payload) AS ref(file_id)
    WHERE m.conversation_id = p_conversation_id
      AND m.tenant_id = v_tenant_id
  LOOP
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM data.file_nodes fn
        WHERE fn.id = v_file_id
          AND fn.tenant_id = v_tenant_id
          AND fn.created_by = v_user_id
          AND fn.is_deleted = false
          AND fn.node_type = 'file'
          AND COALESCE(fn.metadata ->> 'source', '') = 'ai-chat'
      ) THEN
        PERFORM data.hard_delete_node(v_file_id, v_tenant_id);
        v_deleted_files := v_deleted_files + 1;
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        NULL;
    END;
  END LOOP;

  UPDATE data.ai_conversations
  SET status = 'deleted', updated_at = now()
  WHERE id = p_conversation_id
    AND user_id = v_user_id
    AND tenant_id = v_tenant_id;

  RETURN jsonb_build_object(
    'success', true,
    'id', p_conversation_id,
    'deleted_attachment_files', v_deleted_files
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.delete_ai_conversation(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4) pg_cron — diari 04:00 UTC (després de queue-expired-trash 03:00)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_job_id bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    SELECT jobid INTO v_job_id
    FROM cron.job
    WHERE jobname = 'cleanup-orphan-ai-chat-attachments'
    LIMIT 1;

    IF v_job_id IS NOT NULL THEN
      PERFORM cron.unschedule(v_job_id);
    END IF;

    PERFORM cron.schedule(
      'cleanup-orphan-ai-chat-attachments',
      '0 4 * * *',
      'SELECT data.cleanup_orphan_ai_chat_attachments();'
    );
  END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';
