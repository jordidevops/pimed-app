-- =============================================================================
-- attendance_weekly_recurring_base_adr0003_tests.sql
-- ADR-0003 — Base recurrent setmanal (calendar_group_weekly_intervals +
-- employee_weekly_intervals). Caracteritza la cascada completa de
-- data.resolve_schedule_planner_day amb les noves capes.
-- ADR: docs/plans/checkin/adr-0003-weekly-recurring-base.md
--
-- Cascada (prioritat decreixent):
--   1) employee_override (labor_calendar_overrides, puntual)
--   2) group_site_override / site_override / group_global_override / tenant_override (puntuals)
--   3) assigned_holiday (festiu assignat — guanya a la base recurrent)
--   4) employee_weekly (recurrent individual)
--   5) calendar_group_weekly (recurrent de grup)
--   6) undefined
--
-- Executar contra DB local:
--   Get-Content supabase/tests/attendance_weekly_recurring_base_adr0003_tests.sql |
--     docker exec -i supabase_db_cavalle-app psql -U postgres -d postgres -v ON_ERROR_STOP=0
--
-- Tests:
--   T1  calendar_group_weekly sense cap altra capa → 'work' via base de grup
--   T2  day_type='non_working' explícit al grup (cap de setmana) ≠ 'undefined'
--   T3  employee_weekly guanya a calendar_group_weekly (mateix dia, grups diferents patrons)
--   T4  labor_calendar_overrides puntual guanya a employee_weekly
--   T5  assigned_holiday guanya a employee_weekly i a calendar_group_weekly
--   T6  cap patró definit per aquell day_of_week (ni grup ni empleat) → 'undefined'
--   T7  valid_from/valid_to — un patró futur no s'aplica abans de la data d'efecte
--   T8  api.set_calendar_group_weekly_day — permís insuficient rebutjat
--   T9  api.set_calendar_group_weekly_day — manager pot escriure i el resolver ho reflecteix
-- =============================================================================

BEGIN;

CREATE TEMP TABLE adr3_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0330000-0000-0000-0000-000000000001', 'ADR3 Tenant', 'adr3-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b0330000-0000-0000-0000-000000000001', 'a0330000-0000-0000-0000-000000000001', 'ADR3 Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0330000-0000-0000-0000-000000000001', 'emp1@adr3.test', 'authenticated', 'authenticated'),
  ('c0330000-0000-0000-0000-000000000002', 'emp2@adr3.test', 'authenticated', 'authenticated'),
  ('c0330000-0000-0000-0000-000000000003', 'mgr@adr3.test',  'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0330000-0000-0000-0000-000000000001', 'emp1@adr3.test', 'Emp1 ADR3'),
  ('c0330000-0000-0000-0000-000000000002', 'emp2@adr3.test', 'Emp2 ADR3'),
  ('c0330000-0000-0000-0000-000000000003', 'mgr@adr3.test',  'Mgr ADR3')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0330000-0000-0000-0000-000000000001', 'c0330000-0000-0000-0000-000000000001', 'member',  true),
  (gen_random_uuid(), 'a0330000-0000-0000-0000-000000000001', 'c0330000-0000-0000-0000-000000000002', 'member',  true),
  (gen_random_uuid(), 'a0330000-0000-0000-0000-000000000001', 'c0330000-0000-0000-0000-000000000003', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.calendar_groups (id, tenant_id, site_id, name, color, sort_order)
VALUES
  ('e0330000-0000-0000-0000-000000000001', 'a0330000-0000-0000-0000-000000000001', NULL, 'Grup A', '#3b82f6', 1),
  ('e0330000-0000-0000-0000-000000000002', 'a0330000-0000-0000-0000-000000000001', NULL, 'Grup B', '#10b981', 2)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status, calendar_group_id)
VALUES
  ('d0330000-0000-0000-0000-000000000001', 'a0330000-0000-0000-0000-000000000001',
   'b0330000-0000-0000-0000-000000000001', 'c0330000-0000-0000-0000-000000000001',
   'Emp1 ADR3', 'active', 'e0330000-0000-0000-0000-000000000001'),
  ('d0330000-0000-0000-0000-000000000002', 'a0330000-0000-0000-0000-000000000001',
   'b0330000-0000-0000-0000-000000000001', 'c0330000-0000-0000-0000-000000000002',
   'Emp2 ADR3', 'active', 'e0330000-0000-0000-0000-000000000001')
