-- =============================================================================
-- attendance_today_dashboard_ex036_tests.sql
-- EX-03.6 — get_today_dashboard_rows usa resolve_employee_work_plan
--   (absència aprovada no surt; slots published sí; contracte planned_minutes).
--
-- Executar:
--   Get-Content supabase/tests/attendance_today_dashboard_ex036_tests.sql |
--     docker exec -i supabase_db_cavalle-app psql -U postgres -d postgres -v ON_ERROR_STOP=0
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0370000-0000-0000-0000-000000000001', 'EX036 Tenant', 'ex036-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b0370000-0000-0000-0000-000000000001', 'a0370000-0000-0000-0000-000000000001', 'EX036 Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0370000-0000-0000-0000-000000000001', 'emp@ex036.test', 'authenticated', 'authenticated'),
  ('c0370000-0000-0000-0000-000000000002', 'mgr@ex036.test', 'authenticated', 'authenticated'),
  ('c0370000-0000-0000-0000-000000000003', 'emp2@ex036.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0370000-0000-0000-0000-000000000001', 'emp@ex036.test', 'Emp EX036'),
  ('c0370000-0000-0000-0000-000000000002', 'mgr@ex036.test', 'Mgr EX036'),
  ('c0370000-0000-0000-0000-000000000003', 'emp2@ex036.test', 'Emp2 EX036')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0370000-0000-0000-0000-000000000001', 'c0370000-0000-0000-0000-000000000001', 'member', true),
  (gen_random_uuid(), 'a0370000-0000-0000-0000-000000000001', 'c0370000-0000-0000-0000-000000000002', 'manager', true),
  (gen_random_uuid(), 'a0370000-0000-0000-0000-000000000001', 'c0370000-0000-0000-0000-000000000003', 'member', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.calendar_groups (id, tenant_id, site_id, name, color, sort_order)
VALUES (
  'e0370000-0000-0000-0000-000000000001',
  'a0370000-0000-0000-0000-000000000001',
  'b0370000-0000-0000-0000-000000000001',
  'Grup EX036', '#0ea5e9', 1
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status, calendar_group_id)
VALUES
  (
    'd0370000-0000-0000-0000-000000000001',
    'a0370000-0000-0000-0000-000000000001',
    'b0370000-0000-0000-0000-000000000001',
    'c0370000-0000-0000-0000-000000000001',
    'Emp EX036', 'active',
    'e0370000-0000-0000-0000-000000000001'
  ),
  (
    'd0370000-0000-0000-0000-000000000002',
    'a0370000-0000-0000-0000-000000000001',
    'b0370000-0000-0000-0000-000000000001',
    'c0370000-0000-0000-0000-000000000003',
    'Emp2 EX036', 'active',
    'e0370000-0000-0000-0000-000000000001'
  )
ON CONFLICT (id) DO NOTHING;

-- Dilluns 2026-07-13 = DOW 1, base 08:00-16:00 = 480
INSERT INTO data.calendar_group_weekly_intervals (
  tenant_id, group_id, day_of_week, day_type, work_start, work_end, work_intervals, valid_from
)
VALUES (
  'a0370000-0000-0000-0000-000000000001',
  'e0370000-0000-0000-0000-000000000001',
  1, 'work', '08:00', '16:00',
  '[{"start":"08:00","end":"16:00"}]'::jsonb,
  '2020-01-01'
)
ON CONFLICT DO NOTHING;

INSERT INTO data.work_shifts (id, tenant_id, site_id, name, color, start_time, end_time, is_active)
VALUES (
  'f0370000-0000-0000-0000-000000000001',
  'a0370000-0000-0000-0000-000000000001',
  'b0370000-0000-0000-0000-000000000001',
  'Matí EX036', '#3b82f6', '10:00', '14:00', true
)
ON CONFLICT DO NOTHING;

CREATE TEMP TABLE ex036_results (
  test_name text, status text, details text
) ON COMMIT DROP;

-- Helper JWT manager + tenant header
CREATE OR REPLACE FUNCTION pg_temp.set_mgr_ctx() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0370000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0370000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0370000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0370000-0000-0000-0000-000000000001":{"global_permissions":["attendance.view_all","labor_calendar.manage"],"sites":{}}}}}',
    true);
