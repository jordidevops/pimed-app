-- =============================================================================
-- attendance_portal_my_shifts_ex044_tests.sql
-- EX-04.4 — employee_portal_get_my_shifts (published only)
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0440000-0000-0000-0000-000000000001', 'EX044 Tenant', 'ex044-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b0440000-0000-0000-0000-000000000001', 'a0440000-0000-0000-0000-000000000001', 'EX044 Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0440000-0000-0000-0000-000000000001', 'emp@ex044.test', 'authenticated', 'authenticated'),
  ('c0440000-0000-0000-0000-000000000002', 'mgr@ex044.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0440000-0000-0000-0000-000000000001', 'emp@ex044.test', 'Emp EX044'),
  ('c0440000-0000-0000-0000-000000000002', 'mgr@ex044.test', 'Mgr EX044')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0440000-0000-0000-0000-000000000001', 'c0440000-0000-0000-0000-000000000001', 'member', true),
  (gen_random_uuid(), 'a0440000-0000-0000-0000-000000000001', 'c0440000-0000-0000-0000-000000000002', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES (
  'd0440000-0000-0000-0000-000000000001',
  'a0440000-0000-0000-0000-000000000001',
  'b0440000-0000-0000-0000-000000000001',
  'c0440000-0000-0000-0000-000000000001',
  'Emp EX044', 'active'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.work_shifts (
  id, tenant_id, site_id, name, color, start_time, end_time, is_active
) VALUES (
  'f0440000-0000-0000-0000-000000000001',
  'a0440000-0000-0000-0000-000000000001',
  'b0440000-0000-0000-0000-000000000001',
  'Matí EX044', '#3b82f6', '09:00', '17:00', true
)
ON CONFLICT DO NOTHING;

CREATE TEMP TABLE ex044_results (
  test_name text, status text, details text
) ON COMMIT DROP;

-- Seed: 1 draft + 1 published
INSERT INTO data.shift_slots (
  id, tenant_id, site_id, employee_id, shift_id, slot_date, status,
  start_time, end_time, created_by, published_at
) VALUES
(
  'e0440000-0000-0000-0000-000000000001',
  'a0440000-0000-0000-0000-000000000001',
  'b0440000-0000-0000-0000-000000000001',
  'd0440000-0000-0000-0000-000000000001',
  'f0440000-0000-0000-0000-000000000001',
  '2026-10-05', 'draft', '09:00', '17:00',
  'c0440000-0000-0000-0000-000000000002', NULL
),
(
  'e0440000-0000-0000-0000-000000000002',
  'a0440000-0000-0000-0000-000000000001',
  'b0440000-0000-0000-0000-000000000001',
  'd0440000-0000-0000-0000-000000000001',
  'f0440000-0000-0000-0000-000000000001',
  '2026-10-06', 'published', '09:00', '17:00',
  'c0440000-0000-0000-0000-000000000002', now()
);

-- T1: only published returned
DO $$
DECLARE
  v_res jsonb;
  v_cnt int;
BEGIN
  v_res := api.employee_portal_get_my_shifts(
    'd0440000-0000-0000-0000-000000000001'::uuid,
    'a0440000-0000-0000-0000-000000000001'::uuid,
    '2026-10-05'::date,
    '2026-10-11'::date
  );
  v_cnt := jsonb_array_length(v_res->'slots');
  IF v_cnt = 1
     AND v_res->'slots'->0->>'id' = 'e0440000-0000-0000-0000-000000000002'
     AND v_res->'slots'->0->>'shift_name' = 'Matí EX044'
  THEN
    INSERT INTO ex044_results VALUES ('T1 published only', 'PASS', v_res::text);
  ELSE
    INSERT INTO ex044_results VALUES ('T1 published only', 'FAIL', v_res::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex044_results VALUES ('T1 published only', 'ERROR', SQLERRM);
END;
$$;

-- T2: wrong tenant → employee_not_found
DO $$
DECLARE
  v_ok boolean := false;
BEGIN
  BEGIN
    PERFORM api.employee_portal_get_my_shifts(
      'd0440000-0000-0000-0000-000000000001'::uuid,
      'a0440000-0000-0000-0000-000000000099'::uuid,
      '2026-10-05'::date,
      '2026-10-11'::date
    );
  EXCEPTION WHEN OTHERS THEN
    v_ok := SQLERRM LIKE '%employee_not_found%';
  END;
  IF v_ok THEN
    INSERT INTO ex044_results VALUES ('T2 tenant guard', 'PASS', 'ok');
  ELSE
    INSERT INTO ex044_results VALUES ('T2 tenant guard', 'FAIL', 'not blocked');
  END IF;
END;
$$;

-- T3: invalid range
DO $$
DECLARE
  v_ok boolean := false;
BEGIN
  BEGIN
    PERFORM api.employee_portal_get_my_shifts(
      'd0440000-0000-0000-0000-000000000001'::uuid,
      'a0440000-0000-0000-0000-000000000001'::uuid,
      '2026-10-11'::date,
      '2026-10-05'::date
    );
  EXCEPTION WHEN OTHERS THEN
    v_ok := SQLERRM LIKE '%invalid_date_range%';
  END;
  IF v_ok THEN
    INSERT INTO ex044_results VALUES ('T3 invalid range', 'PASS', 'ok');
  ELSE
    INSERT INTO ex044_results VALUES ('T3 invalid range', 'FAIL', 'not blocked');
  END IF;
END;
$$;

SELECT * FROM ex044_results ORDER BY test_name;
SELECT
  count(*) FILTER (WHERE status = 'PASS') AS passed,
  count(*) FILTER (WHERE status = 'FAIL') AS failed,
  count(*) FILTER (WHERE status = 'ERROR') AS errors,
  count(*) AS total
FROM ex044_results;

ROLLBACK;
