-- =============================================================================
-- Field-work media on Fitxers (file_nodes): entity link + folder helpers
-- =============================================================================

ALTER TABLE data.file_nodes
  ADD COLUMN IF NOT EXISTS entity_type text,
  ADD COLUMN IF NOT EXISTS entity_id uuid;

COMMENT ON COLUMN data.file_nodes.entity_type IS
  'Optional polymorphic link (project, task, checklist_run_item, …).';
COMMENT ON COLUMN data.file_nodes.entity_id IS
  'Optional polymorphic entity id paired with entity_type.';

CREATE INDEX IF NOT EXISTS idx_file_nodes_entity
  ON data.file_nodes (tenant_id, entity_type, entity_id)
  WHERE entity_type IS NOT NULL AND entity_id IS NOT NULL AND is_deleted = false;

CREATE INDEX IF NOT EXISTS idx_file_nodes_metadata_kind
  ON data.file_nodes ((metadata->>'kind'))
  WHERE metadata ? 'kind' AND is_deleted = false;

-- Recreate writable view with entity + site columns
DROP VIEW IF EXISTS api.file_nodes CASCADE;
CREATE VIEW api.file_nodes
  WITH (security_invoker = true) AS
  SELECT
    fn.id,
    fn.tenant_id,
    fn.parent_id,
    fn.created_by,
    fn.node_type,
    fn.name,
    fn.path,
    fn.namespace,
    fn.mime_type,
    fn.size_bytes,
    fn.checksum,
    fn.processing_status,
    fn.metadata,
    fn.created_at,
    fn.updated_at,
    fn.storage_key,
    fn.storage_provider_id,
    fn.site_id,
    fn.entity_type,
    fn.entity_id,
    EXISTS (
      SELECT 1 FROM data.node_acl a WHERE a.node_id = fn.id
    ) AS is_restricted,
    CASE
      WHEN EXISTS (SELECT 1 FROM data.node_acl a WHERE a.node_id = fn.id)
      THEN EXISTS (
        SELECT 1 FROM data.node_acl a
        JOIN data.node_acl_grants g ON g.acl_id = a.id
        WHERE a.node_id = fn.id
          AND (
            g.grantee_user_id = auth.uid()
            OR g.grantee_role = data.my_role_in(fn.tenant_id)
          )
      )
      ELSE true
    END AS can_access_for_me
  FROM data.file_nodes fn
  WHERE fn.is_deleted = false;

GRANT SELECT, INSERT, UPDATE ON api.file_nodes TO authenticated, service_role;

CREATE RULE "api_file_nodes_insert" AS ON INSERT TO api.file_nodes
  DO INSTEAD
  INSERT INTO data.file_nodes (
    tenant_id, parent_id, created_by, node_type, name,
    namespace, mime_type, size_bytes, metadata, site_id, entity_type, entity_id
  )
  VALUES (
    NEW.tenant_id, NEW.parent_id, auth.uid(), NEW.node_type, NEW.name,
    COALESCE(NEW.namespace, 'repository'), NEW.mime_type, COALESCE(NEW.size_bytes, 0),
    NEW.metadata, NEW.site_id, NEW.entity_type, NEW.entity_id
  )
  RETURNING
    id, tenant_id, parent_id, created_by, node_type, name, path,
    namespace, mime_type, size_bytes, checksum, processing_status,
    metadata, created_at, updated_at, storage_key, storage_provider_id,
    site_id, entity_type, entity_id,
    false AS is_restricted,
    true  AS can_access_for_me;

CREATE RULE "api_file_nodes_update" AS ON UPDATE TO api.file_nodes
  DO INSTEAD
  UPDATE data.file_nodes
  SET name        = COALESCE(NEW.name, OLD.name),
      metadata    = COALESCE(NEW.metadata, OLD.metadata),
      entity_type = COALESCE(NEW.entity_type, OLD.entity_type),
      entity_id   = COALESCE(NEW.entity_id, OLD.entity_id),
      site_id     = COALESCE(NEW.site_id, OLD.site_id)
  WHERE id = OLD.id
  RETURNING
    id, tenant_id, parent_id, created_by, node_type, name, path,
    namespace, mime_type, size_bytes, checksum, processing_status,
    metadata, created_at, updated_at, storage_key, storage_provider_id,
    site_id, entity_type, entity_id,
    false AS is_restricted,
    true  AS can_access_for_me;

