-- =============================================================================
-- attendance_coverage_buckets_ex063_tests.sql
-- EX-06.3 — Buckets 15/30 min: demanda vs slots
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0630000-0000-0000-0000-000000000001', 'EX063 Tenant', 'ex063-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b0630000-0000-0000-0000-000000000001', 'a0630000-0000-0000-0000-000000000001', 'EX063 Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0630000-0000-0000-0000-000000000001', 'emp@ex063.test', 'authenticated', 'authenticated'),
  ('c0630000-0000-0000-0000-000000000002', 'mgr@ex063.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0630000-0000-0000-0000-000000000001', 'emp@ex063.test', 'Emp EX063'),
  ('c0630000-0000-0000-0000-000000000002', 'mgr@ex063.test', 'Mgr EX063')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0630000-0000-0000-0000-000000000001', 'c0630000-0000-0000-0000-000000000001', 'member', true),
  (gen_random_uuid(), 'a0630000-0000-0000-0000-000000000001', 'c0630000-0000-0000-0000-000000000002', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status, weekly_hours)
VALUES (
  'd0630000-0000-0000-0000-000000000001',
  'a0630000-0000-0000-0000-000000000001',
  'b0630000-0000-0000-0000-000000000001',
  'c0630000-0000-0000-0000-000000000001',
  'Emp EX063', 'active', 40
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.work_roles (id, tenant_id, key, name, sort_order, is_active)
VALUES ('e0630000-0000-0000-0000-000000000001', 'a0630000-0000-0000-0000-000000000001', 'cambrer', 'Cambrer', 10, true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.work_shifts (id, tenant_id, site_id, name, color, start_time, end_time, is_active, default_role_id)
VALUES (
  'f0630000-0000-0000-0000-000000000001',
  'a0630000-0000-0000-0000-000000000001',
  'b0630000-0000-0000-0000-000000000001',
  'Torn EX063', '#22c55e', '09:00', '17:00', true,
  'e0630000-0000-0000-0000-000000000001'
)
ON CONFLICT (id) DO NOTHING;

CREATE TEMP TABLE ex063_results (
  test_name text, status text, details text
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.set_mgr_ctx() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0630000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0630000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0630000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0630000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","labor_calendar.view","attendance.view_all"],"sites":{}}}}}',
    true);
END;
$$;

-- T1 overlap helper
DO $$
BEGIN
  IF data.time_range_overlaps_minutes(9*60, 12*60, 11*60, 13*60)
     AND NOT data.time_range_overlaps_minutes(9*60, 10*60, 10*60, 11*60)
     AND data.time_range_overlaps_minutes(22*60, 6*60, 23*60, 24*60)  -- overnight vs late
  THEN
    INSERT INTO ex063_results VALUES ('T1 overlap_helper', 'PASS', 'ok');
  ELSE
    INSERT INTO ex063_results VALUES ('T1 overlap_helper', 'FAIL', 'logic');
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex063_results VALUES ('T1 overlap_helper', 'ERROR', SQLERRM);
END;
$$;

-- Setup: demand 12:00-15:00 need 2 on a fixed Monday; one slot 09-17
DO $$
DECLARE
  v_monday date := CURRENT_DATE - ((EXTRACT(DOW FROM CURRENT_DATE)::int + 6) % 7);
BEGIN
  INSERT INTO data.coverage_demands (
    id, tenant_id, site_id, role_id, kind, day_of_week, demand_date,
    start_time, end_time, required_min, required_target, priority, source, name,
    effective_from, is_active
  ) VALUES (
    'a0630000-0000-0000-0000-000000000011',
    'a0630000-0000-0000-0000-000000000001',
    'b0630000-0000-0000-0000-000000000001',
    'e0630000-0000-0000-0000-000000000001',
    'recurring', 1, NULL,
    '12:00', '15:00', 0, 2, 50, 'manual', 'Punta',
    CURRENT_DATE - 60, true
  ) ON CONFLICT (id) DO NOTHING;

  INSERT INTO data.shift_slots (
    id, tenant_id, site_id, employee_id, shift_id, slot_date, status,
    start_time, end_time, role_id, role_name_snapshot
  ) VALUES (
    'a0630000-0000-0000-0000-000000000012',
    'a0630000-0000-0000-0000-000000000001',
    'b0630000-0000-0000-0000-000000000001',
    'd0630000-0000-0000-0000-000000000001',
    'f0630000-0000-0000-0000-000000000001',
    v_monday, 'published',
    '09:00', '17:00',
    'e0630000-0000-0000-0000-000000000001', 'Cambrer'
  ) ON CONFLICT (id) DO NOTHING;
END;
$$;

-- T2 buckets 30min: at 12:00 required=2 assigned=1 gap=-1
DO $$
DECLARE
  v_monday date := CURRENT_DATE - ((EXTRACT(DOW FROM CURRENT_DATE)::int + 6) % 7);
  v_buckets jsonb;
  v_row jsonb;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_buckets := api.get_coverage_buckets(
    'b0630000-0000-0000-0000-000000000001'::uuid,
    v_monday,
    30,
    NULL,
    NULL
  );
  SET LOCAL ROLE postgres;

  SELECT b INTO v_row
  FROM jsonb_array_elements(v_buckets) b
  WHERE b->>'bucket_start' = '12:00'
  LIMIT 1;

  IF v_row IS NOT NULL
     AND (v_row->>'required')::int = 2
     AND (v_row->>'assigned')::int = 1
     AND (v_row->>'gap')::int = -1
  THEN
    INSERT INTO ex063_results VALUES ('T2 gap_at_noon', 'PASS', v_row::text);
  ELSE
    INSERT INTO ex063_results VALUES ('T2 gap_at_noon', 'FAIL', COALESCE(v_row::text, v_buckets::text));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex063_results VALUES ('T2 gap_at_noon', 'ERROR', SQLERRM);
END;
$$;

-- T3 outside demand window (10:00) required=0 assigned=1 (slot 09-17)
DO $$
DECLARE
  v_monday date := CURRENT_DATE - ((EXTRACT(DOW FROM CURRENT_DATE)::int + 6) % 7);
  v_buckets jsonb;
  v_row jsonb;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_buckets := api.get_coverage_buckets(
    'b0630000-0000-0000-0000-000000000001'::uuid,
    v_monday, 30, NULL, NULL
  );
  SET LOCAL ROLE postgres;

  SELECT b INTO v_row
  FROM jsonb_array_elements(v_buckets) b
  WHERE b->>'bucket_start' = '10:00'
  LIMIT 1;

  IF v_row IS NOT NULL
     AND (v_row->>'required')::int = 0
     AND (v_row->>'assigned')::int = 1
     AND (v_row->>'gap')::int = 1
  THEN
    INSERT INTO ex063_results VALUES ('T3 outside_demand', 'PASS', v_row::text);
  ELSE
    INSERT INTO ex063_results VALUES ('T3 outside_demand', 'FAIL', COALESCE(v_row::text, 'missing'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex063_results VALUES ('T3 outside_demand', 'ERROR', SQLERRM);
END;
$$;

-- T4 filter by role that has no demand match still counts role-null demands? 
-- Demand has role cambrer; filter other role → demand excluded (role mismatch), slot excluded
DO $$
DECLARE
  v_monday date := CURRENT_DATE - ((EXTRACT(DOW FROM CURRENT_DATE)::int + 6) % 7);
  v_other uuid;
  v_buckets jsonb;
  v_row jsonb;
BEGIN
  INSERT INTO data.work_roles (id, tenant_id, key, name, sort_order, is_active)
  VALUES ('e0630000-0000-0000-0000-000000000002', 'a0630000-0000-0000-0000-000000000001', 'cuina', 'Cuina', 20, true)
  ON CONFLICT (id) DO NOTHING;
  v_other := 'e0630000-0000-0000-0000-000000000002'::uuid;

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_buckets := api.get_coverage_buckets(
    'b0630000-0000-0000-0000-000000000001'::uuid,
    v_monday, 30, v_other, NULL
  );
  SET LOCAL ROLE postgres;

  SELECT b INTO v_row
  FROM jsonb_array_elements(v_buckets) b
  WHERE b->>'bucket_start' = '12:00'
  LIMIT 1;

  IF v_row IS NOT NULL
     AND (v_row->>'required')::int = 0
     AND (v_row->>'assigned')::int = 0
  THEN
    INSERT INTO ex063_results VALUES ('T4 role_filter', 'PASS', v_row::text);
  ELSE
    INSERT INTO ex063_results VALUES ('T4 role_filter', 'FAIL', COALESCE(v_row::text, 'missing'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex063_results VALUES ('T4 role_filter', 'ERROR', SQLERRM);
END;
$$;

-- T5 invalid bucket size
DO $$
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  PERFORM api.get_coverage_buckets(
    'b0630000-0000-0000-0000-000000000001'::uuid,
    CURRENT_DATE, 20, NULL, NULL
  );
  SET LOCAL ROLE postgres;
  INSERT INTO ex063_results VALUES ('T5 invalid_bucket', 'FAIL', 'expected error');
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  IF SQLERRM ILIKE '%invalid_bucket%' THEN
    INSERT INTO ex063_results VALUES ('T5 invalid_bucket', 'PASS', SQLERRM);
  ELSE
    INSERT INTO ex063_results VALUES ('T5 invalid_bucket', 'ERROR', SQLERRM);
  END IF;
END;
$$;

SELECT test_name, status, details FROM ex063_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM ex063_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EX-06.3 tests failed: % row(s)', v_fail;
  END IF;
END;
$$;

ROLLBACK;
