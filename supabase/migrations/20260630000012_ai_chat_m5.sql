-- M5: regenerar últim torn + presets de xat

-- ---------------------------------------------------------------------------
-- 1) Presets de xat
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.ai_chat_presets (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id               uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  created_by              uuid NOT NULL,
  name                    text NOT NULL,
  provider                data.ai_provider NOT NULL,
  model                   text NOT NULL,
  system_prompt_override  text,
  temperature_override    numeric,
  is_tenant_shared        boolean NOT NULL DEFAULT false,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ai_chat_presets_name_not_empty CHECK (length(trim(name)) > 0)
);

CREATE INDEX IF NOT EXISTS idx_ai_chat_presets_tenant
  ON data.ai_chat_presets (tenant_id, is_tenant_shared, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_chat_presets_owner
  ON data.ai_chat_presets (tenant_id, created_by, updated_at DESC);

ALTER TABLE data.ai_chat_presets ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_chat_presets_select ON data.ai_chat_presets;
CREATE POLICY ai_chat_presets_select ON data.ai_chat_presets
  FOR SELECT TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND (
      created_by = auth.uid()
      OR is_tenant_shared = true
    )
  );

DROP POLICY IF EXISTS ai_chat_presets_no_write ON data.ai_chat_presets;
CREATE POLICY ai_chat_presets_no_write ON data.ai_chat_presets
  FOR ALL TO authenticated
  USING (false)
  WITH CHECK (false);

CREATE OR REPLACE VIEW api.ai_chat_presets
WITH (security_invoker = true) AS
SELECT
  id,
  tenant_id,
  created_by,
  name,
  provider,
  model,
  system_prompt_override,
  temperature_override,
  is_tenant_shared,
  created_at,
  updated_at
FROM data.ai_chat_presets
WHERE tenant_id = data.active_tenant_id()
  AND (created_by = auth.uid() OR is_tenant_shared = true);

GRANT SELECT ON api.ai_chat_presets TO authenticated;
GRANT SELECT ON data.ai_chat_presets TO authenticated;
GRANT ALL ON data.ai_chat_presets TO service_role;

