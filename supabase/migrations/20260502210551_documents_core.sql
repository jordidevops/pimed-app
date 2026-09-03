-- =============================================================================
-- Migration: 20260502210551_documents_core.sql
-- Propòsit: Motor de Gestió Documental (DMS) Genèric
-- Seguretat: jwt_user_tenants() amb patrons globals + per-site
-- Audit: DOCUMENT_FOLDER_CREATED/UPDATED/DELETED, DOCUMENT_CREATED/UPDATED/DELETED,
--        DOCUMENT_VERSION_UPLOADED/DELETED
-- =============================================================================

-- =============================================================================
-- 1. Model de Dades
-- =============================================================================

CREATE TABLE data.document_folders (
  id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id            uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id              uuid                 REFERENCES data.sites(id)   ON DELETE CASCADE,
  parent_id            uuid                 REFERENCES data.document_folders(id) ON DELETE CASCADE,
  name                 text        NOT NULL,
  required_permissions text[]      NOT NULL DEFAULT '{}',
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_doc_folders_tenant_id ON data.document_folders (tenant_id);
CREATE INDEX idx_doc_folders_site_id   ON data.document_folders (site_id);
CREATE INDEX idx_doc_folders_parent_id ON data.document_folders (parent_id);

CREATE TABLE data.documents (
  id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id            uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id              uuid                 REFERENCES data.sites(id)   ON DELETE CASCADE,
  folder_id            uuid                 REFERENCES data.document_folders(id) ON DELETE SET NULL,
  title                text        NOT NULL,
  -- Polimorfisme
  entity_type          varchar(50),
  entity_id            uuid,
  required_permissions text[]      NOT NULL DEFAULT '{}',
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_docs_tenant_id ON data.documents (tenant_id);
CREATE INDEX idx_docs_site_id   ON data.documents (site_id);
CREATE INDEX idx_docs_folder_id ON data.documents (folder_id);
CREATE INDEX idx_docs_entity    ON data.documents (entity_type, entity_id);

CREATE TABLE data.document_versions (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id      uuid        NOT NULL REFERENCES data.documents(id) ON DELETE CASCADE,
  version_number   int         NOT NULL,
  storage_type     text        NOT NULL CHECK (storage_type IN ('native', 'external_link')),
  file_path_or_url text        NOT NULL,
  mime_type        text,
  size_bytes       bigint      DEFAULT 0,
  created_by       uuid                 REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (document_id, version_number)
);

CREATE INDEX idx_doc_versions_doc_id ON data.document_versions (document_id);

-- =============================================================================
-- Triggers updated_at
-- =============================================================================

CREATE TRIGGER trg_doc_folders_updated_at
  BEFORE UPDATE ON data.document_folders
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

CREATE TRIGGER trg_docs_updated_at
  BEFORE UPDATE ON data.documents
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

-- Evita enllaços creuats tenant/site entre document i carpeta.
CREATE OR REPLACE FUNCTION data.trg_validate_document_folder_consistency()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = data
AS $$
DECLARE
  v_folder_tenant_id uuid;
  v_folder_site_id   uuid;
BEGIN
  IF NEW.folder_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT f.tenant_id, f.site_id
  INTO v_folder_tenant_id, v_folder_site_id
  FROM data.document_folders f
  WHERE f.id = NEW.folder_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Folder % does not exist', NEW.folder_id;
  END IF;

  IF v_folder_tenant_id IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION
      'Document tenant_id (%) must match folder tenant_id (%)',
      NEW.tenant_id, v_folder_tenant_id;
  END IF;

  IF v_folder_site_id IS DISTINCT FROM NEW.site_id THEN
    RAISE EXCEPTION
      'Document site_id (%) must match folder site_id (%)',
      NEW.site_id, v_folder_site_id;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_document_folder_consistency
  BEFORE INSERT OR UPDATE ON data.documents
  FOR EACH ROW EXECUTE FUNCTION data.trg_validate_document_folder_consistency();

-- =============================================================================
-- 2. Seguretat RLS i RBAC Multi-Site
-- =============================================================================

ALTER TABLE data.document_folders ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.document_versions ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- Helper de lectura reutilitzable (cridat per carpetes i documents)
-- Comprova:
--   1. L'usuari pertany al tenant
--   2. Té rol global O pertany al site concret (si site_id IS NOT NULL)
--   3. Si required_permissions no és buit, el seu rol hi ha d'estar
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.user_can_read_doc_resource(
  p_tenant_id            uuid,
  p_site_id              uuid,
  p_required_permissions text[]
)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = data AS $$
  SELECT
    -- 1. Membre del tenant
    data.jwt_user_tenants() ? p_tenant_id::text
    -- 2. Accés global o per site
    AND (
      (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IS NOT NULL
      OR (
        p_site_id IS NOT NULL
        AND (data.jwt_user_tenants() -> p_tenant_id::text -> 'sites') ? p_site_id::text
      )
    )
    -- 3. Permisos requerits: si l'array és buit és públic per al tenant/site;
    --    si no, algun rol de l'usuari (global o del site) ha de ser a la llista.
    AND (
      array_length(p_required_permissions, 1) IS NULL
      OR p_required_permissions && array_remove(
           ARRAY[
             data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role',
             CASE
               WHEN p_site_id IS NOT NULL THEN data.jwt_user_tenants() -> p_tenant_id::text -> 'sites' ->> p_site_id::text
               ELSE NULL
             END
           ],
           NULL
         )
    )
$$;

-- ---------------------------------------------------------------------------
-- Policies: data.document_folders
-- ---------------------------------------------------------------------------

CREATE POLICY "doc_folders: select" ON data.document_folders
  FOR SELECT TO authenticated
  USING (data.user_can_read_doc_resource(tenant_id, site_id, required_permissions));

CREATE POLICY "doc_folders: insert" ON data.document_folders
  FOR INSERT TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR (
        site_id IS NOT NULL
        AND (data.jwt_user_tenants() -> tenant_id::text -> 'sites' ->> site_id::text) IN ('owner', 'manager')
      )
    )
  );

CREATE POLICY "doc_folders: update" ON data.document_folders
  FOR UPDATE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR (
        site_id IS NOT NULL
        AND (data.jwt_user_tenants() -> tenant_id::text -> 'sites' ->> site_id::text) IN ('owner', 'manager')
      )
    )
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR (
        site_id IS NOT NULL
        AND (data.jwt_user_tenants() -> tenant_id::text -> 'sites' ->> site_id::text) IN ('owner', 'manager')
      )
    )
  );

