-- Track C3.1 — Compensation ledger: list + manual movements (manager UI)

-- --- 1. List movements ---

CREATE OR REPLACE FUNCTION api.list_compensation_ledger(
  p_employee_id uuid,
  p_limit       int DEFAULT 50,
  p_offset      int DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp     record;
  v_balance int;
  v_rows    jsonb := '[]'::jsonb;
  v_rec     record;
  v_lim     int;
  v_off     int;
BEGIN
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

  v_lim := GREATEST(1, LEAST(COALESCE(p_limit, 50), 200));
  v_off := GREATEST(0, COALESCE(p_offset, 0));
  v_balance := data.get_compensation_balance_minutes(p_employee_id);

  FOR v_rec IN
    SELECT
      l.id,
      l.created_at,
      l.source_work_date,
      l.movement_type,
      l.source_type,
      l.minutes,
      l.is_credit,
      l.notes,
      u.raw_user_meta_data->>'full_name' AS created_by_name
    FROM data.time_compensation_ledger l
    LEFT JOIN auth.users u ON u.id = l.created_by
    WHERE l.employee_id = p_employee_id
    ORDER BY l.created_at DESC, l.id DESC
    LIMIT v_lim
    OFFSET v_off
  LOOP
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'id', v_rec.id,
      'created_at', v_rec.created_at,
      'source_work_date', v_rec.source_work_date,
      'movement_type', v_rec.movement_type,
      'source_type', v_rec.source_type,
      'minutes', v_rec.minutes,
      'is_credit', v_rec.is_credit,
      'signed_minutes', CASE WHEN v_rec.is_credit THEN v_rec.minutes ELSE -v_rec.minutes END,
      'notes', v_rec.notes,
      'created_by_name', v_rec.created_by_name
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'balance_minutes', v_balance,
    'movements', v_rows
  );
END;
$$;

-- --- 2. Record manual movement ---

CREATE OR REPLACE FUNCTION api.record_compensation_movement(
  p_employee_id       uuid,
  p_movement_type     text,
  p_minutes           int,
  p_source_type       text DEFAULT 'overtime',
  p_is_credit         boolean DEFAULT false,
  p_source_work_date  date DEFAULT NULL,
  p_notes             text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp     record;
  v_balance int;
  v_id      uuid;
  v_notes   text;
BEGIN
  IF p_minutes IS NULL OR p_minutes <= 0 THEN
    RAISE EXCEPTION 'invalid_minutes' USING ERRCODE = 'check_violation';
  END IF;

  IF p_movement_type NOT IN (
    'compensated_time_off', 'paid_payroll', 'manual_adjustment', 'accrued'
  ) THEN
    RAISE EXCEPTION 'invalid_movement_type' USING ERRCODE = 'check_violation';
  END IF;

  IF p_source_type NOT IN ('overtime', 'holiday_worked', 'manual') THEN
    RAISE EXCEPTION 'invalid_source_type' USING ERRCODE = 'check_violation';
  END IF;

  -- Manager-only manual paths (accrued/overtime is automatic on consolidation)
  IF p_movement_type = 'accrued' AND p_source_type <> 'holiday_worked' THEN
    RAISE EXCEPTION 'accrued_overtime_automatic_only' USING ERRCODE = 'check_violation';
  END IF;

  IF p_movement_type = 'accrued' AND p_source_work_date IS NULL THEN
    RAISE EXCEPTION 'source_work_date_required' USING ERRCODE = 'check_violation';
  END IF;

  IF p_movement_type IN ('compensated_time_off', 'paid_payroll') AND p_is_credit THEN
    RAISE EXCEPTION 'debit_movement_must_not_be_credit' USING ERRCODE = 'check_violation';
  END IF;

  IF p_movement_type IN ('compensated_time_off', 'paid_payroll') THEN
    p_is_credit := false;
  END IF;

  IF p_movement_type = 'accrued' THEN
    p_is_credit := true;
  END IF;

  SELECT e.id, e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.manage', v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege';
  END IF;

  IF NOT p_is_credit THEN
    v_balance := data.get_compensation_balance_minutes(p_employee_id);
    IF v_balance < p_minutes THEN
      RAISE EXCEPTION 'insufficient_compensation_balance'
        USING ERRCODE = 'check_violation',
              DETAIL = format('balance=%s requested=%s', v_balance, p_minutes);
    END IF;
  END IF;

  v_notes := NULLIF(trim(COALESCE(p_notes, '')), '');

  INSERT INTO data.time_compensation_ledger (
    tenant_id, employee_id, source_work_date,
    movement_type, source_type, minutes, is_credit,
    notes, created_by
  ) VALUES (
    v_emp.tenant_id, p_employee_id, p_source_work_date,
    p_movement_type, p_source_type, p_minutes, p_is_credit,
    v_notes, auth.uid()
  )
  RETURNING id INTO v_id;

  PERFORM data.log_attendance_employee_audit(
    v_emp.tenant_id, auth.uid(), v_emp.site_id, p_employee_id,
    'ATTENDANCE_COMPENSATION_RECORDED',
    jsonb_build_object(
      'ledger_id', v_id,
      'movement_type', p_movement_type,
      'source_type', p_source_type,
      'minutes', p_minutes,
      'is_credit', p_is_credit,
      'source_work_date', p_source_work_date,
      'notes', v_notes
    )
  );

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_compensation_ledger(uuid, int, int) TO authenticated;
GRANT EXECUTE ON FUNCTION api.record_compensation_movement(
  uuid, text, int, text, boolean, date, text
) TO authenticated;

NOTIFY pgrst, 'reload schema';
