-- =============================================================================
-- attendance_roles_quals_ex061_tests.sql
-- EX-06.1 — Rols, assignacions, qualificacions, herència a assign_shift_slot
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0610000-0000-0000-0000-000000000001', 'EX061 Tenant', 'ex061-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b0610000-0000-0000-0000-000000000001', 'a0610000-0000-0000-0000-000000000001', 'EX061 Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0610000-0000-0000-0000-000000000001', 'emp@ex061.test', 'authenticated', 'authenticated'),
  ('c0610000-0000-0000-0000-000000000002', 'mgr@ex061.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0610000-0000-0000-0000-000000000001', 'emp@ex061.test', 'Emp EX061'),
  ('c0610000-0000-0000-0000-000000000002', 'mgr@ex061.test', 'Mgr EX061')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0610000-0000-0000-0000-000000000001', 'c0610000-0000-0000-0000-000000000001', 'member', true),
  (gen_random_uuid(), 'a0610000-0000-0000-0000-000000000001', 'c0610000-0000-0000-0000-000000000002', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status, weekly_hours)
VALUES (
  'd0610000-0000-0000-0000-000000000001',
  'a0610000-0000-0000-0000-000000000001',
  'b0610000-0000-0000-0000-000000000001',
  'c0610000-0000-0000-0000-000000000001',
  'Emp EX061', 'active', 40
)
ON CONFLICT (id) DO NOTHING;

CREATE TEMP TABLE ex061_results (
  test_name text, status text, details text
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.set_mgr_ctx() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0610000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0610000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0610000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0610000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","attendance.view_all"],"sites":{}}}}}',
    true);
END;
$$;

