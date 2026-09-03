-- =============================================================================
-- attendance_shifts_tests.sql — Phase 2: Shift Planning
--
-- Execució:
--   docker exec supabase_db_<proj> psql -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f /tmp/attendance_shifts_tests.sql
--
-- Tests:
--   T1  assign_shift_slot  — assignació correcta (status=draft)
--   T2  assign_shift_slot  — anomalia SHIFT_OVERLAP si l'empleat ja té torn el mateix dia
--   T3  assign_shift_slot  — anomalia WEEKLY_HOURS_EXCEEDED si supera hores contractuals
--   T4  assign_shift_slot  — rebutjat per membre sense labor_calendar.manage
--   T5  publish_shifts     — publicar setmana: draft → published + calendar_events creats
--   T6  get_coverage_for_period — retorna cobertura amb employee_count correcte
--   T7  bulk_delete_shift_slots — cancel·la slots correctament
--   T8  request_shift_swap — sol·licitud creada per propietari del slot
--   T9  request_shift_swap — rebutjada si ja hi ha sol·licitud pendent
--   T10 approve_shift_swap — manager aprova i intercanvia employee_id dels slots
--   T11 empleat no veu drafts (RLS)
--   T12 cancel·lació de slot elimina calendar_event
--   T13 request_shift_swap rebutja slots draft
--   T14 start_time/end_time congelats al slot
--   T15 approve_shift_swap obert amb p_target_employee_id
--   T16 solapament real amb torn nocturn i dia següent
--   T17 publish_shifts exigeix week_start en dilluns
--   T18 cobertura requerida (required_employee_count, coverage_delta)
--   T19 accept_shift_swap per swaps oberts
--   T20 integritat work_shift (tenant/site mismatch)
--   T21 integritat shift_slot (tenant/employee mismatch)
--   T22 integritat shift_swap_request (requester slot owner mismatch)
--   T23 integritat shift_coverage_requirement (tenant/site mismatch)
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('aa100000-0000-0000-0000-000000000001', 'Shift Tenant', 'shift-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('ab100000-0000-0000-0000-000000000001', 'aa100000-0000-0000-0000-000000000001', 'Shift Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('ac100000-0000-0000-0000-000000000001', 'emp1@shift.test',  'authenticated', 'authenticated'),
  ('ac100000-0000-0000-0000-000000000002', 'emp2@shift.test',  'authenticated', 'authenticated'),
  ('ac100000-0000-0000-0000-000000000003', 'mgr1@shift.test',  'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('ac100000-0000-0000-0000-000000000001', 'emp1@shift.test',  'Emp1 Shift'),
  ('ac100000-0000-0000-0000-000000000002', 'emp2@shift.test',  'Emp2 Shift'),
  ('ac100000-0000-0000-0000-000000000003', 'mgr1@shift.test',  'Mgr1 Shift')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'aa100000-0000-0000-0000-000000000001', 'ac100000-0000-0000-0000-000000000001', 'member',  true),
  (gen_random_uuid(), 'aa100000-0000-0000-0000-000000000001', 'ac100000-0000-0000-0000-000000000002', 'member',  true),
  (gen_random_uuid(), 'aa100000-0000-0000-0000-000000000001', 'ac100000-0000-0000-0000-000000000003', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status, weekly_hours)
VALUES
  ('ad100000-0000-0000-0000-000000000001', 'aa100000-0000-0000-0000-000000000001', 'ab100000-0000-0000-0000-000000000001', 'ac100000-0000-0000-0000-000000000001', 'Emp1 Shift', 'active', 40),
  ('ad100000-0000-0000-0000-000000000002', 'aa100000-0000-0000-0000-000000000001', 'ab100000-0000-0000-0000-000000000001', 'ac100000-0000-0000-0000-000000000002', 'Emp2 Shift', 'active', 20)
ON CONFLICT (id) DO NOTHING;

-- Torn de dia: 09:00-17:00 (8h = 480 min)
INSERT INTO data.work_shifts (id, tenant_id, site_id, name, color, start_time, end_time, is_active)
VALUES
  ('ae100000-0000-0000-0000-000000000001', 'aa100000-0000-0000-0000-000000000001', 'ab100000-0000-0000-0000-000000000001', 'Matí',     '#3b82f6', '09:00', '17:00', true),
  ('ae100000-0000-0000-0000-000000000002', 'aa100000-0000-0000-0000-000000000001', 'ab100000-0000-0000-0000-000000000001', 'Tarda',    '#f59e0b', '13:00', '21:00', true),
  ('ae100000-0000-0000-0000-000000000003', 'aa100000-0000-0000-0000-000000000001', 'ab100000-0000-0000-0000-000000000001', 'Nocturn',  '#6366f1', '22:00', '06:00', true)
ON CONFLICT DO NOTHING;

-- Taula de resultats
CREATE TEMP TABLE sh_test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;


-- =============================================================================
-- T1: assign_shift_slot — assignació correcta (status=draft)
-- =============================================================================
DO $$
DECLARE
  v_result  jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"ac100000-0000-0000-0000-000000000003","app_metadata":{"user_tenants":{"aa100000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"aa100000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","attendance.view_all","attendance.approve"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  v_result := api.assign_shift_slot(
    'ad100000-0000-0000-0000-000000000001',
    '2026-06-02',  -- Dilluns
    'ae100000-0000-0000-0000-000000000001'
  );

  SET LOCAL ROLE postgres;

  IF (v_result->>'status') = 'draft'
     AND (v_result->>'slot_id') IS NOT NULL
     AND v_result->'anomalies' = '[]'::jsonb
  THEN
    INSERT INTO sh_test_results VALUES ('T1 assign_shift_slot ok', 'PASS',
      format('slot_id=%s anomalies=[]', v_result->>'slot_id'));
  ELSE
    INSERT INTO sh_test_results VALUES ('T1 assign_shift_slot ok', 'FAIL',
      format('result=%s', v_result));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO sh_test_results VALUES ('T1 assign_shift_slot ok', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T2: assign_shift_slot — anomalia SHIFT_OVERLAP (torn diferent el mateix dia)
-- =============================================================================
DO $$
DECLARE
  v_result  jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"ac100000-0000-0000-0000-000000000003","app_metadata":{"user_tenants":{"aa100000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"aa100000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","attendance.view_all"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  -- Assignar torn Tarda el mateix dia que T1 (Dilluns 2026-06-02, Matí ja assignat)
  v_result := api.assign_shift_slot(
    'ad100000-0000-0000-0000-000000000001',
    '2026-06-02',
    'ae100000-0000-0000-0000-000000000002'  -- torn Tarda
  );

  SET LOCAL ROLE postgres;

  IF v_result->'anomalies' @> '["SHIFT_OVERLAP"]'::jsonb THEN
    INSERT INTO sh_test_results VALUES ('T2 anomalia SHIFT_OVERLAP', 'PASS',
      format('anomalies=%s', v_result->'anomalies'));
  ELSE
    INSERT INTO sh_test_results VALUES ('T2 anomalia SHIFT_OVERLAP', 'FAIL',
      format('result=%s', v_result));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO sh_test_results VALUES ('T2 anomalia SHIFT_OVERLAP', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T3: assign_shift_slot — anomalia WEEKLY_HOURS_EXCEEDED
--     Emp2 té weekly_hours=20 (1200 min). Assignem 3 torns de 8h = 1440 min
-- =============================================================================
DO $$
DECLARE
  v_result  jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"ac100000-0000-0000-0000-000000000003","app_metadata":{"user_tenants":{"aa100000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"aa100000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","attendance.view_all"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  -- Assigns dilluns i dimarts (2 torns Matí = 2*480 = 960 min < 1200 min)
  PERFORM api.assign_shift_slot('ad100000-0000-0000-0000-000000000002', '2026-06-02', 'ae100000-0000-0000-0000-000000000001');
  PERFORM api.assign_shift_slot('ad100000-0000-0000-0000-000000000002', '2026-06-03', 'ae100000-0000-0000-0000-000000000001');

  -- Tercer torn: 960 + 480 = 1440 > 1200 → WEEKLY_HOURS_EXCEEDED
  v_result := api.assign_shift_slot(
    'ad100000-0000-0000-0000-000000000002',
    '2026-06-04',
    'ae100000-0000-0000-0000-000000000001'
  );

  SET LOCAL ROLE postgres;

  IF v_result->'anomalies' @> '["WEEKLY_HOURS_EXCEEDED"]'::jsonb THEN
    INSERT INTO sh_test_results VALUES ('T3 anomalia WEEKLY_HOURS_EXCEEDED', 'PASS',
      format('anomalies=%s', v_result->'anomalies'));
  ELSE
    INSERT INTO sh_test_results VALUES ('T3 anomalia WEEKLY_HOURS_EXCEEDED', 'FAIL',
      format('result=%s', v_result));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO sh_test_results VALUES ('T3 anomalia WEEKLY_HOURS_EXCEEDED', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T4: assign_shift_slot — rebutjat si l'usuari no té labor_calendar.manage
-- =============================================================================
DO $$
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"ac100000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"aa100000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"aa100000-0000-0000-0000-000000000001":{"global_permissions":["attendance.punch_own","absences.request"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  PERFORM api.assign_shift_slot(
    'ad100000-0000-0000-0000-000000000001',
    '2026-06-05',
    'ae100000-0000-0000-0000-000000000001'
  );

  SET LOCAL ROLE postgres;
  INSERT INTO sh_test_results VALUES ('T4 membre no pot assignar torn', 'FAIL',
    'Expected insufficient_privilege not raised');

EXCEPTION WHEN insufficient_privilege THEN
  SET LOCAL ROLE postgres;
  INSERT INTO sh_test_results VALUES ('T4 membre no pot assignar torn', 'PASS',
    format('Exception: %s', SQLERRM));
WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO sh_test_results VALUES ('T4 membre no pot assignar torn', 'FAIL',
    format('Wrong exception: %s', SQLERRM));
END $$;


-- =============================================================================
-- T5: publish_shifts — publicar setmana 2026-06-02/06-06
--     Comprova: slots passen a published, calendar_events creats
-- =============================================================================
DO $$
DECLARE
  v_result       jsonb;
  v_slot_count   int;
  v_event_count  int;
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"ac100000-0000-0000-0000-000000000003","app_metadata":{"user_tenants":{"aa100000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"aa100000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","attendance.view_all","attendance.approve"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  v_result := api.publish_shifts(
    'ab100000-0000-0000-0000-000000000001',
    '2026-06-01',
    ARRAY['SHIFT_OVERLAP', 'WEEKLY_HOURS_EXCEEDED']
  );

  SET LOCAL ROLE postgres;

  SELECT COUNT(*) INTO v_slot_count
  FROM data.shift_slots
  WHERE site_id  = 'ab100000-0000-0000-0000-000000000001'
    AND slot_date BETWEEN '2026-06-02' AND '2026-06-08'
    AND status = 'published';

  SELECT COUNT(*) INTO v_event_count
  FROM data.calendar_events
  WHERE entity_type = 'shift_slot'
    AND tenant_id   = 'aa100000-0000-0000-0000-000000000001';

  IF (v_result->>'published')::int > 0
     AND v_slot_count > 0
     AND v_event_count > 0
     AND v_slot_count = v_event_count
  THEN
    INSERT INTO sh_test_results VALUES ('T5 publish_shifts', 'PASS',
      format('published=%s slots_db=%s calendar_events=%s', v_result->>'published', v_slot_count, v_event_count));
  ELSE
    INSERT INTO sh_test_results VALUES ('T5 publish_shifts', 'FAIL',
      format('result=%s slots=%s events=%s', v_result, v_slot_count, v_event_count));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO sh_test_results VALUES ('T5 publish_shifts', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T6: get_coverage_for_period — retorna coverage per dia amb employee_count
-- =============================================================================
DO $$
DECLARE
  v_result     jsonb;
  v_day_count  int;
  v_ok         boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"ac100000-0000-0000-0000-000000000003","app_metadata":{"user_tenants":{"aa100000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"aa100000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","attendance.view_all"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  v_result := api.get_coverage_for_period(
    'ab100000-0000-0000-0000-000000000001',
    '2026-06-02',
    '2026-06-08'
  );

  SET LOCAL ROLE postgres;

  -- Han de ser 7 dies; dilluns ha de tenir employee_count >= 1
  v_day_count := jsonb_array_length(v_result);

  SELECT (elem->>'employee_count')::int >= 1
  INTO v_ok
  FROM jsonb_array_elements(v_result) AS elem
  WHERE (elem->>'work_date') = '2026-06-02'
  LIMIT 1;

  IF v_day_count = 7 AND v_ok = true THEN
    INSERT INTO sh_test_results VALUES ('T6 get_coverage_for_period', 'PASS',
      format('days=%s dilluns_emp_count=%s', v_day_count, (
        SELECT elem->>'employee_count' FROM jsonb_array_elements(v_result) AS elem
        WHERE (elem->>'work_date') = '2026-06-02' LIMIT 1
      )));
  ELSE
    INSERT INTO sh_test_results VALUES ('T6 get_coverage_for_period', 'FAIL',
      format('days=%s result=%s', v_day_count, v_result));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO sh_test_results VALUES ('T6 get_coverage_for_period', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T7: bulk_delete_shift_slots — cancel·la slots correctament
-- =============================================================================
DO $$
DECLARE
  v_slot_ids  uuid[];
  v_result    jsonb;
  v_cancelled int;
BEGIN
  -- Assignar torns extres per cancel·lar
  PERFORM set_config('request.jwt.claims',
    '{"sub":"ac100000-0000-0000-0000-000000000003","app_metadata":{"user_tenants":{"aa100000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"aa100000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","attendance.view_all"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  PERFORM api.assign_shift_slot('ad100000-0000-0000-0000-000000000001', '2026-06-16', 'ae100000-0000-0000-0000-000000000001');
  PERFORM api.assign_shift_slot('ad100000-0000-0000-0000-000000000001', '2026-06-17', 'ae100000-0000-0000-0000-000000000001');

  SET LOCAL ROLE postgres;

  SELECT array_agg(id) INTO v_slot_ids
  FROM data.shift_slots
  WHERE employee_id = 'ad100000-0000-0000-0000-000000000001'
    AND slot_date IN ('2026-06-16', '2026-06-17')
    AND status = 'draft';

  SET LOCAL ROLE authenticated;

  v_result := api.bulk_delete_shift_slots(v_slot_ids);

  SET LOCAL ROLE postgres;

  SELECT COUNT(*) INTO v_cancelled
  FROM data.shift_slots
  WHERE id = ANY(v_slot_ids) AND status = 'cancelled';

  IF (v_result->>'cancelled_count')::int = 2 AND v_cancelled = 2 THEN
    INSERT INTO sh_test_results VALUES ('T7 bulk_delete_shift_slots', 'PASS',
      format('cancelled_count=2'));
  ELSE
    INSERT INTO sh_test_results VALUES ('T7 bulk_delete_shift_slots', 'FAIL',
      format('result=%s db_cancelled=%s', v_result, v_cancelled));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO sh_test_results VALUES ('T7 bulk_delete_shift_slots', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T8: request_shift_swap — sol·licitud creada per l'empleat propietari del slot
-- =============================================================================
DO $$
DECLARE
  v_slot_id    uuid;
  v_result     jsonb;
BEGIN
  -- Seleccionem el slot Tarda d'Emp1 (Emp2 no té cap Tarda → sense conflicte de constraint en T10)
  SELECT id INTO v_slot_id
  FROM data.shift_slots
  WHERE employee_id = 'ad100000-0000-0000-0000-000000000001'
    AND slot_date   = '2026-06-02'
    AND shift_id    = 'ae100000-0000-0000-0000-000000000002'  -- Tarda
    AND status      = 'published'
  LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    format('{"sub":"ac100000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"aa100000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"aa100000-0000-0000-0000-000000000001":{"global_permissions":["attendance.punch_own","absences.request"],"sites":{}}}}}'),
    true);
  SET LOCAL ROLE authenticated;

  v_result := api.request_shift_swap(
    v_slot_id,
    'ad100000-0000-0000-0000-000000000002',
    NULL,
    'Necessito el dia lliure'
  );

  SET LOCAL ROLE postgres;

  IF (v_result->>'status') = 'pending' AND (v_result->>'request_id') IS NOT NULL THEN
    INSERT INTO sh_test_results VALUES ('T8 request_shift_swap', 'PASS',
      format('request_id=%s status=pending', v_result->>'request_id'));
  ELSE
    INSERT INTO sh_test_results VALUES ('T8 request_shift_swap', 'FAIL',
      format('result=%s', v_result));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO sh_test_results VALUES ('T8 request_shift_swap', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T9: request_shift_swap — rebutjat si ja hi ha sol·licitud pendent per al slot
-- =============================================================================
DO $$
DECLARE
  v_slot_id  uuid;
BEGIN
  SELECT id INTO v_slot_id
  FROM data.shift_slots
  WHERE employee_id = 'ad100000-0000-0000-0000-000000000001'
    AND slot_date   = '2026-06-02'
    AND shift_id    = 'ae100000-0000-0000-0000-000000000002'  -- Tarda (coincideix amb T8)
    AND status      = 'published'
  LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    '{"sub":"ac100000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"aa100000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  PERFORM api.request_shift_swap(v_slot_id, NULL, NULL, 'Intent duplicat');

  SET LOCAL ROLE postgres;
  INSERT INTO sh_test_results VALUES ('T9 swap_already_pending bloquejat', 'FAIL',
    'Expected exclusion_violation not raised');

EXCEPTION WHEN exclusion_violation THEN
  SET LOCAL ROLE postgres;
  INSERT INTO sh_test_results VALUES ('T9 swap_already_pending bloquejat', 'PASS',
    format('Exception correcta: %s', SQLERRM));
WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO sh_test_results VALUES ('T9 swap_already_pending bloquejat', 'FAIL',
    format('Wrong exception: %s', SQLERRM));
END $$;


-- =============================================================================
-- T10: approve_shift_swap — manager aprova i els slots intercanvien employee_id
-- =============================================================================
DO $$
DECLARE
  v_request_id   uuid;
  v_slot_id_1    uuid;
  v_result       jsonb;
  v_new_owner    uuid;
BEGIN
  SELECT id INTO v_request_id
  FROM data.shift_swap_requests
  WHERE requester_id = 'ad100000-0000-0000-0000-000000000001'
    AND status       = 'pending'
  ORDER BY created_at DESC
  LIMIT 1;

  SELECT requester_slot_id INTO v_slot_id_1
  FROM data.shift_swap_requests
  WHERE id = v_request_id;

  PERFORM set_config('request.jwt.claims',
    '{"sub":"ac100000-0000-0000-0000-000000000003","app_metadata":{"user_tenants":{"aa100000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"aa100000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","attendance.approve","attendance.view_all"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  v_result := api.approve_shift_swap(v_request_id, 'approved', 'Aprovat pel manager');

  SET LOCAL ROLE postgres;

  SELECT employee_id INTO v_new_owner
  FROM data.shift_slots WHERE id = v_slot_id_1;

  IF (v_result->>'status') = 'approved'
     AND v_new_owner = 'ad100000-0000-0000-0000-000000000002'
  THEN
    INSERT INTO sh_test_results VALUES ('T10 approve_shift_swap', 'PASS',
      format('status=approved slot_nou_propietari=%s', v_new_owner));
  ELSE
    INSERT INTO sh_test_results VALUES ('T10 approve_shift_swap', 'FAIL',
      format('result=%s new_owner=%s', v_result, v_new_owner));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO sh_test_results VALUES ('T10 approve_shift_swap', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T11: empleat NO pot veure slots draft (F1 — RLS)
-- =============================================================================
DO $$
DECLARE
  v_draft_count  int;
BEGIN
  -- Assignar un draft per a Emp1 en una data futura
  PERFORM set_config('request.jwt.claims',
    '{"sub":"ac100000-0000-0000-0000-000000000003","app_metadata":{"user_tenants":{"aa100000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"aa100000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","attendance.view_all"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;
  PERFORM api.assign_shift_slot('ad100000-0000-0000-0000-000000000001', '2026-07-01', 'ae100000-0000-0000-0000-000000000001');
  SET LOCAL ROLE postgres;

  -- Ara consultar com l'empleat: no ha de veure el draft
  PERFORM set_config('request.jwt.claims',
    '{"sub":"ac100000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"aa100000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"aa100000-0000-0000-0000-000000000001":{"global_permissions":["attendance.punch_own","absences.request","labor_calendar.view"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  SELECT COUNT(*) INTO v_draft_count
  FROM api.shift_slots
  WHERE employee_id = 'ad100000-0000-0000-0000-000000000001'
    AND slot_date   = '2026-07-01'
    AND status      = 'draft';

  SET LOCAL ROLE postgres;

  IF v_draft_count = 0 THEN
    INSERT INTO sh_test_results VALUES ('T11 empleat no veu drafts', 'PASS',
      'draft_count=0 per a l''empleat (RLS ok)');
  ELSE
    INSERT INTO sh_test_results VALUES ('T11 empleat no veu drafts', 'FAIL',
      format('draft_count=%s (hauria de ser 0)', v_draft_count));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO sh_test_results VALUES ('T11 empleat no veu drafts', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T12: cancel·lar slot publicat elimina el calendar_event (F5)
-- =============================================================================
DO $$
DECLARE
  v_slot_id      uuid;
  v_event_before int;
  v_event_after  int;
  v_result       jsonb;
BEGIN
  -- Agafar un slot published d'Emp2
  SELECT id INTO v_slot_id
  FROM data.shift_slots
  WHERE employee_id = 'ad100000-0000-0000-0000-000000000002'
    AND status      = 'published'
  LIMIT 1;

  SELECT COUNT(*) INTO v_event_before
  FROM data.calendar_events
  WHERE entity_type = 'shift_slot' AND entity_id = v_slot_id;

  PERFORM set_config('request.jwt.claims',
    '{"sub":"ac100000-0000-0000-0000-000000000003","app_metadata":{"user_tenants":{"aa100000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"aa100000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","attendance.view_all"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  v_result := api.bulk_delete_shift_slots(ARRAY[v_slot_id]);

  SET LOCAL ROLE postgres;

  SELECT COUNT(*) INTO v_event_after
  FROM data.calendar_events
  WHERE entity_type = 'shift_slot' AND entity_id = v_slot_id;

  IF v_event_before >= 1 AND v_event_after = 0 THEN
    INSERT INTO sh_test_results VALUES ('T12 cancel·la slot elimina calendar_event', 'PASS',
      format('before=%s after=%s', v_event_before, v_event_after));
  ELSE
    INSERT INTO sh_test_results VALUES ('T12 cancel·la slot elimina calendar_event', 'FAIL',
      format('before=%s after=%s (hauria de ser after=0)', v_event_before, v_event_after));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO sh_test_results VALUES ('T12 cancel·la slot elimina calendar_event', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T13: request_shift_swap — rebutjat per a slot draft (F6)
-- =============================================================================
DO $$
DECLARE
  v_draft_slot_id  uuid;
BEGIN
  SELECT id INTO v_draft_slot_id
  FROM data.shift_slots
  WHERE employee_id = 'ad100000-0000-0000-0000-000000000001'
    AND slot_date   = '2026-07-01'
    AND status      = 'draft'
  LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    '{"sub":"ac100000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"aa100000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"aa100000-0000-0000-0000-000000000001":{"global_permissions":["attendance.punch_own","absences.request"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  PERFORM api.request_shift_swap(v_draft_slot_id, NULL, NULL, 'hauria de fallar');

  SET LOCAL ROLE postgres;
  INSERT INTO sh_test_results VALUES ('T13 swap draft rebutjat', 'FAIL',
    'Expected check_violation not raised');

EXCEPTION WHEN check_violation THEN
  SET LOCAL ROLE postgres;
  INSERT INTO sh_test_results VALUES ('T13 swap draft rebutjat', 'PASS',
    format('Exception correcta: %s', SQLERRM));
WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO sh_test_results VALUES ('T13 swap draft rebutjat', 'FAIL',
    format('Wrong exception: %s', SQLERRM));
END $$;


-- =============================================================================
-- T14: start_time/end_time congelats al slot (F2)
--      Canviar plantilla no afecta slot existent
-- =============================================================================
DO $$
DECLARE
  v_slot_time_before  time;
  v_slot_time_after   time;
BEGIN
  SELECT start_time INTO v_slot_time_before
  FROM data.shift_slots
  WHERE employee_id = 'ad100000-0000-0000-0000-000000000001'
    AND slot_date   = '2026-06-02'
  LIMIT 1;

  -- Canviar la plantilla
  UPDATE data.work_shifts
  SET start_time = '10:00:00'
  WHERE id = 'ae100000-0000-0000-0000-000000000001';

  SELECT start_time INTO v_slot_time_after
  FROM data.shift_slots
  WHERE employee_id = 'ad100000-0000-0000-0000-000000000001'
    AND slot_date   = '2026-06-02'
  LIMIT 1;

  -- Revertir canvi plantilla
  UPDATE data.work_shifts
  SET start_time = '09:00:00'
  WHERE id = 'ae100000-0000-0000-0000-000000000001';

  IF v_slot_time_before = v_slot_time_after AND v_slot_time_before = '09:00:00' THEN
    INSERT INTO sh_test_results VALUES ('T14 start_time congelat al slot', 'PASS',
      format('start_time=%s (no ha canviat)', v_slot_time_before));
  ELSE
    INSERT INTO sh_test_results VALUES ('T14 start_time congelat al slot', 'FAIL',
      format('before=%s after=%s (hauria de ser =before)', v_slot_time_before, v_slot_time_after));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO sh_test_results VALUES ('T14 start_time congelat al slot', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T15: approve_shift_swap obert — requerit p_target_employee_id (F7)
-- =============================================================================
DO $$
DECLARE
  v_open_slot_id   uuid;
  v_open_req_id    uuid;
  v_result         jsonb;
BEGIN
  -- Crear un slot published per Emp1 en una data nova
  PERFORM set_config('request.jwt.claims',
    '{"sub":"ac100000-0000-0000-0000-000000000003","app_metadata":{"user_tenants":{"aa100000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"aa100000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","attendance.view_all","attendance.approve"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  PERFORM api.assign_shift_slot('ad100000-0000-0000-0000-000000000001', '2026-07-07', 'ae100000-0000-0000-0000-000000000001');
  PERFORM api.publish_shifts(
    'ab100000-0000-0000-0000-000000000001',
    '2026-07-06',
    ARRAY['SHIFT_OVERLAP', 'WEEKLY_HOURS_EXCEEDED']
  );

  SET LOCAL ROLE postgres;

  SELECT id INTO v_open_slot_id
  FROM data.shift_slots
  WHERE employee_id = 'ad100000-0000-0000-0000-000000000001'
    AND slot_date   = '2026-07-07'
    AND status      = 'published'
  LIMIT 1;

  -- Sol·licitud oberta (target_employee_id NULL)
  PERFORM set_config('request.jwt.claims',
    '{"sub":"ac100000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"aa100000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"aa100000-0000-0000-0000-000000000001":{"global_permissions":["attendance.punch_own","absences.request"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  SELECT (api.request_shift_swap(v_open_slot_id, NULL, NULL, 'swap obert'))->>'request_id'
  INTO v_open_req_id;

  -- Manager aprova amb target_employee_id explícit
  PERFORM set_config('request.jwt.claims',
    '{"sub":"ac100000-0000-0000-0000-000000000003","app_metadata":{"user_tenants":{"aa100000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"aa100000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","attendance.approve","attendance.view_all"],"sites":{}}}}}',
    true);

  v_result := api.approve_shift_swap(v_open_req_id::uuid, 'approved', 'Aprovat', 'ad100000-0000-0000-0000-000000000002');

  SET LOCAL ROLE postgres;

  IF (v_result->>'status') = 'approved'
     AND (SELECT employee_id FROM data.shift_slots WHERE id = v_open_slot_id)
         = 'ad100000-0000-0000-0000-000000000002'
  THEN
    INSERT INTO sh_test_results VALUES ('T15 approve_swap obert amb target param', 'PASS',
      format('status=approved nou_propietari=Emp2'));
  ELSE
    INSERT INTO sh_test_results VALUES ('T15 approve_swap obert amb target param', 'FAIL',
      format('result=%s nou_propietari=%s', v_result,
        (SELECT employee_id FROM data.shift_slots WHERE id = v_open_slot_id)));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO sh_test_results VALUES ('T15 approve_swap obert amb target param', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T16: solapament real amb torn nocturn i dia següent
-- =============================================================================
DO $$
DECLARE
  v_result jsonb;
BEGIN
  -- Crear el torn extra com a postgres (authenticated no té INSERT a work_shifts)
  INSERT INTO data.work_shifts (id, tenant_id, site_id, name, color, start_time, end_time, is_active)
  VALUES ('ae100000-0000-0000-0000-000000000004', 'aa100000-0000-0000-0000-000000000001', 'ab100000-0000-0000-0000-000000000001', 'Madrugada', '#10b981', '05:00', '09:00', true)
  ON CONFLICT DO NOTHING;

  PERFORM set_config('request.jwt.claims',
    '{"sub":"ac100000-0000-0000-0000-000000000003","app_metadata":{"user_tenants":{"aa100000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"aa100000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","attendance.view_all"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  PERFORM api.assign_shift_slot('ad100000-0000-0000-0000-000000000001', '2026-07-20', 'ae100000-0000-0000-0000-000000000003');
  v_result := api.assign_shift_slot('ad100000-0000-0000-0000-000000000001', '2026-07-21', 'ae100000-0000-0000-0000-000000000004');

  SET LOCAL ROLE postgres;

  IF v_result->'anomalies' @> '["SHIFT_OVERLAP"]'::jsonb THEN
    INSERT INTO sh_test_results VALUES ('T16 overlap real nocturn', 'PASS',
      format('anomalies=%s', v_result->'anomalies'));
  ELSE
    INSERT INTO sh_test_results VALUES ('T16 overlap real nocturn', 'FAIL',
      format('result=%s', v_result));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO sh_test_results VALUES ('T16 overlap real nocturn', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T17: publish_shifts rebutja week_start que no és dilluns
-- =============================================================================
DO $$
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"ac100000-0000-0000-0000-000000000003","app_metadata":{"user_tenants":{"aa100000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"aa100000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","attendance.view_all"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  PERFORM api.publish_shifts('ab100000-0000-0000-0000-000000000001', '2026-07-07');

  SET LOCAL ROLE postgres;
  INSERT INTO sh_test_results VALUES ('T17 publish dilluns obligatori', 'FAIL',
    'Expected invalid_parameter_value not raised');
EXCEPTION WHEN invalid_parameter_value THEN
  SET LOCAL ROLE postgres;
  INSERT INTO sh_test_results VALUES ('T17 publish dilluns obligatori', 'PASS',
    format('Exception correcta: %s', SQLERRM));
WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO sh_test_results VALUES ('T17 publish dilluns obligatori', 'FAIL',
    format('Wrong exception: %s', SQLERRM));
END $$;


-- =============================================================================
-- T18: cobertura requerida retorna required_employee_count i coverage_delta
-- =============================================================================
DO $$
DECLARE
  v_result jsonb;
  v_req int;
  v_delta int;
BEGIN
  INSERT INTO data.shift_coverage_requirements (
    tenant_id, site_id, shift_id, day_of_week, required_employees, effective_from
  ) VALUES (
    'aa100000-0000-0000-0000-000000000001',
    'ab100000-0000-0000-0000-000000000001',
    'ae100000-0000-0000-0000-000000000001',
    2,
    3,
    '2026-06-01'
  );

  PERFORM set_config('request.jwt.claims',
    '{"sub":"ac100000-0000-0000-0000-000000000003","app_metadata":{"user_tenants":{"aa100000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"aa100000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","attendance.view_all","labor_calendar.view"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  v_result := api.get_coverage_for_period('ab100000-0000-0000-0000-000000000001', '2026-06-02', '2026-06-02');

  SET LOCAL ROLE postgres;

  v_req := (v_result->0->>'required_employee_count')::int;
  v_delta := (v_result->0->>'coverage_delta')::int;

  IF v_req = 3 AND v_delta IS NOT NULL THEN
    INSERT INTO sh_test_results VALUES ('T18 cobertura requerida', 'PASS',
      format('required=%s delta=%s', v_req, v_delta));
  ELSE
    INSERT INTO sh_test_results VALUES ('T18 cobertura requerida', 'FAIL',
      format('result=%s', v_result));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO sh_test_results VALUES ('T18 cobertura requerida', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T19: accept_shift_swap permet acceptar swap obert abans aprovació manager
-- =============================================================================
DO $$
DECLARE
  v_slot_id uuid;
  v_req_id uuid;
  v_result jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"ac100000-0000-0000-0000-000000000003","app_metadata":{"user_tenants":{"aa100000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"aa100000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","attendance.view_all"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;
  PERFORM api.assign_shift_slot('ad100000-0000-0000-0000-000000000001', '2026-07-28', 'ae100000-0000-0000-0000-000000000001');
  PERFORM api.publish_shifts(
    'ab100000-0000-0000-0000-000000000001',
    '2026-07-27',
    ARRAY['SHIFT_OVERLAP', 'WEEKLY_HOURS_EXCEEDED']
  );
  SET LOCAL ROLE postgres;

  SELECT id INTO v_slot_id
  FROM data.shift_slots
  WHERE employee_id = 'ad100000-0000-0000-0000-000000000001'
    AND slot_date = '2026-07-28'
    AND status = 'published'
  LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    '{"sub":"ac100000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"aa100000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"aa100000-0000-0000-0000-000000000001":{"global_permissions":["attendance.punch_own","absences.request"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;
  SELECT (api.request_shift_swap(v_slot_id, NULL, NULL, 'obert'))->>'request_id' INTO v_req_id;

  PERFORM set_config('request.jwt.claims',
    '{"sub":"ac100000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"aa100000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"aa100000-0000-0000-0000-000000000001":{"global_permissions":["attendance.punch_own","absences.request"],"sites":{}}}}}',
    true);

  v_result := api.accept_shift_swap(v_req_id, 'ad100000-0000-0000-0000-000000000002', NULL);

  SET LOCAL ROLE postgres;

  IF (v_result->>'target_employee_id')::uuid = 'ad100000-0000-0000-0000-000000000002' THEN
    INSERT INTO sh_test_results VALUES ('T19 accept_shift_swap obert', 'PASS',
      format('result=%s', v_result));
  ELSE
    INSERT INTO sh_test_results VALUES ('T19 accept_shift_swap obert', 'FAIL',
      format('result=%s', v_result));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO sh_test_results VALUES ('T19 accept_shift_swap obert', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T20: trigger integritat bloqueja site/tenant mismatch en work_shift
-- =============================================================================
DO $$
BEGIN
  INSERT INTO data.tenants (id, name, slug, is_active)
  VALUES ('aa200000-0000-0000-0000-000000000001', 'Other Tenant', 'other-shift-tenant', true)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO data.work_shifts (tenant_id, site_id, name, color, start_time, end_time)
  VALUES ('aa200000-0000-0000-0000-000000000001', 'ab100000-0000-0000-0000-000000000001', 'Invalid', '#000000', '09:00', '10:00');

  INSERT INTO sh_test_results VALUES ('T20 integritat tenant-site', 'FAIL',
    'Expected foreign_key_violation not raised');
EXCEPTION WHEN foreign_key_violation THEN
  INSERT INTO sh_test_results VALUES ('T20 integritat tenant-site', 'PASS',
    format('Exception correcta: %s', SQLERRM));
WHEN OTHERS THEN
  INSERT INTO sh_test_results VALUES ('T20 integritat tenant-site', 'FAIL',
    format('Wrong exception: %s', SQLERRM));
END $$;


-- =============================================================================
-- T21: trigger integritat bloqueja tenant mismatch en shift_slots
-- =============================================================================
DO $$
BEGIN
  INSERT INTO data.tenants (id, name, slug, is_active)
  VALUES ('aa200000-0000-0000-0000-000000000001', 'Other Tenant', 'other-shift-tenant', true)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO data.shift_slots (
    tenant_id, site_id, employee_id, shift_id,
    slot_date, status, start_time, end_time
  )
  VALUES (
    'aa200000-0000-0000-0000-000000000001',
    'ab100000-0000-0000-0000-000000000001',
    'ad100000-0000-0000-0000-000000000001',
    'ae100000-0000-0000-0000-000000000001',
    '2026-08-01',
    'draft',
    '09:00',
    '17:00'
  );

  INSERT INTO sh_test_results VALUES ('T21 integritat shift_slot tenant-employee', 'FAIL',
    'Expected foreign_key_violation not raised');
EXCEPTION WHEN foreign_key_violation THEN
  INSERT INTO sh_test_results VALUES ('T21 integritat shift_slot tenant-employee', 'PASS',
    format('Exception correcta: %s', SQLERRM));
WHEN OTHERS THEN
  INSERT INTO sh_test_results VALUES ('T21 integritat shift_slot tenant-employee', 'FAIL',
    format('Wrong exception: %s', SQLERRM));
END $$;


-- =============================================================================
-- T22: trigger integritat bloqueja requester_id inconsistent a shift_swap_requests
-- =============================================================================
DO $$
DECLARE
  v_slot_id      uuid;
  v_owner_id     uuid;
  v_bad_owner_id uuid;
BEGIN
  SELECT ss.id, ss.employee_id
  INTO v_slot_id, v_owner_id
  FROM data.shift_slots ss
  WHERE ss.tenant_id = 'aa100000-0000-0000-0000-000000000001'
    AND ss.status = 'published'
    AND NOT EXISTS (
      SELECT 1
      FROM data.shift_swap_requests r
      WHERE r.requester_slot_id = ss.id
        AND r.status = 'pending'
    )
  ORDER BY ss.slot_date, ss.id
  LIMIT 1;

  IF v_slot_id IS NULL THEN
    INSERT INTO sh_test_results VALUES ('T22 integritat swap requester mismatch', 'FAIL',
      'No published slot available without pending swap');
    RETURN;
  END IF;

  v_bad_owner_id := CASE
    WHEN v_owner_id = 'ad100000-0000-0000-0000-000000000001'::uuid
    THEN 'ad100000-0000-0000-0000-000000000002'::uuid
    ELSE 'ad100000-0000-0000-0000-000000000001'::uuid
  END;

  INSERT INTO data.shift_swap_requests (
    tenant_id, requester_slot_id, requester_id, status
  )
  VALUES (
    'aa100000-0000-0000-0000-000000000001',
    v_slot_id,
    v_bad_owner_id,
    'pending'
  );

  INSERT INTO sh_test_results VALUES ('T22 integritat swap requester mismatch', 'FAIL',
    'Expected foreign_key_violation not raised');
EXCEPTION WHEN foreign_key_violation THEN
  INSERT INTO sh_test_results VALUES ('T22 integritat swap requester mismatch', 'PASS',
    format('Exception correcta: %s', SQLERRM));
WHEN OTHERS THEN
  INSERT INTO sh_test_results VALUES ('T22 integritat swap requester mismatch', 'FAIL',
    format('Wrong exception: %s', SQLERRM));
END $$;


-- =============================================================================
-- T23: trigger integritat bloqueja tenant/site mismatch a coverage requirements
-- =============================================================================
DO $$
BEGIN
  INSERT INTO data.shift_coverage_requirements (
    tenant_id, site_id, day_of_week, required_employees, effective_from
  )
  VALUES (
    'aa200000-0000-0000-0000-000000000001',
    'ab100000-0000-0000-0000-000000000001',
    1,
    1,
    '2026-06-01'
  );

  INSERT INTO sh_test_results VALUES ('T23 integritat coverage tenant-site', 'FAIL',
    'Expected foreign_key_violation not raised');
EXCEPTION WHEN foreign_key_violation THEN
  INSERT INTO sh_test_results VALUES ('T23 integritat coverage tenant-site', 'PASS',
    format('Exception correcta: %s', SQLERRM));
WHEN OTHERS THEN
  INSERT INTO sh_test_results VALUES ('T23 integritat coverage tenant-site', 'FAIL',
    format('Wrong exception: %s', SQLERRM));
END $$;


-- =============================================================================
-- Resultat final
-- =============================================================================

SELECT
  test_name,
  status,
  details
FROM sh_test_results
ORDER BY test_name;

SELECT
  COUNT(*) FILTER (WHERE status = 'PASS')  AS passed,
  COUNT(*) FILTER (WHERE status = 'FAIL')  AS failed,
  COUNT(*) FILTER (WHERE status = 'ERROR') AS errors,
  COUNT(*)                                  AS total
FROM sh_test_results;

ROLLBACK;
