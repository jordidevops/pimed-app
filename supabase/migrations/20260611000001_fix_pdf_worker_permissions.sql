-- =============================================================================
-- Migration: 20260611000001_fix_pdf_worker_permissions.sql
-- Purpose : Permisos i RPCs per a workers PDF (service_role)
--
-- Bug: els workers cridaven api.document_pdf_jobs sense GRANT a service_role.
-- Fix: GRANT a les vistes api + RPC create_document_with_version_internal.
-- =============================================================================

-- Grants per a workers que usin client api (defensa en profunditat)
GRANT SELECT, INSERT, UPDATE ON api.document_pdf_jobs   TO service_role;
GRANT SELECT, INSERT        ON api.document_pdf_events   TO service_role;
GRANT SELECT                ON api.document_versions     TO service_role;
GRANT SELECT                ON api.documents             TO service_role;

-- RPC sense check JWT per a workers (patró add_document_version_internal)
CREATE OR REPLACE FUNCTION api.create_document_with_version_internal(
  p_tenant_id        uuid,
  p_title            text,
  p_storage_type     text,
  p_file_path_or_url text,
  p_folder_id        uuid    DEFAULT NULL,
  p_mime_type        text    DEFAULT NULL,
  p_size_bytes       bigint  DEFAULT 0,
  p_created_by       uuid    DEFAULT NULL,
  p_category         text    DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_document data.documents%ROWTYPE;
  v_version  data.document_versions%ROWTYPE;
BEGIN
  IF p_storage_type NOT IN ('native', 'external_link') THEN
    RAISE EXCEPTION 'storage_type ha de ser native o external_link';
  END IF;

  INSERT INTO data.documents (
    tenant_id, folder_id, title, category, required_permissions
  )
  VALUES (
    p_tenant_id, p_folder_id, p_title, p_category, '{}'
  )
  RETURNING * INTO v_document;

  INSERT INTO data.document_versions (
    document_id, version_number, storage_type, file_path_or_url,
    mime_type, size_bytes, created_by
  )
  VALUES (
    v_document.id, 1, p_storage_type, p_file_path_or_url,
    p_mime_type, p_size_bytes, p_created_by
  )
  RETURNING * INTO v_version;

  RETURN json_build_object(
    'document', row_to_json(v_document),
    'version',  row_to_json(v_version)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_document_with_version_internal(
  uuid, text, text, text, uuid, text, bigint, uuid, text
) TO service_role;

REVOKE EXECUTE ON FUNCTION api.create_document_with_version_internal(
  uuid, text, text, text, uuid, text, bigint, uuid, text
) FROM authenticated, anon;

COMMENT ON FUNCTION api.create_document_with_version_internal IS
  'Crea document+versió sense check JWT. Exclusiu service_role (workers PDF/firma).';
