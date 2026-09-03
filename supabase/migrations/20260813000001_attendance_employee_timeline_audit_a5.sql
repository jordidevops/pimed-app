-- A5: esdeveniments de control horari a la timeline de l'empleat (Activitat).

CREATE OR REPLACE FUNCTION data.log_attendance_employee_audit(
  p_tenant_id   uuid,
  p_user_id     uuid,
  p_site_id     uuid,
  p_employee_id uuid,
  p_action      text,
  p_payload     jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF p_employee_id IS NULL OR p_tenant_id IS NULL THEN
    RETURN;
  END IF;

  PERFORM data.log_audit_event(
    p_tenant_id,
    p_user_id,
    p_site_id,
    p_action,
    'employee',
    p_employee_id,
    p_payload || jsonb_build_object('employee_id', p_employee_id),
    false
  );
END;
$$;

REVOKE ALL ON FUNCTION data.log_attendance_employee_audit(uuid, uuid, uuid, uuid, text, jsonb) FROM PUBLIC;

-- ── Confirmació empleat del registre mensual ──────────────────────────────────
CREATE OR REPLACE FUNCTION api.confirm_attendance_month(
  p_employee_id uuid, p_year int, p_month int
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = data, api
AS $$
DECLARE
  v_id  uuid;
  v_emp record;
BEGIN
  SELECT e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.user_id = auth.uid();

  IF v_emp.tenant_id IS NULL THEN
    RAISE EXCEPTION 'insufficient_privilege';
  END IF;

  INSERT INTO data.attendance_monthly_reports (tenant_id, employee_id, year, month, status, confirmed_by, confirmed_at)
  VALUES (v_emp.tenant_id, p_employee_id, p_year, p_month, 'employee_confirmed', auth.uid(), now())
  ON CONFLICT (employee_id, year, month) DO UPDATE SET
    status = 'employee_confirmed', confirmed_by = auth.uid(), confirmed_at = now(), updated_at = now()
  RETURNING id INTO v_id;

  PERFORM data.log_attendance_employee_audit(
    v_emp.tenant_id,
    auth.uid(),
    v_emp.site_id,
    p_employee_id,
    'ATTENDANCE_MONTH_EMPLOYEE_CONFIRMED',
    jsonb_build_object('year', p_year, 'month', p_month, 'report_id', v_id)
  );

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.confirm_attendance_month(uuid, int, int) TO authenticated;

-- ── Tancament mensual per nòmina (manager) ───────────────────────────────────
CREATE OR REPLACE FUNCTION api.approve_attendance_month(
  p_employee_id uuid, p_year int, p_month int
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = data, api
AS $$
DECLARE
  v_id                    uuid;
  v_emp                   record;
  v_check                 jsonb;
  v_settings              jsonb;
  v_require_confirm       boolean := true;
  v_can_close_without     boolean := true;
  v_bulk_approve          boolean := true;
  v_report_status         text;
  v_month_start           date;
  v_month_end             date;
BEGIN
  v_month_start := make_date(p_year, p_month, 1);
  v_month_end   := (v_month_start + interval '1 month' - interval '1 day')::date;

  SELECT * INTO v_emp FROM data.employees WHERE id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.approve', v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege';
  END IF;

  v_check := api.validate_attendance_month_close(p_employee_id, p_year, p_month);
  IF NOT COALESCE((v_check->>'closable')::boolean, false) THEN
    RAISE EXCEPTION 'month_not_closable'
      USING ERRCODE = 'check_violation',
            DETAIL = v_check::text;
  END IF;

  v_settings := api.get_effective_settings(
    p_site_id   => v_emp.site_id,
    p_tenant_id => v_emp.tenant_id
  );
  v_require_confirm := COALESCE(
    (v_settings->>'attendance_monthly_employee_confirm_required')::boolean,
    true
  );
  v_can_close_without := COALESCE(
    (v_settings->>'attendance_monthly_manager_can_close_without_employee')::boolean,
    true
  );
  v_bulk_approve := COALESCE(
    (v_settings->>'attendance_monthly_bulk_approve_days_on_close')::boolean,
    true
  );

  SELECT amr.status INTO v_report_status
  FROM data.attendance_monthly_reports amr
  WHERE amr.employee_id = p_employee_id
    AND amr.year = p_year
    AND amr.month = p_month;

  IF v_report_status IS NULL THEN
    v_report_status := 'draft';
  END IF;

  IF v_require_confirm
     AND NOT v_can_close_without
     AND v_report_status = 'draft' THEN
    RAISE EXCEPTION 'employee_confirmation_required'
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_bulk_approve THEN
    UPDATE data.time_daily_summaries tds
    SET
      status      = 'approved',
      approved_by = auth.uid(),
      approved_at = now(),
      updated_at  = now()
    WHERE tds.employee_id = p_employee_id
      AND tds.work_date BETWEEN v_month_start AND v_month_end
      AND tds.status = 'draft'
      AND tds.payroll_locked_at IS NULL;
  END IF;

  INSERT INTO data.attendance_monthly_reports (tenant_id, employee_id, year, month, status, approved_by, approved_at)
  VALUES (v_emp.tenant_id, p_employee_id, p_year, p_month, 'manager_approved', auth.uid(), now())
  ON CONFLICT (employee_id, year, month) DO UPDATE SET
    status = 'manager_approved', approved_by = auth.uid(), approved_at = now(), updated_at = now()
  RETURNING id INTO v_id;

  PERFORM data.log_attendance_employee_audit(
    v_emp.tenant_id,
    auth.uid(),
    v_emp.site_id,
    p_employee_id,
    'ATTENDANCE_MONTH_MANAGER_CLOSED',
    jsonb_build_object(
      'year', p_year,
      'month', p_month,
      'report_id', v_id,
      'previous_status', v_report_status,
      'bulk_approve_days', v_bulk_approve
    )
  );

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.approve_attendance_month(uuid, int, int) TO authenticated;

-- ── Inici signatura mensual ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION api.link_attendance_monthly_report_signing(
  p_employee_id             uuid,
  p_year                    int,
  p_month                   int,
  p_document_id             uuid,
  p_signing_submission_id   uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp   record;
  v_id    uuid;
BEGIN
  SELECT e.tenant_id, e.site_id INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.approve', v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege';
  END IF;

  IF p_month < 1 OR p_month > 12 THEN
    RAISE EXCEPTION 'invalid_month';
  END IF;

  UPDATE data.attendance_monthly_reports amr
  SET
    document_id           = p_document_id,
    signing_submission_id = p_signing_submission_id,
    updated_at            = now()
  WHERE amr.employee_id = p_employee_id
    AND amr.year = p_year
    AND amr.month = p_month
    AND amr.status IN ('employee_confirmed', 'manager_approved', 'signed')
  RETURNING amr.id INTO v_id;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'report_not_ready_for_signing';
  END IF;

  PERFORM data.log_attendance_employee_audit(
    v_emp.tenant_id,
    auth.uid(),
    v_emp.site_id,
    p_employee_id,
    'ATTENDANCE_MONTH_SIGNING_STARTED',
    jsonb_build_object(
      'year', p_year,
      'month', p_month,
      'report_id', v_id,
      'document_id', p_document_id,
      'signing_submission_id', p_signing_submission_id
    )
  );

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.link_attendance_monthly_report_signing(uuid, int, int, uuid, uuid) TO authenticated;

-- ── Signatura completada ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION data.trg_mark_attendance_monthly_report_signed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_report   record;
  v_settings jsonb;
  v_sig_ok   boolean := false;
BEGIN
  IF NEW.status = 'completed' AND (OLD.status IS DISTINCT FROM 'completed') THEN
    FOR v_report IN
      SELECT
        amr.id,
        amr.employee_id,
        amr.year,
        amr.month,
        amr.confirmed_at,
        amr.tenant_id,
        e.site_id,
        e.user_id AS employee_user_id
      FROM data.attendance_monthly_reports amr
      JOIN data.employees e ON e.id = amr.employee_id
      WHERE amr.status = 'manager_approved'
        AND (
          amr.signing_submission_id = NEW.id
          OR (amr.document_id IS NOT NULL AND amr.document_id = NEW.source_document_id)
        )
    LOOP
      v_settings := api.get_effective_settings(
        p_site_id   => v_report.site_id,
        p_tenant_id => v_report.tenant_id
      );
      v_sig_ok := COALESCE(
        (v_settings->>'attendance_monthly_signature_is_employee_approval')::boolean,
        false
      );

      UPDATE data.attendance_monthly_reports amr
      SET
        status       = 'signed',
        confirmed_by = CASE
          WHEN v_sig_ok AND amr.confirmed_at IS NULL AND v_report.employee_user_id IS NOT NULL
            THEN v_report.employee_user_id
          ELSE amr.confirmed_by
        END,
        confirmed_at = CASE
          WHEN v_sig_ok AND amr.confirmed_at IS NULL THEN now()
          ELSE amr.confirmed_at
        END,
        updated_at = now()
      WHERE amr.id = v_report.id;

      PERFORM data.log_attendance_employee_audit(
        v_report.tenant_id,
        coalesce(NEW.initiated_by, auth.uid()),
        v_report.site_id,
        v_report.employee_id,
        'ATTENDANCE_MONTH_SIGNED',
        jsonb_build_object(
          'year', v_report.year,
          'month', v_report.month,
          'report_id', v_report.id,
          'signing_submission_id', NEW.id,
          'signature_counts_as_employee_confirm', v_sig_ok
        )
      );
    END LOOP;
  END IF;
  RETURN NEW;
END;
$$;

-- ── Aprovació / rebuig absència ───────────────────────────────────────────────
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

  IF p_new_status = 'approved' THEN
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
        )
      );
      v_d := v_d + 1;
    END LOOP;

    PERFORM data.log_attendance_employee_audit(
      v_abs.tenant_id,
      auth.uid(),
      v_abs.site_id,
      v_abs.employee_id,
      'ATTENDANCE_ABSENCE_APPROVED',
      jsonb_build_object(
        'absence_id', p_absence_id,
        'absence_type', v_abs.absence_type,
        'start_date', v_abs.start_date,
        'end_date', v_abs.end_date
      )
    );
  ELSIF p_new_status = 'rejected' THEN
    PERFORM data.log_attendance_employee_audit(
      v_abs.tenant_id,
      auth.uid(),
      v_abs.site_id,
      v_abs.employee_id,
      'ATTENDANCE_ABSENCE_REJECTED',
      jsonb_build_object(
        'absence_id', p_absence_id,
        'absence_type', v_abs.absence_type,
        'start_date', v_abs.start_date,
        'end_date', v_abs.end_date,
        'review_comment', p_review_comment
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'absence_id', p_absence_id,
    'status',     p_new_status
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.approve_absence(uuid, text, text) TO authenticated;

-- ── Registre IT ───────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION api.register_it(
  p_employee_id    uuid,
  p_absence_type   text,
  p_start_date     date,
  p_end_date       date    DEFAULT NULL,
  p_it_reference   text    DEFAULT NULL,
  p_notes          text    DEFAULT NULL,
  p_document_id    uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = api, data, public
AS $$
DECLARE
  v_emp           record;
  v_absence_id    uuid;
BEGIN
  SELECT e.tenant_id, e.site_id INTO v_emp
  FROM data.employees e WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id USING ERRCODE = 'P0002';
  END IF;

  IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.approve') THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.approve requerit';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.tenant_absence_type_configs
    WHERE (tenant_id = v_emp.tenant_id OR (tenant_id IS NULL AND is_system = true))
      AND absence_type = p_absence_type AND is_it = true
  ) THEN
    RAISE EXCEPTION 'invalid_it_type: % no és un tipus IT vàlid', p_absence_type;
  END IF;

  IF EXISTS (
    SELECT 1 FROM data.employee_absences
    WHERE employee_id = p_employee_id
      AND status IN ('requested','approved','active')
      AND start_date <= COALESCE(p_end_date, '9999-12-31')
      AND COALESCE(end_date, '9999-12-31') >= p_start_date
  ) THEN
    RAISE EXCEPTION 'absence_overlap: ja existeix una absència activa que se solapa amb el període indicat'
      USING ERRCODE = 'exclusion_violation';
  END IF;

  INSERT INTO data.employee_absences (
    tenant_id, site_id, employee_id,
    absence_type, start_date, end_date,
    status, is_paid, counts_as_worked, affects_entitlement,
    it_reference, it_start_confirmed,
    notes, document_id, requested_by,
    reviewed_by, reviewed_at
  ) VALUES (
    v_emp.tenant_id, v_emp.site_id, p_employee_id,
    p_absence_type,
    p_start_date,
    p_end_date,
    'active',
    false, false, false,
    p_it_reference,
    p_it_reference IS NOT NULL,
    p_notes, p_document_id,
    auth.uid(), auth.uid(), now()
  )
  RETURNING id INTO v_absence_id;

  PERFORM data.log_attendance_employee_audit(
    v_emp.tenant_id,
    auth.uid(),
    v_emp.site_id,
    p_employee_id,
    'ATTENDANCE_IT_REGISTERED',
    jsonb_build_object(
      'absence_id', v_absence_id,
      'absence_type', p_absence_type,
      'start_date', p_start_date,
      'end_date', p_end_date,
      'it_reference', p_it_reference
    )
  );

  RETURN jsonb_build_object(
    'absence_id',  v_absence_id,
    'employee_id', p_employee_id,
    'start_date',  p_start_date,
    'status',      'active'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.register_it TO authenticated;

-- ── Tancament IT ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION api.close_it(
  p_absence_id      uuid,
  p_end_date        date,
  p_it_reference    text    DEFAULT NULL,
  p_document_id     uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = api, data, public
AS $$
DECLARE
  v_abs   record;
BEGIN
  SELECT a.*, e.tenant_id AS emp_tenant_id
  INTO v_abs
  FROM data.employee_absences a
  JOIN data.employees e ON e.id = a.employee_id
  WHERE a.id = p_absence_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'absence_not_found: %', p_absence_id USING ERRCODE = 'P0002';
  END IF;

  IF NOT data.jwt_has_permission(v_abs.emp_tenant_id, 'attendance.approve') THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.approve requerit';
  END IF;

  IF NOT v_abs.is_it THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.tenant_absence_type_configs
      WHERE absence_type = v_abs.absence_type AND is_it = true
    ) THEN
      RAISE EXCEPTION 'not_an_it: % no és una IT', p_absence_id;
    END IF;
  END IF;

  IF v_abs.status != 'active' THEN
    RAISE EXCEPTION 'invalid_status: la IT ha d''estar en estat active per tancar-la (actual: %)', v_abs.status;
  END IF;

  IF p_end_date < v_abs.start_date THEN
    RAISE EXCEPTION 'invalid_date: end_date ha de ser >= start_date de la IT';
  END IF;

  UPDATE data.employee_absences SET
    end_date          = p_end_date,
    status            = 'closed',
    it_end_confirmed  = true,
    it_reference      = COALESCE(p_it_reference, it_reference),
    document_id       = COALESCE(p_document_id, document_id),
    reviewed_by       = auth.uid(),
    reviewed_at       = now()
  WHERE id = p_absence_id;

  PERFORM data.log_attendance_employee_audit(
    v_abs.tenant_id,
    auth.uid(),
    v_abs.site_id,
    v_abs.employee_id,
    'ATTENDANCE_IT_CLOSED',
    jsonb_build_object(
      'absence_id', p_absence_id,
      'absence_type', v_abs.absence_type,
      'start_date', v_abs.start_date,
      'end_date', p_end_date,
      'it_reference', COALESCE(p_it_reference, v_abs.it_reference)
    )
  );

  RETURN jsonb_build_object(
    'absence_id', p_absence_id,
    'end_date',   p_end_date,
    'status',     'closed'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.close_it TO authenticated;

-- Propaga payload d'assistència a message_vars per a la timeline UI.
CREATE OR REPLACE FUNCTION data.timeline_audit_message_vars(
  p_action  text,
  p_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  CASE p_action
    WHEN 'EMPLOYEE_CREATED' THEN
      RETURN jsonb_build_object('name', coalesce(p_payload ->> 'full_name', p_payload ->> 'name'));
    WHEN 'EMPLOYEE_UPDATED' THEN
      IF p_payload ? 'changes' THEN
        RETURN jsonb_build_object(
          'changes', p_payload -> 'changes',
          'change_count', jsonb_array_length(p_payload -> 'changes')
        );
      END IF;
      RETURN jsonb_build_object('changes', '[]'::jsonb, 'change_count', 0);
    WHEN 'EMPLOYEE_TERMINATED' THEN
      RETURN jsonb_build_object(
        'name', coalesce(p_payload ->> 'full_name', p_payload ->> 'name'),
        'ends_on', p_payload ->> 'ends_on'
      );
    WHEN 'CONTACT_CREATED', 'CONTACT_ARCHIVED', 'CONTACT_UNARCHIVED' THEN
      RETURN jsonb_build_object('name', coalesce(p_payload ->> 'display_name', p_payload ->> 'name'));
    WHEN 'CONTACT_UPDATED' THEN
      IF p_payload ? 'changes' THEN
        RETURN jsonb_build_object(
          'changes', p_payload -> 'changes',
          'change_count', jsonb_array_length(p_payload -> 'changes')
        );
      END IF;
      RETURN jsonb_build_object('changes', '[]'::jsonb, 'change_count', 0);
    WHEN 'COMMENT_TASK_RESOLVED' THEN
      RETURN jsonb_build_object(
        'task_preview', p_payload ->> 'task_preview',
        'resolver_id', p_payload ->> 'resolved_by'
      );
    WHEN 'PROJECT_STATUS_CHANGED' THEN
      RETURN jsonb_build_object(
        'old', coalesce(p_payload ->> 'old_status', p_payload #>> '{old,status}'),
        'new', coalesce(p_payload ->> 'new_status', p_payload #>> '{new,status}')
      );
    ELSE
      IF coalesce(p_action, '') LIKE 'ATTENDANCE\_%' ESCAPE '\' THEN
        RETURN coalesce(p_payload, '{}'::jsonb);
      END IF;
      RETURN jsonb_build_object('action', p_action);
  END CASE;
END;
$$;

NOTIFY pgrst, 'reload schema';
