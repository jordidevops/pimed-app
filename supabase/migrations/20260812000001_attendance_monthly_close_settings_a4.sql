-- A4: registre de settings de tancament mensual + bulk approve + signatura com a confirmació.

INSERT INTO data.settings_registry
  (setting_key, scope, required_permission, owner_only, is_active, description)
VALUES
  ('attendance_monthly_employee_confirm_required', 'tenant', 'settings.manage', false, true,
   'Requereix confirmació de l''empleat abans del tancament mensual per nòmina'),
  ('attendance_monthly_signature_is_employee_approval', 'tenant', 'settings.manage', false, true,
   'La signatura digital de l''empleat compta com a confirmació del registre mensual'),
  ('attendance_monthly_manager_can_close_without_employee', 'tenant', 'settings.manage', false, true,
   'Permet al gestor tancar el mes sense confirmació prèvia de l''empleat (amb advertència)'),
  ('attendance_monthly_require_digital_signature', 'tenant', 'settings.manage', false, true,
   'Signatura digital obligatòria després del tancament mensual'),
  ('attendance_monthly_bulk_approve_days_on_close', 'tenant', 'settings.manage', false, true,
   'En tancar el mes, marca els dies en esborrany com a aprovats en bloc')
ON CONFLICT (setting_key) DO UPDATE SET
  scope = EXCLUDED.scope,
  description = EXCLUDED.description,
  updated_at = now();

INSERT INTO data.system_settings (module, settings)
VALUES ('defaults', '{
  "attendance_monthly_employee_confirm_required": true,
  "attendance_monthly_signature_is_employee_approval": false,
  "attendance_monthly_manager_can_close_without_employee": true,
  "attendance_monthly_require_digital_signature": false,
  "attendance_monthly_bulk_approve_days_on_close": true
}'::jsonb)
ON CONFLICT (module) DO UPDATE
  SET settings = data.system_settings.settings || EXCLUDED.settings,
      updated_at = now();

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
  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.approve_attendance_month(uuid, int, int) TO authenticated;

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
      SELECT amr.id, amr.confirmed_at, amr.tenant_id, e.site_id, e.user_id AS employee_user_id
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
    END LOOP;
  END IF;
  RETURN NEW;
END;
$$;

NOTIFY pgrst, 'reload schema';