END;
$$;

-- T1: empleat amb base setmanal → fila present (480, expected_start 08:00)
DO $$
DECLARE
  v_rows jsonb;
  v_row  jsonb;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;

  v_rows := api.get_today_dashboard_rows(
    'b0370000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date
  );

  SET LOCAL ROLE postgres;

  SELECT r INTO v_row
  FROM jsonb_array_elements(v_rows) r
  WHERE r->>'employee_id' = 'd0370000-0000-0000-0000-000000000001';

  IF v_row IS NOT NULL
     AND v_row->>'day_type' = 'work'
     AND (v_row->>'planned_minutes')::int = 480
     AND v_row->>'expected_start' = '08:00'
  THEN
    INSERT INTO ex036_results VALUES ('T1 programat base weekly', 'PASS',
      format('planned=%s start=%s', v_row->>'planned_minutes', v_row->>'expected_start'));
  ELSE
    INSERT INTO ex036_results VALUES ('T1 programat base weekly', 'FAIL',
      format('row=%s rows=%s', v_row, v_rows));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex036_results VALUES ('T1 programat base weekly', 'ERROR', SQLERRM);
END;
$$;

-- T2: absència aprovada → NO surt al dashboard (bug ADR-0001)
DO $$
DECLARE
  v_rows jsonb;
  v_cnt  int;
BEGIN
  INSERT INTO data.employee_absences (
    id, tenant_id, site_id, employee_id,
    absence_type, start_date, end_date,
    status, is_paid, requested_by, reviewed_by, reviewed_at
  ) VALUES (
    'ab037000-0000-0000-0000-000000000001',
    'a0370000-0000-0000-0000-000000000001',
    'b0370000-0000-0000-0000-000000000001',
    'd0370000-0000-0000-0000-000000000001',
    'vacation', '2026-07-13', '2026-07-13',
    'approved', true,
    'c0370000-0000-0000-0000-000000000001',
    'c0370000-0000-0000-0000-000000000002',
    now()
  ) ON CONFLICT (id) DO NOTHING;

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;

  v_rows := api.get_today_dashboard_rows(
    'b0370000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date
  );

  SET LOCAL ROLE postgres;

  SELECT count(*)::int INTO v_cnt
  FROM jsonb_array_elements(v_rows) r
  WHERE r->>'employee_id' = 'd0370000-0000-0000-0000-000000000001';

  IF v_cnt = 0 THEN
    INSERT INTO ex036_results VALUES ('T2 absència no surt', 'PASS',
      format('rows=%s', jsonb_array_length(v_rows)));
  ELSE
    INSERT INTO ex036_results VALUES ('T2 absència no surt', 'FAIL',
      format('cnt=%s rows=%s', v_cnt, v_rows));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex036_results VALUES ('T2 absència no surt', 'ERROR', SQLERRM);
END;
$$;

-- T3: slot published substitueix intervals (Emp2 sense absència)
DO $$
DECLARE
  v_rows jsonb;
  v_row  jsonb;
  v_asg  jsonb;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;

  v_asg := api.assign_shift_slot(
    'd0370000-0000-0000-0000-000000000002'::uuid,
    '2026-07-13'::date,
    'f0370000-0000-0000-0000-000000000001'::uuid
  );
  PERFORM api.publish_shifts(
    'b0370000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date
  );

  v_rows := api.get_today_dashboard_rows(
    'b0370000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date
  );

  SET LOCAL ROLE postgres;

  SELECT r INTO v_row
  FROM jsonb_array_elements(v_rows) r
  WHERE r->>'employee_id' = 'd0370000-0000-0000-0000-000000000002';

  IF v_asg->>'slot_id' IS NOT NULL
     AND v_row IS NOT NULL
     AND (v_row->>'planned_minutes')::int = 240
     AND v_row->>'expected_start' = '10:00'
  THEN
    INSERT INTO ex036_results VALUES ('T3 slot published 240', 'PASS',
      format('planned=%s start=%s', v_row->>'planned_minutes', v_row->>'expected_start'));
  ELSE
    INSERT INTO ex036_results VALUES ('T3 slot published 240', 'FAIL',
      format('asg=%s row=%s rows=%s', v_asg, v_row, v_rows));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex036_results VALUES ('T3 slot published 240', 'ERROR', SQLERRM);
