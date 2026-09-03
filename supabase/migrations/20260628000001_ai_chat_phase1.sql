-- =============================================================================
-- AI Chat Phase 1: converses, governança unificada, propostes, RBAC ai.*
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Ampliació governança tenant / usuari
-- ---------------------------------------------------------------------------
ALTER TABLE data.tenant_ai_provider_config
  ADD COLUMN IF NOT EXISTS enabled_models text[] NOT NULL DEFAULT '{}';

COMMENT ON COLUMN data.tenant_ai_provider_config.enabled_models IS
  'Whitelist de models permesos pel tenant. Buit = tots els available_models.';

ALTER TABLE data.tenant_ai_config
  ADD COLUMN IF NOT EXISTS rate_limit_tokens_per_day integer NOT NULL DEFAULT 500000,
  ADD COLUMN IF NOT EXISTS conversation_retention_days integer;

ALTER TABLE data.tenant_ai_config
  DROP CONSTRAINT IF EXISTS tenant_ai_config_rate_limit_tokens_per_day_check;
ALTER TABLE data.tenant_ai_config
  ADD CONSTRAINT tenant_ai_config_rate_limit_tokens_per_day_check
  CHECK (rate_limit_tokens_per_day > 0);

ALTER TABLE data.tenant_ai_user_policy
  ADD COLUMN IF NOT EXISTS ai_enabled boolean,
  ADD COLUMN IF NOT EXISTS allowed_models jsonb NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS custom_tokens_daily_limit integer;

-- ---------------------------------------------------------------------------
-- 2) Converses i missatges
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.ai_conversations (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id     uuid REFERENCES data.sites(id) ON DELETE SET NULL,
  user_id     uuid NOT NULL,
  title       text,
  provider    data.ai_provider NOT NULL,
  model       text NOT NULL,
  status      text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'archived', 'deleted')),
  metadata    jsonb NOT NULL DEFAULT '{}',
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_conversations_tenant_user
  ON data.ai_conversations (tenant_id, user_id, updated_at DESC);

CREATE TABLE IF NOT EXISTS data.ai_conversation_messages (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL REFERENCES data.ai_conversations(id) ON DELETE CASCADE,
  tenant_id       uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  sequence        integer NOT NULL,
  role            text NOT NULL CHECK (role IN ('system', 'user', 'assistant', 'tool')),
  content         text,
  tool_call_id    text,
  tool_name       text,
  payload         jsonb NOT NULL DEFAULT '{}',
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (conversation_id, sequence)
);

CREATE INDEX IF NOT EXISTS idx_ai_messages_conversation
  ON data.ai_conversation_messages (conversation_id, sequence);

-- ---------------------------------------------------------------------------
-- 3) Propostes d'escriptura (confirmació humana)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.ai_action_proposals (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id         uuid REFERENCES data.sites(id) ON DELETE SET NULL,
  user_id         uuid NOT NULL,
  conversation_id uuid REFERENCES data.ai_conversations(id) ON DELETE SET NULL,
  tool_name       text NOT NULL,
  proposal_token  text NOT NULL UNIQUE,
  payload         jsonb NOT NULL,
  status          text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'applied', 'rejected', 'expired')),
  applied_at      timestamptz,
  applied_by      uuid,
  idempotency_key text,
  correlation_id  uuid,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_action_proposals_tenant_user
  ON data.ai_action_proposals (tenant_id, user_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- 4) RLS — lectura pròpia; escriptura només service_role (Edge)
-- ---------------------------------------------------------------------------
ALTER TABLE data.ai_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.ai_conversation_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.ai_action_proposals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_conversations_select_own ON data.ai_conversations;
CREATE POLICY ai_conversations_select_own ON data.ai_conversations
  FOR SELECT TO authenticated
  USING (
    user_id = auth.uid()
    AND tenant_id = data.active_tenant_id()
    AND status <> 'deleted'
  );

DROP POLICY IF EXISTS ai_conversations_no_write ON data.ai_conversations;
CREATE POLICY ai_conversations_no_write ON data.ai_conversations
  FOR ALL TO authenticated
  USING (false)
  WITH CHECK (false);

DROP POLICY IF EXISTS ai_messages_select_own ON data.ai_conversation_messages;
CREATE POLICY ai_messages_select_own ON data.ai_conversation_messages
  FOR SELECT TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND EXISTS (
      SELECT 1 FROM data.ai_conversations c
      WHERE c.id = conversation_id
        AND c.user_id = auth.uid()
        AND c.status <> 'deleted'
    )
  );

