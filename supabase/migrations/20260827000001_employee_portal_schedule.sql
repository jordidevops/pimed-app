-- EP6: schedule read-only per al portal d'empleats (service_role via Edge Function)

CREATE OR REPLACE FUNCTION api.employee_portal_get_schedule(
  p_employee_id uuid,
  p_tenant_id   uuid,
  p_from        date,
  p_to          date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp record;
  v_days jsonb := '[]'::jsonb;
  v_absences jsonb;
  d date;
  v_day jsonb;
BEGIN
  SELECT e.id, e.tenant_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND e.tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from THEN
    RAISE EXCEPTION 'invalid_date_range' USING ERRCODE = 'check_violation';
  END IF;

  IF (p_to - p_from) > 366 THEN
    RAISE EXCEPTION 'date_range_too_large' USING ERRCODE = 'check_violation';
  END IF;

  d := p_from;
  WHILE d <= p_to LOOP
    v_day := api.resolve_work_day(p_employee_id, d);
    v_day := v_day || jsonb_build_object('date', d);
    v_days := v_days || jsonb_build_array(v_day);
    d := d + 1;
  END LOOP;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', ea.id,
        'start_date', ea.start_date,
        'end_date', ea.end_date,
        'status', ea.status,
        'absence_type', ea.absence_type
      )
      ORDER BY ea.start_date ASC, ea.created_at ASC
    ),
    '[]'::jsonb
  )
  INTO v_absences
  FROM data.employee_absences ea
  WHERE ea.employee_id = p_employee_id
    AND ea.end_date >= p_from
    AND ea.start_date <= p_to;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'tenant_id', p_tenant_id,
    'from', p_from,
    'to', p_to,
    'days', v_days,
    'absences', v_absences
  );
END;
$$;

REVOKE ALL ON FUNCTION api.employee_portal_get_schedule(uuid, uuid, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_portal_get_schedule(uuid, uuid, date, date) TO service_role;

NOTIFY pgrst, 'reload schema';
