-- E6: auto-assistència aprovació — política de confiança per «horari previst real»

INSERT INTO data.settings_registry
  (setting_key, scope, required_permission, owner_only, is_active, description)
VALUES
  (
    'attendance_trust_schedule_hours_claim',
    'tenant',
    'settings.manage',
    false,
    true,
    'Suggerir aprovació ràpida quan l''empleat declara haver seguit l''horari previst (E6)'
  )
ON CONFLICT (setting_key) DO UPDATE SET
  scope = EXCLUDED.scope,
  description = EXCLUDED.description,
  updated_at = now();

INSERT INTO data.system_settings (module, settings)
VALUES ('defaults', '{"attendance_trust_schedule_hours_claim": false}'::jsonb)
ON CONFLICT (module) DO UPDATE
  SET settings = data.system_settings.settings || EXCLUDED.settings,
      updated_at = now();

-- Aprovar un dia neteja needs_review (el gestor ha revisat)
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
  v_summary_id uuid;
  v_status     text;
  v_locked_at  timestamptz;
BEGIN
  SELECT e.tenant_id INTO v_tenant_id
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
    RAISE EXCEPTION 'summary_not_found: employee %, date %', p_employee_id, p_work_date;
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

GRANT EXECUTE ON FUNCTION api.approve_time_day(uuid, date) TO authenticated;

NOTIFY pgrst, 'reload schema';
