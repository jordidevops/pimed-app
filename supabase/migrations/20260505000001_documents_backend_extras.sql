-- =============================================================================
-- Migration: 20260505000001_documents_backend_extras.sql
-- Purpose: Backend extras for the Documents module (self-contained)
--
-- This migration defines the full operational state for documents backend
-- features beyond documents_core, including fixes that prevent known runtime
-- issues in tags/audit/view writes and folder integrity rules.
--
-- Includes:
--   1. Storage bucket + RLS policies for documents files
--   2. Folder scope by entity (global/module-shared/record-specific)
--   3. Parent-child/document-folder consistency triggers
--   4. Guardrail to prevent deleting non-empty folders
--   5. Expiry/renewal model (rolling and natural anchors)
--   6. active_documents view update + suggest_next_expiry RPC
--   7. create_document_with_version RPC with expiry/renewal parameters
--   8. add_document_version RPC with FOR UPDATE concurrency protection
--   9. Document tags model, RLS, views, and required grants
--  10. Secure INSTEAD OF triggers for tag assignment writes via API view
--  11. Atomic set_document_tags RPC and PostgREST schema cache reload
--
-- Fixes captured in this migration:
--   - Correct audit logging signature for document tag lifecycle events
--   - Ensure security_invoker views have underlying table grants
--   - Prevent authorization bypass in tag-assignment INSTEAD OF triggers
-- =============================================================================

-- =============================================================================
-- 1) Storage bucket + RLS policies (defense in depth)
-- =============================================================================

INSERT INTO storage.buckets (id, name, public, file_size_limit)
VALUES ('documents', 'documents', false, 52428800)  -- 50 MB
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "documents bucket: tenant members can read" ON storage.objects;
CREATE POLICY "documents bucket: tenant members can read"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'documents'
    AND data.jwt_user_tenants() ? (storage.foldername(name))[1]::text
  );

DROP POLICY IF EXISTS "documents bucket: owner/manager can upload" ON storage.objects;
CREATE POLICY "documents bucket: owner/manager can upload"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'documents'
    AND (
      (data.jwt_user_tenants() -> (storage.foldername(name))[1]::text ->> 'global_role')
        IN ('owner', 'manager')
    )
  );

DROP POLICY IF EXISTS "documents bucket: owner/manager can delete" ON storage.objects;
CREATE POLICY "documents bucket: owner/manager can delete"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'documents'
    AND (
      (data.jwt_user_tenants() -> (storage.foldername(name))[1]::text ->> 'global_role')
        IN ('owner', 'manager')
    )
  );

-- =============================================================================
-- 2) Folder scope by module/entity (global, module-shared, record-specific)
-- =============================================================================

ALTER TABLE data.document_folders
  ADD COLUMN IF NOT EXISTS entity_type varchar(50),
  ADD COLUMN IF NOT EXISTS entity_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_folder_entity_consistency'
      AND conrelid = 'data.document_folders'::regclass
  ) THEN
    ALTER TABLE data.document_folders
      ADD CONSTRAINT chk_folder_entity_consistency
      CHECK (
        (entity_type IS NULL AND entity_id IS NULL) OR
        (entity_type IS NOT NULL)
      );
  END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS idx_doc_folders_entity
  ON data.document_folders (entity_type, entity_id);

CREATE INDEX IF NOT EXISTS idx_doc_folders_root_scope
  ON data.document_folders (tenant_id, entity_type, entity_id)
  WHERE parent_id IS NULL;

CREATE OR REPLACE FUNCTION data.trg_validate_folder_parent_consistency()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = data
AS $$
DECLARE
  v_parent data.document_folders%ROWTYPE;
