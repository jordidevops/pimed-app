-- Validació confirmació empleat + A7 signatura DMS amb validació A2.

CREATE OR REPLACE FUNCTION api.validate_attendance_month_employee_confirm(
  p_employee_id uuid,
  p_year        int,
  p_month       int
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_full     jsonb;
  v_blockers jsonb := '[]'::jsonb;
  v_item     jsonb;
BEGIN
  v_full := api.validate_attendance_month_close(p_employee_id, p_year, p_month);

  FOR v_item IN SELECT value FROM jsonb_array_elements(COALESCE(v_full -> 'blockers', '[]'::jsonb))
  LOOP
    IF v_item ->> 'code' IN (
      'FUTURE_MONTH',
      'CURRENT_MONTH_INCOMPLETE',
      'OPEN_TIME_ENTRY'
    ) THEN
      v_blockers := v_blockers || jsonb_build_array(v_item);
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'confirmable', jsonb_array_length(v_blockers) = 0,
    'blockers', v_blockers,
    'period', v_full -> 'period'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.validate_attendance_month_employee_confirm(uuid, int, int) TO authenticated;

CREATE OR REPLACE FUNCTION api.confirm_attendance_month(
  p_employee_id uuid, p_year int, p_month int
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = data, api
AS $$
DECLARE
  v_id    uuid;
  v_emp   record;
  v_check jsonb;
BEGIN
  SELECT e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.user_id = auth.uid();

  IF v_emp.tenant_id IS NULL THEN
    RAISE EXCEPTION 'insufficient_privilege';
  END IF;

  v_check := api.validate_attendance_month_employee_confirm(p_employee_id, p_year, p_month);
  IF NOT COALESCE((v_check->>'confirmable')::boolean, false) THEN
    RAISE EXCEPTION 'month_not_confirmable'
      USING ERRCODE = 'check_violation',
            DETAIL = v_check::text;
  END IF;

  INSERT INTO data.attendance_monthly_reports (tenant_id, employee_id, year, month, status, confirmed_by, confirmed_at)
  VALUES (v_emp.tenant_id, p_employee_id, p_year, p_month, 'employee_confirmed', auth.uid(), now())
  ON CONFLICT (employee_id, year, month) DO UPDATE SET
    status = 'employee_confirmed', confirmed_by = auth.uid(), confirmed_at = now(), updated_at = now()
  RETURNING id INTO v_id;

  PERFORM data.log_attendance_employee_audit(
    v_emp.tenant_id,
    auth.uid(),
    v_emp.site_id,
    p_employee_id,
    'ATTENDANCE_MONTH_EMPLOYEE_CONFIRMED',
    jsonb_build_object('year', p_year, 'month', p_month, 'report_id', v_id)
  );

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.confirm_attendance_month(uuid, int, int) TO authenticated;

-- A7: signatura només si el mes passa validació A2 i està tancat per nòmina.
CREATE OR REPLACE FUNCTION api.link_attendance_monthly_report_signing(
  p_employee_id             uuid,
  p_year                    int,
  p_month                   int,
  p_document_id             uuid,
  p_signing_submission_id   uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp    record;
  v_id     uuid;
  v_check  jsonb;
  v_status text;
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

  SELECT amr.status INTO v_status
  FROM data.attendance_monthly_reports amr
  WHERE amr.employee_id = p_employee_id
    AND amr.year = p_year
    AND amr.month = p_month;

  IF v_status IS DISTINCT FROM 'manager_approved' THEN
    RAISE EXCEPTION 'report_not_ready_for_signing'
      USING ERRCODE = 'check_violation',
            DETAIL = 'status_must_be_manager_approved';
  END IF;

  v_check := api.validate_attendance_month_close(p_employee_id, p_year, p_month);
  IF NOT COALESCE((v_check->>'closable')::boolean, false) THEN
    RAISE EXCEPTION 'month_not_closable'
      USING ERRCODE = 'check_violation',
            DETAIL = v_check::text;
  END IF;

  UPDATE data.attendance_monthly_reports amr
  SET
    document_id           = p_document_id,
    signing_submission_id = p_signing_submission_id,
    updated_at            = now()
  WHERE amr.employee_id = p_employee_id
    AND amr.year = p_year
    AND amr.month = p_month
    AND amr.status = 'manager_approved'
  RETURNING amr.id INTO v_id;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'report_not_ready_for_signing';
  END IF;

  PERFORM data.log_attendance_employee_audit(
    v_emp.tenant_id,
    auth.uid(),
    v_emp.site_id,
    p_employee_id,
    'ATTENDANCE_MONTH_SIGNING_STARTED',
    jsonb_build_object(
      'year', p_year,
      'month', p_month,
      'report_id', v_id,
      'document_id', p_document_id,
      'signing_submission_id', p_signing_submission_id
    )
  );

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.link_attendance_monthly_report_signing(uuid, int, int, uuid, uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
