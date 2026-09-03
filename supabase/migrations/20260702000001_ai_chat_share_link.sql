-- M6: share link read-only per converses IA (dins tenant, autenticat)

ALTER TABLE data.ai_conversations
  ADD COLUMN IF NOT EXISTS share_token text,
  ADD COLUMN IF NOT EXISTS share_enabled_at timestamptz;

CREATE UNIQUE INDEX IF NOT EXISTS idx_ai_conversations_share_token
  ON data.ai_conversations (share_token)
  WHERE share_token IS NOT NULL;

COMMENT ON COLUMN data.ai_conversations.share_token IS
  'Token opac per compartir conversa en mode read-only dins del tenant.';
COMMENT ON COLUMN data.ai_conversations.share_enabled_at IS
  'Timestamp quan es va activar el share link (revocat quan share_token = NULL).';

-- ---------------------------------------------------------------------------
-- Estat del share link (només propietari)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_ai_conversation_share_status(p_conversation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row data.ai_conversations%ROWTYPE;
BEGIN
  SELECT * INTO v_row
  FROM data.ai_conversations
  WHERE id = p_conversation_id
    AND user_id = auth.uid()
    AND tenant_id = data.active_tenant_id()
    AND status <> 'deleted';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Conversation not found';
  END IF;

  RETURN jsonb_build_object(
    'enabled', v_row.share_token IS NOT NULL,
    'share_token', v_row.share_token,
    'share_enabled_at', v_row.share_enabled_at
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_ai_conversation_share_status(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- Activar / generar share link (propietari)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.enable_ai_conversation_share(p_conversation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_token text;
BEGIN
  UPDATE data.ai_conversations
  SET
    share_token = COALESCE(
      share_token,
      encode(gen_random_bytes(32), 'hex')
    ),
    share_enabled_at = COALESCE(share_enabled_at, now()),
    updated_at = now()
  WHERE id = p_conversation_id
    AND user_id = auth.uid()
    AND tenant_id = data.active_tenant_id()
    AND status <> 'deleted'
  RETURNING share_token INTO v_token;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Conversation not found';
  END IF;

  RETURN jsonb_build_object(
    'enabled', true,
    'share_token', v_token
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.enable_ai_conversation_share(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- Revocar share link (propietari)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.disable_ai_conversation_share(p_conversation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  UPDATE data.ai_conversations
  SET
    share_token = NULL,
    share_enabled_at = NULL,
    updated_at = now()
  WHERE id = p_conversation_id
    AND user_id = auth.uid()
    AND tenant_id = data.active_tenant_id()
    AND status <> 'deleted';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Conversation not found';
  END IF;

  RETURN jsonb_build_object('enabled', false);
END;
$$;

GRANT EXECUTE ON FUNCTION api.disable_ai_conversation_share(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- Lectura read-only via share token (qualsevol membre actiu del tenant)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_ai_shared_conversation(p_share_token text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_conv data.ai_conversations%ROWTYPE;
  v_owner_name text;
  v_messages jsonb;
BEGIN
  IF p_share_token IS NULL OR p_share_token !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Invalid share token';
  END IF;

  SELECT * INTO v_conv
  FROM data.ai_conversations
  WHERE share_token = p_share_token
    AND tenant_id = data.active_tenant_id()
    AND status IN ('active', 'archived');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Shared conversation not found';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM data.tenant_members tm
    WHERE tm.tenant_id = v_conv.tenant_id
      AND tm.user_id = auth.uid()
      AND tm.is_active = true
  ) THEN
    RAISE EXCEPTION 'Access denied';
  END IF;

  SELECT COALESCE(p.full_name, p.email, 'Usuari')
  INTO v_owner_name
  FROM data.profiles p
  WHERE p.id = v_conv.user_id;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', m.id,
      'sequence', m.sequence,
      'role', m.role,
      'content', m.content,
      'tool_name', m.tool_name,
      'payload', m.payload,
      'created_at', m.created_at
    ) ORDER BY m.sequence
  ), '[]'::jsonb)
  INTO v_messages
  FROM data.ai_conversation_messages m
  WHERE m.conversation_id = v_conv.id
    AND m.role IN ('user', 'assistant');

  RETURN jsonb_build_object(
    'conversation', jsonb_build_object(
      'id', v_conv.id,
      'title', v_conv.title,
      'provider', v_conv.provider,
      'model', v_conv.model,
      'owner_user_id', v_conv.user_id,
      'owner_name', v_owner_name,
      'created_at', v_conv.created_at,
      'updated_at', v_conv.updated_at,
      'read_only', true
    ),
    'messages', v_messages
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_ai_shared_conversation(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
