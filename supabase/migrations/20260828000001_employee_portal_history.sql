-- EP7: historial de fitxatges per al portal d'empleats (service_role via Edge Function)

CREATE OR REPLACE FUNCTION api.employee_portal_get_history(
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
  v_entries jsonb;
  v_punches jsonb;
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

  IF (p_to - p_from) > 93 THEN
    RAISE EXCEPTION 'date_range_too_large' USING ERRCODE = 'check_violation';
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', te.id,
        'work_date', te.work_date,
        'starts_at', te.starts_at,
        'ends_at', te.ends_at,
        'net_minutes', te.net_minutes,
        'status', te.status
      )
      ORDER BY te.work_date DESC
    ),
    '[]'::jsonb
  )
  INTO v_entries
  FROM data.time_entries te
  WHERE te.employee_id = p_employee_id
    AND te.work_date >= p_from
    AND te.work_date <= p_to;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', tp.id,
        'punch_type', tp.punch_type,
        'occurred_at', tp.occurred_at,
        'source', tp.source
      )
      ORDER BY tp.occurred_at ASC, tp.id ASC
    ),
    '[]'::jsonb
  )
  INTO v_punches
  FROM data.time_punches tp
  WHERE tp.employee_id = p_employee_id
    AND (tp.occurred_at AT TIME ZONE 'Europe/Madrid')::date >= p_from
    AND (tp.occurred_at AT TIME ZONE 'Europe/Madrid')::date <= p_to;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'tenant_id', p_tenant_id,
    'from', p_from,
    'to', p_to,
    'entries', v_entries,
    'punches', v_punches
  );
END;
$$;

REVOKE ALL ON FUNCTION api.employee_portal_get_history(uuid, uuid, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_portal_get_history(uuid, uuid, date, date) TO service_role;

NOTIFY pgrst, 'reload schema';
