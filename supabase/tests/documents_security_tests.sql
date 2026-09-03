-- =============================================================================
-- Documents Security Tests
-- =============================================================================
-- Cobertura:
--   T1 RLS read: rol global + rol site intersecten correctament required_permissions
--   T2 RLS write versions: site manager pot UPDATE/DELETE versions
--   T3 Integritat: document.folder_id no pot creuar tenant/site
--   T4 RPC: create_document_with_version retorna JSON complet (document + version)
-- =============================================================================

BEGIN;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

-- -----------------------------------------------------------------------------
-- T1: rol global + rol site (cas mixt)
-- Esperat: amb global_role=member i site_role=manager, un recurs que requereix
--          'manager' ha de ser visible al site corresponent.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_count integer := 0;
BEGIN
  -- Setup amb owner per crear la dada de prova
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  INSERT INTO data.documents (
    tenant_id, site_id, title, required_permissions
  )
  VALUES (
    '10000000-0000-0000-0000-000000000001'::uuid,
    '30000000-0000-0000-0000-000000000001'::uuid,
    'T1 Mixed role visibility',
    ARRAY['manager']::text[]
  );

  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000004', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000004","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{"30000000-0000-0000-0000-000000000001":"manager"}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT COUNT(*) INTO v_count
  FROM data.documents
  WHERE title = 'T1 Mixed role visibility';

  IF v_count = 1 THEN
    INSERT INTO test_results VALUES (
      'T1 mixed global+site role read',
      'PASS',
      format('rows=%s', v_count)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T1 mixed global+site role read',
      'FAIL',
      format('Expected rows=1, got rows=%s', v_count)
    );
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T2: site manager pot UPDATE/DELETE versions
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_doc_id            uuid;
  v_ver_id            uuid;
  v_update_rows       integer := 0;
  v_delete_rows       integer := 0;
BEGIN
  -- Inserció amb perfil owner per preparar dades
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  INSERT INTO data.documents (tenant_id, site_id, title, required_permissions)
  VALUES (
    '10000000-0000-0000-0000-000000000001'::uuid,
    '30000000-0000-0000-0000-000000000001'::uuid,
    'T2 Version permissions',
    '{}'::text[]
  )
  RETURNING id INTO v_doc_id;

  INSERT INTO data.document_versions (
    document_id, version_number, storage_type, file_path_or_url, created_by
  )
  VALUES (
    v_doc_id, 1, 'native', 'docs/t2-v1.pdf', '20000000-0000-0000-0000-000000000002'::uuid
  )
  RETURNING id INTO v_ver_id;

  -- Ara provem amb manager del site i sense rol global
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000004', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000004","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":null,"sites":{"30000000-0000-0000-0000-000000000001":"manager"}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  UPDATE data.document_versions
  SET mime_type = 'application/pdf'
  WHERE id = v_ver_id;
  GET DIAGNOSTICS v_update_rows = ROW_COUNT;

  DELETE FROM data.document_versions
  WHERE id = v_ver_id;
  GET DIAGNOSTICS v_delete_rows = ROW_COUNT;

  IF v_update_rows = 1 AND v_delete_rows = 1 THEN
    INSERT INTO test_results VALUES (
      'T2 site manager update/delete versions',
      'PASS',
      format('update_rows=%s, delete_rows=%s', v_update_rows, v_delete_rows)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T2 site manager update/delete versions',
      'FAIL',
      format('Expected update_rows=1 and delete_rows=1; got update_rows=%s, delete_rows=%s', v_update_rows, v_delete_rows)
    );
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T3: integritat folder-document (tenant/site)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_folder_id uuid;
  v_denied    boolean := false;
BEGIN
  -- Crear carpeta en tenant ACME
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );

  INSERT INTO data.document_folders (tenant_id, site_id, name)
  VALUES (
    '10000000-0000-0000-0000-000000000001'::uuid,
    NULL,
    'T3 Folder ACME'
  )
  RETURNING id INTO v_folder_id;

  -- Intentar crear document a un altre tenant amb folder ACME (ha de fallar)
  BEGIN
    INSERT INTO data.documents (tenant_id, site_id, folder_id, title, required_permissions)
    VALUES (
      '10000000-0000-0000-0000-000000000002'::uuid,
      NULL,
      v_folder_id,
      'T3 Cross tenant should fail',
      '{}'::text[]
    );
  EXCEPTION
    WHEN OTHERS THEN
      v_denied := true;
  END;

  IF v_denied THEN
    INSERT INTO test_results VALUES (
      'T3 folder-document tenant/site consistency',
      'PASS',
      'Cross-tenant folder reference blocked'
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T3 folder-document tenant/site consistency',
      'FAIL',
      'Expected exception for cross-tenant folder reference'
    );
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T4: RPC retorna JSON complet
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_out         jsonb;
  v_has_doc     boolean := false;
  v_has_ver     boolean := false;
  v_has_doc_id  boolean := false;
  v_has_ver_id  boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  SELECT api.create_document_with_version(
    p_tenant_id        => '10000000-0000-0000-0000-000000000001'::uuid,
    p_title            => 'T4 RPC document',
    p_storage_type     => 'native',
    p_file_path_or_url => 'docs/t4-v1.pdf',
    p_site_id          => '30000000-0000-0000-0000-000000000001'::uuid,
    p_required_permissions => ARRAY['member']::text[]
  )
  INTO v_out;

  v_has_doc := (v_out ? 'document');
  v_has_ver := (v_out ? 'version');
  v_has_doc_id := (v_out -> 'document' ->> 'id') IS NOT NULL;
  v_has_ver_id := (v_out -> 'version' ->> 'id') IS NOT NULL;

  IF v_has_doc AND v_has_ver AND v_has_doc_id AND v_has_ver_id THEN
    INSERT INTO test_results VALUES (
      'T4 RPC returns full payload',
      'PASS',
      'Keys document/version present with ids'
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T4 RPC returns full payload',
      'FAIL',
      format('doc=%s ver=%s doc_id=%s ver_id=%s', v_has_doc, v_has_ver, v_has_doc_id, v_has_ver_id)
    );
  END IF;
END $$;

SELECT test_name, status, details
FROM test_results
ORDER BY test_name;

SELECT
  COUNT(*) FILTER (WHERE status = 'PASS') AS pass_count,
  COUNT(*) FILTER (WHERE status = 'FAIL') AS fail_count,
  COUNT(*)                                 AS total_count
FROM test_results;

ROLLBACK;