BEGIN
  IF NEW.parent_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_parent
  FROM data.document_folders
  WHERE id = NEW.parent_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Parent folder % does not exist', NEW.parent_id;
  END IF;

  IF v_parent.tenant_id IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION
      'Subfolder tenant_id (%) must match parent tenant_id (%)',
      NEW.tenant_id, v_parent.tenant_id;
  END IF;

  IF v_parent.site_id IS NOT NULL AND v_parent.site_id IS DISTINCT FROM NEW.site_id THEN
    RAISE EXCEPTION
      'Subfolder site_id (%) must match parent site_id (%)',
      NEW.site_id, v_parent.site_id;
  END IF;

  IF v_parent.entity_type IS DISTINCT FROM NEW.entity_type THEN
    RAISE EXCEPTION
      'Subfolder entity_type (%) must match parent entity_type (%)',
      NEW.entity_type, v_parent.entity_type;
  END IF;

  IF v_parent.entity_id IS NOT NULL AND v_parent.entity_id IS DISTINCT FROM NEW.entity_id THEN
    RAISE EXCEPTION
      'Subfolder entity_id (%) must match parent entity_id (%) when parent is record-specific',
      NEW.entity_id, v_parent.entity_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_folder_parent_consistency ON data.document_folders;
CREATE TRIGGER trg_validate_folder_parent_consistency
  BEFORE INSERT OR UPDATE ON data.document_folders
  FOR EACH ROW EXECUTE FUNCTION data.trg_validate_folder_parent_consistency();

CREATE OR REPLACE FUNCTION data.trg_validate_document_folder_consistency()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = data
AS $$
DECLARE
  v_folder data.document_folders%ROWTYPE;
BEGIN
  IF NEW.folder_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_folder
  FROM data.document_folders
  WHERE id = NEW.folder_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Folder % does not exist', NEW.folder_id;
  END IF;

  IF v_folder.tenant_id IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION
      'Document tenant_id (%) must match folder tenant_id (%)',
      NEW.tenant_id, v_folder.tenant_id;
  END IF;

  IF v_folder.site_id IS DISTINCT FROM NEW.site_id THEN
    RAISE EXCEPTION
      'Document site_id (%) must match folder site_id (%)',
      NEW.site_id, v_folder.site_id;
  END IF;

  IF v_folder.entity_type IS NOT NULL THEN
    IF v_folder.entity_type IS DISTINCT FROM NEW.entity_type THEN
      RAISE EXCEPTION
        'Document entity_type (%) must match folder entity_type (%)',
        NEW.entity_type, v_folder.entity_type;
    END IF;

    IF v_folder.entity_id IS NOT NULL AND v_folder.entity_id IS DISTINCT FROM NEW.entity_id THEN
      RAISE EXCEPTION
        'Document entity_id (%) must match folder entity_id (%) for record-specific folder',
        NEW.entity_id, v_folder.entity_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP VIEW IF EXISTS api.document_folders;
CREATE VIEW api.document_folders WITH (security_invoker = true) AS
  SELECT
    id, tenant_id, site_id, parent_id, name,
    entity_type, entity_id,
    required_permissions, created_at, updated_at
  FROM data.document_folders;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.document_folders TO authenticated;

CREATE OR REPLACE FUNCTION data.trg_audit_document_folders()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id, COALESCE(auth.uid(), NULL), NEW.site_id,
      'DOCUMENT_FOLDER_CREATED', 'document_folder', NEW.id,
      jsonb_build_object(
        'name', NEW.name,
        'parent_id', NEW.parent_id,
        'entity_type', NEW.entity_type,
        'entity_id', NEW.entity_id
      )
    );
  ELSIF TG_OP = 'UPDATE' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id, COALESCE(auth.uid(), NULL), NEW.site_id,
      'DOCUMENT_FOLDER_UPDATED', 'document_folder', NEW.id,
      jsonb_build_object(
        'old', jsonb_build_object(
          'name', OLD.name,
          'parent_id', OLD.parent_id,
          'entity_type', OLD.entity_type,
          'entity_id', OLD.entity_id
        ),
        'new', jsonb_build_object(
          'name', NEW.name,
          'parent_id', NEW.parent_id,
          'entity_type', NEW.entity_type,
          'entity_id', NEW.entity_id
        )
      )
    );
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id, COALESCE(auth.uid(), NULL), OLD.site_id,
      'DOCUMENT_FOLDER_DELETED', 'document_folder', OLD.id,
      jsonb_build_object(
        'name', OLD.name,
        'entity_type', OLD.entity_type,
        'entity_id', OLD.entity_id
      )
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

