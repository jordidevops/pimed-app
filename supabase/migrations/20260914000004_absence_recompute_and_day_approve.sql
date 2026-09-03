-- Absències: recompute en crear/auto-aprovar; aprovar dia amb absència sense resum encara.

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
  v_emp           record;
  v_type_cfg      record;
  v_absence_id    uuid;
  v_workflow      text;
  v_init_status   text := 'requested';
  v_d             date;
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
  END IF;

  RETURN jsonb_build_object(
    'absence_id',  v_absence_id,
    'status',      v_init_status,
    'employee_id', p_employee_id,
    'start_date',  p_start_date,
    'end_date',    p_end_date
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.approve_absence(
  p_absence_id     uuid,
  p_new_status     text,
  p_review_comment text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_abs    record;
  v_d      date;
BEGIN
  SELECT ea.*, e.tenant_id AS emp_tenant_id
  INTO v_abs
  FROM data.employee_absences ea
  JOIN data.employees e ON e.id = ea.employee_id
  WHERE ea.id = p_absence_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'absence_not_found: %', p_absence_id
      USING ERRCODE = 'P0002';
  END IF;

  IF auth.uid() IS NOT NULL
     AND NOT data.jwt_has_permission(v_abs.tenant_id, 'attendance.approve') THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.approve requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_new_status NOT IN ('approved', 'rejected', 'cancelled') THEN
    RAISE EXCEPTION 'invalid_status: % — valid: approved, rejected, cancelled', p_new_status
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_abs.status NOT IN ('requested', 'approved') THEN
    RAISE EXCEPTION 'absence_not_actionable: status actual = %', v_abs.status
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_new_status = 'approved' THEN
    IF EXISTS (
      SELECT 1 FROM data.employee_absences
      WHERE employee_id = v_abs.employee_id
        AND id          != p_absence_id
        AND status       = 'approved'
        AND start_date  <= v_abs.end_date
        AND end_date    >= v_abs.start_date
    ) THEN
      RAISE EXCEPTION 'absence_overlap: ja existeix una absència aprovada que se solapa amb el període indicat'
        USING ERRCODE = 'exclusion_violation';
    END IF;
  END IF;

  UPDATE data.employee_absences
  SET status         = p_new_status,
      reviewed_by    = auth.uid(),
      reviewed_at    = now(),
      review_comment = p_review_comment,
      updated_at     = now()
  WHERE id = p_absence_id;

  IF p_new_status IN ('approved', 'rejected', 'cancelled') THEN
    v_d := v_abs.start_date;
    WHILE v_d <= v_abs.end_date LOOP
      PERFORM pgmq.send(
        'attendance_recompute_queue',
        jsonb_build_object(
          'task',            'recompute_attendance_day',
          'tenant_id',       v_abs.tenant_id,
          'employee_id',     v_abs.employee_id,
          'work_date',       v_d::text,
          'idempotency_key', 'recompute-' || v_abs.employee_id::text
                             || '-' || v_d::text || '-abs-' || p_absence_id::text
                             || '-' || p_new_status
        )
      );
      v_d := v_d + 1;
    END LOOP;
  END IF;

  IF p_new_status = 'approved' THEN
    PERFORM data.log_attendance_employee_audit(
      v_abs.tenant_id, auth.uid(), v_abs.site_id, v_abs.employee_id,
      'ATTENDANCE_ABSENCE_APPROVED',
      jsonb_build_object(
        'absence_id', p_absence_id, 'absence_type', v_abs.absence_type,
        'start_date', v_abs.start_date, 'end_date', v_abs.end_date
      )
    );
  ELSIF p_new_status = 'rejected' THEN
    PERFORM data.log_attendance_employee_audit(
      v_abs.tenant_id, auth.uid(), v_abs.site_id, v_abs.employee_id,
      'ATTENDANCE_ABSENCE_REJECTED',
      jsonb_build_object(
        'absence_id', p_absence_id, 'absence_type', v_abs.absence_type,
        'start_date', v_abs.start_date, 'end_date', v_abs.end_date,
        'review_comment', p_review_comment
      )
    );
  ELSIF p_new_status = 'cancelled' THEN
    PERFORM data.log_attendance_employee_audit(
      v_abs.tenant_id, auth.uid(), v_abs.site_id, v_abs.employee_id,
      'ATTENDANCE_ABSENCE_CANCELLED',
      jsonb_build_object(
        'absence_id', p_absence_id, 'absence_type', v_abs.absence_type,
        'start_date', v_abs.start_date, 'end_date', v_abs.end_date,
        'review_comment', p_review_comment
      )
    );
  END IF;

  RETURN jsonb_build_object('absence_id', p_absence_id, 'status', p_new_status);
END;
$$;

CREATE OR REPLACE FUNCTION api.approve_time_day(
  p_employee_id uuid,
  p_work_date   date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant_id  uuid;
  v_site_id    uuid;
  v_summary_id uuid;
  v_status     text;
  v_locked_at  timestamptz;
  v_has_absence boolean;
BEGIN
  SELECT e.tenant_id, e.site_id INTO v_tenant_id, v_site_id
  FROM data.employees e WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id;
  END IF;

  IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.approve') THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.approve required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT id, status, payroll_locked_at
    INTO v_summary_id, v_status, v_locked_at
  FROM data.time_daily_summaries
  WHERE employee_id = p_employee_id AND work_date = p_work_date;

  IF NOT FOUND THEN
    SELECT EXISTS (
      SELECT 1
      FROM data.employee_absences ea
      WHERE ea.employee_id = p_employee_id
        AND ea.start_date <= p_work_date
        AND ea.end_date >= p_work_date
        AND ea.status IN ('approved', 'active', 'closed')
    ) INTO v_has_absence;

    IF NOT v_has_absence THEN
      RAISE EXCEPTION 'summary_not_found: employee %, date %', p_employee_id, p_work_date;
    END IF;

    INSERT INTO data.time_daily_summaries (
      tenant_id, site_id, employee_id, work_date,
      worked_minutes, break_minutes, punch_count, status
    )
    VALUES (
      v_tenant_id, v_site_id, p_employee_id, p_work_date,
      0, 0, 0, 'draft'
    )
    RETURNING id, status, payroll_locked_at
    INTO v_summary_id, v_status, v_locked_at;
  END IF;

  IF v_locked_at IS NOT NULL THEN
    RAISE EXCEPTION 'day_payroll_locked: cannot approve after export on %', p_work_date
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_status = 'approved' THEN
    RETURN jsonb_build_object('summary_id', v_summary_id, 'status', 'already_approved');
  END IF;

  UPDATE data.time_daily_summaries
  SET status       = 'approved',
      approved_by  = auth.uid(),
      approved_at  = now(),
      needs_review = false,
      updated_at   = now()
  WHERE id = v_summary_id;

  RETURN jsonb_build_object('summary_id', v_summary_id, 'status', 'approved');
END;
$$;

NOTIFY pgrst, 'reload schema';
