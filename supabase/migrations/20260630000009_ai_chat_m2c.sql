-- M2c: títol automàtic (RPC), latència al payload (edge), neteja adjunts en esborrar conversa

-- ---------------------------------------------------------------------------
-- 1) Actualitzar títol de conversa (service_role, edge títol automàtic)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.update_ai_conversation_title_service(
  p_conversation_id uuid,
  p_tenant_id       uuid,
  p_user_id         uuid,
  p_title           text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  UPDATE data.ai_conversations
  SET
    title = left(trim(p_title), 80),
    metadata = metadata || jsonb_build_object('auto_title', true),
    updated_at = now()
  WHERE id = p_conversation_id
    AND tenant_id = p_tenant_id
    AND user_id = p_user_id
    AND status = 'active';
END;
$$;

REVOKE ALL ON FUNCTION api.update_ai_conversation_title_service(uuid, uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.update_ai_conversation_title_service(uuid, uuid, uuid, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 2) Esborrar conversa + adjunts ai-chat (allibera quota)
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
    SELECT DISTINCT (attachment.value ->> 'fileId')::uuid AS file_id
    FROM data.ai_conversation_messages m
    CROSS JOIN LATERAL jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(m.payload -> 'attachments') = 'array'
          THEN m.payload -> 'attachments'
        ELSE '[]'::jsonb
      END
    ) AS attachment(value)
    WHERE m.conversation_id = p_conversation_id
      AND m.tenant_id = v_tenant_id
      AND attachment.value ->> 'fileId' ~* '^[0-9a-f-]{36}$'
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

NOTIFY pgrst, 'reload schema';