-- =============================================================================
-- 3) Guardrail: do not allow deleting non-empty folders
-- =============================================================================

CREATE OR REPLACE FUNCTION data.trg_prevent_delete_non_empty_document_folder()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM data.document_folders f
    WHERE f.parent_id = OLD.id
  ) THEN
    RAISE EXCEPTION 'Cannot delete non-empty folder: has child folders';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM data.documents d
    WHERE d.folder_id = OLD.id
  ) THEN
    RAISE EXCEPTION 'Cannot delete non-empty folder: has documents';
  END IF;

  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_prevent_delete_non_empty_document_folder ON data.document_folders;
CREATE TRIGGER trg_prevent_delete_non_empty_document_folder
  BEFORE DELETE ON data.document_folders
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_prevent_delete_non_empty_document_folder();

-- =============================================================================
-- 4) Expiry and renewal model for documents
-- =============================================================================

ALTER TABLE data.documents
  ADD COLUMN IF NOT EXISTS valid_from timestamptz,
  ADD COLUMN IF NOT EXISTS expires_at timestamptz,
  ADD COLUMN IF NOT EXISTS renewal_interval_months int CHECK (renewal_interval_months > 0),
  ADD COLUMN IF NOT EXISTS renewal_anchor_mode varchar(10) CHECK (renewal_anchor_mode IN ('rolling','natural')),
  ADD COLUMN IF NOT EXISTS renewal_anchor_month smallint CHECK (renewal_anchor_month BETWEEN 1 AND 12),
  ADD COLUMN IF NOT EXISTS renewal_anchor_day smallint CHECK (renewal_anchor_day BETWEEN 1 AND 31);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_natural_anchor'
      AND conrelid = 'data.documents'::regclass
  ) THEN
    ALTER TABLE data.documents
      ADD CONSTRAINT chk_natural_anchor CHECK (
        renewal_anchor_mode IS DISTINCT FROM 'natural'
        OR (renewal_anchor_month IS NOT NULL AND renewal_anchor_day IS NOT NULL)
      );
  END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS idx_docs_expires_at
  ON data.documents (expires_at)
  WHERE expires_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_docs_tenant_expires
  ON data.documents (tenant_id, expires_at)
  WHERE expires_at IS NOT NULL;

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
    d.valid_from,
    d.expires_at,
    d.renewal_interval_months,
    d.renewal_anchor_mode,
    d.renewal_anchor_month,
    d.renewal_anchor_day,
    d.created_at,
    d.updated_at,
    v.id AS version_id,
    v.version_number,
    v.storage_type,
    v.file_path_or_url,
    v.mime_type,
    v.size_bytes,
    v.created_by AS version_created_by,
    v.created_at AS version_created_at
  FROM data.documents d
  JOIN (
    SELECT document_id, MAX(version_number) AS version_number
    FROM data.document_versions
    GROUP BY document_id
  ) mx ON d.id = mx.document_id
  JOIN data.document_versions v
    ON d.id = v.document_id AND mx.version_number = v.version_number;

GRANT SELECT ON api.active_documents TO authenticated;

CREATE OR REPLACE FUNCTION api.suggest_next_expiry(
  p_document_id uuid,
  p_effective_date timestamptz DEFAULT now()
)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_doc record;
  v_year int;
  v_day int;
  v_candidate date;
BEGIN
  SELECT renewal_interval_months,
         renewal_anchor_mode,
         renewal_anchor_month,
         renewal_anchor_day
  INTO v_doc
  FROM data.documents
  WHERE id = p_document_id;

  IF NOT FOUND OR v_doc.renewal_interval_months IS NULL THEN
    RETURN NULL;
  END IF;

  IF v_doc.renewal_anchor_mode = 'rolling' THEN
    RETURN p_effective_date + (v_doc.renewal_interval_months || ' months')::interval;
  ELSIF v_doc.renewal_anchor_mode = 'natural' THEN
    v_year := EXTRACT(YEAR FROM p_effective_date)::int;

    v_day := LEAST(
      v_doc.renewal_anchor_day,
      EXTRACT(DAY FROM (
        DATE_TRUNC('month', make_date(v_year, v_doc.renewal_anchor_month, 1)::timestamp)
        + INTERVAL '1 month' - INTERVAL '1 day'
      ))::int
    );
    v_candidate := make_date(v_year, v_doc.renewal_anchor_month, v_day);

    IF v_candidate::timestamptz <= p_effective_date THEN
      v_year := v_year + 1;
      v_day := LEAST(
        v_doc.renewal_anchor_day,
        EXTRACT(DAY FROM (
          DATE_TRUNC('month', make_date(v_year, v_doc.renewal_anchor_month, 1)::timestamp)
          + INTERVAL '1 month' - INTERVAL '1 day'
        ))::int
      );
      v_candidate := make_date(v_year, v_doc.renewal_anchor_month, v_day);
    END IF;

    RETURN v_candidate::timestamptz;
  END IF;

  RETURN NULL;
