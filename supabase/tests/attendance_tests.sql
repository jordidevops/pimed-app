-- =============================================================================
-- attendance_tests.sql
-- Cobertura Phase 1A: api.record_time_punch, api.sync_time_punches,
--                     api.approve_time_day, api.adjust_time_entry, RLS
--
-- Executar contra DB local:
--   psql "$DB_URL" -f supabase/tests/attendance_tests.sql
--
-- Tests:
--   T1  record_time_punch — fitxatge bàsic IN crea punch i encua recompute
--   T2  record_time_punch — idempotència: duplicate si mateix client_op_id
--   T3  record_time_punch — rebutjat si empleat inactiu
--   T4  record_time_punch — CLOCK_SKEW anotiat si offset > threshold
--   T5  sync_time_punches — batch processa cada op independentment
--   T6  RLS — empleat no veu fitxatges d'un altre empleat
--   T7  approve_time_day — rebutjat si l'usuari no té attendance.approve
--   T8  approve_time_day — aprova correctament com a manager
--   T9  adjust_time_entry — bloquejat si dia exportat (payroll_locked_at)
--   T10 get_role_permissions — viewer té attendance.view_own, manager attendance.approve
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Fixtures: dades de prova (tot dins la transacció → ROLLBACK al final)
-- ---------------------------------------------------------------------------

-- Tenant de prova
INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0000000-0000-0000-0000-000000000001', 'Test Attendance Tenant', 'test-attend', true)
ON CONFLICT (id) DO NOTHING;

-- Site
INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'Site Test', true)
ON CONFLICT (id) DO NOTHING;

-- Perfils d'usuari
INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0000000-0000-0000-0000-000000000001', 'alice@test.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-000000000002', 'bob@test.com',   'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-000000000003', 'mgr@test.com',   'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0000000-0000-0000-0000-000000000001', 'alice@test.com', 'Alice Test'),
  ('c0000000-0000-0000-0000-000000000002', 'bob@test.com',   'Bob Test'),
  ('c0000000-0000-0000-0000-000000000003', 'mgr@test.com',   'Manager Test')
ON CONFLICT (id) DO NOTHING;

-- Membresies
INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'member',  true),
  (gen_random_uuid(), 'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000002', 'member',  true),
  (gen_random_uuid(), 'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000003', 'manager', true)
ON CONFLICT DO NOTHING;

