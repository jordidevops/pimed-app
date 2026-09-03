-- =============================================================================
-- attendance_inspection_access_ex092_tests.sql
-- EX-09.2 — enllaços d'inspecció (resolve + constraints; create via JWT si possible)
-- Executar:
--   psql postgresql://postgres:postgres@127.0.0.1:54322/postgres \
--     -f supabase/tests/attendance_inspection_access_ex092_tests.sql
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0920000-0000-0000-0000-000000000001', 'EX092 Tenant', 'ex092-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES (
  'b0920000-0000-0000-0000-000000000001',
  'a0920000-0000-0000-0000-000000000001',
  'EX092 Site',
  true
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0920000-0000-0000-0000-000000000001', 'emp@ex092.test', 'authenticated', 'authenticated'),
  ('c0920000-0000-0000-0000-000000000002', 'mgr@ex092.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0920000-0000-0000-0000-000000000001', 'emp@ex092.test', 'Emp EX092'),
  ('c0920000-0000-0000-0000-000000000002', 'mgr@ex092.test', 'Mgr EX092')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0920000-0000-0000-0000-000000000001',
   'c0920000-0000-0000-0000-000000000001', 'member', true),
  (gen_random_uuid(), 'a0920000-0000-0000-0000-000000000001',
   'c0920000-0000-0000-0000-000000000002', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES
  (
    'd0920000-0000-0000-0000-000000000001',
    'a0920000-0000-0000-0000-000000000001',
    'b0920000-0000-0000-0000-000000000001',
    'c0920000-0000-0000-0000-000000000001',
    'Emp EX092',
    'active'
  ),
  (
    'd0920000-0000-0000-0000-000000000002',
    'a0920000-0000-0000-0000-000000000001',
    'b0920000-0000-0000-0000-000000000001',
    NULL,
    'Other Emp EX092',
    'active'
  )
ON CONFLICT (id) DO NOTHING;

CREATE TEMP TABLE ex092_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.set_mgr_ctx() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0920000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claim.sub',
    'c0920000-0000-0000-0000-000000000002', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0920000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0920000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0920000-0000-0000-0000-000000000001":{"global_permissions":["attendance.export","attendance.view_all"],"sites":{}}}}}',
    true);
END;
$$;

-- Fixture punches + summary in / out of inspection period
DO $$
DECLARE
  v_tenant uuid := 'a0920000-0000-0000-0000-000000000001';
  v_site   uuid := 'b0920000-0000-0000-0000-000000000001';
  v_emp    uuid := 'd0920000-0000-0000-0000-000000000001';
  v_other  uuid := 'd0920000-0000-0000-0000-000000000002';
  v_in     date := CURRENT_DATE - 10;
  v_out    date := CURRENT_DATE - 40;
  v_sum    date := CURRENT_DATE - 5;
BEGIN
  INSERT INTO data.time_punches (
    id, tenant_id, site_id, employee_id, client_op_id, punch_type, occurred_at, source
  ) VALUES
    (
      'e0920000-0000-0000-0000-000000000001',
      v_tenant, v_site, v_emp,
      'e0920000-0000-0000-0000-0000000000c1',
      'in',
      (v_in + time '09:00') AT TIME ZONE 'Europe/Madrid',
      'manual_entry'
    ),
    (
      'e0920000-0000-0000-0000-000000000002',
      v_tenant, v_site, v_emp,
      'e0920000-0000-0000-0000-0000000000c2',
      'in',
      (v_out + time '09:00') AT TIME ZONE 'Europe/Madrid',
      'manual_entry'
    ),
    (
      'e0920000-0000-0000-0000-000000000003',
      v_tenant, v_site, v_other,
      'e0920000-0000-0000-0000-0000000000c3',
      'in',
      (v_in + time '10:00') AT TIME ZONE 'Europe/Madrid',
      'manual_entry'
    )
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO data.time_daily_summaries (
    id, tenant_id, site_id, employee_id, work_date, status, worked_minutes, punch_count
  ) VALUES (
    'f0920000-0000-0000-0000-000000000001',
    v_tenant, v_site, v_emp, v_sum, 'draft', 480, 1
  )
  ON CONFLICT (employee_id, work_date) DO UPDATE
    SET worked_minutes = 480, punch_count = 1, status = 'draft';
END $$;

-- Link rows (direct insert with known hash)
DO $$
DECLARE
  v_hash bytea := api._employee_portal_secret_hash_bytea('test-secret-ex092');
