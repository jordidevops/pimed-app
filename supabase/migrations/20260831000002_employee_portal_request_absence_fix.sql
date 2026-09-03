-- Fix: CASE NULL inferia text a reviewed_by (uuid)

CREATE OR REPLACE FUNCTION api.employee_portal_request_absence(
  p_employee_id        uuid,
  p_tenant_id          uuid,
  p_absence_type       text,
  p_start_date         date,
  p_end_date           date,
  p_notes              text    DEFAULT NULL,
  p_partial_start_time time    DEFAULT NULL,
  p_partial_end_time   time    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp           record;
  v_type_cfg      record;
  v_absence_id    uuid;
  v_workflow      text;
  v_init_status   text := 'requested';
BEGIN
  SELECT e.tenant_id, e.site_id, e.id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND e.tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT DISTINCT ON (absence_type) *
  INTO v_type_cfg
  FROM data.tenant_absence_type_configs
  WHERE absence_type = p_absence_type
    AND is_active = true
    AND (tenant_id = v_emp.tenant_id OR (tenant_id IS NULL AND is_system = true))
  ORDER BY absence_type, (tenant_id IS NOT NULL) DESC;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid_absence_type: %', p_absence_type
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_type_cfg.is_it THEN
    RAISE EXCEPTION 'use_register_it: les baixes IT no es poden sol·licitar des del portal';
  END IF;

  IF p_end_date < p_start_date THEN
    RAISE EXCEPTION 'invalid_date_range: end_date ha de ser >= start_date';
  END IF;

  IF EXISTS (
    SELECT 1 FROM data.employee_absences
    WHERE employee_id = p_employee_id
      AND status IN ('approved', 'requested', 'active')
      AND start_date <= p_end_date
      AND end_date >= p_start_date
  ) THEN
    RAISE EXCEPTION 'absence_overlap: ja existeix una absència que se solapa'
      USING ERRCODE = 'exclusion_violation';
  END IF;

  SELECT COALESCE(
    (data.merge_effective_settings_for_service(v_emp.tenant_id, v_emp.site_id)
      ->> 'attendance_default_absence_workflow'),
    'require_approval'
  ) INTO v_workflow;

  IF v_workflow = 'auto_approve' OR NOT v_type_cfg.requires_approval THEN
    v_init_status := 'approved';
  END IF;

  INSERT INTO data.employee_absences (
    tenant_id, site_id, employee_id,
    absence_type, start_date, end_date,
    status, is_paid, notes,
    partial_start_time, partial_end_time,
    counts_as_worked, affects_entitlement, entitlement_type,
    requested_by,
    reviewed_by, reviewed_at
  ) VALUES (
    v_emp.tenant_id, v_emp.site_id, p_employee_id,
    p_absence_type, p_start_date, p_end_date,
    v_init_status,
    v_type_cfg.counts_as_worked,
    p_notes,
    p_partial_start_time, p_partial_end_time,
    v_type_cfg.counts_as_worked,
    v_type_cfg.affects_entitlement,
    v_type_cfg.entitlement_type,
    NULL::uuid,
    NULL::uuid,
    CASE WHEN v_init_status = 'approved' THEN now() ELSE NULL END
  )
  RETURNING id INTO v_absence_id;

  RETURN jsonb_build_object(
    'absence_id', v_absence_id,
    'status', v_init_status,
    'employee_id', p_employee_id,
    'start_date', p_start_date,
    'end_date', p_end_date
  );
END;
$$;

NOTIFY pgrst, 'reload schema';
