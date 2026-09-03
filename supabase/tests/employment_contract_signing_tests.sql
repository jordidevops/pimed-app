-- M-EC-05 employment contract signing tests
BEGIN;
SET client_min_messages TO WARNING;

-- Create temp tables as authenticated so DO blocks can write results
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text PRIMARY KEY,
  status text NOT NULL,
  details text
) ON COMMIT DROP;

CREATE TEMP TABLE test_ids (
  contract_id uuid,
  submission_id uuid,
  version_id uuid
) ON COMMIT DROP;

INSERT INTO test_ids DEFAULT VALUES;

-- Owner JWT
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

-- T1: draft with requirement none can schedule
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_alice  uuid := '40000000-0000-0000-0000-000000000001';
  v_id uuid;
  v_status text;
BEGIN
  INSERT INTO api.employment_contracts (
    tenant_id, employee_id, contract_number, starts_on,
    lifecycle_status, is_primary, signature_requirement, signature_status
  ) VALUES (
    v_tenant, v_alice, 'EC5-TEST-1', CURRENT_DATE,
    'draft', true, 'none', 'not_required'
  ) RETURNING id INTO v_id;

  UPDATE test_ids SET contract_id = v_id;
  PERFORM api.transition_employment_contract(v_id, 'scheduled', NULL);
  SELECT lifecycle_status INTO v_status FROM data.employment_contracts WHERE id = v_id;

  IF v_status = 'scheduled' THEN
    INSERT INTO test_results VALUES ('T1 schedule without signature', 'PASS', v_status);
  ELSE
    INSERT INTO test_results VALUES ('T1 schedule without signature', 'FAIL', coalesce(v_status, 'null'));
  END IF;

  -- reset to draft for further tests
  UPDATE data.employment_contracts SET lifecycle_status = 'draft' WHERE id = v_id;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T1 schedule without signature', 'FAIL', SQLERRM);
END $$;

-- T2: requirement employee_and_employer blocks schedule
DO $$
DECLARE
  v_id uuid;
  v_blocked boolean := false;
  v_err text;
BEGIN
  SELECT contract_id INTO v_id FROM test_ids;
  UPDATE data.employment_contracts
  SET signature_requirement = 'employee_and_employer',
      signature_status = 'pending',
      lifecycle_status = 'draft'
  WHERE id = v_id;

  BEGIN
    PERFORM api.transition_employment_contract(v_id, 'scheduled', NULL);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    IF v_err ILIKE '%signature_required%' THEN
      v_blocked := true;
    ELSE
      RAISE;
    END IF;
  END;

  IF v_blocked THEN
    INSERT INTO test_results VALUES ('T2 schedule blocked pending sig', 'PASS', 'signature_required');
  ELSE
    INSERT INTO test_results VALUES ('T2 schedule blocked pending sig', 'FAIL', 'allowed');
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 schedule blocked pending sig', 'FAIL', SQLERRM);
END $$;

-- T3 setup: insert submission as postgres (bypass RLS)
RESET ROLE;
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_sub uuid;
  v_ver uuid;
  v_doc uuid;
BEGIN
  INSERT INTO data.documents (tenant_id, title, category, entity_type, required_permissions)
  VALUES (v_tenant, 'EC5 signed stub', 'hr', 'employment_contract', ARRAY['owner','manager'])
  RETURNING id INTO v_doc;

  INSERT INTO data.document_versions (
    document_id, version_number, storage_type, file_path_or_url, mime_type, size_bytes
  ) VALUES (
    v_doc, 1, 'external_link', 'employment-contract://ec5/v1', 'application/pdf', 10
  ) RETURNING id INTO v_ver;

  INSERT INTO data.signing_submissions (
    tenant_id, source_type, source_template_locale_id, status, signers
  ) VALUES (
    v_tenant,
    'template_locale',
    '71000000-0000-0000-0000-000000000001',
    'in_progress',
    '[{"email":"a@x.com","role":"worker"},{"email":"b@x.com","role":"hr_manager"}]'::jsonb
  ) RETURNING id INTO v_sub;

  UPDATE test_ids SET submission_id = v_sub, version_id = v_ver;
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

