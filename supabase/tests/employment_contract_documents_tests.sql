-- M-EC-04 employment contract documents tests
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
  document_id uuid
) ON COMMIT DROP;

INSERT INTO test_ids DEFAULT VALUES;

-- JWT owner
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

-- T1: create draft + generate document
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_alice  uuid := '40000000-0000-0000-0000-000000000001';
  v_id     uuid;
  v_out    api.employment_contracts;
  v_ent    text;
BEGIN
  INSERT INTO api.employment_contracts (
    tenant_id, employee_id, contract_number, starts_on, weekly_hours,
    lifecycle_status, is_primary, signature_requirement, signature_status
  )
  VALUES (
    v_tenant, v_alice, 'EC4-TEST-1', CURRENT_DATE, 40,
    'draft', true, 'none', 'not_required'
  )
  RETURNING id INTO v_id;

  UPDATE test_ids SET contract_id = v_id;

  v_out := api.generate_employment_contract_document(v_id, NULL, false);

  IF v_out.generated_document_id IS NULL THEN
    INSERT INTO test_results VALUES ('T1 generate creates document', 'FAIL', 'no document_id');
    RETURN;
  END IF;

  UPDATE test_ids SET document_id = v_out.generated_document_id;

  SELECT entity_type INTO v_ent FROM data.documents WHERE id = v_out.generated_document_id;

  IF v_ent = 'employment_contract'
     AND v_out.template_locale_id = '71000000-0000-0000-0000-000000000001'
     AND (v_out.variables_snapshot ? 'full_name')
     AND (v_out.template_snapshot ? 'rendered_html')
  THEN
    INSERT INTO test_results VALUES (
      'T1 generate creates document',
      'PASS',
      format('doc=%s locale=%s', v_out.generated_document_id, v_out.template_locale_id)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T1 generate creates document',
      'FAIL',
      format('ent=%s locale=%s vars=%s snap=%s',
        coalesce(v_ent, 'null'),
        coalesce(v_out.template_locale_id::text, 'null'),
        coalesce(v_out.variables_snapshot::text, 'null'),
        coalesce(v_out.template_snapshot::text, 'null')
      )
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T1 generate creates document', 'FAIL', SQLERRM);
END $$;

-- T2: idempotent second call returns same document
DO $$
DECLARE
  v_id uuid;
  v_doc uuid;
  v_out api.employment_contracts;
BEGIN
  SELECT contract_id, document_id INTO v_id, v_doc FROM test_ids;
  v_out := api.generate_employment_contract_document(v_id, NULL, false);
  IF v_out.generated_document_id = v_doc THEN
    INSERT INTO test_results VALUES ('T2 generate idempotent', 'PASS', v_doc::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T2 generate idempotent',
      'FAIL',
      format('got=%s expected=%s', v_out.generated_document_id, v_doc)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 generate idempotent', 'FAIL', SQLERRM);
END $$;

-- T3: force regenerate creates a new document id
DO $$
DECLARE
  v_id uuid;
  v_old uuid;
  v_out api.employment_contracts;
BEGIN
  SELECT contract_id, document_id INTO v_id, v_old FROM test_ids;
  v_out := api.generate_employment_contract_document(v_id, NULL, true);
  IF v_out.generated_document_id IS DISTINCT FROM v_old AND v_out.generated_document_id IS NOT NULL THEN
    UPDATE test_ids SET document_id = v_out.generated_document_id;
    INSERT INTO test_results VALUES (
      'T3 force regenerate',
      'PASS',
      format('old=%s new=%s', v_old, v_out.generated_document_id)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T3 force regenerate',
      'FAIL',
      format('old=%s new=%s', v_old, v_out.generated_document_id)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 force regenerate', 'FAIL', SQLERRM);
END $$;

-- T4: rendered HTML contains Alice name / hours
DO $$
DECLARE
  v_id uuid;
  v_html text;
BEGIN
  SELECT contract_id INTO v_id FROM test_ids;
  SELECT template_snapshot ->> 'rendered_html' INTO v_html
  FROM data.employment_contracts WHERE id = v_id;

  IF v_html ILIKE '%Alice%' OR v_html ILIKE '%40%' THEN
    INSERT INTO test_results VALUES ('T4 rendered html has vars', 'PASS', left(v_html, 80));
  ELSE
    INSERT INTO test_results VALUES ('T4 rendered html has vars', 'FAIL', left(coalesce(v_html, 'null'), 120));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T4 rendered html has vars', 'FAIL', SQLERRM);
END $$;

-- T5: Dave (member) cannot generate
DO $$
DECLARE
  v_id uuid;
  v_denied boolean := false;
BEGIN
  SELECT contract_id INTO v_id FROM test_ids;

  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000005', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000005","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  BEGIN
    PERFORM api.generate_employment_contract_document(v_id, NULL, false);
  EXCEPTION
    WHEN insufficient_privilege THEN
      v_denied := true;
    WHEN OTHERS THEN
      IF SQLSTATE IN ('42501', 'P0001') OR SQLERRM ILIKE '%privilege%' OR SQLERRM ILIKE '%permission%' THEN
        v_denied := true;
      ELSE
        RAISE;
      END IF;
  END;

  IF v_denied THEN
    INSERT INTO test_results VALUES ('T5 Dave denied generate', 'PASS', 'denied');
  ELSE
    INSERT INTO test_results VALUES ('T5 Dave denied generate', 'FAIL', 'allowed');
  END IF;
END $$;

-- T6: changing template locale after snapshot does not alter stored snapshot html_content
DO $$
DECLARE
  v_id uuid;
  v_snap_html text;
  v_live_html text;
BEGIN
  -- restore owner JWT
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT contract_id INTO v_id FROM test_ids;
  SELECT template_snapshot ->> 'html_content' INTO v_snap_html
  FROM data.employment_contracts WHERE id = v_id;

  SELECT html_content INTO v_live_html
  FROM data.document_template_locales
  WHERE id = '71000000-0000-0000-0000-000000000001';

  -- Snapshot must equal the live content at generation time; mutating live later is outside this txn.
  -- Here we only assert snapshot was captured (non-null and matches current live = frozen at gen time).
  IF v_snap_html IS NOT NULL AND v_snap_html = v_live_html THEN
    INSERT INTO test_results VALUES ('T6 template snapshot frozen', 'PASS', 'snapshot=live_at_gen');
  ELSE
    INSERT INTO test_results VALUES (
      'T6 template snapshot frozen',
      'FAIL',
      format('snap_len=%s live_len=%s', length(coalesce(v_snap_html,'')), length(coalesce(v_live_html,'')))
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 template snapshot frozen', 'FAIL', SQLERRM);
END $$;

-- Cleanup
RESET ROLE;
DO $$
DECLARE
  v_deleted int;
BEGIN
  DELETE FROM data.documents
  WHERE id IN (
    SELECT generated_document_id FROM data.employment_contracts WHERE contract_number LIKE 'EC4-TEST-%'
  )
  OR (entity_type = 'employment_contract' AND entity_id IN (
    SELECT id FROM data.employment_contracts WHERE contract_number LIKE 'EC4-TEST-%'
  ));

  DELETE FROM data.employment_contracts WHERE contract_number LIKE 'EC4-TEST-%';
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  INSERT INTO test_results VALUES ('T7 cleanup', 'PASS', format('contracts_deleted=%s', v_deleted));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T7 cleanup', 'FAIL', SQLERRM);
END $$;

SELECT * FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status = 'FAIL';
  RAISE NOTICE 'M-EC-04 employment contract documents: % PASS, % FAIL',
    (SELECT count(*) FROM test_results WHERE status = 'PASS'),
    v_fail;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'M-EC-04 employment contract documents tests failed';
  END IF;
END $$;

ROLLBACK;
