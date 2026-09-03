-- EC-WFM P0 §6 / §4.6 tests — convenio catalogs + work context snapshots
-- Acme tenant / Alice owner JWT; rolled back.
BEGIN;
SET client_min_messages TO WARNING;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text PRIMARY KEY,
  status text NOT NULL,
  details text
) ON COMMIT DROP;

CREATE TEMP TABLE test_ids (
  agreement_id uuid,
  category_id uuid,
  contract_id uuid,
  summary_id uuid,
  work_date date
) ON COMMIT DROP;

INSERT INTO test_ids DEFAULT VALUES;

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

-- Cleanup leftover contracts from prior failed runs (as postgres)
RESET ROLE;
DO $$
DECLARE
  v_alice uuid := '40000000-0000-0000-0000-000000000001';
BEGIN
  UPDATE data.employment_contracts
  SET lifecycle_status = 'cancelled', cancelled_at = now(),
      cancellation_reason = 'ec-wfm-p0-convenio-cleanup'
  WHERE employee_id = v_alice
    AND contract_number LIKE 'EC-WFM-P0C-%'
    AND lifecycle_status IN ('draft', 'scheduled', 'active', 'ended');

  DELETE FROM data.time_daily_summaries
  WHERE employee_id = v_alice
    AND work_date BETWEEN CURRENT_DATE + 100 AND CURRENT_DATE + 120;
END $$;

SET LOCAL ROLE authenticated;
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

-- T1: create agreement + category
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_agr uuid;
  v_cat uuid;
BEGIN
  INSERT INTO api.collective_agreements (
    tenant_id, code, name, valid_from, is_active
  ) VALUES (
    v_tenant, 'EC-WFM-P0C-CA', 'Convenio Test Hostaleria', CURRENT_DATE - 365, true
  ) RETURNING id INTO v_agr;

  INSERT INTO api.professional_categories (
    tenant_id, collective_agreement_id, code, name,
    professional_group, contribution_group, default_weekly_hours, is_active
  ) VALUES (
    v_tenant, v_agr, 'EC-WFM-P0C-PC', 'Cambrer/a',
    'II', '5', 40, true
  ) RETURNING id INTO v_cat;

  UPDATE test_ids SET agreement_id = v_agr, category_id = v_cat;

  INSERT INTO test_results VALUES (
    'T1 create agreement + category',
    CASE WHEN v_agr IS NOT NULL AND v_cat IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
    format('agr=%s cat=%s', v_agr, v_cat)
  );
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T1 create agreement + category', 'FAIL', SQLERRM);
END $$;

-- T2: attach to draft then activate OK
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_alice  uuid := '40000000-0000-0000-0000-000000000001';
  v_site   uuid := '30000000-0000-0000-0000-000000000001';
  v_agr uuid;
  v_cat uuid;
  v_id  uuid;
  v_ok  boolean := false;
BEGIN
  SELECT agreement_id, category_id INTO v_agr, v_cat FROM test_ids;

  INSERT INTO api.employment_contracts (
    tenant_id, employee_id, contract_number, starts_on, weekly_hours, site_id,
    collective_agreement_id, professional_category_id,
    lifecycle_status, is_primary, signature_requirement, signature_status
  ) VALUES (
    v_tenant, v_alice, 'EC-WFM-P0C-T2', CURRENT_DATE, 40, v_site,
    v_agr, v_cat,
    'draft', true, 'none', 'not_required'
  ) RETURNING id INTO v_id;

  UPDATE test_ids SET contract_id = v_id;
  PERFORM api.transition_employment_contract(v_id, 'active', NULL);

  SELECT collective_agreement_id = v_agr AND professional_category_id = v_cat
  INTO v_ok
  FROM data.employment_contracts WHERE id = v_id AND lifecycle_status = 'active';

  INSERT INTO test_results VALUES (
    'T2 attach to draft/active contract OK',
    CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
    format('contract=%s', v_id)
  );
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 attach to draft/active contract OK', 'FAIL', SQLERRM);
END $$;

-- T3: deactivate OK; hard DELETE referenced raises
DO $$
DECLARE
  v_agr uuid;
  v_raised boolean := false;
