-- Plantilles IA: etiqueta de format + missatge assistant des del xat

CREATE OR REPLACE FUNCTION api.search_document_templates_for_ai(
  p_tenant_id uuid,
  p_search    text DEFAULT NULL,
  p_limit     integer DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
  v_rows  jsonb;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT COALESCE(jsonb_agg(row_data ORDER BY template_name, format_label, locale), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'templateLocaleId', dtl.id,
      'templateId', dt.id,
      'templateName', dt.name,
      'locale', dtl.locale,
      'mimeType', dtl.mime_type,
      'formatLabel', CASE
        WHEN dtl.mime_type ILIKE '%html%' THEN 'HTML'
        ELSE 'DOCX'
      END
    ) AS row_data,
    dt.name AS template_name,
    CASE WHEN dtl.mime_type ILIKE '%html%' THEN 'HTML' ELSE 'DOCX' END AS format_label,
    dtl.locale
    FROM data.document_template_locales dtl
    JOIN data.document_templates dt ON dt.id = dtl.template_id
    WHERE dt.is_active = true
      AND (
        dt.tenant_id = p_tenant_id
        OR (dt.tenant_id IS NULL AND dt.is_platform_default = true)
      )
      AND (
        p_search IS NULL OR trim(p_search) = ''
        OR dt.name ILIKE '%' || trim(p_search) || '%'
      )
    ORDER BY dt.name, format_label, dtl.locale
    LIMIT v_limit
  ) sub;

  RETURN COALESCE(v_rows, '[]'::jsonb);
END;
$$;

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
  v_user_id   uuid := auth.uid();
  v_tenant_id uuid;
  v_sequence  integer;
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
    AND c.status <> 'deleted';

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Conversa no trobada';
  END IF;

  IF NOT data.is_tenant_member(v_tenant_id, v_user_id) THEN
    RAISE EXCEPTION 'forbidden';
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
