-- =============================================================================
-- attendance_coverage_ops_ex065_tests.sql
-- EX-06.5 — Snapshot operatiu + alertes de gap
-- =============================================================================

BEGIN;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0650000-0000-0000-0000-000000000001', 'EX065 Tenant', 'ex065-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active, settings)
VALUES (
  'b0650000-0000-0000-0000-000000000001',
  'a0650000-0000-0000-0000-000000000001',
  'EX065 Site', true,
  '{"site_timezone":"Europe/Madrid"}'::jsonb
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0650000-0000-0000-0000-000000000001', 'emp@ex065.test', 'authenticated', 'authenticated'),
  ('c0650000-0000-0000-0000-000000000002', 'mgr@ex065.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0650000-0000-0000-0000-000000000001', 'emp@ex065.test', 'Emp EX065'),
  ('c0650000-0000-0000-0000-000000000002', 'mgr@ex065.test', 'Mgr EX065')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0650000-0000-0000-0000-000000000001', 'c0650000-0000-0000-0000-000000000001', 'member', true),
  (gen_random_uuid(), 'a0650000-0000-0000-0000-000000000001', 'c0650000-0000-0000-0000-000000000002', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status, weekly_hours)
VALUES (
  'd0650000-0000-0000-0000-000000000001',
  'a0650000-0000-0000-0000-000000000001',
  'b0650000-0000-0000-0000-000000000001',
  'c0650000-0000-0000-0000-000000000001',
  'Emp EX065', 'active', 40
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.work_roles (id, tenant_id, key, name, sort_order, is_active)
VALUES ('e0650000-0000-0000-0000-000000000001', 'a0650000-0000-0000-0000-000000000001', 'cambrer', 'Cambrer', 10, true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.work_shifts (id, tenant_id, site_id, name, color, start_time, end_time, is_active, default_role_id)
VALUES (
  'f0650000-0000-0000-0000-000000000001',
  'a0650000-0000-0000-0000-000000000001',
  'b0650000-0000-0000-0000-000000000001',
  'Torn EX065', '#22c55e', '09:00', '17:00', true,
  'e0650000-0000-0000-0000-000000000001'
)
ON CONFLICT (id) DO NOTHING;

CREATE TEMP TABLE ex065_results (
  test_name text, status text, details text
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.set_mgr_ctx() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0650000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0650000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0650000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0650000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","labor_calendar.view","attendance.view_all"],"sites":{}}}}}',
    true);
END;
$$;

-- Data fixa: dilluns amb demanda 11:00-14:00 need 2; 1 slot published; as_of = 11:15
DO $$
DECLARE
  v_monday date := date '2026-07-13'; -- dilluns
BEGIN
  INSERT INTO data.coverage_demands (
    id, tenant_id, site_id, role_id, kind, day_of_week, demand_date,
    start_time, end_time, required_min, required_target, priority, source, name,
    effective_from, is_active
  ) VALUES (
    'a0650000-0000-0000-0000-000000000011',
    'a0650000-0000-0000-0000-000000000001',
    'b0650000-0000-0000-0000-000000000001',
    'e0650000-0000-0000-0000-000000000001',
    'extraordinary', NULL, v_monday,
    '11:00', '14:00', 0, 2, 50, 'manual', 'Punta EX065',
    v_monday - 7, true
  ) ON CONFLICT (id) DO NOTHING;

  INSERT INTO data.shift_slots (
    id, tenant_id, site_id, employee_id, shift_id, slot_date, status,
    start_time, end_time, role_id, role_name_snapshot, published_at
  ) VALUES (
    'a0650000-0000-0000-0000-000000000012',
    'a0650000-0000-0000-0000-000000000001',
    'b0650000-0000-0000-0000-000000000001',
    'd0650000-0000-0000-0000-000000000001',
    'f0650000-0000-0000-0000-000000000001',
    v_monday, 'published',
    '09:00', '17:00',
    'e0650000-0000-0000-0000-000000000001', 'Cambrer', now()
  ) ON CONFLICT (id) DO NOTHING;
END;
$$;

-- T1: gap planificat ara (need 2, planned 1) + missing_now (no punch)
DO $$
DECLARE
  v_as_of timestamptz := (timestamp '2026-07-13 11:15:00' AT TIME ZONE 'Europe/Madrid');
  v_snap jsonb;
  v_alerts int;
  v_missing int;
  v_kinds text;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_snap := api.get_coverage_operational_snapshot(
    'b0650000-0000-0000-0000-000000000001'::uuid,
    30, 240,
    'e0650000-0000-0000-0000-000000000001'::uuid,
    v_as_of
  );
  SET LOCAL ROLE postgres;

  v_alerts := jsonb_array_length(COALESCE(v_snap->'alerts', '[]'::jsonb));
  v_missing := jsonb_array_length(COALESCE(v_snap->'missing_now', '[]'::jsonb));
  v_kinds := v_snap::text;

  IF v_missing = 1
     AND (v_snap->'summary'->>'missing_now_count')::int = 1
     AND (v_snap->'current'->>'required')::int = 2
     AND (v_snap->'current'->>'planned')::int = 1
     AND v_alerts >= 1
     AND v_kinds ILIKE '%understaffed_planned%'
  THEN
    INSERT INTO ex065_results VALUES ('T1 gap_and_missing', 'PASS', (v_snap->'summary')::text);
  ELSE
    INSERT INTO ex065_results VALUES ('T1 gap_and_missing', 'FAIL', v_snap::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex065_results VALUES ('T1 gap_and_missing', 'ERROR', SQLERRM);
END;
$$;

-- T2: amb punch IN → missing_now=0; present gap encara si need=2
DO $$
DECLARE
  v_monday date := date '2026-07-13';
  v_as_of timestamptz := (timestamp '2026-07-13 11:20:00' AT TIME ZONE 'Europe/Madrid');
  v_snap jsonb;
BEGIN
  INSERT INTO data.time_punches (
    id, tenant_id, site_id, employee_id, client_op_id, punch_type,
    occurred_at, received_at, source
  ) VALUES (
    'a0650000-0000-0000-0000-000000000041',
    'a0650000-0000-0000-0000-000000000001',
    'b0650000-0000-0000-0000-000000000001',
    'd0650000-0000-0000-0000-000000000001',
    'a0650000-0000-0000-0000-000000000041',
    'in',
    (v_monday + time '10:00') AT TIME ZONE 'Europe/Madrid',
    now(), 'manual_entry'
  ) ON CONFLICT DO NOTHING;

  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_snap := api.get_coverage_operational_snapshot(
    'b0650000-0000-0000-0000-000000000001'::uuid,
    30, 240,
    'e0650000-0000-0000-0000-000000000001'::uuid,
    v_as_of
  );
  SET LOCAL ROLE postgres;

  IF (v_snap->'summary'->>'missing_now_count')::int = 0
     AND (v_snap->'current'->>'present')::int = 1
     AND (v_snap->'current'->>'gap_present')::int = -1
  THEN
    INSERT INTO ex065_results VALUES ('T2 present_after_punch', 'PASS', v_snap->'current'::text);
  ELSE
    INSERT INTO ex065_results VALUES ('T2 present_after_punch', 'FAIL', v_snap::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex065_results VALUES ('T2 present_after_punch', 'ERROR', SQLERRM);
END;
$$;

-- T3: horizon curt no inclou gaps llunyans (demanda acaba 14:00; as_of 11:15 horizon 30 → només fins 11:45)
DO $$
DECLARE
  v_as_of timestamptz := (timestamp '2026-07-13 11:15:00' AT TIME ZONE 'Europe/Madrid');
  v_snap jsonb;
  v_alert jsonb;
  v_has_late boolean := false;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_snap := api.get_coverage_operational_snapshot(
    'b0650000-0000-0000-0000-000000000001'::uuid,
    30, 30,
    'e0650000-0000-0000-0000-000000000001'::uuid,
    v_as_of
  );
  SET LOCAL ROLE postgres;

  FOR v_alert IN SELECT * FROM jsonb_array_elements(v_snap->'alerts')
  LOOP
    IF (v_alert->>'bucket_start_min')::int >= 11 * 60 + 45 THEN
      v_has_late := true;
    END IF;
  END LOOP;

  IF NOT v_has_late AND (v_snap->>'horizon_minutes')::int = 30 THEN
    INSERT INTO ex065_results VALUES ('T3 horizon_filter', 'PASS', (v_snap->'summary')::text);
  ELSE
    INSERT INTO ex065_results VALUES ('T3 horizon_filter', 'FAIL', v_snap::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex065_results VALUES ('T3 horizon_filter', 'ERROR', SQLERRM);
END;
$$;

-- T4: sense permís → error
DO $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0650000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0650000-0000-0000-0000-000000000001","app_metadata":{"user_tenants":{"a0650000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"a0650000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{}}}}}',
    true);
  SET LOCAL ROLE authenticated;
  PERFORM api.get_coverage_operational_snapshot(
    'b0650000-0000-0000-0000-000000000001'::uuid,
    30, 60, NULL, NULL
  );
  SET LOCAL ROLE postgres;
  INSERT INTO ex065_results VALUES ('T4 privilege', 'FAIL', 'expected error');
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  IF SQLERRM ILIKE '%insufficient_privilege%' THEN
    INSERT INTO ex065_results VALUES ('T4 privilege', 'PASS', SQLERRM);
  ELSE
    INSERT INTO ex065_results VALUES ('T4 privilege', 'ERROR', SQLERRM);
  END IF;
END;
$$;

-- T5: dia sense demanda → current_ok / sense open gaps de demanda
DO $$
DECLARE
  v_as_of timestamptz := (timestamp '2026-07-14 11:15:00' AT TIME ZONE 'Europe/Madrid'); -- dimarts
  v_snap jsonb;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;
  v_snap := api.get_coverage_operational_snapshot(
    'b0650000-0000-0000-0000-000000000001'::uuid,
    30, 240, NULL, v_as_of
  );
  SET LOCAL ROLE postgres;

  IF (v_snap->'summary'->>'open_gap_count')::int = 0 THEN
    INSERT INTO ex065_results VALUES ('T5 no_demand_day', 'PASS', (v_snap->'summary')::text);
  ELSE
    INSERT INTO ex065_results VALUES ('T5 no_demand_day', 'FAIL', v_snap::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  SET LOCAL ROLE postgres;
  INSERT INTO ex065_results VALUES ('T5 no_demand_day', 'ERROR', SQLERRM);
END;
$$;

SELECT test_name, status, details FROM ex065_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM ex065_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EX-06.5 tests failed: % row(s)', v_fail;
  END IF;
END;
$$;

ROLLBACK;