DROP POLICY IF EXISTS ai_messages_no_write ON data.ai_conversation_messages;
CREATE POLICY ai_messages_no_write ON data.ai_conversation_messages
  FOR ALL TO authenticated
  USING (false)
  WITH CHECK (false);

DROP POLICY IF EXISTS ai_proposals_select_own ON data.ai_action_proposals;
CREATE POLICY ai_proposals_select_own ON data.ai_action_proposals
  FOR SELECT TO authenticated
  USING (
    user_id = auth.uid()
    AND tenant_id = data.active_tenant_id()
  );

DROP POLICY IF EXISTS ai_proposals_no_write ON data.ai_action_proposals;
CREATE POLICY ai_proposals_no_write ON data.ai_action_proposals
  FOR ALL TO authenticated
  USING (false)
  WITH CHECK (false);

GRANT SELECT ON data.ai_conversations TO authenticated;
GRANT SELECT ON data.ai_conversation_messages TO authenticated;
GRANT SELECT ON data.ai_action_proposals TO authenticated;

-- ---------------------------------------------------------------------------
-- 5) Vistes API
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.ai_conversations
WITH (security_invoker = true) AS
SELECT
  id, tenant_id, site_id, user_id, title, provider, model, status,
  metadata, created_at, updated_at
FROM data.ai_conversations
WHERE user_id = auth.uid()
  AND tenant_id = data.active_tenant_id()
  AND status <> 'deleted';

CREATE OR REPLACE VIEW api.ai_conversation_messages
WITH (security_invoker = true) AS
SELECT
  m.id, m.conversation_id, m.tenant_id, m.sequence, m.role, m.content,
  m.tool_call_id, m.tool_name, m.payload, m.created_at
FROM data.ai_conversation_messages m
INNER JOIN data.ai_conversations c ON c.id = m.conversation_id
WHERE c.user_id = auth.uid()
  AND m.tenant_id = data.active_tenant_id()
  AND c.status <> 'deleted';

GRANT SELECT ON api.ai_conversations TO authenticated;
GRANT SELECT ON api.ai_conversation_messages TO authenticated;

-- ---------------------------------------------------------------------------
-- 6) RBAC — permisos ai.* a get_role_permissions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.get_role_permissions(
  p_role              text,
  p_custom_perms      jsonb DEFAULT NULL
)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_viewer_base  text[] := ARRAY[
    'storage.view', 'calendar.view', 'email.view', 'invoices.view',
    'members.view', 'sites.view', 'settings.view',
    'attendance.view_own', 'labor_calendar.view'
  ];
  v_member_base  text[] := ARRAY[
    'storage.upload', 'calendar.edit', 'email.send', 'invoices.edit',
    'attendance.punch_own', 'absences.request',
    'ai.use'
  ];
  v_manager_base text[] := ARRAY[
    'storage.delete', 'calendar.manage', 'email.manage', 'invoices.manage',
    'members.invite', 'sites.create', 'settings.manage', 'permissions.manage',
    'attendance.view_all', 'attendance.adjust', 'attendance.approve',
    'attendance.export', 'attendance.devices.manage',
    'labor_calendar.manage', 'absences.approve',
    'ai.configure', 'ai.tools.write'
  ];
  v_accumulated  text[] := '{}';
BEGIN
  IF p_role = 'owner' THEN
    RETURN ARRAY['*'];
  END IF;

  IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'viewer' THEN
    v_accumulated := v_accumulated ||
      ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'viewer'));
  ELSE
    v_accumulated := v_accumulated || v_viewer_base;
  END IF;

  IF p_role IN ('member', 'manager') THEN
    IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'member' THEN
      v_accumulated := v_accumulated ||
        ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'member'));
    ELSE
      v_accumulated := v_accumulated || v_member_base;
    END IF;
  END IF;

  IF p_role = 'manager' THEN
    IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'manager' THEN
      v_accumulated := v_accumulated ||
        ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'manager'));
    ELSE
      v_accumulated := v_accumulated || v_manager_base;
    END IF;
  END IF;

  RETURN ARRAY(SELECT DISTINCT unnest(v_accumulated));
END;
$$;

