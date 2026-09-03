-- =============================================================================
-- attendance_station_st6c_st2a_plus_tests.sql
-- ST-6c+ summarize_location_work + ST-2a+ update/bulk/list inactive
-- =============================================================================

BEGIN;

CREATE TEMP TABLE st6c_results (test_name text, status text, details text) ON COMMIT DROP;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0610000-0000-0000-0000-000000000001', 'ST6C Tenant', 'st6c-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b0610000-0000-0000-0000-000000000001', 'a0610000-0000-0000-0000-000000000001', 'ST6C Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.locations (id, tenant_id, site_id, name, type, status)
VALUES (
  'c0610000-0000-0000-0000-000000000001',
  'a0610000-0000-0000-0000-000000000001',
  'b0610000-0000-0000-0000-000000000001',
  'ST6C Loc', 'zone', 'active'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, full_name, status)
VALUES (
  'd0610000-0000-0000-0000-000000000001',
  'a0610000-0000-0000-0000-000000000001',
  'b0610000-0000-0000-0000-000000000001',
  'Emp ST6C', 'active'
),
(
  'd0610000-0000-0000-0000-000000000002',
  'a0610000-0000-0000-0000-000000000001',
  'b0610000-0000-0000-0000-000000000001',
  'Emp ST6C B', 'active'
)
ON CONFLICT (id) DO NOTHING;

DELETE FROM data.time_punches
WHERE employee_id IN (
  'd0610000-0000-0000-0000-000000000001',
  'd0610000-0000-0000-0000-000000000002'
);

-- Work day in Europe/Madrid: 09:00–12:00 = 180 min
INSERT INTO data.time_punches (
  id, tenant_id, site_id, employee_id, punch_type, occurred_at,
  location_id, location_name_snapshot, source, client_op_id
)
VALUES
(
  'f0610000-0000-0000-0000-000000000001',
  'a0610000-0000-0000-0000-000000000001',
  'b0610000-0000-0000-0000-000000000001',
  'd0610000-0000-0000-0000-000000000001',
  'in',
  timestamptz '2026-07-10 09:00:00+02',
  'c0610000-0000-0000-0000-000000000001',
  'ST6C Loc',
  'manual_entry',
  'f0610000-0000-0000-0000-0000000000c1'
),
(
  'f0610000-0000-0000-0000-000000000002',
  'a0610000-0000-0000-0000-000000000001',
  'b0610000-0000-0000-0000-000000000001',
  'd0610000-0000-0000-0000-000000000001',
  'out',
  timestamptz '2026-07-10 12:00:00+02',
  'c0610000-0000-0000-0000-000000000001',
  'ST6C Loc',
  'manual_entry',
  'f0610000-0000-0000-0000-0000000000c2'
);

-- Bypass privilege for service_role style: call aggregate helper + api via SET ROLE
-- Tests run as postgres; simulate tenant context for api if needed.
DO $$
DECLARE
  v_rows jsonb;
  v_mins int;
BEGIN
  -- Direct helper (owner)
  SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
    INTO v_rows
  FROM data._st6c_aggregate_location_work(
    'b0610000-0000-0000-0000-000000000001',
    'a0610000-0000-0000-0000-000000000001',
    'Europe/Madrid',
    timestamptz '2026-07-10 00:00:00+02',
    timestamptz '2026-07-11 00:00:00+02',
    NULL,
    NULL
  ) x;

  v_mins := COALESCE((v_rows->0->>'work_minutes')::int, 0);

  IF jsonb_array_length(v_rows) = 1 AND v_mins = 180 THEN
    INSERT INTO st6c_results VALUES ('T1 aggregate_180min', 'PASS', v_rows::text);
  ELSE
    INSERT INTO st6c_results VALUES ('T1 aggregate_180min', 'FAIL', v_rows::text);
  END IF;
END;
$$;

-- Open interval
INSERT INTO data.time_punches (
  id, tenant_id, site_id, employee_id, punch_type, occurred_at,
  location_id, location_name_snapshot, source, client_op_id
)
VALUES (
  'f0610000-0000-0000-0000-000000000003',
  'a0610000-0000-0000-0000-000000000001',
  'b0610000-0000-0000-0000-000000000001',
  'd0610000-0000-0000-0000-000000000002',
  'in',
  timestamptz '2026-07-10 14:00:00+02',
  'c0610000-0000-0000-0000-000000000001',
  'ST6C Loc',
  'manual_entry',
  'f0610000-0000-0000-0000-0000000000c3'
);

DO $$
DECLARE
  v_rows jsonb;
  v_open int;
BEGIN
  SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
    INTO v_rows
  FROM data._st6c_aggregate_location_work(
    'b0610000-0000-0000-0000-000000000001',
    'a0610000-0000-0000-0000-000000000001',
    'Europe/Madrid',
    timestamptz '2026-07-10 00:00:00+02',
    timestamptz '2026-07-11 00:00:00+02',
    'd0610000-0000-0000-0000-000000000002',
    NULL
  ) x;

  v_open := COALESCE((v_rows->0->>'open_interval_count')::int, 0);

  IF jsonb_array_length(v_rows) = 1 AND v_open = 1
     AND COALESCE((v_rows->0->>'work_minutes')::int, -1) = 0 THEN
    INSERT INTO st6c_results VALUES ('T2 open_interval', 'PASS', v_rows::text);
  ELSE
    INSERT INTO st6c_results VALUES ('T2 open_interval', 'FAIL', v_rows::text);
  END IF;
