-- QT-1: full-body commercial templates (quote / delivery_note).
-- Additive only. Letterhead resolver (category=commercial) is unchanged.

ALTER TABLE data.commercial_documents
  ADD COLUMN IF NOT EXISTS full_body_template_id uuid
    REFERENCES data.document_templates(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_commercial_documents_full_body_template
  ON data.commercial_documents (full_body_template_id)
  WHERE full_body_template_id IS NOT NULL;

COMMENT ON COLUMN data.commercial_documents.full_body_template_id IS
  'Plantilla de cos complet (category quote|delivery_note) usada en emetre. NULL = fallback buildCommercialDocumentHtml.';

-- ── Resolver ─────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.resolve_commercial_full_body_template_id(
  p_tenant_id uuid,
  p_doc_type text
)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_category text;
  v_settings_key text;
  v_settings_id text;
  v_id uuid;
BEGIN
  IF p_tenant_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF p_doc_type = 'delivery_note' THEN
    v_category := 'delivery_note';
    v_settings_key := 'delivery_note_template_id';
  ELSIF p_doc_type IN ('quote', 'quote_amendment') THEN
    v_category := 'quote';
    v_settings_key := 'quote_template_id';
  ELSE
    RETURN NULL;
  END IF;

  SELECT NULLIF(btrim(settings #>> ARRAY['commercial', v_settings_key]), '')
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
        AND t.template_type IN ('html', 'docx')
        AND lower(COALESCE(t.category, '')) = v_category
        AND (
          t.tenant_id = p_tenant_id
          OR (t.tenant_id IS NULL AND t.is_platform_default)
        )
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
    AND t.template_type IN ('html', 'docx')
    AND lower(COALESCE(t.category, '')) = v_category
  ORDER BY t.created_at
  LIMIT 1;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION data.resolve_commercial_full_body_template_id(uuid, text) FROM PUBLIC;

-- ── Trigger: assign on INSERT, do not change letterhead behaviour ────────────

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

  IF NEW.full_body_template_id IS NULL THEN
    NEW.full_body_template_id := data.resolve_commercial_full_body_template_id(
      NEW.tenant_id,
      NEW.doc_type
    );
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

-- Issued documents keep the template id even if the template is later deactivated.
CREATE OR REPLACE FUNCTION data.trg_commercial_documents_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.status <> 'draft' THEN
    IF NEW.doc_type IS DISTINCT FROM OLD.doc_type
       OR NEW.doc_number IS DISTINCT FROM OLD.doc_number
       OR NEW.client_id IS DISTINCT FROM OLD.client_id
       OR NEW.project_id IS DISTINCT FROM OLD.project_id
       OR NEW.parent_document_id IS DISTINCT FROM OLD.parent_document_id
       OR NEW.supersedes_id IS DISTINCT FROM OLD.supersedes_id
       OR NEW.seller_snapshot IS DISTINCT FROM OLD.seller_snapshot
       OR NEW.buyer_snapshot IS DISTINCT FROM OLD.buyer_snapshot
       OR NEW.service_address_snapshot IS DISTINCT FROM OLD.service_address_snapshot
       OR NEW.terms_text IS DISTINCT FROM OLD.terms_text
       OR NEW.locale IS DISTINCT FROM OLD.locale
       OR NEW.currency IS DISTINCT FROM OLD.currency
       OR NEW.subtotal IS DISTINCT FROM OLD.subtotal
       OR NEW.tax_breakdown IS DISTINCT FROM OLD.tax_breakdown
       OR NEW.total IS DISTINCT FROM OLD.total
       OR NEW.valid_until IS DISTINCT FROM OLD.valid_until
       OR NEW.show_prices IS DISTINCT FROM OLD.show_prices
       OR NEW.content_hash IS DISTINCT FROM OLD.content_hash
       OR NEW.full_body_template_id IS DISTINCT FROM OLD.full_body_template_id
    THEN
      RAISE EXCEPTION 'commercial_document_immutable'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- ── Legal token presence (QT-0 freeze: 01 §2.1) ──────────────────────────────

CREATE OR REPLACE FUNCTION data.validate_commercial_template_locale(
  p_content text,
  p_mime_type text,
  p_doc_type text
)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $validate$
DECLARE
  v_content text := COALESCE(p_content, '');
  v_missing text[] := '{}';
  v_html boolean;
BEGIN
  IF p_doc_type IS NULL OR p_doc_type NOT IN ('quote', 'quote_amendment', 'delivery_note') THEN
    RAISE EXCEPTION 'invalid_doc_type' USING ERRCODE = 'P0001';
  END IF;

  IF p_mime_type IS NULL
     OR p_mime_type NOT IN (
       'text/html',
       'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
     ) THEN
    RETURN '{}'::text[];
  END IF;

  v_html := (p_mime_type = 'text/html');

  IF p_doc_type IN ('quote', 'quote_amendment') THEN
    IF v_html THEN
      IF position('{% for line in lines %}' IN v_content) = 0 THEN
        v_missing := array_append(v_missing, 'lines_loop');
      END IF;
    ELSE
      IF position('[[#lines]]' IN v_content) = 0 THEN
        v_missing := array_append(v_missing, 'lines_loop');
      END IF;
    END IF;

    IF position('totals.total' IN v_content) = 0 THEN
      v_missing := array_append(v_missing, 'totals.total');
    END IF;
    IF position('document.doc_number' IN v_content) = 0 THEN
      v_missing := array_append(v_missing, 'document.doc_number');
    END IF;
    IF position('document.valid_until' IN v_content) = 0 THEN
      v_missing := array_append(v_missing, 'document.valid_until');
    END IF;
    IF position('totals.tax_breakdown' IN v_content) = 0 THEN
      v_missing := array_append(v_missing, 'tax_breakdown');
    END IF;

    IF v_html THEN
      IF position('role="client_accept"' IN v_content) = 0
         AND position($$role='client_accept'$$ IN v_content) = 0 THEN
        v_missing := array_append(v_missing, 'client_accept');
      END IF;
      IF position('role="client_reject"' IN v_content) = 0
         AND position($$role='client_reject'$$ IN v_content) = 0 THEN
        v_missing := array_append(v_missing, 'client_reject');
      END IF;
    ELSE
      IF position('role=client_accept' IN v_content) = 0 THEN
        v_missing := array_append(v_missing, 'client_accept');
      END IF;
      IF position('role=client_reject' IN v_content) = 0 THEN
        v_missing := array_append(v_missing, 'client_reject');
      END IF;
    END IF;
  ELSE
    IF v_html THEN
      IF position('{% for line in lines %}' IN v_content) = 0 THEN
        v_missing := array_append(v_missing, 'lines_loop');
      END IF;
    ELSE
      IF position('[[#lines]]' IN v_content) = 0 THEN
        v_missing := array_append(v_missing, 'lines_loop');
      END IF;
    END IF;

    IF position('document.doc_number' IN v_content) = 0 THEN
      v_missing := array_append(v_missing, 'document.doc_number');
    END IF;

    IF v_html THEN
      IF position('role="client_delivery"' IN v_content) = 0
         AND position($$role='client_delivery'$$ IN v_content) = 0 THEN
        v_missing := array_append(v_missing, 'client_delivery');
      END IF;
    ELSE
      IF position('role=client_delivery' IN v_content) = 0 THEN
        v_missing := array_append(v_missing, 'client_delivery');
      END IF;
    END IF;
  END IF;

  RETURN v_missing;
END;
$validate$;

REVOKE ALL ON FUNCTION data.validate_commercial_template_locale(text, text, text) FROM PUBLIC;

-- ── upsert_document_template_locale + p_acknowledge_legal_gaps ───────────────

DROP FUNCTION IF EXISTS api.upsert_document_template_locale(
  uuid, text, text, text, text, jsonb, jsonb, jsonb, boolean, jsonb
);

CREATE OR REPLACE FUNCTION api.upsert_document_template_locale(
  p_template_id              uuid,
  p_locale                   text,
  p_mime_type                text,
  p_storage_path             text    DEFAULT NULL,
  p_html_content             text    DEFAULT NULL,
  p_variables_schema         jsonb   DEFAULT '{}',
  p_signing_roles_schema     jsonb   DEFAULT '{}',
  p_sample_values            jsonb   DEFAULT NULL,
  p_is_active                boolean DEFAULT true,
  p_pdf_fields_schema        jsonb   DEFAULT NULL,
  p_acknowledge_legal_gaps   boolean DEFAULT false
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_template      data.document_templates%ROWTYPE;
  v_locale_record data.document_template_locales%ROWTYPE;
  v_max_kb        integer;
  v_doc_type      text;
  v_missing       text[];
  v_content       text;
BEGIN
  IF p_mime_type NOT IN (
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'text/html',
    'application/pdf'
  ) THEN
    RAISE EXCEPTION 'Invalid mime_type: %. Must be docx, text/html or application/pdf', p_mime_type
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_mime_type = 'text/html' AND (p_html_content IS NULL OR p_html_content = '') THEN
    RAISE EXCEPTION 'html_content is required for text/html locales'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_mime_type IN (
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/pdf'
  ) AND p_storage_path IS NULL THEN
    RAISE EXCEPTION 'storage_path is required for DOCX/PDF locales'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT t.* INTO v_template
  FROM data.document_templates t
  WHERE t.id = p_template_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Template % not found', p_template_id;
  END IF;

  IF v_template.tenant_id IS NOT NULL THEN
    IF NOT (
      data.jwt_user_tenants() ? v_template.tenant_id::text
      AND (data.jwt_user_tenants() -> v_template.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    ) THEN
      RAISE EXCEPTION 'Access denied: owner or manager role required';
    END IF;

    IF p_mime_type = 'text/html' THEN
      SELECT p.max_html_template_size_kb INTO v_max_kb
      FROM data.tenants t
      JOIN data.plans   p ON p.id = t.plan_id
      WHERE t.id = v_template.tenant_id;

      IF v_max_kb IS NOT NULL AND v_max_kb > 0
         AND octet_length(p_html_content) > v_max_kb * 1024 THEN
        RAISE EXCEPTION 'HTML template exceeds plan limit of % KB (content: % KB)',
          v_max_kb, round(octet_length(p_html_content) / 1024.0, 1)
          USING ERRCODE = 'check_violation';
      END IF;
    END IF;

  ELSE
    RAISE EXCEPTION 'Platform templates must be managed via admin portal';
  END IF;

  IF p_is_active AND lower(COALESCE(v_template.category, '')) IN ('quote', 'delivery_note') THEN
    v_doc_type := CASE lower(v_template.category)
      WHEN 'delivery_note' THEN 'delivery_note'
      ELSE 'quote'
    END;
    -- DOCX no es valida en aquesta fase: p_html_content no porta el binari,
    -- per tant v_content és sempre '' i tots els tokens es marquen absents.
    -- Efecte: activar un DOCX quote/delivery_note SEMPRE exigeix
    -- p_acknowledge_legal_gaps=true. Vegeu [ref al contracte congelat].
    v_content := CASE
      WHEN p_mime_type = 'text/html' THEN p_html_content
      ELSE COALESCE(p_html_content, '')
    END;
    v_missing := data.validate_commercial_template_locale(v_content, p_mime_type, v_doc_type);
    IF COALESCE(array_length(v_missing, 1), 0) > 0 THEN
      IF NOT COALESCE(p_acknowledge_legal_gaps, false) THEN
        RAISE EXCEPTION 'commercial_template_legal_gaps: %', array_to_string(v_missing, ', ')
          USING ERRCODE = 'P0001',
                DETAIL = array_to_string(v_missing, ', ');
      END IF;
      PERFORM data.log_audit_event(
        v_template.tenant_id,
        auth.uid(),
        NULL,
        'TEMPLATE_LEGAL_GAP_ACKNOWLEDGED',
        'document_template',
        v_template.id,
        jsonb_build_object(
          'locale', p_locale,
          'mime_type', p_mime_type,
          'doc_type', v_doc_type,
          'missing_tokens', to_jsonb(v_missing)
        )
      );
    END IF;
  END IF;

  INSERT INTO data.document_template_locales (
    template_id, locale, mime_type, storage_path, html_content,
    variables_schema, signing_roles_schema, sample_values, is_active,
    pdf_fields_schema
  ) VALUES (
    p_template_id, p_locale, p_mime_type,
    CASE WHEN p_mime_type = 'text/html' THEN NULL ELSE p_storage_path END,
    CASE WHEN p_mime_type = 'text/html' THEN p_html_content ELSE NULL END,
    p_variables_schema, p_signing_roles_schema, p_sample_values, p_is_active,
    p_pdf_fields_schema
  )
  ON CONFLICT (template_id, locale) DO UPDATE SET
    mime_type              = EXCLUDED.mime_type,
    storage_path           = EXCLUDED.storage_path,
    html_content           = EXCLUDED.html_content,
    variables_schema       = EXCLUDED.variables_schema,
    signing_roles_schema   = EXCLUDED.signing_roles_schema,
    sample_values          = EXCLUDED.sample_values,
    is_active              = EXCLUDED.is_active,
    pdf_fields_schema      = EXCLUDED.pdf_fields_schema,
    updated_at             = now()
  RETURNING * INTO v_locale_record;

  RETURN row_to_json(v_locale_record);
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_document_template_locale(
  uuid, text, text, text, text, jsonb, jsonb, jsonb, boolean, jsonb, boolean
) TO authenticated;

-- View was created with SELECT * expanded at CF-18; recreate so the new column is visible.
CREATE OR REPLACE VIEW api.commercial_documents
  WITH (security_invoker = true) AS
SELECT * FROM data.commercial_documents
WHERE tenant_id = data.active_tenant_id();

GRANT SELECT ON api.commercial_documents TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
