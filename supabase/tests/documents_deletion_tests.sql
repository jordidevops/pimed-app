-- =============================================================================
-- Documents Deletion Tests
-- =============================================================================
-- Coverage:
--   T1 site manager can delete latest version when >=2 versions exist
--   T2 delete latest rejects single-version document with domain error
--   T3 non-manager owner of all versions can delete full document
--   T4 owner-of-all path is blocked when any version has created_by NULL
--   T5 tenant mismatch is rejected
--   T6 regression guard: delete RPCs keep FOR UPDATE lock
-- =============================================================================

BEGIN;
SET LOCAL ROLE authenticated;

CREATE TEMP TABLE test_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

-- -----------------------------------------------------------------------------
-- T1: site manager can delete latest version
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_doc_id    uuid;
  v_v1_id     uuid;
  v_v2_id     uuid;
  v_count     integer := 0;
  v_max_ver   integer := 0;
BEGIN
  -- Seed as global owner
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  INSERT INTO data.documents (tenant_id, site_id, title, required_permissions, created_by)
  VALUES (
    '10000000-0000-0000-0000-000000000001'::uuid,
    '30000000-0000-0000-0000-000000000001'::uuid,
    'T1 delete latest by site manager',
    '{}'::text[],
    '20000000-0000-0000-0000-000000000002'::uuid
  )
  RETURNING id INTO v_doc_id;

  INSERT INTO data.document_versions (
    document_id, version_number, storage_type, file_path_or_url, created_by
  ) VALUES (
    v_doc_id,
    1,
    'native',
    '10000000-0000-0000-0000-000000000001/t1/v1.pdf',
    '20000000-0000-0000-0000-000000000002'::uuid
  ) RETURNING id INTO v_v1_id;

  INSERT INTO data.document_versions (
    document_id, version_number, storage_type, file_path_or_url, created_by
  ) VALUES (
    v_doc_id,
    2,
    'native',
    '10000000-0000-0000-0000-000000000001/t1/v2.pdf',
    '20000000-0000-0000-0000-000000000002'::uuid
  ) RETURNING id INTO v_v2_id;

  -- Execute as site manager with no global manager role
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000004', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000004","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{"30000000-0000-0000-0000-000000000001":"manager"}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  PERFORM api.delete_document_latest_version(v_doc_id);

  SELECT COUNT(*), COALESCE(MAX(version_number), 0)
  INTO v_count, v_max_ver
  FROM data.document_versions
  WHERE document_id = v_doc_id;

  IF v_count = 1 AND v_max_ver = 1 THEN
    INSERT INTO test_results VALUES (
      'T1 site manager delete latest',
      'PASS',
      format('remaining_versions=%s max_version=%s', v_count, v_max_ver)
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T1 site manager delete latest',
      'FAIL',
      format('Expected remaining_versions=1 max_version=1; got remaining_versions=%s max_version=%s', v_count, v_max_ver)
    );
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T2: deleting latest of single-version document is rejected
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_doc_id     uuid;
  v_is_domain  boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  INSERT INTO data.documents (tenant_id, title, required_permissions, created_by)
  VALUES (
    '10000000-0000-0000-0000-000000000001'::uuid,
    'T2 single version guarded',
    '{}'::text[],
    '20000000-0000-0000-0000-000000000002'::uuid
  )
  RETURNING id INTO v_doc_id;

  INSERT INTO data.document_versions (
    document_id, version_number, storage_type, file_path_or_url, created_by
  ) VALUES (
    v_doc_id,
    1,
    'native',
    '10000000-0000-0000-0000-000000000001/t2/v1.pdf',
    '20000000-0000-0000-0000-000000000002'::uuid
  );

  BEGIN
    PERFORM api.delete_document_latest_version(v_doc_id);
  EXCEPTION
    WHEN OTHERS THEN
      v_is_domain := position('last_version_cannot_be_deleted' in SQLERRM) > 0;
  END;

  IF v_is_domain THEN
    INSERT INTO test_results VALUES (
      'T2 single-version latest delete denied',
      'PASS',
      'last_version_cannot_be_deleted raised'
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T2 single-version latest delete denied',
      'FAIL',
      'Expected last_version_cannot_be_deleted'
    );
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T3: member owning all versions can delete whole document
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_doc_id      uuid;
  v_doc_exists  integer := 0;
