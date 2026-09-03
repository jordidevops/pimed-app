-- G1b: extend employee portal today payload for mobile punch UI

CREATE OR REPLACE FUNCTION api.employee_portal_get_today(
  p_employee_id uuid,
  p_tenant_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp record;
  v_today date;
  v_punches jsonb;
  v_last record;
  v_status text;
  v_active_pause_type text;
  v_open_pause_since timestamptz;
  v_resolved jsonb;
  v_profile text;
  v_legacy boolean;
  v_day_state text := 'off';
  v_next_state text;
  v_punch record;
BEGIN
  SELECT e.id, e.tenant_id, e.status
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND e.tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  v_today := (now() AT TIME ZONE 'Europe/Madrid')::date;

  SELECT data.resolve_attendance_record_policy(p_employee_id, v_today)
  INTO v_resolved;

  v_profile := COALESCE(v_resolved->>'work_profile', 'fixed_site');
  v_legacy := data.policy_legacy_in_out_only(v_resolved->'policy', v_profile);

  SELECT COALESCE(jsonb_agg(row_to_json(p)::jsonb ORDER BY p.occurred_at ASC, p.id ASC), '[]'::jsonb)
  INTO v_punches
  FROM (
    SELECT
      tp.id,
      tp.punch_type,
      tp.occurred_at,
      tp.received_at,
      tp.anomaly_codes,
      tp.source,
      tp.pause_type,
      tp.is_remote
    FROM data.time_punches tp
    WHERE tp.employee_id = p_employee_id
      AND (tp.occurred_at AT TIME ZONE 'Europe/Madrid')::date = v_today
    ORDER BY tp.occurred_at ASC, tp.id ASC
  ) p;

  FOR v_punch IN
    SELECT punch_type
    FROM data.time_punches
    WHERE employee_id = p_employee_id
      AND (occurred_at AT TIME ZONE 'Europe/Madrid')::date = v_today
    ORDER BY occurred_at ASC, id ASC
  LOOP
    v_next_state := data.punch_day_state_after(v_day_state, v_punch.punch_type);
    IF v_next_state IS NULL THEN
      v_status := 'unknown';
      EXIT;
    END IF;
    v_day_state := v_next_state;
  END LOOP;

  SELECT punch_type, occurred_at, pause_type
  INTO v_last
  FROM data.time_punches
  WHERE employee_id = p_employee_id
    AND (occurred_at AT TIME ZONE 'Europe/Madrid')::date = v_today
  ORDER BY occurred_at DESC, id DESC
  LIMIT 1;

  IF v_status IS NULL THEN
    v_status := CASE v_day_state
      WHEN 'off' THEN 'outside'
      WHEN 'day' THEN
        CASE
          WHEN data.is_mobile_work_profile(v_profile) AND NOT v_legacy THEN 'on_day'
          ELSE 'outside'
        END
      WHEN 'work' THEN 'working'
      WHEN 'break' THEN 'on_pause'
      WHEN 'travel' THEN 'traveling'
      ELSE 'unknown'
    END;
  END IF;

  v_active_pause_type := NULL;
  v_open_pause_since := NULL;

  IF v_status = 'on_pause' AND v_last.punch_type IS NOT NULL THEN
    v_active_pause_type := v_last.pause_type;
    v_open_pause_since := v_last.occurred_at;
  END IF;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'tenant_id', p_tenant_id,
    'work_date', v_today,
    'punches', v_punches,
    'last_punch_type', v_last.punch_type,
    'last_punch_at', v_last.occurred_at,
    'current_status', v_status,
    'active_pause_type', v_active_pause_type,
    'open_pause_since', v_open_pause_since,
    'work_profile', v_profile,
    'legacy_in_out_only', v_legacy,
    'day_state', v_day_state
  );
END;
$$;

REVOKE ALL ON FUNCTION api.employee_portal_get_today(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_portal_get_today(uuid, uuid) TO service_role;
