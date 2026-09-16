-- CF-18 follow-up: commercial PDFs live under a stable per-client DMS folder
-- with an English subfolder (quotes / delivery-notes). Folder identity is
-- entity_type=contact + entity_id=client_id, not the display name. Subfolder
-- names stay English so CA/ES/EN UIs do not create duplicate trees.

CREATE OR REPLACE FUNCTION data.sanitize_document_folder_name(p_name text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = data
AS $$
  SELECT COALESCE(
    NULLIF(
      left(
        btrim(
          regexp_replace(
            regexp_replace(COALESCE(p_name, ''), '[/\\:*?"<>|[:cntrl:]]+', ' ', 'g'),
            '\s+',
            ' ',
            'g'
          )
        ),
        80
      ),
      ''
    ),
    'client'
  );
$$;

COMMENT ON FUNCTION data.sanitize_document_folder_name(text) IS
  'Filesystem-safe folder label: strips control chars and path punctuation, collapses space, max 80.';

CREATE UNIQUE INDEX IF NOT EXISTS uq_document_folders_contact_root
  ON data.document_folders (tenant_id, entity_id)
  WHERE entity_type = 'contact'
    AND parent_id IS NULL
    AND entity_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_document_folders_contact_child_name
  ON data.document_folders (tenant_id, entity_id, name)
  WHERE entity_type = 'contact'
    AND parent_id IS NOT NULL
    AND entity_id IS NOT NULL;

CREATE OR REPLACE FUNCTION data.commercial_dms_leaf_name(p_doc_type text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = data
AS $$
  SELECT CASE
    WHEN p_doc_type IN ('quote', 'quote_amendment') THEN 'quotes'
    WHEN p_doc_type = 'delivery_note' THEN 'delivery-notes'
    ELSE 'quotes'
  END;
$$;

CREATE OR REPLACE FUNCTION data.ensure_commercial_dms_folder(
  p_tenant_id uuid,
  p_client_id uuid,
  p_doc_type text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_contact data.contacts%ROWTYPE;
  v_root data.document_folders%ROWTYPE;
  v_leaf data.document_folders%ROWTYPE;
  v_leaf_name text;
  v_root_name text;
BEGIN
  IF p_tenant_id IS NULL OR p_client_id IS NULL THEN
    RAISE EXCEPTION 'client_required' USING ERRCODE = 'not_null_violation';
  END IF;

  SELECT * INTO v_contact
  FROM data.contacts
  WHERE id = p_client_id
    AND tenant_id = p_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'client_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  v_leaf_name := data.commercial_dms_leaf_name(p_doc_type);
  v_root_name := data.sanitize_document_folder_name(
    COALESCE(NULLIF(btrim(v_contact.display_name), ''), v_contact.legal_name)
  ) || ' [' || substr(v_contact.id::text, 1, 8) || ']';

  SELECT * INTO v_root
  FROM data.document_folders
  WHERE tenant_id = p_tenant_id
    AND entity_type = 'contact'
    AND entity_id = p_client_id
    AND parent_id IS NULL
  LIMIT 1;

  IF NOT FOUND THEN
    BEGIN
      INSERT INTO data.document_folders (
        tenant_id, site_id, parent_id, name, entity_type, entity_id, required_permissions
      ) VALUES (
        p_tenant_id, NULL, NULL, v_root_name, 'contact', p_client_id, '{}'
      )
      RETURNING * INTO v_root;
    EXCEPTION WHEN unique_violation THEN
      SELECT * INTO v_root
      FROM data.document_folders
      WHERE tenant_id = p_tenant_id
        AND entity_type = 'contact'
        AND entity_id = p_client_id
        AND parent_id IS NULL
      LIMIT 1;
    END;
  END IF;

  SELECT * INTO v_leaf
  FROM data.document_folders
  WHERE tenant_id = p_tenant_id
    AND entity_type = 'contact'
    AND entity_id = p_client_id
    AND parent_id = v_root.id
    AND name = v_leaf_name
  LIMIT 1;

  IF NOT FOUND THEN
    BEGIN
      INSERT INTO data.document_folders (
        tenant_id, site_id, parent_id, name, entity_type, entity_id, required_permissions
      ) VALUES (
        p_tenant_id, NULL, v_root.id, v_leaf_name, 'contact', p_client_id, '{}'
      )
      RETURNING * INTO v_leaf;
    EXCEPTION WHEN unique_violation THEN
      SELECT * INTO v_leaf
      FROM data.document_folders
      WHERE tenant_id = p_tenant_id
        AND entity_type = 'contact'
        AND entity_id = p_client_id
        AND parent_id = v_root.id
        AND name = v_leaf_name
      LIMIT 1;
    END;
  END IF;

  RETURN v_leaf.id;
END;
$$;

COMMENT ON FUNCTION data.ensure_commercial_dms_folder(uuid, uuid, text) IS
  'Idempotent client root (fixed sanitized name + contact id suffix) and English leaf quotes|delivery-notes.';

REVOKE ALL ON FUNCTION data.ensure_commercial_dms_folder(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.ensure_commercial_dms_folder(uuid, uuid, text) TO service_role;

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

  -- Commercial PDFs are keyed to commercial_document but filed under the client.
  IF NEW.entity_type = 'commercial_document'
     AND v_folder.entity_type = 'contact'
     AND v_folder.entity_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM data.commercial_documents cd
      WHERE cd.id = NEW.entity_id
        AND cd.tenant_id = NEW.tenant_id
        AND cd.client_id = v_folder.entity_id
    ) THEN
      RAISE EXCEPTION
        'Commercial document % does not belong to contact folder %',
        NEW.entity_id, v_folder.entity_id;
    END IF;
    RETURN NEW;
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

CREATE OR REPLACE FUNCTION api.create_commercial_rendered_document_internal(
  p_tenant_id uuid,
  p_commercial_document_id uuid,
  p_title text,
  p_file_path_or_url text,
  p_mime_type text,
  p_size_bytes bigint,
  p_created_by uuid DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_cd data.commercial_documents%ROWTYPE;
  v_existing uuid;
  v_folder_id uuid;
  v_document data.documents%ROWTYPE;
  v_version data.document_versions%ROWTYPE;
BEGIN
  SELECT * INTO v_cd
  FROM data.commercial_documents
  WHERE id = p_commercial_document_id
    AND tenant_id = p_tenant_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  v_folder_id := data.ensure_commercial_dms_folder(
    p_tenant_id, v_cd.client_id, v_cd.doc_type
  );

  SELECT id INTO v_existing
  FROM data.documents
  WHERE tenant_id = p_tenant_id
    AND entity_type = 'commercial_document'
    AND entity_id = p_commercial_document_id
  LIMIT 1;

  IF v_existing IS NOT NULL THEN
    SELECT * INTO v_document FROM data.documents WHERE id = v_existing FOR UPDATE;
    IF v_document.folder_id IS DISTINCT FROM v_folder_id THEN
      UPDATE data.documents
      SET folder_id = v_folder_id
      WHERE id = v_existing
      RETURNING * INTO v_document;
    END IF;

    INSERT INTO data.document_versions (
      document_id, version_number, storage_type, file_path_or_url,
      mime_type, size_bytes, created_by
    )
    VALUES (
      v_existing,
      COALESCE((
        SELECT MAX(version_number)
        FROM data.document_versions
        WHERE document_id = v_existing
      ), 0) + 1,
      'native',
      p_file_path_or_url,
      p_mime_type,
      p_size_bytes,
      p_created_by
    )
    RETURNING * INTO v_version;
  ELSE
    INSERT INTO data.documents (
      tenant_id, title, folder_id, entity_type, entity_id, category,
      required_permissions, created_by
    ) VALUES (
      p_tenant_id,
      p_title,
      v_folder_id,
      'commercial_document',
      p_commercial_document_id,
      'commercial',
      '{}',
      p_created_by
    )
    RETURNING * INTO v_document;

    INSERT INTO data.document_versions (
      document_id, version_number, storage_type, file_path_or_url,
      mime_type, size_bytes, created_by
    ) VALUES (
      v_document.id, 1, 'native', p_file_path_or_url, p_mime_type, p_size_bytes, p_created_by
    )
    RETURNING * INTO v_version;
  END IF;

  RETURN json_build_object(
    'document', row_to_json(v_document),
    'version', row_to_json(v_version)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.create_commercial_rendered_document_internal(
  uuid, uuid, text, text, text, bigint, uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_commercial_rendered_document_internal(
  uuid, uuid, text, text, text, bigint, uuid
) TO service_role;

DO $$
DECLARE
  r record;
  v_folder uuid;
BEGIN
  FOR r IN
    SELECT d.id, d.tenant_id, cd.client_id, cd.doc_type
    FROM data.documents d
    JOIN data.commercial_documents cd
      ON cd.id = d.entity_id
     AND cd.tenant_id = d.tenant_id
    WHERE d.entity_type = 'commercial_document'
      AND d.folder_id IS NULL
  LOOP
    v_folder := data.ensure_commercial_dms_folder(r.tenant_id, r.client_id, r.doc_type);
    UPDATE data.documents
    SET folder_id = v_folder
    WHERE id = r.id;
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';
