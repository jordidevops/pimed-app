-- =============================================================================
-- 20260520000001_document_delete_rpcs.sql
--
-- Eliminació de documents i versions al mòdul DMS.
--
-- Canvis:
--   1. Afegeix data.documents.created_by + backfill des de primera versió
--   2. Actualitza api.create_document_with_version per escriure created_by
--   3. Amplia la policy "documents: delete" per permetre al creador eliminar
--   4. Recrea api.active_documents afegint d.created_by (preserva shape existent)
--   5. RPC api.delete_document_latest_version — elimina la darrera versió
--   6. RPC api.delete_document_all — elimina document + totes les versions
--
-- Seguretat:
--   - RPCs SECURITY DEFINER SET search_path = ''
--   - Validació explícita: tenant_membership + rol (global/site) o creador
--   - Prefix validation de storage_key (defense-in-depth cross-tenant)
--   - Reutilitza trash_deletion_queue amb camp bucket='documents'
--
-- Atomicitat:
--   - Transacció BD + pgmq.send atòmics (mateixa transacció PL/pgSQL)
--   - Esborrat físic de Storage gestionat pel worker process-deletion-queue
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Afegir created_by a data.documents + backfill des de primera versió
-- ---------------------------------------------------------------------------

ALTER TABLE data.documents
  ADD COLUMN IF NOT EXISTS created_by uuid
    REFERENCES data.profiles(id) ON DELETE SET NULL;

-- Backfill: primera versió amb created_by no nul de cada document
UPDATE data.documents d
SET created_by = (
  SELECT v.created_by
  FROM data.document_versions v
  WHERE v.document_id = d.id
    AND v.created_by IS NOT NULL
  ORDER BY v.version_number ASC
  LIMIT 1
)
WHERE d.created_by IS NULL;

-- ---------------------------------------------------------------------------
-- 2) Actualitzar api.create_document_with_version per escriure created_by
--    Mantenim search_path = data, public (igual que l'original)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.create_document_with_version(
  p_tenant_id uuid,
  p_title text,
  p_storage_type text,
  p_file_path_or_url text,
  p_site_id uuid DEFAULT NULL,
  p_folder_id uuid DEFAULT NULL,
  p_entity_type varchar DEFAULT NULL,
  p_entity_id uuid DEFAULT NULL,
  p_required_permissions text[] DEFAULT '{}',
  p_mime_type text DEFAULT NULL,
  p_size_bytes bigint DEFAULT 0,
  p_valid_from timestamptz DEFAULT NULL,
  p_expires_at timestamptz DEFAULT NULL,
  p_renewal_interval_months int DEFAULT NULL,
  p_renewal_anchor_mode varchar DEFAULT NULL,
  p_renewal_anchor_month smallint DEFAULT NULL,
  p_renewal_anchor_day smallint DEFAULT NULL
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
  IF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (
      (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR (
        p_site_id IS NOT NULL
        AND (data.jwt_user_tenants() -> p_tenant_id::text -> 'sites' ->> p_site_id::text) IN ('owner', 'manager')
      )
    )
  ) THEN
    RAISE EXCEPTION 'Access denied: owner or manager role required';
  END IF;

  INSERT INTO data.documents (
    tenant_id, site_id, folder_id, title, entity_type, entity_id,
    required_permissions,
    valid_from, expires_at,
    renewal_interval_months, renewal_anchor_mode,
    renewal_anchor_month, renewal_anchor_day,
    created_by
  )
  VALUES (
    p_tenant_id, p_site_id, p_folder_id, p_title, p_entity_type, p_entity_id,
    p_required_permissions,
    p_valid_from, p_expires_at,
    p_renewal_interval_months, p_renewal_anchor_mode,
    p_renewal_anchor_month, p_renewal_anchor_day,
    auth.uid()
  )
  RETURNING * INTO v_document;

  INSERT INTO data.document_versions (
    document_id, version_number, storage_type, file_path_or_url,
    mime_type, size_bytes, created_by
  )
  VALUES (
    v_document.id, 1, p_storage_type, p_file_path_or_url,
    p_mime_type, p_size_bytes, auth.uid()
  )
  RETURNING * INTO v_version;

  RETURN json_build_object(
    'document', row_to_json(v_document),
    'version', row_to_json(v_version)
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- 3) Ampliar "documents: delete" perquè el creador del document pugui eliminar
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS "documents: delete" ON data.documents;

CREATE POLICY "documents: delete" ON data.documents
  FOR DELETE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR created_by = auth.uid()
    )
  );

-- ---------------------------------------------------------------------------
-- 4) Recrear api.active_documents afegint d.created_by (preserva shape existent)
--    Ordre de columnes: metadades doc → created_by → expiry → timestamps → versió
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS api.active_documents;

