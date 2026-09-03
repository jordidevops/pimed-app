-- Edge Functions no poden consultar data.* via PostgREST (schema data no exposat).
-- RPCs internes service_role per persistència de converses IA.

CREATE OR REPLACE FUNCTION api.ensure_ai_conversation_service(
  p_conversation_id uuid,
  p_tenant_id       uuid,
  p_user_id         uuid,
  p_site_id         uuid,
  p_provider        data.ai_provider,
  p_model           text,
  p_title           text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_conversation_id IS NOT NULL THEN
    SELECT id INTO v_id
    FROM data.ai_conversations
    WHERE id = p_conversation_id
      AND tenant_id = p_tenant_id
      AND user_id = p_user_id
      AND status <> 'deleted';

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Conversa no trobada';
    END IF;

    RETURN v_id;
  END IF;

  INSERT INTO data.ai_conversations (
    tenant_id, user_id, site_id, provider, model, title, status
  ) VALUES (
    p_tenant_id,
    p_user_id,
    p_site_id,
    p_provider,
    p_model,
    COALESCE(NULLIF(trim(p_title), ''), 'Nou xat'),
    'active'
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.load_ai_conversation_messages_service(
  p_conversation_id uuid,
  p_tenant_id       uuid,
  p_user_id         uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_rows jsonb;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.ai_conversations
    WHERE id = p_conversation_id
      AND tenant_id = p_tenant_id
      AND user_id = p_user_id
      AND status <> 'deleted'
  ) THEN
    RAISE EXCEPTION 'Conversa no trobada';
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'sequence', m.sequence,
      'role', m.role,
      'content', m.content,
      'tool_call_id', m.tool_call_id,
      'tool_name', m.tool_name,
      'payload', m.payload
    ) ORDER BY m.sequence
  ), '[]'::jsonb)
  INTO v_rows
  FROM data.ai_conversation_messages m
  WHERE m.conversation_id = p_conversation_id;

  RETURN v_rows;
END;
$$;

CREATE OR REPLACE FUNCTION api.get_next_ai_message_sequence_service(
  p_conversation_id uuid,
  p_tenant_id       uuid,
  p_user_id         uuid
)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_next integer;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.ai_conversations
    WHERE id = p_conversation_id
      AND tenant_id = p_tenant_id
      AND user_id = p_user_id
      AND status <> 'deleted'
  ) THEN
    RAISE EXCEPTION 'Conversa no trobada';
  END IF;

  SELECT COALESCE(MAX(sequence), 0) + 1
  INTO v_next
  FROM data.ai_conversation_messages
  WHERE conversation_id = p_conversation_id;

  RETURN v_next;
END;
$$;

CREATE OR REPLACE FUNCTION api.insert_ai_conversation_message_service(
  p_conversation_id uuid,
  p_tenant_id       uuid,
  p_user_id         uuid,
  p_sequence        integer,
  p_role            text,
  p_content         text,
  p_tool_call_id    text,
  p_tool_name       text,
  p_payload         jsonb
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

  IF NOT EXISTS (
    SELECT 1 FROM data.ai_conversations
    WHERE id = p_conversation_id
      AND tenant_id = p_tenant_id
      AND user_id = p_user_id
      AND status <> 'deleted'
  ) THEN
    RAISE EXCEPTION 'Conversa no trobada';
  END IF;

  INSERT INTO data.ai_conversation_messages (
    conversation_id, tenant_id, sequence, role, content,
    tool_call_id, tool_name, payload
  ) VALUES (
    p_conversation_id,
    p_tenant_id,
    p_sequence,
    p_role,
    p_content,
    p_tool_call_id,
    p_tool_name,
    COALESCE(p_payload, '{}'::jsonb)
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.touch_ai_conversation_service(
  p_conversation_id uuid,
  p_tenant_id       uuid,
  p_user_id         uuid
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
  SET updated_at = now()
  WHERE id = p_conversation_id
    AND tenant_id = p_tenant_id
    AND user_id = p_user_id
    AND status <> 'deleted';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Conversa no trobada';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION api.ensure_ai_conversation_service(uuid, uuid, uuid, uuid, data.ai_provider, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.load_ai_conversation_messages_service(uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_next_ai_message_sequence_service(uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.insert_ai_conversation_message_service(uuid, uuid, uuid, integer, text, text, text, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.touch_ai_conversation_service(uuid, uuid, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.ensure_ai_conversation_service(uuid, uuid, uuid, uuid, data.ai_provider, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION api.load_ai_conversation_messages_service(uuid, uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION api.get_next_ai_message_sequence_service(uuid, uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION api.insert_ai_conversation_message_service(uuid, uuid, uuid, integer, text, text, text, text, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION api.touch_ai_conversation_service(uuid, uuid, uuid) TO service_role;
