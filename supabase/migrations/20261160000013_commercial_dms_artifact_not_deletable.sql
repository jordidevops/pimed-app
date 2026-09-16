-- Commercial PDF in DMS is an artifact of an immutable commercial_document.
-- Deleting it would SET NULL rendered_document_id and leave the quote without a file.

CREATE OR REPLACE FUNCTION data.assert_not_commercial_dms_artifact(p_entity_type text)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  IF p_entity_type = 'commercial_document' THEN
    RAISE EXCEPTION 'commercial_artifact_not_deletable' USING ERRCODE = 'P0001';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION api.delete_document_latest_version(
  p_document_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_doc        data.documents%ROWTYPE;
  v_latest     data.document_versions%ROWTYPE;
  v_count      int;
  v_active_tid uuid;
BEGIN
  SELECT * INTO v_doc
  FROM data.documents
  WHERE id = p_document_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'document_not_found';
  END IF;

  v_active_tid := data.active_tenant_id();
  IF v_active_tid IS NOT NULL AND v_active_tid IS DISTINCT FROM v_doc.tenant_id THEN
    RAISE EXCEPTION 'tenant_mismatch';
  END IF;

  IF NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'insufficient_permissions';
  END IF;

  PERFORM data.assert_not_commercial_dms_artifact(v_doc.entity_type);

  SELECT * INTO v_latest
  FROM data.document_versions
  WHERE document_id = p_document_id
  ORDER BY version_number DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no_versions';
  END IF;

  IF NOT (
    (data.jwt_user_tenants() -> v_doc.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    OR (
      v_doc.site_id IS NOT NULL
      AND (data.jwt_user_tenants() -> v_doc.tenant_id::text -> 'sites' ->> v_doc.site_id::text)
          IN ('owner', 'manager')
    )
    OR v_latest.created_by = auth.uid()
  ) THEN
    RAISE EXCEPTION 'insufficient_permissions';
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM data.document_versions
  WHERE document_id = p_document_id;

  IF v_count <= 1 THEN
    RAISE EXCEPTION 'last_version_cannot_be_deleted'
      USING HINT = 'Use delete_document_all to delete the entire document';
  END IF;

  IF v_latest.storage_type = 'native'
     AND v_latest.file_path_or_url IS NOT NULL
     AND v_latest.file_path_or_url LIKE (v_doc.tenant_id::text || '/%')
  THEN
    PERFORM pgmq.send('trash_deletion_queue', jsonb_build_object(
      'tenant_id',           v_doc.tenant_id,
      'idempotency_key',     'doc-ver-del-' || v_latest.id::text,
      'file_node_id',        v_latest.id,
      'storage_provider_id', NULL,
      'storage_key',         v_latest.file_path_or_url,
      'bucket',              'documents'
    ));
  END IF;

  DELETE FROM data.document_versions WHERE id = v_latest.id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.delete_document_latest_version(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION api.delete_document_all(
  p_document_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_doc        data.documents%ROWTYPE;
  v_active_tid uuid;
  v_ver        data.document_versions%ROWTYPE;
  v_all_own    boolean;
BEGIN
  SELECT * INTO v_doc
  FROM data.documents
  WHERE id = p_document_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'document_not_found';
  END IF;

  v_active_tid := data.active_tenant_id();
  IF v_active_tid IS NOT NULL AND v_active_tid IS DISTINCT FROM v_doc.tenant_id THEN
    RAISE EXCEPTION 'tenant_mismatch';
  END IF;

  IF NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'insufficient_permissions';
  END IF;

  PERFORM data.assert_not_commercial_dms_artifact(v_doc.entity_type);

  IF NOT (
    (data.jwt_user_tenants() -> v_doc.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    OR (
      v_doc.site_id IS NOT NULL
      AND (data.jwt_user_tenants() -> v_doc.tenant_id::text -> 'sites' ->> v_doc.site_id::text)
          IN ('owner', 'manager')
    )
  ) THEN
    SELECT bool_and(COALESCE(created_by = auth.uid(), false)) INTO v_all_own
    FROM data.document_versions
    WHERE document_id = p_document_id;

    IF NOT COALESCE(v_all_own, false) THEN
      RAISE EXCEPTION 'insufficient_permissions';
    END IF;
  END IF;

  FOR v_ver IN
    SELECT *
    FROM data.document_versions
    WHERE document_id = p_document_id
      AND storage_type = 'native'
      AND file_path_or_url IS NOT NULL
      AND file_path_or_url LIKE (v_doc.tenant_id::text || '/%')
  LOOP
    PERFORM pgmq.send('trash_deletion_queue', jsonb_build_object(
      'tenant_id',           v_doc.tenant_id,
      'idempotency_key',     'doc-ver-del-' || v_ver.id::text,
      'file_node_id',        v_ver.id,
      'storage_provider_id', NULL,
      'storage_key',         v_ver.file_path_or_url,
      'bucket',              'documents'
    ));
  END LOOP;

  DELETE FROM data.documents WHERE id = p_document_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.delete_document_all(uuid) TO authenticated;
