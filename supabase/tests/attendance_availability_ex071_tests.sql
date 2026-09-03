-- =============================================================================
-- attendance_availability_ex071_tests.sql
-- EX-07.1 — Regles / excepcions / resolve disponibilitat
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0710000-0000-0000-0000-000000000001', 'EX071 Tenant', 'ex071-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b0710000-0000-0000-0000-000000000001', 'a0710000-0000-0000-0000-000000000001', 'EX071 Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0710000-0000-0000-0000-000000000001', 'emp@ex071.test', 'authenticated', 'authenticated'),
  ('c0710000-0000-0000-0000-000000000002', 'mgr@ex071.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0710000-0000-0000-0000-000000000001', 'emp@ex071.test', 'Emp EX071'),
  ('c0710000-0000-0000-0000-000000000002', 'mgr@ex071.test', 'Mgr EX071')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0710000-0000-0000-0000-000000000001', 'c0710000-0000-0000-0000-000000000001', 'member', true),
  (gen_random_uuid(), 'a0710000-0000-0000-0000-000000000001', 'c0710000-0000-0000-0000-000000000002', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status, weekly_hours)
VALUES (
  'd0710000-0000-0000-0000-000000000001',
  'a0710000-0000-0000-0000-000000000001',
  'b0710000-0000-0000-0000-000000000001',
  'c0710000-0000-0000-0000-000000000001',
  'Emp EX071', 'active', 40
)
ON CONFLICT (id) DO NOTHING;

CREATE TEMP TABLE ex071_results (
  test_name text, status text, details text
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.set_mgr_ctx() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0710000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0710000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0710000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0710000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","labor_calendar.view","attendance.view_all"],"sites":{}}}}}',
    true);
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.set_emp_ctx() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0710000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0710000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"a0710000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"a0710000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{}}}}}',
    true);
END;
$$;

