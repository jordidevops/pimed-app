-- F1: esmenes post-tancament del registre mensual (documentació legal, sense reobrir export nòmina).

CREATE TABLE IF NOT EXISTS data.attendance_monthly_report_amendments (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id uuid        NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  report_id   uuid        NOT NULL REFERENCES data.attendance_monthly_reports(id) ON DELETE CASCADE,
  year        int         NOT NULL,
  month       int         NOT NULL CHECK (month BETWEEN 1 AND 12),
  work_date   date,
  reason      text        NOT NULL,
  description text,
  created_by  uuid        REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT attendance_monthly_report_amendments_reason_check
    CHECK (char_length(trim(reason)) >= 3)
);

CREATE INDEX IF NOT EXISTS idx_attendance_monthly_amendments_report
  ON data.attendance_monthly_report_amendments (report_id);

CREATE INDEX IF NOT EXISTS idx_attendance_monthly_amendments_employee_period
  ON data.attendance_monthly_report_amendments (employee_id, year, month, created_at DESC);

ALTER TABLE data.attendance_monthly_report_amendments ENABLE ROW LEVEL SECURITY;

CREATE POLICY attendance_monthly_amendments_select
  ON data.attendance_monthly_report_amendments
  FOR SELECT
  USING (
    tenant_id = data.active_tenant_id()
    AND (
      data.jwt_has_permission(tenant_id, 'attendance.view_all')
      OR employee_id IN (SELECT id FROM data.employees WHERE user_id = auth.uid())
    )
  );

CREATE OR REPLACE VIEW api.attendance_monthly_report_amendments
  WITH (security_invoker = true) AS
  SELECT * FROM data.attendance_monthly_report_amendments;

GRANT SELECT ON data.attendance_monthly_report_amendments TO authenticated;
GRANT SELECT ON api.attendance_monthly_report_amendments TO authenticated;

-- ── List amendments for a monthly report ─────────────────────────────────────

CREATE OR REPLACE FUNCTION api.list_attendance_month_amendments(
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
  v_emp  record;
  v_rows jsonb := '[]'::jsonb;
  v_rec  record;
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

  FOR v_rec IN
    SELECT
      a.id,
      a.report_id,
      a.year,
      a.month,
      a.work_date,
      a.reason,
      a.description,
      a.created_at,
      p.full_name AS created_by_name
    FROM data.attendance_monthly_report_amendments a
    LEFT JOIN data.profiles p ON p.id = a.created_by
    WHERE a.employee_id = p_employee_id
      AND a.year = p_year
      AND a.month = p_month
    ORDER BY a.created_at DESC, a.id DESC
  LOOP
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'id', v_rec.id,
      'report_id', v_rec.report_id,
      'year', v_rec.year,
      'month', v_rec.month,
      'work_date', v_rec.work_date,
      'reason', v_rec.reason,
      'description', v_rec.description,
      'created_at', v_rec.created_at,
      'created_by_name', v_rec.created_by_name
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'year', p_year,
    'month', p_month,
    'amendments', v_rows
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_attendance_month_amendments(uuid, int, int) TO authenticated;

-- ── Register post-close amendment ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.register_attendance_month_amendment(
  p_employee_id uuid,
  p_year        int,
  p_month       int,
  p_reason      text,
  p_work_date   date DEFAULT NULL,
  p_description text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp       record;
  v_report    record;
  v_month_from date;
  v_month_to   date;
  v_reason     text;
  v_id         uuid;
BEGIN
  IF p_month < 1 OR p_month > 12 THEN
    RAISE EXCEPTION 'invalid_month';
  END IF;

  v_reason := trim(COALESCE(p_reason, ''));
  IF char_length(v_reason) < 3 THEN
    RAISE EXCEPTION 'amendment_reason_required';
  END IF;

  SELECT e.id, e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'insufficient_privilege';
  END IF;

  IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.approve', v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege';
  END IF;

  SELECT amr.id, amr.status
  INTO v_report
  FROM data.attendance_monthly_reports amr
  WHERE amr.employee_id = p_employee_id
    AND amr.year = p_year
    AND amr.month = p_month;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'monthly_report_not_found';
  END IF;

  IF v_report.status NOT IN ('manager_approved', 'signed', 'archived') THEN
    RAISE EXCEPTION 'month_not_closed_for_amendment'
      USING ERRCODE = 'check_violation',
            DETAIL = jsonb_build_object('status', v_report.status)::text;
  END IF;

  v_month_from := make_date(p_year, p_month, 1);
  v_month_to   := (v_month_from + interval '1 month' - interval '1 day')::date;

  IF p_work_date IS NOT NULL
     AND (p_work_date < v_month_from OR p_work_date > v_month_to) THEN
    RAISE EXCEPTION 'amendment_work_date_out_of_month';
  END IF;

  INSERT INTO data.attendance_monthly_report_amendments (
    tenant_id,
    employee_id,
    report_id,
    year,
    month,
    work_date,
    reason,
    description,
    created_by
  ) VALUES (
    v_emp.tenant_id,
    p_employee_id,
    v_report.id,
    p_year,
    p_month,
    p_work_date,
    v_reason,
    NULLIF(trim(COALESCE(p_description, '')), ''),
    auth.uid()
  )
  RETURNING id INTO v_id;

  PERFORM data.log_attendance_employee_audit(
    v_emp.tenant_id,
    auth.uid(),
    v_emp.site_id,
    p_employee_id,
    'ATTENDANCE_MONTH_AMENDMENT_REGISTERED',
    jsonb_build_object(
      'year', p_year,
      'month', p_month,
      'report_id', v_report.id,
      'amendment_id', v_id,
      'work_date', p_work_date,
      'reason', v_reason
    )
  );

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.register_attendance_month_amendment(uuid, int, int, text, date, text) TO authenticated;

COMMENT ON TABLE data.attendance_monthly_report_amendments IS
  'Esmenes documentades després del tancament mensual (F1). No reobre export nòmina extern.';

COMMENT ON FUNCTION api.register_attendance_month_amendment IS
  'Registra una esmena post-tancament quan el mes està manager_approved/signed/archived.';

NOTIFY pgrst, 'reload schema';
