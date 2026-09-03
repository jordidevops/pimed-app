-- =============================================================================
-- CR-5 medical clearance signing tests
-- =============================================================================
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
  medical_type_id uuid,
  tech_type_id uuid,
  medical_cert_id uuid,
  tech_cert_id uuid
) ON COMMIT DROP;

INSERT INTO test_ids DEFAULT VALUES;

RESET ROLE;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_site uuid := '30000000-0000-0000-0000-000000000001';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_emp uuid;
  v_med uuid;
  v_tech uuid;
  v_mc uuid;
  v_tc uuid;
BEGIN
  DELETE FROM data.employee_certifications
  WHERE employee_id IN (
    SELECT id FROM data.employees WHERE full_name = 'CR5 Medical Emp'
  );
  DELETE FROM data.employees WHERE tenant_id = v_tenant AND full_name = 'CR5 Medical Emp';
  DELETE FROM data.compliance_requirement_types
  WHERE tenant_id = v_tenant AND code IN ('CR5_MED', 'CR5_TECH');

  INSERT INTO data.employees (tenant_id, full_name, status, weekly_hours, site_id)
  VALUES (v_tenant, 'CR5 Medical Emp', 'active', 40, v_site)
  RETURNING id INTO v_emp;

  INSERT INTO data.compliance_requirement_types (
    tenant_id, code, name, category, is_active
  ) VALUES (
    v_tenant, 'CR5_MED', 'CR5 Medical', 'medical', true
  )
  RETURNING id INTO v_med;

  INSERT INTO data.compliance_requirement_types (
    tenant_id, code, name, category, is_active
  ) VALUES (
    v_tenant, 'CR5_TECH', 'CR5 Technical', 'technical', true
  )
  RETURNING id INTO v_tech;
  INSERT INTO data.employee_certifications (
    tenant_id, employee_id, requirement_type_id,
    issuer, valid_from, valid_until, notes, created_by
  ) VALUES (
    v_tenant, v_emp, v_med,
    'SPP Test', CURRENT_DATE, CURRENT_DATE + 365, 'fit', v_owner
  )
  RETURNING id INTO v_mc;

  INSERT INTO data.employee_certifications (
    tenant_id, employee_id, requirement_type_id,
    issuer, valid_from, valid_until, created_by
  ) VALUES (
    v_tenant, v_emp, v_tech,
    'PRL', CURRENT_DATE, CURRENT_DATE + 365, v_owner
  )
  RETURNING id INTO v_tc;

  UPDATE test_ids SET
    employee_id = v_emp,
    medical_type_id = v_med,
    tech_type_id = v_tech,
    medical_cert_id = v_mc,
    tech_cert_id = v_tc;
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

-- T1: generate medical document
DO $$
DECLARE
  v_cert uuid;
  v_out api.employee_certifications;
