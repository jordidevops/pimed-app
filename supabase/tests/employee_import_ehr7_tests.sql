-- =============================================================================
-- EHR-7 — employee import V2 tests (connectors backlog)
-- =============================================================================

BEGIN;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

GRANT ALL ON TABLE test_results TO authenticated;

-- Reuse Acme owner JWT
CREATE OR REPLACE FUNCTION pg_temp.set_owner_jwt() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["employees.private.manage","employees.private.view"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.set_mgr_no_private() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000004', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000004","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"manager","sites":{"30000000-0000-0000-0000-000000000001":"manager"}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);
END;
$$;

-- Ensure a job position for resolve tests
INSERT INTO data.job_positions (id, tenant_id, code, name, is_active)
VALUES (
  'a0000000-0000-0000-0000-00000000e701',
  '10000000-0000-0000-0000-000000000001',
  'EHR7-ELEC',
  'Electricista EHR7',
  true
)
ON CONFLICT DO NOTHING;

-- T1: dry_run create with V2 fields + domains
SET LOCAL ROLE authenticated;
SELECT pg_temp.set_owner_jwt();

DO $$
DECLARE
  v jsonb;
  r jsonb;
BEGIN
  v := api.import_employees_bulk(
    jsonb_build_array(
      jsonb_build_object(
        'full_name', 'EHR7 Nova Persona',
        'employee_code', 'EHR7-NEW-1',
        'document_id', '99887766Z',
        'email', 'ehr7.new@acme-corp.com',
        'job_position_ref', 'EHR7-ELEC',
        'tags', 'camp,prl',
        'preferred_name', 'Nova',
        'external_id', 'EHR7-EXT-1'
      )
    ),
    jsonb_build_object('dry_run', true, 'default_provider', 'csv')
  );
  r := v->'results'->0;

  IF (v->>'ok')::boolean
     AND (v->>'created')::int = 1
     AND (r->>'action') = 'create'
     AND (r->'domains'->>'employee')::boolean = true
     AND (r->'domains'->>'contract') = 'deferred_ec'
     AND (v->'connectors'->>'status') = 'backlog' THEN
    INSERT INTO test_results VALUES ('T1 dry_run V2 create domains', 'PASS', v::text);
  ELSE
    INSERT INTO test_results VALUES ('T1 dry_run V2 create domains', 'FAIL', v::text);
  END IF;
END $$;

-- T2: real create + V2 fields + tags + position
DO $$
DECLARE
  v jsonb;
  v_emp uuid;
  v_code text;
  v_pos uuid;
  v_tag_cnt int;
BEGIN
  v := api.import_employees_bulk(
    jsonb_build_array(
      jsonb_build_object(
        'full_name', 'EHR7 Nova Persona',
        'employee_code', 'EHR7-NEW-1',
        'document_id', '99887766Z',
        'email', 'ehr7.new@acme-corp.com',
        'job_position_ref', 'EHR7-ELEC',
        'tags', 'camp,prl',
        'preferred_name', 'Nova',
        'manager_external_ref', '40000000-0000-0000-0000-000000000001',
        'external_id', 'EHR7-EXT-1'
      )
    ),
    jsonb_build_object('dry_run', false, 'default_provider', 'csv',
      'default_site_id', '30000000-0000-0000-0000-000000000001')
  );

  SELECT id, employee_code, job_position_id INTO v_emp, v_code, v_pos
  FROM data.employees
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'
    AND data.normalize_document_id(document_id) = '99887766Z'
  LIMIT 1;

  SELECT count(*) INTO v_tag_cnt
  FROM data.employee_tag_assignments a
  WHERE a.employee_id = v_emp;

  IF (v->>'created')::int = 1
     AND v_code = 'EHR7-NEW-1'
     AND v_pos = 'a0000000-0000-0000-0000-00000000e701'
     AND v_tag_cnt >= 2 THEN
    INSERT INTO test_results VALUES ('T2 create V2 position tags', 'PASS', v_emp::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T2 create V2 position tags', 'FAIL',
      format('v=%s code=%s pos=%s tags=%s', v::text, v_code, v_pos, v_tag_cnt)
    );
  END IF;
END $$;

-- T3: idempotent reimport via employee_code
DO $$
DECLARE
  v jsonb;
  v_cnt int;
BEGIN
  v := api.import_employees_bulk(
    jsonb_build_array(
      jsonb_build_object(
        'full_name', 'EHR7 Nova Persona Updated',
        'employee_code', 'EHR7-NEW-1',
        'document_id', '99887766Z',
        'email', 'ehr7.new@acme-corp.com'
      )
    ),
    jsonb_build_object('dry_run', false, 'default_provider', 'csv')
  );

  SELECT count(*) INTO v_cnt
  FROM data.employees
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'
    AND data.normalize_document_id(document_id) = '99887766Z';

  IF (v->>'updated')::int = 1 AND (v->>'created')::int = 0 AND v_cnt = 1
     AND (v->'results'->0->>'matched_by') = 'employee_code' THEN
    INSERT INTO test_results VALUES ('T3 idempotent by code', 'PASS', v::text);
  ELSE
    INSERT INTO test_results VALUES ('T3 idempotent by code', 'FAIL', v::text);
  END IF;
END $$;

-- T4: private skipped without explicit permission (Charlie manager, sense private.manage)
SELECT pg_temp.set_mgr_no_private();

DO $$
DECLARE
  v jsonb;
  r jsonb;
BEGIN
  v := api.import_employees_bulk(
    jsonb_build_array(
      jsonb_build_object(
        'full_name', 'Charlie (Acme)',
        'email', 'charlie@acme-corp.com',
        'personal_email', 'charlie.private@example.com'
      )
    ),
    jsonb_build_object('dry_run', true, 'default_provider', 'csv')
  );
  r := v->'results'->0;

  IF (r->'domains'->>'private') = 'no_permission'
     AND (r->>'action') IN ('update', 'needs_review') THEN
    INSERT INTO test_results VALUES ('T4 private no permission', 'PASS', r::text);
  ELSE
    INSERT INTO test_results VALUES ('T4 private no permission', 'FAIL', v::text);
  END IF;
END $$;

-- T5: private applies with permission (owner)
SELECT pg_temp.set_owner_jwt();

DO $$
DECLARE
  v jsonb;
  v_mail text;
BEGIN
  v := api.import_employees_bulk(
    jsonb_build_array(
      jsonb_build_object(
        'full_name', 'EHR7 Nova Persona Updated',
        'employee_code', 'EHR7-NEW-1',
        'document_id', '99887766Z',
        'personal_email', 'ehr7.private@acme-corp.com',
        'emergency_contact_name', 'Contact EHR7'
      )
    ),
    jsonb_build_object('dry_run', false, 'default_provider', 'csv')
  );

  SELECT personal_email INTO v_mail
  FROM data.employee_private_profiles pp
  JOIN data.employees e ON e.id = pp.employee_id
  WHERE e.employee_code = 'EHR7-NEW-1'
    AND e.tenant_id = '10000000-0000-0000-0000-000000000001';

  IF v_mail = 'ehr7.private@acme-corp.com'
     AND (v->'results'->0->'domains'->>'private') = 'applied' THEN
    INSERT INTO test_results VALUES ('T5 private with permission', 'PASS', v_mail);
  ELSE
    INSERT INTO test_results VALUES ('T5 private with permission', 'FAIL',
      format('mail=%s v=%s', v_mail, v::text));
  END IF;
END $$;

-- T6: signed contract conflict → needs_review
DO $$
DECLARE
  v_emp uuid := '40000000-0000-0000-0000-000000000001';
  v jsonb;
  r jsonb;
  v_hours numeric;
BEGIN
  -- Ensure a signed contract with weekly_hours
  INSERT INTO data.employment_contracts (
    id, tenant_id, employee_id, lifecycle_status, signature_status,
    signature_requirement, starts_on, weekly_hours, is_primary
  )
  VALUES (
    'a0000000-0000-0000-0000-00000000e702',
    '10000000-0000-0000-0000-000000000001',
    v_emp,
    'active',
    'completed',
    'employee_and_employer',
    CURRENT_DATE - 30,
    40,
    true
  )
  ON CONFLICT (id) DO UPDATE SET
    lifecycle_status = 'active',
    signature_status = 'completed',
    weekly_hours = 40,
    signature_requirement = 'employee_and_employer';

  -- Keep legacy hours different so we can assert they are NOT overwritten to 20
  UPDATE data.employees SET weekly_hours = 40 WHERE id = v_emp;

  v := api.import_employees_bulk(
    jsonb_build_array(
      jsonb_build_object(
        'full_name', 'Alice (Acme)',
        'email', 'alice@acme-corp.com',
        'weekly_hours', 20
      )
    ),
    jsonb_build_object('dry_run', false, 'default_provider', 'csv')
  );
  r := v->'results'->0;

  SELECT weekly_hours INTO v_hours FROM data.employees WHERE id = v_emp;

  IF (v->>'needs_review')::int >= 1
     AND (r->>'action') = 'needs_review'
     AND (r->'domains'->>'contract') = 'needs_review'
     AND (r->>'matched_by') IN ('email', 'document_id', 'employee_code', 'mapping')
     AND (v_hours IS DISTINCT FROM 20) THEN
    INSERT INTO test_results VALUES ('T6 signed conflict review', 'PASS',
      format('hours_kept=%s match=%s', v_hours, r->>'matched_by'));
  ELSE
    INSERT INTO test_results VALUES ('T6 signed conflict review', 'FAIL',
      format('v=%s hours=%s', v::text, v_hours));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 signed conflict review', 'FAIL', SQLERRM);
END $$;

-- T7: contract fields stripped / ignored
DO $$
DECLARE
  v jsonb;
  r jsonb;
  v_has_warn boolean := false;
  w jsonb;
BEGIN
  v := api.import_employees_bulk(
    jsonb_build_array(
      jsonb_build_object(
        'full_name', 'EHR7 Meta Strip',
        'document_id', '11223344C',
        'email', 'ehr7.meta@acme-corp.com',
        'contract_type', 'indefinit',
        'metadata', jsonb_build_object('conveni', 'metall', 'category', 'A')
      )
    ),
    jsonb_build_object('dry_run', true, 'default_provider', 'csv')
  );
  r := v->'results'->0;
  FOR w IN SELECT * FROM jsonb_array_elements(COALESCE(r->'warnings', '[]'::jsonb))
  LOOP
    IF w->>'code' IN ('METADATA_CONTRACT_STRIPPED', 'CONTRACT_FIELDS_IGNORED') THEN
      v_has_warn := true;
    END IF;
  END LOOP;

  IF v_has_warn AND (r->'domains'->>'contract') = 'deferred_ec' THEN
    INSERT INTO test_results VALUES ('T7 contract fields ignored', 'PASS', r::text);
  ELSE
    INSERT INTO test_results VALUES ('T7 contract fields ignored', 'FAIL', v::text);
  END IF;
END $$;

-- T8: per-row error isolation
DO $$
DECLARE
  v jsonb;
BEGIN
  v := api.import_employees_bulk(
    jsonb_build_array(
      jsonb_build_object('full_name', ''),
      jsonb_build_object(
        'full_name', 'EHR7 OK Row',
        'document_id', '55667788D',
        'email', 'ehr7.ok@acme-corp.com'
      )
    ),
    jsonb_build_object('dry_run', true, 'default_provider', 'csv')
  );

  IF (v->>'created')::int = 1 AND (v->>'skipped')::int >= 1 THEN
    INSERT INTO test_results VALUES ('T8 per-row isolation', 'PASS', v::text);
  ELSE
    INSERT INTO test_results VALUES ('T8 per-row isolation', 'FAIL', v::text);
  END IF;
END $$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EHR-7 tests failed: % failures', v_fail;
  END IF;
END $$;

ROLLBACK;
