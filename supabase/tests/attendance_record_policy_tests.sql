-- attendance_record_policy_tests.sql — Track G Phase 1
-- psql "$DB_URL" -f supabase/tests/attendance_record_policy_tests.sql

BEGIN;

CREATE TEMP TABLE policy_test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

INSERT INTO data.tenants (id, name, slug, is_active)
VALUES ('f1000000-0000-0000-0000-000000000001', 'Policy Test Tenant', 'policy-test', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.sites (id, tenant_id, name, is_active)
VALUES ('f2000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', 'Policy Site', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.calendar_groups (id, tenant_id, site_id, name, color, is_active, sort_order)
VALUES (
  'f3000000-0000-0000-0000-000000000001',
  'f1000000-0000-0000-0000-000000000001',
  NULL,
  'Test Group',
  '#6366f1',
  true,
  0
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.employees (id, tenant_id, site_id, full_name, status, calendar_group_id)
VALUES (
  'f4000000-0000-0000-0000-000000000001',
  'f1000000-0000-0000-0000-000000000001',
  'f2000000-0000-0000-0000-000000000001',
  'Policy Test Employee',
  'active',
  'f3000000-0000-0000-0000-000000000001'
)
ON CONFLICT (id) DO NOTHING;

-- T1: default when no rows
DO $$
DECLARE
  v jsonb;
BEGIN
  DELETE FROM data.attendance_record_policies
  WHERE tenant_id = 'f1000000-0000-0000-0000-000000000001';

  v := data.resolve_attendance_record_policy(
    'f4000000-0000-0000-0000-000000000001',
    CURRENT_DATE
  );

  INSERT INTO policy_test_results VALUES (
    'T1_default_no_policy',
    CASE
      WHEN v->>'resolved_from' = 'system_default'
       AND (v->'policy'->>'version')::int = 2
       AND v->>'work_profile' = 'fixed_site'
      THEN 'PASS' ELSE 'FAIL'
    END,
    v::text
  );
END;
$$;

-- T2: tenant overrides default
DO $$
DECLARE
  v jsonb;
BEGIN
  INSERT INTO data.attendance_record_policies (
    tenant_id, scope, effective_from, policy
  ) VALUES (
    'f1000000-0000-0000-0000-000000000001',
    'tenant',
    '2020-01-01',
    jsonb_set(
      data.default_attendance_record_policy('fixed_site'),
      '{courtesy,early_arrival_minutes}',
      '30'::jsonb
    )
  );

  v := data.resolve_attendance_record_policy(
    'f4000000-0000-0000-0000-000000000001',
    CURRENT_DATE
  );

  INSERT INTO policy_test_results VALUES (
    'T2_tenant_override',
    CASE
      WHEN v->>'resolved_from' = 'tenant'
       AND (v->'policy'->'courtesy'->>'early_arrival_minutes')::int = 30
      THEN 'PASS' ELSE 'FAIL'
    END,
    v->>'resolved_from' || ' early=' || (v->'policy'->'courtesy'->>'early_arrival_minutes')
  );
END;
$$;

-- T3: group overrides tenant
DO $$
DECLARE
  v jsonb;
BEGIN
  INSERT INTO data.attendance_record_policies (
    tenant_id, scope, calendar_group_id, effective_from, policy
  ) VALUES (
    'f1000000-0000-0000-0000-000000000001',
    'group',
    'f3000000-0000-0000-0000-000000000001',
    '2020-01-01',
    data.default_attendance_record_policy('mobile_peripatetic')
  );

  v := data.resolve_attendance_record_policy(
    'f4000000-0000-0000-0000-000000000001',
    CURRENT_DATE
  );

  INSERT INTO policy_test_results VALUES (
    'T3_group_override',
    CASE
      WHEN v->>'resolved_from' = 'group'
       AND v->'policy'->>'work_profile' = 'mobile_peripatetic'
      THEN 'PASS' ELSE 'FAIL'
    END,
    v->>'resolved_from' || ' profile=' || (v->'policy'->>'work_profile')
  );
END;
$$;

-- T4: group_site overrides group
DO $$
DECLARE
  v jsonb;
BEGIN
  INSERT INTO data.attendance_record_policies (
    tenant_id, scope, calendar_group_id, site_id, effective_from, policy
  ) VALUES (
    'f1000000-0000-0000-0000-000000000001',
    'group_site',
    'f3000000-0000-0000-0000-000000000001',
    'f2000000-0000-0000-0000-000000000001',
    '2020-01-01',
    jsonb_set(
      data.default_attendance_record_policy('fixed_site'),
      '{daily_work_budget_minutes}',
      '600'::jsonb
    )
  );

  v := data.resolve_attendance_record_policy(
    'f4000000-0000-0000-0000-000000000001',
    CURRENT_DATE
  );

  INSERT INTO policy_test_results VALUES (
    'T4_group_site_override',
    CASE
      WHEN v->>'resolved_from' = 'group_site'
       AND (v->'policy'->>'daily_work_budget_minutes')::int = 600
      THEN 'PASS' ELSE 'FAIL'
    END,
    v->>'resolved_from'
  );
END;
$$;

-- T5: employee override
DO $$
DECLARE
  v jsonb;
BEGIN
  INSERT INTO data.attendance_record_policies (
    tenant_id, scope, employee_id, effective_from, policy
  ) VALUES (
    'f1000000-0000-0000-0000-000000000001',
    'employee',
    'f4000000-0000-0000-0000-000000000001',
    '2020-01-01',
    jsonb_set(
      data.default_attendance_record_policy('fixed_site'),
      '{overtime,requires_prior_authorization}',
      'false'::jsonb
    )
  );

  v := data.resolve_attendance_record_policy(
    'f4000000-0000-0000-0000-000000000001',
    CURRENT_DATE
  );

  INSERT INTO policy_test_results VALUES (
    'T5_employee_override',
    CASE
      WHEN v->>'resolved_from' = 'employee' THEN 'PASS' ELSE 'FAIL'
    END,
    v->>'resolved_from'
  );
END;
$$;

-- T6: effective_to excludes policy
DO $$
DECLARE
  v jsonb;
BEGIN
  UPDATE data.attendance_record_policies
  SET effective_to = CURRENT_DATE - 1
  WHERE scope = 'employee'
    AND employee_id = 'f4000000-0000-0000-0000-000000000001';

  v := data.resolve_attendance_record_policy(
    'f4000000-0000-0000-0000-000000000001',
    CURRENT_DATE
  );

  INSERT INTO policy_test_results VALUES (
    'T6_effective_to_expired',
    CASE
      WHEN v->>'resolved_from' = 'group_site' THEN 'PASS' ELSE 'FAIL'
    END,
    'resolved=' || (v->>'resolved_from')
  );
END;
$$;

-- T7: employee attendance_work_profile overrides policy work_profile
DO $$
DECLARE
  v jsonb;
BEGIN
  UPDATE data.employees
  SET attendance_work_profile = 'delivery'
  WHERE id = 'f4000000-0000-0000-0000-000000000001';

  v := data.resolve_attendance_record_policy(
    'f4000000-0000-0000-0000-000000000001',
    CURRENT_DATE
  );

  INSERT INTO policy_test_results VALUES (
    'T7_employee_work_profile',
    CASE WHEN v->>'work_profile' = 'delivery' THEN 'PASS' ELSE 'FAIL' END,
    'work_profile=' || (v->>'work_profile')
  );
END;
$$;

-- T8: RLS enabled
DO $$
DECLARE
  v_enabled boolean;
BEGIN
  SELECT c.relrowsecurity INTO v_enabled
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'data' AND c.relname = 'attendance_record_policies';

  INSERT INTO policy_test_results VALUES (
    'T8_rls_enabled',
    CASE WHEN v_enabled IS TRUE THEN 'PASS' ELSE 'FAIL' END,
    'rls=' || COALESCE(v_enabled::text, 'null')
  );
END;
$$;

DO $$
DECLARE
  r record;
  v_fail int := 0;
BEGIN
  FOR r IN SELECT * FROM policy_test_results ORDER BY test_name LOOP
    RAISE NOTICE '[%] % — %', r.status, r.test_name, r.details;
    IF r.status <> 'PASS' THEN v_fail := v_fail + 1; END IF;
  END LOOP;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'Policy tests failed: %', v_fail;
  END IF;
END;
$$;

ROLLBACK;
