-- =============================================================================
-- attendance_shift_openings_ex072_tests.sql
-- EX-07.2 — Openings + claims (sense crear shift_slot)
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0720000-0000-0000-0000-000000000001', 'EX072 Tenant', 'ex072-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b0720000-0000-0000-0000-000000000001', 'a0720000-0000-0000-0000-000000000001', 'EX072 Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0720000-0000-0000-0000-000000000001', 'emp@ex072.test', 'authenticated', 'authenticated'),
  ('c0720000-0000-0000-0000-000000000002', 'mgr@ex072.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0720000-0000-0000-0000-000000000001', 'emp@ex072.test', 'Emp EX072'),
  ('c0720000-0000-0000-0000-000000000002', 'mgr@ex072.test', 'Mgr EX072')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0720000-0000-0000-0000-000000000001', 'c0720000-0000-0000-0000-000000000001', 'member', true),
  (gen_random_uuid(), 'a0720000-0000-0000-0000-000000000001', 'c0720000-0000-0000-0000-000000000002', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status, weekly_hours)
VALUES (
  'd0720000-0000-0000-0000-000000000001',
  'a0720000-0000-0000-0000-000000000001',
  'b0720000-0000-0000-0000-000000000001',
  'c0720000-0000-0000-0000-000000000001',
  'Emp EX072', 'active', 40
)
ON CONFLICT (id) DO NOTHING;

CREATE TEMP TABLE ex072_results (
  test_name text, status text, details text
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.set_mgr_ctx() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0720000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0720000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0720000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0720000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","labor_calendar.view","attendance.view_all"],"sites":{}}}}}',
    true);
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.set_emp_ctx() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0720000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0720000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"a0720000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"a0720000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{}}}}}',
    true);
END;
$$;

-- T1 create draft + publish
DO $$
DECLARE
  v_row jsonb;
  v_id uuid;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_row := api.upsert_shift_opening(
    NULL::uuid,
    'b0720000-0000-0000-0000-000000000001'::uuid,
    date '2026-07-20',
    '18:00'::time,
    '22:00'::time,
    2,
    'manager_approval'::text,
    NULL::uuid, NULL::uuid, NULL::uuid,
    'Punta sopar'::text,
    NULL::text, NULL::text,
    NULL::timestamptz, NULL::timestamptz,
    false, false
  );
  v_id := (v_row->>'id')::uuid;
  v_row := api.publish_shift_opening(v_id);
  SET LOCAL ROLE postgres;

  IF v_row->>'status' = 'open' AND (v_row->>'places_total')::int = 2 THEN
    INSERT INTO ex072_results VALUES ('T1 publish_opening', 'PASS', v_id::text);
  ELSE
    INSERT INTO ex072_results VALUES ('T1 publish_opening', 'FAIL', v_row::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex072_results VALUES ('T1 publish_opening', 'ERROR', SQLERRM);
END;
$$;

-- T2 employee claim
DO $$
DECLARE
  v_id uuid;
  v_claim jsonb;
BEGIN
  SELECT id INTO v_id FROM data.shift_openings
  WHERE site_id = 'b0720000-0000-0000-0000-000000000001' AND status = 'open'
  LIMIT 1;

  PERFORM pg_temp.set_emp_ctx();
  SET LOCAL ROLE authenticated;
  v_claim := api.claim_shift_opening(v_id, 'Puc fer-ho'::text);
  SET LOCAL ROLE postgres;

  IF v_claim->'claim'->>'status' = 'pending'
     AND (v_claim->>'places_remaining')::int = 2
  THEN
    INSERT INTO ex072_results VALUES ('T2 claim', 'PASS', v_claim::text);
  ELSE
    INSERT INTO ex072_results VALUES ('T2 claim', 'FAIL', v_claim::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex072_results VALUES ('T2 claim', 'ERROR', SQLERRM);
END;
$$;

-- T3 duplicate claim blocked
DO $$
DECLARE
  v_id uuid;
BEGIN
  SELECT id INTO v_id FROM data.shift_openings
  WHERE site_id = 'b0720000-0000-0000-0000-000000000001' AND status = 'open'
  LIMIT 1;

  PERFORM pg_temp.set_emp_ctx();
  SET LOCAL ROLE authenticated;
  PERFORM api.claim_shift_opening(v_id, NULL::text);
  SET LOCAL ROLE postgres;
  INSERT INTO ex072_results VALUES ('T3 dup_claim', 'FAIL', 'expected error');
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  IF SQLERRM ILIKE '%claim_already%' OR SQLERRM ILIKE '%unique%' THEN
    INSERT INTO ex072_results VALUES ('T3 dup_claim', 'PASS', SQLERRM);
  ELSE
    INSERT INTO ex072_results VALUES ('T3 dup_claim', 'ERROR', SQLERRM);
  END IF;
END;
$$;

-- T4 manager reject
DO $$
DECLARE
  v_claim_id uuid;
  v_row jsonb;
BEGIN
  SELECT c.id INTO v_claim_id
  FROM data.shift_opening_claims c
  JOIN data.shift_openings o ON o.id = c.opening_id
  WHERE o.site_id = 'b0720000-0000-0000-0000-000000000001'
    AND c.status = 'pending'
  LIMIT 1;

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_row := api.reject_shift_opening_claim(v_claim_id, 'Ja cobert'::text);
  SET LOCAL ROLE postgres;

  IF v_row->>'status' = 'rejected' THEN
    INSERT INTO ex072_results VALUES ('T4 reject', 'PASS', v_row::text);
  ELSE
    INSERT INTO ex072_results VALUES ('T4 reject', 'FAIL', v_row::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex072_results VALUES ('T4 reject', 'ERROR', SQLERRM);
END;
$$;

-- T5 cancel opening + no slot placeholder created
DO $$
DECLARE
  v_id uuid;
  v_row jsonb;
  v_slots int;
BEGIN
  SELECT id INTO v_id FROM data.shift_openings
  WHERE site_id = 'b0720000-0000-0000-0000-000000000001'
  LIMIT 1;

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_row := api.cancel_shift_opening(v_id);
  SET LOCAL ROLE postgres;

  SELECT count(*) INTO v_slots
  FROM data.shift_slots
  WHERE site_id = 'b0720000-0000-0000-0000-000000000001'
    AND slot_date = date '2026-07-20';

  IF v_row->>'status' = 'cancelled' AND v_slots = 0 THEN
    INSERT INTO ex072_results VALUES ('T5 cancel_no_slot', 'PASS', format('slots=%s', v_slots));
  ELSE
    INSERT INTO ex072_results VALUES ('T5 cancel_no_slot', 'FAIL', format('row=%s slots=%s', v_row::text, v_slots));
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex072_results VALUES ('T5 cancel_no_slot', 'ERROR', SQLERRM);
END;
$$;

SELECT test_name, status, details FROM ex072_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM ex072_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EX-07.2 tests failed: % row(s)', v_fail;
  END IF;
END;
$$;

ROLLBACK;