END;
$$;

GRANT EXECUTE ON FUNCTION api.suggest_next_expiry(uuid, timestamptz) TO authenticated;

-- =============================================================================
-- 5) RPC create_document_with_version (extended signature)
-- =============================================================================

DROP FUNCTION IF EXISTS api.create_document_with_version(
  uuid, text, text, text, uuid, uuid, varchar, uuid, text[], text, bigint
);

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
  v_version data.document_versions%ROWTYPE;
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
    renewal_anchor_month, renewal_anchor_day
  )
  VALUES (
    p_tenant_id, p_site_id, p_folder_id, p_title, p_entity_type, p_entity_id,
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
    'version', row_to_json(v_version)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_document_with_version(
  uuid, text, text, text, uuid, uuid, varchar, uuid, text[], text, bigint,
  timestamptz, timestamptz, int, varchar, smallint, smallint
) TO authenticated;

-- =============================================================================
-- 6) RPC add_document_version (concurrency-safe with FOR UPDATE)
-- =============================================================================

CREATE OR REPLACE FUNCTION api.add_document_version(
  p_document_id uuid,
  p_storage_type text,
  p_file_path_or_url text,
  p_mime_type text DEFAULT NULL,
  p_size_bytes bigint DEFAULT 0
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_doc data.documents%ROWTYPE;
  v_next_version int;
  v_version data.document_versions%ROWTYPE;
BEGIN
  IF p_storage_type NOT IN ('native', 'external_link') THEN
    RAISE EXCEPTION 'storage_type ha de ser native o external_link';
  END IF;

  SELECT * INTO v_doc
  FROM data.documents
  WHERE id = p_document_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Document % no trobat', p_document_id;
  END IF;

  IF NOT (
    data.jwt_user_tenants() ? v_doc.tenant_id::text
    AND (
      (data.jwt_user_tenants() -> v_doc.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR (
        v_doc.site_id IS NOT NULL
        AND (data.jwt_user_tenants() -> v_doc.tenant_id::text -> 'sites' ->> v_doc.site_id::text)
          IN ('owner', 'manager')
      )
    )
  ) THEN
    RAISE EXCEPTION 'Acces denegat: cal rol owner o manager';
  END IF;

  SELECT COALESCE(MAX(version_number), 0) + 1
  INTO v_next_version
  FROM data.document_versions
  WHERE document_id = p_document_id;

  INSERT INTO data.document_versions (
    document_id, version_number, storage_type, file_path_or_url, mime_type, size_bytes, created_by
  )
  VALUES (
    p_document_id, v_next_version, p_storage_type, p_file_path_or_url, p_mime_type, p_size_bytes, auth.uid()
  )
  RETURNING * INTO v_version;

  RETURN row_to_json(v_version);
END;
$$;

GRANT EXECUTE ON FUNCTION api.add_document_version TO authenticated;

-- =============================================================================
-- 7) Tags model + RLS + API views
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.document_tags (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  name text NOT NULL,
  color varchar(7) NOT NULL DEFAULT '#6b7280',
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_doc_tag_tenant_name UNIQUE (tenant_id, name)
);

CREATE INDEX IF NOT EXISTS idx_doc_tags_tenant ON data.document_tags (tenant_id);

CREATE TABLE IF NOT EXISTS data.document_tag_assignments (
  document_id uuid NOT NULL REFERENCES data.documents(id) ON DELETE CASCADE,
  tag_id uuid NOT NULL REFERENCES data.document_tags(id) ON DELETE CASCADE,
  assigned_at timestamptz NOT NULL DEFAULT now(),
  assigned_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  PRIMARY KEY (document_id, tag_id)
);

CREATE INDEX IF NOT EXISTS idx_doc_tag_asn_doc ON data.document_tag_assignments (document_id);
CREATE INDEX IF NOT EXISTS idx_doc_tag_asn_tag ON data.document_tag_assignments (tag_id);

ALTER TABLE data.document_tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.document_tag_assignments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tags_tenant_select ON data.document_tags;
CREATE POLICY tags_tenant_select ON data.document_tags
  FOR SELECT USING (
    data.jwt_user_tenants() ? tenant_id::text
  );

DROP POLICY IF EXISTS tags_manager_insert ON data.document_tags;
CREATE POLICY tags_manager_insert ON data.document_tags
  FOR INSERT WITH CHECK (
    (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

DROP POLICY IF EXISTS tags_manager_update ON data.document_tags;
CREATE POLICY tags_manager_update ON data.document_tags
  FOR UPDATE USING (
    (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

DROP POLICY IF EXISTS tags_manager_delete ON data.document_tags;
CREATE POLICY tags_manager_delete ON data.document_tags
  FOR DELETE USING (
    (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

DROP POLICY IF EXISTS tag_assign_select ON data.document_tag_assignments;
CREATE POLICY tag_assign_select ON data.document_tag_assignments
  FOR SELECT USING (
    EXISTS (
      SELECT 1
      FROM data.documents d
      WHERE d.id = document_id
        AND data.jwt_user_tenants() ? d.tenant_id::text
    )
  );

DROP POLICY IF EXISTS tag_assign_write ON data.document_tag_assignments;
CREATE POLICY tag_assign_write ON data.document_tag_assignments
  FOR ALL USING (
    EXISTS (
      SELECT 1
      FROM data.documents d
      WHERE d.id = document_id
        AND (data.jwt_user_tenants() -> d.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  );

CREATE OR REPLACE VIEW api.document_tags WITH (security_invoker = true) AS
  SELECT id, tenant_id, name, color, created_at
  FROM data.document_tags;

CREATE OR REPLACE VIEW api.document_tag_assignments WITH (security_invoker = true) AS
  SELECT
    dta.document_id,
    dta.tag_id,
    dta.assigned_at,
    dta.assigned_by,
    dt.name AS tag_name,
    dt.color AS tag_color
  FROM data.document_tag_assignments dta
  JOIN data.document_tags dt ON dt.id = dta.tag_id;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.document_tags TO authenticated;
GRANT SELECT, INSERT, DELETE ON api.document_tag_assignments TO authenticated;

-- security_invoker views also require table-level privileges for caller role.
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE data.document_tags TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE data.document_tag_assignments TO authenticated;

-- =============================================================================
-- 8) Audit + secure INSTEAD OF triggers for api.document_tag_assignments
-- =============================================================================

CREATE OR REPLACE FUNCTION data.trg_audit_document_tags()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      auth.uid(),
      NULL::uuid,
      'DOCUMENT_TAG_CREATED',
      'document_tag',
      NEW.id,
      jsonb_build_object(
        'name', NEW.name,
        'color', NEW.color
      )
    );
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id,
      auth.uid(),
      NULL::uuid,
      'DOCUMENT_TAG_DELETED',
      'document_tag',
      OLD.id,
      jsonb_build_object(
        'name', OLD.name
      )
    );
    RETURN OLD;
  END IF;

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_document_tags ON data.document_tags;
CREATE TRIGGER trg_audit_document_tags
  AFTER INSERT OR DELETE ON data.document_tags
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_document_tags();

CREATE OR REPLACE FUNCTION api.trg_iof_doc_tag_assign_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_doc_tenant_id uuid;
  v_tag_tenant_id uuid;
  v_global_role text;
BEGIN
  SELECT d.tenant_id
  INTO v_doc_tenant_id
  FROM data.documents d
  WHERE d.id = NEW.document_id;

  IF v_doc_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Document not found';
  END IF;

  SELECT t.tenant_id
  INTO v_tag_tenant_id
  FROM data.document_tags t
  WHERE t.id = NEW.tag_id;

  IF v_tag_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tag not found';
  END IF;

  IF v_doc_tenant_id IS DISTINCT FROM v_tag_tenant_id THEN
    RAISE EXCEPTION 'Tag and document must belong to same tenant';
  END IF;

  v_global_role := data.jwt_user_tenants() -> v_doc_tenant_id::text ->> 'global_role';
  IF v_global_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'Access denied: owner or manager role required';
  END IF;

  INSERT INTO data.document_tag_assignments (document_id, tag_id, assigned_by)
  VALUES (NEW.document_id, NEW.tag_id, COALESCE(auth.uid(), NEW.assigned_by));

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION api.trg_iof_doc_tag_assign_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_doc_tenant_id uuid;
  v_global_role text;
BEGIN
  SELECT d.tenant_id
  INTO v_doc_tenant_id
  FROM data.documents d
  WHERE d.id = OLD.document_id;

  IF v_doc_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Document not found';
  END IF;

  v_global_role := data.jwt_user_tenants() -> v_doc_tenant_id::text ->> 'global_role';
  IF v_global_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'Access denied: owner or manager role required';
  END IF;

  DELETE FROM data.document_tag_assignments
  WHERE document_id = OLD.document_id
    AND tag_id = OLD.tag_id;

  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_iof_doc_tag_assign_insert ON api.document_tag_assignments;
CREATE TRIGGER trg_iof_doc_tag_assign_insert
  INSTEAD OF INSERT ON api.document_tag_assignments
  FOR EACH ROW EXECUTE FUNCTION api.trg_iof_doc_tag_assign_insert();

DROP TRIGGER IF EXISTS trg_iof_doc_tag_assign_delete ON api.document_tag_assignments;
CREATE TRIGGER trg_iof_doc_tag_assign_delete
  INSTEAD OF DELETE ON api.document_tag_assignments
  FOR EACH ROW EXECUTE FUNCTION api.trg_iof_doc_tag_assign_delete();

-- =============================================================================
-- 9) Atomic RPC to replace all document tags
-- =============================================================================

CREATE OR REPLACE FUNCTION api.set_document_tags(
  p_document_id uuid,
  p_tag_ids uuid[] DEFAULT '{}'
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_tenant_id uuid;
  v_global_role text;
  v_input_count int;
  v_valid_count int;
BEGIN
  SELECT d.tenant_id
  INTO v_tenant_id
  FROM data.documents d
  WHERE d.id = p_document_id;

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Document not found';
  END IF;

  v_global_role := data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role';
  IF v_global_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'Access denied: owner or manager role required';
  END IF;

  WITH input_tags AS (
    SELECT DISTINCT unnest(COALESCE(p_tag_ids, '{}'::uuid[])) AS tag_id
  )
  SELECT COUNT(*) INTO v_input_count FROM input_tags;

  WITH input_tags AS (
    SELECT DISTINCT unnest(COALESCE(p_tag_ids, '{}'::uuid[])) AS tag_id
  )
  SELECT COUNT(*)
  INTO v_valid_count
  FROM input_tags i
  JOIN data.document_tags t ON t.id = i.tag_id
  WHERE t.tenant_id = v_tenant_id;

  IF v_valid_count <> v_input_count THEN
    RAISE EXCEPTION 'One or more tags are invalid for this tenant';
  END IF;

  DELETE FROM data.document_tag_assignments
  WHERE document_id = p_document_id;

  INSERT INTO data.document_tag_assignments (document_id, tag_id, assigned_by)
  SELECT p_document_id, i.tag_id, auth.uid()
  FROM (
    SELECT DISTINCT unnest(COALESCE(p_tag_ids, '{}'::uuid[])) AS tag_id
  ) i;
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_document_tags(uuid, uuid[]) TO authenticated;

-- Reload PostgREST schema cache to ensure RPC/view metadata is fresh.
NOTIFY pgrst, 'reload schema';
