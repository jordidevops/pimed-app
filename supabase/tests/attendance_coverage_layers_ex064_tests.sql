-- =============================================================================
-- attendance_coverage_layers_ex064_tests.sql
-- EX-06.4 — Capes planned / confirmed / present / qualified
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active, settings)
VALUES (
  'a0640000-0000-0000-0000-000000000001', 'EX064 Tenant', 'ex064-tenant', true,
  '{"require_shift_confirmation": true}'::jsonb
)
ON CONFLICT (id) DO UPDATE SET settings = EXCLUDED.settings;

INSERT INTO data.sites (id, tenant_id, name, is_active, settings)
VALUES (
  'b0640000-0000-0000-0000-000000000001',
  'a0640000-0000-0000-0000-000000000001',
  'EX064 Site', true,
  '{"site_timezone":"Europe/Madrid"}'::jsonb
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0640000-0000-0000-0000-000000000001', 'emp@ex064.test', 'authenticated', 'authenticated'),
  ('c0640000-0000-0000-0000-000000000002', 'mgr@ex064.test', 'authenticated', 'authenticated'),
  ('c0640000-0000-0000-0000-000000000003', 'emp2@ex064.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0640000-0000-0000-0000-000000000001', 'emp@ex064.test', 'Emp EX064'),
  ('c0640000-0000-0000-0000-000000000002', 'mgr@ex064.test', 'Mgr EX064'),
  ('c0640000-0000-0000-0000-000000000003', 'emp2@ex064.test', 'Emp2 EX064')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0640000-0000-0000-0000-000000000001', 'c0640000-0000-0000-0000-000000000001', 'member', true),
  (gen_random_uuid(), 'a0640000-0000-0000-0000-000000000001', 'c0640000-0000-0000-0000-000000000002', 'manager', true),
  (gen_random_uuid(), 'a0640000-0000-0000-0000-000000000001', 'c0640000-0000-0000-0000-000000000003', 'member', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status, weekly_hours)
VALUES
  (
    'd0640000-0000-0000-0000-000000000001',
    'a0640000-0000-0000-0000-000000000001',
    'b0640000-0000-0000-0000-000000000001',
    'c0640000-0000-0000-0000-000000000001',
    'Emp EX064', 'active', 40
  ),
  (
    'd0640000-0000-0000-0000-000000000002',
    'a0640000-0000-0000-0000-000000000001',
    'b0640000-0000-0000-0000-000000000001',
    'c0640000-0000-0000-0000-000000000003',
    'Emp2 EX064', 'active', 40
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.work_roles (id, tenant_id, key, name, sort_order, is_active)
VALUES ('e0640000-0000-0000-0000-000000000001', 'a0640000-0000-0000-0000-000000000001', 'cambrer', 'Cambrer', 10, true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employee_role_assignments (
  id, tenant_id, employee_id, role_id, level, is_active, is_primary
) VALUES (
  'a0640000-0000-0000-0000-000000000021',
  'a0640000-0000-0000-0000-000000000001',
  'd0640000-0000-0000-0000-000000000001',
  'e0640000-0000-0000-0000-000000000001',
  1, true, true
) ON CONFLICT DO NOTHING;

-- Emp2 té rol però falta qualificació required
INSERT INTO data.employee_role_assignments (
  id, tenant_id, employee_id, role_id, level, is_active, is_primary
) VALUES (
  'a0640000-0000-0000-0000-000000000022',
  'a0640000-0000-0000-0000-000000000001',
  'd0640000-0000-0000-0000-000000000002',
  'e0640000-0000-0000-0000-000000000001',
  1, true, true
) ON CONFLICT DO NOTHING;

INSERT INTO data.role_qualification_requirements (
  id, tenant_id, role_id, qualification_key, required, is_active
) VALUES (
  'a0640000-0000-0000-0000-000000000031',
  'a0640000-0000-0000-0000-000000000001',
  'e0640000-0000-0000-0000-000000000001',
  'manipulador', true, true
) ON CONFLICT DO NOTHING;

INSERT INTO data.employee_qualifications (
  id, tenant_id, employee_id, key, label, is_active, issued_at
) VALUES (
  'a0640000-0000-0000-0000-000000000032',
  'a0640000-0000-0000-0000-000000000001',
  'd0640000-0000-0000-0000-000000000001',
  'manipulador', 'Manipulador aliments', true, CURRENT_DATE - 30
) ON CONFLICT DO NOTHING;

INSERT INTO data.work_shifts (id, tenant_id, site_id, name, color, start_time, end_time, is_active, default_role_id)
VALUES (
  'f0640000-0000-0000-0000-000000000001',
  'a0640000-0000-0000-0000-000000000001',
  'b0640000-0000-0000-0000-000000000001',
  'Torn EX064', '#22c55e', '09:00', '17:00', true,
  'e0640000-0000-0000-0000-000000000001'
)
ON CONFLICT (id) DO NOTHING;

CREATE TEMP TABLE ex064_results (
  test_name text, status text, details text
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.set_mgr_ctx() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0640000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0640000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0640000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0640000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","labor_calendar.view","attendance.view_all"],"sites":{}}}}}',
    true);
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.set_emp_ctx() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0640000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0640000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"a0640000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"a0640000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{}}}}}',
    true);