END;
$$;

-- T4: festiu assignat → no surt
DO $$
DECLARE
  v_rows jsonb;
  v_cnt  int;
  v_cal  uuid := 'a0370000-0000-0000-0000-0000000000c1';
BEGIN
  INSERT INTO data.holiday_calendars (id, tenant_id, name, country_code, year, is_active)
  VALUES (v_cal, 'a0370000-0000-0000-0000-000000000001', 'Cal EX036', 'ES', 2026, true)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO data.holidays (calendar_id, date, name, holiday_type)
  VALUES (v_cal, '2026-07-14', 'Festiu EX036', 'tenant_custom')
  ON CONFLICT DO NOTHING;

  INSERT INTO data.site_holiday_calendar_assignments (site_id, calendar_id, priority)
  VALUES ('b0370000-0000-0000-0000-000000000001', v_cal, 1)
  ON CONFLICT DO NOTHING;

  -- Dimarts amb base weekly work; festiu assignat ha de guanyar
  INSERT INTO data.calendar_group_weekly_intervals (
    tenant_id, group_id, day_of_week, day_type, work_start, work_end, work_intervals, valid_from
  )
  VALUES (
    'a0370000-0000-0000-0000-000000000001',
    'e0370000-0000-0000-0000-000000000001',
    2, 'work', '08:00', '16:00',
    '[{"start":"08:00","end":"16:00"}]'::jsonb,
    '2020-01-01'
  )
  ON CONFLICT DO NOTHING;

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;

  v_rows := api.get_today_dashboard_rows(
    'b0370000-0000-0000-0000-000000000001'::uuid,
    '2026-07-14'::date
  );

  SET LOCAL ROLE postgres;

  SELECT count(*)::int INTO v_cnt
  FROM jsonb_array_elements(v_rows) r
  WHERE r->>'employee_id' IN (
    'd0370000-0000-0000-0000-000000000001',
    'd0370000-0000-0000-0000-000000000002'
  );

  IF v_cnt = 0 THEN
    INSERT INTO ex036_results VALUES ('T4 festiu no surt', 'PASS', 'ok');
  ELSE
    INSERT INTO ex036_results VALUES ('T4 festiu no surt', 'FAIL',
      format('cnt=%s rows=%s', v_cnt, v_rows));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex036_results VALUES ('T4 festiu no surt', 'ERROR', SQLERRM);
END;
$$;

-- T5: sense attendance.view_all → insufficient_privilege
DO $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0370000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0370000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"a0370000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"a0370000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  PERFORM api.get_today_dashboard_rows(
    'b0370000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date
  );

  SET LOCAL ROLE postgres;
  INSERT INTO ex036_results VALUES ('T5 sense permís', 'FAIL', 'expected exception');
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  IF SQLERRM ILIKE '%insufficient_privilege%' THEN
    INSERT INTO ex036_results VALUES ('T5 sense permís', 'PASS', SQLERRM);
  ELSE
    INSERT INTO ex036_results VALUES ('T5 sense permís', 'ERROR', SQLERRM);
  END IF;
END;
$$;

SELECT * FROM ex036_results ORDER BY test_name;

SELECT
  count(*) FILTER (WHERE status = 'PASS') AS passed,
  count(*) FILTER (WHERE status = 'FAIL') AS failed,
  count(*) FILTER (WHERE status = 'ERROR') AS errors,
  count(*) AS total
FROM ex036_results;

ROLLBACK;
