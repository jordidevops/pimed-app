-- =============================================================================
-- 20260528000001_signing_v2_plan_size_locale_audit.sql
--
-- Signing V2 — Easy items:
--   1. data.plans.max_html_template_size_kb
--      · Límit de mida del camp html_content d'un template locale, per pla.
--      · 0 = il·limitat (enterprise/admin). Convencions: free=200, pro=500, enterprise=0.
--
--   2. api.plans — exposa max_html_template_size_kb
--
--   3. api.upsert_document_template_locale — check de mida HTML per pla
--      · Comprova length(p_html_content) <= max_html_template_size_kb * 1024.
--      · Plantilles de plataforma (tenant_id IS NULL) no es comproven (admin portal).
--
--   4. data.trg_audit_document_template_locales
--      · AFTER INSERT OR UPDATE OR DELETE
--      · Accions: TEMPLATE_LOCALE_CREATED / TEMPLATE_LOCALE_UPDATED / TEMPLATE_LOCALE_DELETED
--      · Payload segur: per HTML guarda sha256 hex del contingut, mai el text sencer.
-- =============================================================================

-- 1. Columna max_html_template_size_kb a data.plans
-- ---------------------------------------------------------------------------
ALTER TABLE data.plans
  ADD COLUMN IF NOT EXISTS max_html_template_size_kb integer NOT NULL DEFAULT 500;

COMMENT ON COLUMN data.plans.max_html_template_size_kb
  IS 'Mida màxima del camp html_content d''un template locale en KB. 0 = il·limitat.';

-- Valors per pla
UPDATE data.plans SET max_html_template_size_kb = 200 WHERE name = 'free';
UPDATE data.plans SET max_html_template_size_kb = 500 WHERE name = 'pro';
UPDATE data.plans SET max_html_template_size_kb = 0   WHERE name = 'enterprise';

-- 2. Vista api.plans — afegir max_html_template_size_kb
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.plans WITH (security_invoker = true) AS
SELECT
  id,
  name,
  display_name,
  max_members,
  max_storage_mb,
  price_monthly,
  max_sites,
  max_portal_pages,
  portal_field_limits,
  max_html_template_size_kb
FROM data.plans
WHERE is_active = true;

GRANT SELECT ON api.plans TO authenticated, anon;

-- 3. api.upsert_document_template_locale — check de mida HTML per pla
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.upsert_document_template_locale(
  p_template_id          uuid,
  p_locale               text,
  p_mime_type            text,
  p_storage_path         text    DEFAULT NULL,
  p_html_content         text    DEFAULT NULL,
  p_variables_schema     jsonb   DEFAULT '{}',
  p_signing_roles_schema jsonb   DEFAULT '{}',
  p_sample_values        jsonb   DEFAULT NULL,
  p_is_active            boolean DEFAULT true
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

  -- Carregar la plantilla
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

    -- Check de mida HTML per pla del tenant (0 = il·limitat)
    IF p_mime_type = 'text/html' THEN
      SELECT p.max_html_template_size_kb INTO v_max_kb
      FROM data.tenants t
      JOIN data.plans   p ON p.id = t.plan_id
      WHERE t.id = v_template.tenant_id;

      IF v_max_kb IS NOT NULL AND v_max_kb > 0
         AND length(p_html_content) > v_max_kb * 1024 THEN
        RAISE EXCEPTION 'HTML template exceeds plan limit of % KB (content: % KB)',
          v_max_kb, round(length(p_html_content) / 1024.0, 1)
          USING ERRCODE = 'check_violation';
      END IF;
    END IF;

  ELSE
    -- Plantilles de plataforma: cal ser admin (cridat per admin-portal via service_role)
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

-- 4. Trigger d'auditoria de data.document_template_locales
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_document_template_locales()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id uuid;
BEGIN
  -- Localitzar el tenant_id via la plantilla pare
  IF TG_OP = 'DELETE' THEN
    SELECT tenant_id INTO v_tenant_id FROM data.document_templates WHERE id = OLD.template_id;
  ELSE
    SELECT tenant_id INTO v_tenant_id FROM data.document_templates WHERE id = NEW.template_id;
  END IF;

  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      v_tenant_id, COALESCE(auth.uid(), NULL), NULL,
      'TEMPLATE_LOCALE_CREATED', 'document_template_locale', NEW.id,
      jsonb_build_object(
        'template_id',       NEW.template_id,
        'locale',            NEW.locale,
        'mime_type',         NEW.mime_type,
        'is_active',         NEW.is_active,
        'html_size_bytes',   CASE WHEN NEW.mime_type = 'text/html'
                               THEN length(NEW.html_content)
                               ELSE NULL END
      )
    );

  ELSIF TG_OP = 'UPDATE' THEN
    PERFORM data.log_audit_event(
      v_tenant_id, COALESCE(auth.uid(), NULL), NULL,
      'TEMPLATE_LOCALE_UPDATED', 'document_template_locale', NEW.id,
      jsonb_build_object(
        'template_id', NEW.template_id,
        'locale',      NEW.locale,
        -- Mostra només els camps que han canviat; sha256 per html_content (mai el text)
        'old', jsonb_strip_nulls(jsonb_build_object(
          'is_active',
            CASE WHEN OLD.is_active IS DISTINCT FROM NEW.is_active
              THEN to_jsonb(OLD.is_active) ELSE NULL END,
          'mime_type',
            CASE WHEN OLD.mime_type IS DISTINCT FROM NEW.mime_type
              THEN to_jsonb(OLD.mime_type) ELSE NULL END,
          'storage_path',
            CASE WHEN OLD.storage_path IS DISTINCT FROM NEW.storage_path
              THEN to_jsonb(OLD.storage_path) ELSE NULL END,
          'html_content_sha256',
            CASE WHEN OLD.html_content IS DISTINCT FROM NEW.html_content
              THEN to_jsonb(encode(sha256(OLD.html_content::bytea), 'hex')) ELSE NULL END
        )),
        'new', jsonb_strip_nulls(jsonb_build_object(
          'is_active',
            CASE WHEN OLD.is_active IS DISTINCT FROM NEW.is_active
              THEN to_jsonb(NEW.is_active) ELSE NULL END,
          'mime_type',
            CASE WHEN OLD.mime_type IS DISTINCT FROM NEW.mime_type
              THEN to_jsonb(NEW.mime_type) ELSE NULL END,
          'storage_path',
            CASE WHEN OLD.storage_path IS DISTINCT FROM NEW.storage_path
              THEN to_jsonb(NEW.storage_path) ELSE NULL END,
          'html_content_sha256',
            CASE WHEN OLD.html_content IS DISTINCT FROM NEW.html_content
              THEN to_jsonb(encode(sha256(NEW.html_content::bytea), 'hex')) ELSE NULL END
        )),
        'html_size_bytes',
          CASE WHEN NEW.mime_type = 'text/html' THEN length(NEW.html_content) ELSE NULL END
      )
    );

  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      v_tenant_id, COALESCE(auth.uid(), NULL), NULL,
      'TEMPLATE_LOCALE_DELETED', 'document_template_locale', OLD.id,
      jsonb_build_object(
        'template_id', OLD.template_id,
        'locale',      OLD.locale,
        'mime_type',   OLD.mime_type
      )
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

-- DROP IF EXISTS per idempotència (CREATE OR REPLACE no funciona per triggers)
DROP TRIGGER IF EXISTS trg_audit_document_template_locales
  ON data.document_template_locales;

CREATE TRIGGER trg_audit_document_template_locales
  AFTER INSERT OR UPDATE OR DELETE ON data.document_template_locales
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_document_template_locales();
