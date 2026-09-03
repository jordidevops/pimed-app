-- =============================================================================
-- 20260523000007_document_delete_race_fixes.sql
--
-- Fixes de concurrencia per a les RPC de delete de documents.
--
-- Problema:
--   delete_document_latest_version i delete_document_all llegien/encuaven
--   sense bloquejar la fila pare de data.documents. Amb concorrencia, add_document_version
--   (que fa FOR UPDATE del document) podia intercalar-se i deixar fitxers orfes.
--
-- Solucio:
--   Bloqueig FOR UPDATE del document al principi de cada RPC.
--   Aquest lock serialitza:
--     - add_document_version (mateix lock FOR UPDATE)
--     - insercions per FK (KEY SHARE) sobre document_versions del mateix document
--
-- Resultat:
--   Snapshot consistent de versions mentre s'encua i s'elimina.
-- =============================================================================

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
  -- 1) Lock del document per serialitzar amb add_document_version i inserts FK.
  SELECT * INTO v_doc
  FROM data.documents
  WHERE id = p_document_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'document_not_found';
  END IF;

  -- 2) Coherencia tenant actiu (header x-tenant-id)
  v_active_tid := data.active_tenant_id();
  IF v_active_tid IS NOT NULL AND v_active_tid IS DISTINCT FROM v_doc.tenant_id THEN
    RAISE EXCEPTION 'tenant_mismatch';
  END IF;

  -- 3) Validar membresia del tenant
  IF NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'insufficient_permissions';
  END IF;

  -- 4) Carregar la versio amb numero maxim
  SELECT * INTO v_latest
  FROM data.document_versions
  WHERE document_id = p_document_id
  ORDER BY version_number DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no_versions';
  END IF;

  -- 5) Comprovar permis sobre la versio a eliminar
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

  -- 6) Verificar que no es la unica versio del document
  SELECT COUNT(*) INTO v_count
  FROM data.document_versions
  WHERE document_id = p_document_id;

  IF v_count <= 1 THEN
    RAISE EXCEPTION 'last_version_cannot_be_deleted'
      USING HINT = 'Use delete_document_all to delete the entire document';
  END IF;

  -- 7) Encuar esborrat fisic si es fitxer natiu
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

  -- 8) Eliminar versio (trigger existent audita DOCUMENT_VERSION_DELETED)
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
  -- 1) Lock del document per serialitzar amb add_document_version i inserts FK.
  SELECT * INTO v_doc
  FROM data.documents
  WHERE id = p_document_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'document_not_found';
  END IF;

  -- 2) Coherencia tenant actiu
  v_active_tid := data.active_tenant_id();
  IF v_active_tid IS NOT NULL AND v_active_tid IS DISTINCT FROM v_doc.tenant_id THEN
    RAISE EXCEPTION 'tenant_mismatch';
  END IF;

  -- 3) Validar membresia del tenant
  IF NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'insufficient_permissions';
  END IF;

  -- 4) Comprovar permis: owner/manager (global o site) o propietari de totes les versions
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

  -- 5) Encuar esborrat fisic de tots els fitxers natius
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

  -- 6) Eliminar document (CASCADE elimina versions)
  DELETE FROM data.documents WHERE id = p_document_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.delete_document_all(uuid) TO authenticated;
