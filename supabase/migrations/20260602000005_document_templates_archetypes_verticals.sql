-- ============================================================================
-- Migration: 20260602000005_document_templates_archetypes_verticals
-- Purpose:   Add target_archetypes + target_verticals to data.document_templates
--            for archetype/sector-based filtering in TemplatesPage.
--            NULL = universal (applies to all tenants).
-- Changes:
--   1. ADD COLUMN target_archetypes text[] DEFAULT NULL
--   2. ADD COLUMN target_verticals  text[] DEFAULT NULL
--   3. Rebuild api.document_templates view to expose new columns
--   4. Update api.create_document_template RPC to accept new params
--   5. Update audit trigger to include new columns in payload
-- ============================================================================

-- 1. Add columns
ALTER TABLE data.document_templates
  ADD COLUMN IF NOT EXISTS target_archetypes text[] DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS target_verticals  text[] DEFAULT NULL;

COMMENT ON COLUMN data.document_templates.target_archetypes IS
  'Archetypes this template targets (field_service, practice, hospitality, workshop_maker, generic). NULL = universal.';
COMMENT ON COLUMN data.document_templates.target_verticals IS
  'Sector verticals this template targets (e.g. restaurant, clinic, garage). NULL = universal.';

-- ============================================================================
-- 2. Rebuild api.document_templates view (add new columns)
-- ============================================================================

CREATE OR REPLACE VIEW api.document_templates WITH (security_invoker = true) AS
  SELECT
    t.id,
    t.tenant_id,
    t.name,
    t.description,
    t.category,
    t.is_platform_default,
    t.cloned_from_id,
    t.is_active,
    t.created_by,
    t.created_at,
    t.updated_at,
    t.template_type,
    t.target_archetypes,
    t.target_verticals
  FROM data.document_templates t;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.document_templates TO authenticated;
GRANT SELECT ON api.document_templates TO service_role;

-- ============================================================================
-- 3. Update api.create_document_template RPC — add p_target_archetypes + p_target_verticals
--    Drop old signature first to avoid overload ambiguity.
-- ============================================================================

DROP FUNCTION IF EXISTS api.create_document_template(uuid, text, text, text, uuid, text);

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

GRANT EXECUTE ON FUNCTION api.create_document_template TO authenticated;
GRANT EXECUTE ON FUNCTION api.create_document_template TO service_role;

-- ============================================================================
-- 4. Update audit trigger on document_templates to include new columns
-- ============================================================================

CREATE OR REPLACE FUNCTION data.trg_audit_document_templates()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      COALESCE(auth.uid(), NULL),
      NULL,
      'TEMPLATE_CREATED',
      'document_template',
      NEW.id,
      jsonb_build_object(
        'name',               NEW.name,
        'template_type',      NEW.template_type,
        'is_platform_default',NEW.is_platform_default,
        'cloned_from_id',     NEW.cloned_from_id,
        'target_archetypes',  NEW.target_archetypes,
        'target_verticals',   NEW.target_verticals
      )
    );
  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.is_active IS DISTINCT FROM NEW.is_active THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id,
        COALESCE(auth.uid(), NULL),
        NULL,
        CASE WHEN NEW.is_active THEN 'TEMPLATE_ACTIVATED' ELSE 'TEMPLATE_DEACTIVATED' END,
        'document_template',
        NEW.id,
        jsonb_build_object(
          'name', NEW.name,
          'target_archetypes', NEW.target_archetypes,
          'target_verticals', NEW.target_verticals
        )
      );
    ELSE
      PERFORM data.log_audit_event(
        NEW.tenant_id,
        COALESCE(auth.uid(), NULL),
        NULL,
        'TEMPLATE_UPDATED',
        'document_template',
        NEW.id,
        jsonb_build_object(
          'old', jsonb_build_object(
            'name', OLD.name,
            'category', OLD.category,
            'target_archetypes', OLD.target_archetypes,
            'target_verticals', OLD.target_verticals
          ),
          'new', jsonb_build_object(
            'name', NEW.name,
            'category', NEW.category,
            'target_archetypes', NEW.target_archetypes,
            'target_verticals', NEW.target_verticals
          )
        )
      );
    END IF;
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id,
      COALESCE(auth.uid(), NULL),
      NULL,
      'TEMPLATE_DELETED',
      'document_template',
      OLD.id,
      jsonb_build_object(
        'name', OLD.name,
        'template_type', OLD.template_type,
        'target_archetypes', OLD.target_archetypes,
        'target_verticals', OLD.target_verticals
      )
    );
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;
