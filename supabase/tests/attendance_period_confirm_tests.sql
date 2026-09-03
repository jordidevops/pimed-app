-- =============================================================================
-- attendance_period_confirm_tests.sql — Fase 0 PERIOD_NOT_ENDED
--
-- Executar:
--   Get-Content supabase/tests/attendance_period_confirm_tests.sql -Raw |
--     docker exec -i supabase_db_<project> psql -U postgres -d postgres
-- =============================================================================

BEGIN;

CREATE TEMP TABLE period_confirm_test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('b1000000-0000-0000-0000-000000000001', 'Period Confirm Test', 'period-confirm-test', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b2000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', 'Period Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES (
  'b5000000-0000-0000-0000-000000000001',
  'b1000000-0000-0000-0000-000000000001',
  'b2000000-0000-0000-0000-000000000001',
  NULL,
  'Period Test Employee',
  'active'
)
ON CONFLICT (id) DO NOTHING;

-- P0-T1: mes natural en curs → PERIOD_NOT_ENDED
DO $$
DECLARE
  v_today  date := (now() AT TIME ZONE 'Europe/Madrid')::date;
  v_year   int  := EXTRACT(YEAR FROM v_today)::int;
  v_month  int  := EXTRACT(MONTH FROM v_today)::int;
  v_result jsonb;
  v_has    boolean;
BEGIN
  v_result := api.validate_attendance_month_employee_confirm(
    'b5000000-0000-0000-0000-000000000001',
    v_year,
    v_month
  );

  SELECT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(COALESCE(v_result -> 'blockers', '[]'::jsonb)) b
    WHERE b ->> 'code' = 'PERIOD_NOT_ENDED'
  ) INTO v_has;

  IF COALESCE((v_result ->> 'confirmable')::boolean, true) OR NOT v_has THEN
    INSERT INTO period_confirm_test_results VALUES (
      'P0-T1 current month PERIOD_NOT_ENDED',
      'FAIL',
      v_result::text
    );
  ELSE
    INSERT INTO period_confirm_test_results VALUES (
      'P0-T1 current month PERIOD_NOT_ENDED',
      'PASS',
      NULL
    );
  END IF;
END $$;

-- P0-T2: últim dia del període = avui → PERIOD_NOT_ENDED
DO $$
DECLARE
  v_today  date := (now() AT TIME ZONE 'Europe/Madrid')::date;
  v_from   date := v_today - 6;
  v_result jsonb;
  v_has    boolean;
BEGIN
  v_result := api.validate_attendance_period_employee_confirm(
    'b5000000-0000-0000-0000-000000000001',
    v_from,
    v_today
  );

  SELECT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(COALESCE(v_result -> 'blockers', '[]'::jsonb)) b
    WHERE b ->> 'code' = 'PERIOD_NOT_ENDED'
  ) INTO v_has;

  IF NOT v_has THEN
    INSERT INTO period_confirm_test_results VALUES (
      'P0-T2 period_to=today PERIOD_NOT_ENDED',
      'FAIL',
      v_result::text
    );
  ELSE
    INSERT INTO period_confirm_test_results VALUES (
      'P0-T2 period_to=today PERIOD_NOT_ENDED',
      'PASS',
      NULL
    );
  END IF;
END $$;

-- P0-T3: període acabat (fins ahir) → sense PERIOD_NOT_ENDED
DO $$
DECLARE
  v_today  date := (now() AT TIME ZONE 'Europe/Madrid')::date;
  v_to     date := v_today - 1;
  v_from   date := v_to - 6;
  v_result jsonb;
  v_has    boolean;
BEGIN
  v_result := api.validate_attendance_period_employee_confirm(
    'b5000000-0000-0000-0000-000000000001',
    v_from,
    v_to
  );

  SELECT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(COALESCE(v_result -> 'blockers', '[]'::jsonb)) b
    WHERE b ->> 'code' = 'PERIOD_NOT_ENDED'
  ) INTO v_has;

  IF v_has THEN
    INSERT INTO period_confirm_test_results VALUES (
      'P0-T3 ended period no PERIOD_NOT_ENDED',
      'FAIL',
      v_result::text
    );
  ELSE
    INSERT INTO period_confirm_test_results VALUES (
      'P0-T3 ended period no PERIOD_NOT_ENDED',
      'PASS',
      NULL
    );
  END IF;
END $$;

-- P0-T4: jornada oberta dins període acabat → OPEN_TIME_ENTRY
DO $$
DECLARE
  v_today  date := (now() AT TIME ZONE 'Europe/Madrid')::date;
  v_work   date := v_today - 3;
  v_from   date := v_today - 7;
  v_to     date := v_today - 1;
  v_result jsonb;
  v_has    boolean;
BEGIN
  INSERT INTO data.time_entries (
    tenant_id, site_id, employee_id, work_date, status
  ) VALUES (
    'b1000000-0000-0000-0000-000000000001',
    'b2000000-0000-0000-0000-000000000001',
    'b5000000-0000-0000-0000-000000000001',
    v_work,
    'open'
  )
  ON CONFLICT (employee_id, work_date) DO UPDATE SET status = 'open';

  v_result := api.validate_attendance_period_employee_confirm(
    'b5000000-0000-0000-0000-000000000001',
    v_from,
    v_to
  );

  SELECT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(COALESCE(v_result -> 'blockers', '[]'::jsonb)) b
    WHERE b ->> 'code' = 'OPEN_TIME_ENTRY'
  ) INTO v_has;

  IF NOT v_has THEN
    INSERT INTO period_confirm_test_results VALUES (
      'P0-T4 open entry OPEN_TIME_ENTRY',
      'FAIL',
      v_result::text
    );
  ELSE
    INSERT INTO period_confirm_test_results VALUES (
      'P0-T4 open entry OPEN_TIME_ENTRY',
      'PASS',
      NULL
    );
  END IF;
END $$;

SELECT test_name, status, details FROM period_confirm_test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT COUNT(*) INTO v_fail FROM period_confirm_test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'attendance_period_confirm_tests: % failure(s)', v_fail;
  END IF;
END $$;

ROLLBACK;
