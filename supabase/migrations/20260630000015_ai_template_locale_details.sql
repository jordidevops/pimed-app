-- Detall de locale de plantilla per eines IA (variables, rols, storage)

CREATE OR REPLACE FUNCTION api.get_template_locale_for_ai_service(
  p_tenant_id          uuid,
  p_template_locale_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row record;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT
    dtl.id,
    dtl.locale,
    dtl.mime_type,
    dtl.storage_path,
    dtl.html_content,
    dtl.variables_schema,
    dtl.signing_roles_schema,
    dt.id AS template_id,
    dt.name AS template_name,
    dt.category AS template_category,
    dt.default_block_mapping,
    dt.template_type
  INTO v_row
  FROM data.document_template_locales dtl
  JOIN data.document_templates dt ON dt.id = dtl.template_id
  WHERE dtl.id = p_template_locale_id
    AND dt.is_active = true
    AND (
      dt.tenant_id = p_tenant_id
      OR (dt.tenant_id IS NULL AND dt.is_platform_default = true)
    );

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'templateLocaleId', v_row.id,
    'templateId', v_row.template_id,
    'templateName', v_row.template_name,
    'locale', v_row.locale,
    'mimeType', v_row.mime_type,
    'storagePath', v_row.storage_path,
    'htmlContent', v_row.html_content,
    'variablesSchema', COALESCE(v_row.variables_schema, '{}'::jsonb),
    'signingRolesSchema', COALESCE(v_row.signing_roles_schema, '{}'::jsonb),
    'templateCategory', v_row.template_category,
    'blockMapping', v_row.default_block_mapping,
    'templateType', v_row.template_type
  );
END;
$$;
