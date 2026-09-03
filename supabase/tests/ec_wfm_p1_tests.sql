-- EC-WFM P1 tests (workload, leave grants, placements)
-- Acme tenant / Alice owner JWT; rolled back.
BEGIN;
SET client_min_messages TO WARNING;

CREATE TEMP TABLE test_results (
  test_name text PRIMARY KEY,
  status text NOT NULL,
  details text
) ON COMMIT DROP;

CREATE TEMP TABLE test_ids (
  emp_id uuid,
  tenant_id uuid,
  site_gracia uuid,
  site_sants uuid,
  draft_contract_id uuid,
  activate_contract_id uuid,
  grant_id uuid,
  placement_id uuid
) ON COMMIT DROP;

INSERT INTO test_ids DEFAULT VALUES;

CREATE OR REPLACE FUNCTION pg_temp.set_alice_jwt()
RETURNS void
LANGUAGE plpgsql
AS $$
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

RESET ROLE;
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_alice  uuid := '40000000-0000-0000-0000-000000000001';
  v_site_g uuid := '30000000-0000-0000-0000-000000000001';
  v_site_s uuid := '30000000-0000-0000-0000-000000000002';
BEGIN
  UPDATE data.employment_contracts
  SET lifecycle_status = 'cancelled', cancelled_at = now(), cancellation_reason = 'ec-wfm-p1-cleanup'
  WHERE employee_id = v_alice AND contract_number LIKE 'EC-WFM-P1-%'
    AND lifecycle_status IN ('draft', 'scheduled', 'active', 'ended');

  DELETE FROM data.employee_placement_periods
  WHERE employee_id = v_alice AND coalesce(reason, '') LIKE 'EC-WFM-P1%';

  UPDATE test_ids SET
    emp_id = v_alice,
    tenant_id = v_tenant,
    site_gracia = v_site_g,
    site_sants = v_site_s;
END $$;

-- ---------------------------------------------------------------------------
-- T1: upsert workload_terms week 2250 min → weekly_hours 37.5 on draft
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_tenant uuid;
  v_alice uuid;
  v_cid uuid;
  v_hours numeric;
  v_ctx jsonb;
