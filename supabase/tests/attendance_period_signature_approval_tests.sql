-- attendance_period_signature_approval_tests.sql — signature_is_employee_approval + L1

BEGIN;

CREATE TEMP TABLE period_signature_approval_test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

INSERT INTO data.tenants (id, name, slug, is_active, settings)
VALUES (
  'a1000000-0000-0000-0000-000000000001',
  'Period Signature Approval Test',
  'period-sig-approval-test',
  true,
  '{
    "attendance_monthly_employee_confirm_required": true,
    "attendance_monthly_manager_can_close_without_employee": false,
    "attendance_monthly_signature_is_employee_approval": true,
    "attendance_employee_confirm_cycle": "calendar_month"
  }'::jsonb
)
ON CONFLICT (id) DO UPDATE SET
  settings = EXCLUDED.settings;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('a2000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'Sig Approval Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES (
  'a5000000-0000-0000-0000-000000000001',
  'a1000000-0000-0000-0000-000000000001',
  'a2000000-0000-0000-0000-000000000001',
  NULL,
  'Sig Approval Employee',
  'active'
)
ON CONFLICT (id) DO NOTHING;

-- SIG-T1: validació període → EMPLOYEE_CONFIRM_VIA_SIGNATURE
DO $$
DECLARE
  v_result jsonb;
  v_has    boolean;
BEGIN
  v_result := api.validate_attendance_period_employee_confirm(
    'a5000000-0000-0000-0000-000000000001',
    '2025-05-01',
    '2025-05-31'
  );

  SELECT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(COALESCE(v_result -> 'blockers', '[]'::jsonb)) b
    WHERE b ->> 'code' = 'EMPLOYEE_CONFIRM_VIA_SIGNATURE'
  ) INTO v_has;

  IF v_has AND NOT COALESCE((v_result ->> 'confirmable')::boolean, true) THEN
    INSERT INTO period_signature_approval_test_results VALUES ('SIG-T1 validate blocker', 'PASS', NULL);
  ELSE
    INSERT INTO period_signature_approval_test_results VALUES ('SIG-T1 validate blocker', 'FAIL', v_result::text);
  END IF;
END $$;

-- SIG-T2: confirm_attendance_period → employee_confirm_via_signature_required
DO $$
DECLARE
  v_err text;
BEGIN
  BEGIN
    PERFORM api.confirm_attendance_period(
      'a5000000-0000-0000-0000-000000000001',
      '2025-05-01',
      '2025-05-31',
      'employee_portal',
      2025,
      5,
      NULL
    );
    INSERT INTO period_signature_approval_test_results VALUES (
      'SIG-T2 confirm blocked',
      'FAIL',
      'expected exception'
    );
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    IF v_err LIKE '%employee_confirm_via_signature_required%' THEN
      INSERT INTO period_signature_approval_test_results VALUES ('SIG-T2 confirm blocked', 'PASS', NULL);
    ELSE
      INSERT INTO period_signature_approval_test_results VALUES ('SIG-T2 confirm blocked', 'FAIL', v_err);
    END IF;
  END;
END $$;

-- SIG-T3: satisfied sense períodes confirmats → true
DO $$
DECLARE
  v_ok boolean;
BEGIN
  DELETE FROM data.attendance_period_confirmations
  WHERE employee_id = 'a5000000-0000-0000-0000-000000000001';

  DELETE FROM data.attendance_monthly_reports
  WHERE employee_id = 'a5000000-0000-0000-0000-000000000001'
    AND year = 2025 AND month = 5;

  v_ok := data.attendance_month_employee_confirm_satisfied(
    'a5000000-0000-0000-0000-000000000001',
    2025,
    5,
    'draft'
  );

  IF v_ok THEN
    INSERT INTO period_signature_approval_test_results VALUES ('SIG-T3 satisfied without periods', 'PASS', NULL);
  ELSE
    INSERT INTO period_signature_approval_test_results VALUES ('SIG-T3 satisfied without periods', 'FAIL', 'expected true');
  END IF;
END $$;

-- SIG-T4: validate_attendance_month_close sense bloqueig de períodes
DO $$
DECLARE
  v_result jsonb;
  v_has_blocker boolean;
BEGIN
  v_result := api.validate_attendance_month_close(
    'a5000000-0000-0000-0000-000000000001',
    2025,
    5
  );

  SELECT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(COALESCE(v_result -> 'blockers', '[]'::jsonb)) b
    WHERE b ->> 'code' = 'EMPLOYEE_PERIOD_CONFIRM_INCOMPLETE'
  ) INTO v_has_blocker;

  IF NOT v_has_blocker THEN
    INSERT INTO period_signature_approval_test_results VALUES ('SIG-T4 close not blocked by periods', 'PASS', NULL);
  ELSE
    INSERT INTO period_signature_approval_test_results VALUES (
      'SIG-T4 close not blocked by periods',
      'FAIL',
      v_result::text
    );
  END IF;
END $$;

SELECT test_name, status, details FROM period_signature_approval_test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT COUNT(*) INTO v_fail
  FROM period_signature_approval_test_results
  WHERE status <> 'PASS';

  IF v_fail > 0 THEN
    RAISE EXCEPTION '% signature approval test(s) FAILED', v_fail;
  END IF;
END $$;

ROLLBACK;
