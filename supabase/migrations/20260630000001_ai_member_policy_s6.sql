-- S6: Polítiques IA per membre — ai_enabled, allowed_models, custom_tokens_daily_limit

CREATE OR REPLACE FUNCTION api.get_tenant_ai_user_policies(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  PERFORM api._assert_ai_owner_access(p_tenant_id);

  SELECT COALESCE(jsonb_agg(row_data ORDER BY email), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT jsonb_build_object(
      'user_id', m.user_id,
      'email', p.email,
      'full_name', p.full_name,
      'role', m.role,
      'policy', COALESCE(pol.policy, 'allow'),
      'custom_hourly_limit', pol.custom_hourly_limit,
      'custom_daily_limit', pol.custom_daily_limit,
      'custom_tokens_daily_limit', pol.custom_tokens_daily_limit,
      'ai_enabled', pol.ai_enabled,
      'allowed_models', COALESCE(pol.allowed_models, '{}'::jsonb),
      'notes', pol.notes,
      'updated_at', pol.updated_at
    ) AS row_data,
    p.email
    FROM (
      SELECT DISTINCT ON (tm.user_id)
        tm.user_id,
        tm.role
      FROM data.tenant_members tm
      WHERE tm.tenant_id = p_tenant_id
        AND tm.is_active = true
        AND tm.site_id IS NULL
      ORDER BY tm.user_id, tm.joined_at ASC
    ) m
    INNER JOIN data.profiles p ON p.id = m.user_id
    LEFT JOIN data.tenant_ai_user_policy pol
      ON pol.tenant_id = p_tenant_id AND pol.user_id = m.user_id
  ) sub;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

DROP FUNCTION IF EXISTS api.set_tenant_ai_user_policy(uuid, uuid, text, integer, integer, text);

CREATE OR REPLACE FUNCTION api.set_tenant_ai_user_policy(
  p_tenant_id                 uuid,
  p_user_id                   uuid,
  p_policy                    text,
  p_custom_hourly_limit       integer DEFAULT NULL,
  p_custom_daily_limit        integer DEFAULT NULL,
  p_notes                     text DEFAULT NULL,
  p_ai_enabled                boolean DEFAULT NULL,
  p_allowed_models            jsonb DEFAULT '{}'::jsonb,
  p_custom_tokens_daily_limit integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  PERFORM api._assert_ai_owner_access(p_tenant_id);

  IF lower(p_policy) NOT IN ('allow', 'warn_only', 'block') THEN
    RAISE EXCEPTION 'Invalid policy';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.tenant_members
    WHERE tenant_id = p_tenant_id AND user_id = p_user_id AND is_active = true
  ) THEN
    RAISE EXCEPTION 'User is not an active tenant member';
  END IF;

  INSERT INTO data.tenant_ai_user_policy (
    tenant_id,
    user_id,
    policy,
    custom_hourly_limit,
    custom_daily_limit,
    custom_tokens_daily_limit,
    ai_enabled,
    allowed_models,
    notes,
    updated_by
  ) VALUES (
    p_tenant_id,
    p_user_id,
    lower(p_policy),
    p_custom_hourly_limit,
    p_custom_daily_limit,
    p_custom_tokens_daily_limit,
    p_ai_enabled,
    COALESCE(p_allowed_models, '{}'::jsonb),
    p_notes,
    auth.uid()
  )
  ON CONFLICT (tenant_id, user_id) DO UPDATE
    SET policy = EXCLUDED.policy,
        custom_hourly_limit = EXCLUDED.custom_hourly_limit,
        custom_daily_limit = EXCLUDED.custom_daily_limit,
        custom_tokens_daily_limit = EXCLUDED.custom_tokens_daily_limit,
        ai_enabled = EXCLUDED.ai_enabled,
        allowed_models = EXCLUDED.allowed_models,
        notes = EXCLUDED.notes,
        updated_by = auth.uid(),
        updated_at = now();

  RETURN jsonb_build_object(
    'success', true,
    'user_id', p_user_id,
    'policy', lower(p_policy)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_tenant_ai_user_policy(
  uuid, uuid, text, integer, integer, text, boolean, jsonb, integer
) TO authenticated;