BEGIN
  SELECT tenant_id, emp_id INTO v_tenant, v_alice FROM test_ids;

  PERFORM pg_temp.set_alice_jwt();
  SET LOCAL ROLE authenticated;

  INSERT INTO api.employment_contracts (
    tenant_id, employee_id, contract_number, starts_on, weekly_hours,
    lifecycle_status, is_primary, signature_requirement, signature_status
  ) VALUES (
    v_tenant, v_alice, 'EC-WFM-P1-T1', CURRENT_DATE + 120, 20,
    'draft', false, 'none', 'not_required'
  ) RETURNING id INTO v_cid;

  INSERT INTO api.employment_contract_workload_terms (
    tenant_id, contract_id, commitment_basis,
    ordinary_commitment_minutes, complementary_commitment_minutes
  ) VALUES (
    v_tenant, v_cid, 'week', 2250, 0
  );

  RESET ROLE;

  UPDATE test_ids SET draft_contract_id = v_cid;

  SELECT weekly_hours INTO v_hours FROM data.employment_contracts WHERE id = v_cid;
  v_ctx := data.resolve_employee_work_context(v_alice, CURRENT_DATE + 120, NULL);

  IF v_hours = 37.5
     OR (v_ctx->'workload'->>'weekly_hours')::numeric = 37.5 THEN
    INSERT INTO test_results VALUES (
      'T1 workload week projects 37.5',
      'PASS',
      format('contract_hours=%s ctx_hours=%s', v_hours, v_ctx->'workload'->>'weekly_hours')
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T1 workload week projects 37.5',
      'FAIL',
      format('contract_hours=%s ctx=%s', v_hours, v_ctx->'workload')
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO test_results VALUES ('T1 workload week projects 37.5', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- T2: work_context shows workload source workload_terms
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_alice uuid;
  v_cid uuid;
  v_ctx jsonb;
BEGIN
  SELECT emp_id, draft_contract_id INTO v_alice, v_cid FROM test_ids;

  UPDATE data.employment_contracts
  SET is_primary = false
  WHERE employee_id = v_alice
    AND id <> v_cid
    AND lifecycle_status IN ('scheduled', 'active')
    AND is_primary;

  UPDATE data.employment_contracts
  SET lifecycle_status = 'scheduled', is_primary = true
  WHERE id = v_cid;

  v_ctx := data.resolve_employee_work_context(v_alice, CURRENT_DATE + 120, NULL);

  IF v_ctx->'workload'->>'source' = 'workload_terms'
     AND (v_ctx->'workload'->>'ordinary_commitment_minutes')::int = 2250 THEN
    INSERT INTO test_results VALUES (
      'T2 workload source workload_terms',
      'PASS',
      (v_ctx->'workload')::text
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T2 workload source workload_terms',
      'FAIL',
      coalesce(v_ctx::text, 'null')
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 workload source workload_terms', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- T3: leave_terms + activate generates grant; idempotent
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_tenant uuid;
  v_alice uuid;
  v_cid uuid;
  v_id1 uuid;
  v_id2 uuid;
  v_cnt int;
  v_year int := EXTRACT(YEAR FROM CURRENT_DATE)::int;
BEGIN
  SELECT tenant_id, emp_id INTO v_tenant, v_alice FROM test_ids;

  INSERT INTO data.employment_contracts (
    tenant_id, employee_id, contract_number, starts_on, ends_on, weekly_hours,
    lifecycle_status, is_primary, signature_requirement, signature_status
  ) VALUES (
    v_tenant, v_alice, 'EC-WFM-P1-T3',
    make_date(v_year, 1, 1), make_date(v_year, 12, 31), 37.5,
    'draft', false, 'none', 'not_required'
  ) RETURNING id INTO v_cid;

  UPDATE test_ids SET activate_contract_id = v_cid;

  INSERT INTO data.employment_contract_leave_terms (
    tenant_id, contract_id, paid_leave_allowance, allowance_unit,
    counting_method, proration_method
  ) VALUES (
    v_tenant, v_cid, 22, 'days', 'working_days', 'none'
  );

  UPDATE data.employment_contracts
  SET lifecycle_status = 'active', activated_at = now(), is_primary = false
  WHERE id = v_cid;

  v_id1 := data.generate_leave_grant_for_contract_activation(v_cid);
  v_id2 := data.generate_leave_grant_for_contract_activation(v_cid);

  SELECT count(*) INTO v_cnt
  FROM data.leave_entitlement_grants
  WHERE contract_id = v_cid AND source_event = 'contract_activated';

  UPDATE test_ids SET grant_id = coalesce(v_id1, v_id2);

  IF v_cnt = 1 AND v_id1 IS NOT NULL AND v_id1 = v_id2 THEN
    INSERT INTO test_results VALUES (
      'T3 leave grant on activate idempotent',
      'PASS',
      format('grant=%s cnt=%s', v_id1, v_cnt)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T3 leave grant on activate idempotent',
      'FAIL',
      format('id1=%s id2=%s cnt=%s', v_id1, v_id2, v_cnt)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 leave grant on activate idempotent', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- T4: grant UPDATE raises leave_grant_immutable
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_gid uuid;
  v_ok boolean := false;
  v_msg text;
BEGIN
  SELECT grant_id INTO v_gid FROM test_ids;
  IF v_gid IS NULL THEN
    INSERT INTO test_results VALUES ('T4 grant update immutable', 'FAIL', 'no grant_id');
    RETURN;
  END IF;

  BEGIN
    UPDATE data.leave_entitlement_grants SET quantity = 1 WHERE id = v_gid;
  EXCEPTION
    WHEN check_violation THEN
      IF SQLERRM ILIKE '%leave_grant_immutable%' THEN
        v_ok := true;
        v_msg := SQLERRM;
      ELSE
        v_msg := SQLERRM;
      END IF;
    WHEN OTHERS THEN
      IF SQLERRM ILIKE '%leave_grant_immutable%' THEN
        v_ok := true;
        v_msg := SQLERRM;
      ELSE
        v_msg := SQLERRM;
      END IF;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T4 grant update immutable', 'PASS', v_msg);
  ELSE
    INSERT INTO test_results VALUES ('T4 grant update immutable', 'FAIL', coalesce(v_msg, 'no exception'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T4 grant update immutable', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- T5: placement period overrides site in work_context
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_tenant uuid;
  v_alice uuid;
  v_site_s uuid;
  v_pid uuid;
  v_ctx jsonb;
  v_eff_site uuid;
BEGIN
  SELECT tenant_id, emp_id, site_sants
  INTO v_tenant, v_alice, v_site_s
  FROM test_ids;

  INSERT INTO data.employee_placement_periods (
    tenant_id, employee_id, site_id, starts_on, ends_on, source, reason
  ) VALUES (
    v_tenant, v_alice, v_site_s, CURRENT_DATE - 1, CURRENT_DATE + 30,
    'manual', 'EC-WFM-P1-T5'
  ) RETURNING id INTO v_pid;

  UPDATE test_ids SET placement_id = v_pid;

  v_ctx := data.resolve_employee_work_context(v_alice, CURRENT_DATE, NULL);
  v_eff_site := NULLIF(v_ctx->'placement'->>'site_id', '')::uuid;

  IF v_eff_site = v_site_s
     AND v_ctx->'placement'->>'source' = 'placement_period' THEN
    INSERT INTO test_results VALUES (
      'T5 placement overrides site',
      'PASS',
      format('site=%s source=%s', v_eff_site, v_ctx->'placement'->>'source')
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T5 placement overrides site',
      'FAIL',
      coalesce((v_ctx->'placement')::text, 'null')
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 placement overrides site', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- T6: overlapping placement INSERT raises
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_tenant uuid;
  v_alice uuid;
  v_site_g uuid;
  v_ok boolean := false;
  v_msg text;
BEGIN
  SELECT tenant_id, emp_id, site_gracia INTO v_tenant, v_alice, v_site_g FROM test_ids;

  BEGIN
    INSERT INTO data.employee_placement_periods (
      tenant_id, employee_id, site_id, starts_on, ends_on, source, reason
    ) VALUES (
      v_tenant, v_alice, v_site_g, CURRENT_DATE, CURRENT_DATE + 10,
      'manual', 'EC-WFM-P1-T6-overlap'
    );
  EXCEPTION
    WHEN exclusion_violation THEN
      v_ok := true;
      v_msg := SQLERRM;
    WHEN OTHERS THEN
      IF SQLSTATE = '23P01' OR SQLERRM ILIKE '%overlap%' OR SQLERRM ILIKE '%exclude%' THEN
        v_ok := true;
      END IF;
      v_msg := SQLERRM;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T6 overlapping placement rejected', 'PASS', v_msg);
  ELSE
    INSERT INTO test_results VALUES ('T6 overlapping placement rejected', 'FAIL', coalesce(v_msg, 'no exception'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 overlapping placement rejected', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- T7: resolver_version is ec_wfm_p1_v1
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_alice uuid;
  v_ctx jsonb;
BEGIN
  SELECT emp_id INTO v_alice FROM test_ids;
  v_ctx := data.resolve_employee_work_context(v_alice, CURRENT_DATE, NULL);

  IF v_ctx->>'resolver_version' = 'ec_wfm_p1_v1' THEN
    INSERT INTO test_results VALUES ('T7 resolver_version ec_wfm_p1_v1', 'PASS', v_ctx->>'resolver_version');
  ELSE
    INSERT INTO test_results VALUES ('T7 resolver_version ec_wfm_p1_v1', 'FAIL', coalesce(v_ctx->>'resolver_version', 'null'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T7 resolver_version ec_wfm_p1_v1', 'FAIL', SQLERRM);
END $$;

SELECT * FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  RAISE NOTICE 'EC-WFM P1: % PASS, % FAIL',
    (SELECT count(*) FROM test_results WHERE status = 'PASS'),
    v_fail;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EC-WFM P1 tests failed';
  END IF;
END $$;

ROLLBACK;
