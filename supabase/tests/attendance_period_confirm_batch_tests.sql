-- attendance_period_confirm_batch_tests.sql — P2 batch RPC

BEGIN;

CREATE TEMP TABLE period_batch_test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

INSERT INTO data.tenants (id, name, slug, is_active, settings)
VALUES (
  'b1000000-0000-0000-0000-000000000001',
  'Period Batch Test',
  'period-batch-test',
  true,
  '{"attendance_employee_confirm_cycle": "calendar_month"}'::jsonb
)
ON CONFLICT (id) DO UPDATE SET settings = EXCLUDED.settings;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b2000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', 'Batch Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES
  (
    'b5000000-0000-0000-0000-000000000001',
    'b1000000-0000-0000-0000-000000000001',
    'b2000000-0000-0000-0000-000000000001',
    NULL,
    'Batch Employee A',
    'active'
  ),
  (
    'b5000000-0000-0000-0000-000000000002',
    'b1000000-0000-0000-0000-000000000001',
    'b2000000-0000-0000-0000-000000000001',
    NULL,
    'Batch Employee B',
    'active'
  )
ON CONFLICT (id) DO NOTHING;

-- P2B-T1: batch buit
DO $$
DECLARE
  v_result jsonb;
BEGIN
  v_result := api.get_attendance_month_period_status_batch(ARRAY[]::uuid[], 2025, 5);
  IF jsonb_array_length(COALESCE(v_result -> 'employees', '[]'::jsonb)) = 0 THEN
    INSERT INTO period_batch_test_results VALUES ('P2B-T1 empty batch', 'PASS', NULL);
  ELSE
    INSERT INTO period_batch_test_results VALUES ('P2B-T1 empty batch', 'FAIL', v_result::text);
  END IF;
END $$;

-- P2B-T2: batch 2 empleats, un confirmat
DO $$
DECLARE
  v_result jsonb;
  v_a jsonb;
  v_b jsonb;
BEGIN
  DELETE FROM data.attendance_period_confirmations
  WHERE employee_id IN (
    'b5000000-0000-0000-0000-000000000001',
    'b5000000-0000-0000-0000-000000000002'
  );

  INSERT INTO data.attendance_period_confirmations (
    tenant_id, employee_id, period_from, period_to, cycle_type,
    calendar_year, calendar_month, confirmed_via
  ) VALUES (
    'b1000000-0000-0000-0000-000000000001',
    'b5000000-0000-0000-0000-000000000001',
    '2025-05-01',
    '2025-05-31',
    'calendar_month',
    2025,
    5,
    'tenant_app'
  );

  v_result := api.get_attendance_month_period_status_batch(
    ARRAY[
      'b5000000-0000-0000-0000-000000000001'::uuid,
      'b5000000-0000-0000-0000-000000000002'::uuid
    ],
    2025,
    5
  );

  SELECT elem INTO v_a
  FROM jsonb_array_elements(v_result -> 'employees') elem
  WHERE (elem ->> 'employee_id')::uuid = 'b5000000-0000-0000-0000-000000000001';

  SELECT elem INTO v_b
  FROM jsonb_array_elements(v_result -> 'employees') elem
  WHERE (elem ->> 'employee_id')::uuid = 'b5000000-0000-0000-0000-000000000002';

  IF COALESCE((v_a ->> 'month_fully_confirmed')::boolean, false)
     AND NOT COALESCE((v_b ->> 'month_fully_confirmed')::boolean, true) THEN
    INSERT INTO period_batch_test_results VALUES ('P2B-T2 batch mixed confirm', 'PASS', NULL);
  ELSE
    INSERT INTO period_batch_test_results VALUES (
      'P2B-T2 batch mixed confirm',
      'FAIL',
      jsonb_build_object('a', v_a, 'b', v_b)::text
    );
  END IF;
END $$;

-- P2B-T3: single i batch coincideixen
DO $$
DECLARE
  v_single jsonb;
  v_batch jsonb;
  v_batch_row jsonb;
BEGIN
  v_single := api.get_attendance_month_period_status(
    'b5000000-0000-0000-0000-000000000001',
    2025,
    5
  );

  v_batch := api.get_attendance_month_period_status_batch(
    ARRAY['b5000000-0000-0000-0000-000000000001'::uuid],
    2025,
    5
  );

  SELECT elem INTO v_batch_row
  FROM jsonb_array_elements(v_batch -> 'employees') elem
  LIMIT 1;

  IF (v_single ->> 'month_fully_confirmed') = (v_batch_row ->> 'month_fully_confirmed')
     AND (v_single ->> 'weeks_required') = (v_batch_row ->> 'weeks_required') THEN
    INSERT INTO period_batch_test_results VALUES ('P2B-T3 single vs batch parity', 'PASS', NULL);
  ELSE
    INSERT INTO period_batch_test_results VALUES ('P2B-T3 single vs batch parity', 'FAIL', NULL);
  END IF;
END $$;

SELECT test_name, status, details
FROM period_batch_test_results
ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT COUNT(*) INTO v_fail FROM period_batch_test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'attendance_period_confirm_batch_tests: % failure(s)', v_fail;
  END IF;
END $$;

ROLLBACK;
