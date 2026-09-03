-- =============================================================================
-- 20260524000001_add_document_version_internal.sql
--
-- Funció auxiliar sense check de rol per al webhook DocuSeal.
--
-- Context:
--   El webhook docuseal-webhook usa createAdminClient() (service_role).
--   La RPC existent api.add_document_version comprova jwt_user_tenants() per
--   garantir que l'usuari és owner/manager. Però amb service_role no hi ha
--   JWT d'usuari → jwt_user_tenants() retorna '{}' → accés denegat.
--
-- Solució:
--   Nova funció api.add_document_version_internal idèntica a add_document_version
--   però sense el check de jwt_user_tenants().
--
-- Seguretat:
--   - GRANT EXECUTE exclusivament a service_role (no a authenticated ni anon)
--   - REVOKE explícit de authenticated i anon
--   - No accessible via client d'usuari (la RPC no apareix als rols no privilegiats)
-- =============================================================================

CREATE OR REPLACE FUNCTION api.add_document_version_internal(
  p_document_id      uuid,
  p_file_path_or_url text,
  p_mime_type        text,
  p_size_bytes       bigint,
  p_storage_type     text DEFAULT 'native'
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_doc          data.documents%ROWTYPE;
  v_next_version int;
  v_version      data.document_versions%ROWTYPE;
BEGIN
  IF p_storage_type NOT IN ('native', 'external_link') THEN
    RAISE EXCEPTION 'storage_type ha de ser native o external_link';
  END IF;

  -- Serialitzar amb FOR UPDATE per evitar race conditions en insercions concurrents
  SELECT * INTO v_doc
  FROM data.documents
  WHERE id = p_document_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Document % no trobat', p_document_id;
  END IF;

  -- Nota: NO es comprova jwt_user_tenants() perquè aquesta funció
  -- és exclusivament per a crides de sistema (webhook, service_role).

  SELECT COALESCE(MAX(version_number), 0) + 1
  INTO v_next_version
  FROM data.document_versions
  WHERE document_id = p_document_id;

  INSERT INTO data.document_versions (
    document_id, version_number, storage_type, file_path_or_url,
    mime_type, size_bytes
    -- created_by és NULL: acció de sistema, no d'usuari
  )
  VALUES (
    p_document_id, v_next_version, p_storage_type, p_file_path_or_url,
    p_mime_type, p_size_bytes
  )
  RETURNING * INTO v_version;

  RETURN row_to_json(v_version);
END;
$$;

-- Accessible únicament per service_role (webhook)
GRANT EXECUTE ON FUNCTION api.add_document_version_internal TO service_role;

-- Revocar explícitament d'usuaris autenticats i anons per seguretat
REVOKE EXECUTE ON FUNCTION api.add_document_version_internal FROM authenticated;
REVOKE EXECUTE ON FUNCTION api.add_document_version_internal FROM anon;
