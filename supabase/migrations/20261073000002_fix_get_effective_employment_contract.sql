-- Fix get_effective_employment_contract: SELECT from api view (38 cols),
-- not data table (43 cols) — positional INTO was mapping jsonb {} onto uuid.

CREATE OR REPLACE FUNCTION api.get_effective_employment_contract(
  p_employee_id uuid,
  p_on date DEFAULT CURRENT_DATE
)
RETURNS api.employment_contracts
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_emp data.employees%ROWTYPE;
  v_out api.employment_contracts;
  v_on date := coalesce(p_on, CURRENT_DATE);
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT * INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT (
    data.jwt_can_view_employment_contracts(v_emp.tenant_id, v_emp.site_id)
    OR (v_emp.user_id IS NOT NULL AND v_emp.user_id = auth.uid())
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT c.* INTO v_out
  FROM api.employment_contracts c
  WHERE c.tenant_id = v_tenant_id
    AND c.employee_id = p_employee_id
    AND c.is_primary
    AND c.lifecycle_status IN ('active', 'scheduled', 'ended')
    AND c.starts_on <= v_on
    AND (c.ends_on IS NULL OR c.ends_on >= v_on)
  ORDER BY
    CASE c.lifecycle_status WHEN 'active' THEN 0 WHEN 'scheduled' THEN 1 ELSE 2 END,
    c.starts_on DESC
  LIMIT 1;

  RETURN v_out;
END;
$$;

REVOKE EXECUTE ON FUNCTION api.get_effective_employment_contract(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_effective_employment_contract(uuid, date) TO authenticated;

NOTIFY pgrst, 'reload schema';