END;
$$;

DO $$
DECLARE
  v_monday date := CURRENT_DATE - ((EXTRACT(DOW FROM CURRENT_DATE)::int + 6) % 7);
BEGIN
  INSERT INTO data.coverage_demands (
    id, tenant_id, site_id, role_id, kind, day_of_week, demand_date,
    start_time, end_time, required_min, required_target, priority, source, name,
    effective_from, is_active
  ) VALUES (
    'a0640000-0000-0000-0000-000000000011',
    'a0640000-0000-0000-0000-000000000001',
    'b0640000-0000-0000-0000-000000000001',
    'e0640000-0000-0000-0000-000000000001',
    'recurring', 1, NULL,
    '10:00', '14:00', 0, 2, 50, 'manual', 'Punta EX064',
    CURRENT_DATE - 60, true
  ) ON CONFLICT (id) DO NOTHING;

  INSERT INTO data.shift_slots (
    id, tenant_id, site_id, employee_id, shift_id, slot_date, status,
    start_time, end_time, role_id, role_name_snapshot, published_at
  ) VALUES (
    'a0640000-0000-0000-0000-000000000012',
    'a0640000-0000-0000-0000-000000000001',
    'b0640000-0000-0000-0000-000000000001',
    'd0640000-0000-0000-0000-000000000001',
    'f0640000-0000-0000-0000-000000000001',
    v_monday, 'published',
    '09:00', '17:00',
    'e0640000-0000-0000-0000-000000000001', 'Cambrer', now()
  ) ON CONFLICT (id) DO NOTHING;

  -- Emp2 published however not confirmed
  INSERT INTO data.shift_slots (
    id, tenant_id, site_id, employee_id, shift_id, slot_date, status,
    start_time, end_time, role_id, role_name_snapshot, published_at
  ) VALUES (
    'a0640000-0000-0000-0000-000000000013',
    'a0640000-0000-0000-0000-000000000001',
    'b0640000-0000-0000-0000-000000000001',
    'd0640000-0000-0000-0000-000000000002',
    'f0640000-0000-0000-0000-000000000001',
    v_monday, 'published',
    '09:00', '17:00',
    'e0640000-0000-0000-0000-000000000001', 'Cambrer', now()
  ) ON CONFLICT (id) DO NOTHING;

  -- Presència: emp1 10:00–12:00, emp2 10:00–13:00 (mateix dilluns)
  INSERT INTO data.time_punches (
    id, tenant_id, site_id, employee_id, client_op_id, punch_type,
    occurred_at, received_at, source
  ) VALUES
  (
    'a0640000-0000-0000-0000-000000000041',
    'a0640000-0000-0000-0000-000000000001',
    'b0640000-0000-0000-0000-000000000001',
    'd0640000-0000-0000-0000-000000000001',
    'a0640000-0000-0000-0000-000000000041',
    'in',
    (v_monday + time '10:00') AT TIME ZONE 'Europe/Madrid',
    now(), 'manual_entry'
  ),
  (
    'a0640000-0000-0000-0000-000000000042',
    'a0640000-0000-0000-0000-000000000001',
    'b0640000-0000-0000-0000-000000000001',
    'd0640000-0000-0000-0000-000000000001',
    'a0640000-0000-0000-0000-000000000042',
    'out',
    (v_monday + time '12:00') AT TIME ZONE 'Europe/Madrid',
    now(), 'manual_entry'
  ),
  (
    'a0640000-0000-0000-0000-000000000043',
    'a0640000-0000-0000-0000-000000000001',
    'b0640000-0000-0000-0000-000000000001',
    'd0640000-0000-0000-0000-000000000002',
    'a0640000-0000-0000-0000-000000000043',
    'in',
    (v_monday + time '10:00') AT TIME ZONE 'Europe/Madrid',
    now(), 'manual_entry'
  ),
  (
    'a0640000-0000-0000-0000-000000000044',
    'a0640000-0000-0000-0000-000000000001',
    'b0640000-0000-0000-0000-000000000001',
    'd0640000-0000-0000-0000-000000000002',
    'a0640000-0000-0000-0000-000000000044',
    'out',
    (v_monday + time '13:00') AT TIME ZONE 'Europe/Madrid',
    now(), 'manual_entry'
  )
  ON CONFLICT DO NOTHING;
