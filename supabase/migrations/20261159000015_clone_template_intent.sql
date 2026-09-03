-- Copy visit intent when cloning checklist templates
CREATE OR REPLACE FUNCTION api.clone_checklist_template(
  p_source_template_id uuid,
  p_tenant_id uuid,
  p_name text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_src data.checklist_templates%ROWTYPE;
  v_src_version data.checklist_template_versions%ROWTYPE;
  v_new_template_id uuid;
  v_new_version_id uuid;
  v_default_set_id uuid;
  v_item data.checklist_template_items%ROWTYPE;
  v_point data.checklist_review_points%ROWTYPE;
  v_point_id uuid;
  v_item_set_id uuid;
BEGIN
  PERFORM data.assert_checklist_tenant_admin(p_tenant_id);

  SELECT * INTO v_src FROM data.checklist_templates WHERE id = p_source_template_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'template_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_src.tenant_id IS NOT NULL AND v_src.tenant_id IS DISTINCT FROM p_tenant_id THEN
    RAISE EXCEPTION 'cannot_clone_other_tenant_template' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_src_version
  FROM data.checklist_template_versions
  WHERE template_id = p_source_template_id AND status = 'published'
  ORDER BY version_number DESC
  LIMIT 1;

  IF NOT FOUND THEN
    SELECT * INTO v_src_version
    FROM data.checklist_template_versions
    WHERE template_id = p_source_template_id
    ORDER BY version_number DESC
    LIMIT 1;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'source_version_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  v_default_set_id := data.clone_checklist_response_set(
    v_src_version.default_response_set_id, p_tenant_id
  );

  INSERT INTO data.checklist_templates (
    tenant_id, name, description, kind, locale, category, vertical, archetype,
    metadata, is_default, is_active, created_by, intent
  ) VALUES (
    p_tenant_id,
    COALESCE(NULLIF(btrim(COALESCE(p_name, '')), ''), v_src.name),
    v_src.description,
    v_src.kind,
    v_src.locale,
    v_src.category,
    v_src.vertical,
    v_src.archetype,
    v_src.metadata,
    false,
    true,
    auth.uid(),
    COALESCE(v_src.intent, 'generic')
  )
  RETURNING id INTO v_new_template_id;

  INSERT INTO data.checklist_template_versions (
    template_id, version_number, status, default_response_set_id, created_by
  ) VALUES (
    v_new_template_id, 1, 'draft', v_default_set_id, auth.uid()
  )
  RETURNING id INTO v_new_version_id;

  FOR v_item IN
    SELECT * FROM data.checklist_template_items
    WHERE version_id = v_src_version.id
    ORDER BY position
  LOOP
    v_point_id := NULL;
    v_point := NULL;

    IF v_item.review_point_id IS NOT NULL THEN
      v_point_id := api.clone_checklist_review_point(
        v_item.review_point_id, p_tenant_id, NULL, NULL
      );
      SELECT * INTO v_point FROM data.checklist_review_points WHERE id = v_point_id;
    END IF;

    v_item_set_id := data.clone_checklist_response_set(v_item.response_set_id, p_tenant_id);

    INSERT INTO data.checklist_template_items (
      version_id, position, review_point_id, title, description_internal,
      description_public, locale, category, include_in_report, is_required,
      response_type, response_set_id, evidence_required
    ) VALUES (
      v_new_version_id,
      v_item.position,
      v_point_id,
      COALESCE(v_point.title, v_item.title),
      COALESCE(v_point.description, v_item.description_internal),
      COALESCE(v_point.client_text, v_item.description_public),
      COALESCE(v_item.locale, v_src.locale),
      COALESCE(v_item.category, v_src.category),
      v_item.include_in_report,
      v_item.is_required,
      v_item.response_type,
      COALESCE(v_item_set_id, v_default_set_id),
      v_item.evidence_required
    );
  END LOOP;

  INSERT INTO data.checklist_template_forks (
    source_template_id, source_version_id, source_published_version_number,
    tenant_template_id, tenant_id
  ) VALUES (
    p_source_template_id,
    v_src_version.id,
    CASE WHEN v_src_version.status = 'published' THEN v_src_version.version_number ELSE NULL END,
    v_new_template_id,
    p_tenant_id
  )
  ON CONFLICT DO NOTHING;

  RETURN v_new_template_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.clone_checklist_template(uuid, uuid, text)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
