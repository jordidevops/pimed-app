-- CT-3: prepare an agreement from an accepted quote. Accept does not call this.
-- Render and native signing stay on the existing PDF path (role client).

CREATE OR REPLACE FUNCTION data.validate_commercial_agreement_template_locale(
  p_content text,
  p_mime_type text
)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $validate$
DECLARE
  v_content text := COALESCE(p_content, '');
  v_missing text[] := '{}';
BEGIN
  IF p_mime_type IS DISTINCT FROM 'text/html' THEN
    RETURN ARRAY['html_only'];
  END IF;

  IF position('source_quote.doc_number' IN v_content) = 0 THEN
    v_missing := array_append(v_missing, 'source_quote.doc_number');
  END IF;
  IF position('source_quote.content_hash' IN v_content) = 0 THEN
    v_missing := array_append(v_missing, 'source_quote.content_hash');
  END IF;
  IF position('{% for line in lines %}' IN v_content) = 0 THEN
    v_missing := array_append(v_missing, 'lines_loop');
  END IF;
  IF position('totals.total' IN v_content) = 0 THEN
    v_missing := array_append(v_missing, 'totals.total');
  END IF;
  IF position('role="client"' IN v_content) = 0
     AND position($$role='client'$$ IN v_content) = 0 THEN
    v_missing := array_append(v_missing, 'client');
  END IF;
  IF position('client_accept' IN v_content) > 0 THEN
    v_missing := array_append(v_missing, 'forbidden_client_accept');
  END IF;
  IF position('client_reject' IN v_content) > 0 THEN
    v_missing := array_append(v_missing, 'forbidden_client_reject');
  END IF;

  RETURN v_missing;
END;
$validate$;

REVOKE ALL ON FUNCTION data.validate_commercial_agreement_template_locale(text, text) FROM PUBLIC;

CREATE OR REPLACE FUNCTION data.trg_validate_agreement_template_locale()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_category text;
  v_missing text[];
BEGIN
  IF NEW.mime_type IS DISTINCT FROM 'text/html' OR NEW.is_active IS NOT TRUE THEN
    RETURN NEW;
  END IF;

  SELECT lower(COALESCE(category, '')) INTO v_category
  FROM data.document_templates
  WHERE id = NEW.template_id;

  IF v_category IS DISTINCT FROM 'commercial_agreement' THEN
    RETURN NEW;
  END IF;

  v_missing := data.validate_commercial_agreement_template_locale(NEW.html_content, NEW.mime_type);
  IF COALESCE(array_length(v_missing, 1), 0) > 0 THEN
    RAISE EXCEPTION 'agreement_template_legal_gaps: %', array_to_string(v_missing, ', ')
      USING ERRCODE = 'P0001',
            DETAIL = array_to_string(v_missing, ', ');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_agreement_template_locale ON data.document_template_locales;
CREATE TRIGGER trg_validate_agreement_template_locale
  BEFORE INSERT OR UPDATE OF html_content, mime_type, is_active, template_id
  ON data.document_template_locales
  FOR EACH ROW EXECUTE FUNCTION data.trg_validate_agreement_template_locale();

