-- Fase 3: portal empleat — validació i confirmació per període (setmana ISO).

CREATE OR REPLACE FUNCTION api.employee_portal_validate_period(
  p_employee_id uuid,
  p_tenant_id   uuid,
  p_period_from date,
  p_period_to   date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp record;
BEGIN
  SELECT e.id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND e.tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF p_period_from IS NULL OR p_period_to IS NULL OR p_period_from > p_period_to THEN
    RAISE EXCEPTION 'invalid_period_range' USING ERRCODE = 'check_violation';
  END IF;

  RETURN api.validate_attendance_period_employee_confirm(
    p_employee_id,
    p_period_from,
    p_period_to
  );
END;
$$;

REVOKE ALL ON FUNCTION api.employee_portal_validate_period(uuid, uuid, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_portal_validate_period(uuid, uuid, date, date) TO service_role;

CREATE OR REPLACE FUNCTION api.employee_portal_confirm_period_report(
  p_employee_id    uuid,
  p_tenant_id      uuid,
  p_period_from    date,
  p_period_to      date,
  p_calendar_year  int,
  p_calendar_month int
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp         record;
  v_settings    jsonb;
  v_require_sig boolean;
  v_confirmation_id uuid;
BEGIN
  SELECT e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND e.tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF p_period_from IS NULL OR p_period_to IS NULL OR p_period_from > p_period_to THEN
    RAISE EXCEPTION 'invalid_period_range' USING ERRCODE = 'check_violation';
  END IF;

  IF p_calendar_month < 1 OR p_calendar_month > 12 THEN
    RAISE EXCEPTION 'invalid_month' USING ERRCODE = 'check_violation';
  END IF;

  v_settings := data.merge_effective_settings_for_service(v_emp.tenant_id, v_emp.site_id);
  v_require_sig := COALESCE(
    (v_settings->>'attendance_monthly_require_digital_signature')::boolean,
    false
  );

  IF v_require_sig THEN
    RAISE EXCEPTION 'digital_signature_required'
      USING ERRCODE = 'check_violation';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM data.attendance_period_confirmations c
    WHERE c.employee_id = p_employee_id
      AND c.period_from = p_period_from
      AND c.period_to = p_period_to
  ) THEN
    RAISE EXCEPTION 'period_already_confirmed' USING ERRCODE = 'check_violation';
  END IF;

  v_confirmation_id := api.confirm_attendance_period(
    p_employee_id,
    p_period_from,
    p_period_to,
    'employee_portal',
    p_calendar_year,
    p_calendar_month,
    NULL
  );

  RETURN v_confirmation_id;
END;
$$;

REVOKE ALL ON FUNCTION api.employee_portal_confirm_period_report(uuid, uuid, date, date, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_portal_confirm_period_report(uuid, uuid, date, date, int, int) TO service_role;

NOTIFY pgrst, 'reload schema';
