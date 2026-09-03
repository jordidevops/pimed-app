-- P2: compute helper + batch period status + refactor single RPC.

CREATE OR REPLACE FUNCTION data.compute_month_period_status(
  p_cycle          text,
  p_year           int,
  p_month          int,
  p_month_from     date,
  p_month_to       date,
  p_confirmations  jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = data, public
AS $$
DECLARE
  v_weeks_required        int := 0;
  v_weeks_confirmed       int := 0;
  v_month_period_confirmed boolean := false;
  v_week                  record;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(COALESCE(p_confirmations, '[]'::jsonb)) elem
    WHERE (elem ->> 'period_from')::date = p_month_from
      AND (elem ->> 'period_to')::date = p_month_to
      AND elem ->> 'cycle_type' = 'calendar_month'
  ) INTO v_month_period_confirmed;

  IF p_cycle = 'iso_week' THEN
    FOR v_week IN
      SELECT w.period_from, w.period_to
      FROM data.list_calendar_month_iso_weeks(p_year, p_month) w
    LOOP
      v_weeks_required := v_weeks_required + 1;
      IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(COALESCE(p_confirmations, '[]'::jsonb)) elem
        WHERE (elem ->> 'period_from')::date = v_week.period_from
          AND (elem ->> 'period_to')::date = v_week.period_to
      ) THEN
        v_weeks_confirmed := v_weeks_confirmed + 1;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'cycle', p_cycle,
    'month_from', p_month_from,
    'month_to', p_month_to,
    'confirmations', COALESCE(p_confirmations, '[]'::jsonb),
    'weeks_required', v_weeks_required,
    'weeks_confirmed', v_weeks_confirmed,
    'month_period_confirmed', v_month_period_confirmed,
    'month_fully_confirmed', CASE
      WHEN p_cycle = 'calendar_month' THEN v_month_period_confirmed
      ELSE v_weeks_required > 0 AND v_weeks_confirmed = v_weeks_required
    END
  );
END;
$$;

REVOKE ALL ON FUNCTION data.compute_month_period_status(text, int, int, date, date, jsonb) FROM PUBLIC;

CREATE OR REPLACE FUNCTION api.get_attendance_month_period_status(
  p_employee_id uuid,
  p_year        int,
  p_month       int
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp           record;
  v_settings      jsonb;
  v_cycle         text;
  v_month_from    date;
  v_month_to      date;
  v_confirmations jsonb := '[]'::jsonb;
BEGIN
  IF p_month < 1 OR p_month > 12 THEN
    RAISE EXCEPTION 'invalid_month';
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
      data.jwt_has_permission(v_emp.tenant_id, 'attendance.view_all', v_emp.site_id)
      OR v_emp.user_id = auth.uid()
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege';
    END IF;
  END IF;

  v_month_from := make_date(p_year, p_month, 1);
  v_month_to   := (v_month_from + interval '1 month' - interval '1 day')::date;

  v_settings := data.merge_effective_settings_for_service(v_emp.tenant_id, v_emp.site_id);
  v_cycle := data.attendance_employee_confirm_cycle(v_settings);

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', c.id,
      'period_from', c.period_from,
      'period_to', c.period_to,
      'cycle_type', c.cycle_type,
      'calendar_year', c.calendar_year,
      'calendar_month', c.calendar_month,
      'confirmed_at', c.confirmed_at,
      'confirmed_via', c.confirmed_via
    )
    ORDER BY c.period_from
  ), '[]'::jsonb)
  INTO v_confirmations
  FROM data.attendance_period_confirmations c
  WHERE c.employee_id = p_employee_id
    AND c.calendar_year = p_year
    AND c.calendar_month = p_month;

  RETURN data.compute_month_period_status(
    v_cycle, p_year, p_month, v_month_from, v_month_to, v_confirmations
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_attendance_month_period_status(uuid, int, int) TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_attendance_month_period_status(uuid, int, int) TO service_role;

-- ── Batch: estat període per N empleats (1 query confirmacions + compute per empleat) ─

CREATE OR REPLACE FUNCTION api.get_attendance_month_period_status_batch(
  p_employee_ids uuid[],
  p_year         int,
  p_month        int
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_month_from      date;
  v_month_to        date;
  v_emp             record;
  v_settings        jsonb;
  v_cycle           text;
  v_confirmations   jsonb := '[]'::jsonb;
  v_status          jsonb;
  v_results         jsonb := '[]'::jsonb;
  v_settings_cache  jsonb := '{}'::jsonb;
  v_site_key        text;
BEGIN
  IF p_month < 1 OR p_month > 12 THEN
    RAISE EXCEPTION 'invalid_month';
  END IF;

  IF p_employee_ids IS NULL OR cardinality(p_employee_ids) = 0 THEN
    RETURN jsonb_build_object(
      'year', p_year,
      'month', p_month,
      'employees', '[]'::jsonb
    );
  END IF;

  v_month_from := make_date(p_year, p_month, 1);
  v_month_to   := (v_month_from + interval '1 month' - interval '1 day')::date;

  FOR v_emp IN
    SELECT e.id, e.tenant_id, e.site_id, e.user_id
    FROM data.employees e
    WHERE e.id = ANY(p_employee_ids)
    ORDER BY e.full_name NULLS LAST, e.id
  LOOP
    IF auth.uid() IS NOT NULL THEN
      IF NOT (
        data.jwt_has_permission(v_emp.tenant_id, 'attendance.view_all', v_emp.site_id)
        OR v_emp.user_id = auth.uid()
      ) THEN
        CONTINUE;
      END IF;
    END IF;

    v_site_key := v_emp.tenant_id::text || ':' || COALESCE(v_emp.site_id::text, '');
    IF v_settings_cache ? v_site_key THEN
      v_settings := v_settings_cache -> v_site_key;
    ELSE
      v_settings := data.merge_effective_settings_for_service(v_emp.tenant_id, v_emp.site_id);
      v_settings_cache := v_settings_cache || jsonb_build_object(v_site_key, v_settings);
    END IF;

    v_cycle := data.attendance_employee_confirm_cycle(v_settings);

    SELECT COALESCE(jsonb_agg(
      jsonb_build_object(
        'id', c.id,
        'period_from', c.period_from,
        'period_to', c.period_to,
        'cycle_type', c.cycle_type,
        'calendar_year', c.calendar_year,
        'calendar_month', c.calendar_month,
        'confirmed_at', c.confirmed_at,
        'confirmed_via', c.confirmed_via
      )
      ORDER BY c.period_from
    ), '[]'::jsonb)
    INTO v_confirmations
    FROM data.attendance_period_confirmations c
    WHERE c.employee_id = v_emp.id
      AND c.calendar_year = p_year
      AND c.calendar_month = p_month;

    v_status := data.compute_month_period_status(
      v_cycle, p_year, p_month, v_month_from, v_month_to, v_confirmations
    );

    v_results := v_results || jsonb_build_array(
      jsonb_build_object('employee_id', v_emp.id) || v_status
    );
  END LOOP;

  RETURN jsonb_build_object(
    'year', p_year,
    'month', p_month,
    'employees', v_results
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_attendance_month_period_status_batch(uuid[], int, int) TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_attendance_month_period_status_batch(uuid[], int, int) TO service_role;

COMMENT ON FUNCTION api.get_attendance_month_period_status_batch IS
  'Estat confirmació per període per a múltiples empleats (mateix mes legal). Omite empleats sense permís.';

NOTIFY pgrst, 'reload schema';
