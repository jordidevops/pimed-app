-- =============================================================================
-- Migration: 20260603000007_pdf_fields_schema
-- Phase B1: Suport natiu a plantilles PDF amb posicionament de camps
--
-- Canvis:
--   1. data.document_templates     + 'pdf' a template_type CHECK
--   2. data.document_template_locales
--                                  + 'application/pdf' a mime_type CHECK
--                                  + pdf_fields_schema jsonb NULL
--                                  + content_consistency CHECK actualitzat
--   3. api.document_template_locales   + pdf_fields_schema a la vista
--   4. api.create_document_template    + 'pdf' vàlid a validació
--   5. api.upsert_document_template_locale
--                                  + 'application/pdf' vàlid
--                                  + p_pdf_fields_schema jsonb DEFAULT NULL
-- =============================================================================

-- ============================================================================
-- 1. data.document_templates — Ampliar CHECK template_type per incloure 'pdf'
-- ============================================================================

-- Eliminar constraint existent (nom generat per PostgreSQL)
DO $$
DECLARE
  v_constraint_name TEXT;
BEGIN
  SELECT conname INTO v_constraint_name
  FROM pg_constraint
  WHERE conrelid = 'data.document_templates'::regclass
    AND contype = 'c'
    AND pg_get_constraintdef(oid) LIKE '%template_type%';

  IF v_constraint_name IS NOT NULL THEN
    EXECUTE format('ALTER TABLE data.document_templates DROP CONSTRAINT %I', v_constraint_name);
  END IF;
END $$;

ALTER TABLE data.document_templates
  ADD CONSTRAINT chk_document_templates_template_type
    CHECK (template_type IN ('docx', 'html', 'pdf'));

COMMENT ON COLUMN data.document_templates.template_type
  IS 'Tipus de plantilla: docx (fitxer a Storage), html (html_content a BD), pdf (fitxer PDF a Storage amb camps posicionals). Immutable un cop creat.';


-- ============================================================================
-- 2. data.document_template_locales — pdf_fields_schema + CHECKs actualitzats
-- ============================================================================

-- 2a. Nou camp
ALTER TABLE data.document_template_locales
  ADD COLUMN IF NOT EXISTS pdf_fields_schema jsonb NULL;

COMMENT ON COLUMN data.document_template_locales.pdf_fields_schema
  IS 'Definició de camps posicionals per a PDF: [{id, page, x, y, w, h, type, role?, label?}, ...]. NULL per a plantilles no-PDF.';


-- 2b. Ampliar el CHECK de mime_type per incloure application/pdf
DO $$
BEGIN
  -- Eliminar la constraint nomenada explícitament a migració 20260522000002
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'data.document_template_locales'::regclass
      AND conname = 'chk_doc_template_locale_mime_type'
  ) THEN
    ALTER TABLE data.document_template_locales DROP CONSTRAINT chk_doc_template_locale_mime_type;
  END IF;
END $$;

ALTER TABLE data.document_template_locales
  ADD CONSTRAINT chk_doc_template_locale_mime_type CHECK (
    mime_type IS NULL
    OR mime_type IN (
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'text/html',
      'application/pdf'
    )
  );


-- 2c. Actualitzar la constraint de consistència de contingut per incloure PDF
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'data.document_template_locales'::regclass
      AND conname = 'chk_doc_template_locale_content_consistency'
  ) THEN
    ALTER TABLE data.document_template_locales DROP CONSTRAINT chk_doc_template_locale_content_consistency;
  END IF;
END $$;

ALTER TABLE data.document_template_locales
  ADD CONSTRAINT chk_doc_template_locale_content_consistency CHECK (
    -- HTML: cal html_content; storage_path és NULL
    (mime_type = 'text/html'
      AND html_content IS NOT NULL
      AND storage_path IS NULL)
    OR
    -- DOCX: cal storage_path; html_content és NULL
    (mime_type = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
      AND storage_path IS NOT NULL
      AND html_content IS NULL)
    OR
    -- PDF: cal storage_path; html_content és NULL; pdf_fields_schema pot ser NULL
    (mime_type = 'application/pdf'
      AND storage_path IS NOT NULL
      AND html_content IS NULL)
    OR
    -- Encara no definit (NULL mime_type = locale buit en creació)
    mime_type IS NULL
  );

COMMENT ON CONSTRAINT chk_doc_template_locale_content_consistency
  ON data.document_template_locales
  IS 'Consistència: HTML→html_content ≠ NULL, storage_path NULL. DOCX/PDF→storage_path ≠ NULL, html_content NULL.';