ON CONFLICT (id) DO NOTHING;

-- Grup A: Dl (DOW=1) 09:00-17:00 laborable, Dg (DOW=0) non_working explícit
INSERT INTO data.calendar_group_weekly_intervals (
  tenant_id, group_id, day_of_week, day_type, work_start, work_end, work_intervals, valid_from
)
VALUES
  ('a0330000-0000-0000-0000-000000000001', 'e0330000-0000-0000-0000-000000000001', 1, 'work',
   '09:00', '17:00', '[{"start":"09:00","end":"17:00"}]'::jsonb, '2020-01-01'),
  ('a0330000-0000-0000-0000-000000000001', 'e0330000-0000-0000-0000-000000000001', 0, 'non_working',
   NULL, NULL, NULL, '2020-01-01')
ON CONFLICT ON CONSTRAINT uq_cgwi_group_dow_from DO NOTHING;

-- Grup B: Dl (DOW=1) 07:00-15:00 (patró diferent de Grup A, per T3)
INSERT INTO data.calendar_group_weekly_intervals (
  tenant_id, group_id, day_of_week, day_type, work_start, work_end, work_intervals, valid_from
)
VALUES
  ('a0330000-0000-0000-0000-000000000001', 'e0330000-0000-0000-0000-000000000002', 1, 'work',
   '07:00', '15:00', '[{"start":"07:00","end":"15:00"}]'::jsonb, '2020-01-01')
ON CONFLICT ON CONSTRAINT uq_cgwi_group_dow_from DO NOTHING;

-- Emp2: override individual Dl (DOW=1) 06:00-14:00 (diferent del seu grup A: 09:00-17:00)
INSERT INTO data.employee_weekly_intervals (
  tenant_id, employee_id, day_of_week, day_type, work_start, work_end, work_intervals, valid_from
)
VALUES
  ('a0330000-0000-0000-0000-000000000001', 'd0330000-0000-0000-0000-000000000002', 1, 'work',
   '06:00', '14:00', '[{"start":"06:00","end":"14:00"}]'::jsonb, '2020-01-01')
ON CONFLICT ON CONSTRAINT uq_ewi_employee_dow_from DO NOTHING;

-- Festiu assignat el 2026-07-20 (Dilluns) per al site
INSERT INTO data.holiday_calendars (id, tenant_id, name, country_code, year, is_active)
VALUES ('f0330000-0000-0000-0000-000000000001', 'a0330000-0000-0000-0000-000000000001',
        'Festius ADR3', 'ES', 2026, true)
ON CONFLICT DO NOTHING;

INSERT INTO data.holidays (calendar_id, date, name, holiday_type)
VALUES ('f0330000-0000-0000-0000-000000000001', '2026-07-20', 'Festiu ADR3 Test', 'tenant_custom')
ON CONFLICT (calendar_id, date) DO NOTHING;

INSERT INTO data.site_holiday_calendar_assignments (site_id, calendar_id, priority)
VALUES ('b0330000-0000-0000-0000-000000000001', 'f0330000-0000-0000-0000-000000000001', 10)
ON CONFLICT (site_id, calendar_id) DO NOTHING;

-- 2026-07-06 (Dilluns) — punctual override per Emp1 (per T4)
INSERT INTO data.labor_calendar_overrides (
  tenant_id, site_id, group_id, employee_id, calendar_date, day_type, day_name, work_intervals
) VALUES (
  'a0330000-0000-0000-0000-000000000001', 'b0330000-0000-0000-0000-000000000001',
  NULL, 'd0330000-0000-0000-0000-000000000002',
  '2026-07-06', 'work', 'Puntual ADR3', '[{"start":"10:00","end":"12:00"}]'::jsonb
) ON CONFLICT ON CONSTRAINT labor_calendar_overrides_unique DO NOTHING;


-- =============================================================================
-- T1: calendar_group_weekly sense cap altra capa → 'work' via base de grup
-- =============================================================================
DO $$
DECLARE
  r record;
