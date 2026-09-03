-- A3: tancament mensual sense manager_confirm; configuració bàsica de confirmació empleat.

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
BEGIN
  RAISE EXCEPTION 'deprecated: manager_confirm_attendance_month removed; use approve_attendance_month'
    USING ERRCODE = 'feature_not_supported';
END;
$$;

CREATE OR REPLACE FUNCTION api.approve_attendance_month(
  p_employee_id uuid, p_year int, p_month int
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = data, api
AS $$
DECLARE
  v_id                 uuid;
  v_emp                record;
  v_check              jsonb;
  v_settings           jsonb;
  v_require_confirm    boolean := true;
  v_can_close_without  boolean := true;
  v_report_status      text;
BEGIN
  SELECT * INTO v_emp FROM data.employees WHERE id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.approve', v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege';
  END IF;

  v_check := api.validate_attendance_month_close(p_employee_id, p_year, p_month);
  IF NOT COALESCE((v_check->>'closable')::boolean, false) THEN
    RAISE EXCEPTION 'month_not_closable'
      USING ERRCODE = 'check_violation',
            DETAIL = v_check::text;
  END IF;

  v_settings := api.get_effective_settings(
    p_site_id   => v_emp.site_id,
    p_tenant_id => v_emp.tenant_id
  );
  v_require_confirm := COALESCE(
    (v_settings->>'attendance_monthly_employee_confirm_required')::boolean,
    true
  );
  v_can_close_without := COALESCE(
    (v_settings->>'attendance_monthly_manager_can_close_without_employee')::boolean,
    true
  );

  SELECT amr.status INTO v_report_status
  FROM data.attendance_monthly_reports amr
  WHERE amr.employee_id = p_employee_id
    AND amr.year = p_year
    AND amr.month = p_month;

  IF v_report_status IS NULL THEN
    v_report_status := 'draft';
  END IF;

  IF v_require_confirm
     AND NOT v_can_close_without
     AND v_report_status = 'draft' THEN
    RAISE EXCEPTION 'employee_confirmation_required'
      USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO data.attendance_monthly_reports (tenant_id, employee_id, year, month, status, approved_by, approved_at)
  VALUES (v_emp.tenant_id, p_employee_id, p_year, p_month, 'manager_approved', auth.uid(), now())
  ON CONFLICT (employee_id, year, month) DO UPDATE SET
    status = 'manager_approved', approved_by = auth.uid(), approved_at = now(), updated_at = now()
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.approve_attendance_month(uuid, int, int) TO authenticated;

NOTIFY pgrst, 'reload schema';
