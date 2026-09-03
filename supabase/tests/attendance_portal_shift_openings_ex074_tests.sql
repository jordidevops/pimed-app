-- =============================================================================
-- attendance_portal_shift_openings_ex074_tests.sql
-- EX-07.4 — Portal list / claim / withdraw openings
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0740000-0000-0000-0000-000000000001', 'EX074 Tenant', 'ex074-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b0740000-0000-0000-0000-000000000001', 'a0740000-0000-0000-0000-000000000001', 'EX074 Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0740000-0000-0000-0000-000000000001', 'emp@ex074.test', 'authenticated', 'authenticated'),
  ('c0740000-0000-0000-0000-000000000002', 'mgr@ex074.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0740000-0000-0000-0000-000000000001', 'emp@ex074.test', 'Emp EX074'),
  ('c0740000-0000-0000-0000-000000000002', 'mgr@ex074.test', 'Mgr EX074')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0740000-0000-0000-0000-000000000001', 'c0740000-0000-0000-0000-000000000001', 'member', true),
  (gen_random_uuid(), 'a0740000-0000-0000-0000-000000000001', 'c0740000-0000-0000-0000-000000000002', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status, weekly_hours)
VALUES (
  'd0740000-0000-0000-0000-000000000001',
  'a0740000-0000-0000-0000-000000000001',
  'b0740000-0000-0000-0000-000000000001',
  'c0740000-0000-0000-0000-000000000001',
  'Emp EX074', 'active', 40
)
ON CONFLICT (id) DO NOTHING;

CREATE TEMP TABLE ex074_results (
  test_name text, status text, details text
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.set_mgr_ctx() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0740000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0740000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0740000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0740000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","labor_calendar.view","attendance.view_all"],"sites":{}}}}}',
    true);
END;
$$;

-- Seed openings
DO $$
DECLARE
  v_opening jsonb;
  v_id uuid;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;

  v_opening := api.upsert_shift_opening(
    NULL::uuid,
    'b0740000-0000-0000-0000-000000000001'::uuid,
    date '2026-09-01',
    '16:00'::time,
    '20:00'::time,
    1,
    'manager_approval'::text,
    NULL::uuid, NULL::uuid, NULL::uuid,
    'EX074 portal'::text,
    NULL::text, NULL::text,
    NULL::timestamptz, NULL::timestamptz,
    false, false
  );
  v_id := (v_opening->>'id')::uuid;
  PERFORM api.publish_shift_opening(v_id);

  v_opening := api.upsert_shift_opening(
    NULL::uuid,
    'b0740000-0000-0000-0000-000000000001'::uuid,
    date '2026-09-02',
    '10:00'::time,
    '14:00'::time,
    1,
    'first_eligible'::text,
    NULL::uuid, NULL::uuid, NULL::uuid,
    'EX074 first'::text,
    NULL::text, NULL::text,
    NULL::timestamptz, NULL::timestamptz,
    false, false
  );
  PERFORM api.publish_shift_opening((v_opening->>'id')::uuid);

  SET LOCAL ROLE postgres;

  CREATE TEMP TABLE ex074_ids (
    approval_opening_id uuid,
    first_opening_id uuid
  ) ON COMMIT DROP;

  INSERT INTO ex074_ids
  SELECT
    (SELECT id FROM data.shift_openings WHERE title = 'EX074 portal' LIMIT 1),
    (SELECT id FROM data.shift_openings WHERE title = 'EX074 first' LIMIT 1);
END;
$$;

-- T1 list shows open openings for employee site
DO $$
DECLARE
  v_res jsonb;
  v_count int;
BEGIN
  v_res := api.employee_portal_list_shift_openings(
    'd0740000-0000-0000-0000-000000000001'::uuid,
    'a0740000-0000-0000-0000-000000000001'::uuid,
    date '2026-09-01',
    date '2026-09-15'
  );
  v_count := jsonb_array_length(COALESCE(v_res->'openings', '[]'::jsonb));

  IF v_count >= 2
     AND EXISTS (
       SELECT 1 FROM jsonb_array_elements(v_res->'openings') o
       WHERE o->>'title' = 'EX074 portal' AND (o->>'eligible')::boolean = true
     )
  THEN
    INSERT INTO ex074_results VALUES ('T1 portal_list_openings', 'PASS', format('count=%s', v_count));
  ELSE
    INSERT INTO ex074_results VALUES ('T1 portal_list_openings', 'FAIL', v_res::text);
  END IF;