CREATE POLICY "doc_folders: delete" ON data.document_folders
  FOR DELETE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- ---------------------------------------------------------------------------
-- Policies: data.documents
-- ---------------------------------------------------------------------------

CREATE POLICY "documents: select" ON data.documents
  FOR SELECT TO authenticated
  USING (data.user_can_read_doc_resource(tenant_id, site_id, required_permissions));

CREATE POLICY "documents: insert" ON data.documents
  FOR INSERT TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR (
        site_id IS NOT NULL
        AND (data.jwt_user_tenants() -> tenant_id::text -> 'sites' ->> site_id::text) IN ('owner', 'manager')
      )
    )
  );

CREATE POLICY "documents: update" ON data.documents
  FOR UPDATE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR (
        site_id IS NOT NULL
        AND (data.jwt_user_tenants() -> tenant_id::text -> 'sites' ->> site_id::text) IN ('owner', 'manager')
      )
    )
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR (
        site_id IS NOT NULL
        AND (data.jwt_user_tenants() -> tenant_id::text -> 'sites' ->> site_id::text) IN ('owner', 'manager')
      )
    )
  );

CREATE POLICY "documents: delete" ON data.documents
  FOR DELETE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- ---------------------------------------------------------------------------
-- Policies: data.document_versions
-- Les versions hereten l'accés del document pare via EXISTS sobre data.documents,
-- on les polítiques RLS del pare s'avaluen automàticament.
-- ---------------------------------------------------------------------------

CREATE POLICY "doc_versions: select" ON data.document_versions
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM data.documents d
      WHERE d.id = document_id
      -- RLS de data.documents s'aplica automàticament en el subquery
    )
  );

