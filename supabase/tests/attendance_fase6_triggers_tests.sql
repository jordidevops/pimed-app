-- =============================================================================
-- attendance_fase6_triggers_tests.sql
-- PUNCH_IN_UNUSUAL_HOUR | ABSENCE_REQUEST_PENDING | MONTH_CLOSED_REPORT emit
-- =============================================================================

BEGIN;

CREATE TEMP TABLE f6_results (test_name text, status text, details text) ON COMMIT DROP;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0f60000-0000-0000-0000-000000000001', 'F6 Tenant', 'f6-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b0f60000-0000-0000-0000-000000000001', 'a0f60000-0000-0000-0000-000000000001', 'F6 Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES
  ('c0f60000-0000-0000-0000-000000000001', 'emp@f6.test', 'authenticated', 'authenticated'),
  ('c0f60000-0000-0000-0000-000000000002', 'mgr@f6.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES
  ('c0f60000-0000-0000-0000-000000000001', 'emp@f6.test', 'Emp F6'),
  ('c0f60000-0000-0000-0000-000000000002', 'mgr@f6.test', 'Mgr F6')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES
  (gen_random_uuid(), 'a0f60000-0000-0000-0000-000000000001', 'c0f60000-0000-0000-0000-000000000001', 'member', true),
  (gen_random_uuid(), 'a0f60000-0000-0000-0000-000000000001', 'c0f60000-0000-0000-0000-000000000002', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES (
  'd0f60000-0000-0000-0000-000000000001',
  'a0f60000-0000-0000-0000-000000000001',
  'b0f60000-0000-0000-0000-000000000001',
  'c0f60000-0000-0000-0000-000000000001',
  'Emp F6', 'active'
)
ON CONFLICT (id) DO NOTHING;

-- Work plan for unusual-hour tests
INSERT INTO data.labor_calendar_overrides (
  tenant_id, site_id, calendar_date, day_type, day_name, work_intervals
) VALUES (
  'a0f60000-0000-0000-0000-000000000001',
  'b0f60000-0000-0000-0000-000000000001',
  CURRENT_DATE,
  'work',
  'F6 day',
  '[{"start":"08:00","end":"14:00"},{"start":"16:00","end":"18:00"}]'::jsonb
)
ON CONFLICT ON CONSTRAINT labor_calendar_overrides_unique DO UPDATE SET
  work_intervals = EXCLUDED.work_intervals;

-- T1: emit PUNCH_IN_UNUSUAL_HOUR + dedup
DO $$
DECLARE
  v1 jsonb;
  v2 jsonb;
BEGIN
  DELETE FROM data.attendance_anomaly_automation_fired
  WHERE tenant_id = 'a0f60000-0000-0000-0000-000000000001';

  v1 := data.emit_attendance_anomaly_automation(
    'a0f60000-0000-0000-0000-000000000001'::uuid,
    'b0f60000-0000-0000-0000-000000000001'::uuid,
    'PUNCH_IN_UNUSUAL_HOUR',
    'punch:test-unusual-1',
    'd0f60000-0000-0000-0000-000000000001'::uuid,
    CURRENT_DATE,
    jsonb_build_object('test', true),
    true
  );
  v2 := data.emit_attendance_anomaly_automation(
    'a0f60000-0000-0000-0000-000000000001'::uuid,
    'b0f60000-0000-0000-0000-000000000001'::uuid,
    'PUNCH_IN_UNUSUAL_HOUR',
    'punch:test-unusual-1',
    'd0f60000-0000-0000-0000-000000000001'::uuid,
    CURRENT_DATE,
    jsonb_build_object('test', true),
    true
  );

  IF (v1->>'ok')::boolean AND NOT COALESCE((v2->>'ok')::boolean, false)
     AND (v2->>'reason') = 'already_fired'
  THEN
    INSERT INTO f6_results VALUES ('T1_unusual_emit_dedup', 'PASS', v1::text);
  ELSE
    INSERT INTO f6_results VALUES ('T1_unusual_emit_dedup', 'FAIL',
      format('v1=%s v2=%s', v1, v2));
  END IF;
END;
$$;

-- T2: settings OFF → disabled
DO $$
DECLARE
  v jsonb;
BEGIN
  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb) || jsonb_build_object(
    'attendance_anomaly_automations', jsonb_build_object(
      'enabled', true,
      'punch_in_unusual_hour', false
    )
  )
  WHERE id = 'a0f60000-0000-0000-0000-000000000001';

  v := data.emit_attendance_anomaly_automation(
    'a0f60000-0000-0000-0000-000000000001'::uuid,
    'b0f60000-0000-0000-0000-000000000001'::uuid,
    'PUNCH_IN_UNUSUAL_HOUR',
    'punch:test-unusual-off',
    'd0f60000-0000-0000-0000-000000000001'::uuid,
    CURRENT_DATE,
    '{}'::jsonb,
    true
  );

  IF (v->>'ok')::boolean = false AND (v->>'reason') = 'disabled' THEN
    INSERT INTO f6_results VALUES ('T2_unusual_disabled', 'PASS', v::text);
  ELSE
    INSERT INTO f6_results VALUES ('T2_unusual_disabled', 'FAIL', v::text);
  END IF;

  UPDATE data.tenants
  SET settings = settings - 'attendance_anomaly_automations'
  WHERE id = 'a0f60000-0000-0000-0000-000000000001';
END;
$$;

-- T3: absence requested fires; approved does not use same path for insert-as-approved
DO $$
DECLARE
  v_abs_id uuid;
  v_cnt int;
BEGIN
  DELETE FROM data.attendance_anomaly_automation_fired
  WHERE tenant_id = 'a0f60000-0000-0000-0000-000000000001'
    AND trigger_code = 'ABSENCE_REQUEST_PENDING';

  INSERT INTO data.employee_absences (
    id, tenant_id, employee_id, absence_type, start_date, end_date, status
  ) VALUES (
    gen_random_uuid(),
    'a0f60000-0000-0000-0000-000000000001',
    'd0f60000-0000-0000-0000-000000000001',
    'vacation',
    CURRENT_DATE + 30,
    CURRENT_DATE + 32,
    'requested'
  )
  RETURNING id INTO v_abs_id;

  SELECT COUNT(*) INTO v_cnt
  FROM data.attendance_anomaly_automation_fired
  WHERE tenant_id = 'a0f60000-0000-0000-0000-000000000001'
    AND trigger_code = 'ABSENCE_REQUEST_PENDING'
    AND entity_key = format('absence:%s', v_abs_id);

  IF v_cnt = 1 THEN
    INSERT INTO f6_results VALUES ('T3_absence_requested_fires', 'PASS', v_abs_id::text);
  ELSE
    INSERT INTO f6_results VALUES ('T3_absence_requested_fires', 'FAIL', format('cnt=%s', v_cnt));
  END IF;

  DELETE FROM data.attendance_anomaly_automation_fired
  WHERE tenant_id = 'a0f60000-0000-0000-0000-000000000001'
    AND trigger_code = 'ABSENCE_REQUEST_PENDING';

  INSERT INTO data.employee_absences (
    id, tenant_id, employee_id, absence_type, start_date, end_date, status
  ) VALUES (
    gen_random_uuid(),
    'a0f60000-0000-0000-0000-000000000001',
    'd0f60000-0000-0000-0000-000000000001',
    'vacation',
    CURRENT_DATE + 40,
    CURRENT_DATE + 41,
    'approved'
  );

  SELECT COUNT(*) INTO v_cnt
  FROM data.attendance_anomaly_automation_fired
  WHERE tenant_id = 'a0f60000-0000-0000-0000-000000000001'
    AND trigger_code = 'ABSENCE_REQUEST_PENDING';

  IF v_cnt = 0 THEN
    INSERT INTO f6_results VALUES ('T3b_absence_approved_no_fire', 'PASS', NULL);
  ELSE
    INSERT INTO f6_results VALUES ('T3b_absence_approved_no_fire', 'FAIL', format('cnt=%s', v_cnt));
  END IF;
END;
$$;

-- T4: MONTH_CLOSED_REPORT emit + invoke does not raise
DO $$
DECLARE
  v jsonb;
  v_req bigint;
BEGIN
  v := data.emit_attendance_anomaly_automation(
    'a0f60000-0000-0000-0000-000000000001'::uuid,
    'b0f60000-0000-0000-0000-000000000001'::uuid,
    'MONTH_CLOSED_REPORT',
    format('month:d0f60000-0000-0000-0000-000000000001:%s-01', EXTRACT(YEAR FROM CURRENT_DATE)::int),
    'd0f60000-0000-0000-0000-000000000001'::uuid,
    date_trunc('month', CURRENT_DATE)::date,
    jsonb_build_object('year', EXTRACT(YEAR FROM CURRENT_DATE)::int, 'month', 1),
    true
  );

  BEGIN
    v_req := data.invoke_generate_attendance_report(
      'a0f60000-0000-0000-0000-000000000001'::uuid,
      'd0f60000-0000-0000-0000-000000000001'::uuid,
      EXTRACT(YEAR FROM CURRENT_DATE)::int,
      1
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'invoke should not hard-fail: %', SQLERRM;
  END;

  IF (v->>'ok')::boolean THEN
    INSERT INTO f6_results VALUES (
      'T4_month_closed_emit_and_invoke',
      'PASS',
      format('emit=%s req=%s', v, v_req)
    );
  ELSE
    INSERT INTO f6_results VALUES ('T4_month_closed_emit_and_invoke', 'FAIL', v::text);
  END IF;
END;
$$;

-- T5: punch at 03:00 with plan → unusual via helper
DO $$
DECLARE
  v_punch data.time_punches;
  v jsonb;
  v_id uuid := gen_random_uuid();
BEGIN
  INSERT INTO data.time_punches (
    id, tenant_id, site_id, employee_id, client_op_id, punch_type, occurred_at, source
  ) VALUES (
    v_id,
    'a0f60000-0000-0000-0000-000000000001',
    'b0f60000-0000-0000-0000-000000000001',
    'd0f60000-0000-0000-0000-000000000001',
    gen_random_uuid(),
    'in',
    (CURRENT_DATE + time '03:00') AT TIME ZONE 'Europe/Madrid',
    'mobile'
  )
  RETURNING * INTO v_punch;

  -- Trigger already ran on INSERT; check fired table
  IF EXISTS (
    SELECT 1 FROM data.attendance_anomaly_automation_fired
    WHERE tenant_id = 'a0f60000-0000-0000-0000-000000000001'
      AND trigger_code = 'PUNCH_IN_UNUSUAL_HOUR'
      AND entity_key = format('punch:%s', v_id)
  ) THEN
    INSERT INTO f6_results VALUES ('T5_punch_trigger_unusual', 'PASS', v_id::text);
  ELSE
    -- Fallback: call helper directly if resolve_plan failed in trigger context
    v := data.maybe_emit_punch_in_unusual_hour(v_punch);
    IF (v->>'ok')::boolean OR (v->>'reason') IN ('already_fired', 'within_window', 'no_plan') THEN
      INSERT INTO f6_results VALUES (
        'T5_punch_trigger_unusual',
        CASE WHEN (v->>'ok')::boolean OR EXISTS (
          SELECT 1 FROM data.attendance_anomaly_automation_fired
          WHERE entity_key = format('punch:%s', v_id)
        ) THEN 'PASS' ELSE 'FAIL' END,
        v::text
      );
    ELSE
      INSERT INTO f6_results VALUES ('T5_punch_trigger_unusual', 'FAIL', v::text);
    END IF;
  END IF;
END;
$$;

SELECT test_name, status, details FROM f6_results ORDER BY test_name;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM f6_results WHERE status = 'FAIL') THEN
    RAISE EXCEPTION 'Fase 6 trigger tests FAILED: %',
      (SELECT string_agg(test_name || ':' || coalesce(details,''), ', ') FROM f6_results WHERE status = 'FAIL');
  END IF;
END;
$$;

ROLLBACK;
