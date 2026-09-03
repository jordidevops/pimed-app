-- M1: Exposar allowed_models del membre a get_ai_user_access (selector model al xat)

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
    'allowed_models', COALESCE(v_policy.allowed_models, '{}'::jsonb),
    'blocked', (NOT v_ai_enabled) OR COALESCE(v_policy.policy, 'allow') = 'block',
    'warn_only', COALESCE(v_policy.policy, 'allow') = 'warn_only'
  );
END;
$$;
