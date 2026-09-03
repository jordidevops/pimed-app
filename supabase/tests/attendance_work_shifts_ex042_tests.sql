-- =============================================================================
-- attendance_work_shifts_ex042_tests.sql
-- EX-04.2 — CRUD work_shifts + multi-slot / anomalies (assign)
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0420000-0000-0000-0000-000000000001', 'EX042 Tenant', 'ex042-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b0420000-0000-0000-0000-000000000001', 'a0420000-0000-0000-0000-000000000001', 'EX042 Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0420000-0000-0000-0000-000000000001', 'emp@ex042.test', 'authenticated', 'authenticated'),
  ('c0420000-0000-0000-0000-000000000002', 'mgr@ex042.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0420000-0000-0000-0000-000000000001', 'emp@ex042.test', 'Emp EX042'),
  ('c0420000-0000-0000-0000-000000000002', 'mgr@ex042.test', 'Mgr EX042')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0420000-0000-0000-0000-000000000001', 'c0420000-0000-0000-0000-000000000001', 'member', true),
  (gen_random_uuid(), 'a0420000-0000-0000-0000-000000000001', 'c0420000-0000-0000-0000-000000000002', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status, weekly_hours)
VALUES (
  'd0420000-0000-0000-0000-000000000001',
  'a0420000-0000-0000-0000-000000000001',
  'b0420000-0000-0000-0000-000000000001',
  'c0420000-0000-0000-0000-000000000001',
  'Emp EX042', 'active', 20
)
ON CONFLICT (id) DO NOTHING;

CREATE TEMP TABLE ex042_results (
  test_name text, status text, details text
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.set_mgr_ctx() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0420000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0420000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0420000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0420000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","attendance.view_all"],"sites":{}}}}}',
    true);
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.set_member_ctx() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0420000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0420000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"a0420000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"a0420000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{}}}}}',
    true);
END;
$$;

