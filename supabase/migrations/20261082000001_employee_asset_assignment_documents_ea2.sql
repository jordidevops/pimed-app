-- =============================================================================
-- M-EA-02 — Documents reconeixement / retorn d'assignacions (EA-2)
-- Nota d'abast: a EXECUTION.md, EA-2 = documents (no regles readiness del pla EA,
-- que depenen de CR-2c i queden com a fase posterior / renumerades).
-- Patró: EC-4 (generate idempotent + link + soft entity_type).
-- Default ack: plantilla HTML «Acta de lliurament d'EPI» (710…0004).
-- Default return: plantilla HTML nova «Acta de devolució d'equipament» (710…0041).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Plantilla plataforma: acta de devolució
-- ---------------------------------------------------------------------------
INSERT INTO data.document_templates (
  id, tenant_id, name, description, category, template_type,
  is_platform_default, is_active, target_archetypes
) VALUES (
  '70000000-0000-0000-0000-000000000041',
  NULL,
  'Acta de devolució d''equipament',
  'Justificant de retorn d''actiu assignat a empleat.',
  'safety',
  'html',
  true,
  true,
  ARRAY['field_service', 'workshop_maker', 'hospitality', 'generic']
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.document_template_locales (
  id, template_id, locale, mime_type, storage_path,
  html_content, variables_schema, signing_roles_schema, is_active
) VALUES (
  '71000000-0000-0000-0000-000000000041',
  '70000000-0000-0000-0000-000000000041',
  'ca',
  'text/html',
  NULL,
  '<h1>Acta de devolució d''equipament</h1>'
    || '<p>En data <strong>{{data_retorn}}</strong> el/la treballador/a '
    || '<strong>{{worker.full_name}}</strong> retorna l''actiu '
    || '<strong>{{asset_name}}</strong>'
    || '{{asset_tag_suffix}} en condició <strong>{{return_condition}}</strong>.</p>'
    || '<p>{{notes}}</p>',
  jsonb_build_object(
    'data_retorn', jsonb_build_object('type', 'date', 'label', 'Data de retorn', 'required', true, 'order', 0),
    'worker.full_name', jsonb_build_object('type', 'string', 'label', 'Treballador/a', 'required', true, 'order', 1),
    'asset_name', jsonb_build_object('type', 'string', 'label', 'Actiu', 'required', true, 'order', 2),
    'return_condition', jsonb_build_object('type', 'string', 'label', 'Condició', 'required', true, 'order', 3)
  ),
  '{}'::jsonb,
  true
)
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. Append-only: permet enllaçar documents (ack obert / return tancat)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.enforce_employee_asset_assignment_append_only()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_identity_ok boolean;
  v_only_ack boolean;
  v_only_return_doc boolean;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'employee_asset_assignment_delete_forbidden'
      USING ERRCODE = 'check_violation';
  END IF;

  v_identity_ok :=
    NEW.asset_id IS NOT DISTINCT FROM OLD.asset_id
    AND NEW.employee_id IS NOT DISTINCT FROM OLD.employee_id
    AND NEW.tenant_id IS NOT DISTINCT FROM OLD.tenant_id
    AND NEW.assigned_at IS NOT DISTINCT FROM OLD.assigned_at
    AND NEW.assigned_by IS NOT DISTINCT FROM OLD.assigned_by
    AND NEW.created_at IS NOT DISTINCT FROM OLD.created_at
    AND NEW.expected_return_at IS NOT DISTINCT FROM OLD.expected_return_at;

  -- Closed row: only return_document_id may change (late generate/link)
  IF OLD.returned_at IS NOT NULL THEN
    v_only_return_doc :=
      v_identity_ok
      AND NEW.returned_at IS NOT DISTINCT FROM OLD.returned_at
      AND NEW.return_condition IS NOT DISTINCT FROM OLD.return_condition
      AND NEW.returned_by IS NOT DISTINCT FROM OLD.returned_by
      AND NEW.acknowledgment_document_id IS NOT DISTINCT FROM OLD.acknowledgment_document_id
      AND NEW.notes IS NOT DISTINCT FROM OLD.notes
      AND NEW.return_document_id IS DISTINCT FROM OLD.return_document_id;

    IF v_only_return_doc THEN
      RETURN NEW;
    END IF;

    RAISE EXCEPTION 'employee_asset_assignment_closed_immutable'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Closing open row: fill return fields; identity immutable; ack may stay
  IF NEW.returned_at IS NOT NULL AND OLD.returned_at IS NULL THEN
    IF NOT v_identity_ok
       OR NEW.acknowledgment_document_id IS DISTINCT FROM OLD.acknowledgment_document_id THEN
      RAISE EXCEPTION 'employee_asset_assignment_identity_immutable'
        USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
  END IF;

  -- Open row: only acknowledgment_document_id (and notes untouched)
  v_only_ack :=
    v_identity_ok
    AND NEW.returned_at IS NULL
    AND NEW.return_condition IS NULL
    AND NEW.returned_by IS NULL
    AND NEW.return_document_id IS NOT DISTINCT FROM OLD.return_document_id
    AND NEW.notes IS NOT DISTINCT FROM OLD.notes
    AND NEW.acknowledgment_document_id IS DISTINCT FROM OLD.acknowledgment_document_id;

  IF v_only_ack THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'employee_asset_assignment_update_forbidden'
    USING ERRCODE = 'check_violation';
END;
$$;

-- ---------------------------------------------------------------------------
-- 2b. Fix NULL OR false → privilege bypass (IF NOT NULL no entra al RAISE)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.can_manage_employee_asset_assignments(
  p_tenant_id uuid,
  p_site_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT coalesce(
    data.jwt_has_permission(p_tenant_id, 'assets.employee_assignments.manage', p_site_id),
    false
  )
  OR coalesce(
    (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager'),
    false
  );
$$;

CREATE OR REPLACE FUNCTION data.can_view_employee_asset_assignments(
  p_tenant_id uuid,
  p_site_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT coalesce(
    data.jwt_has_permission(p_tenant_id, 'assets.employee_assignments.view', p_site_id),
    false
  )
  OR coalesce(
    data.jwt_has_permission(p_tenant_id, 'assets.employee_assignments.manage', p_site_id),
    false
  )
  OR coalesce(
    (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager'),
    false
  );
$$;

-- ---------------------------------------------------------------------------
-- 3. Helpers: default locales + variables + render
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.default_asset_acknowledgment_template_locale_id()
RETURNS uuid
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT '71000000-0000-0000-0000-000000000004'::uuid;
$$;

CREATE OR REPLACE FUNCTION data.default_asset_return_template_locale_id()
RETURNS uuid
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT '71000000-0000-0000-0000-000000000041'::uuid;
$$;

CREATE OR REPLACE FUNCTION data.build_employee_asset_assignment_variables(
  p_assignment data.employee_asset_assignments,
  p_kind text DEFAULT 'acknowledgment'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_emp data.employees%ROWTYPE;
  v_asset data.assets%ROWTYPE;
  v_list text;
  v_tag_suffix text;
BEGIN
  SELECT * INTO v_emp FROM data.employees WHERE id = p_assignment.employee_id;
  SELECT * INTO v_asset FROM data.assets WHERE id = p_assignment.asset_id;

  v_list := coalesce(v_asset.name, 'actiu');
  IF v_asset.asset_tag IS NOT NULL AND length(trim(v_asset.asset_tag)) > 0 THEN
    v_list := v_list || ' (' || v_asset.asset_tag || ')';
    v_tag_suffix := ' (' || v_asset.asset_tag || ')';
  ELSE
    v_tag_suffix := '';
  END IF;

  IF p_kind = 'return' THEN
    RETURN jsonb_build_object(
      'full_name', coalesce(v_emp.full_name, ''),
      'worker.full_name', coalesce(v_emp.full_name, ''),
      'document_header', '',
      'document_footer', '',
      'data_retorn', coalesce(p_assignment.returned_at::date::text, CURRENT_DATE::text),
      'asset_name', coalesce(v_asset.name, ''),
      'asset_tag', coalesce(v_asset.asset_tag, ''),
      'asset_tag_suffix', v_tag_suffix,
      'return_condition', coalesce(p_assignment.return_condition, ''),
      'notes', coalesce(p_assignment.notes, ''),
      'llista_epi', v_list
    );
  END IF;

  RETURN jsonb_build_object(
    'full_name', coalesce(v_emp.full_name, ''),
    'worker.full_name', coalesce(v_emp.full_name, ''),
    'document_header', '',
    'document_footer', '',
    'data_lliurament', coalesce(p_assignment.assigned_at::date::text, CURRENT_DATE::text),
    'llista_epi', v_list,
    'asset_name', coalesce(v_asset.name, ''),
    'asset_tag', coalesce(v_asset.asset_tag, '')
  );
END;
$$;

-- Reuse EC-4 renderer (same {{key}} / liquid-ish tokens)
CREATE OR REPLACE FUNCTION data.render_employee_asset_assignment_html(
  p_html text,
  p_vars jsonb
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT data.render_employment_contract_html(p_html, p_vars);
$$;

CREATE OR REPLACE FUNCTION data.resolve_asset_assignment_template_locale(
  p_locale_id uuid,
  p_tenant_id uuid
)
RETURNS data.document_template_locales
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_locale data.document_template_locales%ROWTYPE;
  v_tmpl data.document_templates%ROWTYPE;
BEGIN
  SELECT * INTO v_locale
  FROM data.document_template_locales
  WHERE id = p_locale_id AND is_active;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'template_locale_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT * INTO v_tmpl FROM data.document_templates WHERE id = v_locale.template_id AND is_active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'template_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_tmpl.tenant_id IS NOT NULL AND v_tmpl.tenant_id <> p_tenant_id THEN
    RAISE EXCEPTION 'template_tenant_mismatch' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN v_locale;
END;
$$;

CREATE OR REPLACE FUNCTION data.create_asset_assignment_document(
  p_tenant_id uuid,
  p_site_id uuid,
  p_assignment_id uuid,
  p_title text,
  p_kind text,
  p_rendered text,
  p_locale data.document_template_locales,
  p_tmpl data.document_templates,
  p_vars jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_doc_id uuid;
  v_ver_id uuid;
  v_scheme text;
BEGIN
  v_scheme := CASE
    WHEN p_kind = 'return' THEN 'asset-return'
    ELSE 'asset-acknowledgment'
  END;

  INSERT INTO data.documents (
    tenant_id, site_id, title, category, entity_type, entity_id,
    required_permissions, created_by
  )
  VALUES (
    p_tenant_id,
    p_site_id,
    p_title,
    coalesce(p_tmpl.category, 'safety'),
    'employee_asset_assignment',
    p_assignment_id,
    ARRAY['owner', 'manager'],
    auth.uid()
  )
  RETURNING id INTO v_doc_id;

  INSERT INTO data.document_versions (
    document_id, version_number, storage_type, file_path_or_url,
    mime_type, size_bytes, created_by
  )
  VALUES (
    v_doc_id,
    1,
    'external_link',
    format('%s://%s/v1', v_scheme, p_assignment_id),
    'text/html',
    octet_length(coalesce(p_rendered, '')),
    auth.uid()
  )
  RETURNING id INTO v_ver_id;

  -- Snapshot on document title already; store rendered HTML via a version note if needed.
  -- Consumers read via documents + assignment FK; EC-4 keeps snapshot on parent — we store
  -- minimal metadata on the document version path and assignment notes stay untouched.
  PERFORM data.log_audit_event(
    p_tenant_id, auth.uid(), p_site_id,
    CASE WHEN p_kind = 'return' THEN 'ASSET_RETURN_DOC_GENERATED' ELSE 'ASSET_ACK_DOC_GENERATED' END,
    'employee_asset_assignment', p_assignment_id,
    jsonb_build_object(
      'document_id', v_doc_id,
      'template_locale_id', p_locale.id,
      'template_id', p_tmpl.id,
      'variables', p_vars,
      'rendered_html_len', octet_length(coalesce(p_rendered, ''))
    ),
    false
  );

  RETURN v_doc_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. RPCs generate / link
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.generate_employee_asset_acknowledgment_document(
  p_assignment_id uuid,
  p_template_locale_id uuid DEFAULT NULL,
  p_force boolean DEFAULT false
)
RETURNS api.employee_asset_assignments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_a data.employee_asset_assignments%ROWTYPE;
  v_asset data.assets%ROWTYPE;
  v_emp data.employees%ROWTYPE;
  v_locale data.document_template_locales%ROWTYPE;
  v_tmpl data.document_templates%ROWTYPE;
  v_vars jsonb;
  v_rendered text;
  v_doc_id uuid;
  v_locale_id uuid;
  v_out api.employee_asset_assignments;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT * INTO v_a
  FROM data.employee_asset_assignments
  WHERE id = p_assignment_id AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'assignment_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_a.returned_at IS NOT NULL THEN
    RAISE EXCEPTION 'assignment_already_returned' USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_asset FROM data.assets WHERE id = v_a.asset_id;
  SELECT * INTO v_emp FROM data.employees WHERE id = v_a.employee_id;

  IF NOT data.can_manage_employee_asset_assignments(v_tenant_id, v_asset.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_a.acknowledgment_document_id IS NOT NULL AND NOT p_force THEN
    IF EXISTS (SELECT 1 FROM data.documents d WHERE d.id = v_a.acknowledgment_document_id) THEN
      SELECT * INTO v_out FROM api.employee_asset_assignments WHERE id = v_a.id;
      RETURN v_out;
    END IF;
  END IF;

  v_locale_id := coalesce(
    p_template_locale_id,
    data.default_asset_acknowledgment_template_locale_id()
  );
  v_locale := data.resolve_asset_assignment_template_locale(v_locale_id, v_tenant_id);
  SELECT * INTO v_tmpl FROM data.document_templates WHERE id = v_locale.template_id;

  v_vars := data.build_employee_asset_assignment_variables(v_a, 'acknowledgment');
  v_rendered := data.render_employee_asset_assignment_html(v_locale.html_content, v_vars);

  v_doc_id := data.create_asset_assignment_document(
    v_tenant_id,
    v_asset.site_id,
    v_a.id,
    format('Reconeixement lliurament — %s — %s', coalesce(v_emp.full_name, 'empleat'), coalesce(v_asset.name, 'actiu')),
    'acknowledgment',
    v_rendered,
    v_locale,
    v_tmpl,
    v_vars
  );

  UPDATE data.employee_asset_assignments
  SET acknowledgment_document_id = v_doc_id
  WHERE id = v_a.id;

  SELECT * INTO v_out FROM api.employee_asset_assignments WHERE id = v_a.id;
  RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION api.generate_employee_asset_return_document(
  p_assignment_id uuid,
  p_template_locale_id uuid DEFAULT NULL,
  p_force boolean DEFAULT false
)
RETURNS api.employee_asset_assignments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_a data.employee_asset_assignments%ROWTYPE;
  v_asset data.assets%ROWTYPE;
  v_emp data.employees%ROWTYPE;
  v_locale data.document_template_locales%ROWTYPE;
  v_tmpl data.document_templates%ROWTYPE;
  v_vars jsonb;
  v_rendered text;
  v_doc_id uuid;
  v_locale_id uuid;
  v_out api.employee_asset_assignments;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT * INTO v_a
  FROM data.employee_asset_assignments
  WHERE id = p_assignment_id AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'assignment_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_a.returned_at IS NULL THEN
    RAISE EXCEPTION 'assignment_not_returned' USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_asset FROM data.assets WHERE id = v_a.asset_id;
  SELECT * INTO v_emp FROM data.employees WHERE id = v_a.employee_id;

  IF NOT data.can_manage_employee_asset_assignments(v_tenant_id, v_asset.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_a.return_document_id IS NOT NULL AND NOT p_force THEN
    IF EXISTS (SELECT 1 FROM data.documents d WHERE d.id = v_a.return_document_id) THEN
      SELECT * INTO v_out FROM api.employee_asset_assignments WHERE id = v_a.id;
      RETURN v_out;
    END IF;
  END IF;

  v_locale_id := coalesce(
    p_template_locale_id,
    data.default_asset_return_template_locale_id()
  );
  v_locale := data.resolve_asset_assignment_template_locale(v_locale_id, v_tenant_id);
  SELECT * INTO v_tmpl FROM data.document_templates WHERE id = v_locale.template_id;

  v_vars := data.build_employee_asset_assignment_variables(v_a, 'return');
  v_rendered := data.render_employee_asset_assignment_html(v_locale.html_content, v_vars);

  v_doc_id := data.create_asset_assignment_document(
    v_tenant_id,
    v_asset.site_id,
    v_a.id,
    format('Devolució equipament — %s — %s', coalesce(v_emp.full_name, 'empleat'), coalesce(v_asset.name, 'actiu')),
    'return',
    v_rendered,
    v_locale,
    v_tmpl,
    v_vars
  );

  UPDATE data.employee_asset_assignments
  SET return_document_id = v_doc_id
  WHERE id = v_a.id;

  SELECT * INTO v_out FROM api.employee_asset_assignments WHERE id = v_a.id;
  RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION api.link_employee_asset_acknowledgment_document(
  p_assignment_id uuid,
  p_document_id uuid
)
RETURNS api.employee_asset_assignments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_a data.employee_asset_assignments%ROWTYPE;
  v_asset data.assets%ROWTYPE;
  v_doc data.documents%ROWTYPE;
  v_out api.employee_asset_assignments;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT * INTO v_a
  FROM data.employee_asset_assignments
  WHERE id = p_assignment_id AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'assignment_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_a.returned_at IS NOT NULL THEN
    RAISE EXCEPTION 'assignment_already_returned' USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_asset FROM data.assets WHERE id = v_a.asset_id;
  IF NOT data.can_manage_employee_asset_assignments(v_tenant_id, v_asset.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_doc FROM data.documents WHERE id = p_document_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  UPDATE data.documents SET
    entity_type = coalesce(nullif(entity_type, ''), 'employee_asset_assignment'),
    entity_id = coalesce(entity_id, v_a.id),
    required_permissions = CASE
      WHEN required_permissions IS NULL OR cardinality(required_permissions) = 0
        THEN ARRAY['owner', 'manager']
      ELSE required_permissions
    END,
    updated_at = now()
  WHERE id = v_doc.id;

  UPDATE data.employee_asset_assignments
  SET acknowledgment_document_id = v_doc.id
  WHERE id = v_a.id;

  SELECT * INTO v_out FROM api.employee_asset_assignments WHERE id = v_a.id;
  RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION api.link_employee_asset_return_document(
  p_assignment_id uuid,
  p_document_id uuid
)
RETURNS api.employee_asset_assignments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_a data.employee_asset_assignments%ROWTYPE;
  v_asset data.assets%ROWTYPE;
  v_doc data.documents%ROWTYPE;
  v_out api.employee_asset_assignments;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT * INTO v_a
  FROM data.employee_asset_assignments
  WHERE id = p_assignment_id AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'assignment_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_a.returned_at IS NULL THEN
    RAISE EXCEPTION 'assignment_not_returned' USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_asset FROM data.assets WHERE id = v_a.asset_id;
  IF NOT data.can_manage_employee_asset_assignments(v_tenant_id, v_asset.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_doc FROM data.documents WHERE id = p_document_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  UPDATE data.documents SET
    entity_type = coalesce(nullif(entity_type, ''), 'employee_asset_assignment'),
    entity_id = coalesce(entity_id, v_a.id),
    required_permissions = CASE
      WHEN required_permissions IS NULL OR cardinality(required_permissions) = 0
        THEN ARRAY['owner', 'manager']
      ELSE required_permissions
    END,
    updated_at = now()
  WHERE id = v_doc.id;

  UPDATE data.employee_asset_assignments
  SET return_document_id = v_doc.id
  WHERE id = v_a.id;

  SELECT * INTO v_out FROM api.employee_asset_assignments WHERE id = v_a.id;
  RETURN v_out;
END;
$$;

COMMENT ON FUNCTION api.generate_employee_asset_acknowledgment_document(uuid, uuid, boolean) IS
  'EA-2: genera justificant de lliurament (idempotent; p_force regenera).';
COMMENT ON FUNCTION api.generate_employee_asset_return_document(uuid, uuid, boolean) IS
  'EA-2: genera justificant de devolució sobre assignació ja tancada.';
COMMENT ON FUNCTION api.link_employee_asset_acknowledgment_document(uuid, uuid) IS
  'EA-2: enllaça un document DMS existent com a reconeixement.';
COMMENT ON FUNCTION api.link_employee_asset_return_document(uuid, uuid) IS
  'EA-2: enllaça un document DMS existent com a devolució.';

REVOKE ALL ON FUNCTION api.generate_employee_asset_acknowledgment_document(uuid, uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.generate_employee_asset_return_document(uuid, uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.link_employee_asset_acknowledgment_document(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.link_employee_asset_return_document(uuid, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.generate_employee_asset_acknowledgment_document(uuid, uuid, boolean)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.generate_employee_asset_return_document(uuid, uuid, boolean)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.link_employee_asset_acknowledgment_document(uuid, uuid)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.link_employee_asset_return_document(uuid, uuid)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
