-- =============================================================================
-- attendance_planning_heuristics_ex083_tests.sql
-- EX-08.3 — Heurístiques fatiga / equitat / gap (AP-09)
-- =============================================================================

BEGIN;

CREATE TEMP TABLE ex083_results (test_name text, status text, details text) ON COMMIT DROP;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0830000-0000-0000-0000-000000000001', 'EX083 Tenant', 'ex083-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b0830000-0000-0000-0000-000000000001', 'a0830000-0000-0000-0000-000000000001', 'EX083 Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES ('c0830000-0000-0000-0000-000000000002', 'mgr@ex083.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES ('c0830000-0000-0000-0000-000000000002', 'mgr@ex083.test', 'Mgr EX083')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES (gen_random_uuid(), 'a0830000-0000-0000-0000-000000000001', 'c0830000-0000-0000-0000-000000000002', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status)
VALUES
  ('d0830000-0000-0000-0000-000000000001', 'a0830000-0000-0000-0000-000000000001',
   'b0830000-0000-0000-0000-000000000001', NULL, 'Emp A EX083', 'active'),
  ('d0830000-0000-0000-0000-000000000002', 'a0830000-0000-0000-0000-000000000001',
   'b0830000-0000-0000-0000-000000000001', NULL, 'Emp B EX083', 'active')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.work_shifts (id, tenant_id, site_id, name, color, start_time, end_time, is_active)
VALUES (
  'f0830000-0000-0000-0000-000000000001',
  'a0830000-0000-0000-0000-000000000001',
  'b0830000-0000-0000-0000-000000000001',
  'EX083', '#3b82f6', '09:00', '17:00', true
)
ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION pg_temp.set_mgr_ctx() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0830000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0830000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0830000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0830000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","labor_calendar.view","attendance.view_all"],"sites":{}}}}}',
    true);
END;
$$;

-- Fixed as_of Monday 2026-07-13 for reproducible DOW
-- T1 fatigue consecutive days (5 days ending 2026-07-13)
DO $$
DECLARE
  v_as_of date := '2026-07-13';
  v_d date;
  v_h jsonb;
  v_found boolean;
BEGIN
  FOR v_d IN SELECT generate_series('2026-07-09'::date, '2026-07-13'::date, '1 day')::date LOOP
    INSERT INTO data.shift_slots (
      tenant_id, site_id, employee_id, shift_id, slot_date, status,
      start_time, end_time, created_by
    ) VALUES (
      'a0830000-0000-0000-0000-000000000001',
      'b0830000-0000-0000-0000-000000000001',
      'd0830000-0000-0000-0000-000000000001',
      'f0830000-0000-0000-0000-000000000001',
      v_d, 'draft', '09:00', '17:00',
      'c0830000-0000-0000-0000-000000000002'
    );
  END LOOP;

  v_h := data.compute_site_planning_heuristics(
    'b0830000-0000-0000-0000-000000000001'::uuid, v_as_of, 28
  );

  SELECT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_h->'fatigue_alerts') f
    WHERE f->>'employee_id' = 'd0830000-0000-0000-0000-000000000001'
      AND (f->>'code') IN ('NEAR_MAX_CONSECUTIVE_DAYS', 'MAX_CONSECUTIVE_WORK_DAYS')
      AND (f->>'actual_days')::int >= 5
      AND f ? 'explanation'
  ) INTO v_found;

  IF (v_h->>'ok')::boolean AND v_found AND (v_h->>'disclaimer') ILIKE '%AP-09%' THEN
    INSERT INTO ex083_results VALUES ('T1 fatigue_consecutive', 'PASS',
      (SELECT f->>'explanation' FROM jsonb_array_elements(v_h->'fatigue_alerts') f LIMIT 1));
  ELSE
    INSERT INTO ex083_results VALUES ('T1 fatigue_consecutive', 'FAIL', v_h::text);
  END IF;
END;
$$;

-- T2 equity imbalance (A many hours, B few)
DO $$
DECLARE
  v_h jsonb;
  v_a numeric;
  v_b numeric;
