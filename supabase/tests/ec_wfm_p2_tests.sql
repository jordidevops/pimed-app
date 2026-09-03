-- EC-WFM P2 tests (baseline plan, hour balance, provenance preflight, planning cost)
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
  draft_contract_id uuid,
  signed_contract_id uuid,
  cost_contract_id uuid,
  snapshot_id uuid,
  balance_before int
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
BEGIN
  UPDATE data.employment_contracts
  SET lifecycle_status = 'cancelled', cancelled_at = now(), cancellation_reason = 'ec-wfm-p2-cleanup'
  WHERE employee_id = v_alice AND contract_number LIKE 'EC-WFM-P2-%'
    AND lifecycle_status IN ('draft', 'scheduled', 'active', 'ended');

  DELETE FROM data.hour_balance_policies WHERE tenant_id = v_tenant
    AND coalesce(metadata->>'test', '') = 'ec-wfm-p2';

  UPDATE test_ids SET
    emp_id = v_alice,
    tenant_id = v_tenant,
    site_gracia = v_site_g;
END $$;

-- ---------------------------------------------------------------------------
-- T1: baseline_plan returns ec_wfm_p2_v1 and excludes absences/shifts
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_alice uuid;
  v_plan jsonb;
BEGIN
  SELECT emp_id INTO v_alice FROM test_ids;
  v_plan := data.resolve_employee_baseline_plan(v_alice, CURRENT_DATE);

  IF v_plan->>'resolver_version' = 'ec_wfm_p2_v1'
     AND (v_plan->'excludes'->>'absences')::boolean IS TRUE
     AND (v_plan->'excludes'->>'shift_slots')::boolean IS TRUE THEN
    INSERT INTO test_results VALUES (
      'T1 baseline_plan version + excludes',
      'PASS',
      format('ver=%s excludes=%s', v_plan->>'resolver_version', v_plan->'excludes')
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T1 baseline_plan version + excludes',
      'FAIL',
      coalesce(v_plan::text, 'null')
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T1 baseline_plan version + excludes', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- T2: baseline expected_minutes >= 0 and day_type present
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_alice uuid;
  v_plan jsonb;
  v_dt text;
  v_min int;
BEGIN
  SELECT emp_id INTO v_alice FROM test_ids;
  v_plan := data.resolve_employee_baseline_plan(v_alice, CURRENT_DATE);
  v_dt := v_plan->>'day_type';
  v_min := coalesce((v_plan->>'expected_minutes')::int, -1);

  IF v_dt IS NOT NULL AND v_dt <> '' AND v_min >= 0 THEN
    INSERT INTO test_results VALUES (
      'T2 baseline day_type + minutes',
      'PASS',
      format('day_type=%s expected_minutes=%s', v_dt, v_min)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T2 baseline day_type + minutes',
      'FAIL',
      coalesce(v_plan::text, 'null')
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 baseline day_type + minutes', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- T3: hour_balance_policies upsert + resolve returns ledger source
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_tenant uuid;
  v_alice uuid;
  v_bal jsonb;
BEGIN
  SELECT tenant_id, emp_id INTO v_tenant, v_alice FROM test_ids;

  PERFORM pg_temp.set_alice_jwt();
  SET LOCAL ROLE authenticated;

  INSERT INTO api.hour_balance_policies (
    tenant_id, window_type, window_length, rounding_rule, carry_enabled, metadata
  ) VALUES (
    v_tenant, 'month', 1, 'nearest', true, '{"test":"ec-wfm-p2"}'::jsonb
  )
  ON CONFLICT (tenant_id) DO UPDATE SET
    window_type = EXCLUDED.window_type,
    window_length = EXCLUDED.window_length,
    rounding_rule = EXCLUDED.rounding_rule,
    carry_enabled = EXCLUDED.carry_enabled,
    metadata = EXCLUDED.metadata;

  RESET ROLE;

  v_bal := data.resolve_employee_hour_balance(v_alice, CURRENT_DATE);

  UPDATE test_ids SET balance_before = coalesce((v_bal->>'balance_minutes')::int, 0);

  IF v_bal->>'ledger_source' = 'time_compensation_ledger'
     AND v_bal->>'resolver_version' = 'ec_wfm_p2_v1'
     AND v_bal->'policy'->>'window_type' = 'month' THEN
    INSERT INTO test_results VALUES (
      'T3 hour_balance policy + ledger source',
      'PASS',
      v_bal::text
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T3 hour_balance policy + ledger source',
      'FAIL',
      coalesce(v_bal::text, 'null')
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO test_results VALUES ('T3 hour_balance policy + ledger source', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- T4: insert ledger credit, balance increases
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_tenant uuid;
  v_alice uuid;
  v_before int;
  v_after int;
  v_bal jsonb;
BEGIN
  SELECT tenant_id, emp_id, balance_before INTO v_tenant, v_alice, v_before FROM test_ids;

  RESET ROLE;
  INSERT INTO data.time_compensation_ledger (
    tenant_id, employee_id, source_work_date, movement_type, source_type,
    minutes, is_credit, notes
  ) VALUES (
    v_tenant, v_alice, CURRENT_DATE, 'accrued', 'manual',
    90, true, 'EC-WFM-P2-T4'
  );

  v_bal := data.resolve_employee_hour_balance(v_alice, CURRENT_DATE);
  v_after := coalesce((v_bal->>'balance_minutes')::int, -999);

  IF v_after = coalesce(v_before, 0) + 90 THEN
    INSERT INTO test_results VALUES (
      'T4 ledger credit increases balance',
      'PASS',
      format('before=%s after=%s', v_before, v_after)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T4 ledger credit increases balance',
      'FAIL',
      format('before=%s after=%s bal=%s', v_before, v_after, v_bal)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T4 ledger credit increases balance', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- T5: preflight blocks overwrite of signed/active contract
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_tenant uuid;
  v_alice uuid;
  v_cid uuid;
  v_pf jsonb;
  v_blocked boolean := false;
BEGIN
  SELECT tenant_id, emp_id INTO v_tenant, v_alice FROM test_ids;

  RESET ROLE;
  INSERT INTO data.employment_contracts (
    tenant_id, employee_id, contract_number, starts_on, weekly_hours,
    lifecycle_status, is_primary, signature_requirement, signature_status,
    fully_signed_at, external_identity, approval_status
  ) VALUES (
    v_tenant, v_alice, 'EC-WFM-P2-T5-SIGNED', CURRENT_DATE - 30, 40,
    'active', false, 'employee_and_employer', 'completed',
    now(), 'ext-ec-wfm-p2-t5', 'approved'
  ) RETURNING id INTO v_cid;

  UPDATE test_ids SET signed_contract_id = v_cid;

  v_pf := data.preflight_external_contract_import(
    v_tenant,
    jsonb_build_object(
      'contract_id', v_cid,
      'external_identity', 'ext-ec-wfm-p2-t5',
      'employee_id', v_alice,
      'starts_on', CURRENT_DATE - 30,
      'weekly_hours', 35
    )
  );

  SELECT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_pf->'blocks') b
    WHERE b->>'code' = 'cannot_overwrite_signed_contract'
  ) INTO v_blocked;

  IF v_pf->>'ok' = 'false' AND v_blocked THEN
    INSERT INTO test_results VALUES (
      'T5 preflight blocks signed overwrite',
      'PASS',
      v_pf::text
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T5 preflight blocks signed overwrite',
      'FAIL',
      coalesce(v_pf::text, 'null')
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 preflight blocks signed overwrite', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- T6: resolve_contract_planning_cost derived/hourly for Alice contract
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_tenant uuid;
  v_alice uuid;
  v_cid uuid;
  v_cost jsonb;
BEGIN
  SELECT tenant_id, emp_id INTO v_tenant, v_alice FROM test_ids;

  RESET ROLE;
  INSERT INTO data.employment_contracts (
    tenant_id, employee_id, contract_number, starts_on, weekly_hours,
    lifecycle_status, is_primary, signature_requirement, signature_status,
    approval_status
  ) VALUES (
    v_tenant, v_alice, 'EC-WFM-P2-T6-COST', CURRENT_DATE + 200, 40,
    'draft', false, 'none', 'not_required', 'pending'
  ) RETURNING id INTO v_cid;

  INSERT INTO data.employment_contract_compensation (
    tenant_id, contract_id, currency, gross_amount, pay_period,
    employer_annual_cost
  ) VALUES (
    v_tenant, v_cid, 'EUR', NULL, 'monthly', 31200.00
  );

  INSERT INTO data.employment_contract_workload_terms (
    tenant_id, contract_id, commitment_basis,
    ordinary_commitment_minutes, complementary_commitment_minutes
  ) VALUES (
    v_tenant, v_cid, 'week', 2400, 0
  );

  UPDATE test_ids SET cost_contract_id = v_cid;

  v_cost := data.resolve_contract_planning_cost(v_cid, CURRENT_DATE);

  IF v_cost->>'formula_version' = 'ec_wfm_p2_cost_v1'
     AND v_cost->>'method' = 'derived_annual_cost'
     AND (v_cost->>'employer_annual_cost')::numeric = 31200
     AND (v_cost->>'annual_ordinary_minutes')::numeric = 2400 * 52 THEN
    INSERT INTO test_results VALUES (
      'T6 planning_cost derived_annual',
      'PASS',
      v_cost::text
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T6 planning_cost derived_annual',
      'FAIL',
      coalesce(v_cost::text, 'null')
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 planning_cost derived_annual', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- T7: api.resolve_contract_planning_cost as owner OK
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_cid uuid;
  v_cost jsonb;
BEGIN
  SELECT cost_contract_id INTO v_cid FROM test_ids;

  PERFORM pg_temp.set_alice_jwt();
  SET LOCAL ROLE authenticated;

  v_cost := api.resolve_contract_planning_cost(v_cid, CURRENT_DATE);

  RESET ROLE;

  IF v_cost->>'method' IN ('derived_annual_cost', 'hourly_rate')
     AND v_cost->>'formula_version' = 'ec_wfm_p2_cost_v1' THEN
    INSERT INTO test_results VALUES (
      'T7 api planning_cost as owner',
      'PASS',
      v_cost->>'method'
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T7 api planning_cost as owner',
      'FAIL',
      coalesce(v_cost::text, 'null')
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO test_results VALUES ('T7 api planning_cost as owner', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- T8: freeze_planning_cost_snapshot creates row
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_cid uuid;
  v_sid uuid;
  v_cnt int;
BEGIN
  SELECT cost_contract_id INTO v_cid FROM test_ids;

  PERFORM pg_temp.set_alice_jwt();
  SET LOCAL ROLE authenticated;

  v_sid := api.freeze_planning_cost_snapshot(v_cid, CURRENT_DATE, 'EC-WFM-P2-T8');

  RESET ROLE;

  UPDATE test_ids SET snapshot_id = v_sid;

  SELECT count(*) INTO v_cnt
  FROM data.planning_cost_snapshots
  WHERE id = v_sid AND contract_id = v_cid AND budget_label = 'EC-WFM-P2-T8';

  IF v_sid IS NOT NULL AND v_cnt = 1 THEN
    INSERT INTO test_results VALUES (
      'T8 freeze_planning_cost_snapshot',
      'PASS',
      v_sid::text
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T8 freeze_planning_cost_snapshot',
      'FAIL',
      format('sid=%s cnt=%s', v_sid, v_cnt)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  INSERT INTO test_results VALUES ('T8 freeze_planning_cost_snapshot', 'FAIL', SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- T9: unique external_identity conflict
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_tenant uuid;
  v_alice uuid;
  v_ok boolean := false;
  v_msg text;
BEGIN
  SELECT tenant_id, emp_id INTO v_tenant, v_alice FROM test_ids;

  RESET ROLE;
  BEGIN
    INSERT INTO data.employment_contracts (
      tenant_id, employee_id, contract_number, starts_on, weekly_hours,
      lifecycle_status, is_primary, signature_requirement, signature_status,
      external_identity, approval_status
    ) VALUES (
      v_tenant, v_alice, 'EC-WFM-P2-T9-DUP', CURRENT_DATE + 300, 20,
      'draft', false, 'none', 'not_required',
      'ext-ec-wfm-p2-t5', 'pending'
    );
  EXCEPTION
    WHEN unique_violation THEN
      v_ok := true;
      v_msg := SQLERRM;
    WHEN OTHERS THEN
      IF SQLSTATE = '23505' THEN
        v_ok := true;
      END IF;
      v_msg := SQLERRM;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T9 unique external_identity', 'PASS', v_msg);
  ELSE
    INSERT INTO test_results VALUES ('T9 unique external_identity', 'FAIL', coalesce(v_msg, 'no exception'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T9 unique external_identity', 'FAIL', SQLERRM);
END $$;

SELECT * FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  RAISE NOTICE 'EC-WFM P2: % PASS, % FAIL',
    (SELECT count(*) FROM test_results WHERE status = 'PASS'),
    v_fail;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EC-WFM P2 tests failed';
  END IF;
END $$;

ROLLBACK;