-- Empleats
INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES
  ('d0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'Alice Employee', 'active'),
  ('d0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000002', 'Bob Employee',   'active'),
  ('d0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', NULL,                                    'Inactive Emp',   'inactive')
ON CONFLICT (id) DO NOTHING;

-- Taula de resultats
CREATE TEMP TABLE att_test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;


-- =============================================================================
-- T1: record_time_punch — fitxatge bàsic IN
-- =============================================================================
DO $$
DECLARE
  v_result    jsonb;
  v_punch_id  uuid;
  v_op_id     uuid := 'e0000000-0000-0000-0000-000000000001';
BEGIN
  -- Simular Alice (membre) fitxant el seu propi fitxatge
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0000000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"a0000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true);
  PERFORM set_config('request.headers', '{"x-tenant-id":"a0000000-0000-0000-0000-000000000001"}', true);

  SET LOCAL ROLE authenticated;

  v_result := api.record_time_punch(
    p_employee_id  => 'd0000000-0000-0000-0000-000000000001',
    p_client_op_id => v_op_id,
    p_punch_type   => 'in',
    p_occurred_at  => now()
  );

  SET LOCAL ROLE postgres;

  v_punch_id := (v_result->>'punch_id')::uuid;

  IF v_result->>'status' = 'created' AND v_punch_id IS NOT NULL THEN
    INSERT INTO att_test_results VALUES ('T1 record_time_punch basico IN', 'PASS',
      format('punch_id=%s status=%s', v_punch_id, v_result->>'status'));
  ELSE
    INSERT INTO att_test_results VALUES ('T1 record_time_punch basico IN', 'FAIL',
      format('result=%s', v_result));
  END IF;

EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO att_test_results VALUES ('T1 record_time_punch basico IN', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T2: record_time_punch — idempotència (duplicate)
-- =============================================================================
DO $$
DECLARE
  v_result1  jsonb;
  v_result2  jsonb;
  v_op_id    uuid := 'e0000000-0000-0000-0000-000000000002';
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0000000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"a0000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true);
  PERFORM set_config('request.headers', '{"x-tenant-id":"a0000000-0000-0000-0000-000000000001"}', true);

  SET LOCAL ROLE authenticated;

  v_result1 := api.record_time_punch('d0000000-0000-0000-0000-000000000001', v_op_id, 'in', now());
  v_result2 := api.record_time_punch('d0000000-0000-0000-0000-000000000001', v_op_id, 'in', now());

  SET LOCAL ROLE postgres;

  IF v_result1->>'status' = 'created' AND v_result2->>'status' = 'duplicate' THEN
    INSERT INTO att_test_results VALUES ('T2 idempotencia duplicate', 'PASS',
      format('1st=%s 2nd=%s', v_result1->>'status', v_result2->>'status'));
  ELSE
    INSERT INTO att_test_results VALUES ('T2 idempotencia duplicate', 'FAIL',
      format('1st=%s 2nd=%s', v_result1->>'status', v_result2->>'status'));
  END IF;

EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO att_test_results VALUES ('T2 idempotencia duplicate', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T3: record_time_punch — empleat inactiu → rebutjat
-- =============================================================================
DO $$
DECLARE
  v_op_id  uuid := 'e0000000-0000-0000-0000-000000000003';
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0000000-0000-0000-0000-000000000003","app_metadata":{"user_tenants":{"a0000000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}}}}',
    true);

  SET LOCAL ROLE authenticated;

  -- Intentem fitxar un empleat inactiu (d000...003)
  PERFORM api.record_time_punch('d0000000-0000-0000-0000-000000000003', v_op_id, 'in', now());

  SET LOCAL ROLE postgres;
  INSERT INTO att_test_results VALUES ('T3 empleat inactiu rebutjat', 'FAIL', 'Expected exception not raised');

EXCEPTION WHEN check_violation THEN
  SET LOCAL ROLE postgres;
  INSERT INTO att_test_results VALUES ('T3 empleat inactiu rebutjat', 'PASS',
    format('Exception correcta: %s', SQLERRM));
WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO att_test_results VALUES ('T3 empleat inactiu rebutjat', 'FAIL',
    format('Wrong exception: %s', SQLERRM));
END $$;


-- =============================================================================
-- T4: record_time_punch — CLOCK_SKEW si offset > 5 minuts
-- =============================================================================
DO $$
DECLARE
  v_result  jsonb;
  v_op_id   uuid := 'e0000000-0000-0000-0000-000000000004';
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0000000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"a0000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true);
  PERFORM set_config('request.headers', '{"x-tenant-id":"a0000000-0000-0000-0000-000000000001"}', true);

  SET LOCAL ROLE authenticated;

  -- Timestamp desfasat 10 minuts en el futur
  v_result := api.record_time_punch(
    p_employee_id  => 'd0000000-0000-0000-0000-000000000001',
    p_client_op_id => v_op_id,
    p_punch_type   => 'in',
    p_occurred_at  => now() + interval '10 minutes'
  );

  SET LOCAL ROLE postgres;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements_text(v_result->'anomaly_codes') AS x(code)
    WHERE x.code = 'CLOCK_SKEW'
  ) THEN
    INSERT INTO att_test_results VALUES ('T4 CLOCK_SKEW detectat', 'PASS',
      format('anomaly_codes=%s', v_result->'anomaly_codes'));
  ELSE
    INSERT INTO att_test_results VALUES ('T4 CLOCK_SKEW detectat', 'FAIL',
      format('anomaly_codes=%s', v_result->'anomaly_codes'));
  END IF;

EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO att_test_results VALUES ('T4 CLOCK_SKEW detectat', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T5: sync_time_punches — batch amb 2 ops vàlides + 1 kind desconegut
-- =============================================================================
DO $$
DECLARE
  v_result  jsonb;
  v_count   int;
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true);
  PERFORM set_config('request.headers', '{"x-tenant-id":"a0000000-0000-0000-0000-000000000001"}', true);

  SET LOCAL ROLE authenticated;

  v_result := api.sync_time_punches('[
    {
      "id": "e0000000-0000-0000-0000-000000000010",
      "kind": "punch",
      "payload": {
        "employee_id": "d0000000-0000-0000-0000-000000000002",
        "punch_type": "in",
        "occurred_at": "2026-01-15T08:00:00+01:00"
      }
    },
    {
      "id": "e0000000-0000-0000-0000-000000000011",
      "kind": "punch",
      "payload": {
        "employee_id": "d0000000-0000-0000-0000-000000000002",
        "punch_type": "out",
        "occurred_at": "2026-01-15T17:00:00+01:00"
      }
    },
    {
      "id": "e0000000-0000-0000-0000-000000000012",
      "kind": "unknown_op",
      "payload": {}
    }
  ]'::jsonb);

  SET LOCAL ROLE postgres;

  SELECT COUNT(*) INTO v_count
  FROM jsonb_array_elements(v_result) AS r
  WHERE r->>'status' = 'created';

  IF v_count = 2 AND (
    SELECT COUNT(*) FROM jsonb_array_elements(v_result) AS r WHERE r->>'status' = 'rejected'
  ) = 1 THEN
    INSERT INTO att_test_results VALUES ('T5 sync_time_punches batch', 'PASS',
      format('created=%s rejected=1', v_count));
  ELSE
    INSERT INTO att_test_results VALUES ('T5 sync_time_punches batch', 'FAIL',
      format('result=%s', v_result));
  END IF;

EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO att_test_results VALUES ('T5 sync_time_punches batch', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T6: RLS — Alice no veu fitxatges de Bob
-- =============================================================================
DO $$
DECLARE
  v_alice_count int;
  v_bob_count   int;
BEGIN
  -- Inserir un fitxatge de Bob directament (service_role)
  INSERT INTO data.time_punches (tenant_id, site_id, employee_id, client_op_id, punch_type, occurred_at)
  VALUES (
    'a0000000-0000-0000-0000-000000000001',
    'b0000000-0000-0000-0000-000000000001',
    'd0000000-0000-0000-0000-000000000002',
    'e0000000-0000-0000-0000-000000000020',
    'in', now()
  ) ON CONFLICT DO NOTHING;

  -- Alice autenticada
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0000000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"a0000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true);
  PERFORM set_config('request.headers', '{"x-tenant-id":"a0000000-0000-0000-0000-000000000001"}', true);

  SET LOCAL ROLE authenticated;

  SELECT COUNT(*) INTO v_alice_count
  FROM api.time_punches
  WHERE employee_id = 'd0000000-0000-0000-0000-000000000001'::uuid;

  SELECT COUNT(*) INTO v_bob_count
  FROM api.time_punches
  WHERE employee_id = 'd0000000-0000-0000-0000-000000000002'::uuid;

  SET LOCAL ROLE postgres;

  IF v_bob_count = 0 THEN
    INSERT INTO att_test_results VALUES ('T6 RLS Alice no veu Bob', 'PASS',
      format('alice_punches=%s bob_visible=%s', v_alice_count, v_bob_count));
  ELSE
    INSERT INTO att_test_results VALUES ('T6 RLS Alice no veu Bob', 'FAIL',
      format('bob_visible=%s (should be 0)', v_bob_count));
  END IF;

EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO att_test_results VALUES ('T6 RLS Alice no veu Bob', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T7: approve_time_day — membre sense permís → rebutjat
-- =============================================================================
DO $$
DECLARE
  v_work_date date := '2026-01-15';
BEGIN
  -- Crear resum de prova
  INSERT INTO data.time_daily_summaries
    (tenant_id, site_id, employee_id, work_date, status)
  VALUES
    ('a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001',
     'd0000000-0000-0000-0000-000000000001', v_work_date, 'draft')
  ON CONFLICT (employee_id, work_date) DO UPDATE SET status = 'draft';

  -- Bob és membre → no té attendance.approve
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"a0000000-0000-0000-0000-000000000001":{"global_permissions":["attendance.view_own","attendance.punch_own"],"sites":{}}}}}',
    true);
  PERFORM set_config('request.headers', '{"x-tenant-id":"a0000000-0000-0000-0000-000000000001"}', true);

  SET LOCAL ROLE authenticated;

  PERFORM api.approve_time_day('d0000000-0000-0000-0000-000000000001', v_work_date);

  SET LOCAL ROLE postgres;
  INSERT INTO att_test_results VALUES ('T7 approve rebutjat sense permis', 'FAIL', 'Expected exception not raised');