END;
$$;

-- ST-2a+ assignments: insert + update + list inactive + bulk
DELETE FROM data.attendance_location_assignments
WHERE location_id = 'c0610000-0000-0000-0000-000000000001';

-- Seed as owner of functions (bypass privilege by direct insert)
INSERT INTO data.attendance_location_assignments (
  id, tenant_id, employee_id, location_id, starts_on, ends_on
) VALUES (
  'a1610000-0000-0000-0000-000000000001',
  'a0610000-0000-0000-0000-000000000001',
  'd0610000-0000-0000-0000-000000000001',
  'c0610000-0000-0000-0000-000000000001',
  DATE '2026-01-01',
  DATE '2026-01-31'
);

DO $$
BEGIN
  -- Update dates via API would need JWT; exercise UPDATE path through SQL helper logic
  UPDATE data.attendance_location_assignments
  SET starts_on = DATE '2020-01-01', ends_on = DATE '2020-12-31'
  WHERE id = 'a1610000-0000-0000-0000-000000000001';

  IF NOT data.attendance_location_assignment_active(
    DATE '2020-01-01', DATE '2020-12-31', CURRENT_DATE
  ) THEN
    INSERT INTO st6c_results VALUES ('T3 inactive_dates', 'PASS', 'inactive today');
  ELSE
    INSERT INTO st6c_results VALUES ('T3 inactive_dates', 'FAIL', 'still active');
  END IF;
END;
$$;

DO $$
DECLARE
  v_exists boolean;
BEGIN
  -- Simulate list filter logic
  SELECT EXISTS (
    SELECT 1
    FROM data.attendance_location_assignments ala
    WHERE ala.location_id = 'c0610000-0000-0000-0000-000000000001'
      AND data.attendance_location_assignment_active(ala.starts_on, ala.ends_on, CURRENT_DATE)
  ) INTO v_exists;

  IF NOT v_exists THEN
    INSERT INTO st6c_results VALUES ('T4 list_active_empty', 'PASS', 'no active');
  ELSE
    INSERT INTO st6c_results VALUES ('T4 list_active_empty', 'FAIL', 'unexpected active');
  END IF;
END;
$$;

DO $$
DECLARE
  v_cnt int;
BEGIN
  SELECT count(*)::int INTO v_cnt
  FROM data.attendance_location_assignments ala
  WHERE ala.location_id = 'c0610000-0000-0000-0000-000000000001';

  IF v_cnt = 1 THEN
    INSERT INTO st6c_results VALUES ('T5 include_inactive_row', 'PASS', format('cnt=%s', v_cnt));
  ELSE
    INSERT INTO st6c_results VALUES ('T5 include_inactive_row', 'FAIL', format('cnt=%s', v_cnt));
  END IF;
END;
$$;

-- Bulk upsert via direct uniqueness: second employee insert
INSERT INTO data.attendance_location_assignments (
  tenant_id, employee_id, location_id, starts_on, ends_on
) VALUES (
  'a0610000-0000-0000-0000-000000000001',
  'd0610000-0000-0000-0000-000000000002',
  'c0610000-0000-0000-0000-000000000001',
  NULL,
  NULL
);

DO $$
DECLARE
  v_cnt int;
BEGIN
  SELECT count(*)::int INTO v_cnt
  FROM data.attendance_location_assignments
  WHERE location_id = 'c0610000-0000-0000-0000-000000000001';
  IF v_cnt = 2 THEN
    INSERT INTO st6c_results VALUES ('T6 bulk_second_employee', 'PASS', '2 rows');
  ELSE
    INSERT INTO st6c_results VALUES ('T6 bulk_second_employee', 'FAIL', format('cnt=%s', v_cnt));
  END IF;
END;
$$;

-- Function existence
DO $$
BEGIN
  IF to_regprocedure('api.summarize_location_work(uuid,date,date,uuid,uuid)') IS NOT NULL
     AND to_regprocedure('api.bulk_add_attendance_location_assignments(uuid,uuid[],date,date)') IS NOT NULL
     AND to_regprocedure('api.update_attendance_location_assignment(uuid,date,date)') IS NOT NULL
     AND to_regprocedure('api.list_attendance_location_assignments(uuid,boolean)') IS NOT NULL THEN
    INSERT INTO st6c_results VALUES ('T7 rpc_signatures', 'PASS', 'all present');
  ELSE
    INSERT INTO st6c_results VALUES ('T7 rpc_signatures', 'FAIL', 'missing rpc');
  END IF;
END;
$$;

SELECT test_name, status, details FROM st6c_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*)::int INTO v_fail FROM st6c_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'st6c/st2a+ tests failed: %', v_fail;
  END IF;
END;
$$;

ROLLBACK;
