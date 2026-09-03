-- =============================================================================
-- attendance_resolve_work_plan_ex033_tests.sql
-- EX-03.3 — Caracterització de data.resolve_employee_work_plan + adaptador
-- api.resolve_work_day (slots published, paritat base, holiday no convertit).
--
-- Executar:
--   Get-Content supabase/tests/attendance_resolve_work_plan_ex033_tests.sql |
--     docker exec -i supabase_db_cavalle-app psql -U postgres -d postgres -v ON_ERROR_STOP=0
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0340000-0000-0000-0000-000000000001', 'EX033 Tenant', 'ex033-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b0340000-0000-0000-0000-000000000001', 'a0340000-0000-0000-0000-000000000001', 'EX033 Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0340000-0000-0000-0000-000000000001', 'emp@ex033.test', 'authenticated', 'authenticated'),
  ('c0340000-0000-0000-0000-000000000002', 'mgr@ex033.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0340000-0000-0000-0000-000000000001', 'emp@ex033.test', 'Emp EX033'),
  ('c0340000-0000-0000-0000-000000000002', 'mgr@ex033.test', 'Mgr EX033')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0340000-0000-0000-0000-000000000001', 'c0340000-0000-0000-0000-000000000001', 'member', true),
  (gen_random_uuid(), 'a0340000-0000-0000-0000-000000000001', 'c0340000-0000-0000-0000-000000000002', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status, calendar_group_id)
VALUES (
  'd0340000-0000-0000-0000-000000000001',
  'a0340000-0000-0000-0000-000000000001',
  'b0340000-0000-0000-0000-000000000001',
  'c0340000-0000-0000-0000-000000000001',
  'Emp EX033', 'active', NULL
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.calendar_groups (id, tenant_id, site_id, name, color, sort_order)
VALUES (
  'e0340000-0000-0000-0000-000000000001',
  'a0340000-0000-0000-0000-000000000001',
  'b0340000-0000-0000-0000-000000000001',
  'Grup EX033', '#0ea5e9', 1
)
ON CONFLICT (id) DO NOTHING;

UPDATE data.employees
SET calendar_group_id = 'e0340000-0000-0000-0000-000000000001'
WHERE id = 'd0340000-0000-0000-0000-000000000001';

-- Base recurrent: dilluns (DOW=1) 08:00-16:00 = 480 min
INSERT INTO data.calendar_group_weekly_intervals (
  tenant_id, group_id, day_of_week, day_type, work_start, work_end, work_intervals, valid_from
)
VALUES (
  'a0340000-0000-0000-0000-000000000001',
  'e0340000-0000-0000-0000-000000000001',
  1, 'work', '08:00', '16:00',
  '[{"start":"08:00","end":"16:00"}]'::jsonb,
  '2020-01-01'
)
ON CONFLICT DO NOTHING;

-- Dimarts (DOW=2) explícitament sense patró → unknown (cap fila)

INSERT INTO data.work_shifts (id, tenant_id, site_id, name, color, start_time, end_time, is_active)
VALUES
  ('f0340000-0000-0000-0000-000000000001', 'a0340000-0000-0000-0000-000000000001',
   'b0340000-0000-0000-0000-000000000001', 'Matí EX033', '#3b82f6', '10:00', '14:00', true),
  ('f0340000-0000-0000-0000-000000000002', 'a0340000-0000-0000-0000-000000000001',
   'b0340000-0000-0000-0000-000000000001', 'Tarda EX033', '#f59e0b', '15:00', '19:00', true)
ON CONFLICT DO NOTHING;

-- Festiu assignat: 2026-07-20 és dilluns — creem calendari + assignment
INSERT INTO data.holiday_calendars (id, tenant_id, name, year, country_code, is_active)
VALUES (
  'a0340001-0000-0000-0000-000000000001',
  'a0340000-0000-0000-0000-000000000001',
  'EX033 Holidays', 2026, 'ES', true
)
ON CONFLICT DO NOTHING;

INSERT INTO data.holidays (id, calendar_id, date, name, holiday_type, is_half_day)
VALUES (
  'a0340002-0000-0000-0000-000000000001',
  'a0340001-0000-0000-0000-000000000001',
  '2026-07-20', 'Festiu EX033', 'national', false
)
ON CONFLICT DO NOTHING;

INSERT INTO data.site_holiday_calendar_assignments (site_id, calendar_id, priority)
VALUES (
  'b0340000-0000-0000-0000-000000000001',
  'a0340001-0000-0000-0000-000000000001',
  0
)
ON CONFLICT (site_id, calendar_id) DO NOTHING;

CREATE TEMP TABLE ex033_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

-- =============================================================================
-- T1: paritat canònic vs api sense slots (dilluns base recurrent 08-16)
-- 2026-07-13 = dilluns (NO festiu)
-- =============================================================================
DO $$
DECLARE
  r_plan jsonb;
  r_api  jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0340000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0340000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0340000-0000-0000-0000-000000000001":{"global_permissions":["attendance.view_all","labor_calendar.manage"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  r_plan := data.resolve_employee_work_plan(
    'd0340000-0000-0000-0000-000000000001', '2026-07-13'::date
  );
  r_api := api.resolve_work_day(
    'd0340000-0000-0000-0000-000000000001', '2026-07-13'::date
  );

  SET LOCAL ROLE postgres;

  IF r_plan->>'day_type' = 'working'
     AND r_plan->>'labor_source' = 'calendar_group_weekly'
     AND (r_plan->>'expected_minutes')::int = 480
     AND r_api->>'day_type' = r_plan->>'day_type'
     AND r_api->>'labor_source' = r_plan->>'labor_source'
     AND (r_api->>'expected_minutes')::int = (r_plan->>'expected_minutes')::int
  THEN
    INSERT INTO ex033_results VALUES ('T1 paritat base recurrent sense slots', 'PASS',
      format('source=%s minutes=%s', r_plan->>'labor_source', r_plan->>'expected_minutes'));
  ELSE
    INSERT INTO ex033_results VALUES ('T1 paritat base recurrent sense slots', 'FAIL',
      format('plan=%s api=%s', r_plan, r_api));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex033_results VALUES ('T1 paritat base recurrent sense slots', 'ERROR', SQLERRM);
