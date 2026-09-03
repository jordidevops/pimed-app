/*
  Fix: copiar default_block_mapping en clonar plantilles

  El clone de plantilles de plataforma no heretava el mapeig de blocs
  del template font. Això feia que el rendering final no rebria
  document_header/document_footer/custom_block_* malgrat que el preview
  de la UI mostrés el mapeig localment.

  Ara la funció api.create_document_template copia la columna
  default_block_mapping del template origen al template clonat.
*/

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
  v_source                 data.document_templates%ROWTYPE;
  v_default_block_mapping  jsonb;
  v_template               data.document_templates%ROWTYPE;
BEGIN
  IF p_template_type NOT IN ('docx', 'html', 'pdf') THEN
    RAISE EXCEPTION 'Invalid template_type: %. Must be docx, html or pdf', p_template_type
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'Access denied: owner or manager role required';
  END IF;

  v_default_block_mapping := NULL;

  IF p_cloned_from_id IS NOT NULL THEN
    SELECT * INTO v_source
    FROM data.document_templates src
    WHERE src.id = p_cloned_from_id
      AND (src.is_platform_default = true OR src.tenant_id = p_tenant_id)
      AND src.is_active = true;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Source template % not found or not accessible', p_cloned_from_id;
    END IF;

    v_default_block_mapping := v_source.default_block_mapping;
  END IF;

  INSERT INTO data.document_templates (
    tenant_id, name, description, category,
    template_type, is_platform_default, cloned_from_id,
    default_block_mapping, is_active, created_by,
    target_archetypes, target_verticals
  ) VALUES (
    p_tenant_id, p_name, p_description, p_category,
    p_template_type, false, p_cloned_from_id,
    v_default_block_mapping, true, auth.uid(),
    p_target_archetypes, p_target_verticals
  )
  RETURNING * INTO v_template;

  RETURN row_to_json(v_template);
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_document_template(uuid, text, text, text, uuid, text, text[], text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION api.create_document_template(uuid, text, text, text, uuid, text, text[], text[]) TO service_role;
