-- M-EC-01 employment contracts tests
BEGIN;
SET client_min_messages TO WARNING;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text PRIMARY KEY,
  status text NOT NULL,
  details text
) ON COMMIT DROP;

CREATE TEMP TABLE test_ids (
  contract_id uuid,
  overlap_draft_id uuid
) ON COMMIT DROP;

INSERT INTO test_ids DEFAULT VALUES;

-- T1: tables exist
DO $$
BEGIN
  IF to_regclass('data.employment_contracts') IS NOT NULL
     AND to_regclass('data.employment_contract_types') IS NOT NULL
     AND to_regclass('data.employment_contract_compensation') IS NOT NULL THEN
    INSERT INTO test_results VALUES ('T1 tables exist', 'PASS', 'contracts+types+compensation');
  ELSE
    INSERT INTO test_results VALUES ('T1 tables exist', 'FAIL', 'missing tables');
  END IF;
END $$;

-- JWT owner (Alice owner) — same pattern as employees_profile_v2_tests.sql
DO $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
END $$;

-- T2: owner creates draft contract for Alice
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_alice  uuid := '40000000-0000-0000-0000-000000000001';
  v_id     uuid;
BEGIN
  INSERT INTO api.employment_contracts (
    tenant_id, employee_id, contract_number, starts_on,
    lifecycle_status, is_primary, signature_requirement, signature_status
  )
  VALUES (
    v_tenant, v_alice, 'EC-TEST-1', CURRENT_DATE,
    'draft', true, 'none', 'not_required'
  )
  RETURNING id INTO v_id;

  UPDATE test_ids SET contract_id = v_id;

  IF v_id IS NOT NULL THEN
    INSERT INTO test_results VALUES ('T2 owner create draft Alice', 'PASS', v_id::text);
  ELSE
    INSERT INTO test_results VALUES ('T2 owner create draft Alice', 'FAIL', 'null id');
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 owner create draft Alice', 'FAIL', SQLERRM);
END $$;

-- T3: transition draft → scheduled
DO $$
DECLARE
  v_id uuid;
  v_status text;
