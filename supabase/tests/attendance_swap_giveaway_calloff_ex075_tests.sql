-- =============================================================================
-- attendance_swap_giveaway_calloff_ex075_tests.sql
-- EX-07.5 — kind + eligibility + call_off → opening
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0750000-0000-0000-0000-000000000001', 'EX075 Tenant', 'ex075-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b0750000-0000-0000-0000-000000000001', 'a0750000-0000-0000-0000-000000000001', 'EX075 Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0750000-0000-0000-0000-000000000001', 'emp1@ex075.test', 'authenticated', 'authenticated'),
  ('c0750000-0000-0000-0000-000000000002', 'emp2@ex075.test', 'authenticated', 'authenticated'),
  ('c0750000-0000-0000-0000-000000000003', 'mgr@ex075.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0750000-0000-0000-0000-000000000001', 'emp1@ex075.test', 'Emp1 EX075'),
  ('c0750000-0000-0000-0000-000000000002', 'emp2@ex075.test', 'Emp2 EX075'),
  ('c0750000-0000-0000-0000-000000000003', 'mgr@ex075.test', 'Mgr EX075')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0750000-0000-0000-0000-000000000001', 'c0750000-0000-0000-0000-000000000001', 'member', true),
  (gen_random_uuid(), 'a0750000-0000-0000-0000-000000000001', 'c0750000-0000-0000-0000-000000000002', 'member', true),
  (gen_random_uuid(), 'a0750000-0000-0000-0000-000000000001', 'c0750000-0000-0000-0000-000000000003', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status, weekly_hours)
VALUES
  ('d0750000-0000-0000-0000-000000000001', 'a0750000-0000-0000-0000-000000000001',
   'b0750000-0000-0000-0000-000000000001', 'c0750000-0000-0000-0000-000000000001', 'Emp1 EX075', 'active', 40),
  ('d0750000-0000-0000-0000-000000000002', 'a0750000-0000-0000-0000-000000000001',
   'b0750000-0000-0000-0000-000000000001', 'c0750000-0000-0000-0000-000000000002', 'Emp2 EX075', 'active', 40)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.work_shifts (id, tenant_id, site_id, name, color, start_time, end_time, is_active)
VALUES
  ('e0750000-0000-0000-0000-000000000001', 'a0750000-0000-0000-0000-000000000001',
   'b0750000-0000-0000-0000-000000000001', 'Matí EX075', '#22c55e', '09:00', '13:00', true),
  ('e0750000-0000-0000-0000-000000000002', 'a0750000-0000-0000-0000-000000000001',
   'b0750000-0000-0000-0000-000000000001', 'Tarda EX075', '#3b82f6', '15:00', '19:00', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.shift_slots (
  id, tenant_id, site_id, employee_id, shift_id, slot_date, status,
  start_time, end_time, published_at, created_by
) VALUES
  ('f0750000-0000-0000-0000-000000000001', 'a0750000-0000-0000-0000-000000000001',
   'b0750000-0000-0000-0000-000000000001', 'd0750000-0000-0000-0000-000000000001',
   'e0750000-0000-0000-0000-000000000001', date '2026-09-20', 'published',
   '09:00', '13:00', now(), 'c0750000-0000-0000-0000-000000000003'),
  ('f0750000-0000-0000-0000-000000000002', 'a0750000-0000-0000-0000-000000000001',
   'b0750000-0000-0000-0000-000000000001', 'd0750000-0000-0000-0000-000000000002',
   'e0750000-0000-0000-0000-000000000002', date '2026-09-20', 'published',
   '15:00', '19:00', now(), 'c0750000-0000-0000-0000-000000000003'),
  ('f0750000-0000-0000-0000-000000000003', 'a0750000-0000-0000-0000-000000000001',
   'b0750000-0000-0000-0000-000000000001', 'd0750000-0000-0000-0000-000000000001',
   'e0750000-0000-0000-0000-000000000002', date '2026-09-21', 'published',
   '15:00', '19:00', now(), 'c0750000-0000-0000-0000-000000000003')
ON CONFLICT (id) DO NOTHING;

CREATE TEMP TABLE ex075_results (test_name text, status text, details text) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.set_mgr_ctx() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0750000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0750000-0000-0000-0000-000000000003","app_metadata":{"user_tenants":{"a0750000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0750000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","labor_calendar.view","attendance.approve","attendance.view_all"],"sites":{}}}}}',
    true);
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.set_emp1_ctx() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0750000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0750000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"a0750000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"a0750000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{}}}}}',
    true);
END;
$$;

-- T1 give_away request + approve reassigns
DO $$
DECLARE
  v_req jsonb;
  v_req_id uuid;
  v_res jsonb;
  v_emp uuid;