-- ---------------------------------------------------------------------------
-- 2) ensure_ai_conversation_service — metadata (preset)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.ensure_ai_conversation_service(
  p_conversation_id uuid,
  p_tenant_id       uuid,
  p_user_id         uuid,
  p_site_id         uuid,
  p_provider        data.ai_provider,
  p_model           text,
  p_title           text,
  p_metadata        jsonb DEFAULT '{}'::jsonb
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
    tenant_id, user_id, site_id, provider, model, title, status, metadata
  ) VALUES (
    p_tenant_id,
    p_user_id,
    p_site_id,
    p_provider,
    p_model,
    COALESCE(NULLIF(trim(p_title), ''), 'Nou xat'),
    'active',
    COALESCE(p_metadata, '{}'::jsonb)
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.ensure_ai_conversation_service(uuid, uuid, uuid, uuid, data.ai_provider, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.ensure_ai_conversation_service(uuid, uuid, uuid, uuid, data.ai_provider, text, text, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Preset CRUD (authenticated)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.upsert_ai_chat_preset(
  p_id                      uuid,
  p_name                    text,
  p_provider                data.ai_provider,
  p_model                   text,
  p_system_prompt_override  text DEFAULT NULL,
  p_temperature_override    numeric DEFAULT NULL,
  p_is_tenant_shared        boolean DEFAULT false
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_role      text;
  v_id        uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.tenant_members
    WHERE tenant_id = v_tenant_id AND user_id = auth.uid() AND is_active = true
  ) THEN
    RAISE EXCEPTION 'Access denied';
  END IF;

  SELECT tm.role INTO v_role
  FROM data.tenant_members tm
  WHERE tm.tenant_id = v_tenant_id AND tm.user_id = auth.uid() AND tm.is_active = true;

  IF p_is_tenant_shared AND v_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'Only owner/manager can create shared presets';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO data.ai_chat_presets (
      tenant_id, created_by, name, provider, model,
      system_prompt_override, temperature_override, is_tenant_shared
    ) VALUES (
      v_tenant_id,
      auth.uid(),
      trim(p_name),
      p_provider,
      trim(p_model),
      nullif(trim(p_system_prompt_override), ''),
      p_temperature_override,
      COALESCE(p_is_tenant_shared, false)
    )
    RETURNING id INTO v_id;
    RETURN v_id;
  END IF;

  UPDATE data.ai_chat_presets
  SET
    name = trim(p_name),
    provider = p_provider,
    model = trim(p_model),
    system_prompt_override = nullif(trim(p_system_prompt_override), ''),
    temperature_override = p_temperature_override,
    is_tenant_shared = CASE
      WHEN v_role IN ('owner', 'manager') THEN COALESCE(p_is_tenant_shared, is_tenant_shared)
      ELSE false
    END,
    updated_at = now()
  WHERE id = p_id
    AND tenant_id = v_tenant_id
    AND created_by = auth.uid();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Preset not found';
  END IF;

  RETURN p_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_ai_chat_preset(uuid, text, data.ai_provider, text, text, numeric, boolean) TO authenticated;

CREATE OR REPLACE FUNCTION api.delete_ai_chat_preset(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_role      text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT tm.role INTO v_role
  FROM data.tenant_members tm
  WHERE tm.tenant_id = v_tenant_id AND tm.user_id = auth.uid() AND tm.is_active = true;

  DELETE FROM data.ai_chat_presets p
  WHERE p.id = p_id
    AND p.tenant_id = v_tenant_id
    AND (
      p.created_by = auth.uid()
      OR (p.is_tenant_shared = true AND v_role IN ('owner', 'manager'))
    );

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Preset not found';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION api.delete_ai_chat_preset(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION api.get_ai_chat_preset_service(
  p_preset_id uuid,
  p_tenant_id uuid,
  p_user_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row data.ai_chat_presets%ROWTYPE;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_row
  FROM data.ai_chat_presets p
  WHERE p.id = p_preset_id
    AND p.tenant_id = p_tenant_id
    AND (
      p.created_by = p_user_id
      OR p.is_tenant_shared = true
    );

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'name', v_row.name,
    'provider', v_row.provider,
    'model', v_row.model,
    'system_prompt_override', v_row.system_prompt_override,
    'temperature_override', v_row.temperature_override,
    'is_tenant_shared', v_row.is_tenant_shared
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_ai_chat_preset_service(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_ai_chat_preset_service(uuid, uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 4) Regenerar últim torn
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.prepare_regenerate_ai_chat_turn_service(
  p_conversation_id uuid,
  p_tenant_id       uuid,
  p_user_id         uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_last_user_seq integer;
  v_start_seq     integer;
  v_has_attachments boolean := false;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.ai_conversations
    WHERE id = p_conversation_id
      AND tenant_id = p_tenant_id
      AND user_id = p_user_id
      AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'Conversa no trobada';
  END IF;

  SELECT MAX(m.sequence)
  INTO v_last_user_seq
  FROM data.ai_conversation_messages m
  WHERE m.conversation_id = p_conversation_id
    AND m.role = 'user';

  IF v_last_user_seq IS NULL THEN
    RAISE EXCEPTION 'NO_USER_MESSAGE';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM data.ai_conversation_messages m
    WHERE m.conversation_id = p_conversation_id
      AND m.sequence = v_last_user_seq
      AND (
        jsonb_typeof(m.payload -> 'attachments') = 'array'
        AND jsonb_array_length(m.payload -> 'attachments') > 0
      )
  ) INTO v_has_attachments;

  UPDATE data.ai_action_proposals
  SET status = 'expired'
  WHERE conversation_id = p_conversation_id
    AND status = 'pending'
    AND created_at >= (
      SELECT created_at
      FROM data.ai_conversation_messages
      WHERE conversation_id = p_conversation_id
        AND sequence = v_last_user_seq
      LIMIT 1
    );

  DELETE FROM data.ai_conversation_messages
  WHERE conversation_id = p_conversation_id
    AND sequence > v_last_user_seq;

  v_start_seq := v_last_user_seq + 1;

  UPDATE data.ai_conversations
  SET updated_at = now()
  WHERE id = p_conversation_id;

  RETURN jsonb_build_object(
    'conversation_id', p_conversation_id,
    'last_user_sequence', v_last_user_seq,
    'start_sequence', v_start_seq,
    'has_attachments', v_has_attachments
  );
END;
$$;

REVOKE ALL ON FUNCTION api.prepare_regenerate_ai_chat_turn_service(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.prepare_regenerate_ai_chat_turn_service(uuid, uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION api.get_ai_conversation_service(
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
  v_row data.ai_conversations%ROWTYPE;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_row
  FROM data.ai_conversations c
  WHERE c.id = p_conversation_id
    AND c.tenant_id = p_tenant_id
    AND c.user_id = p_user_id
    AND c.status <> 'deleted';

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'provider', v_row.provider,
    'model', v_row.model,
    'metadata', v_row.metadata,
    'title', v_row.title
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_ai_conversation_service(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_ai_conversation_service(uuid, uuid, uuid) TO service_role;

NOTIFY pgrst, 'reload schema';