BEGIN
  INSERT INTO data.shift_slots (
    tenant_id, site_id, employee_id, shift_id, slot_date, status,
    start_time, end_time, created_by
  ) VALUES (
    'a0830000-0000-0000-0000-000000000001',
    'b0830000-0000-0000-0000-000000000001',
    'd0830000-0000-0000-0000-000000000002',
    'f0830000-0000-0000-0000-000000000001',
    '2026-07-12', 'draft', '09:00', '13:00',
    'c0830000-0000-0000-0000-000000000002'
  );

  v_h := data.compute_site_planning_heuristics(
    'b0830000-0000-0000-0000-000000000001'::uuid, '2026-07-13'::date, 28
  );

  SELECT (e->>'hours')::numeric INTO v_a
  FROM jsonb_array_elements(v_h->'equity_snapshot'->'employees') e
  WHERE e->>'employee_id' = 'd0830000-0000-0000-0000-000000000001';

  SELECT (e->>'hours')::numeric INTO v_b
  FROM jsonb_array_elements(v_h->'equity_snapshot'->'employees') e
  WHERE e->>'employee_id' = 'd0830000-0000-0000-0000-000000000002';

  IF v_a > v_b
     AND EXISTS (
       SELECT 1 FROM jsonb_array_elements(v_h->'equity_snapshot'->'employees') e
       WHERE e ? 'explanation' AND e ? 'delta_vs_avg_hours'
     )
  THEN
    INSERT INTO ex083_results VALUES ('T2 equity_snapshot', 'PASS',
      format('A=%s B=%s avg=%s', v_a, v_b, v_h->'equity_snapshot'->>'site_avg_hours'));
  ELSE
    INSERT INTO ex083_results VALUES ('T2 equity_snapshot', 'FAIL', v_h::text);
  END IF;
END;
$$;

-- T3 gap risk tomorrow (demand > planned)
DO $$
DECLARE
  v_h jsonb;
  v_gap jsonb;
  v_as_of date := '2026-07-13'; -- Mon → tomorrow Tue DOW=2
BEGIN
  INSERT INTO data.coverage_demands (
    tenant_id, site_id, kind, day_of_week, start_time, end_time,
    required_min, required_target, priority, source, effective_from, is_active
  ) VALUES (
    'a0830000-0000-0000-0000-000000000001',
    'b0830000-0000-0000-0000-000000000001',
    'recurring', 2, '09:00', '17:00',
    1, 3, 100, 'manual', '2026-01-01', true
  );

  v_h := data.compute_site_planning_heuristics(
    'b0830000-0000-0000-0000-000000000001'::uuid, v_as_of, 28
  );
  v_gap := v_h->'gap_risk_tomorrow';

  IF (v_gap->>'date')::date = '2026-07-14'
     AND (v_gap->>'required_target_sum')::int >= 3
     AND (v_gap->>'gap')::int >= 1
     AND v_gap->>'risk_level' IN ('medium', 'high')
     AND jsonb_array_length(v_gap->'reinforce_suggestions') >= 1
  THEN
    INSERT INTO ex083_results VALUES ('T3 gap_risk_tomorrow', 'PASS', v_gap->>'explanation');
  ELSE
    INSERT INTO ex083_results VALUES ('T3 gap_risk_tomorrow', 'FAIL', v_gap::text);
  END IF;
END;
$$;

-- T4 absence pattern by DOW
DO $$
DECLARE
  v_h jsonb;
BEGIN
  INSERT INTO data.employee_absences (
    tenant_id, site_id, employee_id, absence_type, start_date, end_date, status
  ) VALUES (
    'a0830000-0000-0000-0000-000000000001',
    'b0830000-0000-0000-0000-000000000001',
    'd0830000-0000-0000-0000-000000000002',
    'vacation', '2026-07-06', '2026-07-06', 'approved'
  );

  v_h := data.compute_site_planning_heuristics(
    'b0830000-0000-0000-0000-000000000001'::uuid, '2026-07-13'::date, 28
  );

  IF jsonb_array_length(COALESCE(v_h->'absence_patterns', '[]'::jsonb)) >= 1
     AND EXISTS (
       SELECT 1 FROM jsonb_array_elements(v_h->'absence_patterns') a
       WHERE (a->>'absence_count')::int >= 1 AND a ? 'explanation'
     )
  THEN
    INSERT INTO ex083_results VALUES ('T4 absence_patterns', 'PASS',
      (v_h->'absence_patterns')::text);
  ELSE
    INSERT INTO ex083_results VALUES ('T4 absence_patterns', 'FAIL', v_h::text);
  END IF;
END;
$$;

-- T5 API permission wrapper
DO $$
DECLARE
  v jsonb;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;

  v := api.get_site_planning_heuristics(
    'b0830000-0000-0000-0000-000000000001'::uuid,
    '2026-07-13'::date,
    28
  );

  RESET ROLE;

  IF (v->>'ok')::boolean
     AND v ? 'fatigue_alerts'
     AND v ? 'equity_snapshot'
     AND v ? 'gap_risk_tomorrow'
     AND v ? 'disclaimer'
  THEN
    INSERT INTO ex083_results VALUES ('T5 api_wrapper', 'PASS', 'ok');
  ELSE
    INSERT INTO ex083_results VALUES ('T5 api_wrapper', 'FAIL', v::text);
  END IF;
END;
$$;

SELECT test_name, status, details FROM ex083_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM ex083_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EX-08.3 tests failed: %', v_fail;
  END IF;
END;
$$;

ROLLBACK;