BEGIN
  PERFORM pg_temp.set_emp1_ctx();
  SET LOCAL ROLE authenticated;
  v_req := api.request_shift_swap(
    'f0750000-0000-0000-0000-000000000001'::uuid,
    'd0750000-0000-0000-0000-000000000002'::uuid,
    NULL::uuid,
    'cedeixo matí'::text,
    'give_away'::text
  );
  v_req_id := (v_req->>'request_id')::uuid;
  SET LOCAL ROLE postgres;

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_res := api.approve_shift_swap(v_req_id, 'approved', 'ok', NULL, true, true);
  SET LOCAL ROLE postgres;

  SELECT employee_id INTO v_emp FROM data.shift_slots WHERE id = 'f0750000-0000-0000-0000-000000000001';

  IF v_req->>'kind' = 'give_away'
     AND v_res->>'status' = 'approved'
     AND v_emp = 'd0750000-0000-0000-0000-000000000002'
  THEN
    INSERT INTO ex075_results VALUES ('T1 give_away_approve', 'PASS', v_req_id::text);
  ELSE
    INSERT INTO ex075_results VALUES ('T1 give_away_approve', 'FAIL',
      jsonb_build_object('req', v_req, 'res', v_res, 'emp', v_emp)::text);
  END IF;
END;
$$;

-- T2 swap two slots
DO $$
DECLARE
  v_req jsonb;
  v_req_id uuid;
  v_res jsonb;
  v_a uuid;
  v_b uuid;
BEGIN
  -- Reset ownership for swap test: emp2 has morning (from T1), emp2 has afternoon
  -- Use emp1's afternoon slot (0003) swap with emp2 afternoon (0002)
  UPDATE data.shift_slots SET employee_id = 'd0750000-0000-0000-0000-000000000001'
  WHERE id = 'f0750000-0000-0000-0000-000000000003';
  UPDATE data.shift_slots SET employee_id = 'd0750000-0000-0000-0000-000000000002'
  WHERE id = 'f0750000-0000-0000-0000-000000000002';

  PERFORM pg_temp.set_emp1_ctx();
  SET LOCAL ROLE authenticated;
  v_req := api.request_shift_swap(
    'f0750000-0000-0000-0000-000000000003'::uuid,
    'd0750000-0000-0000-0000-000000000002'::uuid,
    'f0750000-0000-0000-0000-000000000002'::uuid,
    'intercanvi'::text,
    'swap'::text
  );
  v_req_id := (v_req->>'request_id')::uuid;
  SET LOCAL ROLE postgres;

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_res := api.approve_shift_swap(v_req_id, 'approved', NULL, NULL, true, true);
  SET LOCAL ROLE postgres;

  SELECT employee_id INTO v_a FROM data.shift_slots WHERE id = 'f0750000-0000-0000-0000-000000000003';
  SELECT employee_id INTO v_b FROM data.shift_slots WHERE id = 'f0750000-0000-0000-0000-000000000002';

  IF v_req->>'kind' = 'swap'
     AND v_a = 'd0750000-0000-0000-0000-000000000002'
     AND v_b = 'd0750000-0000-0000-0000-000000000001'
  THEN
    INSERT INTO ex075_results VALUES ('T2 swap_exchange', 'PASS', v_req_id::text);
  ELSE
    INSERT INTO ex075_results VALUES ('T2 swap_exchange', 'FAIL',
      format('a=%s b=%s res=%s', v_a, v_b, v_res));
  END IF;
END;
$$;

-- T3 call_off cancels + creates opening
DO $$
DECLARE
  v_slot_id uuid := 'f0750000-0000-0000-0000-000000000020';
  v_req jsonb;
  v_req_id uuid;
  v_res jsonb;
  v_status text;
  v_opening uuid;
BEGIN
  INSERT INTO data.shift_slots (
    id, tenant_id, site_id, employee_id, shift_id, slot_date, status,
    start_time, end_time, published_at, created_by
  ) VALUES (
    v_slot_id, 'a0750000-0000-0000-0000-000000000001',
    'b0750000-0000-0000-0000-000000000001', 'd0750000-0000-0000-0000-000000000001',
    'e0750000-0000-0000-0000-000000000001', date '2026-09-23', 'published',
    '09:00', '13:00', now(), 'c0750000-0000-0000-0000-000000000003'
  ) ON CONFLICT (id) DO NOTHING;

  PERFORM pg_temp.set_emp1_ctx();
  SET LOCAL ROLE authenticated;
  v_req := api.request_shift_swap(v_slot_id, NULL, NULL, 'no puc'::text, 'call_off'::text);
  v_req_id := (v_req->>'request_id')::uuid;
  SET LOCAL ROLE postgres;

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_res := api.approve_shift_swap(v_req_id, 'approved', 'ok', NULL, true, true);
  SET LOCAL ROLE postgres;

  SELECT status INTO v_status FROM data.shift_slots WHERE id = v_slot_id;
  v_opening := (v_res->>'opening_id')::uuid;

  IF v_req->>'kind' = 'call_off'
     AND v_status = 'cancelled'
     AND v_opening IS NOT NULL
     AND EXISTS (SELECT 1 FROM data.shift_openings o WHERE o.id = v_opening AND o.status = 'open')
  THEN
    INSERT INTO ex075_results VALUES ('T3 call_off_opening', 'PASS', v_opening::text);
  ELSE
    INSERT INTO ex075_results VALUES ('T3 call_off_opening', 'FAIL',
      jsonb_build_object('res', v_res, 'status', v_status)::text);
  END IF;
