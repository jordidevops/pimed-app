-- =============================================================================
-- attendance_accept_opening_claim_ex073_tests.sql
-- EX-07.3 — Eligibility + accept → shift_slot published
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0730000-0000-0000-0000-000000000001', 'EX073 Tenant', 'ex073-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b0730000-0000-0000-0000-000000000001', 'a0730000-0000-0000-0000-000000000001', 'EX073 Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0730000-0000-0000-0000-000000000001', 'emp@ex073.test', 'authenticated', 'authenticated'),
  ('c0730000-0000-0000-0000-000000000002', 'mgr@ex073.test', 'authenticated', 'authenticated'),
  ('c0730000-0000-0000-0000-000000000003', 'emp2@ex073.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0730000-0000-0000-0000-000000000001', 'emp@ex073.test', 'Emp EX073'),
  ('c0730000-0000-0000-0000-000000000002', 'mgr@ex073.test', 'Mgr EX073'),
  ('c0730000-0000-0000-0000-000000000003', 'emp2@ex073.test', 'Emp2 EX073')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0730000-0000-0000-0000-000000000001', 'c0730000-0000-0000-0000-000000000001', 'member', true),
  (gen_random_uuid(), 'a0730000-0000-0000-0000-000000000001', 'c0730000-0000-0000-0000-000000000002', 'manager', true),
  (gen_random_uuid(), 'a0730000-0000-0000-0000-000000000001', 'c0730000-0000-0000-0000-000000000003', 'member', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status, weekly_hours)
VALUES
  (
    'd0730000-0000-0000-0000-000000000001',
    'a0730000-0000-0000-0000-000000000001',
    'b0730000-0000-0000-0000-000000000001',
    'c0730000-0000-0000-0000-000000000001',
    'Emp EX073', 'active', 40
  ),
  (
    'd0730000-0000-0000-0000-000000000002',
    'a0730000-0000-0000-0000-000000000001',
    'b0730000-0000-0000-0000-000000000001',
    'c0730000-0000-0000-0000-000000000003',
    'Emp2 EX073', 'active', 40
  )
ON CONFLICT (id) DO NOTHING;

CREATE TEMP TABLE ex073_results (
  test_name text, status text, details text
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.set_mgr_ctx() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0730000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0730000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0730000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0730000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","labor_calendar.view","attendance.view_all"],"sites":{}}}}}',
    true);
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.set_emp_ctx() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0730000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0730000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"a0730000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"a0730000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{}}}}}',
    true);
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.set_emp2_ctx() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0730000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0730000-0000-0000-0000-000000000003","app_metadata":{"user_tenants":{"a0730000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"a0730000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{}}}}}',
    true);
END;
$$;

-- Shared opening (manager_approval, 1 place) + claim
DO $$
DECLARE
  v_opening jsonb;
  v_claim jsonb;
  v_opening_id uuid;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_opening := api.upsert_shift_opening(
    NULL::uuid,
    'b0730000-0000-0000-0000-000000000001'::uuid,
    date '2026-08-10',
    '10:00'::time,
    '14:00'::time,
    1,
    'manager_approval'::text,
    NULL::uuid, NULL::uuid, NULL::uuid,
    'EX073 accept'::text,
    NULL::text, NULL::text,
    NULL::timestamptz, NULL::timestamptz,
    false, false
  );
  v_opening_id := (v_opening->>'id')::uuid;
  PERFORM api.publish_shift_opening(v_opening_id);
  SET LOCAL ROLE postgres;

  PERFORM pg_temp.set_emp_ctx();
  SET LOCAL ROLE authenticated;
  v_claim := api.claim_shift_opening(v_opening_id, 'vull el torn'::text);
  SET LOCAL ROLE postgres;

  CREATE TEMP TABLE ex073_ids (
    opening_id uuid,
    claim_id uuid
  ) ON COMMIT DROP;
  INSERT INTO ex073_ids VALUES (v_opening_id, (v_claim->'claim'->>'id')::uuid);
END;
$$;

-- T1 evaluate eligible
DO $$
DECLARE
  v_elig jsonb;
  v_claim_id uuid;
BEGIN
  SELECT claim_id INTO v_claim_id FROM ex073_ids;
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_elig := api.evaluate_shift_opening_claim(v_claim_id);
  SET LOCAL ROLE postgres;

  IF (v_elig->>'ok')::boolean = true
     AND jsonb_array_length(COALESCE(v_elig->'blocks', '[]'::jsonb)) = 0
  THEN
    INSERT INTO ex073_results VALUES ('T1 evaluate_eligible', 'PASS', v_elig::text);
  ELSE
    INSERT INTO ex073_results VALUES ('T1 evaluate_eligible', 'FAIL', v_elig::text);
  END IF;
