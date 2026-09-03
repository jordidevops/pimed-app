-- =============================================================================
-- attendance_st19_shift_location_ex034_tests.sql
-- EX-03.4 / ST-19 — location a work_shifts/shift_slots, snapshots, integritat,
-- exposició al resolver canònic.
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0350000-0000-0000-0000-000000000001', 'EX034 Tenant', 'ex034-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES
  ('b0350000-0000-0000-0000-000000000001', 'a0350000-0000-0000-0000-000000000001', 'EX034 Site A', true),
  ('b0350000-0000-0000-0000-000000000002', 'a0350000-0000-0000-0000-000000000001', 'EX034 Site B', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0350000-0000-0000-0000-000000000001', 'emp@ex034.test', 'authenticated', 'authenticated'),
  ('c0350000-0000-0000-0000-000000000002', 'mgr@ex034.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0350000-0000-0000-0000-000000000001', 'emp@ex034.test', 'Emp EX034'),
  ('c0350000-0000-0000-0000-000000000002', 'mgr@ex034.test', 'Mgr EX034')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0350000-0000-0000-0000-000000000001', 'c0350000-0000-0000-0000-000000000001', 'member', true),
  (gen_random_uuid(), 'a0350000-0000-0000-0000-000000000001', 'c0350000-0000-0000-0000-000000000002', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES (
  'd0350000-0000-0000-0000-000000000001',
  'a0350000-0000-0000-0000-000000000001',
  'b0350000-0000-0000-0000-000000000001',
  'c0350000-0000-0000-0000-000000000001',
  'Emp EX034', 'active'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.locations (id, tenant_id, site_id, name, type, status)
VALUES
  ('e0350000-0000-0000-0000-000000000001', 'a0350000-0000-0000-0000-000000000001',
   'b0350000-0000-0000-0000-000000000001', 'Cuina', 'zone', 'active'),
  ('e0350000-0000-0000-0000-000000000002', 'a0350000-0000-0000-0000-000000000001',
   'b0350000-0000-0000-0000-000000000001', 'Passadís', 'zone', 'active'),
  ('e0350000-0000-0000-0000-000000000003', 'a0350000-0000-0000-0000-000000000001',
   'b0350000-0000-0000-0000-000000000002', 'Magatzem B', 'zone', 'active')
ON CONFLICT (id) DO NOTHING;

UPDATE data.locations
SET parent_id = 'e0350000-0000-0000-0000-000000000001'
WHERE id = 'e0350000-0000-0000-0000-000000000002';

INSERT INTO data.work_shifts (
  id, tenant_id, site_id, name, color, start_time, end_time, is_active, default_location_id
) VALUES (
  'f0350000-0000-0000-0000-000000000001',
  'a0350000-0000-0000-0000-000000000001',
  'b0350000-0000-0000-0000-000000000001',
  'Matí Cuina', '#3b82f6', '09:00', '17:00', true,
  'e0350000-0000-0000-0000-000000000001'
)
ON CONFLICT DO NOTHING;

CREATE TEMP TABLE ex034_results (
  test_name text, status text, details text
) ON COMMIT DROP;

-- T1: herència default_location en assign
DO $$
DECLARE
  v_result jsonb;
  v_slot uuid;
  v_loc uuid;
  v_snap text;
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0350000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0350000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0350000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","attendance.view_all"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  -- 2026-07-13 = dilluns
  v_result := api.assign_shift_slot(
    'd0350000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date,
    'f0350000-0000-0000-0000-000000000001'::uuid
  );

  SET LOCAL ROLE postgres;

  v_slot := (v_result->>'slot_id')::uuid;
  SELECT location_id, location_name_snapshot INTO v_loc, v_snap
  FROM data.shift_slots WHERE id = v_slot;

  IF v_loc = 'e0350000-0000-0000-0000-000000000001'
     AND v_snap = 'Cuina'
     AND v_result->>'location_id' = 'e0350000-0000-0000-0000-000000000001'
  THEN
    INSERT INTO ex034_results VALUES ('T1 herència default_location', 'PASS',
      format('loc=%s snap=%s', v_loc, v_snap));
  ELSE
    INSERT INTO ex034_results VALUES ('T1 herència default_location', 'FAIL',
      format('result=%s loc=%s snap=%s', v_result, v_loc, v_snap));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex034_results VALUES ('T1 herència default_location', 'ERROR', SQLERRM);
END $$;

-- T2: override explícit p_location_id (Passadís fill)
DO $$
DECLARE
  v_result jsonb;
  v_path text;
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0350000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0350000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0350000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","attendance.view_all"],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;

  v_result := api.assign_shift_slot(
    'd0350000-0000-0000-0000-000000000001',
    '2026-07-14'::date,
    'f0350000-0000-0000-0000-000000000001',
    NULL,
    'e0350000-0000-0000-0000-000000000002'
  );

  SET LOCAL ROLE postgres;

  SELECT location_path_snapshot INTO v_path
  FROM data.shift_slots WHERE id = (v_result->>'slot_id')::uuid;

  IF v_result->>'location_id' = 'e0350000-0000-0000-0000-000000000002'
     AND v_path LIKE '%Cuina%Passadís%'
  THEN
    INSERT INTO ex034_results VALUES ('T2 override location + path snapshot', 'PASS', v_path);
  ELSE
    INSERT INTO ex034_results VALUES ('T2 override location + path snapshot', 'FAIL',
      format('result=%s path=%s', v_result, v_path));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex034_results VALUES ('T2 override location + path snapshot', 'ERROR', SQLERRM);
END $$;

-- T3: location d'un altre site → reject
DO $$
BEGIN
  INSERT INTO data.shift_slots (
    tenant_id, site_id, employee_id, shift_id,
    slot_date, status, start_time, end_time, location_id
  ) VALUES (
    'a0350000-0000-0000-0000-000000000001',
    'b0350000-0000-0000-0000-000000000001',
    'd0350000-0000-0000-0000-000000000001',
    'f0350000-0000-0000-0000-000000000001',
    '2026-07-15', 'draft', '09:00', '17:00',
    'e0350000-0000-0000-0000-000000000003' -- site B
  );
  INSERT INTO ex034_results VALUES ('T3 location site mismatch', 'FAIL', 'expected exception');
EXCEPTION WHEN foreign_key_violation THEN
  INSERT INTO ex034_results VALUES ('T3 location site mismatch', 'PASS', SQLERRM);
WHEN OTHERS THEN
  IF SQLERRM ILIKE '%location site mismatch%' THEN
    INSERT INTO ex034_results VALUES ('T3 location site mismatch', 'PASS', SQLERRM);
  ELSE
    INSERT INTO ex034_results VALUES ('T3 location site mismatch', 'FAIL', SQLERRM);
  END IF;
END $$;

-- T4: publish congela snapshot; rename location no canvia snapshot
DO $$
DECLARE
  v_slot uuid;
  v_name_before text;
  v_name_after text;
BEGIN
  SELECT id INTO v_slot FROM data.shift_slots
  WHERE employee_id = 'd0350000-0000-0000-0000-000000000001'
    AND slot_date = '2026-07-13' AND status = 'draft'
  LIMIT 1;

  UPDATE data.shift_slots
  SET status = 'published', published_at = now()
  WHERE id = v_slot;

  SELECT location_name_snapshot INTO v_name_before FROM data.shift_slots WHERE id = v_slot;

  UPDATE data.locations SET name = 'Cuina Nova' WHERE id = 'e0350000-0000-0000-0000-000000000001';

  SELECT location_name_snapshot INTO v_name_after FROM data.shift_slots WHERE id = v_slot;

  IF v_name_before = 'Cuina' AND v_name_after = 'Cuina' THEN
    INSERT INTO ex034_results VALUES ('T4 snapshot immutable després rename', 'PASS',
      format('snap=%s', v_name_after));
  ELSE
    INSERT INTO ex034_results VALUES ('T4 snapshot immutable després rename', 'FAIL',
      format('before=%s after=%s', v_name_before, v_name_after));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex034_results VALUES ('T4 snapshot immutable després rename', 'ERROR', SQLERRM);
END $$;

-- T5: no es pot mutar location d'un slot published
DO $$
DECLARE
  v_slot uuid;
BEGIN
  SELECT id INTO v_slot FROM data.shift_slots
  WHERE employee_id = 'd0350000-0000-0000-0000-000000000001'
    AND slot_date = '2026-07-13' AND status = 'published'
  LIMIT 1;

  UPDATE data.shift_slots
  SET location_id = 'e0350000-0000-0000-0000-000000000002'
  WHERE id = v_slot;

  INSERT INTO ex034_results VALUES ('T5 freeze location published', 'FAIL', 'expected exception');
EXCEPTION WHEN check_violation THEN
  INSERT INTO ex034_results VALUES ('T5 freeze location published', 'PASS', SQLERRM);
WHEN OTHERS THEN
  IF SQLERRM ILIKE '%cannot mutate published%' THEN
    INSERT INTO ex034_results VALUES ('T5 freeze location published', 'PASS', SQLERRM);
  ELSE
    INSERT INTO ex034_results VALUES ('T5 freeze location published', 'FAIL', SQLERRM);
  END IF;
END $$;

-- T6: resolver exposa scheduled_location_id
DO $$
DECLARE
  r jsonb;
BEGIN
  -- Assegurar base laborable (override puntual) perquè slots apliquin
  INSERT INTO data.labor_calendar_overrides (
    tenant_id, site_id, group_id, employee_id,
    calendar_date, day_type, work_start, work_end, work_intervals
  ) VALUES (
    'a0350000-0000-0000-0000-000000000001',
    NULL, NULL, 'd0350000-0000-0000-0000-000000000001',
    '2026-07-13', 'work', '09:00', '17:00',
    '[{"start":"09:00","end":"17:00"}]'::jsonb
  );

  r := data.resolve_employee_work_plan(
    'd0350000-0000-0000-0000-000000000001', '2026-07-13'::date
  );

  IF r->>'labor_source' = 'published_shift'
     AND r->>'scheduled_location_id' = 'e0350000-0000-0000-0000-000000000001'
     AND r->>'scheduled_location_name' = 'Cuina'
     AND r->'work_intervals'->0->>'location_id' = 'e0350000-0000-0000-0000-000000000001'
  THEN
    INSERT INTO ex034_results VALUES ('T6 resolver scheduled_location_id', 'PASS',
      format('loc=%s name=%s', r->>'scheduled_location_id', r->>'scheduled_location_name'));
  ELSE
    INSERT INTO ex034_results VALUES ('T6 resolver scheduled_location_id', 'FAIL', r::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO ex034_results VALUES ('T6 resolver scheduled_location_id', 'ERROR', SQLERRM);
END $$;

-- T7: default_location site mismatch a work_shifts
DO $$
BEGIN
  UPDATE data.work_shifts
  SET default_location_id = 'e0350000-0000-0000-0000-000000000003'
  WHERE id = 'f0350000-0000-0000-0000-000000000001';
  INSERT INTO ex034_results VALUES ('T7 work_shift default_location site mismatch', 'FAIL', 'expected exception');
EXCEPTION WHEN foreign_key_violation THEN
  INSERT INTO ex034_results VALUES ('T7 work_shift default_location site mismatch', 'PASS', SQLERRM);
WHEN OTHERS THEN
  IF SQLERRM ILIKE '%default_location site mismatch%' THEN
    INSERT INTO ex034_results VALUES ('T7 work_shift default_location site mismatch', 'PASS', SQLERRM);
  ELSE
    INSERT INTO ex034_results VALUES ('T7 work_shift default_location site mismatch', 'FAIL', SQLERRM);
  END IF;
END $$;

SELECT test_name, status, details FROM ex034_results ORDER BY test_name;
SELECT
  count(*) FILTER (WHERE status = 'PASS') AS passed,
  count(*) FILTER (WHERE status = 'FAIL') AS failed,
  count(*) FILTER (WHERE status = 'ERROR') AS errors,
  count(*) AS total
FROM ex034_results;

ROLLBACK;