-- T1 upsert_work_role
DO $$
DECLARE
  v_row jsonb;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_row := api.upsert_work_role(
    NULL, NULL, 'cambrer', 'Cambrer', 10, true
  );
  SET LOCAL ROLE postgres;
  IF v_row->>'key' = 'cambrer' AND v_row->>'name' = 'Cambrer' THEN
    INSERT INTO ex061_results VALUES ('T1 upsert_work_role', 'PASS', v_row->>'id');
  ELSE
    INSERT INTO ex061_results VALUES ('T1 upsert_work_role', 'FAIL', v_row::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex061_results VALUES ('T1 upsert_work_role', 'ERROR', SQLERRM);
END;
$$;

-- T2 role qual requirement + assignment + expired qual fails meet
DO $$
DECLARE
  v_role_id uuid;
  v_meets boolean;
BEGIN
  SELECT id INTO v_role_id FROM data.work_roles
  WHERE tenant_id = 'a0610000-0000-0000-0000-000000000001' AND key = 'cambrer';

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;

  PERFORM api.upsert_role_qualification_requirement(
    NULL, v_role_id, 'carretilla', true, NULL, true
  );

  PERFORM api.upsert_employee_role_assignment(
    NULL,
    'd0610000-0000-0000-0000-000000000001'::uuid,
    v_role_id,
    1::smallint, NULL, NULL, true, true
  );

  PERFORM api.upsert_employee_qualification(
    NULL,
    'd0610000-0000-0000-0000-000000000001'::uuid,
    'carretilla',
    'Carretilla',
    CURRENT_DATE - 30,
    CURRENT_DATE - 1,  -- expired yesterday
    NULL,
    true
  );

  v_meets := api.employee_meets_role_qualifications(
    'd0610000-0000-0000-0000-000000000001'::uuid,
    v_role_id,
    CURRENT_DATE
  );

  SET LOCAL ROLE postgres;

  IF v_meets = false THEN
    INSERT INTO ex061_results VALUES ('T2 expired_qual_fails_meet', 'PASS', 'meets=false');
  ELSE
    INSERT INTO ex061_results VALUES ('T2 expired_qual_fails_meet', 'FAIL', 'expected false');
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex061_results VALUES ('T2 expired_qual_fails_meet', 'ERROR', SQLERRM);
END;
$$;

-- T3 valid qual + role → meets
DO $$
DECLARE
  v_role_id uuid;
  v_qual_id uuid;
  v_meets boolean;
BEGIN
  SELECT id INTO v_role_id FROM data.work_roles
  WHERE tenant_id = 'a0610000-0000-0000-0000-000000000001' AND key = 'cambrer';

  SELECT id INTO v_qual_id FROM data.employee_qualifications
  WHERE employee_id = 'd0610000-0000-0000-0000-000000000001'
    AND key = 'carretilla'
    AND is_active = true;

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;

  PERFORM api.upsert_employee_qualification(
    v_qual_id,
    NULL,
    NULL,
    'Carretilla',
    CURRENT_DATE - 30,
    CURRENT_DATE + 30,
    NULL,
    true
  );

  v_meets := api.employee_meets_role_qualifications(
    'd0610000-0000-0000-0000-000000000001'::uuid,
    v_role_id,
    CURRENT_DATE
  );

  SET LOCAL ROLE postgres;

  IF v_meets = true THEN
    INSERT INTO ex061_results VALUES ('T3 valid_qual_meets', 'PASS', 'meets=true');
  ELSE
    INSERT INTO ex061_results VALUES ('T3 valid_qual_meets', 'FAIL', 'expected true');
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex061_results VALUES ('T3 valid_qual_meets', 'ERROR', SQLERRM);
END;
$$;

-- T4 create_work_shift with default_role + assign inherits role snapshot
DO $$
DECLARE
  v_role_id uuid;
  v_shift jsonb;
  v_assign jsonb;
  v_slot data.shift_slots;
BEGIN
  SELECT id INTO v_role_id FROM data.work_roles
  WHERE tenant_id = 'a0610000-0000-0000-0000-000000000001' AND key = 'cambrer';

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;

  v_shift := api.create_work_shift(
    'b0610000-0000-0000-0000-000000000001'::uuid,
    'Torn EX061',
    '09:00'::time,
    '17:00'::time,
    '#22c55e',
    v_role_id
  );

  v_assign := api.assign_shift_slot(
    'd0610000-0000-0000-0000-000000000001'::uuid,
    (CURRENT_DATE + 7),
    (v_shift->>'id')::uuid,
    NULL,
    NULL,
    NULL  -- inherit default_role_id
  );

  SET LOCAL ROLE postgres;

  SELECT * INTO v_slot FROM data.shift_slots WHERE id = (v_assign->>'slot_id')::uuid;

  IF v_shift->>'default_role_id' = v_role_id::text
     AND v_slot.role_id = v_role_id
     AND v_slot.role_name_snapshot = 'Cambrer'
  THEN
    INSERT INTO ex061_results VALUES ('T4 role_inheritance_on_assign', 'PASS', v_slot.id::text);
  ELSE
    INSERT INTO ex061_results VALUES (
      'T4 role_inheritance_on_assign', 'FAIL',
      jsonb_build_object(
        'shift_role', v_shift->>'default_role_id',
        'slot_role', v_slot.role_id,
        'snapshot', v_slot.role_name_snapshot,
        'assign', v_assign
      )::text
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex061_results VALUES ('T4 role_inheritance_on_assign', 'ERROR', SQLERRM);
END;
$$;

-- T5 has_active_role without assignment → false
DO $$
DECLARE
  v_role_id uuid;
  v_other jsonb;
  v_has boolean;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_other := api.upsert_work_role(NULL, NULL, 'cuina', 'Cuina', 20, true);
  SET LOCAL ROLE postgres;

  v_role_id := (v_other->>'id')::uuid;
  v_has := data.employee_has_active_role(
    'd0610000-0000-0000-0000-000000000001'::uuid,
    v_role_id,
    CURRENT_DATE
  );

  IF v_has = false THEN
    INSERT INTO ex061_results VALUES ('T5 no_role_assignment', 'PASS', 'has=false');
  ELSE
    INSERT INTO ex061_results VALUES ('T5 no_role_assignment', 'FAIL', 'expected false');
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex061_results VALUES ('T5 no_role_assignment', 'ERROR', SQLERRM);
END;
$$;

SELECT test_name, status, details FROM ex061_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM ex061_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EX-06.1 tests failed: % row(s)', v_fail;
  END IF;
END;
$$;

ROLLBACK;
