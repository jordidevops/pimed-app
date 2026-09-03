-- Track G6 Lot 1 (G6.8): resolve employee signer email (HR record → portal account)

CREATE OR REPLACE FUNCTION api.resolve_employee_signer_email(p_employee_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp   record;
  v_email text;
BEGIN
  SELECT e.tenant_id, e.site_id, e.user_id, e.email AS emp_email
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF NOT (
      v_emp.user_id = auth.uid()
      OR data.jwt_has_permission(v_emp.tenant_id, 'attendance.manage', v_emp.site_id)
      OR data.jwt_has_permission(v_emp.tenant_id, 'attendance.approve', v_emp.site_id)
      OR data.jwt_has_permission(v_emp.tenant_id, 'attendance.export', v_emp.site_id)
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege';
    END IF;
  END IF;

  v_email := NULLIF(trim(COALESCE(v_emp.emp_email, '')), '');

  IF v_email IS NULL AND v_emp.user_id IS NOT NULL THEN
    SELECT NULLIF(trim(COALESCE(p.email, '')), '')
    INTO v_email
    FROM data.profiles p
    WHERE p.id = v_emp.user_id;
  END IF;

  RETURN v_email;
END;
$$;

COMMENT ON FUNCTION api.resolve_employee_signer_email(uuid) IS
  'G6.8: correu del signant empleat (fitxa RRHH o compte portal vinculat).';

GRANT EXECUTE ON FUNCTION api.resolve_employee_signer_email(uuid) TO authenticated;