CREATE POLICY "doc_versions: insert" ON data.document_versions
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM data.documents d
      WHERE d.id = document_id
        AND data.jwt_user_tenants() ? d.tenant_id::text
        AND (
          (data.jwt_user_tenants() -> d.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
          OR (
            d.site_id IS NOT NULL
            AND (data.jwt_user_tenants() -> d.tenant_id::text -> 'sites' ->> d.site_id::text) IN ('owner', 'manager')
          )
        )
    )
  );

CREATE POLICY "doc_versions: update" ON data.document_versions
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM data.documents d
      WHERE d.id = document_id
        AND data.jwt_user_tenants() ? d.tenant_id::text
        AND (
          (data.jwt_user_tenants() -> d.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
          OR (
            d.site_id IS NOT NULL
            AND (data.jwt_user_tenants() -> d.tenant_id::text -> 'sites' ->> d.site_id::text) IN ('owner', 'manager')
          )
        )
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM data.documents d
      WHERE d.id = document_id
        AND data.jwt_user_tenants() ? d.tenant_id::text
        AND (
          (data.jwt_user_tenants() -> d.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
          OR (
            d.site_id IS NOT NULL
            AND (data.jwt_user_tenants() -> d.tenant_id::text -> 'sites' ->> d.site_id::text) IN ('owner', 'manager')
          )
        )
    )
  );

CREATE POLICY "doc_versions: delete" ON data.document_versions
  FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM data.documents d
      WHERE d.id = document_id
        AND data.jwt_user_tenants() ? d.tenant_id::text
        AND (
          (data.jwt_user_tenants() -> d.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
          OR (
            d.site_id IS NOT NULL
            AND (data.jwt_user_tenants() -> d.tenant_id::text -> 'sites' ->> d.site_id::text) IN ('owner', 'manager')
          )
        )
    )
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON data.document_folders TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.documents TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.document_versions TO authenticated;

-- =============================================================================
-- 3. Audit Triggers
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Audit: data.document_folders
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_document_folders()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id, COALESCE(auth.uid(), NULL), NEW.site_id,
      'DOCUMENT_FOLDER_CREATED', 'document_folder', NEW.id,
      jsonb_build_object('name', NEW.name, 'parent_id', NEW.parent_id)
    );
  ELSIF TG_OP = 'UPDATE' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id, COALESCE(auth.uid(), NULL), NEW.site_id,
      'DOCUMENT_FOLDER_UPDATED', 'document_folder', NEW.id,
      jsonb_build_object(
        'old', jsonb_build_object('name', OLD.name, 'parent_id', OLD.parent_id),
        'new', jsonb_build_object('name', NEW.name, 'parent_id', NEW.parent_id)
      )
    );
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id, COALESCE(auth.uid(), NULL), OLD.site_id,
      'DOCUMENT_FOLDER_DELETED', 'document_folder', OLD.id,
      jsonb_build_object('name', OLD.name)
    );
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_audit_document_folders
  AFTER INSERT OR UPDATE OR DELETE ON data.document_folders
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_document_folders();

-- ---------------------------------------------------------------------------
-- Audit: data.documents
-- ---------------------------------------------------------------------------
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
    PERFORM data.log_audit_event(
      NEW.tenant_id, COALESCE(auth.uid(), NULL), NEW.site_id,
      'DOCUMENT_UPDATED', 'document', NEW.id,
      jsonb_build_object(
        'old', jsonb_build_object('title', OLD.title, 'folder_id', OLD.folder_id),
        'new', jsonb_build_object('title', NEW.title, 'folder_id', NEW.folder_id)
      )
    );
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

CREATE TRIGGER trg_audit_documents
  AFTER INSERT OR UPDATE OR DELETE ON data.documents
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_documents();

