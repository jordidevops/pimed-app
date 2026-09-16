-- CF-18: branded commercial PDF artifact (DMS link), not formal signing.
-- document_template_id is optional letterhead; rendered_document_id is the PDF.

INSERT INTO data.entity_types (
  code, label_key,
  supports_timeline, supports_documents, supports_signing, supports_subscriptions
)
SELECT 'commercial_document', 'entity_types.commercial_document', false, true, false, false
WHERE NOT EXISTS (
  SELECT 1 FROM data.entity_types et WHERE et.code = 'commercial_document'
);

DO $$
DECLARE
  v_con text;
BEGIN
  SELECT c.conname INTO v_con
  FROM pg_constraint c
  WHERE c.conrelid = 'data.document_pdf_jobs'::regclass
    AND c.contype = 'c'
    AND pg_get_constraintdef(c.oid) ILIKE '%source_type%';
  IF v_con IS NOT NULL THEN
    EXECUTE format('ALTER TABLE data.document_pdf_jobs DROP CONSTRAINT %I', v_con);
  END IF;
END $$;
ALTER TABLE data.document_pdf_jobs
  ADD CONSTRAINT document_pdf_jobs_source_type_check
  CHECK (source_type IN ('template_locale', 'document_existing', 'commercial_document'));

ALTER TABLE data.commercial_documents
  ADD COLUMN IF NOT EXISTS document_template_id uuid
    REFERENCES data.document_templates(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS rendered_document_id uuid
    REFERENCES data.documents(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS pdf_job_id uuid
    REFERENCES data.document_pdf_jobs(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_commercial_documents_rendered
  ON data.commercial_documents (rendered_document_id)
  WHERE rendered_document_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_documents_commercial_entity
  ON data.documents (tenant_id, entity_id)
  WHERE entity_type = 'commercial_document' AND entity_id IS NOT NULL;

ALTER TABLE data.commercial_document_events
  DROP CONSTRAINT IF EXISTS commercial_document_events_event_type_check;

ALTER TABLE data.commercial_document_events
  ADD CONSTRAINT commercial_document_events_event_type_check
  CHECK (event_type IN (
    'issued', 'sent', 'viewed', 'accepted', 'rejected',
    'signed', 'superseded', 'cancelled', 'pdf_rendered'
  ));

CREATE OR REPLACE FUNCTION data.resolve_commercial_document_template_id(p_tenant_id uuid)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_settings_id text;
  v_id uuid;
BEGIN
  SELECT NULLIF(btrim(settings #>> '{commercial,document_template_id}'), '')
  INTO v_settings_id
  FROM data.tenants
  WHERE id = p_tenant_id;

  IF v_settings_id IS NOT NULL THEN
    BEGIN
      v_id := v_settings_id::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      v_id := NULL;
    END;
    IF v_id IS NOT NULL AND EXISTS (
      SELECT 1
      FROM data.document_templates t
      WHERE t.id = v_id
        AND t.is_active
        AND t.template_type = 'html'
        AND (t.tenant_id = p_tenant_id OR t.tenant_id IS NULL)
    ) THEN
      RETURN v_id;
    END IF;
  END IF;

  SELECT t.id
  INTO v_id
  FROM data.document_templates t
  JOIN data.document_template_locales l ON l.template_id = t.id AND l.is_active
  WHERE t.tenant_id = p_tenant_id
    AND t.is_active
    AND t.template_type = 'html'
    AND lower(COALESCE(t.category, '')) = 'commercial'
  ORDER BY t.created_at
  LIMIT 1;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION data.resolve_commercial_document_template_id(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION data.trg_commercial_documents_assign_render_meta()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_logo text;
BEGIN
  IF NEW.document_template_id IS NULL THEN
    NEW.document_template_id := data.resolve_commercial_document_template_id(NEW.tenant_id);
  END IF;

  IF NEW.seller_snapshot IS NOT NULL
     AND NULLIF(NEW.seller_snapshot ->> 'logo_url', '') IS NULL THEN
    SELECT logo_url INTO v_logo
    FROM data.email_configs
    WHERE tenant_id = NEW.tenant_id
    LIMIT 1;
    IF v_logo IS NOT NULL THEN
      NEW.seller_snapshot := NEW.seller_snapshot || jsonb_build_object('logo_url', v_logo);
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_commercial_documents_assign_render_meta
  ON data.commercial_documents;
CREATE TRIGGER trg_commercial_documents_assign_render_meta
  BEFORE INSERT ON data.commercial_documents
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_commercial_documents_assign_render_meta();

CREATE OR REPLACE VIEW api.commercial_documents
  WITH (security_invoker = true) AS
SELECT * FROM data.commercial_documents
WHERE tenant_id = data.active_tenant_id();

GRANT SELECT ON api.commercial_documents TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.link_commercial_rendered_document(
  p_document_id uuid,
  p_dms_document_id uuid,
  p_client_op_id uuid,
  p_pdf_job_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_dms data.documents%ROWTYPE;
  v_event uuid;
  v_is_service boolean := COALESCE(auth.role(), '') = 'service_role';
BEGIN
  IF v_uid IS NULL AND NOT v_is_service THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_dms_document_id IS NULL THEN
    RAISE EXCEPTION 'rendered_document_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = p_document_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF NOT v_is_service AND NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_doc.status = 'draft' THEN
    RAISE EXCEPTION 'document_not_issued' USING ERRCODE = 'P0001';
  END IF;

  SELECT id INTO v_event
  FROM data.commercial_document_events
  WHERE tenant_id = v_doc.tenant_id
    AND client_op_id = p_client_op_id;
  IF v_event IS NOT NULL THEN
    RETURN COALESCE(v_doc.rendered_document_id, p_dms_document_id);
  END IF;

  SELECT * INTO v_dms
  FROM data.documents
  WHERE id = p_dms_document_id;
  IF NOT FOUND OR v_dms.tenant_id IS DISTINCT FROM v_doc.tenant_id THEN
    RAISE EXCEPTION 'rendered_document_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_doc.rendered_document_id IS NOT NULL
     AND v_doc.rendered_document_id IS DISTINCT FROM p_dms_document_id THEN
    RAISE EXCEPTION 'commercial_render_already_linked' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.commercial_documents
  SET rendered_document_id = p_dms_document_id,
      pdf_job_id = COALESCE(p_pdf_job_id, pdf_job_id),
      updated_at = now()
  WHERE id = v_doc.id;

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, content_hash, client_op_id, payload
  ) VALUES (
    v_doc.tenant_id,
    v_doc.id,
    'pdf_rendered',
    v_uid,
    v_doc.content_hash,
    p_client_op_id,
    jsonb_build_object(
      'rendered_document_id', p_dms_document_id,
      'pdf_job_id', p_pdf_job_id
    )
  )
  RETURNING id INTO v_event;

  RETURN p_dms_document_id;
END;
$$;

REVOKE ALL ON FUNCTION api.link_commercial_rendered_document(uuid, uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.link_commercial_rendered_document(uuid, uuid, uuid, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.set_commercial_pdf_job(
  p_document_id uuid,
  p_pdf_job_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_is_service boolean := COALESCE(auth.role(), '') = 'service_role';
BEGIN
  IF v_uid IS NULL AND NOT v_is_service THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = p_document_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF NOT v_is_service AND NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  UPDATE data.commercial_documents
  SET pdf_job_id = p_pdf_job_id,
      updated_at = now()
  WHERE id = v_doc.id;
END;
$$;

REVOKE ALL ON FUNCTION api.set_commercial_pdf_job(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_commercial_pdf_job(uuid, uuid)
  TO authenticated, service_role;

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
  v_existing uuid;
  v_document data.documents%ROWTYPE;
  v_version data.document_versions%ROWTYPE;
BEGIN
  SELECT id INTO v_existing
  FROM data.documents
  WHERE tenant_id = p_tenant_id
    AND entity_type = 'commercial_document'
    AND entity_id = p_commercial_document_id
  LIMIT 1;

  IF v_existing IS NOT NULL THEN
    SELECT * INTO v_document FROM data.documents WHERE id = v_existing FOR UPDATE;
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
      tenant_id, title, entity_type, entity_id, category, required_permissions, created_by
    ) VALUES (
      p_tenant_id,
      p_title,
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

NOTIFY pgrst, 'reload schema';