INSERT INTO data.document_templates (
  id, tenant_id, name, description, category, template_type,
  is_platform_default, is_active, created_by
) VALUES (
  '76100000-0000-0000-0000-000000000001',
  NULL,
  'Contracte formal de serveis',
  'Punt de partida per a un acord amb annex del pressupost acceptat. No és assessorament jurídic.',
  'commercial_agreement',
  'html',
  true,
  true,
  NULL
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.document_template_locales (
  id, template_id, locale, mime_type, html_content, variables_schema,
  signing_roles_schema, sample_values, is_active
) VALUES (
  '78100000-0000-0000-0000-000000000011',
  '76100000-0000-0000-0000-000000000001',
  'ca',
  'text/html',
  $html$<!DOCTYPE html><html lang="ca"><body>
<h1>Contracte de serveis</h1>
<p>Annex: pressupost {{ source_quote.doc_number }}. Empremta {{ source_quote.content_hash }}.</p>
<ul>{% for line in lines %}<li>{{ line.name }} — {{ line.line_total }}</li>{% endfor %}</ul>
<p>Total {{ totals.total }} {{ document.currency }}</p>
<signature-field role="client"></signature-field>
</body></html>$html$,
  '{}'::jsonb,
  '{"roles":["client"]}'::jsonb,
  '{}'::jsonb,
  true
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.document_template_locales (
  id, template_id, locale, mime_type, html_content, variables_schema,
  signing_roles_schema, sample_values, is_active
) VALUES (
  '79100000-0000-0000-0000-000000000011',
  '76100000-0000-0000-0000-000000000001',
  'es',
  'text/html',
  $html$<!DOCTYPE html><html lang="es"><body>
<h1>Contrato de servicios</h1>
<p>Anexo: presupuesto {{ source_quote.doc_number }}. Huella {{ source_quote.content_hash }}.</p>
<ul>{% for line in lines %}<li>{{ line.name }} — {{ line.line_total }}</li>{% endfor %}</ul>
<p>Total {{ totals.total }} {{ document.currency }}</p>
<signature-field role="client"></signature-field>
</body></html>$html$,
  '{}'::jsonb,
  '{"roles":["client"]}'::jsonb,
  '{}'::jsonb,
  true
)
ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION api.prepare_agreement_from_quote(
  p_document_id uuid,
  p_template_id uuid,
  p_work_gate text,
  p_client_op_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_project data.projects%ROWTYPE;
  v_agreement data.commercial_agreements%ROWTYPE;
  v_version data.commercial_agreement_versions%ROWTYPE;
  v_existing_agreement uuid;
  v_html text;
  v_missing text[];
  v_hash text;
  v_annex uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_work_gate IS NULL OR p_work_gate NOT IN ('none', 'require_signed_agreement') THEN
    RAISE EXCEPTION 'invalid_work_gate' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'quote_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;
  IF COALESCE((
    SELECT tm.role
    FROM data.tenant_members tm
    WHERE tm.tenant_id = v_doc.tenant_id
      AND tm.user_id = v_uid
      AND tm.site_id IS NULL
    LIMIT 1
  ), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'permission_denied:agreement_prepare' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.doc_type NOT IN ('quote', 'quote_amendment') THEN
    RAISE EXCEPTION 'invalid_doc_type' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.status <> 'accepted' THEN
    RAISE EXCEPTION 'quote_not_accepted' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.formalization_mode IS DISTINCT FROM 'separate_agreement' THEN
    RAISE EXCEPTION 'quote_not_separate_agreement' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.content_hash IS NULL OR btrim(v_doc.content_hash) = '' THEN
    RAISE EXCEPTION 'quote_content_hash_missing' USING ERRCODE = 'P0001';
  END IF;

  SELECT e.agreement_id INTO v_existing_agreement
  FROM data.commercial_agreement_events e
  WHERE e.tenant_id = v_doc.tenant_id
    AND e.client_op_id = p_client_op_id
  LIMIT 1;
  IF v_existing_agreement IS NOT NULL THEN
    RETURN v_existing_agreement;
  END IF;

  IF p_template_id IS NULL THEN
    RAISE EXCEPTION 'agreement_template_required' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM data.document_templates t
    WHERE t.id = p_template_id
      AND t.is_active
      AND t.template_type = 'html'
      AND lower(COALESCE(t.category, '')) = 'commercial_agreement'
      AND (
        t.tenant_id = v_doc.tenant_id
        OR (t.tenant_id IS NULL AND t.is_platform_default)
      )
  ) THEN
    RAISE EXCEPTION 'agreement_template_invalid' USING ERRCODE = 'P0001';
  END IF;

  SELECT l.html_content INTO v_html
  FROM data.document_template_locales l
  WHERE l.template_id = p_template_id
    AND l.locale = COALESCE(NULLIF(btrim(v_doc.locale), ''), 'ca')
    AND l.is_active
    AND l.mime_type = 'text/html';
  IF v_html IS NULL THEN
    SELECT l.html_content INTO v_html
    FROM data.document_template_locales l
    WHERE l.template_id = p_template_id
      AND l.locale = 'ca'
      AND l.is_active
      AND l.mime_type = 'text/html';
  END IF;
  v_missing := data.validate_commercial_agreement_template_locale(v_html, 'text/html');
  IF v_html IS NULL OR COALESCE(array_length(v_missing, 1), 0) > 0 THEN
    RAISE EXCEPTION 'agreement_template_invalid'
      USING ERRCODE = 'P0001',
            DETAIL = array_to_string(v_missing, ', ');
  END IF;

  v_hash := encode(
    extensions.digest(
      convert_to(
        v_doc.content_hash || '|' || COALESCE(v_doc.doc_number, '') || '|' || p_template_id::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  v_annex := v_doc.rendered_document_id;

  SELECT a.* INTO v_agreement
  FROM data.commercial_agreements a
  WHERE a.tenant_id = v_doc.tenant_id
    AND a.source_quote_id = v_doc.id
    AND a.status <> 'cancelled'
  ORDER BY a.created_at DESC
  LIMIT 1;

  IF FOUND THEN
    SELECT * INTO v_version
    FROM data.commercial_agreement_versions
    WHERE agreement_id = v_agreement.id
    ORDER BY version_no DESC
    LIMIT 1;
    IF v_version.status IN ('pending_signature', 'signed') THEN
      RETURN v_agreement.id;
    END IF;

    UPDATE data.commercial_agreements
    SET work_gate = p_work_gate
    WHERE id = v_agreement.id;

    UPDATE data.commercial_agreement_versions
    SET source_quote_content_hash = v_doc.content_hash,
        source_quote_document_id = v_annex,
        full_body_template_id = p_template_id,
        content_hash = v_hash,
        rendered_document_id = NULL
    WHERE id = v_version.id;

    INSERT INTO data.commercial_agreement_events (
      tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
    ) VALUES (
      v_doc.tenant_id, v_agreement.id, 'prepared', v_uid, p_client_op_id,
      jsonb_build_object(
        'source_quote_id', v_doc.id,
        'source_quote_content_hash', v_doc.content_hash,
        'full_body_template_id', p_template_id
      )
    );
    RETURN v_agreement.id;
  END IF;

  INSERT INTO data.commercial_agreements (
    tenant_id, client_id, kind, status, source_quote_id, work_gate, created_by
  ) VALUES (
    v_doc.tenant_id, v_doc.client_id, 'specific', 'pending_start',
    v_doc.id, p_work_gate, v_uid
  ) RETURNING * INTO v_agreement;

  INSERT INTO data.commercial_agreement_versions (
    tenant_id, agreement_id, version_no, status,
    source_quote_id, source_quote_content_hash, source_quote_document_id,
    full_body_template_id, content_hash
  ) VALUES (
    v_doc.tenant_id, v_agreement.id, 1, 'draft',
    v_doc.id, v_doc.content_hash, v_annex,
    p_template_id, v_hash
  ) RETURNING * INTO v_version;

  UPDATE data.commercial_agreements
  SET active_version_id = v_version.id
  WHERE id = v_agreement.id;

  INSERT INTO data.commercial_agreement_events (
    tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_doc.tenant_id, v_agreement.id, 'prepared', v_uid, p_client_op_id,
    jsonb_build_object(
      'source_quote_id', v_doc.id,
      'source_quote_content_hash', v_doc.content_hash,
      'full_body_template_id', p_template_id
    )
  );

  IF v_doc.project_id IS NOT NULL THEN
    SELECT * INTO v_project FROM data.projects WHERE id = v_doc.project_id;
    INSERT INTO data.commercial_agreement_projects (tenant_id, agreement_id, project_id)
    VALUES (v_doc.tenant_id, v_agreement.id, v_doc.project_id)
    ON CONFLICT (agreement_id, project_id) DO NOTHING;
    INSERT INTO data.commercial_agreement_events (
      tenant_id, agreement_id, event_type, actor_id, payload
    ) VALUES (
      v_doc.tenant_id, v_agreement.id, 'project_linked', v_uid,
      jsonb_build_object('project_id', v_doc.project_id)
    );
  END IF;

  RETURN v_agreement.id;
END;
$$;

REVOKE ALL ON FUNCTION api.prepare_agreement_from_quote(uuid, uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.prepare_agreement_from_quote(uuid, uuid, text, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.mark_agreement_sent_for_signature(
  p_version_id uuid,
  p_submission_id uuid,
  p_signer_role text,
  p_client_op_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_version data.commercial_agreement_versions%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_signer_role IS DISTINCT FROM 'client' THEN
    RAISE EXCEPTION 'agreement_signer_role_invalid' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_version FROM data.commercial_agreement_versions WHERE id = p_version_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_version.tenant_id::text) THEN
    RAISE EXCEPTION 'agreement_version_not_found' USING ERRCODE = 'P0001';
  END IF;
  IF COALESCE((
    SELECT tm.role
    FROM data.tenant_members tm
    WHERE tm.tenant_id = v_version.tenant_id
      AND tm.user_id = v_uid
      AND tm.site_id IS NULL
    LIMIT 1
  ), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'permission_denied:agreement_prepare' USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1 FROM data.commercial_agreement_events e
    WHERE e.tenant_id = v_version.tenant_id AND e.client_op_id = p_client_op_id
  ) THEN
    RETURN v_version.agreement_id;
  END IF;

  IF v_version.status = 'pending_signature' THEN
    RETURN v_version.agreement_id;
  END IF;
  IF v_version.status <> 'draft' THEN
    RAISE EXCEPTION 'agreement_version_immutable' USING ERRCODE = 'P0001';
  END IF;
  IF v_version.rendered_document_id IS NULL THEN
    RAISE EXCEPTION 'agreement_pdf_required' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.commercial_agreement_versions
  SET status = 'pending_signature'
  WHERE id = v_version.id;

  INSERT INTO data.commercial_agreement_events (
    tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_version.tenant_id, v_version.agreement_id, 'sent', v_uid, p_client_op_id,
    jsonb_build_object(
      'submission_id', p_submission_id,
      'signer_role', 'client',
      'rendered_document_id', v_version.rendered_document_id
    )
  );

  RETURN v_version.agreement_id;
END;
$$;

REVOKE ALL ON FUNCTION api.mark_agreement_sent_for_signature(uuid, uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.mark_agreement_sent_for_signature(uuid, uuid, text, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.create_commercial_agreement_rendered_document_internal(
  p_version_id uuid,
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
  v_version data.commercial_agreement_versions%ROWTYPE;
  v_agreement data.commercial_agreements%ROWTYPE;
  v_folder_id uuid;
  v_document data.documents%ROWTYPE;
  v_doc_version data.document_versions%ROWTYPE;
  v_existing uuid;
BEGIN
  SELECT * INTO v_version FROM data.commercial_agreement_versions WHERE id = p_version_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'agreement_version_not_found' USING ERRCODE = 'P0001';
  END IF;
  IF v_version.status <> 'draft' THEN
    RAISE EXCEPTION 'agreement_version_immutable' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_agreement FROM data.commercial_agreements WHERE id = v_version.agreement_id;

  v_folder_id := data.ensure_commercial_dms_folder(
    v_version.tenant_id, v_agreement.client_id, 'commercial_agreement'
  );

  SELECT id INTO v_existing
  FROM data.documents
  WHERE tenant_id = v_version.tenant_id
    AND entity_type = 'commercial_agreement'
    AND entity_id = v_version.id
  LIMIT 1;

  IF v_existing IS NOT NULL THEN
    SELECT * INTO v_document FROM data.documents WHERE id = v_existing FOR UPDATE;
    INSERT INTO data.document_versions (
      document_id, version_number, storage_type, file_path_or_url,
      mime_type, size_bytes, created_by
    ) VALUES (
      v_existing,
      COALESCE((
        SELECT MAX(version_number) FROM data.document_versions WHERE document_id = v_existing
      ), 0) + 1,
      'native', p_file_path_or_url, p_mime_type, p_size_bytes, p_created_by
    ) RETURNING * INTO v_doc_version;
  ELSE
    INSERT INTO data.documents (
      tenant_id, title, folder_id, entity_type, entity_id, category,
      required_permissions, created_by
    ) VALUES (
      v_version.tenant_id, p_title, v_folder_id, 'commercial_agreement', v_version.id,
      'commercial', '{}', p_created_by
    ) RETURNING * INTO v_document;

    INSERT INTO data.document_versions (
      document_id, version_number, storage_type, file_path_or_url,
      mime_type, size_bytes, created_by
    ) VALUES (
      v_document.id, 1, 'native', p_file_path_or_url, p_mime_type, p_size_bytes, p_created_by
    ) RETURNING * INTO v_doc_version;
  END IF;

  UPDATE data.commercial_agreement_versions
  SET rendered_document_id = v_document.id
  WHERE id = v_version.id;

  RETURN json_build_object(
    'document', row_to_json(v_document),
    'version', row_to_json(v_doc_version)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.create_commercial_agreement_rendered_document_internal(
  uuid, text, text, text, bigint, uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_commercial_agreement_rendered_document_internal(
  uuid, text, text, text, bigint, uuid
) TO service_role;

NOTIFY pgrst, 'reload schema';