END $$;

-- =============================================================================
-- T2: slots published substitueixen intervals en dia work
-- =============================================================================
DO $$
DECLARE
  r jsonb;
  v_slot uuid;
BEGIN
  INSERT INTO data.shift_slots (
    id, tenant_id, site_id, employee_id, shift_id,
    slot_date, status, start_time, end_time, published_at
  ) VALUES (
    'a0340004-0000-0000-0000-000000000001',
    'a0340000-0000-0000-0000-000000000001',
    'b0340000-0000-0000-0000-000000000001',
    'd0340000-0000-0000-0000-000000000001',
    'f0340000-0000-0000-0000-000000000001',
    '2026-07-13', 'published', '10:00', '14:00', now()
  )
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_slot;

  r := data.resolve_employee_work_plan(
    'd0340000-0000-0000-0000-000000000001', '2026-07-13'::date
  );

  IF r->>'day_type' = 'working'
     AND r->>'labor_source' = 'published_shift'
     AND r->>'base_source' = 'calendar_group_weekly'
     AND (r->>'expected_minutes')::int = 240
     AND r->'work_intervals'->0->>'start' = '10:00'
     AND r->'work_intervals'->0->>'end' = '14:00'
     AND jsonb_array_length(r->'published_slot_ids') = 1
  THEN
    INSERT INTO ex033_results VALUES ('T2 slots published substitueixen intervals', 'PASS',
      format('minutes=%s base=%s', r->>'expected_minutes', r->>'base_source'));
  ELSE
    INSERT INTO ex033_results VALUES ('T2 slots published substitueixen intervals', 'FAIL',
      r::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex033_results VALUES ('T2 slots published substitueixen intervals', 'ERROR', SQLERRM);
END $$;

-- =============================================================================
-- T3: draft slots NO afecten el resolver
-- =============================================================================
DO $$
DECLARE
  r jsonb;
BEGIN
  -- Dimarts 2026-07-14: sense patró setmanal → unknown; draft no ha de convertir
  INSERT INTO data.shift_slots (
    tenant_id, site_id, employee_id, shift_id,
    slot_date, status, start_time, end_time
  ) VALUES (
    'a0340000-0000-0000-0000-000000000001',
    'b0340000-0000-0000-0000-000000000001',
    'd0340000-0000-0000-0000-000000000001',
    'f0340000-0000-0000-0000-000000000001',
    '2026-07-14', 'draft', '10:00', '14:00'
  );

  r := data.resolve_employee_work_plan(
    'd0340000-0000-0000-0000-000000000001', '2026-07-14'::date
  );

  IF r->>'day_type' = 'unknown'
     AND (r->>'expected_minutes')::int = 0
     AND jsonb_array_length(COALESCE(r->'published_slot_ids', '[]'::jsonb)) = 0
  THEN
    INSERT INTO ex033_results VALUES ('T3 draft slots ignorats', 'PASS',
      format('day_type=%s source=%s', r->>'day_type', r->>'labor_source'));
  ELSE
    INSERT INTO ex033_results VALUES ('T3 draft slots ignorats', 'FAIL', r::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex033_results VALUES ('T3 draft slots ignorats', 'ERROR', SQLERRM);
END $$;

-- =============================================================================
-- T4: slots published en dia undefined → working (sí poden omplir indefinit)
-- =============================================================================
DO $$
DECLARE
  r jsonb;
BEGIN
  INSERT INTO data.shift_slots (
    tenant_id, site_id, employee_id, shift_id,
    slot_date, status, start_time, end_time, published_at
  ) VALUES (
    'a0340000-0000-0000-0000-000000000001',
    'b0340000-0000-0000-0000-000000000001',
    'd0340000-0000-0000-0000-000000000001',
    'f0340000-0000-0000-0000-000000000001',
    '2026-07-21', -- dimarts sense patró
    'published', '10:00', '14:00', now()
  );

  r := data.resolve_employee_work_plan(
    'd0340000-0000-0000-0000-000000000001', '2026-07-21'::date
  );

  IF r->>'day_type' = 'working'
     AND r->>'labor_source' = 'published_shift'
     AND (r->>'expected_minutes')::int = 240
  THEN
    INSERT INTO ex033_results VALUES ('T4 slots omplen dia undefined', 'PASS',
      format('minutes=%s', r->>'expected_minutes'));
  ELSE
    INSERT INTO ex033_results VALUES ('T4 slots omplen dia undefined', 'FAIL', r::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex033_results VALUES ('T4 slots omplen dia undefined', 'ERROR', SQLERRM);
END $$;

-- =============================================================================
-- T5: slots published NO converteixen festiu en work
-- 2026-07-20 = dilluns + festiu assignat
-- =============================================================================
DO $$
DECLARE
  r jsonb;
BEGIN
  INSERT INTO data.shift_slots (
    tenant_id, site_id, employee_id, shift_id,
    slot_date, status, start_time, end_time, published_at
  ) VALUES (
    'a0340000-0000-0000-0000-000000000001',
    'b0340000-0000-0000-0000-000000000001',
    'd0340000-0000-0000-0000-000000000001',
    'f0340000-0000-0000-0000-000000000001',
    '2026-07-20', 'published', '10:00', '14:00', now()
  );

  r := data.resolve_employee_work_plan(
    'd0340000-0000-0000-0000-000000000001', '2026-07-20'::date
  );

  IF r->>'day_type' = 'holiday'
     AND r->>'labor_source' = 'assigned_holiday'
     AND (r->>'expected_minutes')::int = 0
     AND jsonb_array_length(r->'published_slot_ids') = 1
  THEN
    INSERT INTO ex033_results VALUES ('T5 slots no converteixen festiu', 'PASS',
      format('day_type=%s slots=%s', r->>'day_type', r->'published_slot_ids'));
  ELSE
    INSERT INTO ex033_results VALUES ('T5 slots no converteixen festiu', 'FAIL', r::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex033_results VALUES ('T5 slots no converteixen festiu', 'ERROR', SQLERRM);
END $$;

-- =============================================================================
-- T6: múltiples slots published → intervals múltiples
-- =============================================================================
DO $$
DECLARE
  r jsonb;
BEGIN
  -- Dilluns 2026-07-27: base work + dos slots
  INSERT INTO data.shift_slots (
    tenant_id, site_id, employee_id, shift_id,
    slot_date, status, start_time, end_time, published_at
  ) VALUES
    ('a0340000-0000-0000-0000-000000000001', 'b0340000-0000-0000-0000-000000000001',
     'd0340000-0000-0000-0000-000000000001', 'f0340000-0000-0000-0000-000000000001',
     '2026-07-27', 'published', '10:00', '14:00', now()),
    ('a0340000-0000-0000-0000-000000000001', 'b0340000-0000-0000-0000-000000000001',
     'd0340000-0000-0000-0000-000000000001', 'f0340000-0000-0000-0000-000000000002',
     '2026-07-27', 'published', '15:00', '19:00', now());

  r := data.resolve_employee_work_plan(
    'd0340000-0000-0000-0000-000000000001', '2026-07-27'::date
  );

  IF r->>'labor_source' = 'published_shift'
     AND jsonb_array_length(r->'work_intervals') = 2
     AND (r->>'expected_minutes')::int = 480
     AND jsonb_array_length(r->'published_slot_ids') = 2
  THEN
    INSERT INTO ex033_results VALUES ('T6 múltiples slots = intervals múltiples', 'PASS',
      format('intervals=%s minutes=%s', r->'work_intervals', r->>'expected_minutes'));
  ELSE
    INSERT INTO ex033_results VALUES ('T6 múltiples slots = intervals múltiples', 'FAIL', r::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex033_results VALUES ('T6 múltiples slots = intervals múltiples', 'ERROR', SQLERRM);
END $$;

-- =============================================================================
-- T7: absència aprovada guanya a slots published
-- =============================================================================
DO $$
DECLARE
  r jsonb;
BEGIN
  INSERT INTO data.employee_absences (
    id, tenant_id, site_id, employee_id, absence_type,
    start_date, end_date, status, is_paid, requested_by
  ) VALUES (
    'a0340005-0000-0000-0000-000000000001',
    'a0340000-0000-0000-0000-000000000001',
    'b0340000-0000-0000-0000-000000000001',
    'd0340000-0000-0000-0000-000000000001',
    'vacation',
    '2026-07-27', '2026-07-27', 'approved', true,
    'c0340000-0000-0000-0000-000000000001'
  );

  r := data.resolve_employee_work_plan(
    'd0340000-0000-0000-0000-000000000001', '2026-07-27'::date
  );

  IF r->>'day_type' = 'absence'
     AND r->>'labor_source' = 'absence'
     AND (r->>'is_absence')::boolean = true
  THEN
    INSERT INTO ex033_results VALUES ('T7 absència > slots published', 'PASS',
      format('type=%s', r->>'absence_type'));
  ELSE
    INSERT INTO ex033_results VALUES ('T7 absència > slots published', 'FAIL', r::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex033_results VALUES ('T7 absència > slots published', 'ERROR', SQLERRM);
END $$;

-- =============================================================================
-- Summary
-- =============================================================================
SELECT test_name, status, details FROM ex033_results ORDER BY test_name;

SELECT
  count(*) FILTER (WHERE status = 'PASS')  AS passed,
  count(*) FILTER (WHERE status = 'FAIL')  AS failed,
  count(*) FILTER (WHERE status = 'ERROR') AS errors,
  count(*) AS total
FROM ex033_results;

ROLLBACK;
