-- =============================================================================
-- EC Automation Center blueprints tests
-- Platform CONTRACT_* blueprints, onboarding rewrite, deactivate renewal,
-- install_blueprint as Acme owner.
-- =============================================================================
BEGIN;
SET client_min_messages TO WARNING;

-- Temp tables owned by authenticated so owner JWT block can write results
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

CREATE TEMP TABLE test_results (
  test_name text PRIMARY KEY,
  status text NOT NULL,
  details text
) ON COMMIT DROP;

CREATE TEMP TABLE t4_ids (
  blueprint_id uuid,
  installed_id uuid,
  err text
) ON COMMIT DROP;

INSERT INTO t4_ids DEFAULT VALUES;
RESET ROLE;

-- T1: platform blueprints exist for 4 CONTRACT_* events
DO $$
DECLARE
  v_missing text[];
BEGIN
  SELECT array_agg(e ORDER BY e)
  INTO v_missing
  FROM (
    VALUES
      ('CONTRACT_ACTIVATION_BLOCKED'),
      ('CONTRACT_ACTIVATED'),
      ('CONTRACT_EXPIRING'),
      ('CONTRACT_ENDED')
  ) AS expected(e)
  WHERE NOT EXISTS (
    SELECT 1
    FROM data.automation_workflows w
    WHERE w.is_blueprint = true
      AND w.tenant_id IS NULL
      AND w.is_active = true
      AND w.trigger_event = expected.e
  );

  IF v_missing IS NULL THEN
    INSERT INTO test_results VALUES ('T1 contract_blueprints', 'PASS', '4 active platform blueprints');
  ELSE
    INSERT INTO test_results VALUES ('T1 contract_blueprints', 'FAIL', format('missing: %s', v_missing));
  END IF;
END $$;

-- T2: Onboarding rewritten to EMPLOYEE_LIFECYCLE_CHANGED + to=active; no GENERATE_DOCUMENT
DO $$
DECLARE
  v_trigger text;
  v_filters jsonb;
  v_steps jsonb;
  v_has_gen boolean;
BEGIN
  SELECT trigger_event, trigger_filters, steps
  INTO v_trigger, v_filters, v_steps
  FROM data.automation_workflows
  WHERE is_blueprint = true
    AND tenant_id IS NULL
    AND name = 'Onboarding d''empleats';

  SELECT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(COALESCE(v_steps, '[]'::jsonb)) s
    WHERE s ->> 'type' = 'GENERATE_DOCUMENT'
  ) INTO v_has_gen;

  IF v_trigger = 'EMPLOYEE_LIFECYCLE_CHANGED'
     AND (v_filters ->> 'to') = 'active'
     AND NOT COALESCE(v_has_gen, true)
  THEN
    INSERT INTO test_results VALUES (
      'T2 onboarding_lifecycle',
      'PASS',
      format('trigger=%s filters=%s', v_trigger, v_filters)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T2 onboarding_lifecycle',
      'FAIL',
      format('trigger=%s filters=%s has_gen=%s steps=%s', v_trigger, v_filters, v_has_gen, v_steps)
    );
  END IF;
END $$;

-- T3: Recordatori renovació is_active = false
DO $$
DECLARE
  v_active boolean;
BEGIN
  SELECT is_active INTO v_active
  FROM data.automation_workflows
  WHERE is_blueprint = true
    AND tenant_id IS NULL
    AND name = 'Recordatori renovació de contractes';

  IF v_active IS FALSE THEN
    INSERT INTO test_results VALUES ('T3 renewal_deactivated', 'PASS', 'is_active=false');
  ELSE
    INSERT INTO test_results VALUES (
      'T3 renewal_deactivated',
      'FAIL',
      format('is_active=%s', v_active)
    );
  END IF;
END $$;

-- T4 prep (postgres): resolve blueprint + clean prior tenant clones
DO $$
DECLARE
  v_bp_id uuid;
BEGIN
  SELECT id INTO v_bp_id
  FROM data.automation_workflows
  WHERE is_blueprint = true
    AND tenant_id IS NULL
    AND trigger_event = 'CONTRACT_ACTIVATION_BLOCKED'
    AND is_active = true
  LIMIT 1;

  UPDATE t4_ids SET blueprint_id = v_bp_id;

  IF v_bp_id IS NOT NULL THEN
    DELETE FROM data.automation_workflows
    WHERE tenant_id = '10000000-0000-0000-0000-000000000001'
      AND source_blueprint_id = v_bp_id;
  END IF;
