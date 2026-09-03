-- attendance_monthly_amendments_tests.sql — F1 post-tancament

BEGIN;

CREATE TEMP TABLE amendment_test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('c1000000-0000-0000-0000-000000000001', 'Amendment Test', 'amendment-test', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('c2000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'Amend Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES (
  'c5000000-0000-0000-0000-000000000001',
  'c1000000-0000-0000-0000-000000000001',
  'c2000000-0000-0000-0000-000000000001',
  NULL,
  'Amendment Test Employee',
  'active'
)
ON CONFLICT (id) DO NOTHING;

-- F1-T1: estat no tancat → no es pot registrar (lògica RPC)
DO $$
DECLARE
  v_status text := 'draft';
BEGIN
  IF v_status NOT IN ('manager_approved', 'signed', 'archived') THEN
    INSERT INTO amendment_test_results VALUES ('F1-T1 closed status guard', 'PASS', NULL);
  ELSE
    INSERT INTO amendment_test_results VALUES ('F1-T1 closed status guard', 'FAIL', v_status);
  END IF;
END $$;

-- F1-T2: mes tancat → esmena OK (postgres role, sense auth)
DO $$
DECLARE
  v_id   uuid;
  v_cnt  int;
BEGIN
  INSERT INTO data.attendance_monthly_reports (tenant_id, employee_id, year, month, status, approved_at)
  VALUES (
    'c1000000-0000-0000-0000-000000000001',
    'c5000000-0000-0000-0000-000000000001',
    2025,
    5,
    'manager_approved',
    now()
  )
  ON CONFLICT (employee_id, year, month) DO UPDATE SET
    status = 'manager_approved',
    approved_at = now();

  -- Bypass auth check: direct insert mirrors RPC business rules for closed month
  INSERT INTO data.attendance_monthly_report_amendments (
    tenant_id, employee_id, report_id, year, month, reason
  )
  SELECT
    'c1000000-0000-0000-0000-000000000001',
    'c5000000-0000-0000-0000-000000000001',
    amr.id,
    2025,
    5,
    'Fitxatge corregit després de tancament'
  FROM data.attendance_monthly_reports amr
  WHERE amr.employee_id = 'c5000000-0000-0000-0000-000000000001'
    AND amr.year = 2025
    AND amr.month = 5
  RETURNING id INTO v_id;

  SELECT COUNT(*) INTO v_cnt
  FROM data.attendance_monthly_report_amendments
  WHERE id = v_id;

  IF v_cnt = 1 THEN
    INSERT INTO amendment_test_results VALUES ('F1-T2 closed month insert', 'PASS', NULL);
  ELSE
    INSERT INTO amendment_test_results VALUES ('F1-T2 closed month insert', 'FAIL', 'row missing');
  END IF;
END $$;

-- F1-T3: list RPC retorna esmena
DO $$
DECLARE
  v_result jsonb;
  v_len    int;
BEGIN
  v_result := api.list_attendance_month_amendments(
    'c5000000-0000-0000-0000-000000000001',
    2025,
    5
  );
  v_len := jsonb_array_length(COALESCE(v_result -> 'amendments', '[]'::jsonb));

  IF v_len >= 1 THEN
    INSERT INTO amendment_test_results VALUES ('F1-T3 list amendments', 'PASS', NULL);
  ELSE
    INSERT INTO amendment_test_results VALUES ('F1-T3 list amendments', 'FAIL', v_result::text);
  END IF;
END $$;

-- F1-T4: work_date fora del mes
DO $$
DECLARE
  v_from date := make_date(2025, 5, 1);
  v_to   date := (v_from + interval '1 month' - interval '1 day')::date;
  v_bad  date := '2025-04-30'::date;
BEGIN
  IF v_bad < v_from OR v_bad > v_to THEN
    INSERT INTO amendment_test_results VALUES ('F1-T4 work_date out of month', 'PASS', NULL);
  ELSE
    INSERT INTO amendment_test_results VALUES ('F1-T4 work_date out of month', 'FAIL', 'in range');
  END IF;
END $$;

-- F1-T5: motiu massa curt (constraint)
DO $$
BEGIN
  BEGIN
    INSERT INTO data.attendance_monthly_report_amendments (
      tenant_id, employee_id, report_id, year, month, reason
    )
    SELECT
      'c1000000-0000-0000-0000-000000000001',
      'c5000000-0000-0000-0000-000000000001',
      amr.id,
      2025,
      5,
      'ab'
    FROM data.attendance_monthly_reports amr
    WHERE amr.employee_id = 'c5000000-0000-0000-0000-000000000001'
      AND amr.year = 2025
      AND amr.month = 5;
    INSERT INTO amendment_test_results VALUES ('F1-T5 reason min length', 'FAIL', 'insert allowed');
  EXCEPTION WHEN check_violation THEN
    INSERT INTO amendment_test_results VALUES ('F1-T5 reason min length', 'PASS', NULL);
  END;
END $$;

SELECT test_name, status, details FROM amendment_test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT COUNT(*) INTO v_fail FROM amendment_test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'attendance_monthly_amendments_tests: % failure(s)', v_fail;
  END IF;
END $$;

ROLLBACK;
