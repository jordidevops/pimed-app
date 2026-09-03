-- =============================================================================
-- CP-ADM tests: resolve TCMS+CP, upsert preserve, sync, platform kill-switch
-- =============================================================================
BEGIN;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

-- T1: resolve restores TCMS employee fields + customer_portal capabilities
DO $$
DECLARE
  v_tid uuid;
  v_ent jsonb;
BEGIN
  SELECT id INTO v_tid FROM data.tenants LIMIT 1;
  v_ent := data.resolve_portal_entitlements(v_tid);

  IF (v_ent ? 'tenant_portal_entitlements')
     AND (v_ent->'employee_portal' ? 'included_granted')
     AND (v_ent->'customer_portal' ? 'can_create_shares')
     AND (v_ent->'customer_portal' ? 'mode_effective')
  THEN
    INSERT INTO test_results VALUES ('T1_resolve_shape', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T1_resolve_shape', 'FAIL', v_ent::text);
  END IF;
END $$;

-- T2: upsert employee-only payload preserves customer_portal in snapshot
DO $$
DECLARE
  v_tid uuid;
  v_before jsonb;
  v_after jsonb;
BEGIN
  SELECT id INTO v_tid FROM data.tenants LIMIT 1;
  SELECT tenant_portal_entitlements->'customer_portal' INTO v_before
  FROM data.tenants WHERE id = v_tid;

  PERFORM api.upsert_tenant_portal_entitlements(
    v_tid,
    jsonb_build_object(
      'employee_portal', jsonb_build_object('included', true, 'cms_tier', 'basic')
    )
  );

  SELECT tenant_portal_entitlements->'customer_portal' INTO v_after
  FROM data.tenants WHERE id = v_tid;

  IF v_after IS NOT NULL AND (v_after ? 'included') THEN
    INSERT INTO test_results VALUES ('T2_upsert_preserves_cp', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES (
      'T2_upsert_preserves_cp', 'FAIL',
      jsonb_build_object('before', v_before, 'after', v_after)::text
    );
  END IF;
END $$;

-- T3: sync keeps customer_portal on snapshot
DO $$
DECLARE
  v_tid uuid;
  v_ent jsonb;
BEGIN
  SELECT id INTO v_tid FROM data.tenants LIMIT 1;
  v_ent := data.sync_portal_entitlements_with_plan(v_tid);

  IF (v_ent->'tenant_portal_entitlements' ? 'customer_portal')
     AND (v_ent->'customer_portal' ? 'effective')
  THEN
    INSERT INTO test_results VALUES ('T3_sync_keeps_cp', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T3_sync_keeps_cp', 'FAIL', v_ent::text);
  END IF;
END $$;

-- T4: platform kill-switch clears effective; restore after
DO $$
DECLARE
  v_tid uuid;
  v_ent jsonb;
BEGIN
  SELECT id INTO v_tid FROM data.tenants LIMIT 1;
  PERFORM data.set_customer_portal_kill_switch('platform', NULL, false, 'cpa_adm_test');
  v_ent := data.resolve_portal_entitlements(v_tid);

  IF COALESCE((v_ent->'customer_portal'->>'effective')::boolean, true) = false
     AND COALESCE((v_ent->'customer_portal'->>'enabled_by_platform')::boolean, true) = false
  THEN
    INSERT INTO test_results VALUES ('T4_platform_kill_switch', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T4_platform_kill_switch', 'FAIL', v_ent->'customer_portal');
  END IF;

  PERFORM data.set_customer_portal_kill_switch('platform', NULL, true, 'cpa_adm_test_restore');
END $$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;
SELECT
  COUNT(*) FILTER (WHERE status = 'PASS') AS passed,
  COUNT(*) FILTER (WHERE status = 'FAIL') AS failed
FROM test_results;

ROLLBACK;
