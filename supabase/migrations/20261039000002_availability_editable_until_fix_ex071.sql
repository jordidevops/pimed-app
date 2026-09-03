-- EX-07.1 fix: COALESCE jwt_has_permission (NULL no ha de saltar editable_until)
CREATE OR REPLACE FUNCTION api.upsert_employee_availability_rule(
  p_id             uuid DEFAULT NULL,
  p_employee_id    uuid DEFAULT NULL,
  p_day_of_week    smallint DEFAULT NULL,
  p_start_time     time DEFAULT NULL,
  p_end_time       time DEFAULT NULL,
  p_preference     text DEFAULT 'available',
  p_notes          text DEFAULT NULL,
  p_editable_until date DEFAULT NULL,
  p_effective_from date DEFAULT NULL,
  p_effective_to   date DEFAULT NULL,
  p_is_active      boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp record;
  v_row data.employee_availability_rules;
  v_is_manager boolean;
BEGIN
  IF p_id IS NOT NULL THEN
    SELECT * INTO v_row FROM data.employee_availability_rules WHERE id = p_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'rule_not_found' USING ERRCODE = 'P0002';
    END IF;
    SELECT e.* INTO v_emp FROM data.employees e WHERE e.id = v_row.employee_id;
  ELSE
    IF p_employee_id IS NULL OR p_day_of_week IS NULL OR p_start_time IS NULL OR p_end_time IS NULL THEN
      RAISE EXCEPTION 'employee_dow_times_required' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    SELECT e.* INTO v_emp FROM data.employees e WHERE e.id = p_employee_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  IF NOT data.can_manage_employee_availability(v_emp.tenant_id, v_emp.site_id, v_emp.id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_is_manager := COALESCE(
    data.jwt_has_permission(v_emp.tenant_id, 'labor_calendar.manage', v_emp.site_id),
    false
  );

  IF NOT v_is_manager AND v_row.id IS NOT NULL THEN
    IF v_row.editable_until IS NOT NULL AND CURRENT_DATE > v_row.editable_until THEN
      RAISE EXCEPTION 'editable_until_passed' USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  IF p_preference IS NOT NULL AND p_preference NOT IN ('preferred', 'available', 'unavailable') THEN
    RAISE EXCEPTION 'invalid_preference' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO data.employee_availability_rules (
      tenant_id, employee_id, day_of_week, start_time, end_time, preference,
      notes, editable_until, effective_from, effective_to, is_active
    ) VALUES (
      v_emp.tenant_id, v_emp.id, p_day_of_week, p_start_time, p_end_time,
      COALESCE(p_preference, 'available'),
      NULLIF(btrim(p_notes), ''),
      p_editable_until,
      COALESCE(p_effective_from, CURRENT_DATE),
      p_effective_to,
      COALESCE(p_is_active, true)
    )
    RETURNING * INTO v_row;
  ELSE
    UPDATE data.employee_availability_rules r SET
      day_of_week = COALESCE(p_day_of_week, r.day_of_week),
      start_time = COALESCE(p_start_time, r.start_time),
      end_time = COALESCE(p_end_time, r.end_time),
      preference = COALESCE(p_preference, r.preference),
      notes = CASE WHEN p_notes IS NULL THEN r.notes ELSE NULLIF(btrim(p_notes), '') END,
      editable_until = CASE WHEN v_is_manager THEN COALESCE(p_editable_until, r.editable_until) ELSE r.editable_until END,
      effective_from = COALESCE(p_effective_from, r.effective_from),
      effective_to = CASE WHEN p_effective_to IS NULL AND p_effective_from IS NULL THEN r.effective_to ELSE p_effective_to END,
      is_active = COALESCE(p_is_active, r.is_active),
      updated_at = now()
    WHERE r.id = p_id
    RETURNING * INTO v_row;
  END IF;

  RETURN to_jsonb(v_row);
END;
$$;

CREATE OR REPLACE FUNCTION api.deactivate_employee_availability_rule(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_row data.employee_availability_rules;
  v_emp record;
  v_is_manager boolean;
BEGIN
  SELECT * INTO v_row FROM data.employee_availability_rules WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'rule_not_found' USING ERRCODE = 'P0002';
  END IF;
  SELECT e.* INTO v_emp FROM data.employees e WHERE e.id = v_row.employee_id;

  IF NOT data.can_manage_employee_availability(v_emp.tenant_id, v_emp.site_id, v_emp.id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_is_manager := COALESCE(
    data.jwt_has_permission(v_emp.tenant_id, 'labor_calendar.manage', v_emp.site_id),
    false
  );
  IF NOT v_is_manager AND v_row.editable_until IS NOT NULL AND CURRENT_DATE > v_row.editable_until THEN
    RAISE EXCEPTION 'editable_until_passed' USING ERRCODE = 'check_violation';
  END IF;

  UPDATE data.employee_availability_rules
  SET is_active = false, updated_at = now()
  WHERE id = p_id
  RETURNING * INTO v_row;

  RETURN jsonb_build_object('id', v_row.id, 'is_active', false);
END;
$$;

CREATE OR REPLACE FUNCTION api.upsert_employee_availability_exception(
  p_id             uuid DEFAULT NULL,
  p_employee_id    uuid DEFAULT NULL,
  p_exception_date date DEFAULT NULL,
  p_start_time     time DEFAULT NULL,
  p_end_time       time DEFAULT NULL,
  p_preference     text DEFAULT 'unavailable',
  p_notes          text DEFAULT NULL,
  p_editable_until date DEFAULT NULL,
  p_is_active      boolean DEFAULT true,
  p_clear_times    boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp record;
  v_row data.employee_availability_exceptions;
  v_is_manager boolean;
  v_start time;
  v_end time;
BEGIN
  IF p_id IS NOT NULL THEN
    SELECT * INTO v_row FROM data.employee_availability_exceptions WHERE id = p_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'exception_not_found' USING ERRCODE = 'P0002';
    END IF;
    SELECT e.* INTO v_emp FROM data.employees e WHERE e.id = v_row.employee_id;
  ELSE
    IF p_employee_id IS NULL OR p_exception_date IS NULL THEN
      RAISE EXCEPTION 'employee_and_date_required' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    SELECT e.* INTO v_emp FROM data.employees e WHERE e.id = p_employee_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  IF NOT data.can_manage_employee_availability(v_emp.tenant_id, v_emp.site_id, v_emp.id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_is_manager := COALESCE(
    data.jwt_has_permission(v_emp.tenant_id, 'labor_calendar.manage', v_emp.site_id),
    false
  );
  IF NOT v_is_manager AND v_row.id IS NOT NULL THEN
    IF v_row.editable_until IS NOT NULL AND CURRENT_DATE > v_row.editable_until THEN
      RAISE EXCEPTION 'editable_until_passed' USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  IF p_preference IS NOT NULL AND p_preference NOT IN ('preferred', 'available', 'unavailable') THEN
    RAISE EXCEPTION 'invalid_preference' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_clear_times THEN
    v_start := NULL;
    v_end := NULL;
  ELSE
    v_start := p_start_time;
    v_end := p_end_time;
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO data.employee_availability_exceptions (
      tenant_id, employee_id, exception_date, start_time, end_time,
      preference, notes, editable_until, is_active
    ) VALUES (
      v_emp.tenant_id, v_emp.id, p_exception_date, v_start, v_end,
      COALESCE(p_preference, 'unavailable'),
      NULLIF(btrim(p_notes), ''),
      p_editable_until,
      COALESCE(p_is_active, true)
    )
    RETURNING * INTO v_row;
  ELSE
    UPDATE data.employee_availability_exceptions x SET
      exception_date = COALESCE(p_exception_date, x.exception_date),
      start_time = CASE
        WHEN p_clear_times THEN NULL
        WHEN p_start_time IS NOT NULL THEN p_start_time
        ELSE x.start_time
      END,
      end_time = CASE
        WHEN p_clear_times THEN NULL
        WHEN p_end_time IS NOT NULL THEN p_end_time
        ELSE x.end_time
      END,
      preference = COALESCE(p_preference, x.preference),
      notes = CASE WHEN p_notes IS NULL THEN x.notes ELSE NULLIF(btrim(p_notes), '') END,
      editable_until = CASE WHEN v_is_manager THEN COALESCE(p_editable_until, x.editable_until) ELSE x.editable_until END,
      is_active = COALESCE(p_is_active, x.is_active),
      updated_at = now()
    WHERE x.id = p_id
    RETURNING * INTO v_row;
  END IF;

  RETURN to_jsonb(v_row);
END;
$$;

CREATE OR REPLACE FUNCTION api.deactivate_employee_availability_exception(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_row data.employee_availability_exceptions;
  v_emp record;
  v_is_manager boolean;
BEGIN
  SELECT * INTO v_row FROM data.employee_availability_exceptions WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exception_not_found' USING ERRCODE = 'P0002';
  END IF;
  SELECT e.* INTO v_emp FROM data.employees e WHERE e.id = v_row.employee_id;

  IF NOT data.can_manage_employee_availability(v_emp.tenant_id, v_emp.site_id, v_emp.id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_is_manager := COALESCE(
    data.jwt_has_permission(v_emp.tenant_id, 'labor_calendar.manage', v_emp.site_id),
    false
  );
  IF NOT v_is_manager AND v_row.editable_until IS NOT NULL AND CURRENT_DATE > v_row.editable_until THEN
    RAISE EXCEPTION 'editable_until_passed' USING ERRCODE = 'check_violation';
  END IF;

  UPDATE data.employee_availability_exceptions
  SET is_active = false, updated_at = now()
  WHERE id = p_id
  RETURNING * INTO v_row;

  RETURN jsonb_build_object('id', v_row.id, 'is_active', false);
END;
$$;

NOTIFY pgrst, 'reload schema';
