-- =============================================================================
-- Restore api.set_employee_photo_path
-- Dropped by later migrations that ran:
--   DROP VIEW IF EXISTS api.employees CASCADE;
-- (function RETURNS api.employees → cascade dependency)
-- Returns data.employees so future api.employees CASCADE drops do not remove it.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.set_employee_photo_path(
  p_employee_id uuid,
  p_photo_object_path text
)
RETURNS data.employees
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_emp       data.employees%ROWTYPE;
  v_expected  text;
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

  IF NOT data.jwt_can_manage_employee(v_emp.tenant_id, v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_photo_object_path IS NULL OR btrim(p_photo_object_path) = '' THEN
    UPDATE data.employees
    SET photo_object_path = NULL, updated_at = now()
    WHERE id = v_emp.id
    RETURNING * INTO v_emp;
  ELSE
    v_expected := v_tenant_id::text || '/' || v_emp.id::text || '/photo';
    IF btrim(p_photo_object_path) <> v_expected THEN
      RAISE EXCEPTION 'invalid_photo_path' USING ERRCODE = 'check_violation';
    END IF;
    UPDATE data.employees
    SET photo_object_path = v_expected, updated_at = now()
    WHERE id = v_emp.id
    RETURNING * INTO v_emp;
  END IF;

  RETURN v_emp;
END;
$$;

REVOKE EXECUTE ON FUNCTION api.set_employee_photo_path(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_employee_photo_path(uuid, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
