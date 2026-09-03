-- =============================================================================
-- attendance_anomaly_automations_ex082_tests.sql
-- EX-08.2 — Automatitzacions d'anomalies (emit, dedup, quiet hours, scans)
-- =============================================================================

BEGIN;

CREATE TEMP TABLE ex082_results (test_name text, status text, details text) ON COMMIT DROP;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0820000-0000-0000-0000-000000000001', 'EX082 Tenant', 'ex082-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b0820000-0000-0000-0000-000000000001', 'a0820000-0000-0000-0000-000000000001', 'EX082 Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0820000-0000-0000-0000-000000000001', 'emp@ex082.test', 'authenticated', 'authenticated'),
  ('c0820000-0000-0000-0000-000000000002', 'mgr@ex082.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0820000-0000-0000-0000-000000000001', 'emp@ex082.test', 'Emp EX082'),
  ('c0820000-0000-0000-0000-000000000002', 'mgr@ex082.test', 'Mgr EX082')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0820000-0000-0000-0000-000000000001', 'c0820000-0000-0000-0000-000000000001', 'member', true),
  (gen_random_uuid(), 'a0820000-0000-0000-0000-000000000001', 'c0820000-0000-0000-0000-000000000002', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES (
  'd0820000-0000-0000-0000-000000000001',
  'a0820000-0000-0000-0000-000000000001',
  'b0820000-0000-0000-0000-000000000001',
  'c0820000-0000-0000-0000-000000000001',
  'Emp EX082', 'active'
)
ON CONFLICT (id) DO NOTHING;

-- Mid-day as_of to avoid quiet hours in scans that use clock_timestamp for quiet check
-- emit uses clock_timestamp() for quiet hours — tests run whenever; force urgent when needed.

-- T1 emit pause + dedup
DO $$
DECLARE
  v1 jsonb;
  v2 jsonb;
BEGIN
  DELETE FROM data.attendance_anomaly_automation_fired
  WHERE tenant_id = 'a0820000-0000-0000-0000-000000000001';

  v1 := data.emit_attendance_anomaly_automation(
    'a0820000-0000-0000-0000-000000000001'::uuid,
    'b0820000-0000-0000-0000-000000000001'::uuid,
    'PAUSE_NOT_CLOSED',
    'pause:d0820000-0000-0000-0000-000000000001:2026-07-17',
    'd0820000-0000-0000-0000-000000000001'::uuid,
    '2026-07-17'::date,
    jsonb_build_object('test', true),
    true  -- urgent → bypass quiet hours
  );

  v2 := data.emit_attendance_anomaly_automation(
    'a0820000-0000-0000-0000-000000000001'::uuid,
    'b0820000-0000-0000-0000-000000000001'::uuid,
    'PAUSE_NOT_CLOSED',
    'pause:d0820000-0000-0000-0000-000000000001:2026-07-17',
    'd0820000-0000-0000-0000-000000000001'::uuid,
    '2026-07-17'::date,
    jsonb_build_object('test', true),
    true
  );

  IF (v1->>'ok')::boolean = true
     AND (v2->>'ok')::boolean = false
     AND v2->>'reason' = 'already_fired'
  THEN
    INSERT INTO ex082_results VALUES ('T1 emit_dedup', 'PASS', (v1->>'fired_id'));
  ELSE
    INSERT INTO ex082_results VALUES ('T1 emit_dedup', 'FAIL',
      format('v1=%s v2=%s', v1, v2));
  END IF;
END;
$$;

-- T2 disabled via settings
DO $$
DECLARE
  v jsonb;
BEGIN
  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb)
    || '{"attendance_anomaly_automations":{"enabled":false}}'::jsonb
  WHERE id = 'a0820000-0000-0000-0000-000000000001';

  v := data.emit_attendance_anomaly_automation(
    'a0820000-0000-0000-0000-000000000001'::uuid,
    'b0820000-0000-0000-0000-000000000001'::uuid,
    'PUNCH_OUT_MISSING',
    'pout:disabled-test',
    'd0820000-0000-0000-0000-000000000001'::uuid,
    CURRENT_DATE,
    '{}'::jsonb,
    true
  );

  IF (v->>'ok')::boolean = false AND v->>'reason' = 'disabled' THEN
    INSERT INTO ex082_results VALUES ('T2 settings_disabled', 'PASS', v->>'reason');
  ELSE
    INSERT INTO ex082_results VALUES ('T2 settings_disabled', 'FAIL', v::text);
  END IF;

  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb)
    || '{"attendance_anomaly_automations":{"enabled":true,"punch_out_missing":true,"shift_coverage_gap":true,"pause_not_closed":true}}'::jsonb
  WHERE id = 'a0820000-0000-0000-0000-000000000001';
