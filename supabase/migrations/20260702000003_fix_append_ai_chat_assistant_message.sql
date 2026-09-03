-- Fix: data.is_tenant_member no existeix; validar conversa + tenant actiu

CREATE OR REPLACE FUNCTION api.append_ai_chat_assistant_message(
  p_conversation_id uuid,
  p_content         text,
  p_payload         jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_user_id    uuid := auth.uid();
  v_tenant_id  uuid;
  v_sequence   integer;
  v_message_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT c.tenant_id
  INTO v_tenant_id
  FROM data.ai_conversations c
  WHERE c.id = p_conversation_id
    AND c.user_id = v_user_id
    AND c.status <> 'deleted'
    AND c.tenant_id = data.active_tenant_id();

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Conversa no trobada';
  END IF;

  SELECT COALESCE(MAX(m.sequence), 0) + 1
  INTO v_sequence
  FROM data.ai_conversation_messages m
  WHERE m.conversation_id = p_conversation_id;

  INSERT INTO data.ai_conversation_messages (
    conversation_id, tenant_id, sequence, role, content, payload
  ) VALUES (
    p_conversation_id,
    v_tenant_id,
    v_sequence,
    'assistant',
    COALESCE(p_content, ''),
    COALESCE(p_payload, '{}'::jsonb)
  )
  RETURNING id INTO v_message_id;

  UPDATE data.ai_conversations
  SET updated_at = now()
  WHERE id = p_conversation_id;

  RETURN jsonb_build_object(
    'message_id', v_message_id,
    'sequence', v_sequence
  );
END;
$$;

REVOKE ALL ON FUNCTION api.append_ai_chat_assistant_message(uuid, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.append_ai_chat_assistant_message(uuid, text, jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';
