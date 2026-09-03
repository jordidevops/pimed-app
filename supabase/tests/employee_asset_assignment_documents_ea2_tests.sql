-- M-EA-02 employee asset assignment documents tests
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
  ack_doc_id uuid,
  return_doc_id uuid,
  link_doc_id uuid
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
  DELETE FROM data.employee_asset_assignments
  WHERE asset_id IN (SELECT id FROM data.assets WHERE asset_tag LIKE 'EA2-%');
  DELETE FROM data.documents
  WHERE title LIKE 'EA2 link doc%'
     OR title LIKE 'Reconeixement lliurament — EA2%'
     OR title LIKE 'Devolució equipament — EA2%';
  DELETE FROM data.assets WHERE tenant_id = v_tenant AND asset_tag LIKE 'EA2-%';
  DELETE FROM data.employees WHERE tenant_id = v_tenant AND full_name = 'EA2 Docs Emp';

  INSERT INTO data.employees (tenant_id, full_name, status, weekly_hours, site_id)
  VALUES (v_tenant, 'EA2 Docs Emp', 'active', 40, v_site)
  RETURNING id INTO v_emp;

  INSERT INTO data.assets (tenant_id, site_id, name, asset_tag, status)
  VALUES (v_tenant, v_site, 'EA2 Casc', 'EA2-A', 'operational')
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

-- T1: assign + generate acknowledgment
DO $$
DECLARE
  v_emp uuid;
  v_asset uuid;
  v_asn api.employee_asset_assignments;
  v_out api.employee_asset_assignments;
  v_ent text;
  v_eid uuid;