BEGIN
  SELECT medical_cert_id INTO v_cert FROM test_ids;
  v_out := api.generate_employee_medical_clearance_document(v_cert, NULL, false);

  IF v_out.document_id IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM data.documents d
       WHERE d.id = v_out.document_id
         AND d.entity_type = 'employee_certification'
         AND d.entity_id = v_cert
     ) THEN
    INSERT INTO test_results VALUES ('T1 generate medical doc', 'PASS', v_out.document_id::text);
  ELSE
    INSERT INTO test_results VALUES ('T1 generate medical doc', 'FAIL', v_out::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T1 generate medical doc', 'FAIL', SQLERRM);
END $$;

-- T2: prepare signing payload
DO $$
DECLARE
  v_cert uuid;
  v_prep jsonb;
BEGIN
  SELECT medical_cert_id INTO v_cert FROM test_ids;
  v_prep := api.prepare_employee_medical_clearance_signing(v_cert);

  IF (v_prep->>'certification_id')::uuid = v_cert
     AND v_prep ? 'template_locale_id'
     AND v_prep ? 'variables' THEN
    INSERT INTO test_results VALUES ('T2 prepare signing', 'PASS', v_prep::text);
  ELSE
    INSERT INTO test_results VALUES ('T2 prepare signing', 'FAIL', v_prep::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 prepare signing', 'FAIL', SQLERRM);
END $$;

-- T3: technical cert rejected by generate
DO $$
DECLARE
  v_cert uuid;
  v_ok boolean := false;
BEGIN
  SELECT tech_cert_id INTO v_cert FROM test_ids;
  BEGIN
    PERFORM api.generate_employee_medical_clearance_document(v_cert, NULL, false);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%not_medical_certification%' THEN
      v_ok := true;
    END IF;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T3 tech rejected', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T3 tech rejected', 'FAIL', 'expected not_medical');
  END IF;
END $$;

-- T4: certifications.manage without medical cannot prepare
DO $$
DECLARE
  v_cert uuid;
  v_ok boolean := false;
BEGIN
  SELECT medical_cert_id INTO v_cert FROM test_ids;

  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000005', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000005","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["compliance.certifications.manage","compliance.certifications.view"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  BEGIN
    PERFORM api.prepare_employee_medical_clearance_signing(v_cert);
  EXCEPTION WHEN insufficient_privilege THEN
    v_ok := true;
  WHEN OTHERS THEN
    IF SQLERRM ILIKE '%insufficient_privilege%' THEN
      v_ok := true;
    END IF;
  END;

  IF v_ok THEN
    INSERT INTO test_results VALUES ('T4 certs.manage denied medical', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T4 certs.manage denied medical', 'FAIL', 'expected deny');
  END IF;
END $$;

-- T5: medical_clearance.manage can prepare
DO $$
DECLARE
  v_cert uuid;
  v_prep jsonb;
BEGIN
  SELECT medical_cert_id INTO v_cert FROM test_ids;

  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000005', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000005","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["compliance.medical_clearance.manage","compliance.medical_clearance.view"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  v_prep := api.prepare_employee_medical_clearance_signing(v_cert);
  IF (v_prep->>'certification_id')::uuid = v_cert THEN
    INSERT INTO test_results VALUES ('T5 medical.manage can prepare', 'PASS', NULL);
  ELSE
    INSERT INTO test_results VALUES ('T5 medical.manage can prepare', 'FAIL', v_prep::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 medical.manage can prepare', 'FAIL', SQLERRM);
END $$;

-- T6: generate idempotent
DO $$
DECLARE
  v_cert uuid;
  v_d1 uuid;
  v_d2 uuid;
BEGIN
  -- Restore owner
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT medical_cert_id INTO v_cert FROM test_ids;
  SELECT document_id INTO v_d1 FROM data.employee_certifications WHERE id = v_cert;
  PERFORM api.generate_employee_medical_clearance_document(v_cert, NULL, false);
  SELECT document_id INTO v_d2 FROM data.employee_certifications WHERE id = v_cert;

  IF v_d1 IS NOT NULL AND v_d1 = v_d2 THEN
    INSERT INTO test_results VALUES ('T6 generate idempotent', 'PASS', v_d1::text);
  ELSE
    INSERT INTO test_results VALUES ('T6 generate idempotent', 'FAIL', format('%s vs %s', v_d1, v_d2));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 generate idempotent', 'FAIL', SQLERRM);
END $$;

-- T7: link signing (synthetic submission)
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_cert uuid;
  v_doc uuid;
  v_sub uuid;
  v_out api.employee_certifications;
BEGIN
  SELECT medical_cert_id INTO v_cert FROM test_ids;
  SELECT document_id INTO v_doc FROM data.employee_certifications WHERE id = v_cert;

  RESET ROLE;
  INSERT INTO data.signing_submissions (
    tenant_id, source_type, source_template_locale_id, status, external_id, initiated_by
  ) VALUES (
    v_tenant,
    'template_locale',
    '71000000-0000-0000-0000-000000000042',
    'pending',
    'cr5-test-' || gen_random_uuid()::text,
    '20000000-0000-0000-0000-000000000002'
  )
  RETURNING id INTO v_sub;

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  v_out := api.link_employee_medical_clearance_signing(v_cert, v_sub, v_doc);

  IF v_out.signing_submission_id = v_sub THEN
    INSERT INTO test_results VALUES ('T7 link signing', 'PASS', v_sub::text);
  ELSE
    INSERT INTO test_results VALUES ('T7 link signing', 'FAIL', v_out::text);
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T7 link signing', 'FAIL', SQLERRM);
END $$;

DO $$
DECLARE
  v_fail int;
  r record;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  RAISE WARNING '=== CR-5 medical signing ===';
  FOR r IN SELECT test_name, status, details FROM test_results ORDER BY test_name LOOP
    RAISE WARNING '%: % — %', r.test_name, r.status, coalesce(r.details, '');
  END LOOP;
  IF v_fail > 0 THEN
    RAISE EXCEPTION '% failed tests', v_fail;
  END IF;
END $$;

ROLLBACK;
