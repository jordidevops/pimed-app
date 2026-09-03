-- M6b hardening: token generator portability + default expiry 7 days + pagination

ALTER TABLE data.ai_conversations
  ADD COLUMN IF NOT EXISTS share_expires_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_ai_conversations_share_expires_at
  ON data.ai_conversations (share_expires_at)
  WHERE share_expires_at IS NOT NULL;

COMMENT ON COLUMN data.ai_conversations.share_expires_at IS
  'Expiració del share link read-only de la conversa (default 7 dies).';

-- ---------------------------------------------------------------------------
-- Estat del share link (només propietari) + expiració
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_ai_conversation_share_status(p_conversation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row data.ai_conversations%ROWTYPE;
  v_enabled boolean;
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

  v_enabled := (
    v_row.share_token IS NOT NULL
    AND (v_row.share_expires_at IS NULL OR v_row.share_expires_at > now())
  );

  RETURN jsonb_build_object(
    'enabled', v_enabled,
    'share_token', CASE WHEN v_enabled THEN v_row.share_token ELSE NULL END,
    'share_enabled_at', v_row.share_enabled_at,
    'share_expires_at', v_row.share_expires_at
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_ai_conversation_share_status(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_ai_conversation_share_status(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION api.get_ai_conversation_share_status(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- Activar / regenerar share link (propietari) amb expiració default 7 dies
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.enable_ai_conversation_share(
  p_conversation_id uuid,
  p_expiry_seconds integer DEFAULT 604800
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_token text;
  v_expires_at timestamptz;
  v_expiry_seconds integer := LEAST(GREATEST(COALESCE(p_expiry_seconds, 604800), 3600), 2592000);
BEGIN
  -- Portable 64-hex token generator without relying on gen_random_bytes.
  v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  v_expires_at := now() + make_interval(secs => v_expiry_seconds);

  UPDATE data.ai_conversations
  SET
    share_token = v_token,
    share_enabled_at = now(),
    share_expires_at = v_expires_at,
    updated_at = now()
  WHERE id = p_conversation_id
    AND user_id = auth.uid()
    AND tenant_id = data.active_tenant_id()
    AND status <> 'deleted';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Conversation not found';
  END IF;

  RETURN jsonb_build_object(
    'enabled', true,
    'share_token', v_token,
    'share_expires_at', v_expires_at
  );
END;
$$;

REVOKE ALL ON FUNCTION api.enable_ai_conversation_share(uuid, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.enable_ai_conversation_share(uuid, integer) FROM anon;
GRANT EXECUTE ON FUNCTION api.enable_ai_conversation_share(uuid, integer) TO authenticated;

-- Compatibility overload for existing RPC clients calling one parameter.
CREATE OR REPLACE FUNCTION api.enable_ai_conversation_share(p_conversation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  RETURN api.enable_ai_conversation_share(p_conversation_id, 604800);
END;
$$;

REVOKE ALL ON FUNCTION api.enable_ai_conversation_share(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.enable_ai_conversation_share(uuid) FROM anon;
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
    share_expires_at = NULL,
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

REVOKE ALL ON FUNCTION api.disable_ai_conversation_share(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.disable_ai_conversation_share(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION api.disable_ai_conversation_share(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- Lectura read-only via share token amb paginació
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_ai_shared_conversation(
  p_share_token text,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
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
  v_total_messages integer := 0;
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 200);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF p_share_token IS NULL OR p_share_token !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Invalid share token';
  END IF;

  SELECT * INTO v_conv
  FROM data.ai_conversations
  WHERE share_token = p_share_token
    AND tenant_id = data.active_tenant_id()
    AND status IN ('active', 'archived')
    AND (share_expires_at IS NULL OR share_expires_at > now());

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

  SELECT COUNT(*)::integer
  INTO v_total_messages
  FROM data.ai_conversation_messages m
  WHERE m.conversation_id = v_conv.id
    AND m.role IN ('user', 'assistant');

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', msg.id,
      'sequence', msg.sequence,
      'role', msg.role,
      'content', msg.content,
      'tool_name', msg.tool_name,
      'payload', msg.payload,
      'created_at', msg.created_at
    ) ORDER BY msg.sequence
  ), '[]'::jsonb)
  INTO v_messages
  FROM (
    SELECT m.id, m.sequence, m.role, m.content, m.tool_name, m.payload, m.created_at
    FROM data.ai_conversation_messages m
    WHERE m.conversation_id = v_conv.id
      AND m.role IN ('user', 'assistant')
    ORDER BY m.sequence
    LIMIT v_limit
    OFFSET v_offset
  ) AS msg;

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
      'share_expires_at', v_conv.share_expires_at,
      'read_only', true
    ),
    'messages', v_messages,
    'page', jsonb_build_object(
      'limit', v_limit,
      'offset', v_offset,
      'total', v_total_messages,
      'has_more', (v_offset + v_limit) < v_total_messages,
      'next_offset', CASE WHEN (v_offset + v_limit) < v_total_messages THEN (v_offset + v_limit) ELSE NULL END
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_ai_shared_conversation(text, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_ai_shared_conversation(text, integer, integer) FROM anon;
GRANT EXECUTE ON FUNCTION api.get_ai_shared_conversation(text, integer, integer) TO authenticated;

-- Compatibility overload for existing frontend callers.
CREATE OR REPLACE FUNCTION api.get_ai_shared_conversation(p_share_token text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  RETURN api.get_ai_shared_conversation(p_share_token, 100, 0);
END;
$$;

REVOKE ALL ON FUNCTION api.get_ai_shared_conversation(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_ai_shared_conversation(text) FROM anon;
GRANT EXECUTE ON FUNCTION api.get_ai_shared_conversation(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
