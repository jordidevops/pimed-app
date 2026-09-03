-- =============================================================================
-- attendance_calendar_tests.sql
-- SP-0 / EX-03.1 — Caracterització del resolver VIGENT (labor calendar).
-- ADR: docs/plans/checkin/adr-0001-work-plan-source-of-truth.md
-- ADR: docs/plans/checkin/adr-0003-weekly-recurring-base.md
--
-- Font de veritat: api.resolve_work_day → resolve_labor_calendar_for_employee
--   → resolve_schedule_planner_day (overrides puntuals > base recurrent
--   setmanal [ADR-0003: employee_weekly_intervals > calendar_group_weekly_intervals]
--   > festius). work_schedules / employee_schedule_assignments (legacy,
--   mai van alimentar el resolver) es van retirar a ADR-0003.
--
-- Executar contra DB local:
--   Get-Content supabase/tests/attendance_calendar_tests.sql |
--     docker exec -i supabase_db_cavalle-app psql -U postgres -d postgres -v ON_ERROR_STOP=0
--
-- Tests:
--   T0  ADR-0003 — calendar_group_weekly_intervals SÍ alimenta el resolver
--   T1  resolve_work_day — dia laborable via labor_calendar_overrides 09:00-18:00
--   T2  resolve_work_day — diumenge sense override → unknown
--   T2b resolve_work_day — diumenge amb override leave → non_working
--   T3  resolve_work_day — festiu (holiday assignat al site)
--   T4  resolve_work_day — absència aprovada (prioritat)
--   T5  resolve_work_day — torn nocturn 22:00-06:00 (spans_midnight)
--   T5b resolve_work_day — site_timezone exposat (Europe/Madrid per defecte)
--   T6  request_absence — sol·licitud correcta d'un empleat propi
--   T7  request_absence — rebutjat si solapament (tipus actiu personal_days)
--   T8  approve_absence — membre sense permís → rebutjat
--   T9  approve_absence — manager aprova
--   T10 import_holidays — Nager.Date
--   T11 ADR-0003 — employee_weekly_intervals té prioritat sobre calendar_group_weekly_intervals
--   T12 resolve_work_day — HR guard (member no veu altre empleat)
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('aa000000-0000-0000-0000-000000000001', 'Cal Tenant', 'cal-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('bb000000-0000-0000-0000-000000000001', 'aa000000-0000-0000-0000-000000000001', 'Cal Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('cc000000-0000-0000-0000-000000000001', 'emp1@cal.test',  'authenticated', 'authenticated'),
  ('cc000000-0000-0000-0000-000000000002', 'emp2@cal.test',  'authenticated', 'authenticated'),
  ('cc000000-0000-0000-0000-000000000003', 'mgr1@cal.test',  'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('cc000000-0000-0000-0000-000000000001', 'emp1@cal.test',  'Emp1 Cal'),
  ('cc000000-0000-0000-0000-000000000002', 'emp2@cal.test',  'Emp2 Cal'),
  ('cc000000-0000-0000-0000-000000000003', 'mgr1@cal.test',  'Mgr1 Cal')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'aa000000-0000-0000-0000-000000000001', 'cc000000-0000-0000-0000-000000000001', 'member',  true),
  (gen_random_uuid(), 'aa000000-0000-0000-0000-000000000001', 'cc000000-0000-0000-0000-000000000002', 'member',  true),
  (gen_random_uuid(), 'aa000000-0000-0000-0000-000000000001', 'cc000000-0000-0000-0000-000000000003', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES
  ('dd000000-0000-0000-0000-000000000001', 'aa000000-0000-0000-0000-000000000001', 'bb000000-0000-0000-0000-000000000001', 'cc000000-0000-0000-0000-000000000001', 'Emp1 Day',   'active'),
  ('dd000000-0000-0000-0000-000000000002', 'aa000000-0000-0000-0000-000000000001', 'bb000000-0000-0000-0000-000000000001', 'cc000000-0000-0000-0000-000000000002', 'Emp2 Night', 'active')
ON CONFLICT (id) DO NOTHING;

-- ADR-0003: Grup de calendari amb base recurrent Dl-Dv 09:00-18:00
INSERT INTO data.calendar_groups (id, tenant_id, site_id, name, color, sort_order)
VALUES ('ee000000-0000-0000-0000-000000000001', 'aa000000-0000-0000-0000-000000000001',
        'bb000000-0000-0000-0000-000000000001', 'Jornada Dia', '#3b82f6', 1)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.calendar_group_weekly_intervals (
  tenant_id, group_id, day_of_week, day_type, work_start, work_end, work_intervals, valid_from
)
VALUES
  ('aa000000-0000-0000-0000-000000000001', 'ee000000-0000-0000-0000-000000000001', 1, 'work',
   '09:00', '18:00', '[{"start":"09:00","end":"18:00"}]'::jsonb, '2020-01-01'),
  ('aa000000-0000-0000-0000-000000000001', 'ee000000-0000-0000-0000-000000000001', 2, 'work',
   '09:00', '18:00', '[{"start":"09:00","end":"18:00"}]'::jsonb, '2020-01-01'),
  ('aa000000-0000-0000-0000-000000000001', 'ee000000-0000-0000-0000-000000000001', 3, 'work',
   '09:00', '18:00', '[{"start":"09:00","end":"18:00"}]'::jsonb, '2020-01-01'),
  ('aa000000-0000-0000-0000-000000000001', 'ee000000-0000-0000-0000-000000000001', 4, 'work',
   '09:00', '18:00', '[{"start":"09:00","end":"18:00"}]'::jsonb, '2020-01-01'),
  ('aa000000-0000-0000-0000-000000000001', 'ee000000-0000-0000-0000-000000000001', 5, 'work',
   '09:00', '18:00', '[{"start":"09:00","end":"18:00"}]'::jsonb, '2020-01-01')
ON CONFLICT ON CONSTRAINT uq_cgwi_group_dow_from DO NOTHING;

-- Emp1 pertany al grup "Jornada Dia"
UPDATE data.employees SET calendar_group_id = 'ee000000-0000-0000-0000-000000000001'
WHERE id = 'dd000000-0000-0000-0000-000000000001';

-- ADR-0003: override individual (employee_weekly) de Emp2 — torn nocturn Dl-Dv 22:00-06:00,
-- amb prioritat sobre el patró del seu grup (Emp2 no pertany a "Jornada Dia").
INSERT INTO data.employee_weekly_intervals (
  tenant_id, employee_id, day_of_week, day_type, work_start, work_end, work_intervals, valid_from
)
VALUES
  ('aa000000-0000-0000-0000-000000000001', 'dd000000-0000-0000-0000-000000000002', 1, 'work',
   '22:00', '06:00', '[{"start":"22:00","end":"06:00"}]'::jsonb, '2020-01-01'),
  ('aa000000-0000-0000-0000-000000000001', 'dd000000-0000-0000-0000-000000000002', 2, 'work',
   '22:00', '06:00', '[{"start":"22:00","end":"06:00"}]'::jsonb, '2020-01-01'),
  ('aa000000-0000-0000-0000-000000000001', 'dd000000-0000-0000-0000-000000000002', 3, 'work',
   '22:00', '06:00', '[{"start":"22:00","end":"06:00"}]'::jsonb, '2020-01-01'),
  ('aa000000-0000-0000-0000-000000000001', 'dd000000-0000-0000-0000-000000000002', 4, 'work',
   '22:00', '06:00', '[{"start":"22:00","end":"06:00"}]'::jsonb, '2020-01-01'),
  ('aa000000-0000-0000-0000-000000000001', 'dd000000-0000-0000-0000-000000000002', 5, 'work',
   '22:00', '06:00', '[{"start":"22:00","end":"06:00"}]'::jsonb, '2020-01-01')
ON CONFLICT ON CONSTRAINT uq_ewi_employee_dow_from DO NOTHING;

-- Emp2 pertany també al grup "Jornada Dia" (per demostrar T11: l'override
-- individual (employee_weekly) guanya al patró del grup (calendar_group_weekly)).
UPDATE data.employees SET calendar_group_id = 'ee000000-0000-0000-0000-000000000001'
WHERE id = 'dd000000-0000-0000-0000-000000000002';

-- Calendari de festius del site (tenant-specific)
INSERT INTO data.holiday_calendars (id, tenant_id, name, country_code, year, is_active)
VALUES ('ac000000-0000-0000-0000-000000000001', 'aa000000-0000-0000-0000-000000000001',
        'Festius Cal 2026', 'ES', 2026, true)
ON CONFLICT DO NOTHING;

-- Festiu: 2026-01-06 (Reis) i 2026-04-23 (Sant Jordi, dijous)
INSERT INTO data.holidays (calendar_id, date, name, holiday_type)
VALUES
  ('ac000000-0000-0000-0000-000000000001', '2026-01-06', 'Reis Mags', 'national'),
  ('ac000000-0000-0000-0000-000000000001', '2026-04-23', 'Sant Jordi', 'regional')
ON CONFLICT (calendar_id, date) DO NOTHING;

-- Assignar el calendari al site
INSERT INTO data.site_holiday_calendar_assignments (site_id, calendar_id, priority)
VALUES ('bb000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-000000000001', 10)
ON CONFLICT (site_id, calendar_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Labor calendar overrides = font de veritat del resolver actual
-- (work_schedules de dalt NO alimenten resolve_work_day)
-- ---------------------------------------------------------------------------

-- Emp1: dijous 2026-01-15 laboral 09:00-18:00 (540 min)
INSERT INTO data.labor_calendar_overrides (
  tenant_id, site_id, group_id, employee_id,
  calendar_date, day_type, day_name,
  work_start, work_end, work_intervals
) VALUES (
  'aa000000-0000-0000-0000-000000000001',
  'bb000000-0000-0000-0000-000000000001',
  NULL, 'dd000000-0000-0000-0000-000000000001',
  '2026-01-15', 'work', 'Laboral SP-0',
  '09:00'::time, '18:00'::time,
  '[{"start":"09:00","end":"18:00"}]'::jsonb
) ON CONFLICT ON CONSTRAINT labor_calendar_overrides_unique DO UPDATE SET
  day_type = EXCLUDED.day_type,
  work_start = EXCLUDED.work_start,
  work_end = EXCLUDED.work_end,
  work_intervals = EXCLUDED.work_intervals,
  day_name = EXCLUDED.day_name;

-- Emp2: dilluns 2026-01-19 nocturn 22:00-06:00 (480 min)
INSERT INTO data.labor_calendar_overrides (
  tenant_id, site_id, group_id, employee_id,
  calendar_date, day_type, day_name,
  work_start, work_end, work_intervals
) VALUES (
  'aa000000-0000-0000-0000-000000000001',
  'bb000000-0000-0000-0000-000000000001',
  NULL, 'dd000000-0000-0000-0000-000000000002',
  '2026-01-19', 'work', 'Nocturn SP-0',
  '22:00'::time, '06:00'::time,
  '[{"start":"22:00","end":"06:00"}]'::jsonb
) ON CONFLICT ON CONSTRAINT labor_calendar_overrides_unique DO UPDATE SET
  day_type = EXCLUDED.day_type,
  work_start = EXCLUDED.work_start,
  work_end = EXCLUDED.work_end,
  work_intervals = EXCLUDED.work_intervals,
  day_name = EXCLUDED.day_name;

-- Diumenge amb leave explícit (T2b) — 2026-01-25
INSERT INTO data.labor_calendar_overrides (
  tenant_id, site_id, group_id, employee_id,
  calendar_date, day_type, day_name, work_intervals
) VALUES (
  'aa000000-0000-0000-0000-000000000001',
  'bb000000-0000-0000-0000-000000000001',
  NULL, 'dd000000-0000-0000-0000-000000000001',
  '2026-01-25', 'leave', 'Descans SP-0', '[]'::jsonb
) ON CONFLICT ON CONSTRAINT labor_calendar_overrides_unique DO UPDATE SET
  day_type = EXCLUDED.day_type,
  day_name = EXCLUDED.day_name,
  work_intervals = EXCLUDED.work_intervals;

-- Taula de resultats
CREATE TEMP TABLE cal_test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;


-- =============================================================================
-- T0: ADR-0003 — calendar_group_weekly_intervals SÍ alimenta el resolver
-- =============================================================================
DO $$
DECLARE
  v_result  jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"cc000000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"aa000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  -- Dimecres 2026-01-14: Emp1 (grup "Jornada Dia" 09:00-18:00), SENSE labor override puntual
  -- per aquest dia → hauria de resoldre via la base recurrent de grup (calendar_group_weekly).
  v_result := api.resolve_work_day(
    'dd000000-0000-0000-0000-000000000001',
    '2026-01-14'
  );

  SET LOCAL ROLE postgres;

  IF v_result->>'day_type' = 'working'
     AND (v_result->>'expected_minutes')::int = 540
     AND v_result->>'labor_source' = 'calendar_group_weekly'
  THEN
    INSERT INTO cal_test_results VALUES ('T0 calendar_group_weekly alimenta resolver', 'PASS',
      format('day_type=%s expected=%s labor_source=%s',
             v_result->>'day_type', v_result->>'expected_minutes', v_result->>'labor_source'));
  ELSE
    INSERT INTO cal_test_results VALUES ('T0 calendar_group_weekly alimenta resolver', 'FAIL',
      format('result=%s', v_result));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO cal_test_results VALUES ('T0 calendar_group_weekly alimenta resolver', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T1: resolve_work_day — dia laborable via labor_calendar_overrides
-- =============================================================================
DO $$
DECLARE
  v_result  jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"cc000000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"aa000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  v_result := api.resolve_work_day(
    'dd000000-0000-0000-0000-000000000001',
    '2026-01-15'  -- Dijous amb override laboral 09:00-18:00
  );

  SET LOCAL ROLE postgres;

  IF v_result->>'day_type' = 'working'
     AND (v_result->>'expected_minutes')::int = 540  -- 9h * 60
     AND (v_result->>'spans_midnight')::boolean = false
     AND v_result->>'shift_start_time' = '09:00:00'
     AND v_result->>'shift_end_time' = '18:00:00'
  THEN
    INSERT INTO cal_test_results VALUES ('T1 resolve dia laborable', 'PASS',
      format('day_type=%s expected=%s min source=%s',
             v_result->>'day_type', v_result->>'expected_minutes', v_result->>'labor_source'));
  ELSE
    INSERT INTO cal_test_results VALUES ('T1 resolve dia laborable', 'FAIL',
      format('result=%s', v_result));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO cal_test_results VALUES ('T1 resolve dia laborable', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T2: resolve_work_day — diumenge sense override → unknown (comportament actual)
-- =============================================================================
DO $$
DECLARE
  v_result  jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"cc000000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"aa000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  v_result := api.resolve_work_day(
    'dd000000-0000-0000-0000-000000000001',
    '2026-01-18'  -- Diumenge sense labor override ni festiu
  );

  SET LOCAL ROLE postgres;

  -- Cascada actual: sense capa → undefined → unknown (NO non_working automàtic)
  IF v_result->>'day_type' = 'unknown'
     AND (v_result->>'expected_minutes')::int = 0
  THEN
    INSERT INTO cal_test_results VALUES ('T2 resolve diumenge unknown', 'PASS',
      format('day_type=%s', v_result->>'day_type'));
  ELSE
    INSERT INTO cal_test_results VALUES ('T2 resolve diumenge unknown', 'FAIL',
      format('result=%s', v_result));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO cal_test_results VALUES ('T2 resolve diumenge unknown', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T2b: diumenge amb override leave → non_working
-- =============================================================================
DO $$
DECLARE
  v_result  jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"cc000000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"aa000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  v_result := api.resolve_work_day(
    'dd000000-0000-0000-0000-000000000001',
    '2026-01-25'
  );

  SET LOCAL ROLE postgres;

  IF v_result->>'day_type' = 'non_working'
     AND (v_result->>'expected_minutes')::int = 0
     AND v_result->>'labor_day_type' = 'leave'
  THEN
    INSERT INTO cal_test_results VALUES ('T2b resolve leave → non_working', 'PASS',
      format('day_type=%s labor_day_type=%s', v_result->>'day_type', v_result->>'labor_day_type'));
  ELSE
    INSERT INTO cal_test_results VALUES ('T2b resolve leave → non_working', 'FAIL',
      format('result=%s', v_result));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO cal_test_results VALUES ('T2b resolve leave → non_working', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T3: resolve_work_day — festiu (2026-01-06 = Reis)
-- =============================================================================
DO $$
DECLARE
  v_result  jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"cc000000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"aa000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  v_result := api.resolve_work_day(
    'dd000000-0000-0000-0000-000000000001',
    '2026-01-06'  -- Reis (festiu)
  );

  SET LOCAL ROLE postgres;

  IF v_result->>'day_type' = 'holiday'
     AND (v_result->>'is_holiday')::boolean = true
     AND v_result->>'holiday_name' = 'Reis Mags'
     AND (v_result->>'expected_minutes')::int = 0
  THEN
    INSERT INTO cal_test_results VALUES ('T3 resolve festiu', 'PASS',
      format('day_type=%s name=%s', v_result->>'day_type', v_result->>'holiday_name'));
  ELSE
    INSERT INTO cal_test_results VALUES ('T3 resolve festiu', 'FAIL',
      format('result=%s', v_result));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO cal_test_results VALUES ('T3 resolve festiu', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T4: resolve_work_day — absència aprovada (prioritat sobre horari)
-- =============================================================================
DO $$
DECLARE
  v_result     jsonb;
  v_absence_id uuid;
BEGIN
  -- Inserir directament una absència aprovada (service_role, ja estem com postgres)
  INSERT INTO data.employee_absences (
    id, tenant_id, site_id, employee_id,
    absence_type, start_date, end_date,
    status, is_paid, requested_by, reviewed_by, reviewed_at
  ) VALUES (
    'ab000000-0000-0000-0000-000000000001',
    'aa000000-0000-0000-0000-000000000001',
    'bb000000-0000-0000-0000-000000000001',
    'dd000000-0000-0000-0000-000000000001',
    'vacation', '2026-02-02', '2026-02-06',
    'approved', true,
    'cc000000-0000-0000-0000-000000000001',
    'cc000000-0000-0000-0000-000000000003',
    now()
  ) ON CONFLICT (id) DO NOTHING;

  PERFORM set_config('request.jwt.claims',
    '{"sub":"cc000000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"aa000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  -- 2026-02-04 (Dimecres, DOW=3) → dins l'absència aprovada
  v_result := api.resolve_work_day(
    'dd000000-0000-0000-0000-000000000001',
    '2026-02-04'
  );

  SET LOCAL ROLE postgres;

  IF v_result->>'day_type' = 'absence'
     AND (v_result->>'is_absence')::boolean = true
     AND v_result->>'absence_type' = 'vacation'
  THEN
    INSERT INTO cal_test_results VALUES ('T4 resolve absencia aprovada', 'PASS',
      format('day_type=%s type=%s', v_result->>'day_type', v_result->>'absence_type'));
  ELSE
    INSERT INTO cal_test_results VALUES ('T4 resolve absencia aprovada', 'FAIL',
      format('result=%s', v_result));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO cal_test_results VALUES ('T4 resolve absencia aprovada', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T5: resolve_work_day — torn nocturn (spans_midnight = true)
-- =============================================================================
DO $$
DECLARE
  v_result  jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"cc000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"aa000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  -- Emp2 té torn nocturn; 2026-01-19 = Dilluns (DOW=1) → 22:00-06:00
  v_result := api.resolve_work_day(
    'dd000000-0000-0000-0000-000000000002',
    '2026-01-19'
  );

  SET LOCAL ROLE postgres;

  IF v_result->>'day_type' = 'working'
     AND (v_result->>'spans_midnight')::boolean = true
     AND (v_result->>'expected_minutes')::int = 480  -- 8h
     AND v_result->>'shift_start_time' = '22:00:00'
     AND v_result->>'shift_end_time'   = '06:00:00'
  THEN
    INSERT INTO cal_test_results VALUES ('T5 resolve torn nocturn', 'PASS',
      format('spans_midnight=%s expected=%s start=%s end=%s',
             v_result->>'spans_midnight', v_result->>'expected_minutes',
             v_result->>'shift_start_time', v_result->>'shift_end_time'));
  ELSE
    INSERT INTO cal_test_results VALUES ('T5 resolve torn nocturn', 'FAIL',
      format('result=%s', v_result));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO cal_test_results VALUES ('T5 resolve torn nocturn', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T5b: site_timezone exposat (fallback Europe/Madrid)
-- =============================================================================
DO $$
DECLARE
  v_result  jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"cc000000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"aa000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  v_result := api.resolve_work_day(
    'dd000000-0000-0000-0000-000000000001',
    '2026-01-15'
  );

  SET LOCAL ROLE postgres;

  IF v_result->>'site_timezone' = 'Europe/Madrid' THEN
    INSERT INTO cal_test_results VALUES ('T5b site_timezone', 'PASS',
      format('site_timezone=%s', v_result->>'site_timezone'));
  ELSE
    INSERT INTO cal_test_results VALUES ('T5b site_timezone', 'FAIL',
      format('result=%s', v_result));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO cal_test_results VALUES ('T5b site_timezone', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T6: request_absence — sol·licitud correcta per empleat propi
-- =============================================================================
DO $$
DECLARE
  v_result  jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"cc000000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"aa000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true);
  PERFORM set_config('request.headers', '{"x-tenant-id":"aa000000-0000-0000-0000-000000000001"}', true);
  SET LOCAL ROLE authenticated;

  v_result := api.request_absence(
    p_employee_id  => 'dd000000-0000-0000-0000-000000000001',
    p_absence_type => 'vacation',
    p_start_date   => '2026-03-02',
    p_end_date     => '2026-03-06',
    p_notes        => 'Vacances hivern'
  );

  SET LOCAL ROLE postgres;

  IF v_result->>'status' = 'requested'
     AND (v_result->>'absence_id') IS NOT NULL
  THEN
    INSERT INTO cal_test_results VALUES ('T6 request_absence vacation', 'PASS',
      format('id=%s status=%s', v_result->>'absence_id', v_result->>'status'));
  ELSE
    INSERT INTO cal_test_results VALUES ('T6 request_absence vacation', 'FAIL',
      format('result=%s', v_result));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO cal_test_results VALUES ('T6 request_absence vacation', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T7: request_absence — rebutjat si solapament amb absència aprovada o pendent
-- =============================================================================
DO $$
DECLARE
  v_result  jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"cc000000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"aa000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true);
  PERFORM set_config('request.headers', '{"x-tenant-id":"aa000000-0000-0000-0000-000000000001"}', true);
  SET LOCAL ROLE authenticated;

  -- Solapament amb la vacança aprovada 2026-02-02 / 2026-02-06 (T4)
  -- Tipus actiu (taxonomy Track C1): personal_days (no «personal», obsolet)
  PERFORM api.request_absence(
    p_employee_id  => 'dd000000-0000-0000-0000-000000000001',
    p_absence_type => 'personal_days',
    p_start_date   => '2026-02-04',
    p_end_date     => '2026-02-04'
  );

  SET LOCAL ROLE postgres;
  INSERT INTO cal_test_results VALUES ('T7 request_absence solapament', 'FAIL',
    'Expected exclusion_violation not raised');

EXCEPTION WHEN exclusion_violation THEN
  SET LOCAL ROLE postgres;
  INSERT INTO cal_test_results VALUES ('T7 request_absence solapament', 'PASS',
    format('Exception correcta: %s', SQLERRM));
WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO cal_test_results VALUES ('T7 request_absence solapament', 'FAIL',
    format('Wrong exception: %s', SQLERRM));
END $$;


-- =============================================================================
-- T8: approve_absence — membre sense permís → rebutjat
-- =============================================================================
DO $$
DECLARE
  v_abs_id  uuid;
BEGIN
  -- Obtenir l'absència sol·licitada a T6 (vacation 2026-03-02 / 2026-03-06)
  SELECT id INTO v_abs_id
  FROM data.employee_absences
  WHERE employee_id = 'dd000000-0000-0000-0000-000000000001'
    AND start_date = '2026-03-02'
    AND status = 'requested'
  LIMIT 1;

  IF v_abs_id IS NULL THEN
    INSERT INTO cal_test_results VALUES ('T8 approve rebutjat sense permis', 'SKIP',
      'T6 no ha creat absència, T8 s''omet');
    RETURN;
  END IF;

  PERFORM set_config('request.jwt.claims',
    '{"sub":"cc000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"aa000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  PERFORM api.approve_absence(v_abs_id, 'approved');

  SET LOCAL ROLE postgres;
  INSERT INTO cal_test_results VALUES ('T8 approve rebutjat sense permis', 'FAIL',
    'Expected insufficient_privilege not raised');

EXCEPTION WHEN insufficient_privilege THEN
  SET LOCAL ROLE postgres;
  INSERT INTO cal_test_results VALUES ('T8 approve rebutjat sense permis', 'PASS',
    format('Exception: %s', SQLERRM));
WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO cal_test_results VALUES ('T8 approve rebutjat sense permis', 'FAIL',
    format('Wrong exception: %s', SQLERRM));
END $$;


-- =============================================================================
-- T9: approve_absence — manager aprova correctament
-- =============================================================================
DO $$
DECLARE
  v_abs_id    uuid;
  v_result    jsonb;
  v_db_status text;
BEGIN
  SELECT id INTO v_abs_id
  FROM data.employee_absences
  WHERE employee_id = 'dd000000-0000-0000-0000-000000000001'
    AND start_date = '2026-03-02'
    AND status = 'requested'
  LIMIT 1;

  IF v_abs_id IS NULL THEN
    INSERT INTO cal_test_results VALUES ('T9 manager aprova absence', 'SKIP',
      'T6 no ha creat absència, T9 s''omet');
    RETURN;
  END IF;

  PERFORM set_config('request.jwt.claims',
    '{"sub":"cc000000-0000-0000-0000-000000000003","app_metadata":{"user_tenants":{"aa000000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"aa000000-0000-0000-0000-000000000001":["attendance.approve","absences.approve"]}}}',
    true);
  PERFORM set_config('request.headers', '{"x-tenant-id":"aa000000-0000-0000-0000-000000000001"}', true);
  SET LOCAL ROLE authenticated;

  v_result := api.approve_absence(v_abs_id, 'approved', 'OK, autoritzat');

  SET LOCAL ROLE postgres;

  SELECT status INTO v_db_status
  FROM data.employee_absences WHERE id = v_abs_id;

  IF v_result->>'status' = 'approved' AND v_db_status = 'approved' THEN
    INSERT INTO cal_test_results VALUES ('T9 manager aprova absence', 'PASS',
      format('rpc=%s db=%s', v_result->>'status', v_db_status));
  ELSE
    INSERT INTO cal_test_results VALUES ('T9 manager aprova absence', 'FAIL',
      format('rpc=%s db=%s', v_result->>'status', v_db_status));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO cal_test_results VALUES ('T9 manager aprova absence', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T10: import_holidays — importa festius en format Nager.Date
-- =============================================================================
DO $$
DECLARE
  v_result  jsonb;
  v_count   int;
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"cc000000-0000-0000-0000-000000000003","app_metadata":{"user_tenants":{"aa000000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  v_result := api.import_holidays(
    'ac000000-0000-0000-0000-000000000001',
    '[
      {"date": "2026-05-01", "name": "Dia del Treball", "localName": "Dia del Treball", "holidayType": "Public"},
      {"date": "2026-08-15", "name": "Assumpció",        "localName": "Assumpció",        "holidayType": "Public"},
      {"date": "2026-12-25", "name": "Nadal",            "localName": "Nadal",            "holidayType": "Public"},
      {"date": "BAD-DATE",   "name": "Error",            "localName": "Error",            "holidayType": "Public"}
    ]'::jsonb
  );

  SET LOCAL ROLE postgres;

  SELECT COUNT(*) INTO v_count
  FROM data.holidays
  WHERE calendar_id = 'ac000000-0000-0000-0000-000000000001';

  IF (v_result->>'inserted')::int = 3
     AND (v_result->>'skipped')::int  = 1
     AND v_count >= 3
  THEN
    INSERT INTO cal_test_results VALUES ('T10 import_holidays', 'PASS',
      format('inserted=%s skipped=%s total_db=%s', v_result->>'inserted', v_result->>'skipped', v_count));
  ELSE
    INSERT INTO cal_test_results VALUES ('T10 import_holidays', 'FAIL',
      format('result=%s total_db=%s', v_result, v_count));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO cal_test_results VALUES ('T10 import_holidays', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T11: ADR-0003 — employee_weekly té prioritat sobre calendar_group_weekly
-- =============================================================================
DO $$
DECLARE
  v_result  jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"cc000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"aa000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  -- Dimarts 2026-01-20: Emp2 pertany al grup "Jornada Dia" (09:00-18:00) però té
  -- un override individual (employee_weekly) de torn nocturn 22:00-06:00.
  -- Cap override puntual (labor_calendar_overrides) per aquest dia → l'individual guanya al de grup.
  v_result := api.resolve_work_day(
    'dd000000-0000-0000-0000-000000000002',
    '2026-01-20'
  );

  SET LOCAL ROLE postgres;

  IF v_result->>'day_type' = 'working'
     AND (v_result->>'expected_minutes')::int = 480
     AND (v_result->>'spans_midnight')::boolean = true
     AND v_result->>'labor_source' = 'employee_weekly'
  THEN
    INSERT INTO cal_test_results VALUES ('T11 employee_weekly > calendar_group_weekly', 'PASS',
      format('expected=%s spans_midnight=%s labor_source=%s',
             v_result->>'expected_minutes', v_result->>'spans_midnight', v_result->>'labor_source'));
  ELSE
    INSERT INTO cal_test_results VALUES ('T11 employee_weekly > calendar_group_weekly', 'FAIL',
      format('result=%s', v_result));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO cal_test_results VALUES ('T11 employee_weekly > calendar_group_weekly', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T12: resolve_work_day — member A NO pot resoldre el dia d'employee B (HR guard)
-- =============================================================================
DO $$
DECLARE
  v_result  jsonb;
BEGIN
  -- cc...002 intenta veure l'absència d'dd...001 (empleat d'un altre user)
  PERFORM set_config('request.jwt.claims',
    '{"sub":"cc000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"aa000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  -- dd...001 pertany a cc...001, no a cc...002
  PERFORM api.resolve_work_day(
    'dd000000-0000-0000-0000-000000000001',
    '2026-02-04'  -- Dia amb absència aprovada de T4
  );

  SET LOCAL ROLE postgres;
  INSERT INTO cal_test_results VALUES ('T12 HR access guard', 'FAIL',
    'Expected insufficient_privilege not raised for member accessing other employee absence');

EXCEPTION WHEN insufficient_privilege THEN
  SET LOCAL ROLE postgres;
  INSERT INTO cal_test_results VALUES ('T12 HR access guard', 'PASS',
    format('Exception: %s', SQLERRM));
WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO cal_test_results VALUES ('T12 HR access guard', 'FAIL',
    format('Wrong exception: %s', SQLERRM));
END $$;


-- =============================================================================
-- Resultat final
-- =============================================================================

SELECT
  test_name,
  status,
  details
FROM cal_test_results
ORDER BY test_name;

SELECT
  COUNT(*) FILTER (WHERE status = 'PASS')  AS passed,
  COUNT(*) FILTER (WHERE status = 'FAIL')  AS failed,
  COUNT(*) FILTER (WHERE status = 'ERROR') AS errors,
  COUNT(*) FILTER (WHERE status = 'SKIP')  AS skipped,
  COUNT(*)                                 AS total
FROM cal_test_results;

ROLLBACK;
