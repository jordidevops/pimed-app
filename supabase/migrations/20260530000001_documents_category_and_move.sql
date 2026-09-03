-- =============================================================================
-- Migration: 20260530000001_documents_category_and_move.sql
-- Propòsit: Afegir camp `category` a documents i vistes.
--           Permet organitzar documents per categories com a vista alternativa
--           a la navegació per carpetes.
-- Canvis:
--   1. data.documents             + category text
--   2. api.documents              recreat amb category + camps expiry complets
--   3. api.active_documents       recreat amb category (preserva shape de 20260523000006)
--   4. api.create_document_with_version  + p_category
-- =============================================================================

-- ── 1. Camp category a data.documents ────────────────────────────────────────

ALTER TABLE data.documents
  ADD COLUMN IF NOT EXISTS category text;

CREATE INDEX IF NOT EXISTS idx_docs_category
  ON data.documents (tenant_id, category)
  WHERE category IS NOT NULL;

-- ── 2. api.documents (vista simple, actualitzable via PostgREST) ──────────────
--    Recrea incloent tots els camps actuals + category.

DROP VIEW IF EXISTS api.documents;

CREATE VIEW api.documents WITH (security_invoker = true) AS
  SELECT
    id,
    tenant_id,
    site_id,
    folder_id,
    title,
    category,
    entity_type,
    entity_id,
    required_permissions,
    created_by,
    valid_from,
    expires_at,
    renewal_interval_months,
    renewal_anchor_mode,
    renewal_anchor_month,
    renewal_anchor_day,
    created_at,
    updated_at
  FROM data.documents;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.documents TO authenticated;

-- ── 3. api.active_documents (shape completa + category) ──────────────────────
--    Preserva l'ordre de columnes establert a 20260523000006_document_delete_rpcs.

DROP VIEW IF EXISTS api.active_documents;

CREATE VIEW api.active_documents WITH (security_invoker = true) AS
  SELECT
    d.id,
    d.tenant_id,
    d.site_id,
    d.folder_id,
    d.title,
    d.category,
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

-- ── 4. api.create_document_with_version: afegir p_category ───────────────────
--    La signatura anterior (sense p_category) s'elimina per evitar ambigüitat
--    de sobrecàrrega de funcions PostgreSQL.

DROP FUNCTION IF EXISTS api.create_document_with_version(
  uuid, text, text, text, uuid, uuid, varchar, uuid, text[], text, bigint,
  timestamptz, timestamptz, int, varchar, smallint, smallint
);

CREATE OR REPLACE FUNCTION api.create_document_with_version(
  p_tenant_id                uuid,
  p_title                    text,
  p_storage_type             text,
  p_file_path_or_url         text,
  p_site_id                  uuid          DEFAULT NULL,
  p_folder_id                uuid          DEFAULT NULL,
  p_entity_type              varchar       DEFAULT NULL,
  p_entity_id                uuid          DEFAULT NULL,
  p_required_permissions     text[]        DEFAULT '{}',
  p_mime_type                text          DEFAULT NULL,
  p_size_bytes               bigint        DEFAULT 0,
  p_valid_from               timestamptz   DEFAULT NULL,
  p_expires_at               timestamptz   DEFAULT NULL,
  p_renewal_interval_months  int           DEFAULT NULL,
  p_renewal_anchor_mode      varchar       DEFAULT NULL,
  p_renewal_anchor_month     smallint      DEFAULT NULL,
  p_renewal_anchor_day       smallint      DEFAULT NULL,
  p_category                 text          DEFAULT NULL
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
    tenant_id, site_id, folder_id, title, category, entity_type, entity_id,
    required_permissions,
    valid_from, expires_at,
    renewal_interval_months, renewal_anchor_mode,
    renewal_anchor_month, renewal_anchor_day
  )
  VALUES (
    p_tenant_id, p_site_id, p_folder_id, p_title, p_category, p_entity_type, p_entity_id,
    p_required_permissions,
    p_valid_from, p_expires_at,
    p_renewal_interval_months, p_renewal_anchor_mode,
    p_renewal_anchor_month, p_renewal_anchor_day
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
    'version',  row_to_json(v_version)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_document_with_version(
  uuid, text, text, text, uuid, uuid, varchar, uuid, text[], text, bigint,
  timestamptz, timestamptz, int, varchar, smallint, smallint, text
) TO authenticated;
