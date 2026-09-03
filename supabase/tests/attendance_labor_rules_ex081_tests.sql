-- =============================================================================
-- attendance_labor_rules_ex081_tests.sql
-- EX-08.1 — Motor de regles laborals (defaults, upsert, evaluate, eligibility)
-- =============================================================================

BEGIN;

CREATE TEMP TABLE ex081_results (test_name text, status text, details text) ON COMMIT DROP;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('a0810000-0000-0000-0000-000000000001', 'EX081 Tenant', 'ex081-tenant', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('b0810000-0000-0000-0000-000000000001', 'a0810000-0000-0000-0000-000000000001', 'EX081 Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, role, aud)
VALUES ('c0810000-0000-0000-0000-000000000002', 'mgr@ex081.test', 'authenticated', 'authenticated')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.profiles (id, email, full_name)
VALUES ('c0810000-0000-0000-0000-000000000002', 'mgr@ex081.test', 'Mgr EX081')
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.tenant_members (id, tenant_id, user_id, role, is_active)
VALUES (gen_random_uuid(), 'a0810000-0000-0000-0000-000000000001', 'c0810000-0000-0000-0000-000000000002', 'manager', true)
ON CONFLICT DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, user_id, full_name, status, weekly_hours)
VALUES (
  'd0810000-0000-0000-0000-000000000001',
  'a0810000-0000-0000-0000-000000000001',
  'b0810000-0000-0000-0000-000000000001',
  NULL, 'Emp EX081', 'active', 40
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.work_shifts (
  id, tenant_id, site_id, name, color, start_time, end_time, is_active
)
VALUES (
  'f0810000-0000-0000-0000-000000000001',
  'a0810000-0000-0000-0000-000000000001',
  'b0810000-0000-0000-0000-000000000001',
  'EX081 Shift', '#3b82f6', '08:00', '16:00', true
)
ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION pg_temp.set_mgr_ctx() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers',
    '{"x-tenant-id":"a0810000-0000-0000-0000-000000000001"}', true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"c0810000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"a0810000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{}}},"user_permissions":{"a0810000-0000-0000-0000-000000000001":{"global_permissions":["labor_calendar.manage","labor_calendar.view","attendance.view_all"],"sites":{}}}}}',
    true);
END;
$$;

-- T1 product defaults
DO $$
DECLARE
  v_val numeric;
  v_sev text;
  v_src text;
BEGIN
  SELECT value_numeric, severity, source
  INTO v_val, v_sev, v_src
  FROM data.resolve_labor_rule(
    'a0810000-0000-0000-0000-000000000001'::uuid,
    'b0810000-0000-0000-0000-000000000001'::uuid,
    'min_rest_between_shifts_hours'
  );

  IF v_val = 11 AND v_sev = 'warn_require_reason' AND v_src = 'product_default' THEN
    INSERT INTO ex081_results VALUES ('T1 product_defaults', 'PASS', v_src);
  ELSE
    INSERT INTO ex081_results VALUES ('T1 product_defaults', 'FAIL',
      format('val=%s sev=%s src=%s', v_val, v_sev, v_src));
  END IF;
END;
$$;

-- T2 tenant upsert overrides default
DO $$
DECLARE
  v_row jsonb;
  v_val numeric;
  v_src text;
BEGIN
  PERFORM pg_temp.set_mgr_ctx();
  SET LOCAL ROLE authenticated;

  -- P3 protective: tenant min must beat product default (11) without exception
  v_row := api.upsert_labor_rule(
    'min_rest_between_shifts_hours',
    12::numeric,
    'block',
    NULL,
    true
  );

  RESET ROLE;

  SELECT value_numeric, source
  INTO v_val, v_src
  FROM data.resolve_labor_rule(
    'a0810000-0000-0000-0000-000000000001'::uuid,
    'b0810000-0000-0000-0000-000000000001'::uuid,
    'min_rest_between_shifts_hours'
  );

  IF v_val = 12 AND v_src = 'tenant' AND (v_row->>'severity') = 'block' THEN
    INSERT INTO ex081_results VALUES ('T2 upsert_override', 'PASS', v_src);
  ELSE
    INSERT INTO ex081_results VALUES ('T2 upsert_override', 'FAIL',
      format('val=%s src=%s row=%s', v_val, v_src, v_row));
  END IF;
END;
$$;

-- T3 min rest violation
DO $$
DECLARE
  v_eval jsonb;
  v_codes text;
