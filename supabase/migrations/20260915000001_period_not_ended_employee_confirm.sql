-- Fase 0 (plan-period-employee-confirm): PERIOD_NOT_ENDED estricte per confirmació empleat.
-- Només confirmable quan period_to < avui (Europe/Madrid), incl. últim dia del mes encara en curs.

CREATE OR REPLACE FUNCTION api.validate_attendance_period_employee_confirm(
  p_employee_id uuid,
  p_period_from date,
  p_period_to   date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp          record;
  v_today        date := (now() AT TIME ZONE 'Europe/Madrid')::date;
  v_blockers     jsonb := '[]'::jsonb;
  v_open_dates   date[];
BEGIN
  IF p_period_from IS NULL OR p_period_to IS NULL OR p_period_from > p_period_to THEN
    RAISE EXCEPTION 'invalid_period_range';
  END IF;

  SELECT e.id, e.tenant_id, e.site_id, e.user_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF NOT (
      data.jwt_has_permission(v_emp.tenant_id, 'attendance.approve', v_emp.site_id)
      OR data.jwt_has_permission(v_emp.tenant_id, 'attendance.view_all', v_emp.site_id)
      OR v_emp.user_id = auth.uid()
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege';
    END IF;
  END IF;

  IF p_period_to >= v_today THEN
    v_blockers := v_blockers || jsonb_build_array(
      jsonb_build_object(
        'code', 'PERIOD_NOT_ENDED',
        'period_from', p_period_from,
        'period_to', p_period_to,
        'today', v_today
      )
    );
  END IF;

  SELECT COALESCE(array_agg(te.work_date ORDER BY te.work_date), '{}')
  INTO v_open_dates
  FROM data.time_entries te
  WHERE te.employee_id = p_employee_id
    AND te.work_date BETWEEN p_period_from AND p_period_to
    AND te.status = 'open';

  IF cardinality(v_open_dates) > 0 THEN
    v_blockers := v_blockers || jsonb_build_array(
      jsonb_build_object(
        'code', 'OPEN_TIME_ENTRY',
        'count', cardinality(v_open_dates),
        'work_dates', to_jsonb(v_open_dates)
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'confirmable', jsonb_array_length(v_blockers) = 0,
    'blockers', v_blockers,
    'period', jsonb_build_object('from', p_period_from, 'to', p_period_to)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.validate_attendance_period_employee_confirm(uuid, date, date) TO authenticated;

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
  v_from date;
  v_to   date;
BEGIN
  IF p_month < 1 OR p_month > 12 THEN
    RAISE EXCEPTION 'invalid_month';
  END IF;

  v_from := make_date(p_year, p_month, 1);
  v_to   := (v_from + interval '1 month' - interval '1 day')::date;

  RETURN api.validate_attendance_period_employee_confirm(p_employee_id, v_from, v_to);
END;
$$;

COMMENT ON FUNCTION api.validate_attendance_period_employee_confirm IS
  'Validació confirmació empleat per rang de dates. Bloqueja PERIOD_NOT_ENDED si period_to >= avui (Madrid).';

COMMENT ON FUNCTION api.validate_attendance_month_employee_confirm IS
  'Wrapper mensual natural → validate_attendance_period_employee_confirm.';

NOTIFY pgrst, 'reload schema';
