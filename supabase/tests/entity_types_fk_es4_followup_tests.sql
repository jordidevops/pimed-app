-- =============================================================================
-- ES-4 follow-up — entity_types FK / capability tests
-- =============================================================================

BEGIN;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

GRANT ALL ON TABLE test_results TO authenticated;

CREATE OR REPLACE FUNCTION pg_temp.set_owner_jwt() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
END;
$$;

-- T1: CHECKs dropped, FKs present
DO $$
DECLARE
  v_checks int;
  v_fks int;
BEGIN
  SELECT count(*) INTO v_checks
  FROM pg_constraint
  WHERE conname IN (
    'entity_subscriptions_entity_type_check',
    'entity_comment_templates_entity_type_check',
    'tenant_role_defaults_entity_type_check'
  );

  SELECT count(*) INTO v_fks
  FROM pg_constraint
  WHERE conname IN (
    'entity_subscriptions_entity_type_fkey',
    'entity_comment_templates_entity_type_fkey',
    'tenant_role_defaults_entity_type_fkey',
    'documents_entity_type_fkey',
    'entity_comments_entity_type_fkey'
  );

  IF v_checks = 0 AND v_fks >= 5 THEN
    INSERT INTO test_results VALUES ('T1 checks dropped fks present', 'PASS',
      format('checks=%s fks=%s', v_checks, v_fks));
  ELSE
    INSERT INTO test_results VALUES ('T1 checks dropped fks present', 'FAIL',
      format('checks=%s fks=%s', v_checks, v_fks));
  END IF;
END $$;

-- T2: signing accepts employment_contract
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_id uuid;
BEGIN
  INSERT INTO data.tenant_role_defaults (tenant_id, entity_type, role_key, entity_label)
  VALUES (v_tenant, 'employment_contract', 'ehr83_worker', 'EHR83 Worker')
  RETURNING id INTO v_id;

  IF v_id IS NOT NULL THEN
    INSERT INTO test_results VALUES ('T2 signing employment_contract', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T2 signing employment_contract', 'FAIL', 'no id');
  END IF;

  DELETE FROM data.tenant_role_defaults WHERE id = v_id;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 signing employment_contract', 'FAIL', SQLERRM);
END $$;

-- T3: signing rejects project (supports_signing=false)
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_ok boolean := false;
BEGIN
  BEGIN
    INSERT INTO data.tenant_role_defaults (tenant_id, entity_type, role_key, entity_label)
    VALUES (v_tenant, 'project', 'ehr83_bad', 'Bad');
  EXCEPTION
    WHEN check_violation THEN
      v_ok := true;
    WHEN OTHERS THEN
      IF SQLERRM LIKE '%capability%' OR SQLERRM LIKE '%entity_type%' THEN
        v_ok := true;
      END IF;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T3 signing rejects project', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T3 signing rejects project', 'FAIL', 'expected capability deny');
  END IF;

  DELETE FROM data.tenant_role_defaults
  WHERE tenant_id = v_tenant AND role_key = 'ehr83_bad';
END $$;

-- T4: subscriptions reject employment_contract (no supports_subscriptions)
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_user uuid := '20000000-0000-0000-0000-000000000002';
  v_ok boolean := false;
BEGIN
  BEGIN
    INSERT INTO data.entity_subscriptions (user_id, tenant_id, entity_type, entity_id)
    VALUES (v_user, v_tenant, 'employment_contract', gen_random_uuid());
  EXCEPTION
    WHEN check_violation THEN
      v_ok := true;
    WHEN OTHERS THEN
      IF SQLERRM LIKE '%capability%' OR SQLERRM LIKE '%entity_type%' THEN
        v_ok := true;
      END IF;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T4 sub rejects employment_contract', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T4 sub rejects employment_contract', 'FAIL', 'expected deny');
  END IF;
END $$;

-- T5: subscriptions accept employee
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_user uuid := '20000000-0000-0000-0000-000000000002';
  v_emp uuid;
BEGIN
  SELECT id INTO v_emp
  FROM data.employees
  WHERE tenant_id = v_tenant
  LIMIT 1;

  INSERT INTO data.entity_subscriptions (user_id, tenant_id, entity_type, entity_id)
  VALUES (v_user, v_tenant, 'employee', v_emp)
  ON CONFLICT DO NOTHING;

  INSERT INTO test_results VALUES ('T5 sub accepts employee', 'PASS', NULL);

  DELETE FROM data.entity_subscriptions
  WHERE user_id = v_user AND entity_type = 'employee' AND entity_id = v_emp;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 sub accepts employee', 'FAIL', SQLERRM);
END $$;

-- T6: documents FK accepts employee_certification
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_ok boolean;
BEGIN
  -- Only validate FK path via a probe: unknown code fails
  BEGIN
    PERFORM data.assert_entity_type_capability('employee_certification', 'documents');
    PERFORM data.assert_entity_type_capability('employee_certification', 'signing');
    v_ok := true;
  EXCEPTION WHEN OTHERS THEN
    v_ok := false;
  END;

  IF v_ok AND data.entity_type_supports('employee_certification', 'documents') THEN
    INSERT INTO test_results VALUES ('T6 cert docs+signing flags', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T6 cert docs+signing flags', 'FAIL', NULL);
  END IF;
END $$;

-- T7: unknown code rejected by FK helper
DO $$
DECLARE
  v_ok boolean := false;
BEGIN
  BEGIN
    PERFORM data.assert_entity_type_registered('not_a_real_type_xyz');
  EXCEPTION WHEN OTHERS THEN
    v_ok := true;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T7 unknown code rejected', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T7 unknown code rejected', 'FAIL', NULL);
  END IF;
END $$;

-- T8: set_entity_subscription uses registry (invalid type)
SET LOCAL ROLE authenticated;
SELECT pg_temp.set_owner_jwt();

DO $$
DECLARE
  v_ok boolean := false;
BEGIN
  BEGIN
    PERFORM api.set_entity_subscription('employment_contract', gen_random_uuid(), true);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%invalid_entity_type%' OR SQLSTATE = '22023' THEN
      v_ok := true;
    END IF;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T8 rpc rejects non-sub type', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T8 rpc rejects non-sub type', 'FAIL', 'expected invalid_entity_type');
  END IF;
END $$;

RESET ROLE;

-- Cleanup any leftovers
DELETE FROM data.tenant_role_defaults WHERE role_key LIKE 'ehr83_%';

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'entity_types FK tests failed: %', v_fail;
  END IF;
END $$;

ROLLBACK;
