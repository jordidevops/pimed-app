-- =============================================================================
-- 20260601000001_documents_archive.sql
--
-- Arxiu de documents al mòdul DMS (soft-archive).
--
-- Canvis:
--   1. data.documents             + is_archived boolean NOT NULL DEFAULT false
--   2. Índexs parcials per consultes actives i arxivades
--   3. data.trg_audit_documents() estesa: DOCUMENT_ARCHIVED / DOCUMENT_UNARCHIVED
--   4. api.documents              recreat amb is_archived
--   5. api.active_documents       recreat amb WHERE is_archived = false
--   6. api.archived_documents     nova vista (shape = active_documents, WHERE is_archived = true)
--   7. api.archive_document       RPC SECURITY DEFINER
--   8. api.unarchive_document     RPC SECURITY DEFINER
--
-- Seguretat:
--   - RPCs SECURITY DEFINER SET search_path = ''
--   - Validació explícita: tenant_membership + rol (global/site) + active_tenant_id
--   - Idempotent: arxivar un doc ja arxivat (o desarxivar un actiu) retorna OK
--
-- Auditoria:
--   - El trigger trg_audit_documents detecta canvis a is_archived i emet
--     DOCUMENT_ARCHIVED o DOCUMENT_UNARCHIVED (bypass del camí genèric DOCUMENT_UPDATED)
-- =============================================================================

-- ── 1. Camp is_archived ───────────────────────────────────────────────────────

ALTER TABLE data.documents
  ADD COLUMN IF NOT EXISTS is_archived boolean NOT NULL DEFAULT false;

-- ── 2. Índexs parcials ────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_docs_active
  ON data.documents (tenant_id, updated_at DESC)
  WHERE is_archived = false;

CREATE INDEX IF NOT EXISTS idx_docs_archived
  ON data.documents (tenant_id, updated_at DESC)
  WHERE is_archived = true;

-- ── 3. Funció d'auditoria: DOCUMENT_ARCHIVED / DOCUMENT_UNARCHIVED ────────────
--    CREATE OR REPLACE per preservar el trigger existent sense recrear-lo.

CREATE OR REPLACE FUNCTION data.trg_audit_documents()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id, COALESCE(auth.uid(), NULL), NEW.site_id,
      'DOCUMENT_CREATED', 'document', NEW.id,
      jsonb_build_object(
        'title',       NEW.title,
        'folder_id',   NEW.folder_id,
        'entity_type', NEW.entity_type,
        'entity_id',   NEW.entity_id
      )
    );
  ELSIF TG_OP = 'UPDATE' THEN
    -- Canvi d'estat arxivat: emet DOCUMENT_ARCHIVED o DOCUMENT_UNARCHIVED
    IF NEW.is_archived IS DISTINCT FROM OLD.is_archived THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id, COALESCE(auth.uid(), NULL), NEW.site_id,
        CASE WHEN NEW.is_archived THEN 'DOCUMENT_ARCHIVED' ELSE 'DOCUMENT_UNARCHIVED' END,
        'document', NEW.id,
        jsonb_build_object(
          'title',        NEW.title,
          'was_archived', OLD.is_archived
        )
      );
    ELSE
      PERFORM data.log_audit_event(
        NEW.tenant_id, COALESCE(auth.uid(), NULL), NEW.site_id,
        'DOCUMENT_UPDATED', 'document', NEW.id,
        jsonb_build_object(
          'old', jsonb_build_object('title', OLD.title, 'folder_id', OLD.folder_id),
          'new', jsonb_build_object('title', NEW.title, 'folder_id', NEW.folder_id)
        )
      );
    END IF;
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id, COALESCE(auth.uid(), NULL), OLD.site_id,
      'DOCUMENT_DELETED', 'document', OLD.id,
      jsonb_build_object('title', OLD.title, 'entity_type', OLD.entity_type, 'entity_id', OLD.entity_id)
    );
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;

-- ── 4. api.documents (vista simple + is_archived) ─────────────────────────────
--    Preserva l'ordre de columnes de 20260530000001_documents_category_and_move.

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
    updated_at,
    is_archived
  FROM data.documents;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.documents TO authenticated;

-- ── 5. api.active_documents (exclou arxivats) ────────────────────────────────
--    Preserva l'ordre de columnes de 20260530000001_documents_category_and_move
--    + afegeix d.is_archived (sempre false) al final per consistència de tipus.

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
    v.created_at     AS version_created_at,
    d.is_archived
  FROM data.documents d
  JOIN (
    SELECT document_id, MAX(version_number) AS version_number
    FROM data.document_versions
    GROUP BY document_id
  ) mx ON d.id = mx.document_id
  JOIN data.document_versions v
    ON d.id = v.document_id AND mx.version_number = v.version_number
  WHERE d.is_archived = false;

GRANT SELECT ON api.active_documents TO authenticated;
GRANT SELECT ON api.active_documents TO service_role;

-- ── 6. api.archived_documents (shape idèntic a active_documents, is_archived = true) ──

DROP VIEW IF EXISTS api.archived_documents;

CREATE VIEW api.archived_documents WITH (security_invoker = true) AS
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
    v.created_at     AS version_created_at,
    d.is_archived
  FROM data.documents d
  JOIN (
    SELECT document_id, MAX(version_number) AS version_number
    FROM data.document_versions
    GROUP BY document_id
  ) mx ON d.id = mx.document_id
  JOIN data.document_versions v
    ON d.id = v.document_id AND mx.version_number = v.version_number
  WHERE d.is_archived = true;

GRANT SELECT ON api.archived_documents TO authenticated;
GRANT SELECT ON api.archived_documents TO service_role;

-- ── 7. api.archive_document ───────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.archive_document(
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
BEGIN
  -- 1. Carregar document (SECURITY DEFINER, validació manual)
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

  -- 4. Validar rol: owner/manager global o de site
  IF NOT (
    (data.jwt_user_tenants() -> v_doc.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    OR (
      v_doc.site_id IS NOT NULL
      AND (data.jwt_user_tenants() -> v_doc.tenant_id::text -> 'sites' ->> v_doc.site_id::text)
          IN ('owner', 'manager')
    )
  ) THEN
    RAISE EXCEPTION 'insufficient_permissions';
  END IF;

  -- 5. Idempotent: ja arxivat, retorna OK
  IF v_doc.is_archived THEN
    RETURN;
  END IF;

  -- 6. Arxivar — el trigger d'auditoria emet DOCUMENT_ARCHIVED automàticament
  UPDATE data.documents
  SET is_archived = true,
      updated_at  = now()
  WHERE id = p_document_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.archive_document(uuid) TO authenticated;

-- ── 8. api.unarchive_document ─────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.unarchive_document(
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

  -- 4. Validar rol: owner/manager global o de site
  IF NOT (
    (data.jwt_user_tenants() -> v_doc.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    OR (
      v_doc.site_id IS NOT NULL
      AND (data.jwt_user_tenants() -> v_doc.tenant_id::text -> 'sites' ->> v_doc.site_id::text)
          IN ('owner', 'manager')
    )
  ) THEN
    RAISE EXCEPTION 'insufficient_permissions';
  END IF;

  -- 5. Idempotent: ja actiu, retorna OK
  IF NOT v_doc.is_archived THEN
    RETURN;
  END IF;

  -- 6. Desarxivar — el trigger d'auditoria emet DOCUMENT_UNARCHIVED automàticament
  UPDATE data.documents
  SET is_archived = false,
      updated_at  = now()
  WHERE id = p_document_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.unarchive_document(uuid) TO authenticated;
