-- =============================================================================
-- EX-04.4 — Portal: llista de torns publicats de l'empleat
-- =============================================================================

ALTER TABLE data.employee_portal_access_logs
  DROP CONSTRAINT IF EXISTS employee_portal_access_logs_action_check;

ALTER TABLE data.employee_portal_access_logs
  ADD CONSTRAINT employee_portal_access_logs_action_check CHECK (action IN (
    'view_schedule',
    'view_my_shifts',
    'view_history',
    'view_monthly_report',
    'monthly_confirm',
    'period_confirm',
    'view_access_logs',
    'request_absence',
    'push_subscribe',
    'punch_in',
    'punch_out',
    'pause_start',
    'pause_end',
    'pin_failed',
    'pin_locked',
    'pin_setup',
    'pin_changed',
    'pin_reset',
    'batch_start',
    'batch_fetch',
    'batch_ack',
    'identity_verify_failed',
    'identity_rejected',
    'identity_confirmed',
    'token_invalid',
    'token_expired',
    'session_create',
    'session_refresh'
  ));

CREATE OR REPLACE FUNCTION api.employee_portal_get_my_shifts(
  p_employee_id uuid,
  p_tenant_id   uuid,
  p_from        date,
  p_to          date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp record;
  v_slots jsonb;
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

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', ss.id,
        'slot_date', ss.slot_date,
        'start_time', ss.start_time,
        'end_time', ss.end_time,
        'spans_midnight', (ss.end_time < ss.start_time),
        'status', ss.status,
        'shift_id', ss.shift_id,
        'shift_name', ws.name,
        'shift_color', ws.color,
        'site_id', ss.site_id,
        'location_id', ss.location_id,
        'location_name', ss.location_name_snapshot,
        'location_path', ss.location_path_snapshot,
        'publication_id', ss.publication_id,
        'published_at', ss.published_at,
        'notes', ss.notes
      )
      ORDER BY ss.slot_date ASC, ss.start_time ASC, ss.id ASC
    ),
    '[]'::jsonb
  )
  INTO v_slots
  FROM data.shift_slots ss
  JOIN data.work_shifts ws ON ws.id = ss.shift_id
  WHERE ss.employee_id = p_employee_id
    AND ss.tenant_id = p_tenant_id
    AND ss.status = 'published'
    AND ss.slot_date BETWEEN p_from AND p_to;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'tenant_id', p_tenant_id,
    'from', p_from,
    'to', p_to,
    'slots', COALESCE(v_slots, '[]'::jsonb)
  );
END;
$$;

COMMENT ON FUNCTION api.employee_portal_get_my_shifts(uuid, uuid, date, date) IS
  'EX-04.4: torns published de l''empleat per al portal (service_role).';

REVOKE ALL ON FUNCTION api.employee_portal_get_my_shifts(uuid, uuid, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_portal_get_my_shifts(uuid, uuid, date, date) TO service_role;

NOTIFY pgrst, 'reload schema';
