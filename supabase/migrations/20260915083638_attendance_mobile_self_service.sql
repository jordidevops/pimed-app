-- Mobile attendance self-service: shared reason policy, employee withdrawal,
-- manager revocation, and least-privilege vacation balance.

ALTER TABLE data.employee_absences
  DROP CONSTRAINT IF EXISTS employee_absences_status_check;

ALTER TABLE data.employee_absences
  ADD CONSTRAINT employee_absences_status_check
  CHECK (status IN (
    'requested', 'approved', 'rejected', 'cancelled', 'revoked', 'active', 'closed'
  ));

CREATE OR REPLACE FUNCTION data.enforce_absence_request_reason()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pg_temp
AS $$
DECLARE
  v_parent_key text;
BEGIN
  SELECT cfg.parent_key
  INTO v_parent_key
  FROM data.tenant_absence_type_configs cfg
  WHERE cfg.absence_type = NEW.absence_type
    AND cfg.is_active = true
    AND (
      cfg.tenant_id = NEW.tenant_id
      OR (cfg.tenant_id IS NULL AND cfg.is_system = true)
    )
  ORDER BY (cfg.tenant_id IS NOT NULL) DESC
  LIMIT 1;

  IF v_parent_key = 'permission' AND NULLIF(btrim(NEW.notes), '') IS NULL THEN
    RAISE EXCEPTION 'absence_reason_required: cal indicar el motiu del permís'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION data.enforce_absence_request_reason() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_employee_absences_reason ON data.employee_absences;
CREATE TRIGGER trg_employee_absences_reason
BEFORE INSERT OR UPDATE OF absence_type, notes
ON data.employee_absences
FOR EACH ROW
EXECUTE FUNCTION data.enforce_absence_request_reason();

CREATE OR REPLACE FUNCTION api.cancel_my_absence(
  p_absence_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, pg_temp
AS $$
DECLARE
  v_abs data.employee_absences%ROWTYPE;
  v_employee_user_id uuid;
BEGIN
  SELECT a.*
  INTO v_abs
  FROM data.employee_absences a
  WHERE a.id = p_absence_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'absence_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT e.user_id
  INTO v_employee_user_id
  FROM data.employees e
  WHERE e.id = v_abs.employee_id;

  IF auth.uid() IS NULL OR v_employee_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'insufficient_privilege: només el titular pot retirar la sol·licitud'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT COALESCE(
    data.jwt_has_permission(v_abs.tenant_id, 'absences.request', v_abs.site_id),
    false
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege: absences.request requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_abs.status <> 'requested' THEN
    RAISE EXCEPTION 'invalid_status: només es poden retirar sol·licituds pendents'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  UPDATE data.employee_absences
  SET status = 'cancelled',
      review_comment = NULLIF(btrim(p_reason), ''),
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      updated_at = now()
  WHERE id = p_absence_id;

  RETURN jsonb_build_object('absence_id', p_absence_id, 'status', 'cancelled');
END;
$$;

REVOKE ALL ON FUNCTION api.cancel_my_absence(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.cancel_my_absence(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION api.revoke_absence(
  p_absence_id uuid,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, pg_temp
AS $$
DECLARE
  v_abs data.employee_absences%ROWTYPE;
  v_day date;
BEGIN
  SELECT *
  INTO v_abs
  FROM data.employee_absences
  WHERE id = p_absence_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'absence_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT COALESCE(
    data.jwt_has_permission(v_abs.tenant_id, 'attendance.approve', v_abs.site_id),
    false
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.approve requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_abs.status <> 'approved' THEN
    RAISE EXCEPTION 'invalid_status: només es poden revocar absències aprovades'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF NULLIF(btrim(p_reason), '') IS NULL THEN
    RAISE EXCEPTION 'revoke_reason_required'
      USING ERRCODE = 'check_violation';
  END IF;

  UPDATE data.employee_absences
  SET status = 'revoked',
      review_comment = btrim(p_reason),
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      updated_at = now()
  WHERE id = p_absence_id;

  v_day := v_abs.start_date;
  WHILE v_day <= COALESCE(v_abs.end_date, v_abs.start_date) LOOP
    PERFORM pgmq.send(
      'attendance_recompute_queue',
      jsonb_build_object(
        'task', 'recompute_attendance_day',
        'tenant_id', v_abs.tenant_id,
        'employee_id', v_abs.employee_id,
        'work_date', v_day::text,
        'idempotency_key',
          'recompute-' || v_abs.employee_id::text || '-' || v_day::text
          || '-absence-revoke-' || p_absence_id::text
      )
    );
    v_day := v_day + 1;
  END LOOP;

  RETURN jsonb_build_object('absence_id', p_absence_id, 'status', 'revoked');
END;
$$;

REVOKE ALL ON FUNCTION api.revoke_absence(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.revoke_absence(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION api.get_vacation_entitlement(
  p_employee_id uuid,
  p_year int,
  p_leave_type text DEFAULT 'vacation'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, pg_temp
AS $$
DECLARE
  v_emp record;
  v_ent record;
BEGIN
  SELECT e.tenant_id, e.department_id, e.site_id, e.user_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND e.status = 'active';

  IF NOT FOUND THEN
    RETURN jsonb_build_object('found', false);
  END IF;

  IF auth.uid() IS NULL OR (
    v_emp.user_id IS DISTINCT FROM auth.uid()
    AND NOT COALESCE(
      data.jwt_has_permission(v_emp.tenant_id, 'attendance.approve', v_emp.site_id),
      false
    )
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege: saldo de vacances no autoritzat'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT *
  INTO v_ent
  FROM data.vacation_entitlements ve
  WHERE ve.tenant_id = v_emp.tenant_id
    AND ve.year = p_year
    AND ve.leave_type = p_leave_type
    AND (
      (ve.scope = 'employee' AND ve.employee_id = p_employee_id)
      OR (ve.scope = 'department' AND ve.department_id = v_emp.department_id)
      OR ve.scope = 'tenant'
    )
  ORDER BY CASE ve.scope
    WHEN 'employee' THEN 1
    WHEN 'department' THEN 2
    ELSE 3
  END
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'found', false,
      'days_allocated', 0,
      'days_used', 0,
      'days_remaining', 0
    );
  END IF;

  RETURN jsonb_build_object(
    'found', true,
    'id', v_ent.id,
    'scope', v_ent.scope,
    'days_allocated', v_ent.days_allocated,
    'days_used', v_ent.days_used,
    'days_remaining', GREATEST(0, v_ent.days_allocated - v_ent.days_used)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_vacation_entitlement(uuid, int, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_vacation_entitlement(uuid, int, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
