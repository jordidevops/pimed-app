-- M1 hardening: indexable references from ai messages to file_nodes

-- ---------------------------------------------------------------------------
-- 1) Derived table: message -> file references
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.ai_message_file_refs (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id      uuid NOT NULL REFERENCES data.ai_conversation_messages(id) ON DELETE CASCADE,
  conversation_id uuid NOT NULL REFERENCES data.ai_conversations(id) ON DELETE CASCADE,
  tenant_id       uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  file_id         uuid NOT NULL REFERENCES data.file_nodes(id) ON DELETE CASCADE,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (message_id, file_id)
);

CREATE INDEX IF NOT EXISTS idx_ai_message_file_refs_tenant_file
  ON data.ai_message_file_refs (tenant_id, file_id);

CREATE INDEX IF NOT EXISTS idx_ai_message_file_refs_conversation
  ON data.ai_message_file_refs (conversation_id);

CREATE INDEX IF NOT EXISTS idx_ai_message_file_refs_message
  ON data.ai_message_file_refs (message_id);

ALTER TABLE data.ai_message_file_refs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_message_file_refs_select_own ON data.ai_message_file_refs;
CREATE POLICY ai_message_file_refs_select_own ON data.ai_message_file_refs
  FOR SELECT TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND EXISTS (
      SELECT 1
      FROM data.ai_conversations c
      WHERE c.id = conversation_id
        AND c.user_id = auth.uid()
        AND c.status <> 'deleted'
    )
  );

DROP POLICY IF EXISTS ai_message_file_refs_no_write ON data.ai_message_file_refs;
CREATE POLICY ai_message_file_refs_no_write ON data.ai_message_file_refs
  FOR ALL TO authenticated
  USING (false)
  WITH CHECK (false);

REVOKE ALL ON data.ai_message_file_refs FROM PUBLIC;
GRANT SELECT ON data.ai_message_file_refs TO authenticated;
GRANT ALL ON data.ai_message_file_refs TO service_role;

CREATE OR REPLACE VIEW api.ai_message_file_refs
WITH (security_invoker = true) AS
SELECT
  id, message_id, conversation_id, tenant_id, file_id, created_at
FROM data.ai_message_file_refs
WHERE tenant_id = data.active_tenant_id()
  AND EXISTS (
    SELECT 1
    FROM data.ai_conversations c
    WHERE c.id = conversation_id
      AND c.user_id = auth.uid()
      AND c.status <> 'deleted'
  );

GRANT SELECT ON api.ai_message_file_refs TO authenticated;

-- ---------------------------------------------------------------------------
-- 2) Historical backfill
-- ---------------------------------------------------------------------------
INSERT INTO data.ai_message_file_refs (
  message_id,
  conversation_id,
  tenant_id,
  file_id,
  created_at
)
SELECT
  m.id,
  m.conversation_id,
  m.tenant_id,
  ref.file_id,
  m.created_at
FROM data.ai_conversation_messages m
CROSS JOIN LATERAL data.extract_ai_chat_attachment_ids_from_payload(m.payload) AS ref(file_id)
INNER JOIN data.file_nodes fn
  ON fn.id = ref.file_id
 AND fn.tenant_id = m.tenant_id
ON CONFLICT (message_id, file_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3) Keep refs in sync at write-time
-- ---------------------------------------------------------------------------
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
DECLARE
  v_message_id uuid;
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
  )
  RETURNING id INTO v_message_id;

  INSERT INTO data.ai_message_file_refs (
    message_id,
    conversation_id,
    tenant_id,
    file_id
  )
  SELECT
    v_message_id,
    p_conversation_id,
    p_tenant_id,
    ref.file_id
  FROM data.extract_ai_chat_attachment_ids_from_payload(COALESCE(p_payload, '{}'::jsonb)) AS ref(file_id)
  INNER JOIN data.file_nodes fn
    ON fn.id = ref.file_id
   AND fn.tenant_id = p_tenant_id
  ON CONFLICT (message_id, file_id) DO NOTHING;
END;
$$;

REVOKE ALL ON FUNCTION api.insert_ai_conversation_message_service(uuid, uuid, uuid, integer, text, text, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.insert_ai_conversation_message_service(uuid, uuid, uuid, integer, text, text, text, text, jsonb) TO service_role;

NOTIFY pgrst, 'reload schema';
