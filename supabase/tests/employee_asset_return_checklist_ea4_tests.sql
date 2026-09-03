-- M-EA-04 employee asset return checklist (offboarding) tests
BEGIN;
SET client_min_messages TO WARNING;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text PRIMARY KEY,
  status text NOT NULL,
  details text
) ON COMMIT DROP;

CREATE TEMP TABLE test_ids (
  employee_id uuid,
  asset_id uuid,
  assignment_id uuid,
  checklist_id uuid,
  item_id uuid
) ON COMMIT DROP;

INSERT INTO test_ids DEFAULT VALUES;

RESET ROLE;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_site uuid := '30000000-0000-0000-0000-000000000001';
  v_emp uuid;
  v_asset uuid;
BEGIN
  DELETE FROM data.employee_asset_return_checklist_items
  WHERE assignment_id IN (
    SELECT id FROM data.employee_asset_assignments
    WHERE asset_id IN (SELECT id FROM data.assets WHERE asset_tag LIKE 'EA4-%')
  );
  DELETE FROM data.employee_asset_return_checklists
  WHERE employee_id IN (
    SELECT id FROM data.employees WHERE tenant_id = v_tenant AND full_name = 'EA4 Offboard Emp'
  );
  DELETE FROM data.employee_asset_assignments
  WHERE asset_id IN (SELECT id FROM data.assets WHERE asset_tag LIKE 'EA4-%');
  DELETE FROM data.assets WHERE tenant_id = v_tenant AND asset_tag LIKE 'EA4-%';
  DELETE FROM data.employee_lifecycle_events
  WHERE employee_id IN (
    SELECT id FROM data.employees WHERE tenant_id = v_tenant AND full_name = 'EA4 Offboard Emp'
  );
  DELETE FROM data.employees WHERE tenant_id = v_tenant AND full_name = 'EA4 Offboard Emp';

  INSERT INTO data.employees (
    tenant_id, full_name, status, weekly_hours, site_id, lifecycle_state
  ) VALUES (
    v_tenant, 'EA4 Offboard Emp', 'active', 40, v_site, 'active'
  )
  RETURNING id INTO v_emp;

  -- Bypass lifecycle guard for seed state
  PERFORM set_config('data.lifecycle_state_write', '1', true);
  UPDATE data.employees SET lifecycle_state = 'active' WHERE id = v_emp;

  INSERT INTO data.assets (tenant_id, site_id, name, asset_tag, status)
  VALUES (v_tenant, v_site, 'EA4 Laptop', 'EA4-A', 'operational')
  RETURNING id INTO v_asset;

  UPDATE test_ids SET employee_id = v_emp, asset_id = v_asset;
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

-- T1: assign asset, move to departure then offboarding → checklist with item
DO $$
DECLARE
  v_emp uuid;
  v_asset uuid;
  v_asn api.employee_asset_assignments;
  v_cl data.employee_asset_return_checklists;
  v_items int;
