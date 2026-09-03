-- Gestor que registra absència: aprovació immediata (no flux sol·licitud pendent).
-- Tipus sistema «absència injustificada» per faltes detectades a posteriori.

INSERT INTO data.tenant_absence_type_configs (
  tenant_id, absence_type, name_i18n,
  counts_as_worked, affects_entitlement, entitlement_type,
  requires_approval, requires_document, max_days_per_year,
  is_it, is_partial, is_system, is_active, sort_order,
  parent_key, subtype_key, export_code
)
VALUES (
  NULL, 'unjustified_absence',
  '{"ca":"Absència injustificada","es":"Ausencia injustificada","en":"Unjustified absence"}',
  false, false, NULL,
  false, false, NULL,
  false, false, true, true, 5,
  'other', 'unjustified_absence', 'AIN'
)
ON CONFLICT (tenant_id, absence_type) DO UPDATE SET
  name_i18n         = EXCLUDED.name_i18n,
  counts_as_worked  = EXCLUDED.counts_as_worked,
  requires_approval = EXCLUDED.requires_approval,
  parent_key        = EXCLUDED.parent_key,
  subtype_key       = EXCLUDED.subtype_key,
  export_code       = EXCLUDED.export_code,
  is_active         = true;

CREATE OR REPLACE FUNCTION api.request_absence(
  p_employee_id   uuid,
  p_absence_type  text,
  p_start_date    date,
  p_end_date      date,
  p_hours_per_day numeric DEFAULT NULL,
  p_notes         text    DEFAULT NULL,
  p_partial_start_time time DEFAULT NULL,
  p_partial_end_time   time DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = api, data, public
AS $$
DECLARE
  v_emp                 record;
  v_type_cfg            record;
  v_absence_id          uuid;
  v_workflow            text;
  v_init_status         text := 'requested';
  v_is_manager_register boolean := false;
  v_d                   date;
BEGIN
  SELECT e.tenant_id, e.site_id, e.user_id INTO v_emp
  FROM data.employees e WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id USING ERRCODE = 'P0002';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF v_emp.user_id IS DISTINCT FROM auth.uid() THEN
      IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.approve') THEN
        RAISE EXCEPTION 'insufficient_privilege: attendance.approve requerit';
      END IF;
      v_is_manager_register := true;
    ELSE
      IF NOT data.jwt_has_permission(v_emp.tenant_id, 'absences.request') THEN
        RAISE EXCEPTION 'insufficient_privilege: absences.request requerit';
      END IF;
    END IF;
  END IF;

  SELECT DISTINCT ON (absence_type) *
  INTO v_type_cfg
  FROM data.tenant_absence_type_configs
  WHERE absence_type = p_absence_type
    AND is_active = true
    AND (tenant_id = v_emp.tenant_id OR (tenant_id IS NULL AND is_system = true))
  ORDER BY absence_type, (tenant_id IS NOT NULL) DESC;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid_absence_type: % no és un tipus d''absència actiu', p_absence_type
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_type_cfg.is_it THEN
    RAISE EXCEPTION 'use_register_it: les baixes IT s''han de registrar via api.register_it';
  END IF;

  IF p_end_date < p_start_date THEN
    RAISE EXCEPTION 'invalid_date_range: end_date ha de ser >= start_date';
  END IF;

  IF EXISTS (
    SELECT 1 FROM data.employee_absences
    WHERE employee_id = p_employee_id
      AND status IN ('approved','requested','active')
      AND start_date <= p_end_date
      AND end_date   >= p_start_date
  ) THEN
    RAISE EXCEPTION 'absence_overlap: ja existeix una absència que se solapa amb el període indicat'
      USING ERRCODE = 'exclusion_violation';
  END IF;

  IF v_is_manager_register THEN
    -- Gestor registra per l'empleat: no passa per «sol·licitud pendent».
    v_init_status := 'approved';
  ELSE
    SELECT COALESCE(
      (api.get_effective_settings(
        p_site_id   => v_emp.site_id,
        p_user_id   => NULL,
        p_tenant_id => v_emp.tenant_id
      ) ->> 'attendance_default_absence_workflow'),
      'require_approval'
    ) INTO v_workflow;

    IF v_workflow = 'auto_approve' OR NOT v_type_cfg.requires_approval THEN
      v_init_status := 'approved';
    END IF;
  END IF;

  INSERT INTO data.employee_absences (
    tenant_id, site_id, employee_id,
    absence_type, start_date, end_date,
    status, is_paid, hours_per_day, notes,
    partial_start_time, partial_end_time,
    counts_as_worked, affects_entitlement, entitlement_type,
    requested_by,
    reviewed_by, reviewed_at
  ) VALUES (
    v_emp.tenant_id, v_emp.site_id, p_employee_id,
    p_absence_type, p_start_date, p_end_date,
    v_init_status,
    v_type_cfg.counts_as_worked,
    p_hours_per_day, p_notes,
    p_partial_start_time, p_partial_end_time,
    v_type_cfg.counts_as_worked,
    v_type_cfg.affects_entitlement,
    v_type_cfg.entitlement_type,
    auth.uid(),
    CASE WHEN v_init_status = 'approved' THEN auth.uid() ELSE NULL END,
    CASE WHEN v_init_status = 'approved' THEN now()      ELSE NULL END
  )
  RETURNING id INTO v_absence_id;

  IF v_init_status = 'approved' THEN
    v_d := p_start_date;
    WHILE v_d <= p_end_date LOOP
      PERFORM pgmq.send(
        'attendance_recompute_queue',
        jsonb_build_object(
          'task',            'recompute_attendance_day',
          'tenant_id',       v_emp.tenant_id,
          'employee_id',     p_employee_id,
          'work_date',       v_d::text,
          'idempotency_key', 'recompute-' || p_employee_id::text
                             || '-' || v_d::text || '-abs-req-' || v_absence_id::text
        )
      );
      v_d := v_d + 1;
    END LOOP;

    IF v_is_manager_register THEN
      PERFORM data.log_attendance_employee_audit(
        v_emp.tenant_id, auth.uid(), v_emp.site_id, p_employee_id,
        'ATTENDANCE_ABSENCE_MANAGER_REGISTERED',
        jsonb_build_object(
          'absence_id', p_absence_id, 'absence_type', p_absence_type,
          'start_date', p_start_date, 'end_date', p_end_date,
          'notes', p_notes
        )
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'absence_id',  v_absence_id,
    'status',      v_init_status,
    'employee_id', p_employee_id,
    'start_date',  p_start_date,
    'end_date',    p_end_date,
    'manager_registered', v_is_manager_register
  );
END;
$$;

NOTIFY pgrst, 'reload schema';