END;
$$;

-- T1: planned=2, confirmed=0 (require confirm, cap ack)
DO $$
DECLARE
  v_monday date := CURRENT_DATE - ((EXTRACT(DOW FROM CURRENT_DATE)::int + 6) % 7);
  v_buckets jsonb;
  v_row jsonb;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_buckets := api.get_coverage_buckets(
    'b0640000-0000-0000-0000-000000000001'::uuid,
    v_monday, 30, 'e0640000-0000-0000-0000-000000000001'::uuid, NULL
  );
  SET LOCAL ROLE postgres;

  SELECT b INTO v_row
  FROM jsonb_array_elements(v_buckets) b
  WHERE b->>'bucket_start' = '10:00'
  LIMIT 1;

  IF v_row IS NOT NULL
     AND (v_row->>'required')::int = 2
     AND (v_row->>'planned')::int = 2
     AND (v_row->>'confirmed')::int = 0
     AND (v_row->>'assigned')::int = 2
  THEN
    INSERT INTO ex064_results VALUES ('T1 planned_vs_confirmed', 'PASS', v_row::text);
  ELSE
    INSERT INTO ex064_results VALUES ('T1 planned_vs_confirmed', 'FAIL', COALESCE(v_row::text, v_buckets::text));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex064_results VALUES ('T1 planned_vs_confirmed', 'ERROR', SQLERRM);
END;
$$;

-- T2: confirm slot emp1 → confirmed=1
DO $$
DECLARE
  v_monday date := CURRENT_DATE - ((EXTRACT(DOW FROM CURRENT_DATE)::int + 6) % 7);
  v_buckets jsonb;
  v_row jsonb;
  v_conf jsonb;
BEGIN
  PERFORM pg_temp.set_emp_ctx();
  SET LOCAL ROLE authenticated;
  v_conf := api.confirm_shift_slot('a0640000-0000-0000-0000-000000000012'::uuid);
  SET LOCAL ROLE postgres;

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_buckets := api.get_coverage_buckets(
    'b0640000-0000-0000-0000-000000000001'::uuid,
    v_monday, 30, 'e0640000-0000-0000-0000-000000000001'::uuid, NULL
  );
  SET LOCAL ROLE postgres;

  SELECT b INTO v_row
  FROM jsonb_array_elements(v_buckets) b
  WHERE b->>'bucket_start' = '10:00'
  LIMIT 1;

  IF v_conf ? 'employee_confirmed_at'
     AND (v_row->>'confirmed')::int = 1
     AND (v_row->>'planned')::int = 2
  THEN
    INSERT INTO ex064_results VALUES ('T2 confirm_increments', 'PASS', v_row::text);
  ELSE
    INSERT INTO ex064_results VALUES ('T2 confirm_increments', 'FAIL', COALESCE(v_row::text, v_conf::text));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex064_results VALUES ('T2 confirm_increments', 'ERROR', SQLERRM);
END;
$$;