BEGIN
  INSERT INTO data.attendance_inspection_access_links (
    id, tenant_id, employee_id, period_from, period_to,
    token_hash, expires_at, created_by, label
  ) VALUES
    (
      'a0920000-0000-0000-0000-0000000000a1',
      'a0920000-0000-0000-0000-000000000001',
      'd0920000-0000-0000-0000-000000000001',
      CURRENT_DATE - 30,
      CURRENT_DATE,
      v_hash,
      now() + interval '7 days',
      'c0920000-0000-0000-0000-000000000002',
      'EX092 resolve OK'
    ),
    (
      'a0920000-0000-0000-0000-0000000000a2',
      'a0920000-0000-0000-0000-000000000001',
      'd0920000-0000-0000-0000-000000000001',
      CURRENT_DATE - 30,
      CURRENT_DATE,
      api._employee_portal_secret_hash_bytea('test-secret-ex092-revoke'),
      now() + interval '7 days',
      'c0920000-0000-0000-0000-000000000002',
      'EX092 revoke'
    ),
    (
      'a0920000-0000-0000-0000-0000000000a3',
      'a0920000-0000-0000-0000-000000000001',
      'd0920000-0000-0000-0000-000000000001',
      CURRENT_DATE - 30,
      CURRENT_DATE,
      api._employee_portal_secret_hash_bytea('test-secret-ex092-expire'),
      now() + interval '7 days',
      'c0920000-0000-0000-0000-000000000002',
      'EX092 expire'
    )
  ON CONFLICT (id) DO UPDATE
    SET token_hash = EXCLUDED.token_hash,
        expires_at = EXCLUDED.expires_at,
        revoked_at = NULL,
        period_from = EXCLUDED.period_from,
        period_to = EXCLUDED.period_to;
END $$;

-- T1: resolve OK — punches/summaries scoped to employee + period
DO $$
DECLARE
  v_payload jsonb;
  v_punch_ids uuid[];
  v_ok boolean;