-- T1: regla dilluns preferred 09-17
DO $$
DECLARE
  v_row jsonb;
  v_monday date := date '2026-07-13';
  v_resolved jsonb;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_row := api.upsert_employee_availability_rule(
    NULL::uuid,
    'd0710000-0000-0000-0000-000000000001'::uuid,
    1::smallint,
    '09:00'::time,
    '17:00'::time,
    'preferred'::text,
    'torn matí'::text,
    NULL::date,
    v_monday - 7,
    NULL::date,
    true
  );
  v_resolved := api.resolve_employee_availability(
    'd0710000-0000-0000-0000-000000000001'::uuid,
    v_monday,
    '10:00'::time,
    '12:00'::time
  );
  SET LOCAL ROLE postgres;

  IF v_row->>'preference' = 'preferred'
     AND v_resolved->>'preference' = 'preferred'
     AND v_resolved->>'source' = 'rule'
  THEN
    INSERT INTO ex071_results VALUES ('T1 rule_resolve', 'PASS', v_resolved::text);
  ELSE
    INSERT INTO ex071_results VALUES ('T1 rule_resolve', 'FAIL', v_resolved::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex071_results VALUES ('T1 rule_resolve', 'ERROR', SQLERRM);
END;
$$;

-- T2: excepció unavailable tot el dia substitueix regla
DO $$
DECLARE
  v_monday date := date '2026-07-13';
  v_exc jsonb;
  v_resolved jsonb;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_exc := api.upsert_employee_availability_exception(
    NULL::uuid,
    'd0710000-0000-0000-0000-000000000001'::uuid,
    v_monday,
    NULL::time, NULL::time,
    'unavailable'::text,
    'festa personal'::text,
    NULL::date,
    true,
    true
  );
  v_resolved := api.resolve_employee_availability(
    'd0710000-0000-0000-0000-000000000001'::uuid,
    v_monday,
    '10:00'::time,
    '12:00'::time
  );
  SET LOCAL ROLE postgres;

  IF v_exc->>'preference' = 'unavailable'
     AND v_resolved->>'preference' = 'unavailable'
     AND v_resolved->>'source' = 'exception'
  THEN
    INSERT INTO ex071_results VALUES ('T2 exception_overrides', 'PASS', v_resolved::text);
  ELSE
    INSERT INTO ex071_results VALUES ('T2 exception_overrides', 'FAIL', v_resolved::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex071_results VALUES ('T2 exception_overrides', 'ERROR', SQLERRM);
END;
$$;

-- T3: dimarts sense regla → unknown
DO $$
DECLARE
  v_tue date := date '2026-07-14';
  v_resolved jsonb;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_resolved := api.resolve_employee_availability(
    'd0710000-0000-0000-0000-000000000001'::uuid,
    v_tue,
    '10:00'::time,
    '12:00'::time
  );
  SET LOCAL ROLE postgres;

  IF v_resolved->>'preference' = 'unknown'
     AND v_resolved->>'source' = 'none'
  THEN
    INSERT INTO ex071_results VALUES ('T3 unknown_day', 'PASS', v_resolved::text);
  ELSE
    INSERT INTO ex071_results VALUES ('T3 unknown_day', 'FAIL', v_resolved::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex071_results VALUES ('T3 unknown_day', 'ERROR', SQLERRM);
END;
$$;

-- T4: empleat pot crear regla pròpia; list_site_availability
DO $$
DECLARE
  v_row jsonb;
  v_site jsonb;
  v_found boolean := false;
  e jsonb;
BEGIN
  PERFORM pg_temp.set_emp_ctx();
  SET LOCAL ROLE authenticated;
  v_row := api.upsert_employee_availability_rule(
    NULL::uuid,
    'd0710000-0000-0000-0000-000000000001'::uuid,
    2::smallint,
    '08:00'::time,
    '12:00'::time,
    'available'::text,
    NULL::text, NULL::date, date '2026-07-01', NULL::date, true
  );
  SET LOCAL ROLE postgres;

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_site := api.list_site_availability(
    'b0710000-0000-0000-0000-000000000001'::uuid,
    date '2026-07-14',
    '09:00'::time,
    '11:00'::time
  );
  SET LOCAL ROLE postgres;

  FOR e IN SELECT * FROM jsonb_array_elements(v_site->'employees')
  LOOP
    IF e->>'employee_id' = 'd0710000-0000-0000-0000-000000000001'
       AND e->>'preference' = 'available'
    THEN
      v_found := true;
    END IF;
  END LOOP;

  IF v_row->>'day_of_week' = '2' AND v_found THEN
    INSERT INTO ex071_results VALUES ('T4 self_and_site_list', 'PASS', v_site::text);
  ELSE
    INSERT INTO ex071_results VALUES ('T4 self_and_site_list', 'FAIL', COALESCE(v_site::text, v_row::text));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex071_results VALUES ('T4 self_and_site_list', 'ERROR', SQLERRM);
END;
$$;

-- T5: editable_until bloqueja empleat
DO $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO data.employee_availability_rules (
    id, tenant_id, employee_id, day_of_week, start_time, end_time,
    preference, editable_until, effective_from, is_active
  ) VALUES (
    'a0710000-0000-0000-0000-000000000099',
    'a0710000-0000-0000-0000-000000000001',
    'd0710000-0000-0000-0000-000000000001',
    3, '10:00', '14:00', 'available',
    CURRENT_DATE - 1,
    CURRENT_DATE - 30,
    true
  );

  PERFORM pg_temp.set_emp_ctx();
  SET LOCAL ROLE authenticated;
  PERFORM api.upsert_employee_availability_rule(
    'a0710000-0000-0000-0000-000000000099'::uuid,
    NULL::uuid, NULL::smallint, NULL::time, NULL::time,
    'preferred'::text, NULL::text, NULL::date, NULL::date, NULL::date, true
  );
  SET LOCAL ROLE postgres;
  INSERT INTO ex071_results VALUES ('T5 editable_until', 'FAIL', 'expected error');
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  IF SQLERRM ILIKE '%editable_until%' THEN
    INSERT INTO ex071_results VALUES ('T5 editable_until', 'PASS', SQLERRM);
  ELSE
    INSERT INTO ex071_results VALUES ('T5 editable_until', 'ERROR', SQLERRM);
  END IF;
END;
$$;

SELECT test_name, status, details FROM ex071_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM ex071_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EX-07.1 tests failed: % row(s)', v_fail;
  END IF;
END;
$$;

ROLLBACK;
