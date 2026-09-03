-- EP8: confirmació mensual L1 via portal d'empleats (service_role via Edge Function)

ALTER TABLE data.employee_portal_access_logs
  DROP CONSTRAINT IF EXISTS employee_portal_access_logs_action_check;

ALTER TABLE data.employee_portal_access_logs
  ADD CONSTRAINT employee_portal_access_logs_action_check CHECK (action IN (
    'view_schedule',
    'view_history',
    'view_monthly_report',
    'monthly_confirm',
    'punch_in',
    'punch_out',
    'pin_failed',
    'token_invalid',
    'token_expired',
    'session_create',
    'session_refresh'
  ));

CREATE OR REPLACE FUNCTION api.employee_portal_get_monthly_report(
  p_employee_id uuid,
  p_tenant_id   uuid,
  p_year        int,
  p_month       int
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp       record;
  v_report    record;
  v_export    jsonb;
  v_settings  jsonb;
  v_validation jsonb;
  v_signing   jsonb := NULL;
BEGIN
  SELECT e.id, e.tenant_id, e.site_id, e.full_name, e.email
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND e.tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF p_month < 1 OR p_month > 12 THEN
    RAISE EXCEPTION 'invalid_month' USING ERRCODE = 'check_violation';
  END IF;

  v_export := api.export_attendance_month(p_employee_id, p_year, p_month);
  v_validation := api.validate_attendance_month_employee_confirm(p_employee_id, p_year, p_month);

  v_settings := api.get_effective_settings(
    p_site_id   => v_emp.site_id,
    p_tenant_id => v_emp.tenant_id
  );

  SELECT
    amr.id,
    amr.status,
    amr.confirmed_at,
    amr.approved_at,
    amr.signing_submission_id,
    amr.document_id,
    amr.content_hash
  INTO v_report
  FROM data.attendance_monthly_reports amr
  WHERE amr.employee_id = p_employee_id
    AND amr.year = p_year
    AND amr.month = p_month;

  IF v_report.signing_submission_id IS NOT NULL THEN
    SELECT jsonb_build_object(
      'submission_id', ss.id,
      'status', ss.status,
      'signers', ss.signers
    )
    INTO v_signing
    FROM data.signing_submissions ss
    WHERE ss.id = v_report.signing_submission_id;
  END IF;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'tenant_id', p_tenant_id,
    'year', p_year,
    'month', p_month,
    'employee_name', v_emp.full_name,
    'employee_email', v_emp.email,
    'report', CASE
      WHEN v_report.id IS NULL THEN jsonb_build_object(
        'id', NULL,
        'status', 'draft',
        'confirmed_at', NULL,
        'approved_at', NULL,
        'signing_submission_id', NULL,
        'document_id', NULL,
        'content_hash', NULL
      )
      ELSE jsonb_build_object(
        'id', v_report.id,
        'status', v_report.status,
        'confirmed_at', v_report.confirmed_at,
        'approved_at', v_report.approved_at,
        'signing_submission_id', v_report.signing_submission_id,
        'document_id', v_report.document_id,
        'content_hash', v_report.content_hash
      )
    END,
    'export', v_export,
    'settings', jsonb_build_object(
      'employee_confirm_required', COALESCE(
        (v_settings->>'attendance_monthly_employee_confirm_required')::boolean, true
      ),
      'require_digital_signature', COALESCE(
        (v_settings->>'attendance_monthly_require_digital_signature')::boolean, false
      )
    ),
    'validation', v_validation,
    'signing', v_signing
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.employee_portal_confirm_monthly_report(
  p_employee_id uuid,
  p_tenant_id   uuid,
  p_year        int,
  p_month       int
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp       record;
  v_id        uuid;
  v_check     jsonb;
  v_settings  jsonb;
  v_status    text;
  v_require_sig boolean;
BEGIN
  SELECT e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND e.tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF p_month < 1 OR p_month > 12 THEN
    RAISE EXCEPTION 'invalid_month' USING ERRCODE = 'check_violation';
  END IF;

  v_settings := api.get_effective_settings(
    p_site_id   => v_emp.site_id,
    p_tenant_id => v_emp.tenant_id
  );
  v_require_sig := COALESCE(
    (v_settings->>'attendance_monthly_require_digital_signature')::boolean,
    false
  );

  IF v_require_sig THEN
    RAISE EXCEPTION 'digital_signature_required'
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT amr.status INTO v_status
  FROM data.attendance_monthly_reports amr
  WHERE amr.employee_id = p_employee_id
    AND amr.year = p_year
    AND amr.month = p_month;

  IF v_status IN ('employee_confirmed', 'manager_approved', 'signed', 'archived') THEN
    RAISE EXCEPTION 'already_confirmed' USING ERRCODE = 'check_violation';
  END IF;

  v_check := api.validate_attendance_month_employee_confirm(p_employee_id, p_year, p_month);
  IF NOT COALESCE((v_check->>'confirmable')::boolean, false) THEN
    RAISE EXCEPTION 'month_not_confirmable'
      USING ERRCODE = 'check_violation',
            DETAIL = v_check::text;
  END IF;

  INSERT INTO data.attendance_monthly_reports (
    tenant_id, employee_id, year, month, status, confirmed_at
  )
  VALUES (
    v_emp.tenant_id, p_employee_id, p_year, p_month, 'employee_confirmed', now()
  )
  ON CONFLICT (employee_id, year, month) DO UPDATE SET
    status = 'employee_confirmed',
    confirmed_at = COALESCE(data.attendance_monthly_reports.confirmed_at, now()),
    updated_at = now()
  RETURNING id INTO v_id;

  PERFORM data.log_attendance_employee_audit(
    v_emp.tenant_id,
    NULL,
    v_emp.site_id,
    p_employee_id,
    'ATTENDANCE_MONTH_EMPLOYEE_CONFIRMED',
    jsonb_build_object(
      'year', p_year,
      'month', p_month,
      'report_id', v_id,
      'source', 'employee_portal'
    )
  );

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.employee_portal_get_monthly_report(uuid, uuid, int, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.employee_portal_confirm_monthly_report(uuid, uuid, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_portal_get_monthly_report(uuid, uuid, int, int) TO service_role;
GRANT EXECUTE ON FUNCTION api.employee_portal_confirm_monthly_report(uuid, uuid, int, int) TO service_role;

NOTIFY pgrst, 'reload schema';