-- ============================================================================
-- 3. api.document_template_locales — Exposar pdf_fields_schema
-- ============================================================================

CREATE OR REPLACE VIEW api.document_template_locales WITH (security_invoker = true) AS
  SELECT
    id,
    template_id,
    locale,
    storage_path,
    mime_type,
    variables_schema,
    sample_values,
    is_active,
    created_at,
    updated_at,
    -- html_content: EXCLÒS deliberadament — pot ser gran (fins a 500 KB).
    signing_roles_schema,
    pdf_fields_schema
  FROM data.document_template_locales;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.document_template_locales TO authenticated;
GRANT SELECT ON api.document_template_locales TO service_role;


-- ============================================================================
-- 4. api.create_document_template — Ampliar validació per acceptar 'pdf'
--    La signatura actual (migració 20260602000005) té 8 paràmetres.
--    Recreem la mateixa signatura actualitzant NOMÉS el CHECK de template_type.
-- ============================================================================

DROP FUNCTION IF EXISTS api.create_document_template(uuid, text, text, text, uuid, text, text[], text[]);

CREATE OR REPLACE FUNCTION api.create_document_template(
  p_tenant_id          uuid,
  p_name               text,
  p_description        text     DEFAULT NULL,
  p_category           text     DEFAULT NULL,
  p_cloned_from_id     uuid     DEFAULT NULL,
  p_template_type      text     DEFAULT 'docx',
  p_target_archetypes  text[]   DEFAULT NULL,
  p_target_verticals   text[]   DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_template data.document_templates%ROWTYPE;
BEGIN
  -- Validació de template_type (ara inclou 'pdf')
  IF p_template_type NOT IN ('docx', 'html', 'pdf') THEN
    RAISE EXCEPTION 'Invalid template_type: %. Must be docx, html or pdf', p_template_type
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Validació d'accés: cal ser owner o manager global del tenant
  IF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'Access denied: owner or manager role required';
  END IF;

  -- Si és un clone, validar que la font existeix i és accessible
  IF p_cloned_from_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.document_templates src
      WHERE src.id = p_cloned_from_id
        AND (src.is_platform_default = true OR src.tenant_id = p_tenant_id)
        AND src.is_active = true
    ) THEN
      RAISE EXCEPTION 'Source template % not found or not accessible', p_cloned_from_id;
    END IF;
  END IF;

  INSERT INTO data.document_templates (
    tenant_id, name, description, category,
    template_type, is_platform_default, cloned_from_id, is_active, created_by,
    target_archetypes, target_verticals
  ) VALUES (
    p_tenant_id, p_name, p_description, p_category,
    p_template_type, false, p_cloned_from_id, true, auth.uid(),
    p_target_archetypes, p_target_verticals
  )
  RETURNING * INTO v_template;

  RETURN row_to_json(v_template);
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_document_template(uuid, text, text, text, uuid, text, text[], text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION api.create_document_template(uuid, text, text, text, uuid, text, text[], text[]) TO service_role;


-- ============================================================================
-- 5. api.upsert_document_template_locale — Acceptar PDF + pdf_fields_schema
--    Dropa la signatura antiga (9 paràmetres) per evitar overload ambigu.
-- ============================================================================

DROP FUNCTION IF EXISTS api.upsert_document_template_locale(uuid, text, text, text, text, jsonb, jsonb, jsonb, boolean);

CREATE OR REPLACE FUNCTION api.upsert_document_template_locale(
  p_template_id          uuid,
  p_locale               text,
  p_mime_type            text,
  p_storage_path         text    DEFAULT NULL,
  p_html_content         text    DEFAULT NULL,
  p_variables_schema     jsonb   DEFAULT '{}',
  p_signing_roles_schema jsonb   DEFAULT '{}',
  p_sample_values        jsonb   DEFAULT NULL,
  p_is_active            boolean DEFAULT true,
  p_pdf_fields_schema    jsonb   DEFAULT NULL
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
BEGIN
  -- Validació de mime_type
  IF p_mime_type NOT IN (
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'text/html',
    'application/pdf'
  ) THEN
    RAISE EXCEPTION 'Invalid mime_type: %. Must be docx, text/html or application/pdf', p_mime_type
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Validació de contingut per tipus
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

    -- Límit de mida per HTML (octet_length = bytes UTF-8 reals)
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

GRANT EXECUTE ON FUNCTION api.upsert_document_template_locale(uuid, text, text, text, text, jsonb, jsonb, jsonb, boolean, jsonb) TO authenticated;