-- ---------------------------------------------------------------------------
-- Audit: data.document_versions
-- Fa un JOIN al document pare per obtenir tenant_id/site_id
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_document_versions()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id uuid;
  v_site_id   uuid;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT d.tenant_id, d.site_id INTO v_tenant_id, v_site_id
    FROM data.documents d WHERE d.id = NEW.document_id;

    PERFORM data.log_audit_event(
      v_tenant_id, COALESCE(auth.uid(), NEW.created_by), v_site_id,
      'DOCUMENT_VERSION_UPLOADED', 'document_version', NEW.id,
      jsonb_build_object(
        'document_id',    NEW.document_id,
        'version_number', NEW.version_number,
        'storage_type',   NEW.storage_type,
        'mime_type',      NEW.mime_type,
        'size_bytes',     NEW.size_bytes
      )
    );

  ELSIF TG_OP = 'DELETE' THEN
    SELECT d.tenant_id, d.site_id INTO v_tenant_id, v_site_id
    FROM data.documents d WHERE d.id = OLD.document_id;

    PERFORM data.log_audit_event(
      v_tenant_id, COALESCE(auth.uid(), NULL), v_site_id,
      'DOCUMENT_VERSION_DELETED', 'document_version', OLD.id,
      jsonb_build_object(
        'document_id',    OLD.document_id,
        'version_number', OLD.version_number
      )
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_audit_document_versions_insert
  AFTER INSERT ON data.document_versions
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_document_versions();

CREATE TRIGGER trg_audit_document_versions_delete
  BEFORE DELETE ON data.document_versions
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_document_versions();

-- =============================================================================
-- 4. Vistes API
-- =============================================================================

CREATE OR REPLACE VIEW api.document_folders WITH (security_invoker = true) AS
  SELECT id, tenant_id, site_id, parent_id, name, required_permissions, created_at, updated_at
  FROM data.document_folders;

CREATE OR REPLACE VIEW api.documents WITH (security_invoker = true) AS
  SELECT id, tenant_id, site_id, folder_id, title, entity_type, entity_id, required_permissions, created_at, updated_at
  FROM data.documents;

CREATE OR REPLACE VIEW api.document_versions WITH (security_invoker = true) AS
  SELECT id, document_id, version_number, storage_type, file_path_or_url, mime_type, size_bytes, created_by, created_at
  FROM data.document_versions;

CREATE OR REPLACE VIEW api.active_documents WITH (security_invoker = true) AS
  SELECT 
    d.id, d.tenant_id, d.site_id, d.folder_id, d.title, d.entity_type, d.entity_id, d.required_permissions, d.created_at, d.updated_at,
    v.id AS version_id, v.version_number, v.storage_type, v.file_path_or_url, v.mime_type, v.size_bytes, v.created_by AS version_created_by, v.created_at AS version_created_at
  FROM data.documents d
  JOIN (
    SELECT document_id, MAX(version_number) AS version_number
    FROM data.document_versions
    GROUP BY document_id
  ) mx ON d.id = mx.document_id
  JOIN data.document_versions v ON d.id = v.document_id AND mx.version_number = v.version_number;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.document_folders TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.documents TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.document_versions TO authenticated;
GRANT SELECT ON api.active_documents TO authenticated;

-- =============================================================================
-- 5. RPC Transaccional d'Inserció
-- =============================================================================

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
  p_size_bytes bigint DEFAULT 0
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_doc_id     uuid;
  v_version_id uuid;
  v_document   data.documents%ROWTYPE;
  v_version    data.document_versions%ROWTYPE;
BEGIN
  -- Validació d'accés: cal ser owner o manager del tenant o del site
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

  INSERT INTO data.documents (tenant_id, site_id, folder_id, title, entity_type, entity_id, required_permissions)
  VALUES (p_tenant_id, p_site_id, p_folder_id, p_title, p_entity_type, p_entity_id, p_required_permissions)
  RETURNING * INTO v_document;

  v_doc_id := v_document.id;

  INSERT INTO data.document_versions (document_id, version_number, storage_type, file_path_or_url, mime_type, size_bytes, created_by)
  VALUES (v_doc_id, 1, p_storage_type, p_file_path_or_url, p_mime_type, p_size_bytes, auth.uid())
  RETURNING * INTO v_version;

  v_version_id := v_version.id;

  RETURN json_build_object(
    'document', row_to_json(v_document),
    'version',  row_to_json(v_version)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_document_with_version TO authenticated;