-- T3: present=2 a 10:00; a 12:30 només emp2 (present=1)
DO $$
DECLARE
  v_monday date := CURRENT_DATE - ((EXTRACT(DOW FROM CURRENT_DATE)::int + 6) % 7);
  v_buckets jsonb;
  v_row10 jsonb;
  v_row1230 jsonb;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_buckets := api.get_coverage_buckets(
    'b0640000-0000-0000-0000-000000000001'::uuid,
    v_monday, 30, 'e0640000-0000-0000-0000-000000000001'::uuid, NULL
  );
  SET LOCAL ROLE postgres;

  SELECT b INTO v_row10
  FROM jsonb_array_elements(v_buckets) b
  WHERE b->>'bucket_start' = '10:00'
  LIMIT 1;

  SELECT b INTO v_row1230
  FROM jsonb_array_elements(v_buckets) b
  WHERE b->>'bucket_start' = '12:30'
  LIMIT 1;

  IF (v_row10->>'present')::int = 2
     AND (v_row1230->>'present')::int = 1
  THEN
    INSERT INTO ex064_results VALUES ('T3 present_layers', 'PASS',
      format('10=%s 12:30=%s', v_row10->>'present', v_row1230->>'present'));
  ELSE
    INSERT INTO ex064_results VALUES ('T3 present_layers', 'FAIL',
      format('10=%s 12:30=%s', COALESCE(v_row10::text,'?'), COALESCE(v_row1230::text,'?')));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex064_results VALUES ('T3 present_layers', 'ERROR', SQLERRM);
END;
$$;

-- T4: qualified — només emp1 té manipulador; a 10:00 qualified=1 (role filter)
DO $$
DECLARE
  v_monday date := CURRENT_DATE - ((EXTRACT(DOW FROM CURRENT_DATE)::int + 6) % 7);
  v_buckets jsonb;
  v_row jsonb;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_buckets := api.get_coverage_buckets(
    'b0640000-0000-0000-0000-000000000001'::uuid,
    v_monday, 30, 'e0640000-0000-0000-0000-000000000001'::uuid, NULL
  );
  SET LOCAL ROLE postgres;

  SELECT b INTO v_row
  FROM jsonb_array_elements(v_buckets) b
  WHERE b->>'bucket_start' = '10:00'
  LIMIT 1;

  IF (v_row->>'present')::int = 2
     AND (v_row->>'qualified')::int = 1
  THEN
    INSERT INTO ex064_results VALUES ('T4 qualified_subset', 'PASS', v_row::text);
  ELSE
    INSERT INTO ex064_results VALUES ('T4 qualified_subset', 'FAIL', COALESCE(v_row::text, 'missing'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex064_results VALUES ('T4 qualified_subset', 'ERROR', SQLERRM);
END;
$$;

-- T5: sense exigir confirmació → confirmed = planned
DO $$
DECLARE
  v_monday date := CURRENT_DATE - ((EXTRACT(DOW FROM CURRENT_DATE)::int + 6) % 7);
  v_buckets jsonb;
  v_row jsonb;
BEGIN
  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb) || '{"require_shift_confirmation": false}'::jsonb
  WHERE id = 'a0640000-0000-0000-0000-000000000001';

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_buckets := api.get_coverage_buckets(
    'b0640000-0000-0000-0000-000000000001'::uuid,
    v_monday, 30, 'e0640000-0000-0000-0000-000000000001'::uuid, NULL
  );
  SET LOCAL ROLE postgres;

  SELECT b INTO v_row
  FROM jsonb_array_elements(v_buckets) b
  WHERE b->>'bucket_start' = '10:00'
  LIMIT 1;

  IF (v_row->>'planned')::int = 2
     AND (v_row->>'confirmed')::int = 2
     AND (v_row->>'require_shift_confirmation')::boolean = false
  THEN
    INSERT INTO ex064_results VALUES ('T5 confirm_optional', 'PASS', v_row::text);
  ELSE
    INSERT INTO ex064_results VALUES ('T5 confirm_optional', 'FAIL', COALESCE(v_row::text, 'missing'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex064_results VALUES ('T5 confirm_optional', 'ERROR', SQLERRM);
END;
$$;

SELECT test_name, status, details FROM ex064_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM ex064_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EX-06.4 tests failed: % row(s)', v_fail;
  END IF;
END;
$$;

ROLLBACK;