END;
$$;

-- T2 portal claim manager_approval → pending
DO $$
DECLARE
  v_opening_id uuid;
  v_res jsonb;
  v_claim_id uuid;
BEGIN
  SELECT approval_opening_id INTO v_opening_id FROM ex074_ids;
  v_res := api.employee_portal_claim_shift_opening(
    'd0740000-0000-0000-0000-000000000001'::uuid,
    'a0740000-0000-0000-0000-000000000001'::uuid,
    v_opening_id,
    'portal claim'::text
  );
  v_claim_id := (v_res->'claim'->>'id')::uuid;

  IF COALESCE((v_res->>'auto_accepted')::boolean, true) = false
     AND v_res->'claim'->>'status' = 'pending'
     AND v_claim_id IS NOT NULL
  THEN
    INSERT INTO ex074_results VALUES ('T2 portal_claim_pending', 'PASS', v_claim_id::text);
    CREATE TEMP TABLE ex074_claim (claim_id uuid) ON COMMIT DROP;
    INSERT INTO ex074_claim VALUES (v_claim_id);
  ELSE
    INSERT INTO ex074_results VALUES ('T2 portal_claim_pending', 'FAIL', v_res::text);
  END IF;
END;
$$;

-- T3 withdraw pending claim
DO $$
DECLARE
  v_claim_id uuid;
  v_res jsonb;
BEGIN
  SELECT claim_id INTO v_claim_id FROM ex074_claim;
  v_res := api.employee_portal_withdraw_shift_opening_claim(
    'd0740000-0000-0000-0000-000000000001'::uuid,
    'a0740000-0000-0000-0000-000000000001'::uuid,
    v_claim_id
  );

  IF v_res->>'status' = 'withdrawn' THEN
    INSERT INTO ex074_results VALUES ('T3 portal_withdraw', 'PASS', v_claim_id::text);
  ELSE
    INSERT INTO ex074_results VALUES ('T3 portal_withdraw', 'FAIL', v_res::text);
  END IF;
END;
$$;

-- T4 first_eligible auto-accept via portal claim
DO $$
DECLARE
  v_opening_id uuid;
  v_res jsonb;
  v_slot_id uuid;
  v_status text;
BEGIN
  SELECT first_opening_id INTO v_opening_id FROM ex074_ids;
  v_res := api.employee_portal_claim_shift_opening(
    'd0740000-0000-0000-0000-000000000001'::uuid,
    'a0740000-0000-0000-0000-000000000001'::uuid,
    v_opening_id,
    NULL::text
  );
  v_slot_id := (v_res->>'slot_id')::uuid;
  SELECT ss.status INTO v_status FROM data.shift_slots ss WHERE ss.id = v_slot_id;

  IF COALESCE((v_res->>'auto_accepted')::boolean, false)
     AND v_slot_id IS NOT NULL
     AND v_status = 'published'
  THEN
    INSERT INTO ex074_results VALUES ('T4 portal_first_eligible', 'PASS', v_slot_id::text);
  ELSE
    INSERT INTO ex074_results VALUES ('T4 portal_first_eligible', 'FAIL', v_res::text);
  END IF;
END;
$$;

-- T5 wrong employee/tenant cannot claim
DO $$
DECLARE
  v_opening_id uuid;
  v_blocked boolean := false;
BEGIN
  -- reopen approval opening (withdrawn earlier) — still open
  SELECT approval_opening_id INTO v_opening_id FROM ex074_ids;

  BEGIN
    PERFORM api.employee_portal_claim_shift_opening(
      'd0740000-0000-0000-0000-000000000001'::uuid,
      'a9990000-0000-0000-0000-000000000099'::uuid, -- wrong tenant
      v_opening_id,
      NULL::text
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM ILIKE '%employee_not_found%' OR SQLERRM ILIKE '%opening_not_found%';
  END;

  IF v_blocked THEN
    INSERT INTO ex074_results VALUES ('T5 tenant_isolation', 'PASS', 'blocked');
  ELSE
    INSERT INTO ex074_results VALUES ('T5 tenant_isolation', 'FAIL', 'not blocked');
  END IF;
END;
$$;

SELECT test_name, status, details FROM ex074_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM ex074_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EX-07.4 tests failed: %', v_fail;
  END IF;
END;
$$;

ROLLBACK;