END;
$$;

-- T2 accept → published slot
DO $$
DECLARE
  v_res jsonb;
  v_claim_id uuid;
  v_slot record;
BEGIN
  SELECT claim_id INTO v_claim_id FROM ex073_ids;
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_res := api.accept_shift_opening_claim(v_claim_id, true);
  SET LOCAL ROLE postgres;

  SELECT ss.id, ss.status, ss.employee_id, ss.slot_date, ss.start_time, ss.end_time
  INTO v_slot
  FROM data.shift_slots ss
  WHERE ss.id = (v_res->>'slot_id')::uuid;

  IF v_res->>'claim_status' = 'accepted'
     AND v_res->>'opening_status' = 'filled'
     AND (v_res->>'places_filled')::int = 1
     AND v_slot.status = 'published'
     AND v_slot.employee_id = 'd0730000-0000-0000-0000-000000000001'
  THEN
    INSERT INTO ex073_results VALUES ('T2 accept_creates_published_slot', 'PASS', v_res::text);
  ELSE
    INSERT INTO ex073_results VALUES (
      'T2 accept_creates_published_slot', 'FAIL',
      jsonb_build_object('res', v_res, 'slot', to_jsonb(v_slot))::text
    );
  END IF;
END;
$$;

-- T3 overlap blocks eligibility
DO $$
DECLARE
  v_opening jsonb;
  v_claim jsonb;
  v_elig jsonb;
  v_opening_id uuid;
  v_claim_id uuid;
  v_ok boolean := false;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_opening := api.upsert_shift_opening(
    NULL::uuid,
    'b0730000-0000-0000-0000-000000000001'::uuid,
    date '2026-08-10',
    '12:00'::time,
    '16:00'::time,
    1,
    'manager_approval'::text,
    NULL::uuid, NULL::uuid, NULL::uuid,
    'EX073 overlap'::text,
    NULL::text, NULL::text,
    NULL::timestamptz, NULL::timestamptz,
    false, false
  );
  v_opening_id := (v_opening->>'id')::uuid;
  PERFORM api.publish_shift_opening(v_opening_id);
  SET LOCAL ROLE postgres;

  -- Emp1 already has 10:00–14:00 published from T2 → overlap with 12:00–16:00
  PERFORM pg_temp.set_emp_ctx();
  SET LOCAL ROLE authenticated;
  BEGIN
    v_claim := api.claim_shift_opening(v_opening_id, NULL::text);
    v_claim_id := (v_claim->'claim'->>'id')::uuid;
  EXCEPTION WHEN OTHERS THEN
    -- claim itself may still succeed for manager_approval; evaluate should block
    NULL;
  END;
  SET LOCAL ROLE postgres;

  IF v_claim_id IS NULL THEN
    -- insert claim directly if claim RPC blocked (shouldn't for manager_approval)
    INSERT INTO data.shift_opening_claims (tenant_id, opening_id, employee_id, status)
    VALUES (
      'a0730000-0000-0000-0000-000000000001',
      v_opening_id,
      'd0730000-0000-0000-0000-000000000001',
      'pending'
    )
    RETURNING id INTO v_claim_id;
  END IF;

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_elig := api.evaluate_shift_opening_claim(v_claim_id);
  BEGIN
    PERFORM api.accept_shift_opening_claim(v_claim_id, true);
    v_ok := false;
  EXCEPTION WHEN OTHERS THEN
    v_ok := SQLERRM ILIKE '%SHIFT_OVERLAP%' OR SQLERRM ILIKE '%claim_not_eligible%';
  END;
  SET LOCAL ROLE postgres;

  IF (v_elig->>'ok')::boolean = false
     AND v_elig::text ILIKE '%SHIFT_OVERLAP%'
     AND v_ok
  THEN
    INSERT INTO ex073_results VALUES ('T3 overlap_blocks_accept', 'PASS', v_elig::text);
  ELSE
    INSERT INTO ex073_results VALUES (
      'T3 overlap_blocks_accept', 'FAIL',
      jsonb_build_object('elig', v_elig, 'accept_blocked', v_ok)::text
    );
  END IF;
END;
$$;

-- T4 first_eligible auto-accept on claim
DO $$
DECLARE
  v_opening jsonb;
  v_claim jsonb;
  v_opening_id uuid;
  v_slot_id uuid;
  v_slot_status text;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_opening := api.upsert_shift_opening(
    NULL::uuid,
    'b0730000-0000-0000-0000-000000000001'::uuid,
    date '2026-08-11',
    '09:00'::time,
    '13:00'::time,
    1,
    'first_eligible'::text,
    NULL::uuid, NULL::uuid, NULL::uuid,
    'EX073 first'::text,
    NULL::text, NULL::text,
    NULL::timestamptz, NULL::timestamptz,
    false, false
  );
  v_opening_id := (v_opening->>'id')::uuid;
  PERFORM api.publish_shift_opening(v_opening_id);
  SET LOCAL ROLE postgres;

  PERFORM pg_temp.set_emp2_ctx();
  SET LOCAL ROLE authenticated;
  v_claim := api.claim_shift_opening(v_opening_id, 'auto'::text);
  SET LOCAL ROLE postgres;

  v_slot_id := (v_claim->>'slot_id')::uuid;
  SELECT ss.status INTO v_slot_status FROM data.shift_slots ss WHERE ss.id = v_slot_id;

  IF COALESCE((v_claim->>'auto_accepted')::boolean, false)
     AND v_slot_id IS NOT NULL
     AND v_slot_status = 'published'
     AND EXISTS (
       SELECT 1 FROM data.shift_openings o
       WHERE o.id = v_opening_id AND o.status = 'filled' AND o.places_filled = 1
     )
  THEN
    INSERT INTO ex073_results VALUES ('T4 first_eligible_auto_accept', 'PASS', v_claim::text);
  ELSE
    INSERT INTO ex073_results VALUES ('T4 first_eligible_auto_accept', 'FAIL', v_claim::text);
  END IF;
END;
$$;

-- T5 second claim when full expires / accept fails
DO $$
DECLARE
  v_opening jsonb;
  v_claim1 jsonb;
  v_claim2 jsonb;
  v_opening_id uuid;
  v_claim1_id uuid;
  v_claim2_id uuid;
  v_blocked boolean := false;
  v_expired boolean := false;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_opening := api.upsert_shift_opening(
    NULL::uuid,
    'b0730000-0000-0000-0000-000000000001'::uuid,
    date '2026-08-12',
    '15:00'::time,
    '19:00'::time,
    1,
    'manager_approval'::text,
    NULL::uuid, NULL::uuid, NULL::uuid,
    'EX073 full'::text,
    NULL::text, NULL::text,
    NULL::timestamptz, NULL::timestamptz,
    false, false
  );
  v_opening_id := (v_opening->>'id')::uuid;
  PERFORM api.publish_shift_opening(v_opening_id);
  SET LOCAL ROLE postgres;

  PERFORM pg_temp.set_emp_ctx();
  SET LOCAL ROLE authenticated;
  v_claim1 := api.claim_shift_opening(v_opening_id, 'c1'::text);
  SET LOCAL ROLE postgres;
  v_claim1_id := (v_claim1->'claim'->>'id')::uuid;

  PERFORM pg_temp.set_emp2_ctx();
  SET LOCAL ROLE authenticated;
  v_claim2 := api.claim_shift_opening(v_opening_id, 'c2'::text);
  SET LOCAL ROLE postgres;
  v_claim2_id := (v_claim2->'claim'->>'id')::uuid;

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  PERFORM api.accept_shift_opening_claim(v_claim1_id, true);

  BEGIN
    PERFORM api.accept_shift_opening_claim(v_claim2_id, true);
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM ILIKE '%claim_not_pending%'
      OR SQLERRM ILIKE '%opening_full%'
      OR SQLERRM ILIKE '%claim_not_eligible%'
      OR SQLERRM ILIKE '%opening_full_or_closed%';
  END;
  SET LOCAL ROLE postgres;

  SELECT status = 'expired' INTO v_expired
  FROM data.shift_opening_claims WHERE id = v_claim2_id;

  IF v_blocked AND v_expired THEN
    INSERT INTO ex073_results VALUES ('T5 filled_expires_other_claims', 'PASS',
      format('claim2=%s blocked=%s', v_claim2_id, v_blocked));
  ELSE
    INSERT INTO ex073_results VALUES ('T5 filled_expires_other_claims', 'FAIL',
      format('blocked=%s expired=%s claim2=%s', v_blocked, v_expired, v_claim2_id));
  END IF;
END;
$$;

SELECT test_name, status, details FROM ex073_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM ex073_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EX-07.3 tests failed: %', v_fail;
  END IF;
END;
$$;

ROLLBACK;
