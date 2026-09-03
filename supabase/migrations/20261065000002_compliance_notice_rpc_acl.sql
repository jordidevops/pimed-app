-- =============================================================================
-- M-CR-06b — Privilege check on api.run_emit_certification_expiry_notices
-- =============================================================================

CREATE OR REPLACE FUNCTION api.run_emit_certification_expiry_notices(
  p_as_of date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  -- service_role / cron: auth.uid() pot ser NULL
  IF auth.uid() IS NOT NULL THEN
    IF v_tenant_id IS NULL THEN
      RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF NOT (
      data.jwt_has_permission(v_tenant_id, 'compliance.requirements.manage')
      OR (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  RETURN data.emit_certification_expiry_notices(COALESCE(p_as_of, CURRENT_DATE));
END;
$$;

GRANT EXECUTE ON FUNCTION api.run_emit_certification_expiry_notices(date)
  TO service_role, authenticated;

NOTIFY pgrst, 'reload schema';
