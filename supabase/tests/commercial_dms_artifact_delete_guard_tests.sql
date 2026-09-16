-- Commercial DMS PDFs must not be deletable (quote stays the source of truth).
DO $$
DECLARE
  v_doc uuid;
  v_err text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  PERFORM set_config(
    'request.jwt.claim',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config('request.headers', '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}', true);

  INSERT INTO data.documents (
    tenant_id, title, entity_type, entity_id, required_permissions, created_by
  ) VALUES (
    '10000000-0000-0000-0000-000000000001'::uuid,
    'Commercial PDF guard',
    'commercial_document',
    'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'::uuid,
    '{}'::text[],
    '20000000-0000-0000-0000-000000000002'::uuid
  )
  RETURNING id INTO v_doc;

  INSERT INTO data.document_versions (
    document_id, version_number, storage_type, file_path_or_url, mime_type, created_by
  ) VALUES
    (v_doc, 1, 'external_link', 'https://example.test/v1.pdf', 'application/pdf', '20000000-0000-0000-0000-000000000002'::uuid),
    (v_doc, 2, 'external_link', 'https://example.test/v2.pdf', 'application/pdf', '20000000-0000-0000-0000-000000000002'::uuid);

  BEGIN
    PERFORM api.delete_document_latest_version(v_doc);
    RAISE EXCEPTION 'expected latest-version delete to fail';
  EXCEPTION
    WHEN others THEN
      v_err := SQLERRM;
      IF v_err IS DISTINCT FROM 'commercial_artifact_not_deletable' THEN
        RAISE EXCEPTION 'unexpected latest-version error: %', v_err;
      END IF;
  END;

  BEGIN
    PERFORM api.delete_document_all(v_doc);
    RAISE EXCEPTION 'expected delete-all to fail';
  EXCEPTION
    WHEN others THEN
      v_err := SQLERRM;
      IF v_err IS DISTINCT FROM 'commercial_artifact_not_deletable' THEN
        RAISE EXCEPTION 'unexpected delete-all error: %', v_err;
      END IF;
  END;

  IF NOT EXISTS (SELECT 1 FROM data.documents WHERE id = v_doc) THEN
    RAISE EXCEPTION 'commercial DMS document was deleted';
  END IF;
  IF (SELECT COUNT(*) FROM data.document_versions WHERE document_id = v_doc) <> 2 THEN
    RAISE EXCEPTION 'commercial DMS versions were deleted';
  END IF;

  DELETE FROM data.document_versions WHERE document_id = v_doc;
  DELETE FROM data.documents WHERE id = v_doc;

  RAISE NOTICE 'commercial DMS artifact delete guard tests passed';
END;
$$;