EXCEPTION WHEN insufficient_privilege THEN
  SET LOCAL ROLE postgres;
  INSERT INTO att_test_results VALUES ('T7 approve rebutjat sense permis', 'PASS',
    format('Exception: %s', SQLERRM));
WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO att_test_results VALUES ('T7 approve rebutjat sense permis', 'FAIL',
    format('Wrong exception: %s', SQLERRM));
END $$;


-- =============================================================================
-- T8: approve_time_day — manager aprova correctament
-- =============================================================================
DO $$
DECLARE
  v_result     jsonb;
  v_work_date  date := '2026-01-16';
  v_new_status text;
BEGIN
  INSERT INTO data.time_daily_summaries
    (tenant_id, site_id, employee_id, work_date, status)
  VALUES
    ('a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001',
     'd0000000-0000-0000-0000-000000000001', v_work_date, 'draft')
  ON CONFLICT (employee_id, work_date) DO UPDATE SET status = 'draft', approved_by = NULL, approved_at = NULL;

  -- Manager amb attendance.approve
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0000000-0000-0000-0000-000000000003","app_metadata":{"user_tenants":{"a0000000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0000000-0000-0000-0000-000000000001":["attendance.approve","attendance.view_all"]}}}',
    true);

  SET LOCAL ROLE authenticated;

  v_result := api.approve_time_day('d0000000-0000-0000-0000-000000000001', v_work_date);

  SET LOCAL ROLE postgres;

  SELECT status INTO v_new_status
  FROM data.time_daily_summaries
  WHERE employee_id = 'd0000000-0000-0000-0000-000000000001' AND work_date = v_work_date;

  IF v_result->>'status' = 'approved' AND v_new_status = 'approved' THEN
    INSERT INTO att_test_results VALUES ('T8 manager aprova dia', 'PASS',
      format('rpc_status=%s db_status=%s', v_result->>'status', v_new_status));
  ELSE
    INSERT INTO att_test_results VALUES ('T8 manager aprova dia', 'FAIL',
      format('rpc_status=%s db_status=%s', v_result->>'status', v_new_status));
  END IF;

EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO att_test_results VALUES ('T8 manager aprova dia', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- T9: adjust_time_entry — bloquejat si payroll_locked_at IS NOT NULL
-- =============================================================================
DO $$
DECLARE
  v_work_date  date := '2026-01-17';
BEGIN
  -- Crear entrada i resum exportats
  INSERT INTO data.time_entries
    (tenant_id, site_id, employee_id, work_date, net_minutes, status)
  VALUES
    ('a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001',
     'd0000000-0000-0000-0000-000000000001', v_work_date, 480, 'closed')
  ON CONFLICT (employee_id, work_date) DO UPDATE SET status = 'closed';

  INSERT INTO data.time_daily_summaries
    (tenant_id, site_id, employee_id, work_date, status, payroll_locked_at, worked_minutes)
  VALUES
    ('a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001',
     'd0000000-0000-0000-0000-000000000001', v_work_date, 'exported', now(), 480)
  ON CONFLICT (employee_id, work_date) DO UPDATE
    SET status = 'exported', payroll_locked_at = now();

  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0000000-0000-0000-0000-000000000003","app_metadata":{"user_tenants":{"a0000000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0000000-0000-0000-0000-000000000001":["attendance.adjust"]}}}',
    true);

  SET LOCAL ROLE authenticated;

  PERFORM api.adjust_time_entry('d0000000-0000-0000-0000-000000000001', v_work_date, 450, NULL, 'test');

  SET LOCAL ROLE postgres;
  INSERT INTO att_test_results VALUES ('T9 adjust bloquejat si exportat', 'FAIL', 'Expected exception not raised');

EXCEPTION WHEN check_violation THEN
  SET LOCAL ROLE postgres;
  INSERT INTO att_test_results VALUES ('T9 adjust bloquejat si exportat', 'PASS',
    format('Exception: %s', SQLERRM));
WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO att_test_results VALUES ('T9 adjust bloquejat si exportat', 'FAIL',
    format('Wrong exception: %s', SQLERRM));
END $$;


-- =============================================================================
-- T10: get_role_permissions — viewer té attendance.view_own, manager té approve
-- =============================================================================
DO $$
DECLARE
  v_viewer_perms   text[];
  v_member_perms   text[];
  v_manager_perms  text[];
BEGIN
  v_viewer_perms  := data.get_role_permissions('viewer');
  v_member_perms  := data.get_role_permissions('member');
  v_manager_perms := data.get_role_permissions('manager');

  IF 'attendance.view_own'  = ANY(v_viewer_perms)
    AND 'labor_calendar.view' = ANY(v_viewer_perms) THEN
    INSERT INTO att_test_results VALUES ('T10a viewer perms attendance', 'PASS',
      'attendance.view_own i labor_calendar.view presents');
  ELSE
    INSERT INTO att_test_results VALUES ('T10a viewer perms attendance', 'FAIL',
      format('viewer_perms=%s', v_viewer_perms));
  END IF;

  IF 'attendance.punch_own' = ANY(v_member_perms)
    AND 'absences.request'  = ANY(v_member_perms) THEN
    INSERT INTO att_test_results VALUES ('T10b member perms attendance', 'PASS',
      'attendance.punch_own i absences.request presents');
  ELSE
    INSERT INTO att_test_results VALUES ('T10b member perms attendance', 'FAIL',
      format('member_perms=%s', v_member_perms));
  END IF;

  IF 'attendance.approve' = ANY(v_manager_perms)
    AND 'attendance.export' = ANY(v_manager_perms)
    AND 'attendance.view_all' = ANY(v_manager_perms) THEN
    INSERT INTO att_test_results VALUES ('T10c manager perms attendance', 'PASS',
      'attendance.approve, .export, .view_all presents');
  ELSE
    INSERT INTO att_test_results VALUES ('T10c manager perms attendance', 'FAIL',
      format('manager_perms=%s', v_manager_perms));
  END IF;

EXCEPTION WHEN OTHERS THEN
  INSERT INTO att_test_results VALUES ('T10 get_role_permissions', 'ERROR', SQLERRM);
END $$;


-- =============================================================================
-- Resultat final
-- =============================================================================

SELECT
  test_name,
  status,
  details
FROM att_test_results
ORDER BY test_name;

SELECT
  COUNT(*) FILTER (WHERE status = 'PASS')  AS passed,
  COUNT(*) FILTER (WHERE status = 'FAIL')  AS failed,
  COUNT(*) FILTER (WHERE status = 'ERROR') AS errors,
  COUNT(*)                                 AS total
FROM att_test_results;

ROLLBACK;
