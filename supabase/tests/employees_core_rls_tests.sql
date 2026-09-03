-- =============================================================================
-- Employees Core RLS Tests (EHR-0)
-- =============================================================================
-- Cobertura:
--   T1  api.employees té security_invoker = true
--   T2  api.employees no exposa document_id
--   T3  Site-only manager (Charlie) veu empleats del seu site, no d'altres
--   T4  Member global pot veure empleats del tenant (compatibilitat)
--   T5  Alias hr.manage permet INSERT via permís granular JWT
--   T6  Member sense permís privat no veu employee_hr_profiles
-- =============================================================================

BEGIN;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

-- ─── T1: security_invoker ────────────────────────────────────────────────────
DO $$
DECLARE
  v_invoker text;
BEGIN
  SELECT CASE WHEN c.reloptions @> ARRAY['security_invoker=true'] THEN 'true' ELSE 'false' END
  INTO v_invoker
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'api' AND c.relname = 'employees';

  IF v_invoker = 'true' THEN
    INSERT INTO test_results VALUES (
      'T1 api.employees security_invoker',
      'PASS',
      'security_invoker=true'
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T1 api.employees security_invoker',
      'FAIL',
      format('Expected security_invoker=true, got %s', v_invoker)
    );
  END IF;
END $$;

-- ─── T2: document_id absent de api.employees ─────────────────────────────────
DO $$
DECLARE
  v_has_doc boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'api'
      AND table_name = 'employees'
      AND column_name = 'document_id'
  ) INTO v_has_doc;

  IF NOT v_has_doc THEN
    INSERT INTO test_results VALUES (
      'T2 api.employees hides document_id',
      'PASS',
      'document_id column absent'
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T2 api.employees hides document_id',
      'FAIL',
      'document_id still exposed on api.employees'
    );
  END IF;
END $$;

-- ─── T3: Site-only manager isolation ─────────────────────────────────────────
DO $$
DECLARE
  v_gracia_count integer;
  v_sants_count  integer;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000004', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000004","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":null,"sites":{"30000000-0000-0000-0000-000000000001":"manager"}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT count(*) INTO v_gracia_count
  FROM api.employees
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'::uuid
    AND site_id   = '30000000-0000-0000-0000-000000000001'::uuid;

  SELECT count(*) INTO v_sants_count
  FROM api.employees
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'::uuid
    AND site_id   = '30000000-0000-0000-0000-000000000002'::uuid;

  IF v_gracia_count >= 1 AND v_sants_count = 0 THEN
    INSERT INTO test_results VALUES (
      'T3 site-only manager sees own site only',
      'PASS',
      format('gracia=%s, sants=%s', v_gracia_count, v_sants_count)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T3 site-only manager sees own site only',
      'FAIL',
      format('Expected gracia>=1,sants=0; got gracia=%s,sants=%s', v_gracia_count, v_sants_count)
    );
  END IF;
END $$;

-- ─── T4: Global member can view employees ────────────────────────────────────
DO $$
DECLARE
  v_count integer;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000005', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000005","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT count(*) INTO v_count
  FROM api.employees
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'::uuid;

  IF v_count >= 1 THEN
    INSERT INTO test_results VALUES (
      'T4 global member can view employees',
      'PASS',
      format('count=%s', v_count)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T4 global member can view employees',
      'FAIL',
      format('Expected count>=1, got %s', v_count)
    );
  END IF;
END $$;

-- ─── T5: hr.manage alias allows insert ───────────────────────────────────────
DO $$
DECLARE
  v_new_id uuid := '40000000-0000-0000-0000-00000000e001';
  v_inserted integer := 0;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000099', true);
  PERFORM set_config(
    'request.jwt.claim',
    format(
      '{"sub":"20000000-0000-0000-0000-000000000099","app_metadata":{"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["hr.manage"],"sites":{}}},"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
      '{}'
    ),
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  INSERT INTO api.employees (
    id, tenant_id, site_id, full_name, status
  ) VALUES (
    v_new_id,
    '10000000-0000-0000-0000-000000000001'::uuid,
    '30000000-0000-0000-0000-000000000001'::uuid,
    'EHR Test Insert',
    'active'
  )
  ON CONFLICT (id) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 1 OR EXISTS (SELECT 1 FROM api.employees WHERE id = v_new_id) THEN
    INSERT INTO test_results VALUES (
      'T5 hr.manage alias allows insert',
      'PASS',
      'insert succeeded via hr.manage alias'
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T5 hr.manage alias allows insert',
      'FAIL',
      'insert denied for hr.manage alias'
    );
  END IF;
END $$;

-- ─── T6: Member without private.view cannot read other hr_profiles ───────────
DO $$
DECLARE
  v_count integer;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000005', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000005","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT count(*) INTO v_count
  FROM api.employee_hr_profiles p
  JOIN data.employees e ON e.id = p.id
  WHERE e.user_id IS DISTINCT FROM auth.uid();

  IF v_count = 0 THEN
    INSERT INTO test_results VALUES (
      'T6 member cannot read other employee_hr_profiles',
      'PASS',
      'zero non-self rows visible'
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T6 member cannot read other employee_hr_profiles',
      'FAIL',
      format('Expected 0 non-self rows, got %s', v_count)
    );
  END IF;
END $$;

-- ─── Summary ─────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_pass integer;
  v_fail integer;
BEGIN
  SELECT count(*) FILTER (WHERE status = 'PASS'),
         count(*) FILTER (WHERE status = 'FAIL')
  INTO v_pass, v_fail
  FROM test_results;

  RAISE NOTICE 'Employees core RLS tests: % PASS, % FAIL', v_pass, v_fail;
END $$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail integer;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'Employees core RLS tests failed: % failure(s)', v_fail;
  END IF;
END $$;

ROLLBACK;