BEGIN
  -- 2026-07-13 (Dilluns) Emp1 (Grup A) — cap override, cap festiu
  SELECT * INTO r FROM data.resolve_schedule_planner_day(
    'a0330000-0000-0000-0000-000000000001', 'b0330000-0000-0000-0000-000000000001',
    'd0330000-0000-0000-0000-000000000001',
    'e0330000-0000-0000-0000-000000000001', NULL,
    '2026-07-13', NULL
  );

  IF r.day_type = 'work' AND r.source = 'calendar_group_weekly' AND r.planned_minutes = 480 THEN
    INSERT INTO adr3_results VALUES ('T1 calendar_group_weekly base', 'PASS',
      format('day_type=%s source=%s minutes=%s', r.day_type, r.source, r.planned_minutes));
  ELSE
    INSERT INTO adr3_results VALUES ('T1 calendar_group_weekly base', 'FAIL',
      format('day_type=%s source=%s minutes=%s', r.day_type, r.source, r.planned_minutes));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO adr3_results VALUES ('T1 calendar_group_weekly base', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T2: day_type='non_working' explícit (Grup A, diumenge) ≠ 'undefined'
-- =============================================================================
DO $$
DECLARE
  r record;
BEGIN
  -- 2026-07-12 (Diumenge)
  SELECT * INTO r FROM data.resolve_schedule_planner_day(
    'a0330000-0000-0000-0000-000000000001', 'b0330000-0000-0000-0000-000000000001',
    'd0330000-0000-0000-0000-000000000001',
    'e0330000-0000-0000-0000-000000000001', NULL,
    '2026-07-12', NULL
  );

  IF r.day_type = 'non_working' AND r.source = 'calendar_group_weekly' AND r.planned_minutes = 0 THEN
    INSERT INTO adr3_results VALUES ('T2 non_working explícit', 'PASS',
      format('day_type=%s source=%s', r.day_type, r.source));
  ELSE
    INSERT INTO adr3_results VALUES ('T2 non_working explícit', 'FAIL',
      format('day_type=%s source=%s minutes=%s', r.day_type, r.source, r.planned_minutes));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO adr3_results VALUES ('T2 non_working explícit', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T3: employee_weekly guanya a calendar_group_weekly
-- =============================================================================
DO $$
DECLARE
  r record;
BEGIN
  -- 2026-07-13 (Dilluns) Emp2 (Grup A: 09:00-17:00, però override individual 06:00-14:00)
  SELECT * INTO r FROM data.resolve_schedule_planner_day(
    'a0330000-0000-0000-0000-000000000001', 'b0330000-0000-0000-0000-000000000001',
    'd0330000-0000-0000-0000-000000000002',
    'e0330000-0000-0000-0000-000000000001', NULL,
    '2026-07-13', NULL
  );

  IF r.source = 'employee_weekly'
     AND (r.work_intervals->0->>'start') = '06:00'
     AND (r.work_intervals->0->>'end') = '14:00'
  THEN
    INSERT INTO adr3_results VALUES ('T3 employee_weekly > calendar_group_weekly', 'PASS',
      format('source=%s intervals=%s', r.source, r.work_intervals));
  ELSE
    INSERT INTO adr3_results VALUES ('T3 employee_weekly > calendar_group_weekly', 'FAIL',
      format('source=%s intervals=%s', r.source, r.work_intervals));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO adr3_results VALUES ('T3 employee_weekly > calendar_group_weekly', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T4: labor_calendar_overrides puntual guanya a employee_weekly
-- =============================================================================
DO $$
DECLARE
  r record;
BEGIN
  -- 2026-07-06 (Dilluns) Emp2 — override puntual 10:00-12:00 (vs employee_weekly 06:00-14:00)
  SELECT * INTO r FROM data.resolve_schedule_planner_day(
    'a0330000-0000-0000-0000-000000000001', 'b0330000-0000-0000-0000-000000000001',
    'd0330000-0000-0000-0000-000000000002',
    'e0330000-0000-0000-0000-000000000001', NULL,
    '2026-07-06', NULL
  );

  IF r.source = 'employee_override'
     AND (r.work_intervals->0->>'start') = '10:00'
     AND r.planned_minutes = 120
  THEN
    INSERT INTO adr3_results VALUES ('T4 employee_override puntual > employee_weekly', 'PASS',
      format('source=%s minutes=%s', r.source, r.planned_minutes));
  ELSE
    INSERT INTO adr3_results VALUES ('T4 employee_override puntual > employee_weekly', 'FAIL',
      format('source=%s minutes=%s intervals=%s', r.source, r.planned_minutes, r.work_intervals));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO adr3_results VALUES ('T4 employee_override puntual > employee_weekly', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T5: assigned_holiday guanya a employee_weekly i calendar_group_weekly
-- =============================================================================
DO $$
DECLARE
  r_emp1 record;
  r_emp2 record;
BEGIN
  -- 2026-07-20 (Dilluns, festiu assignat). Emp1 (calendar_group_weekly) i Emp2 (employee_weekly)
  -- haurien de resoldre a 'holiday' malgrat tenir patró recurrent laborable aquell dia.
  SELECT * INTO r_emp1 FROM data.resolve_schedule_planner_day(
    'a0330000-0000-0000-0000-000000000001', 'b0330000-0000-0000-0000-000000000001',
    'd0330000-0000-0000-0000-000000000001',
    'e0330000-0000-0000-0000-000000000001', NULL,
    '2026-07-20', 'Festiu ADR3 Test'
  );
  SELECT * INTO r_emp2 FROM data.resolve_schedule_planner_day(
    'a0330000-0000-0000-0000-000000000001', 'b0330000-0000-0000-0000-000000000001',
    'd0330000-0000-0000-0000-000000000002',
    'e0330000-0000-0000-0000-000000000001', NULL,
    '2026-07-20', 'Festiu ADR3 Test'
  );

  IF r_emp1.day_type = 'holiday' AND r_emp1.source = 'assigned_holiday'
     AND r_emp2.day_type = 'holiday' AND r_emp2.source = 'assigned_holiday'
  THEN
    INSERT INTO adr3_results VALUES ('T5 assigned_holiday > base recurrent', 'PASS',
      format('emp1=%s/%s emp2=%s/%s', r_emp1.day_type, r_emp1.source, r_emp2.day_type, r_emp2.source));
  ELSE
    INSERT INTO adr3_results VALUES ('T5 assigned_holiday > base recurrent', 'FAIL',
      format('emp1=%s/%s emp2=%s/%s', r_emp1.day_type, r_emp1.source, r_emp2.day_type, r_emp2.source));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO adr3_results VALUES ('T5 assigned_holiday > base recurrent', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T6: cap patró definit per aquell day_of_week (Grup B, no DOW=2) → 'undefined'
-- =============================================================================
DO $$
DECLARE
  r record;
BEGIN
  -- 2026-07-14 (Dimarts, DOW=2). Grup B només té patró per DOW=1.
  SELECT * INTO r FROM data.resolve_schedule_planner_day(
    'a0330000-0000-0000-0000-000000000001', 'b0330000-0000-0000-0000-000000000001',
    NULL,
    'e0330000-0000-0000-0000-000000000002', NULL,
    '2026-07-14', NULL
  );

  IF r.day_type = 'undefined' AND r.source = 'none' THEN
    INSERT INTO adr3_results VALUES ('T6 cap patró definit → undefined', 'PASS',
      format('day_type=%s source=%s', r.day_type, r.source));
  ELSE
    INSERT INTO adr3_results VALUES ('T6 cap patró definit → undefined', 'FAIL',
      format('day_type=%s source=%s', r.day_type, r.source));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO adr3_results VALUES ('T6 cap patró definit → undefined', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T7: valid_from/valid_to — un patró futur no s'aplica abans de la data d'efecte
-- =============================================================================
DO $$
DECLARE
  r_before record;
  r_after  record;
BEGIN
  -- Grup B: nou patró Dl (DOW=1) 12:00-20:00 vigent a partir de 2027-01-01
  INSERT INTO data.calendar_group_weekly_intervals (
    tenant_id, group_id, day_of_week, day_type, work_start, work_end, work_intervals, valid_from
  ) VALUES (
    'a0330000-0000-0000-0000-000000000001', 'e0330000-0000-0000-0000-000000000002', 1, 'work',
    '12:00', '20:00', '[{"start":"12:00","end":"20:00"}]'::jsonb, '2027-01-01'
  ) ON CONFLICT ON CONSTRAINT uq_cgwi_group_dow_from DO NOTHING;

  -- Abans de la data d'efecte: hauria de seguir aplicant-se el patró antic (07:00-15:00)
  SELECT * INTO r_before FROM data.resolve_schedule_planner_day(
    'a0330000-0000-0000-0000-000000000001', 'b0330000-0000-0000-0000-000000000001',
    NULL, 'e0330000-0000-0000-0000-000000000002', NULL,
    '2026-07-13', NULL
  );

  -- Després: el nou patró
  SELECT * INTO r_after FROM data.resolve_schedule_planner_day(
    'a0330000-0000-0000-0000-000000000001', 'b0330000-0000-0000-0000-000000000001',
    NULL, 'e0330000-0000-0000-0000-000000000002', NULL,
    '2027-01-04', NULL
  );

  IF (r_before.work_intervals->0->>'start') = '07:00'
     AND (r_after.work_intervals->0->>'start') = '12:00'
  THEN
    INSERT INTO adr3_results VALUES ('T7 valid_from respecta l''efecte temporal', 'PASS',
      format('abans=%s despres=%s', r_before.work_intervals, r_after.work_intervals));
  ELSE
    INSERT INTO adr3_results VALUES ('T7 valid_from respecta l''efecte temporal', 'FAIL',
      format('abans=%s despres=%s', r_before.work_intervals, r_after.work_intervals));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO adr3_results VALUES ('T7 valid_from respecta l''efecte temporal', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T8: api.set_calendar_group_weekly_day — permís insuficient rebutjat
-- =============================================================================
DO $$
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0330000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"a0330000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  PERFORM api.set_calendar_group_weekly_day(
    'e0330000-0000-0000-0000-000000000001'::uuid, 3::smallint, 'work'::text,
    '[{"start":"10:00","end":"18:00"}]'::jsonb, '2026-01-01'::date
  );

  SET LOCAL ROLE postgres;
  INSERT INTO adr3_results VALUES ('T8 set_calendar_group_weekly_day sense permís', 'FAIL',
    'Expected insufficient_privilege not raised');
EXCEPTION WHEN insufficient_privilege THEN
  SET LOCAL ROLE postgres;
  INSERT INTO adr3_results VALUES ('T8 set_calendar_group_weekly_day sense permís', 'PASS',
    format('Exception: %s', SQLERRM));
WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO adr3_results VALUES ('T8 set_calendar_group_weekly_day sense permís', 'FAIL',
    format('Wrong exception: %s', SQLERRM));
END $$;


-- =============================================================================
-- T9: api.set_calendar_group_weekly_day — manager escriu i el resolver ho reflecteix
-- =============================================================================
DO $$
DECLARE
  r record;
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0330000-0000-0000-0000-000000000003","app_metadata":{"user_tenants":{"a0330000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0330000-0000-0000-0000-000000000001":["labor_calendar.manage"]}}}',
    true);
  SET LOCAL ROLE authenticated;

  -- Grup A: nou patró de dimecres (DOW=3) 10:00-18:00, vigent des de 2020-01-01
  PERFORM api.set_calendar_group_weekly_day(
    'e0330000-0000-0000-0000-000000000001'::uuid, 3::smallint, 'work'::text,
    '[{"start":"10:00","end":"18:00"}]'::jsonb, '2020-01-01'::date
  );

  SET LOCAL ROLE postgres;

  SELECT * INTO r FROM data.resolve_schedule_planner_day(
    'a0330000-0000-0000-0000-000000000001', 'b0330000-0000-0000-0000-000000000001',
    'd0330000-0000-0000-0000-000000000001',
    'e0330000-0000-0000-0000-000000000001', NULL,
    '2026-07-15', NULL  -- Dimecres
  );

  IF r.source = 'calendar_group_weekly' AND r.planned_minutes = 480 THEN
    INSERT INTO adr3_results VALUES ('T9 manager escriu i resolver reflecteix', 'PASS',
      format('source=%s minutes=%s', r.source, r.planned_minutes));
  ELSE
    INSERT INTO adr3_results VALUES ('T9 manager escriu i resolver reflecteix', 'FAIL',
      format('source=%s minutes=%s', r.source, r.planned_minutes));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO adr3_results VALUES ('T9 manager escriu i resolver reflecteix', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- Resultat final
-- =============================================================================

SELECT test_name, status, details FROM adr3_results ORDER BY test_name;

SELECT
  COUNT(*) FILTER (WHERE status = 'PASS')  AS passed,
  COUNT(*) FILTER (WHERE status = 'FAIL')  AS failed,
  COUNT(*) FILTER (WHERE status = 'ERROR') AS errors,
  COUNT(*)                                 AS total
FROM adr3_results;

ROLLBACK;