BEGIN
  SELECT employee_id, asset_id INTO v_emp, v_asset FROM test_ids;
  v_asn := api.assign_employee_asset(v_asset, v_emp);
  UPDATE test_ids SET assignment_id = v_asn.id;

  v_out := api.generate_employee_asset_acknowledgment_document(v_asn.id, NULL, false);

  SELECT entity_type, entity_id INTO v_ent, v_eid
  FROM data.documents WHERE id = v_out.acknowledgment_document_id;

  IF v_out.acknowledgment_document_id IS NOT NULL
     AND v_ent = 'employee_asset_assignment'
     AND v_eid = v_asn.id THEN
    UPDATE test_ids SET ack_doc_id = v_out.acknowledgment_document_id;
    INSERT INTO test_results VALUES ('T1 generate acknowledgment', 'PASS', v_out.acknowledgment_document_id::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T1 generate acknowledgment', 'FAIL',
      format('doc=%s ent=%s eid=%s', v_out.acknowledgment_document_id, v_ent, v_eid)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T1 generate acknowledgment', 'FAIL', SQLERRM);
END $$;

-- T2: idempotent ack generate
DO $$
DECLARE
  v_id uuid;
  v_doc uuid;
  v_out api.employee_asset_assignments;
BEGIN
  SELECT assignment_id, ack_doc_id INTO v_id, v_doc FROM test_ids;
  v_out := api.generate_employee_asset_acknowledgment_document(v_id, NULL, false);
  IF v_out.acknowledgment_document_id = v_doc THEN
    INSERT INTO test_results VALUES ('T2 ack idempotent', 'PASS', v_doc::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T2 ack idempotent', 'FAIL',
      format('old=%s new=%s', v_doc, v_out.acknowledgment_document_id)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T2 ack idempotent', 'FAIL', SQLERRM);
END $$;

-- T3: force regenerates new ack doc
DO $$
DECLARE
  v_id uuid;
  v_old uuid;
  v_out api.employee_asset_assignments;
BEGIN
  SELECT assignment_id, ack_doc_id INTO v_id, v_old FROM test_ids;
  v_out := api.generate_employee_asset_acknowledgment_document(v_id, NULL, true);
  IF v_out.acknowledgment_document_id IS NOT NULL
     AND v_out.acknowledgment_document_id IS DISTINCT FROM v_old THEN
    UPDATE test_ids SET ack_doc_id = v_out.acknowledgment_document_id;
    INSERT INTO test_results VALUES ('T3 ack force regenerate', 'PASS', v_out.acknowledgment_document_id::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T3 ack force regenerate', 'FAIL',
      format('old=%s new=%s', v_old, v_out.acknowledgment_document_id)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T3 ack force regenerate', 'FAIL', SQLERRM);
END $$;

-- T4: return then generate return document
DO $$
DECLARE
  v_asset uuid;
  v_id uuid;
  v_out api.employee_asset_assignments;
  v_ent text;
BEGIN
  SELECT asset_id, assignment_id INTO v_asset, v_id FROM test_ids;
  PERFORM api.return_employee_asset(v_asset, 'good', NULL, 'ea2 return');
  v_out := api.generate_employee_asset_return_document(v_id, NULL, false);

  SELECT entity_type INTO v_ent FROM data.documents WHERE id = v_out.return_document_id;

  IF v_out.return_document_id IS NOT NULL AND v_ent = 'employee_asset_assignment' THEN
    UPDATE test_ids SET return_doc_id = v_out.return_document_id;
    INSERT INTO test_results VALUES ('T4 generate return doc', 'PASS', v_out.return_document_id::text);
  ELSE
    INSERT INTO test_results VALUES (
      'T4 generate return doc', 'FAIL',
      format('doc=%s ent=%s', v_out.return_document_id, v_ent)
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T4 generate return doc', 'FAIL', SQLERRM);
END $$;

-- T5: return generate before close → assignment_not_returned
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_site uuid := '30000000-0000-0000-0000-000000000001';
  v_emp uuid;
  v_asset uuid;
  v_asn api.employee_asset_assignments;
BEGIN
  SELECT employee_id INTO v_emp FROM test_ids;

  INSERT INTO data.assets (tenant_id, site_id, name, asset_tag, status)
  VALUES (v_tenant, v_site, 'EA2 Casc Open', 'EA2-B', 'operational')
  RETURNING id INTO v_asset;

  v_asn := api.assign_employee_asset(v_asset, v_emp);

  BEGIN
    PERFORM api.generate_employee_asset_return_document(v_asn.id, NULL, false);
    INSERT INTO test_results VALUES ('T5 return doc requires closed', 'FAIL', 'expected error');
  EXCEPTION
    WHEN check_violation THEN
      IF SQLERRM LIKE '%assignment_not_returned%' THEN
        INSERT INTO test_results VALUES ('T5 return doc requires closed', 'PASS', SQLERRM);
      ELSE
        INSERT INTO test_results VALUES ('T5 return doc requires closed', 'FAIL', SQLERRM);
      END IF;
    WHEN OTHERS THEN
      INSERT INTO test_results VALUES ('T5 return doc requires closed', 'FAIL', SQLERRM);
  END;
END $$;

-- T6: link acknowledgment (fresh open assignment)
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_site uuid := '30000000-0000-0000-0000-000000000001';
  v_emp uuid;
  v_asset uuid;
  v_asn api.employee_asset_assignments;
  v_doc uuid;
  v_out api.employee_asset_assignments;
BEGIN
  SELECT employee_id INTO v_emp FROM test_ids;

  INSERT INTO data.assets (tenant_id, site_id, name, asset_tag, status)
  VALUES (v_tenant, v_site, 'EA2 Casc Link', 'EA2-C', 'operational')
  RETURNING id INTO v_asset;

  v_asn := api.assign_employee_asset(v_asset, v_emp);

  INSERT INTO data.documents (tenant_id, site_id, title, category, required_permissions, created_by)
  VALUES (
    v_tenant, v_site, 'EA2 link doc ack', 'safety',
    ARRAY['owner', 'manager'],
    '20000000-0000-0000-0000-000000000002'
  )
  RETURNING id INTO v_doc;

  v_out := api.link_employee_asset_acknowledgment_document(v_asn.id, v_doc);

  IF v_out.acknowledgment_document_id = v_doc THEN
    UPDATE test_ids SET link_doc_id = v_doc;
    INSERT INTO test_results VALUES ('T6 link acknowledgment', 'PASS', v_doc::text);
  ELSE
    INSERT INTO test_results VALUES ('T6 link acknowledgment', 'FAIL', coalesce(v_out.acknowledgment_document_id::text, 'null'));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T6 link acknowledgment', 'FAIL', SQLERRM);
END $$;

-- T7: member without manage → insufficient_privilege (fresh open assignment)
DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000001';
  v_site uuid := '30000000-0000-0000-0000-000000000001';
  v_emp uuid;
  v_asset uuid;
  v_asn api.employee_asset_assignments;
BEGIN
  SELECT employee_id INTO v_emp FROM test_ids;

  INSERT INTO data.assets (tenant_id, site_id, name, asset_tag, status)
  VALUES (v_tenant, v_site, 'EA2 Casc Priv', 'EA2-D', 'operational')
  RETURNING id INTO v_asset;

  v_asn := api.assign_employee_asset(v_asset, v_emp);

  -- Dave (member) — mateix patró que EC-4 T5
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000005', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000005","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":[],"sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  BEGIN
    PERFORM api.generate_employee_asset_acknowledgment_document(v_asn.id, NULL, false);
    INSERT INTO test_results VALUES ('T7 privilege denied', 'FAIL', 'expected insufficient_privilege');
  EXCEPTION
    WHEN insufficient_privilege THEN
      INSERT INTO test_results VALUES ('T7 privilege denied', 'PASS', SQLERRM);
    WHEN OTHERS THEN
      IF SQLSTATE IN ('42501', 'P0001') OR SQLERRM ILIKE '%privilege%' OR SQLERRM ILIKE '%permission%' THEN
        INSERT INTO test_results VALUES ('T7 privilege denied', 'PASS', SQLERRM);
      ELSE
        INSERT INTO test_results VALUES ('T7 privilege denied', 'FAIL', SQLERRM);
      END IF;
  END;

  -- restore owner JWT
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}},"user_permissions":{"10000000-0000-0000-0000-000000000001":{"global_permissions":["*"],"sites":{}}}}}',
    true
  );
END $$;

-- T8: rendered ack HTML contains employee + asset
DO $$
DECLARE
  v_doc uuid;
  v_path text;
  v_html text;
  v_vars jsonb;
BEGIN
  SELECT ack_doc_id INTO v_doc FROM test_ids;
  -- Re-generate with force to capture via audit is hard; instead re-render vars
  SELECT data.render_employee_asset_assignment_html(
    (SELECT html_content FROM data.document_template_locales
     WHERE id = data.default_asset_acknowledgment_template_locale_id()),
    data.build_employee_asset_assignment_variables(
      (SELECT a FROM data.employee_asset_assignments a WHERE a.id = (SELECT assignment_id FROM test_ids)),
      'acknowledgment'
    )
  ) INTO v_html;

  IF v_html LIKE '%EA2 Docs Emp%' AND v_html LIKE '%EA2 Casc%' THEN
    INSERT INTO test_results VALUES ('T8 rendered ack html', 'PASS', left(v_html, 120));
  ELSE
    INSERT INTO test_results VALUES ('T8 rendered ack html', 'FAIL', left(coalesce(v_html, 'null'), 200));
  END IF;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO test_results VALUES ('T8 rendered ack html', 'FAIL', SQLERRM);
END $$;

SELECT test_name, status, details FROM test_results ORDER BY test_name;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM test_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'EA-2 tests failed: %', v_fail;
  END IF;
END $$;

ROLLBACK;