CREATE VIEW api.active_documents WITH (security_invoker = true) AS
  SELECT
    d.id,
    d.tenant_id,
    d.site_id,
    d.folder_id,
    d.title,
    d.entity_type,
    d.entity_id,
    d.required_permissions,
    d.created_by,
    d.valid_from,
    d.expires_at,
    d.renewal_interval_months,
    d.renewal_anchor_mode,
    d.renewal_anchor_month,
    d.renewal_anchor_day,
    d.created_at,
    d.updated_at,
    v.id             AS version_id,
    v.version_number,
    v.storage_type,
    v.file_path_or_url,
    v.mime_type,
    v.size_bytes,
    v.created_by     AS version_created_by,
    v.created_at     AS version_created_at
  FROM data.documents d
  JOIN (
    SELECT document_id, MAX(version_number) AS version_number
    FROM data.document_versions
    GROUP BY document_id
  ) mx ON d.id = mx.document_id
  JOIN data.document_versions v
    ON d.id = v.document_id AND mx.version_number = v.version_number;

GRANT SELECT ON api.active_documents TO authenticated;
GRANT SELECT ON api.active_documents TO service_role;

-- ---------------------------------------------------------------------------
-- 5) RPC api.delete_document_latest_version
--
--    Elimina la versió amb el número més alt del document.
--    Regla de negoci: el document ha de tenir ≥2 versions; si n'hi ha 1,
--    retorna error de domini i s'ha d'usar delete_document_all.
--
--    Permís:
--      a) global_role IN ('owner','manager')
--      b) site manager quan el document té site_id
--      c) creador de la versió (v_latest.created_by = auth.uid())
-- ---------------------------------------------------------------------------

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
  -- 1. Carregar document (no usar RLS: SECURITY DEFINER fa bypass, permisos manuals)
  SELECT * INTO v_doc FROM data.documents WHERE id = p_document_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'document_not_found';
  END IF;

  -- 2. Coherència tenant actiu (header x-tenant-id)
  v_active_tid := data.active_tenant_id();
  IF v_active_tid IS NOT NULL AND v_active_tid IS DISTINCT FROM v_doc.tenant_id THEN
    RAISE EXCEPTION 'tenant_mismatch';
  END IF;

  -- 3. Validar membresia del tenant
  IF NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'insufficient_permissions';
  END IF;

  -- 4. Carregar la versió amb el número màxim
  SELECT * INTO v_latest
  FROM data.document_versions
  WHERE document_id = p_document_id
  ORDER BY version_number DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no_versions';
  END IF;

  -- 5. Comprovar permís sobre la versió a eliminar
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

  -- 6. Verificar que no és l'única versió del document
  SELECT COUNT(*) INTO v_count
  FROM data.document_versions
  WHERE document_id = p_document_id;

  IF v_count <= 1 THEN
    RAISE EXCEPTION 'last_version_cannot_be_deleted'
      USING HINT = 'Use delete_document_all to delete the entire document';
  END IF;

  -- 7. Encuar esborrat físic si és fitxer natiu
  --    Validació de prefix (defense-in-depth cross-tenant)
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

  -- 8. Eliminar versió (trigger existent dispara DOCUMENT_VERSION_DELETED a audit_logs)
  DELETE FROM data.document_versions WHERE id = v_latest.id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.delete_document_latest_version(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6) RPC api.delete_document_all
--
--    Elimina el document complet (CASCADE elimina totes les versions).
--    Encua l'esborrat físic de tots els fitxers natius abans del DELETE.
--
--    Permís:
--      a) global_role IN ('owner','manager')
--      b) site manager quan el document té site_id
--      c) propietari de TOTES les versions (bool_and(created_by = auth.uid()))
--         → qualsevol versió amb created_by NULL bloqueja aquesta via
-- ---------------------------------------------------------------------------

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
  -- 1. Carregar document
  SELECT * INTO v_doc FROM data.documents WHERE id = p_document_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'document_not_found';
  END IF;

  -- 2. Coherència tenant actiu
  v_active_tid := data.active_tenant_id();
  IF v_active_tid IS NOT NULL AND v_active_tid IS DISTINCT FROM v_doc.tenant_id THEN
    RAISE EXCEPTION 'tenant_mismatch';
  END IF;

  -- 3. Validar membresia del tenant
  IF NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'insufficient_permissions';
  END IF;

  -- 4. Comprovar permís: owner/manager (global o site) o propietari de TOTES les versions
  IF NOT (
    (data.jwt_user_tenants() -> v_doc.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    OR (
      v_doc.site_id IS NOT NULL
      AND (data.jwt_user_tenants() -> v_doc.tenant_id::text -> 'sites' ->> v_doc.site_id::text)
          IN ('owner', 'manager')
    )
  ) THEN
    -- Via "propietari de totes les versions": qualsevol NULL bloqueja
    SELECT bool_and(created_by = auth.uid()) INTO v_all_own
    FROM data.document_versions
    WHERE document_id = p_document_id;

    IF NOT COALESCE(v_all_own, false) THEN
      RAISE EXCEPTION 'insufficient_permissions';
    END IF;
  END IF;

  -- 5. Encuar esborrat físic de tots els fitxers natius (validació de prefix)
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

  -- 6. Eliminar document
  --    CASCADE: document_versions s'eliminen automàticament
  --    Triggers: trg_audit_documents dispara DOCUMENT_DELETED
  --              trg_audit_document_versions dispara DOCUMENT_VERSION_DELETED per cada versió
  DELETE FROM data.documents WHERE id = p_document_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.delete_document_all(uuid) TO authenticated;