END $$;

-- T4: install_blueprint as Acme owner
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

DO $$
DECLARE
  v_bp_id uuid;
  v_new_id uuid;
BEGIN
  SELECT blueprint_id INTO v_bp_id FROM t4_ids;

  IF v_bp_id IS NULL THEN
    UPDATE t4_ids SET err = 'blueprint not found';
    RETURN;
  END IF;

  v_new_id := api.install_blueprint(v_bp_id, '{}'::jsonb);
  UPDATE t4_ids SET installed_id = v_new_id, err = NULL;
EXCEPTION WHEN OTHERS THEN
  UPDATE t4_ids SET installed_id = NULL, err = SQLERRM;
END $$;

RESET ROLE;

DO $$
DECLARE
  v_bp_id uuid;
  v_new_id uuid;
  v_err text;
  v_src uuid;
  v_tenant uuid;
BEGIN
  SELECT blueprint_id, installed_id, err INTO v_bp_id, v_new_id, v_err FROM t4_ids;

  IF v_err IS NOT NULL AND v_new_id IS NULL THEN
    INSERT INTO test_results VALUES ('T4 install_blueprint', 'FAIL', v_err);
    RETURN;
  END IF;

  IF v_bp_id IS NULL THEN
    INSERT INTO test_results VALUES ('T4 install_blueprint', 'FAIL', 'blueprint not found');
    RETURN;
  END IF;

  IF v_new_id IS NULL THEN
    INSERT INTO test_results VALUES ('T4 install_blueprint', 'FAIL', 'install returned null');
    RETURN;
  END IF;

  SELECT source_blueprint_id, tenant_id
  INTO v_src, v_tenant
  FROM data.automation_workflows
  WHERE id = v_new_id;

  IF v_src = v_bp_id
     AND v_tenant = '10000000-0000-0000-0000-000000000001'
  THEN
    INSERT INTO test_results VALUES (
      'T4 install_blueprint',
      'PASS',
      format('workflow_id=%s source=%s', v_new_id, v_src)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T4 install_blueprint',
      'FAIL',
      format('new=%s src=%s tenant=%s', v_new_id, v_src, v_tenant)
    );
  END IF;
END $$;

-- T5: notice path + blueprint steps JSON valid
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_ok boolean;
  v_steps jsonb;
  v_types text[];
  v_cid uuid;
BEGIN
  SELECT steps INTO v_steps
  FROM data.automation_workflows
  WHERE is_blueprint = true
    AND tenant_id IS NULL
    AND trigger_event = 'CONTRACT_ACTIVATION_BLOCKED'
  LIMIT 1;

  SELECT array_agg(s ->> 'type' ORDER BY ordinality)
  INTO v_types
  FROM jsonb_array_elements(COALESCE(v_steps, '[]'::jsonb)) WITH ORDINALITY AS t(s, ordinality);

  IF v_types @> ARRAY['SEND_NOTIFICATION', 'CREATE_TASK']::text[]
     AND jsonb_typeof(v_steps) = 'array'
  THEN
    SELECT id INTO v_cid
    FROM data.employment_contracts
    WHERE tenant_id = v_tenant
    LIMIT 1;

    IF v_cid IS NOT NULL THEN
      SELECT data.try_employment_contract_notice(
        v_tenant,
        v_cid,
        NULL,
        'activation_blocked',
        999,
        'CONTRACT_ACTIVATION_BLOCKED',
        jsonb_build_object('test', 'ec_automation_center_blueprints')
      ) INTO v_ok;
    ELSE
      v_ok := true;
    END IF;

    INSERT INTO test_results VALUES (
      'T5 notice_and_steps',
      'PASS',
      format('types=%s notice=%s', v_types, v_ok)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T5 notice_and_steps',
      'FAIL',
      format('types=%s steps=%s', v_types, v_steps)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 notice_and_steps', 'FAIL', SQLERRM);
END $$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'ec_automation_center_blueprints_tests: % failures', v_fail;
  END IF;
END $$;

ROLLBACK;
