-- Permet al manager registrar la confirmació mensual de l'empleat
-- (p. ex. empleat sense compte o confirmació presencial).

CREATE OR REPLACE FUNCTION api.manager_confirm_attendance_month(
  p_employee_id uuid,
  p_year        int,
  p_month       int
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp record;
  v_id  uuid;
BEGIN
  SELECT e.tenant_id, e.site_id INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.approve', v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege';
  END IF;

  IF p_month < 1 OR p_month > 12 THEN
    RAISE EXCEPTION 'invalid_month';
  END IF;

  INSERT INTO data.attendance_monthly_reports (
    tenant_id, employee_id, year, month, status, confirmed_by, confirmed_at
  )
  VALUES (
    v_emp.tenant_id, p_employee_id, p_year, p_month,
    'employee_confirmed', auth.uid(), now()
  )
  ON CONFLICT (employee_id, year, month) DO UPDATE SET
    status       = 'employee_confirmed',
    confirmed_by = auth.uid(),
    confirmed_at = now(),
    updated_at   = now()
  WHERE data.attendance_monthly_reports.status = 'draft'
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT amr.id INTO v_id
    FROM data.attendance_monthly_reports amr
    WHERE amr.employee_id = p_employee_id
      AND amr.year = p_year
      AND amr.month = p_month
      AND amr.status IN ('employee_confirmed', 'manager_approved', 'signed', 'archived');

    IF v_id IS NULL THEN
      RAISE EXCEPTION 'report_not_in_draft';
    END IF;
  END IF;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.manager_confirm_attendance_month(uuid, int, int) TO authenticated;

NOTIFY pgrst, 'reload schema';