-- ---------------------------------------------------------------------------
-- 7) Models efectius permesos
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.effective_ai_allowed_models(
  p_tenant_id uuid,
  p_user_id   uuid,
  p_provider  data.ai_provider
)
RETURNS text[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_cfg           data.tenant_ai_provider_config%ROWTYPE;
  v_user_pol      data.tenant_ai_user_policy%ROWTYPE;
  v_available     text[] := '{}';
  v_enabled       text[] := '{}';
  v_user_models   text[];
  v_result        text[] := '{}';
  v_model         text;
BEGIN
  SELECT * INTO v_cfg
  FROM data.tenant_ai_provider_config
  WHERE tenant_id = p_tenant_id AND provider = p_provider;

  IF NOT FOUND OR v_cfg.ai_key_secret_id IS NULL OR v_cfg.key_verified_at IS NULL THEN
    RETURN '{}';
  END IF;

  v_available := COALESCE(v_cfg.available_models, '{}');
  IF array_length(v_available, 1) IS NULL OR array_length(v_available, 1) = 0 THEN
    v_available := ARRAY[COALESCE(v_cfg.model, api.ai_provider_default_model(p_provider))];
  END IF;

  v_enabled := COALESCE(v_cfg.enabled_models, '{}');
  IF array_length(v_enabled, 1) IS NULL OR array_length(v_enabled, 1) = 0 THEN
    v_result := v_available;
  ELSE
    FOREACH v_model IN ARRAY v_enabled LOOP
      IF v_model = ANY (v_available) THEN
        v_result := array_append(v_result, v_model);
      END IF;
    END LOOP;
  END IF;

  SELECT * INTO v_user_pol
  FROM data.tenant_ai_user_policy
  WHERE tenant_id = p_tenant_id AND user_id = p_user_id;

  IF FOUND AND v_user_pol.allowed_models ? p_provider::text THEN
    SELECT ARRAY(
      SELECT jsonb_array_elements_text(v_user_pol.allowed_models -> p_provider::text)
    ) INTO v_user_models;

    IF array_length(v_user_models, 1) IS NOT NULL AND array_length(v_user_models, 1) > 0 THEN
      v_result := ARRAY(
        SELECT unnest(v_result)
        INTERSECT
        SELECT unnest(v_user_models)
      );
    END IF;
  END IF;

  RETURN COALESCE(v_result, '{}');
END;
$$;

REVOKE ALL ON FUNCTION api.effective_ai_allowed_models(uuid, uuid, data.ai_provider) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.effective_ai_allowed_models(uuid, uuid, data.ai_provider) TO service_role;

-- ---------------------------------------------------------------------------
-- 8) get_ai_user_access — ai_enabled
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_ai_user_access(p_tenant_id uuid, p_user_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_user_id       uuid := COALESCE(p_user_id, auth.uid());
  v_policy        data.tenant_ai_user_policy%ROWTYPE;
  v_cfg           data.tenant_ai_config%ROWTYPE;
  v_configured    boolean := false;
  v_ai_enabled    boolean := true;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF auth.uid() IS NOT NULL AND auth.uid() <> v_user_id THEN
    IF NOT (
      data.jwt_user_tenants() ? p_tenant_id::text
      AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    ) THEN
      RAISE EXCEPTION 'Access denied';
    END IF;
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.tenant_members
      WHERE tenant_id = p_tenant_id
        AND user_id = v_user_id
        AND is_active = true
    ) THEN
      RAISE EXCEPTION 'Access denied: not a tenant member';
    END IF;
  END IF;

  SELECT * INTO v_cfg
  FROM data.tenant_ai_config
  WHERE tenant_id = p_tenant_id;

  SELECT EXISTS (
    SELECT 1
    FROM data.tenant_ai_provider_config pc
    JOIN data.tenant_ai_config tc ON tc.tenant_id = pc.tenant_id
    WHERE pc.tenant_id = p_tenant_id
      AND pc.provider = COALESCE(v_cfg.default_provider, 'openai'::data.ai_provider)
      AND pc.ai_key_secret_id IS NOT NULL
      AND pc.key_verified_at IS NOT NULL
      AND COALESCE(tc.is_active, true) = true
  ) INTO v_configured;

  SELECT * INTO v_policy
  FROM data.tenant_ai_user_policy
  WHERE tenant_id = p_tenant_id
    AND user_id = v_user_id;

  IF FOUND AND v_policy.ai_enabled IS NOT NULL THEN
    v_ai_enabled := v_policy.ai_enabled;
  ELSIF FOUND THEN
    v_ai_enabled := true;
  END IF;

  RETURN jsonb_build_object(
    'configured', v_configured,
    'ai_enabled', v_ai_enabled,
    'policy', COALESCE(v_policy.policy, 'allow'),
    'custom_hourly_limit', v_policy.custom_hourly_limit,
    'custom_daily_limit', v_policy.custom_daily_limit,
    'custom_tokens_daily_limit', v_policy.custom_tokens_daily_limit,
    'blocked', (NOT v_ai_enabled) OR COALESCE(v_policy.policy, 'allow') = 'block',
    'warn_only', COALESCE(v_policy.policy, 'allow') = 'warn_only'
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- 9) Tokens diaris — comprovació
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.check_ai_tokens_daily_limit(
  p_tenant_id uuid,
  p_user_id   uuid,
  p_estimated_tokens integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_cfg           data.tenant_ai_config%ROWTYPE;
  v_user_pol      data.tenant_ai_user_policy%ROWTYPE;
  v_limit         integer := 500000;
  v_day_start     timestamptz := date_trunc('day', now());
  v_used          bigint := 0;
BEGIN
  SELECT * INTO v_cfg FROM data.tenant_ai_config WHERE tenant_id = p_tenant_id;
  IF FOUND THEN
    v_limit := COALESCE(v_cfg.rate_limit_tokens_per_day, 500000);
  END IF;

  SELECT * INTO v_user_pol
  FROM data.tenant_ai_user_policy
  WHERE tenant_id = p_tenant_id AND user_id = p_user_id;

  IF FOUND AND v_user_pol.custom_tokens_daily_limit IS NOT NULL THEN
    v_limit := v_user_pol.custom_tokens_daily_limit;
  END IF;

  SELECT COALESCE(SUM(
    COALESCE(prompt_tokens, 0) + COALESCE(completion_tokens, 0)
  ), 0) INTO v_used
  FROM data.ai_usage_ledger
  WHERE tenant_id = p_tenant_id
    AND user_id = p_user_id
    AND created_at >= v_day_start
    AND request_status = 'success';

  IF v_limit > 0 AND (v_used + GREATEST(p_estimated_tokens, 0)) > v_limit THEN
    RETURN jsonb_build_object(
      'allowed', false,
      'tokens_used', v_used,
      'tokens_limit', v_limit,
      'estimated', p_estimated_tokens
    );
  END IF;

  RETURN jsonb_build_object(
    'allowed', true,
    'tokens_used', v_used,
    'tokens_limit', v_limit,
    'estimated', p_estimated_tokens
  );
END;
$$;

REVOKE ALL ON FUNCTION api.check_ai_tokens_daily_limit(uuid, uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.check_ai_tokens_daily_limit(uuid, uuid, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 10) prepare_ai_execution — governança central
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.prepare_ai_execution(
  p_tenant_id        uuid,
  p_user_id          uuid,
  p_site_id          uuid DEFAULT NULL,
  p_feature          text DEFAULT 'generic',
  p_provider         text DEFAULT NULL,
  p_model            text DEFAULT NULL,
  p_estimated_tokens integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_cfg             data.tenant_ai_config%ROWTYPE;
  v_provider        data.ai_provider;
  v_model           text;
  v_access          jsonb;
  v_allowed_models  text[];
  v_rate            jsonb;
  v_tokens          jsonb;
  v_warnings        jsonb := '[]'::jsonb;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM data.tenant_members
    WHERE tenant_id = p_tenant_id
      AND user_id = p_user_id
      AND is_active = true
  ) THEN
    RAISE EXCEPTION 'AI_NOT_MEMBER';
  END IF;

  SELECT * INTO v_cfg FROM data.tenant_ai_config WHERE tenant_id = p_tenant_id;

  IF FOUND AND COALESCE(v_cfg.is_active, true) = false THEN
    RAISE EXCEPTION 'AI_TENANT_DISABLED';
  END IF;

  v_access := api.get_ai_user_access(p_tenant_id, p_user_id);

  IF NOT (v_access ->> 'configured')::boolean THEN
    RAISE EXCEPTION 'AI_NOT_CONFIGURED';
  END IF;

  IF (v_access ->> 'blocked')::boolean THEN
    RAISE EXCEPTION 'AI_USER_BLOCKED';
  END IF;

  IF (v_access ->> 'warn_only')::boolean THEN
    v_warnings := v_warnings || jsonb_build_array('warn_only_user');
  END IF;

  v_provider := COALESCE(
    NULLIF(lower(trim(p_provider)), '')::data.ai_provider,
    v_cfg.default_provider,
    'openai'::data.ai_provider
  );

  v_model := NULLIF(trim(p_model), '');
  IF v_model IS NULL THEN
    SELECT model INTO v_model
    FROM data.tenant_ai_provider_config
    WHERE tenant_id = p_tenant_id AND provider = v_provider;
  END IF;

  v_model := COALESCE(v_model, api.ai_provider_default_model(v_provider));

  v_allowed_models := api.effective_ai_allowed_models(p_tenant_id, p_user_id, v_provider);
  IF array_length(v_allowed_models, 1) IS NULL
     OR NOT (v_model = ANY (v_allowed_models)) THEN
    RAISE EXCEPTION 'AI_MODEL_NOT_ALLOWED';
  END IF;

  v_tokens := api.check_ai_tokens_daily_limit(p_tenant_id, p_user_id, p_estimated_tokens);
  IF NOT (v_tokens ->> 'allowed')::boolean THEN
    RAISE EXCEPTION 'AI_TOKENS_DAILY_LIMIT';
  END IF;

  v_rate := api.check_and_increment_ai_rate_limit(p_tenant_id, p_user_id);
  IF NOT (v_rate ->> 'allowed')::boolean THEN
    RAISE EXCEPTION 'AI_RATE_LIMIT';
  END IF;

  IF (v_rate ->> 'near_limit')::boolean THEN
    v_warnings := v_warnings || jsonb_build_array('near_rate_limit');
  END IF;

  RETURN jsonb_build_object(
    'allowed', true,
    'provider', v_provider,
    'model', v_model,
    'warnings', v_warnings,
    'rate', v_rate,
    'tokens', v_tokens
  );
END;
$$;

REVOKE ALL ON FUNCTION api.prepare_ai_execution(uuid, uuid, uuid, text, text, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.prepare_ai_execution(uuid, uuid, uuid, text, text, text, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 11) Cerca empleats per tools IA (tenant injectat al servidor)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.search_employees_for_ai(
  p_tenant_id     uuid,
  p_search        text DEFAULT NULL,
  p_department_id uuid DEFAULT NULL,
  p_limit         integer DEFAULT 20
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
  SELECT COALESCE(jsonb_agg(row_data ORDER BY full_name), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'id', e.id,
      'full_name', e.full_name,
      'email', e.email,
      'job_title', e.job_title,
      'status', e.status,
      'department_id', e.department_id
    ) AS row_data,
    e.full_name
    FROM data.employees e
    WHERE e.tenant_id = p_tenant_id
      AND (p_department_id IS NULL OR e.department_id = p_department_id)
      AND (
        p_search IS NULL OR trim(p_search) = ''
        OR e.full_name ILIKE '%' || trim(p_search) || '%'
        OR COALESCE(e.email, '') ILIKE '%' || trim(p_search) || '%'
        OR COALESCE(e.document_id, '') ILIKE '%' || trim(p_search) || '%'
      )
    ORDER BY e.full_name
    LIMIT v_limit
  ) sub;

  RETURN COALESCE(v_rows, '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION api.search_employees_for_ai(uuid, text, uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.search_employees_for_ai(uuid, text, uuid, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 12) Soft-delete conversa (usuari propietari)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.delete_ai_conversation(p_conversation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  UPDATE data.ai_conversations
  SET status = 'deleted', updated_at = now()
  WHERE id = p_conversation_id
    AND user_id = auth.uid()
    AND tenant_id = data.active_tenant_id();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Conversation not found';
  END IF;

  RETURN jsonb_build_object('success', true, 'id', p_conversation_id);
END;
$$;

GRANT EXECUTE ON FUNCTION api.delete_ai_conversation(uuid) TO authenticated;

GRANT ALL ON data.ai_conversations TO service_role;
GRANT ALL ON data.ai_conversation_messages TO service_role;
GRANT ALL ON data.ai_action_proposals TO service_role;