END;
$$;

-- T4 eligibility blocks overlap on give_away
DO $$
DECLARE
  v_slot_id uuid;
  v_req_id uuid;
  v_elig jsonb;
BEGIN
  -- Create overlapping published slot for emp2 on 2026-09-22 morning, emp1 offers same window
  INSERT INTO data.shift_slots (
    id, tenant_id, site_id, employee_id, shift_id, slot_date, status,
    start_time, end_time, published_at, created_by
  ) VALUES (
    'f0750000-0000-0000-0000-000000000010', 'a0750000-0000-0000-0000-000000000001',
    'b0750000-0000-0000-0000-000000000001', 'd0750000-0000-0000-0000-000000000002',
    'e0750000-0000-0000-0000-000000000001', date '2026-09-22', 'published',
    '09:00', '13:00', now(), 'c0750000-0000-0000-0000-000000000003'
  ) ON CONFLICT (id) DO NOTHING;

  INSERT INTO data.shift_slots (
    id, tenant_id, site_id, employee_id, shift_id, slot_date, status,
    start_time, end_time, published_at, created_by
  ) VALUES (
    'f0750000-0000-0000-0000-000000000011', 'a0750000-0000-0000-0000-000000000001',
    'b0750000-0000-0000-0000-000000000001', 'd0750000-0000-0000-0000-000000000001',
    'e0750000-0000-0000-0000-000000000001', date '2026-09-22', 'published',
    '10:00', '14:00', now(), 'c0750000-0000-0000-0000-000000000003'
  ) ON CONFLICT (id) DO NOTHING;

  v_slot_id := 'f0750000-0000-0000-0000-000000000011';

  PERFORM pg_temp.set_emp1_ctx();
  SET LOCAL ROLE authenticated;
  v_req_id := (api.request_shift_swap(
    v_slot_id,
    'd0750000-0000-0000-0000-000000000002'::uuid,
    NULL::uuid,
    NULL::text,
    'give_away'::text
  )->>'request_id')::uuid;
  SET LOCAL ROLE postgres;

  v_elig := data.evaluate_swap_request_eligibility(v_req_id);

  IF (v_elig->>'ok')::boolean = false AND v_elig::text ILIKE '%SHIFT_OVERLAP%' THEN
    INSERT INTO ex075_results VALUES ('T4 overlap_eligibility', 'PASS', v_elig::text);
  ELSE
    INSERT INTO ex075_results VALUES ('T4 overlap_eligibility', 'FAIL', v_elig::text);
  END IF;
END;
$$;

-- T5 portal list / request call_off
DO $$
DECLARE
  v_list jsonb;
  v_req jsonb;
  v_slot_id uuid := 'f0750000-0000-0000-0000-000000000021';
BEGIN
  INSERT INTO data.shift_slots (
    id, tenant_id, site_id, employee_id, shift_id, slot_date, status,
    start_time, end_time, published_at, created_by
  ) VALUES (
    v_slot_id, 'a0750000-0000-0000-0000-000000000001',
    'b0750000-0000-0000-0000-000000000001', 'd0750000-0000-0000-0000-000000000001',
    'e0750000-0000-0000-0000-000000000002', date '2026-09-24', 'published',
    '15:00', '19:00', now(), 'c0750000-0000-0000-0000-000000000003'
  ) ON CONFLICT (id) DO NOTHING;

  v_req := api.employee_portal_request_shift_swap(
    'd0750000-0000-0000-0000-000000000001'::uuid,
    'a0750000-0000-0000-0000-000000000001'::uuid,
    v_slot_id,
    'call_off'::text,
    'portal call-off'::text,
    NULL::uuid
  );

  v_list := api.employee_portal_list_shift_swaps(
    'd0750000-0000-0000-0000-000000000001'::uuid,
    'a0750000-0000-0000-0000-000000000001'::uuid
  );

  IF v_req->>'kind' = 'call_off'
     AND v_req->>'status' = 'pending'
     AND jsonb_array_length(COALESCE(v_list->'requests', '[]'::jsonb)) >= 1
  THEN
    INSERT INTO ex075_results VALUES ('T5 portal_call_off_list', 'PASS', v_req::text);
  ELSE
    INSERT INTO ex075_results VALUES ('T5 portal_call_off_list', 'FAIL',
      jsonb_build_object('req', v_req, 'list', v_list)::text);
  END IF;
END;
$$;

SELECT test_name, status, details FROM ex075_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM ex075_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EX-07.5 tests failed: %', v_fail;
  END IF;
END;
$$;

ROLLBACK;
