-- =============================================================================
-- Migration: 20260522000002_dms_templates_html_signing_roles.sql
-- Propòsit:  Estendre el sistema de plantilles documentals per suportar
--            HTML (a més de DOCX) i esquema de rols de signatura per locale.
--
-- Canvis a data.*:
--   data.document_templates         + template_type TEXT ('docx'|'html'), immutable
--   data.document_template_locales  + html_content TEXT (NULL per DOCX)
--                                   + signing_roles_schema JSONB DEFAULT '{}'
--                                   · mime_type CHECK actualitzat: afegir 'text/html',
--                                     eliminar 'application/pdf'
--                                   · Locales PDF existents desactivats (is_active=false)
--
-- Canvis a api.*:
--   api.document_templates          + template_type
--   api.document_template_locales   + signing_roles_schema
--                                   (html_content NO s'exposa via vista — càrrega lazy)
--   api.create_document_template    + p_template_type TEXT DEFAULT 'docx'
--
-- Seguretat / rendiment:
--   · html_content pot ser gran (fins a 500 KB per CHECK); s'exclou de la vista
--     per evitar inflate del catàleg. El frontend la carrega via SELECT explícit
--     únicament quan obre l'editor o prepara un document HTML.
--   · DOMPurify s'aplica al preview TipTap (client-side) per evitar XSS.
--   · La migració és idempotent: usa IF NOT EXISTS i OR REPLACE on possible.
--
-- Auditoria:
--   · template_type NO té trigger d'auditoria propi: el canvi és impossible
--     (trigger d'immutabilitat ho bloqueja). La creació ja queda auditada
--     per trg_audit_document_templates (TEMPLATE_CREATED).
-- =============================================================================


-- ============================================================================
-- 1. data.document_templates — Afegir template_type
-- ============================================================================

ALTER TABLE data.document_templates
  ADD COLUMN IF NOT EXISTS template_type TEXT
    NOT NULL DEFAULT 'docx'
    CHECK (template_type IN ('docx', 'html'));

COMMENT ON COLUMN data.document_templates.template_type
  IS 'Tipus de plantilla: docx (fitxer a Storage) o html (html_content a BD). Immutable un cop creat.';


-- ============================================================================
-- 2. Trigger d'immutabilitat de template_type
--    Evita canviar el tipus un cop creat. El document i les locales ja poden
--    tenir dades incompatibles si es permetés canviar el tipus.
-- ============================================================================

CREATE OR REPLACE FUNCTION data.trg_prevent_template_type_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.template_type IS DISTINCT FROM OLD.template_type THEN
    RAISE EXCEPTION
      'template_type cannot be changed after creation (template id: %)', OLD.id
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_document_templates_type_immutable ON data.document_templates;
CREATE TRIGGER trg_document_templates_type_immutable
  BEFORE UPDATE ON data.document_templates
  FOR EACH ROW EXECUTE FUNCTION data.trg_prevent_template_type_change();


-- ============================================================================
-- 3. data.document_template_locales — Nous camps
-- ============================================================================

ALTER TABLE data.document_template_locales
  ADD COLUMN IF NOT EXISTS html_content       TEXT,
  ADD COLUMN IF NOT EXISTS signing_roles_schema JSONB NOT NULL DEFAULT '{}';

-- Límit de mida html_content: 500 KB màx (prevenir abusos de BD)
ALTER TABLE data.document_template_locales
  ADD CONSTRAINT chk_html_content_size
    CHECK (html_content IS NULL OR length(html_content) <= 512000);

COMMENT ON COLUMN data.document_template_locales.html_content
  IS 'Contingut HTML de la plantilla (nullable; usat quan mime_type=text/html). Màx 500 KB.';
COMMENT ON COLUMN data.document_template_locales.signing_roles_schema
  IS 'Esquema de rols de signatura: {roleName: {entity_type, label, order, for_signing}}. Obtingut per escaneig del document.';


-- ============================================================================
-- 4. mime_type CHECK — Actualitzar per permetre text/html i eliminar PDF
--
--    El CHECK existent es diu chk sense nom explícit a la migració original,
--    però PostgreSQL l'assigna automàticament. El dropo per nom de constraint
--    generat i en creo un de nou amb nom explícit per facilitar futures migracions.
-- ============================================================================

-- Eliminar constraint antiga (nom generat per PostgreSQL)
DO $$
DECLARE
  v_constraint_name TEXT;
BEGIN
  SELECT conname INTO v_constraint_name
  FROM pg_constraint
  WHERE conrelid = 'data.document_template_locales'::regclass
    AND contype = 'c'
    AND pg_get_constraintdef(oid) LIKE '%mime_type%';

  IF v_constraint_name IS NOT NULL THEN
    EXECUTE format('ALTER TABLE data.document_template_locales DROP CONSTRAINT %I', v_constraint_name);
  END IF;
END $$;

-- Afegir nova constraint amb nom explícit i mimes actualitzats
ALTER TABLE data.document_template_locales
  ADD CONSTRAINT chk_doc_template_locale_mime_type CHECK (
    mime_type IS NULL
    OR mime_type IN (
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'text/html'
    )
  );

-- Afegir constraint de consistència entre mime_type i els camps de contingut
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
    -- Encara no definit (NULL mime_type = locale buit en creació)
    mime_type IS NULL
  );

COMMENT ON CONSTRAINT chk_doc_template_locale_content_consistency
  ON data.document_template_locales
  IS 'Consistència: HTML→html_content no NULL, storage_path NULL. DOCX→storage_path no NULL, html_content NULL.';


-- ============================================================================
-- 5. Desactivar locales PDF existents (migració de dades segura)
--    No s'esborren: es mantenen per a l'historial de signing_submissions.
-- ============================================================================

UPDATE data.document_template_locales
SET
  is_active  = false,
  updated_at = now()
WHERE mime_type = 'application/pdf'
  AND is_active = true;

-- Nota: en entorns de dev pot no haver-n'hi cap; la UPDATE és idempotent.


-- ============================================================================
-- 6. Actualitzar api.document_templates — Afegir template_type
-- ============================================================================

CREATE OR REPLACE VIEW api.document_templates WITH (security_invoker = true) AS
  SELECT
    id,
    tenant_id,
    name,
    description,
    category,
    is_platform_default,
    cloned_from_id,
    is_active,
    created_by,
    created_at,
    updated_at,
    -- Nou camp (al final per compatibilitat amb CREATE OR REPLACE VIEW)
    template_type
  FROM data.document_templates;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.document_templates TO authenticated;
GRANT SELECT ON api.document_templates TO service_role;


-- ============================================================================
-- 7. Actualitzar api.document_template_locales
--    Afegir signing_roles_schema.
--    html_content EXCLÒS deliberadament — pot ser gran (fins a 500 KB).
--    El frontend el carrega via SELECT explícit únicament quan necessita editar
--    o preparar un document HTML.
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
    -- Nou camp (al final per compatibilitat amb CREATE OR REPLACE VIEW)
    -- html_content: EXCLÒS deliberadament — pot ser gran (fins a 500 KB).
    -- Usa SELECT explícit: supabase.from('document_template_locales').select('html_content').eq('id', localeId)
    signing_roles_schema
  FROM data.document_template_locales;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.document_template_locales TO authenticated;
GRANT SELECT ON api.document_template_locales TO service_role;


-- ============================================================================
-- 8. Actualitzar api.create_document_template — Afegir p_template_type
--    Cal dropar l'antiga signatura (5 paràmetres) per evitar overload ambigu.
--    CREATE OR REPLACE amb signatura diferent crea un overload, no reemplaça.
-- ============================================================================

DROP FUNCTION IF EXISTS api.create_document_template(uuid, text, text, text, uuid);

CREATE OR REPLACE FUNCTION api.create_document_template(
  p_tenant_id      uuid,
  p_name           text,
  p_description    text    DEFAULT NULL,
  p_category       text    DEFAULT NULL,
  p_cloned_from_id uuid    DEFAULT NULL,
  p_template_type  text    DEFAULT 'docx'
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_template data.document_templates%ROWTYPE;
BEGIN
  -- Validació de template_type
  IF p_template_type NOT IN ('docx', 'html') THEN
    RAISE EXCEPTION 'Invalid template_type: %. Must be docx or html', p_template_type
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
    template_type, is_platform_default, cloned_from_id, is_active, created_by
  ) VALUES (
    p_tenant_id, p_name, p_description, p_category,
    p_template_type, false, p_cloned_from_id, true, auth.uid()
  )
  RETURNING * INTO v_template;

  RETURN row_to_json(v_template);
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_document_template TO authenticated;

-- Afegir service_role per a edge functions que crein templates de plataforma
GRANT EXECUTE ON FUNCTION api.create_document_template TO service_role;


-- ============================================================================
-- 9. Vista de detall: api.document_template_locale_detail
--    Inclou html_content per als fluxos d'edició i preparació.
--    S'usa ÚNICAMENT en peticions individuals (.eq('id', localeId)),
--    mai en batch, per evitar inflate de resposta.
-- ============================================================================

CREATE OR REPLACE VIEW api.document_template_locale_detail WITH (security_invoker = true) AS
  SELECT
    id,
    template_id,
    locale,
    storage_path,
    mime_type,
    variables_schema,
    signing_roles_schema,
    sample_values,
    is_active,
    created_at,
    updated_at,
    html_content
  FROM data.document_template_locales;

GRANT SELECT ON api.document_template_locale_detail TO authenticated;
GRANT SELECT ON api.document_template_locale_detail TO service_role;


-- ============================================================================
-- 10. RPC api.upsert_document_template_locale
--     Permet crear o actualitzar un locale amb html_content (camps no exposats
--     via la vista principal). Valida la consistència DOCX vs HTML.
-- ============================================================================

CREATE OR REPLACE FUNCTION api.upsert_document_template_locale(
  p_template_id         uuid,
  p_locale              text,
  p_mime_type           text,
  p_storage_path        text    DEFAULT NULL,
  p_html_content        text    DEFAULT NULL,
  p_variables_schema    jsonb   DEFAULT '{}',
  p_signing_roles_schema jsonb  DEFAULT '{}',
  p_sample_values       jsonb   DEFAULT NULL,
  p_is_active           boolean DEFAULT true
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_template      data.document_templates%ROWTYPE;
  v_locale_record data.document_template_locales%ROWTYPE;
BEGIN
  -- Validar mime_type
  IF p_mime_type NOT IN (
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'text/html'
  ) THEN
    RAISE EXCEPTION 'Invalid mime_type: %. Must be docx or text/html', p_mime_type
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Validar consistència de contingut
  IF p_mime_type = 'text/html' AND (p_html_content IS NULL OR p_html_content = '') THEN
    RAISE EXCEPTION 'html_content is required for text/html locales'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_mime_type != 'text/html' AND p_storage_path IS NULL THEN
    RAISE EXCEPTION 'storage_path is required for DOCX locales'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Validar accés a la plantilla (owner/manager del tenant o plantilla de plataforma)
  SELECT t.* INTO v_template
  FROM data.document_templates t
  WHERE t.id = p_template_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Template % not found', p_template_id;
  END IF;

  -- Plantilles de tenant: cal ser owner/manager
  IF v_template.tenant_id IS NOT NULL THEN
    IF NOT (
      data.jwt_user_tenants() ? v_template.tenant_id::text
      AND (data.jwt_user_tenants() -> v_template.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    ) THEN
      RAISE EXCEPTION 'Access denied: owner or manager role required';
    END IF;
  ELSE
    -- Plantilles de plataforma: cal ser admin (cridat per admin-portal via service_role)
    -- En context normal (authenticated), no es pot modificar plantilles de plataforma
    RAISE EXCEPTION 'Platform templates must be managed via admin portal';
  END IF;

  -- Upsert del locale
  INSERT INTO data.document_template_locales (
    template_id, locale, mime_type, storage_path, html_content,
    variables_schema, signing_roles_schema, sample_values, is_active
  ) VALUES (
    p_template_id, p_locale, p_mime_type,
    CASE WHEN p_mime_type = 'text/html' THEN NULL ELSE p_storage_path END,
    CASE WHEN p_mime_type = 'text/html' THEN p_html_content ELSE NULL END,
    p_variables_schema, p_signing_roles_schema, p_sample_values, p_is_active
  )
  ON CONFLICT (template_id, locale) DO UPDATE SET
    mime_type              = EXCLUDED.mime_type,
    storage_path           = EXCLUDED.storage_path,
    html_content           = EXCLUDED.html_content,
    variables_schema       = EXCLUDED.variables_schema,
    signing_roles_schema   = EXCLUDED.signing_roles_schema,
    sample_values          = EXCLUDED.sample_values,
    is_active              = EXCLUDED.is_active,
    updated_at             = now()
  RETURNING * INTO v_locale_record;

  RETURN row_to_json(v_locale_record);
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_document_template_locale TO authenticated;