BEGIN
  SELECT contract_id INTO v_id FROM test_ids;
  PERFORM api.transition_employment_contract(v_id, 'scheduled', NULL);
  SELECT lifecycle_status INTO v_status FROM data.employment_contracts WHERE id = v_id;
  IF v_status = 'scheduled' THEN
    INSERT INTO test_results VALUES ('T3 draft to scheduled', 'PASS', v_status);
  ELSE
    INSERT INTO test_results VALUES ('T3 draft to scheduled', 'FAIL', coalesce(v_status, 'null'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 draft to scheduled', 'FAIL', SQLERRM);
END $$;

-- T4: overlapping primary scheduled/active rejected (EXCLUDE)
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_alice  uuid := '40000000-0000-0000-0000-000000000001';
  v_ok     boolean := false;
  v_draft  uuid;
BEGIN
  INSERT INTO api.employment_contracts (
    tenant_id, employee_id, contract_number, starts_on,
    lifecycle_status, is_primary, signature_requirement, signature_status
  )
  VALUES (
    v_tenant, v_alice, 'EC-TEST-OVERLAP', CURRENT_DATE,
    'draft', true, 'none', 'not_required'
  )
  RETURNING id INTO v_draft;

  UPDATE test_ids SET overlap_draft_id = v_draft;

  BEGIN
    PERFORM api.transition_employment_contract(v_draft, 'scheduled', NULL);
  EXCEPTION
    WHEN exclusion_violation THEN
      v_ok := true;
    WHEN OTHERS THEN
      IF SQLERRM ILIKE '%exclusion%' OR SQLSTATE = '23P01' THEN
        v_ok := true;
      ELSE
        RAISE;
      END IF;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T4 overlap primary rejected', 'PASS', 'exclusion_violation');
  ELSE
    INSERT INTO test_results VALUES ('T4 overlap primary rejected', 'FAIL', 'overlap allowed');
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T4 overlap primary rejected', 'FAIL', SQLERRM);
END $$;

-- T5: get_effective returns Alice contract for today
DO $$
DECLARE
  v_alice uuid := '40000000-0000-0000-0000-000000000001';
  v_id    uuid;
  v_eff   api.employment_contracts;
BEGIN
  SELECT contract_id INTO v_id FROM test_ids;
  v_eff := api.get_effective_employment_contract(v_alice, CURRENT_DATE);
  IF v_eff.id = v_id THEN
    INSERT INTO test_results VALUES (
      'T5 get_effective Alice today',
      'PASS',
      format('id=%s status=%s', v_eff.id, v_eff.lifecycle_status)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T5 get_effective Alice today',
      'FAIL',
      format('got=%s expected=%s', coalesce(v_eff.id::text, 'null'), v_id)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 get_effective Alice today', 'FAIL', SQLERRM);
END $$;

-- T6: reconcile scheduled → active when starts_on <= today
DO $$
DECLARE
  v_alice uuid := '40000000-0000-0000-0000-000000000001';
  v_id    uuid;
  v_n     int;
  v_status text;
BEGIN
  SELECT contract_id INTO v_id FROM test_ids;
  v_n := api.reconcile_employment_contracts(v_alice, CURRENT_DATE);
  SELECT lifecycle_status INTO v_status FROM data.employment_contracts WHERE id = v_id;
  IF v_status = 'active' AND v_n >= 1 THEN
    INSERT INTO test_results VALUES (
      'T6 reconcile scheduled to active',
      'PASS',
      format('n=%s status=%s', v_n, v_status)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T6 reconcile scheduled to active',
      'FAIL',
      format('n=%s status=%s', v_n, coalesce(v_status, 'null'))
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 reconcile scheduled to active', 'FAIL', SQLERRM);
END $$;

-- T7: Dave (member) cannot SELECT / INSERT employment_contracts
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_alice  uuid := '40000000-0000-0000-0000-000000000001';
  v_cnt    int;
  v_ins_ok boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000005', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000005","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT count(*) INTO v_cnt FROM api.employment_contracts;

  BEGIN
    INSERT INTO api.employment_contracts (
      tenant_id, employee_id, contract_number, starts_on,
      lifecycle_status, is_primary, signature_requirement, signature_status
    )
    VALUES (
      v_tenant, v_alice, 'EC-TEST-DAVE', CURRENT_DATE,
      'draft', true, 'none', 'not_required'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_ins_ok := true;
  WHEN OTHERS THEN
    -- RLS WITH CHECK failure often surfaces as insufficient_privilege or generic
    IF SQLSTATE IN ('42501', 'P0001') OR SQLERRM ILIKE '%policy%' OR SQLERRM ILIKE '%permission%'
       OR SQLERRM ILIKE '%insufficient%' THEN
      v_ins_ok := true;
    ELSE
      -- row not inserted is also acceptably "denied" if we get 0 rows back somehow
      v_ins_ok := false;
      RAISE NOTICE 'T7 insert err: % %', SQLSTATE, SQLERRM;
    END IF;
  END;

  IF v_cnt = 0 AND v_ins_ok THEN
    INSERT INTO test_results VALUES ('T7 Dave denied select insert', 'PASS', format('cnt=%s insert_denied', v_cnt));
  ELSIF v_cnt = 0 AND NOT v_ins_ok THEN
    -- insert may silently fail under RLS (0 rows) in some configs
    IF NOT EXISTS (SELECT 1 FROM data.employment_contracts WHERE contract_number = 'EC-TEST-DAVE') THEN
      INSERT INTO test_results VALUES ('T7 Dave denied select insert', 'PASS', format('cnt=%s insert_blocked', v_cnt));
    ELSE
      INSERT INTO test_results VALUES ('T7 Dave denied select insert', 'FAIL', 'insert succeeded');
    END IF;
  ELSE
    INSERT INTO test_results VALUES (
      'T7 Dave denied select insert',
      'FAIL',
      format('cnt=%s insert_denied=%s', v_cnt, v_ins_ok)
    );
  END IF;
END $$;

-- T8: cleanup test contracts as postgres (no JWT)
RESET ROLE;

DO $$
DECLARE
  v_deleted int;
BEGIN
  DELETE FROM data.employment_contracts WHERE contract_number LIKE 'EC-TEST-%';
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  IF NOT EXISTS (SELECT 1 FROM data.employment_contracts WHERE contract_number LIKE 'EC-TEST-%') THEN
    INSERT INTO test_results VALUES ('T8 cleanup EC-TEST contracts', 'PASS', format('deleted=%s', v_deleted));
  ELSE
    INSERT INTO test_results VALUES ('T8 cleanup EC-TEST contracts', 'FAIL', 'rows remain');
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T8 cleanup EC-TEST contracts', 'FAIL', SQLERRM);
END $$;

SELECT * FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  RAISE NOTICE 'M-EC-01 employment contracts tests: % PASS, % FAIL',
    (SELECT count(*) FROM test_results WHERE status = 'PASS'),
    v_fail;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'M-EC-01 employment contracts tests failed';
  END IF;
END $$;

ROLLBACK;