-- T1 create
DO $$
DECLARE
  v_row jsonb;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_row := api.create_work_shift(
    'b0420000-0000-0000-0000-000000000001'::uuid,
    'Matí EX042',
    '09:00'::time,
    '13:00'::time,
    '#3b82f6'
  );
  SET LOCAL ROLE postgres;
  IF v_row->>'name' = 'Matí EX042'
     AND (v_row->>'start_time') LIKE '09:00%'
     AND (v_row->>'is_active')::boolean = true
  THEN
    INSERT INTO ex042_results VALUES ('T1 create_work_shift', 'PASS', v_row->>'id');
  ELSE
    INSERT INTO ex042_results VALUES ('T1 create_work_shift', 'FAIL', v_row::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex042_results VALUES ('T1 create_work_shift', 'ERROR', SQLERRM);
END;
$$;

-- T2 sense permís
DO $$
BEGIN
  PERFORM pg_temp.set_member_ctx();
  SET LOCAL ROLE authenticated;
  PERFORM api.create_work_shift(
    'b0420000-0000-0000-0000-000000000001'::uuid,
    'X', '10:00'::time, '12:00'::time
  );
  SET LOCAL ROLE postgres;
  INSERT INTO ex042_results VALUES ('T2 create sense permís', 'FAIL', 'expected exception');
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  IF SQLERRM ILIKE '%insufficient_privilege%' THEN
    INSERT INTO ex042_results VALUES ('T2 create sense permís', 'PASS', SQLERRM);
  ELSE
    INSERT INTO ex042_results VALUES ('T2 create sense permís', 'ERROR', SQLERRM);
  END IF;
END;
$$;

-- T3 update
DO $$
DECLARE
  v_id uuid;
  v_row jsonb;
BEGIN
  SELECT id INTO v_id FROM data.work_shifts
  WHERE site_id = 'b0420000-0000-0000-0000-000000000001' AND name = 'Matí EX042'
  LIMIT 1;

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_row := api.update_work_shift(v_id, 'Matí Renamed', '08:00'::time, '12:00'::time, '#22c55e');
  SET LOCAL ROLE postgres;

  IF v_row->>'name' = 'Matí Renamed' AND (v_row->>'start_time') LIKE '08:00%' THEN
    INSERT INTO ex042_results VALUES ('T3 update_work_shift', 'PASS', 'ok');
  ELSE
    INSERT INTO ex042_results VALUES ('T3 update_work_shift', 'FAIL', v_row::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex042_results VALUES ('T3 update_work_shift', 'ERROR', SQLERRM);
END;
$$;

-- T4 multi-slot no solapat
DO $$
DECLARE
  v_m jsonb;
  v_t jsonb;
  v_a1 jsonb;
  v_a2 jsonb;
  v_cnt int;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_m := api.create_work_shift(
    'b0420000-0000-0000-0000-000000000001'::uuid,
    'Bloc A', '10:00'::time, '14:00'::time, '#6366f1'
  );
  v_t := api.create_work_shift(
    'b0420000-0000-0000-0000-000000000001'::uuid,
    'Bloc B', '15:00'::time, '19:00'::time, '#f59e0b'
  );
  v_a1 := api.assign_shift_slot(
    'd0420000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date,
    (v_m->>'id')::uuid
  );
  v_a2 := api.assign_shift_slot(
    'd0420000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date,
    (v_t->>'id')::uuid
  );
  SET LOCAL ROLE postgres;

  SELECT count(*)::int INTO v_cnt
  FROM data.shift_slots
  WHERE employee_id = 'd0420000-0000-0000-0000-000000000001'
    AND slot_date = '2026-07-13'
    AND status = 'draft';

  IF v_cnt = 2
     AND COALESCE(jsonb_array_length(v_a1->'anomalies'), 0) = 0
     AND COALESCE(jsonb_array_length(v_a2->'anomalies'), 0) = 0
  THEN
    INSERT INTO ex042_results VALUES ('T4 multi-slot no overlap', 'PASS',
      format('cnt=%s', v_cnt));
  ELSE
    INSERT INTO ex042_results VALUES ('T4 multi-slot no overlap', 'FAIL',
      format('cnt=%s a1=%s a2=%s', v_cnt, v_a1, v_a2));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex042_results VALUES ('T4 multi-slot no overlap', 'ERROR', SQLERRM);
END;
$$;

-- T5 overlap anomaly
DO $$
DECLARE
  v_x jsonb;
  v_y jsonb;
  v_a jsonb;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_x := api.create_work_shift(
    'b0420000-0000-0000-0000-000000000001'::uuid,
    'Overlap X', '09:00'::time, '17:00'::time
  );
  v_y := api.create_work_shift(
    'b0420000-0000-0000-0000-000000000001'::uuid,
    'Overlap Y', '13:00'::time, '21:00'::time
  );
  PERFORM api.assign_shift_slot(
    'd0420000-0000-0000-0000-000000000001'::uuid,
    '2026-07-14'::date,
    (v_x->>'id')::uuid
  );
  v_a := api.assign_shift_slot(
    'd0420000-0000-0000-0000-000000000001'::uuid,
    '2026-07-14'::date,
    (v_y->>'id')::uuid
  );
  SET LOCAL ROLE postgres;

  IF v_a->'anomalies' ? 'SHIFT_OVERLAP' AND v_a->>'slot_id' IS NOT NULL THEN
    INSERT INTO ex042_results VALUES ('T5 SHIFT_OVERLAP', 'PASS', (v_a->'anomalies')::text);
  ELSE
    INSERT INTO ex042_results VALUES ('T5 SHIFT_OVERLAP', 'FAIL', v_a::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex042_results VALUES ('T5 SHIFT_OVERLAP', 'ERROR', SQLERRM);
END;
$$;

-- T6 deactivate
DO $$
DECLARE
  v_id uuid;
  v_res jsonb;
  v_active boolean;
BEGIN
  SELECT id INTO v_id FROM data.work_shifts
  WHERE site_id = 'b0420000-0000-0000-0000-000000000001' AND name = 'Matí Renamed'
  LIMIT 1;

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_res := api.deactivate_work_shift(v_id);
  SET LOCAL ROLE postgres;

  SELECT is_active INTO v_active FROM data.work_shifts WHERE id = v_id;

  IF (v_res->>'is_active')::boolean = false AND v_active = false THEN
    INSERT INTO ex042_results VALUES ('T6 deactivate', 'PASS', 'ok');
  ELSE
    INSERT INTO ex042_results VALUES ('T6 deactivate', 'FAIL',
      format('res=%s active=%s', v_res, v_active));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex042_results VALUES ('T6 deactivate', 'ERROR', SQLERRM);
END;
$$;

SELECT * FROM ex042_results ORDER BY test_name;

SELECT
  count(*) FILTER (WHERE status = 'PASS') AS passed,
  count(*) FILTER (WHERE status = 'FAIL') AS failed,
  count(*) FILTER (WHERE status = 'ERROR') AS errors,
  count(*) AS total
FROM ex042_results;

ROLLBACK;