END;
$$;

-- T3 punch_out_missing scan
DO $$
DECLARE
  v_as_of timestamptz;
  v_res jsonb;
  v_ok boolean;
BEGIN
  -- Punch in 11h ago, no out → fallback 10h rule
  INSERT INTO data.time_punches (
    id, tenant_id, site_id, employee_id, punch_type, occurred_at, source, client_op_id
  ) VALUES (
    'e0820000-0000-0000-0000-000000000011',
    'a0820000-0000-0000-0000-000000000001',
    'b0820000-0000-0000-0000-000000000001',
    'd0820000-0000-0000-0000-000000000001',
    'in',
    clock_timestamp() - interval '11 hours',
    'manual_entry',
    'e0820000-0000-0000-0000-0000000000c1'
  )
  ON CONFLICT (id) DO NOTHING;

  v_as_of := clock_timestamp();
  v_res := data.scan_punch_out_missing(v_as_of, 0, true);

  SELECT EXISTS (
    SELECT 1 FROM data.attendance_anomaly_automation_fired f
    WHERE f.tenant_id = 'a0820000-0000-0000-0000-000000000001'
      AND f.trigger_code = 'PUNCH_OUT_MISSING'
      AND f.employee_id = 'd0820000-0000-0000-0000-000000000001'
  ) INTO v_ok;

  IF v_ok THEN
    INSERT INTO ex082_results VALUES ('T3 punch_out_missing_scan', 'PASS', v_res::text);
  ELSE
    INSERT INTO ex082_results VALUES ('T3 punch_out_missing_scan', 'FAIL', v_res::text);
  END IF;
END;
$$;

-- T4 coverage gap from open opening
DO $$
DECLARE
  v_res jsonb;
  v_ok boolean;
  v_date date := (clock_timestamp() AT TIME ZONE 'Europe/Madrid')::date;
BEGIN
  INSERT INTO data.shift_openings (
    id, tenant_id, site_id, opening_date, start_time, end_time,
    places_total, places_filled, status, opens_at, closes_at, title
  ) VALUES (
    'e0820000-0000-0000-0000-0000000000a1',
    'a0820000-0000-0000-0000-000000000001',
    'b0820000-0000-0000-0000-000000000001',
    v_date,
    '09:00', '17:00',
    2, 0, 'open',
    now() - interval '1 hour',
    now() + interval '1 day',
    'EX082 gap'
  )
  ON CONFLICT (id) DO NOTHING;

  v_res := data.scan_shift_coverage_gaps(clock_timestamp(), true);

  SELECT EXISTS (
    SELECT 1 FROM data.attendance_anomaly_automation_fired f
    WHERE f.tenant_id = 'a0820000-0000-0000-0000-000000000001'
      AND f.trigger_code = 'SHIFT_COVERAGE_GAP'
      AND f.entity_key = format('cov:%s:%s', 'b0820000-0000-0000-0000-000000000001', v_date)
  ) INTO v_ok;

  IF v_ok THEN
    INSERT INTO ex082_results VALUES ('T4 coverage_gap_scan', 'PASS', v_res::text);
  ELSE
    INSERT INTO ex082_results VALUES ('T4 coverage_gap_scan', 'FAIL', v_res::text);
  END IF;
END;
$$;

-- T5 catalog + run orchestrator shape
DO $$
DECLARE
  v_run jsonb;
  v_cat int;
BEGIN
  SELECT count(*) INTO v_cat
  FROM data.notification_event_catalog
  WHERE event_code IN (
    'ATTENDANCE_PAUSE_NOT_CLOSED',
    'ATTENDANCE_PUNCH_OUT_MISSING',
    'ATTENDANCE_SHIFT_COVERAGE_GAP',
    'ATTENDANCE_OVERTIME_THRESHOLD'
  );

  v_run := api.run_attendance_anomaly_automations(clock_timestamp(), 'a0820000-0000-0000-0000-000000000001');

  IF v_cat = 4
     AND v_run ? 'pause_not_closed'
     AND v_run ? 'punch_out_missing'
     AND v_run ? 'shift_coverage_gap'
     AND v_run ? 'overtime_note'
  THEN
    INSERT INTO ex082_results VALUES ('T5 catalog_orchestrator', 'PASS',
      format('cat=%s note=%s', v_cat, v_run->>'overtime_note'));
  ELSE
    INSERT INTO ex082_results VALUES ('T5 catalog_orchestrator', 'FAIL',
      format('cat=%s run=%s', v_cat, v_run));
  END IF;
END;
$$;

SELECT test_name, status, details FROM ex082_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM ex082_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EX-08.2 tests failed: %', v_fail;
  END IF;
END;
$$;

ROLLBACK;