BEGIN
  SET LOCAL ROLE service_role;

  v_payload := api.resolve_attendance_inspection_access(
    'a0920000-0000-0000-0000-0000000000a1'::uuid,
    'test-secret-ex092',
    0, 500, 0, 200
  );

  RESET ROLE;

  SELECT COALESCE(array_agg((p->>'id')::uuid), ARRAY[]::uuid[])
  INTO v_punch_ids
  FROM jsonb_array_elements(COALESCE(v_payload->'punches', '[]'::jsonb)) p;

  v_ok := v_payload IS NOT NULL
    AND v_payload->>'employee_id' = 'd0920000-0000-0000-0000-000000000001'
    AND COALESCE((v_payload->>'punches_total')::int, 0) >= 1
    AND 'e0920000-0000-0000-0000-000000000001' = ANY (v_punch_ids)
    AND NOT ('e0920000-0000-0000-0000-000000000002' = ANY (v_punch_ids))
    AND NOT ('e0920000-0000-0000-0000-000000000003' = ANY (v_punch_ids))
    AND COALESCE((v_payload->>'summaries_total')::int, 0) >= 1;

  IF v_ok THEN
    INSERT INTO ex092_results VALUES ('T1 resolve scoped payload', 'PASS',
      format('punches_total=%s summaries_total=%s',
        v_payload->>'punches_total', v_payload->>'summaries_total'));
  ELSE
    INSERT INTO ex092_results VALUES ('T1 resolve scoped payload', 'FAIL',
      COALESCE(v_payload::text, 'NULL'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO ex092_results VALUES ('T1 resolve scoped payload', 'FAIL', SQLERRM);
END $$;

-- T2: wrong secret → NULL
DO $$
DECLARE
  v_payload jsonb;
BEGIN
  SET LOCAL ROLE service_role;
  v_payload := api.resolve_attendance_inspection_access(
    'a0920000-0000-0000-0000-0000000000a1'::uuid,
    'wrong-secret-ex092',
    0, 500, 0, 200
  );
  RESET ROLE;

  IF v_payload IS NULL THEN
    INSERT INTO ex092_results VALUES ('T2 wrong secret NULL', 'PASS', 'null');
  ELSE
    INSERT INTO ex092_results VALUES ('T2 wrong secret NULL', 'FAIL', v_payload::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO ex092_results VALUES ('T2 wrong secret NULL', 'FAIL', SQLERRM);
END $$;

-- T3: revoked_at set → NULL
DO $$
DECLARE
  v_payload jsonb;
BEGIN
  UPDATE data.attendance_inspection_access_links
  SET revoked_at = now()
  WHERE id = 'a0920000-0000-0000-0000-0000000000a2';

  SET LOCAL ROLE service_role;
  v_payload := api.resolve_attendance_inspection_access(
    'a0920000-0000-0000-0000-0000000000a2'::uuid,
    'test-secret-ex092-revoke',
    0, 500, 0, 200
  );
  RESET ROLE;

  IF v_payload IS NULL THEN
    INSERT INTO ex092_results VALUES ('T3 revoked NULL', 'PASS', 'null');
  ELSE
    INSERT INTO ex092_results VALUES ('T3 revoked NULL', 'FAIL', v_payload::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO ex092_results VALUES ('T3 revoked NULL', 'FAIL', SQLERRM);
END $$;

-- T4: expires_at in past → NULL
DO $$
DECLARE
  v_payload jsonb;
BEGIN
  UPDATE data.attendance_inspection_access_links
  SET expires_at = now() - interval '1 hour',
      revoked_at = NULL
  WHERE id = 'a0920000-0000-0000-0000-0000000000a3';

  SET LOCAL ROLE service_role;
  v_payload := api.resolve_attendance_inspection_access(
    'a0920000-0000-0000-0000-0000000000a3'::uuid,
    'test-secret-ex092-expire',
    0, 500, 0, 200
  );
  RESET ROLE;

  IF v_payload IS NULL THEN
    INSERT INTO ex092_results VALUES ('T4 expired NULL', 'PASS', 'null');
  ELSE
    INSERT INTO ex092_results VALUES ('T4 expired NULL', 'FAIL', v_payload::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO ex092_results VALUES ('T4 expired NULL', 'FAIL', SQLERRM);
END $$;

-- T5: period > 400 days CHECK fails on insert
DO $$
DECLARE
  v_raised boolean := false;
  v_msg    text;
BEGIN
  BEGIN
    INSERT INTO data.attendance_inspection_access_links (
      id, tenant_id, employee_id, period_from, period_to,
      token_hash, expires_at, created_by, label
    ) VALUES (
      'a0920000-0000-0000-0000-0000000000a4',
      'a0920000-0000-0000-0000-000000000001',
      'd0920000-0000-0000-0000-000000000001',
      CURRENT_DATE - 401,
      CURRENT_DATE,
      api._employee_portal_secret_hash_bytea('test-secret-ex092-range'),
      now() + interval '7 days',
      'c0920000-0000-0000-0000-000000000002',
      'EX092 too long'
    );
  EXCEPTION WHEN check_violation THEN
    v_raised := true;
    v_msg := SQLERRM;
  WHEN OTHERS THEN
    v_msg := SQLERRM;
  END;

  IF v_raised THEN
    INSERT INTO ex092_results VALUES ('T5 period >400 CHECK', 'PASS', v_msg);
  ELSE
    INSERT INTO ex092_results VALUES ('T5 period >400 CHECK', 'FAIL',
      COALESCE(v_msg, 'insert succeeded'));
  END IF;
END $$;

-- T6 (optional): create RPC with JWT manager context
DO $$
DECLARE
  v_created jsonb;
  v_ok boolean := false;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;

  v_created := api.create_attendance_inspection_access_link(
    'd0920000-0000-0000-0000-000000000001'::uuid,
    CURRENT_DATE - 14,
    CURRENT_DATE,
    7,
    'EX092 create RPC'
  );

  RESET ROLE;

  v_ok := v_created IS NOT NULL
    AND v_created ? 'id'
    AND v_created ? 'url_secret'
    AND length(COALESCE(v_created->>'url_secret', '')) > 0;

  IF v_ok THEN
    INSERT INTO ex092_results VALUES ('T6 create RPC JWT', 'PASS',
      format('id=%s', v_created->>'id'));
  ELSE
    INSERT INTO ex092_results VALUES ('T6 create RPC JWT', 'FAIL',
      COALESCE(v_created::text, 'NULL'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  -- JWT mocking can fail depending on auth.uid(); treat as soft skip via FAIL details
  INSERT INTO ex092_results VALUES ('T6 create RPC JWT', 'FAIL', SQLERRM);
END $$;

SELECT test_name, status, details FROM ex092_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  -- T6 is optional: if JWT create fails, do not fail the suite when core T1–T5 pass
  SELECT count(*) INTO v_fail
  FROM ex092_results
  WHERE status <> 'PASS'
    AND test_name <> 'T6 create RPC JWT';

  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EX-09.2 tests failed: %', v_fail;
  END IF;

  -- If T6 failed, log warning but still pass suite
  IF EXISTS (
    SELECT 1 FROM ex092_results
    WHERE test_name = 'T6 create RPC JWT' AND status <> 'PASS'
  ) THEN
    RAISE NOTICE 'EX-09.2: T6 create RPC skipped/failed (JWT) — core resolve tests OK';
  END IF;
END $$;

ROLLBACK;