BEGIN
  -- Previous day late shift ending 22:00; next day early 06:00 → 8h rest < 12h block
  INSERT INTO data.shift_slots (
    id, tenant_id, site_id, employee_id, shift_id, slot_date, status,
    start_time, end_time, created_by
  ) VALUES (
    'e0810000-0000-0000-0000-000000000001',
    'a0810000-0000-0000-0000-000000000001',
    'b0810000-0000-0000-0000-000000000001',
    'd0810000-0000-0000-0000-000000000001',
    'f0810000-0000-0000-0000-000000000001',
    '2026-10-05', 'draft', '14:00', '22:00',
    'c0810000-0000-0000-0000-000000000002'
  )
  ON CONFLICT (id) DO NOTHING;

  v_eval := data.evaluate_labor_rules_for_window(
    'd0810000-0000-0000-0000-000000000001'::uuid,
    'b0810000-0000-0000-0000-000000000001'::uuid,
    '2026-10-06'::date,
    '06:00'::time,
    '14:00'::time,
    NULL
  );

  SELECT string_agg(i->>'code', ',')
  INTO v_codes
  FROM jsonb_array_elements(v_eval->'issues') i;

  IF v_codes LIKE '%MIN_REST_BETWEEN_SHIFTS%'
     AND EXISTS (
       SELECT 1 FROM jsonb_array_elements(v_eval->'issues') i
       WHERE i->>'code' = 'MIN_REST_BETWEEN_SHIFTS' AND i->>'severity' = 'block'
     )
  THEN
    INSERT INTO ex081_results VALUES ('T3 min_rest_violation', 'PASS', v_codes);
  ELSE
    INSERT INTO ex081_results VALUES ('T3 min_rest_violation', 'FAIL',
      coalesce(v_eval::text, 'null'));
  END IF;
END;
$$;

-- T4 max daily hours
DO $$
DECLARE
  v_eval jsonb;
BEGIN
  UPDATE data.labor_rules
  SET value_numeric = 10, severity = 'warn_require_reason', is_active = true
  WHERE tenant_id = 'a0810000-0000-0000-0000-000000000001'
    AND site_id IS NULL
    AND rule_key = 'max_daily_hours';

  IF NOT FOUND THEN
    INSERT INTO data.labor_rules (tenant_id, site_id, rule_key, value_numeric, severity, is_active)
    VALUES (
      'a0810000-0000-0000-0000-000000000001', NULL,
      'max_daily_hours', 10, 'warn_require_reason', true
    );
  END IF;

  INSERT INTO data.shift_slots (
    id, tenant_id, site_id, employee_id, shift_id, slot_date, status,
    start_time, end_time, created_by
  ) VALUES (
    'e0810000-0000-0000-0000-000000000002',
    'a0810000-0000-0000-0000-000000000001',
    'b0810000-0000-0000-0000-000000000001',
    'd0810000-0000-0000-0000-000000000001',
    'f0810000-0000-0000-0000-000000000001',
    '2026-10-12', 'draft', '08:00', '14:00',
    'c0810000-0000-0000-0000-000000000002'
  )
  ON CONFLICT (id) DO NOTHING;

  -- Candidate adds 8h → total 14h > 10
  v_eval := data.evaluate_labor_rules_for_window(
    'd0810000-0000-0000-0000-000000000001'::uuid,
    'b0810000-0000-0000-0000-000000000001'::uuid,
    '2026-10-12'::date,
    '15:00'::time,
    '23:00'::time,
    NULL
  );

  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_eval->'issues') i
    WHERE i->>'code' = 'MAX_DAILY_HOURS'
  ) THEN
    INSERT INTO ex081_results VALUES ('T4 max_daily_hours', 'PASS', v_eval->>'ok');
  ELSE
    INSERT INTO ex081_results VALUES ('T4 max_daily_hours', 'FAIL', v_eval::text);
  END IF;
END;
$$;

-- T5 eligibility includes labor warning/block
DO $$
DECLARE
  v_opening_id uuid := 'e0810000-0000-0000-0000-0000000000a1';
  v_elig jsonb;
BEGIN
  INSERT INTO data.shift_openings (
    id, tenant_id, site_id, opening_date, start_time, end_time,
    places_total, places_filled, status, opens_at, closes_at, created_by
  ) VALUES (
    v_opening_id,
    'a0810000-0000-0000-0000-000000000001',
    'b0810000-0000-0000-0000-000000000001',
    '2026-10-06',
    '06:00', '14:00',
    1, 0, 'open',
    now() - interval '1 hour',
    now() + interval '2 days',
    'c0810000-0000-0000-0000-000000000002'
  )
  ON CONFLICT (id) DO NOTHING;

  v_elig := data.evaluate_opening_claim_eligibility(
    v_opening_id,
    'd0810000-0000-0000-0000-000000000001'::uuid
  );

  IF (v_elig->>'ok')::boolean = false
     AND EXISTS (
       SELECT 1
       FROM jsonb_array_elements_text(COALESCE(v_elig->'blocks', '[]'::jsonb)) b
       WHERE b = 'MIN_REST_BETWEEN_SHIFTS'
     )
  THEN
    INSERT INTO ex081_results VALUES ('T5 eligibility_labor_block', 'PASS', (v_elig->'blocks')::text);
  ELSE
    INSERT INTO ex081_results VALUES ('T5 eligibility_labor_block', 'FAIL', v_elig::text);
  END IF;
END;
$$;

SELECT test_name, status, details FROM ex081_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM ex081_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EX-08.1 tests failed: %', v_fail;
  END IF;
END;
$$;

ROLLBACK;