BEGIN
  SELECT agreement_id INTO v_agr FROM test_ids;

  UPDATE api.collective_agreements SET is_active = false WHERE id = v_agr;

  BEGIN
    DELETE FROM api.collective_agreements WHERE id = v_agr;
  EXCEPTION
    WHEN foreign_key_violation THEN
      v_raised := true;
    WHEN OTHERS THEN
      IF SQLERRM LIKE '%collective_agreement_in_use%' OR SQLSTATE = '23503' THEN
        v_raised := true;
      ELSE
        RAISE;
      END IF;
  END;

  INSERT INTO test_results VALUES (
    'T3 deactivate OK; hard DELETE referenced raises',
    CASE WHEN v_raised
              AND EXISTS (SELECT 1 FROM data.collective_agreements WHERE id = v_agr AND is_active = false)
         THEN 'PASS' ELSE 'FAIL' END,
    format('raised=%s', v_raised)
  );

  -- restore active for later tests
  UPDATE api.collective_agreements SET is_active = true WHERE id = v_agr;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES (
    'T3 deactivate OK; hard DELETE referenced raises', 'FAIL', SQLERRM
  );
END $$;

-- T4: work_context includes convenio_categoria ids
DO $$
DECLARE
  v_alice uuid := '40000000-0000-0000-0000-000000000001';
  v_agr uuid;
  v_cat uuid;
  v_ctx jsonb;
BEGIN
  SELECT agreement_id, category_id INTO v_agr, v_cat FROM test_ids;
  v_ctx := data.resolve_employee_work_context(v_alice, CURRENT_DATE, NULL);

  INSERT INTO test_results VALUES (
    'T4 work_context includes convenio_categoria ids',
    CASE WHEN v_ctx->'convenio_categoria'->>'collective_agreement_id' = v_agr::text
              AND v_ctx->'convenio_categoria'->>'professional_category_id' = v_cat::text
              AND v_ctx->'convenio_categoria'->>'collective_agreement_code' = 'EC-WFM-P0C-CA'
              AND v_ctx->>'resolver_version' IN ('ec_wfm_p1_v1', 'ec_wfm_p0_v1')
         THEN 'PASS' ELSE 'FAIL' END,
    coalesce((v_ctx->'convenio_categoria')::text, 'null')
  );
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES (
    'T4 work_context includes convenio_categoria ids', 'FAIL', SQLERRM
  );
END $$;

-- T5: INSERT time_daily_summaries captures snapshot + contract id
RESET ROLE;
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_alice  uuid := '40000000-0000-0000-0000-000000000001';
  v_site   uuid := '30000000-0000-0000-0000-000000000001';
  v_cid uuid;
  v_sid uuid;
  v_day date := CURRENT_DATE + 105;
  v_row data.time_daily_summaries%ROWTYPE;
BEGIN
  WHILE EXTRACT(ISODOW FROM v_day) IN (6, 7) LOOP
    v_day := v_day + 1;
  END LOOP;

  SELECT contract_id INTO v_cid FROM test_ids;
  DELETE FROM data.time_daily_summaries WHERE employee_id = v_alice AND work_date = v_day;

  INSERT INTO data.time_daily_summaries (
    tenant_id, site_id, employee_id, work_date, day_type, status
  ) VALUES (
    v_tenant, v_site, v_alice, v_day, 'work', 'draft'
  ) RETURNING id INTO v_sid;

  SELECT * INTO v_row FROM data.time_daily_summaries WHERE id = v_sid;
  UPDATE test_ids SET summary_id = v_sid, work_date = v_day;

  INSERT INTO test_results VALUES (
    'T5 INSERT captures snapshot + contract id',
    CASE WHEN v_row.employment_contract_id = v_cid
              AND v_row.work_context_snapshot ? 'convenio_categoria'
              AND v_row.work_context_snapshot ? 'captured_at'
              AND v_row.resolver_version IN ('ec_wfm_p1_v1', 'ec_wfm_p0_v1')
              AND v_row.work_context_frozen_at IS NULL
         THEN 'PASS' ELSE 'FAIL' END,
    format('cid=%s snap_cid=%s frozen=%s',
      v_cid, v_row.employment_contract_id, v_row.work_context_frozen_at)
  );
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 INSERT captures snapshot + contract id', 'FAIL', SQLERRM);
END $$;

-- T6: after payroll_locked_at, mutating work_context_snapshot raises
DO $$
DECLARE
  v_sid uuid;
  v_raised boolean := false;
