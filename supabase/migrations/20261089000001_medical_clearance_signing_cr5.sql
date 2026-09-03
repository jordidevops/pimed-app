-- =============================================================================
-- M-CR-09 / CR-5 — Signatures reconeixements mèdics
-- entity_type soft 'employee_certification' + generate/prepare/link (medical only)
-- Permís: compliance.medical_clearance.manage (NO certifications.manage)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Columnes a employee_certifications
-- ---------------------------------------------------------------------------
ALTER TABLE data.employee_certifications
  ADD COLUMN IF NOT EXISTS signing_submission_id uuid
    REFERENCES data.signing_submissions(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_employee_certifications_signing_submission
  ON data.employee_certifications (signing_submission_id)
  WHERE signing_submission_id IS NOT NULL;

-- Vista: afegir signing_submission_id al final (sense DROP)
CREATE OR REPLACE VIEW api.employee_certifications
  WITH (security_invoker = true) AS
SELECT
  c.id,
  c.tenant_id,
  c.employee_id,
  c.requirement_type_id,
  c.issuer,
  c.credential_number,
  c.issued_on,
  c.valid_from,
  c.valid_until,
  c.document_id,
  c.revoked_at,
  c.revoked_reason,
  c.notes,
  c.created_by,
  c.created_at,
  c.updated_at,
  data.compute_certification_status(c.valid_from, c.valid_until, CURRENT_DATE) AS computed_status,
  t.code AS requirement_code,
  t.name AS requirement_name,
  t.category AS requirement_category,
  c.signing_submission_id
FROM data.employee_certifications c
JOIN data.compliance_requirement_types t ON t.id = c.requirement_type_id;

GRANT SELECT ON api.employee_certifications TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Plantilla plataforma: reconeixement mèdic
-- ---------------------------------------------------------------------------
INSERT INTO data.document_templates (
  id, tenant_id, name, description, category, template_type,
  is_platform_default, is_active, target_archetypes
) VALUES (
  '70000000-0000-0000-0000-000000000042',
  NULL,
  'Reconeixement mèdic / aptitud',
  'Document de reconeixement mèdic amb signatura del servei de prevenció.',
  'hr',
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
  '71000000-0000-0000-0000-000000000042',
  '70000000-0000-0000-0000-000000000042',
  'ca',
  'text/html',
  NULL,
  '<h1>Reconeixement mèdic</h1>'
    || '<p>Treballador/a: <strong>{{worker.full_name}}</strong></p>'
    || '<p>Requeriment: <strong>{{requirement_name}}</strong> ({{requirement_code}})</p>'
    || '<p>Emissor: <strong>{{issuer}}</strong></p>'
    || '<p>Vigència: <strong>{{valid_from}}</strong> — <strong>{{valid_until}}</strong></p>'
    || '<p>Aptitud declarada: <strong>{{fitness}}</strong></p>'
    || '<hr/><p>Signatura servei de prevenció / metge:</p>'
    || '<signature-field name="FirmaMedica" role="medical_officer" required="true" '
    || 'style="width:220px;height:60px;display:inline-block;"></signature-field>',
  jsonb_build_object(
    'worker.full_name', jsonb_build_object('type', 'string', 'label', 'Treballador/a', 'required', true, 'order', 0),
    'requirement_name', jsonb_build_object('type', 'string', 'label', 'Requeriment', 'required', true, 'order', 1),
    'requirement_code', jsonb_build_object('type', 'string', 'label', 'Codi', 'required', true, 'order', 2),
    'issuer', jsonb_build_object('type', 'string', 'label', 'Emissor', 'required', false, 'order', 3),
    'valid_from', jsonb_build_object('type', 'date', 'label', 'Des de', 'required', true, 'order', 4),
    'valid_until', jsonb_build_object('type', 'string', 'label', 'Fins', 'required', false, 'order', 5),
    'fitness', jsonb_build_object('type', 'string', 'label', 'Aptitud', 'required', true, 'order', 6)
  ),
  jsonb_build_object(
    'medical_officer', jsonb_build_object('label', 'Servei de prevenció', 'required', true)
  ),
  true
)
ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION data.default_medical_clearance_template_locale_id()
RETURNS uuid
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT '71000000-0000-0000-0000-000000000042'::uuid;
$$;

-- ---------------------------------------------------------------------------
-- 3. Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.assert_can_manage_medical_clearance(p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF p_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  IF NOT (
    coalesce(data.jwt_has_permission(p_tenant_id, 'compliance.medical_clearance.manage'), false)
    OR (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') = 'owner'
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION data.load_medical_certification_for_tenant(
  p_certification_id uuid,
  p_tenant_id uuid
)
RETURNS data.employee_certifications
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_row data.employee_certifications;
  v_cat text;
BEGIN
  SELECT c.* INTO v_row
  FROM data.employee_certifications c
  WHERE c.id = p_certification_id AND c.tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'certification_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT t.category INTO v_cat
  FROM data.compliance_requirement_types t
  WHERE t.id = v_row.requirement_type_id;

  IF v_cat IS DISTINCT FROM 'medical' THEN
    RAISE EXCEPTION 'not_medical_certification' USING ERRCODE = 'check_violation';
  END IF;

  IF v_row.revoked_at IS NOT NULL THEN
    RAISE EXCEPTION 'certification_revoked' USING ERRCODE = 'check_violation';
  END IF;

  RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION data.build_medical_clearance_variables(
  p_cert data.employee_certifications,
  p_emp data.employees
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_type data.compliance_requirement_types;
  v_fitness text;
BEGIN
  SELECT * INTO v_type FROM data.compliance_requirement_types WHERE id = p_cert.requirement_type_id;

  -- CR-D9: només aptitud genèrica a document; sense motiu clínic
  v_fitness := coalesce(
    nullif(btrim(p_cert.notes), ''),
    'fit'
  );

  RETURN jsonb_build_object(
    'worker.full_name', coalesce(p_emp.full_name, ''),
    'requirement_name', coalesce(v_type.name, ''),
    'requirement_code', coalesce(v_type.code, ''),
    'issuer', coalesce(p_cert.issuer, ''),
    'valid_from', coalesce(p_cert.valid_from::text, ''),
    'valid_until', coalesce(p_cert.valid_until::text, 'indefinida'),
    'fitness', v_fitness
  );
END;
$$;

CREATE OR REPLACE FUNCTION data.create_medical_clearance_document(
  p_tenant_id uuid,
  p_site_id uuid,
  p_certification_id uuid,
  p_title text,
  p_locale data.document_template_locales,
  p_tmpl data.document_templates,
  p_vars jsonb,
  p_rendered text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_doc_id uuid;
BEGIN
  INSERT INTO data.documents (
    tenant_id, site_id, title, category, entity_type, entity_id,
    required_permissions, created_by
  )
  VALUES (
    p_tenant_id,
    p_site_id,
    p_title,
    coalesce(p_tmpl.category, 'hr'),
    'employee_certification',
    p_certification_id,
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
    format('medical-clearance://%s/v1', p_certification_id),
    'text/html',
    octet_length(coalesce(p_rendered, '')),
    auth.uid()
  );

  PERFORM data.log_audit_event(
    p_tenant_id, auth.uid(), p_site_id,
    'MEDICAL_CLEARANCE_DOC_GENERATED',
    'employee_certification', p_certification_id,
    jsonb_build_object(
      'document_id', v_doc_id,
      'template_locale_id', p_locale.id,
      'template_id', p_tmpl.id,
      'variables', p_vars
    ),
    false
  );

  RETURN v_doc_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. generate
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.generate_employee_medical_clearance_document(
  p_certification_id uuid,
  p_template_locale_id uuid DEFAULT NULL,
  p_force boolean DEFAULT false
)
RETURNS api.employee_certifications
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_cert data.employee_certifications;
  v_emp data.employees;
  v_locale data.document_template_locales;
  v_tmpl data.document_templates;
  v_vars jsonb;
  v_rendered text;
  v_doc_id uuid;
  v_locale_id uuid;
  v_out api.employee_certifications;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  PERFORM data.assert_can_manage_medical_clearance(v_tenant_id);
  v_cert := data.load_medical_certification_for_tenant(p_certification_id, v_tenant_id);
  SELECT * INTO v_emp FROM data.employees WHERE id = v_cert.employee_id;

  IF v_cert.document_id IS NOT NULL AND NOT p_force THEN
    IF EXISTS (SELECT 1 FROM data.documents d WHERE d.id = v_cert.document_id) THEN
      SELECT * INTO v_out FROM api.employee_certifications WHERE id = v_cert.id;
      RETURN v_out;
    END IF;
  END IF;

  IF p_force AND v_cert.signing_submission_id IS NOT NULL THEN
    RAISE EXCEPTION 'cannot_regenerate_signed_medical_clearance'
      USING ERRCODE = 'check_violation';
  END IF;

  v_locale_id := coalesce(
    p_template_locale_id,
    data.default_medical_clearance_template_locale_id()
  );

  SELECT * INTO v_locale
  FROM data.document_template_locales
  WHERE id = v_locale_id AND is_active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'template_locale_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT * INTO v_tmpl FROM data.document_templates WHERE id = v_locale.template_id AND is_active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'template_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_tmpl.tenant_id IS NOT NULL AND v_tmpl.tenant_id <> v_tenant_id THEN
    RAISE EXCEPTION 'template_tenant_mismatch' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_vars := data.build_medical_clearance_variables(v_cert, v_emp);
  v_rendered := data.render_employment_contract_html(v_locale.html_content, v_vars);

  v_doc_id := data.create_medical_clearance_document(
    v_tenant_id,
    v_emp.site_id,
    v_cert.id,
    format(
      'Reconeixement mèdic — %s — %s',
      coalesce(v_emp.full_name, 'empleat'),
      coalesce((SELECT code FROM data.compliance_requirement_types WHERE id = v_cert.requirement_type_id), 'MED')
    ),
    v_locale,
    v_tmpl,
    v_vars,
    v_rendered
  );

  UPDATE data.employee_certifications
  SET document_id = v_doc_id
  WHERE id = v_cert.id;

  SELECT * INTO v_out FROM api.employee_certifications WHERE id = v_cert.id;
  RETURN v_out;
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. prepare + link signing
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.prepare_employee_medical_clearance_signing(
  p_certification_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_cert data.employee_certifications;
  v_emp data.employees;
  v_vars jsonb;
  v_locale_id uuid;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  PERFORM data.assert_can_manage_medical_clearance(v_tenant_id);
  v_cert := data.load_medical_certification_for_tenant(p_certification_id, v_tenant_id);
  SELECT * INTO v_emp FROM data.employees WHERE id = v_cert.employee_id;

  IF v_cert.signing_submission_id IS NOT NULL THEN
    RAISE EXCEPTION 'medical_clearance_already_signing' USING ERRCODE = 'check_violation';
  END IF;

  v_locale_id := data.default_medical_clearance_template_locale_id();
  v_vars := data.build_medical_clearance_variables(v_cert, v_emp);

  RETURN jsonb_build_object(
    'certification_id', v_cert.id,
    'employee_id', v_emp.id,
    'employee_name', coalesce(v_emp.full_name, ''),
    'template_locale_id', v_locale_id,
    'variables', v_vars,
    'document_title', format(
      'Reconeixement mèdic — %s',
      coalesce(v_emp.full_name, 'empleat')
    ),
    'document_category', 'hr'
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.link_employee_medical_clearance_signing(
  p_certification_id uuid,
  p_signing_submission_id uuid,
  p_document_id uuid DEFAULT NULL
)
RETURNS api.employee_certifications
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_cert data.employee_certifications;
  v_sub data.signing_submissions;
  v_out api.employee_certifications;
  v_doc_id uuid;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  PERFORM data.assert_can_manage_medical_clearance(v_tenant_id);
  v_cert := data.load_medical_certification_for_tenant(p_certification_id, v_tenant_id);

  SELECT * INTO v_sub
  FROM data.signing_submissions
  WHERE id = p_signing_submission_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'signing_submission_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  v_doc_id := coalesce(p_document_id, v_cert.document_id);

  IF v_doc_id IS NOT NULL THEN
    UPDATE data.documents SET
      entity_type = coalesce(nullif(entity_type, ''), 'employee_certification'),
      entity_id = coalesce(entity_id, v_cert.id),
      required_permissions = CASE
        WHEN required_permissions IS NULL OR cardinality(required_permissions) = 0
          THEN ARRAY['owner', 'manager']
        ELSE required_permissions
      END,
      updated_at = now()
    WHERE id = v_doc_id AND tenant_id = v_tenant_id;
  END IF;

  UPDATE data.employee_certifications
  SET
    signing_submission_id = p_signing_submission_id,
    document_id = coalesce(v_doc_id, document_id)
  WHERE id = v_cert.id;

  PERFORM data.log_audit_event(
    v_tenant_id, auth.uid(),
    (SELECT site_id FROM data.employees WHERE id = v_cert.employee_id),
    'MEDICAL_CLEARANCE_SIGNING_LINKED',
    'employee_certification', v_cert.id,
    jsonb_build_object(
      'signing_submission_id', p_signing_submission_id,
      'document_id', v_doc_id
    ),
    false
  );

  SELECT * INTO v_out FROM api.employee_certifications WHERE id = v_cert.id;
  RETURN v_out;
END;
$$;

REVOKE ALL ON FUNCTION api.generate_employee_medical_clearance_document(uuid, uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.prepare_employee_medical_clearance_signing(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.link_employee_medical_clearance_signing(uuid, uuid, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.generate_employee_medical_clearance_document(uuid, uuid, boolean)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.prepare_employee_medical_clearance_signing(uuid)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.link_employee_medical_clearance_signing(uuid, uuid, uuid)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