-- ---------------------------------------------------------------------------
-- Ensure site root + project folder + Fotos/Adjunts/Evidència (lazy, idempotent)
-- Returns jsonb: { site_folder_id, project_folder_id, photos_id, attachments_id, evidence_id }
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.ensure_field_project_folders(p_project_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_proj data.projects%ROWTYPE;
  v_site_name text;
  v_uid uuid := auth.uid();
  v_site_folder_id uuid;
  v_proj_folder_id uuid;
  v_photos_id uuid;
  v_attach_id uuid;
  v_evidence_id uuid;
  v_site_folder_name text;
  v_proj_folder_name text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;

  SELECT * INTO v_proj FROM data.projects WHERE id = p_project_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'project_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT data.is_active_tenant_member(v_proj.tenant_id, v_uid) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_proj.site_id IS NULL THEN
    RAISE EXCEPTION 'project_requires_site' USING ERRCODE = 'check_violation';
  END IF;

  SELECT COALESCE(NULLIF(btrim(s.name), ''), 'Site')
  INTO v_site_name
  FROM data.sites s
  WHERE s.id = v_proj.site_id;

  v_site_folder_name := 'Arxius d''obra — ' || COALESCE(v_site_name, 'Site');

  SELECT id INTO v_site_folder_id
  FROM data.file_nodes
  WHERE tenant_id = v_proj.tenant_id
    AND site_id = v_proj.site_id
    AND node_type = 'folder'
    AND is_deleted = false
    AND parent_id IS NULL
    AND metadata->>'kind' = 'field_work_root'
  LIMIT 1;

  IF v_site_folder_id IS NULL THEN
    INSERT INTO data.file_nodes (
      tenant_id, parent_id, created_by, node_type, name, namespace, site_id, metadata
    ) VALUES (
      v_proj.tenant_id, NULL, v_uid, 'folder', v_site_folder_name, 'repository', v_proj.site_id,
      jsonb_build_object('kind', 'field_work_root', 'site_id', v_proj.site_id)
    )
    RETURNING id INTO v_site_folder_id;
  END IF;

  v_proj_folder_name := left(COALESCE(NULLIF(btrim(v_proj.name), ''), 'OS') || ' [' || substr(v_proj.id::text, 1, 8) || ']', 180);

  SELECT id INTO v_proj_folder_id
  FROM data.file_nodes
  WHERE tenant_id = v_proj.tenant_id
    AND parent_id = v_site_folder_id
    AND node_type = 'folder'
    AND is_deleted = false
    AND entity_type = 'project'
    AND entity_id = v_proj.id
  LIMIT 1;

  IF v_proj_folder_id IS NULL THEN
    INSERT INTO data.file_nodes (
      tenant_id, parent_id, created_by, node_type, name, namespace, site_id,
      entity_type, entity_id, metadata
    ) VALUES (
      v_proj.tenant_id, v_site_folder_id, v_uid, 'folder', v_proj_folder_name, 'repository',
      v_proj.site_id, 'project', v_proj.id,
      jsonb_build_object('kind', 'field_project', 'project_id', v_proj.id)
    )
    RETURNING id INTO v_proj_folder_id;
  END IF;

  -- Subfolders
  SELECT id INTO v_photos_id FROM data.file_nodes
  WHERE parent_id = v_proj_folder_id AND node_type = 'folder' AND is_deleted = false
    AND metadata->>'kind' = 'field_photos' LIMIT 1;
  IF v_photos_id IS NULL THEN
    INSERT INTO data.file_nodes (tenant_id, parent_id, created_by, node_type, name, namespace, site_id, entity_type, entity_id, metadata)
    VALUES (v_proj.tenant_id, v_proj_folder_id, v_uid, 'folder', 'Fotos', 'repository', v_proj.site_id, 'project', v_proj.id,
      jsonb_build_object('kind', 'field_photos', 'project_id', v_proj.id))
    RETURNING id INTO v_photos_id;
  END IF;

  SELECT id INTO v_attach_id FROM data.file_nodes
  WHERE parent_id = v_proj_folder_id AND node_type = 'folder' AND is_deleted = false
    AND metadata->>'kind' = 'field_attachments' LIMIT 1;
  IF v_attach_id IS NULL THEN
    INSERT INTO data.file_nodes (tenant_id, parent_id, created_by, node_type, name, namespace, site_id, entity_type, entity_id, metadata)
    VALUES (v_proj.tenant_id, v_proj_folder_id, v_uid, 'folder', 'Adjunts', 'repository', v_proj.site_id, 'project', v_proj.id,
      jsonb_build_object('kind', 'field_attachments', 'project_id', v_proj.id))
    RETURNING id INTO v_attach_id;
  END IF;

  SELECT id INTO v_evidence_id FROM data.file_nodes
  WHERE parent_id = v_proj_folder_id AND node_type = 'folder' AND is_deleted = false
    AND metadata->>'kind' = 'field_evidence' LIMIT 1;
  IF v_evidence_id IS NULL THEN
    INSERT INTO data.file_nodes (tenant_id, parent_id, created_by, node_type, name, namespace, site_id, entity_type, entity_id, metadata)
    VALUES (v_proj.tenant_id, v_proj_folder_id, v_uid, 'folder', 'Evidència', 'repository', v_proj.site_id, 'project', v_proj.id,
      jsonb_build_object('kind', 'field_evidence', 'project_id', v_proj.id))
    RETURNING id INTO v_evidence_id;
  END IF;

  RETURN jsonb_build_object(
    'site_folder_id', v_site_folder_id,
    'project_folder_id', v_proj_folder_id,
    'photos_id', v_photos_id,
    'attachments_id', v_attach_id,
    'evidence_id', v_evidence_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.ensure_field_project_folders(uuid) TO authenticated, service_role;

-- Attach entity fields after pending upload confirm
CREATE OR REPLACE FUNCTION api.attach_file_node_entity(
  p_node_id uuid,
  p_entity_type text,
  p_entity_id uuid,
  p_site_id uuid DEFAULT NULL,
  p_metadata jsonb DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_node data.file_nodes%ROWTYPE;
BEGIN
  SELECT * INTO v_node FROM data.file_nodes WHERE id = p_node_id AND is_deleted = false;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'node_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF NOT data.is_active_tenant_member(v_node.tenant_id, auth.uid()) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.file_nodes
  SET entity_type = p_entity_type,
      entity_id = p_entity_id,
      site_id = COALESCE(p_site_id, site_id),
      metadata = CASE
        WHEN p_metadata IS NULL THEN metadata
        ELSE COALESCE(metadata, '{}'::jsonb) || p_metadata
      END,
      updated_at = now()
  WHERE id = p_node_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.attach_file_node_entity(uuid, text, uuid, uuid, jsonb) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.count_field_project_files(p_project_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = data, public
AS $$
  SELECT COUNT(*)::int
  FROM data.file_nodes fn
  WHERE fn.is_deleted = false
    AND fn.node_type = 'file'
    AND (
      (fn.entity_type = 'project' AND fn.entity_id = p_project_id)
      OR (fn.metadata->>'project_id' = p_project_id::text)
    );
$$;

GRANT EXECUTE ON FUNCTION api.count_field_project_files(uuid) TO authenticated, service_role;

-- Soft-trash all field-work files/folders for a project (top-level project folder)
CREATE OR REPLACE FUNCTION api.trash_field_project_files(p_project_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_proj data.projects%ROWTYPE;
  v_folder_id uuid;
  v_count int := 0;
BEGIN
  SELECT * INTO v_proj FROM data.projects WHERE id = p_project_id;
  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  IF NOT data.is_active_tenant_member(v_proj.tenant_id, auth.uid()) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT id INTO v_folder_id
  FROM data.file_nodes
  WHERE tenant_id = v_proj.tenant_id
    AND entity_type = 'project'
    AND entity_id = p_project_id
    AND node_type = 'folder'
    AND metadata->>'kind' = 'field_project'
    AND is_deleted = false
  LIMIT 1;

  IF v_folder_id IS NULL THEN
    RETURN 0;
  END IF;

  -- Soft-delete subtree (folder + descendants via path / parent walk)
  WITH RECURSIVE tree AS (
    SELECT id FROM data.file_nodes WHERE id = v_folder_id
    UNION ALL
    SELECT c.id FROM data.file_nodes c
    JOIN tree t ON c.parent_id = t.id
    WHERE c.is_deleted = false
  )
  UPDATE data.file_nodes fn
  SET is_deleted = true,
      deleted_at = now(),
      deleted_by = auth.uid()
  FROM tree
  WHERE fn.id = tree.id
    AND fn.is_deleted = false;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION api.trash_field_project_files(uuid) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