BEGIN
  -- Seed as owner, but set created_by for versions to member user 0004
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  INSERT INTO data.documents (tenant_id, title, required_permissions, created_by)
  VALUES (
    '10000000-0000-0000-0000-000000000001'::uuid,
    'T3 owner-of-all can delete all',
    '{}'::text[],
    '20000000-0000-0000-0000-000000000004'::uuid
  )
  RETURNING id INTO v_doc_id;

  INSERT INTO data.document_versions (
    document_id, version_number, storage_type, file_path_or_url, created_by
  ) VALUES
  (
    v_doc_id,
    1,
    'native',
    '10000000-0000-0000-0000-000000000001/t3/v1.pdf',
    '20000000-0000-0000-0000-000000000004'::uuid
  ),
  (
    v_doc_id,
    2,
    'native',
    '10000000-0000-0000-0000-000000000001/t3/v2.pdf',
    '20000000-0000-0000-0000-000000000004'::uuid
  );

  -- Member (not manager) but owner of all versions
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000004', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000004","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  PERFORM api.delete_document_all(v_doc_id);

  SELECT COUNT(*) INTO v_doc_exists
  FROM data.documents
  WHERE id = v_doc_id;

  IF v_doc_exists = 0 THEN
    INSERT INTO test_results VALUES (
      'T3 owner-of-all delete all',
      'PASS',
      'Document deleted by non-manager owner-of-all'
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T3 owner-of-all delete all',
      'FAIL',
      format('Document still exists: rows=%s', v_doc_exists)
    );
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T4: owner-of-all path blocked if one version has created_by NULL
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_doc_id      uuid;
  v_denied      boolean := false;
  v_doc_exists  integer := 0;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  INSERT INTO data.documents (tenant_id, title, required_permissions, created_by)
  VALUES (
    '10000000-0000-0000-0000-000000000001'::uuid,
    'T4 null creator blocks owner-of-all',
    '{}'::text[],
    '20000000-0000-0000-0000-000000000004'::uuid
  )
  RETURNING id INTO v_doc_id;

  INSERT INTO data.document_versions (
    document_id, version_number, storage_type, file_path_or_url, created_by
  ) VALUES
  (
    v_doc_id,
    1,
    'native',
    '10000000-0000-0000-0000-000000000001/t4/v1.pdf',
    '20000000-0000-0000-0000-000000000004'::uuid
  ),
  (
    v_doc_id,
    2,
    'native',
    '10000000-0000-0000-0000-000000000001/t4/v2.pdf',
    NULL
  );

  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000004', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000004","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"member","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  BEGIN
    PERFORM api.delete_document_all(v_doc_id);
  EXCEPTION
    WHEN OTHERS THEN
      v_denied := position('insufficient_permissions' in SQLERRM) > 0;
  END;

  SELECT COUNT(*) INTO v_doc_exists
  FROM data.documents
  WHERE id = v_doc_id;

  IF v_denied AND v_doc_exists = 1 THEN
    INSERT INTO test_results VALUES (
      'T4 null created_by blocks owner-of-all',
      'PASS',
      'insufficient_permissions raised and document preserved'
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T4 null created_by blocks owner-of-all',
      'FAIL',
      format('Expected denied=true and doc_exists=1; got denied=%s doc_exists=%s', v_denied, v_doc_exists)
    );
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T5: tenant mismatch is rejected
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_doc_id      uuid;
  v_mismatch    boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}},"10000000-0000-0000-0000-000000000002":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  INSERT INTO data.documents (tenant_id, title, required_permissions, created_by)
  VALUES (
    '10000000-0000-0000-0000-000000000001'::uuid,
    'T5 tenant mismatch',
    '{}'::text[],
    '20000000-0000-0000-0000-000000000002'::uuid
  )
  RETURNING id INTO v_doc_id;

  INSERT INTO data.document_versions (
    document_id, version_number, storage_type, file_path_or_url, created_by
  ) VALUES (
    v_doc_id,
    1,
    'native',
    '10000000-0000-0000-0000-000000000001/t5/v1.pdf',
    '20000000-0000-0000-0000-000000000002'::uuid
  );

  -- Switch to different active tenant header while still having membership
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000002"}', true);

  BEGIN
    PERFORM api.delete_document_all(v_doc_id);
  EXCEPTION
    WHEN OTHERS THEN
      v_mismatch := position('tenant_mismatch' in SQLERRM) > 0;
  END;

  IF v_mismatch THEN
    INSERT INTO test_results VALUES (
      'T5 tenant mismatch guard',
      'PASS',
      'tenant_mismatch raised'
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T5 tenant mismatch guard',
      'FAIL',
      'Expected tenant_mismatch'
    );
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- T6: regression guard for FOR UPDATE lock in both delete RPCs
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_latest_def text;
  v_all_def    text;
  v_has_lock   boolean := false;
BEGIN
  SELECT pg_get_functiondef('api.delete_document_latest_version(uuid)'::regprocedure)
    INTO v_latest_def;
  SELECT pg_get_functiondef('api.delete_document_all(uuid)'::regprocedure)
    INTO v_all_def;

  v_has_lock := (position('FOR UPDATE' in upper(v_latest_def)) > 0)
             AND (position('FOR UPDATE' in upper(v_all_def)) > 0);

  IF v_has_lock THEN
    INSERT INTO test_results VALUES (
      'T6 delete RPC lock regression guard',
      'PASS',
      'FOR UPDATE present in both function definitions'
    );
  ELSE
    INSERT INTO test_results VALUES (
      'T6 delete RPC lock regression guard',
      'FAIL',
      'FOR UPDATE missing in at least one delete RPC'
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