BEGIN
  SELECT employee_id, asset_id INTO v_emp, v_asset FROM test_ids;
  v_asn := api.assign_employee_asset(v_asset, v_emp);
  UPDATE test_ids SET assignment_id = v_asn.id;

  PERFORM api.transition_employee_lifecycle(v_emp, 'departure', 'resignation', CURRENT_DATE, '{}'::jsonb);
  PERFORM api.transition_employee_lifecycle(v_emp, 'offboarding', 'offboarding_started', CURRENT_DATE, '{}'::jsonb);

  SELECT * INTO v_cl
  FROM data.employee_asset_return_checklists
  WHERE employee_id = v_emp AND status = 'open'
  ORDER BY created_at DESC LIMIT 1;

  SELECT count(*) INTO v_items
  FROM data.employee_asset_return_checklist_items
  WHERE checklist_id = v_cl.id AND status = 'pending';

  IF v_cl.id IS NOT NULL AND v_items = 1 THEN
    UPDATE test_ids SET checklist_id = v_cl.id;
    UPDATE test_ids SET item_id = (
      SELECT id FROM data.employee_asset_return_checklist_items
      WHERE checklist_id = v_cl.id LIMIT 1
    );
    INSERT INTO test_results VALUES (
      'T1 offboarding creates checklist', 'PASS',
      format('cl=%s items=%s', v_cl.id, v_items)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T1 offboarding creates checklist', 'FAIL',
      format('cl=%s items=%s', v_cl.id, v_items)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T1 offboarding creates checklist', 'FAIL', SQLERRM);
END $$;

-- T2: get RPC returns pending item
DO $$
DECLARE
  v_emp uuid;
  v_rep jsonb;
BEGIN
  SELECT employee_id INTO v_emp FROM test_ids;
  v_rep := api.get_employee_asset_return_checklist(v_emp, true);

  IF (v_rep->>'pending_count')::int = 1
     AND v_rep->'checklist'->>'status' = 'open'
     AND jsonb_array_length(v_rep->'items') = 1 THEN
    INSERT INTO test_results VALUES ('T2 get checklist RPC', 'PASS', v_rep::text);
  ELSE
    INSERT INTO test_results VALUES ('T2 get checklist RPC', 'FAIL', v_rep::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 get checklist RPC', 'FAIL', SQLERRM);
END $$;

-- T3: return asset syncs item + completes checklist
DO $$
DECLARE
  v_asset uuid;
  v_cl_id uuid;
  v_status text;
  v_item_status text;
BEGIN
  SELECT asset_id, checklist_id INTO v_asset, v_cl_id FROM test_ids;
  PERFORM api.return_employee_asset(v_asset, 'good', NULL, 'ea4 return');

  SELECT status INTO v_status FROM data.employee_asset_return_checklists WHERE id = v_cl_id;
  SELECT status INTO v_item_status
  FROM data.employee_asset_return_checklist_items
  WHERE checklist_id = v_cl_id LIMIT 1;

  IF v_status = 'completed' AND v_item_status = 'returned' THEN
    INSERT INTO test_results VALUES (
      'T3 return syncs checklist', 'PASS',
      format('cl=%s item=%s', v_status, v_item_status)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T3 return syncs checklist', 'FAIL',
      format('cl=%s item=%s', v_status, v_item_status)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 return syncs checklist', 'FAIL', SQLERRM);
END $$;

-- T4: terminated with open assets → soft exception audit (no hard block)
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_site uuid := '30000000-0000-0000-0000-000000000001';
  v_emp uuid;
  v_asset uuid;
  v_state text;
  v_audit int;
BEGIN
  INSERT INTO data.employees (
    tenant_id, full_name, status, weekly_hours, site_id, lifecycle_state
  ) VALUES (
    v_tenant, 'EA4 Exception Emp', 'active', 40, v_site, 'active'
  )
  RETURNING id INTO v_emp;

  PERFORM set_config('data.lifecycle_state_write', '1', true);
  UPDATE data.employees SET lifecycle_state = 'active' WHERE id = v_emp;

  INSERT INTO data.assets (tenant_id, site_id, name, asset_tag, status)
  VALUES (v_tenant, v_site, 'EA4 Phone', 'EA4-B', 'operational')
  RETURNING id INTO v_asset;

  PERFORM api.assign_employee_asset(v_asset, v_emp);
  PERFORM api.transition_employee_lifecycle(v_emp, 'departure', 'dismissal', CURRENT_DATE, '{}'::jsonb);
  PERFORM api.transition_employee_lifecycle(v_emp, 'offboarding', 'offboarding_started', CURRENT_DATE, '{}'::jsonb);
  PERFORM api.transition_employee_lifecycle(v_emp, 'terminated', 'offboarding_completed', CURRENT_DATE, '{}'::jsonb);

  SELECT lifecycle_state INTO v_state FROM data.employees WHERE id = v_emp;

  SELECT count(*) INTO v_audit
  FROM data.audit_logs
  WHERE action = 'OFFBOARDING_OPEN_ASSETS_EXCEPTION'
    AND entity_id = v_emp;

  IF v_state = 'terminated' AND v_audit >= 1 THEN
    INSERT INTO test_results VALUES (
      'T4 terminated soft exception', 'PASS',
      format('audit=%s', v_audit)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T4 terminated soft exception', 'FAIL',
      format('state=%s audit=%s', v_state, v_audit)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T4 terminated soft exception', 'FAIL', SQLERRM);
END $$;

-- T5: waive checklist with pending items
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_site uuid := '30000000-0000-0000-0000-000000000001';
  v_emp uuid;
  v_asset uuid;
  v_cl uuid;
  v_out api.employee_asset_return_checklists;
BEGIN
  INSERT INTO data.employees (
    tenant_id, full_name, status, weekly_hours, site_id, lifecycle_state
  ) VALUES (
    v_tenant, 'EA4 Waive Emp', 'active', 40, v_site, 'active'
  )
  RETURNING id INTO v_emp;

  PERFORM set_config('data.lifecycle_state_write', '1', true);
  UPDATE data.employees SET lifecycle_state = 'active' WHERE id = v_emp;

  INSERT INTO data.assets (tenant_id, site_id, name, asset_tag, status)
  VALUES (v_tenant, v_site, 'EA4 Badge', 'EA4-C', 'operational')
  RETURNING id INTO v_asset;

  PERFORM api.assign_employee_asset(v_asset, v_emp);
  PERFORM api.transition_employee_lifecycle(v_emp, 'departure', 'resignation', CURRENT_DATE, '{}'::jsonb);
  PERFORM api.transition_employee_lifecycle(v_emp, 'offboarding', 'offboarding_started', CURRENT_DATE, '{}'::jsonb);

  SELECT id INTO v_cl
  FROM data.employee_asset_return_checklists
  WHERE employee_id = v_emp AND status = 'open'
  LIMIT 1;

  v_out := api.waive_employee_asset_return_checklist(v_cl, 'lost_in_field');

  IF v_out.status = 'waived' THEN
    INSERT INTO test_results VALUES ('T5 waive checklist', 'PASS', v_out.id::text);
  ELSE
    INSERT INTO test_results VALUES ('T5 waive checklist', 'FAIL', v_out.status);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 waive checklist', 'FAIL', SQLERRM);
END $$;

-- T6: empty open assignments → checklist auto-completed
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_site uuid := '30000000-0000-0000-0000-000000000001';
  v_emp uuid;
  v_status text;
  v_items int;
BEGIN
  INSERT INTO data.employees (
    tenant_id, full_name, status, weekly_hours, site_id, lifecycle_state
  ) VALUES (
    v_tenant, 'EA4 Empty Emp', 'active', 40, v_site, 'active'
  )
  RETURNING id INTO v_emp;

  PERFORM set_config('data.lifecycle_state_write', '1', true);
  UPDATE data.employees SET lifecycle_state = 'active' WHERE id = v_emp;

  PERFORM api.transition_employee_lifecycle(v_emp, 'departure', 'contract_end', CURRENT_DATE, '{}'::jsonb);
  PERFORM api.transition_employee_lifecycle(v_emp, 'offboarding', 'offboarding_started', CURRENT_DATE, '{}'::jsonb);

  SELECT c.status, (
    SELECT count(*) FROM data.employee_asset_return_checklist_items i WHERE i.checklist_id = c.id
  )
  INTO v_status, v_items
  FROM data.employee_asset_return_checklists c
  WHERE c.employee_id = v_emp
  ORDER BY c.created_at DESC LIMIT 1;

  IF v_status = 'completed' AND v_items = 0 THEN
    INSERT INTO test_results VALUES ('T6 empty checklist completed', 'PASS', 'ok');
  ELSE
    INSERT INTO test_results VALUES (
      'T6 empty checklist completed', 'FAIL',
      format('status=%s items=%s', v_status, v_items)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 empty checklist completed', 'FAIL', SQLERRM);
END $$;

-- T7: Dave denied get
DO $$
DECLARE
  v_emp uuid;
BEGIN
  SELECT employee_id INTO v_emp FROM test_ids;

  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000005', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000005","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  BEGIN
    PERFORM api.get_employee_asset_return_checklist(v_emp, true);
    INSERT INTO test_results VALUES ('T7 privilege denied', 'FAIL', 'expected insufficient_privilege');
  EXCEPTION
    WHEN insufficient_privilege THEN
      INSERT INTO test_results VALUES ('T7 privilege denied', 'PASS', SQLERRM);
    WHEN OTHERS THEN
      IF SQLSTATE IN ('42501', 'P0001') OR SQLERRM ILIKE '%privilege%' THEN
        INSERT INTO test_results VALUES ('T7 privilege denied', 'PASS', SQLERRM);
      ELSE
        INSERT INTO test_results VALUES ('T7 privilege denied', 'FAIL', SQLERRM);
      END IF;
  END;
END $$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EA-4 tests failed: %', v_fail;
  END IF;
END $$;

ROLLBACK;