BEGIN
  SELECT summary_id INTO v_sid FROM test_ids;

  UPDATE data.time_daily_summaries
  SET payroll_locked_at = now()
  WHERE id = v_sid;

  BEGIN
    UPDATE data.time_daily_summaries
    SET work_context_snapshot = '{}'::jsonb
    WHERE id = v_sid;
  EXCEPTION
    WHEN check_violation THEN
      v_raised := (SQLERRM LIKE '%work_context_immutable%');
    WHEN OTHERS THEN
      v_raised := (SQLERRM LIKE '%work_context_immutable%');
  END;

  INSERT INTO test_results VALUES (
    'T6 locked snapshot immutable',
    CASE WHEN v_raised
              AND EXISTS (
                SELECT 1 FROM data.time_daily_summaries
                WHERE id = v_sid AND work_context_frozen_at IS NOT NULL
              )
         THEN 'PASS' ELSE 'FAIL' END,
    format('raised=%s', v_raised)
  );
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 locked snapshot immutable', 'FAIL', SQLERRM);
END $$;

-- T7: unlocked recompute refreshes snapshot
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_alice  uuid := '40000000-0000-0000-0000-000000000001';
  v_site   uuid := '30000000-0000-0000-0000-000000000001';
  v_day date := CURRENT_DATE + 112;
  v_sid uuid;
  v_before text;
  v_after text;
  v_agr2 uuid;
  v_cat2 uuid;
  v_cid2 uuid;
BEGIN
  WHILE EXTRACT(ISODOW FROM v_day) IN (6, 7) LOOP
    v_day := v_day + 1;
  END LOOP;

  -- Cancel primary so this date starts as fallback, then activate new contract with convenio
  UPDATE data.employment_contracts
  SET lifecycle_status = 'cancelled', cancelled_at = now(),
      cancellation_reason = 'ec-wfm-p0c-t7'
  WHERE employee_id = v_alice
    AND contract_number = 'EC-WFM-P0C-T2'
    AND lifecycle_status = 'active';

  DELETE FROM data.time_daily_summaries WHERE employee_id = v_alice AND work_date = v_day;

  INSERT INTO data.time_daily_summaries (
    tenant_id, site_id, employee_id, work_date, day_type, status
  ) VALUES (
    v_tenant, v_site, v_alice, v_day, 'work', 'draft'
  ) RETURNING id INTO v_sid;

  SELECT work_context_snapshot->'convenio_categoria'->>'collective_agreement_id'
  INTO v_before
  FROM data.time_daily_summaries WHERE id = v_sid;

  INSERT INTO data.collective_agreements (tenant_id, code, name, is_active)
  VALUES (v_tenant, 'EC-WFM-P0C-CA2', 'Convenio T7', true)
  RETURNING id INTO v_agr2;

  INSERT INTO data.professional_categories (
    tenant_id, collective_agreement_id, code, name, is_active
  ) VALUES (v_tenant, v_agr2, 'EC-WFM-P0C-PC2', 'Categoria T7', true)
  RETURNING id INTO v_cat2;

  INSERT INTO data.employment_contracts (
    tenant_id, employee_id, contract_number, starts_on, ends_on, weekly_hours, site_id,
    collective_agreement_id, professional_category_id,
    lifecycle_status, is_primary, signature_requirement, signature_status,
    approval_status, activated_at
  ) VALUES (
    v_tenant, v_alice, 'EC-WFM-P0C-T7', v_day, NULL, 35, v_site,
    v_agr2, v_cat2,
    'active', true, 'none', 'not_required',
    'approved', now()
  ) RETURNING id INTO v_cid2;

  UPDATE data.time_daily_summaries
  SET worked_minutes = 60
  WHERE id = v_sid;

  SELECT work_context_snapshot->'convenio_categoria'->>'collective_agreement_id'
  INTO v_after
  FROM data.time_daily_summaries WHERE id = v_sid;

  INSERT INTO test_results VALUES (
    'T7 unlocked recompute refreshes snapshot',
    CASE WHEN (v_before IS NULL OR v_before = '')
              AND v_after = v_agr2::text
         THEN 'PASS' ELSE 'FAIL' END,
    format('before=%s after=%s agr2=%s', v_before, v_after, v_agr2)
  );

  -- cleanup T7 artifacts (keep txn rollbackable)
  DELETE FROM data.time_daily_summaries WHERE id = v_sid;
  UPDATE data.employment_contracts
  SET lifecycle_status = 'cancelled', cancelled_at = now(),
      cancellation_reason = 'ec-wfm-p0c-t7-done'
  WHERE id = v_cid2;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES (
    'T7 unlocked recompute refreshes snapshot', 'FAIL', SQLERRM
  );
END $$;

SELECT * FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION '% test(s) FAILED', v_fail;
  END IF;
END $$;

ROLLBACK;


