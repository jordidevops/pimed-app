-- =============================================================================
-- attendance_coverage_demand_ex062_tests.sql
-- EX-06.2 — Demanda recurrent/extraordinària + get_coverage suma
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0620000-0000-0000-0000-000000000001', 'EX062 Tenant', 'ex062-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b0620000-0000-0000-0000-000000000001', 'a0620000-0000-0000-0000-000000000001', 'EX062 Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0620000-0000-0000-0000-000000000001', 'emp@ex062.test', 'authenticated', 'authenticated'),
  ('c0620000-0000-0000-0000-000000000002', 'mgr@ex062.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0620000-0000-0000-0000-000000000001', 'emp@ex062.test', 'Emp EX062'),
  ('c0620000-0000-0000-0000-000000000002', 'mgr@ex062.test', 'Mgr EX062')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0620000-0000-0000-0000-000000000001', 'c0620000-0000-0000-0000-000000000001', 'member', true),
  (gen_random_uuid(), 'a0620000-0000-0000-0000-000000000001', 'c0620000-0000-0000-0000-000000000002', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status, weekly_hours)
VALUES (
  'd0620000-0000-0000-0000-000000000001',
  'a0620000-0000-0000-0000-000000000001',
  'b0620000-0000-0000-0000-000000000001',
  'c0620000-0000-0000-0000-000000000001',
  'Emp EX062', 'active', 40
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.work_roles (id, tenant_id, site_id, key, name, sort_order, is_active)
VALUES (
  'e0620000-0000-0000-0000-000000000001',
  'a0620000-0000-0000-0000-000000000001',
  NULL, 'cambrer', 'Cambrer', 10, true
)
ON CONFLICT (id) DO NOTHING;

CREATE TEMP TABLE ex062_results (
  test_name text, status text, details text
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.set_mgr_ctx() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0620000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0620000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0620000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0620000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","labor_calendar.view","attendance.view_all"],"sites":{}}}}}',
    true);
END;
$$;

-- T1 upsert recurring (effective des de fa 60 dies)
DO $$
DECLARE
  v_row jsonb;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_row := api.upsert_coverage_demand(
    NULL,
    'b0620000-0000-0000-0000-000000000001'::uuid,
    NULL,
    'e0620000-0000-0000-0000-000000000001'::uuid,
    'recurring',
    1::smallint,  -- Monday
    NULL,
    '12:00'::time,
    '15:00'::time,
    1, 3, 4,
    50, 'manual', 'Punta dinar', NULL,
    (CURRENT_DATE - 60), NULL, true, false, false
  );
  SET LOCAL ROLE postgres;
  IF v_row->>'kind' = 'recurring'
     AND (v_row->>'required_target')::int = 3
     AND (v_row->>'day_of_week')::int = 1
  THEN
    INSERT INTO ex062_results VALUES ('T1 upsert_recurring', 'PASS', v_row->>'id');
  ELSE
    INSERT INTO ex062_results VALUES ('T1 upsert_recurring', 'FAIL', v_row::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex062_results VALUES ('T1 upsert_recurring', 'ERROR', SQLERRM);
END;
$$;

-- T2 upsert extraordinary (same Monday as T3)
DO $$
DECLARE
  v_row jsonb;
  v_monday date := CURRENT_DATE - ((EXTRACT(DOW FROM CURRENT_DATE)::int + 6) % 7);
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_row := api.upsert_coverage_demand(
    NULL,
    'b0620000-0000-0000-0000-000000000001'::uuid,
    NULL, NULL,
    'extraordinary',
    NULL,
    v_monday,
    '18:00'::time,
    '22:00'::time,
    0, 2, NULL,
    10, 'event', 'Concert', NULL,
    NULL, NULL, true, false, false
  );
  SET LOCAL ROLE postgres;
  IF v_row->>'kind' = 'extraordinary'
     AND (v_row->>'demand_date')::date = v_monday
     AND (v_row->>'required_target')::int = 2
  THEN
    INSERT INTO ex062_results VALUES ('T2 upsert_extraordinary', 'PASS', v_monday::text);
  ELSE
    INSERT INTO ex062_results VALUES ('T2 upsert_extraordinary', 'FAIL', v_row::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex062_results VALUES ('T2 upsert_extraordinary', 'ERROR', SQLERRM);
END;
$$;

-- T3 sum helper on Monday = recurring 3 + extraordinary 2
DO $$
DECLARE
  v_monday date := CURRENT_DATE - ((EXTRACT(DOW FROM CURRENT_DATE)::int + 6) % 7);
  v_sum int;
BEGIN
  v_sum := data.sum_coverage_demand_target(
    'b0620000-0000-0000-0000-000000000001'::uuid,
    v_monday
  );

  IF v_sum = 5 THEN
    INSERT INTO ex062_results VALUES ('T3 sum_on_monday', 'PASS', format('sum=%s date=%s', v_sum, v_monday));
  ELSE
    INSERT INTO ex062_results VALUES ('T3 sum_on_monday', 'FAIL', format('sum=%s date=%s', v_sum, v_monday));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex062_results VALUES ('T3 sum_on_monday', 'ERROR', SQLERRM);
END;
$$;

-- T4 get_coverage includes demand target
DO $$
DECLARE
  v_monday date;
  v_cov jsonb;
  v_req int;
BEGIN
  v_monday := CURRENT_DATE - ((EXTRACT(DOW FROM CURRENT_DATE)::int + 6) % 7);

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_cov := api.get_coverage_for_period(
    'b0620000-0000-0000-0000-000000000001'::uuid,
    v_monday,
    v_monday
  );
  SET LOCAL ROLE postgres;

  v_req := COALESCE((v_cov->0->>'required_employee_count')::int, -1);

  IF jsonb_typeof(v_cov) = 'array' AND v_req >= 3 THEN
    INSERT INTO ex062_results VALUES ('T4 get_coverage_includes_demand', 'PASS', v_cov->0::text);
  ELSE
    INSERT INTO ex062_results VALUES ('T4 get_coverage_includes_demand', 'FAIL', v_cov::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex062_results VALUES ('T4 get_coverage_includes_demand', 'ERROR', SQLERRM);
END;
$$;

-- T5 list returns both
DO $$
DECLARE
  v_cnt int;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  SELECT count(*)::int INTO v_cnt
  FROM api.list_coverage_demands('b0620000-0000-0000-0000-000000000001'::uuid, false);
  SET LOCAL ROLE postgres;

  IF v_cnt >= 2 THEN
    INSERT INTO ex062_results VALUES ('T5 list_coverage_demands', 'PASS', format('cnt=%s', v_cnt));
  ELSE
    INSERT INTO ex062_results VALUES ('T5 list_coverage_demands', 'FAIL', format('cnt=%s', v_cnt));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex062_results VALUES ('T5 list_coverage_demands', 'ERROR', SQLERRM);
END;
$$;

SELECT test_name, status, details FROM ex062_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM ex062_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EX-06.2 tests failed: % row(s)', v_fail;
  END IF;
END;
$$;

ROLLBACK;