DO $$
DECLARE
  v_id uuid;
  v_sub uuid;
  v_out api.employment_contracts;
  v_prep jsonb;
BEGIN
  SELECT contract_id, submission_id INTO v_id, v_sub FROM test_ids;

  v_prep := api.prepare_employment_contract_signing(v_id);
  IF v_prep ? 'template_locale_id' AND v_prep ? 'variables' THEN
    INSERT INTO test_results VALUES ('T3a prepare signing payload', 'PASS', v_prep ->> 'template_locale_id');
  ELSE
    INSERT INTO test_results VALUES ('T3a prepare signing payload', 'FAIL', coalesce(v_prep::text, 'null'));
  END IF;

  v_out := api.link_employment_contract_signing(v_id, v_sub, NULL);
  IF v_out.signing_submission_id = v_sub
     AND v_out.signature_requirement = 'employee_and_employer'
     AND v_out.signature_status = 'pending' THEN
    INSERT INTO test_results VALUES ('T3b link signing pending', 'PASS', v_sub::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T3b link signing pending',
      'FAIL',
      format('req=%s status=%s sub=%s', v_out.signature_requirement, v_out.signature_status, v_out.signing_submission_id)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 link/prepare', 'FAIL', SQLERRM);
END $$;

-- T4: complete submission -> contract completed
RESET ROLE;
DO $$
DECLARE
  v_sub uuid;
  v_ver uuid;
  v_id uuid;
  v_status text;
  v_fully timestamptz;
BEGIN
  SELECT contract_id, submission_id, version_id INTO v_id, v_sub, v_ver FROM test_ids;

  UPDATE data.signing_submissions
  SET status = 'completed',
      result_document_version_id = v_ver,
      completed_at = now()
  WHERE id = v_sub;

  SELECT signature_status, fully_signed_at
  INTO v_status, v_fully
  FROM data.employment_contracts WHERE id = v_id;

  IF v_status = 'completed' AND v_fully IS NOT NULL THEN
    INSERT INTO test_results VALUES ('T4 complete syncs contract', 'PASS', v_status);
  ELSE
    INSERT INTO test_results VALUES (
      'T4 complete syncs contract',
      'FAIL',
      format('status=%s fully=%s', coalesce(v_status,'null'), coalesce(v_fully::text,'null'))
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T4 complete syncs contract', 'FAIL', SQLERRM);
END $$;

-- T5: after complete, schedule succeeds
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
  v_id uuid;
  v_status text;
BEGIN
  SELECT contract_id INTO v_id FROM test_ids;
  UPDATE data.employment_contracts SET lifecycle_status = 'draft' WHERE id = v_id;
  PERFORM api.transition_employment_contract(v_id, 'scheduled', NULL);
  SELECT lifecycle_status INTO v_status FROM data.employment_contracts WHERE id = v_id;
  IF v_status = 'scheduled' THEN
    INSERT INTO test_results VALUES ('T5 schedule after signed', 'PASS', v_status);
  ELSE
    INSERT INTO test_results VALUES ('T5 schedule after signed', 'FAIL', coalesce(v_status,'null'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T5 schedule after signed', 'FAIL', SQLERRM);
END $$;

-- T6: declined blocks schedule
-- Create draft contract as authenticated
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_alice  uuid := '40000000-0000-0000-0000-000000000001';
  v_id uuid;
BEGIN
  INSERT INTO api.employment_contracts (
    tenant_id, employee_id, contract_number, starts_on,
    lifecycle_status, is_primary, signature_requirement, signature_status
  ) VALUES (
    v_tenant, v_alice, 'EC5-TEST-2', CURRENT_DATE + 30,
    'draft', true, 'employee_and_employer', 'pending'
  ) RETURNING id INTO v_id;
END $$;

-- Link declined submission as postgres, then transition as authenticated
RESET ROLE;
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_id uuid;
  v_sub uuid;
BEGIN
  SELECT id INTO v_id FROM data.employment_contracts WHERE contract_number = 'EC5-TEST-2';

  INSERT INTO data.signing_submissions (
    tenant_id, source_type, source_template_locale_id, status, signers
  ) VALUES (
    v_tenant, 'template_locale', '71000000-0000-0000-0000-000000000001',
    'in_progress', '[]'::jsonb
  ) RETURNING id INTO v_sub;

  UPDATE data.employment_contracts
  SET signing_submission_id = v_sub WHERE id = v_id;

  UPDATE data.signing_submissions SET status = 'declined' WHERE id = v_sub;
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

DO $$
DECLARE
  v_id uuid;
  v_blocked boolean := false;
  v_err text;
  v_sig text;
BEGIN
  SELECT id INTO v_id FROM data.employment_contracts WHERE contract_number = 'EC5-TEST-2';

  BEGIN
    PERFORM api.transition_employment_contract(v_id, 'scheduled', NULL);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    IF v_err ILIKE '%signature_blocked%' OR v_err ILIKE '%signature_required%' THEN
      v_blocked := true;
    ELSE
      RAISE;
    END IF;
  END;

  SELECT signature_status INTO v_sig FROM data.employment_contracts WHERE id = v_id;

  IF v_blocked AND v_sig = 'rejected' THEN
    INSERT INTO test_results VALUES ('T6 declined blocks schedule', 'PASS', 'signature_blocked+rejected');
  ELSIF v_blocked THEN
    INSERT INTO test_results VALUES ('T6 declined blocks schedule', 'PASS', format('blocked sig=%s', coalesce(v_sig,'null')));
  ELSE
    INSERT INTO test_results VALUES ('T6 declined blocks schedule', 'FAIL', format('allowed sig=%s', coalesce(v_sig,'null')));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 declined blocks schedule', 'FAIL', SQLERRM);
END $$;

-- T7: template has signature fields (read as postgres)
RESET ROLE;
DO $$
DECLARE
  v_html text;
BEGIN
  SELECT html_content INTO v_html
  FROM data.document_template_locales
  WHERE id = '71000000-0000-0000-0000-000000000001';

  IF v_html ILIKE '%signature-field%worker%' AND v_html ILIKE '%hr_manager%' THEN
    INSERT INTO test_results VALUES ('T7 template signature fields', 'PASS', 'worker+hr_manager');
  ELSE
    INSERT INTO test_results VALUES ('T7 template signature fields', 'FAIL', left(coalesce(v_html,''), 80));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T7 template signature fields', 'FAIL', SQLERRM);
END $$;

-- Cleanup as postgres
DO $$
BEGIN
  DELETE FROM data.signing_submissions
  WHERE id IN (SELECT signing_submission_id FROM data.employment_contracts WHERE contract_number LIKE 'EC5-TEST-%')
     OR id IN (SELECT submission_id FROM test_ids);

  DELETE FROM data.document_versions
  WHERE document_id IN (SELECT id FROM data.documents WHERE title = 'EC5 signed stub');

  DELETE FROM data.documents
  WHERE title = 'EC5 signed stub'
     OR entity_id IN (SELECT id FROM data.employment_contracts WHERE contract_number LIKE 'EC5-TEST-%');

  DELETE FROM data.employment_contracts WHERE contract_number LIKE 'EC5-TEST-%';
  INSERT INTO test_results VALUES ('T8 cleanup', 'PASS', 'ok');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T8 cleanup', 'FAIL', SQLERRM);
END $$;

SELECT * FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  RAISE NOTICE 'M-EC-05 employment contract signing: % PASS, % FAIL',
    (SELECT count(*) FROM test_results WHERE status = 'PASS'),
    v_fail;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'M-EC-05 employment contract signing tests failed';
  END IF;
END $$;

ROLLBACK;
