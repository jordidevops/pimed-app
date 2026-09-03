-- =============================================================================
-- M-EC-04 — Employment contract documents (EC-4 mínim)
-- FKs plantilla/document, vista API completa, generate idempotent + link RPC.
-- Firma multi-signant = EC-5 (no aquí).
-- Default locale: platform HTML «Contracte de treball indefinit» (710…0001).
-- =============================================================================

-- ─── FKs (additives; columns already exist from EC-1) ─────────────────────────

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'employment_contracts_template_id_fkey'
  ) THEN
    ALTER TABLE data.employment_contracts
      ADD CONSTRAINT employment_contracts_template_id_fkey
      FOREIGN KEY (template_id) REFERENCES data.document_templates(id) ON DELETE SET NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'employment_contracts_template_locale_id_fkey'
  ) THEN
    ALTER TABLE data.employment_contracts
      ADD CONSTRAINT employment_contracts_template_locale_id_fkey
      FOREIGN KEY (template_locale_id) REFERENCES data.document_template_locales(id) ON DELETE SET NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'employment_contracts_generated_document_id_fkey'
  ) THEN
    ALTER TABLE data.employment_contracts
      ADD CONSTRAINT employment_contracts_generated_document_id_fkey
      FOREIGN KEY (generated_document_id) REFERENCES data.documents(id) ON DELETE SET NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'employment_contracts_final_document_version_id_fkey'
  ) THEN
    ALTER TABLE data.employment_contracts
      ADD CONSTRAINT employment_contracts_final_document_version_id_fkey
      FOREIGN KEY (final_document_version_id) REFERENCES data.document_versions(id) ON DELETE SET NULL;
  END IF;
END $$;

-- ─── API view: expose template/doc columns ───────────────────────────────────

DROP FUNCTION IF EXISTS api.generate_employment_contract_document(uuid, uuid, boolean);
DROP FUNCTION IF EXISTS api.link_employment_contract_document(uuid, uuid, uuid, jsonb, jsonb);
DROP FUNCTION IF EXISTS api.get_effective_employment_contract(uuid, date);
DROP FUNCTION IF EXISTS api.transition_employment_contract(uuid, text, text);
DROP VIEW IF EXISTS api.employment_contracts;

CREATE VIEW api.employment_contracts
  WITH (security_invoker = true) AS
SELECT
  id, tenant_id, employee_id, contract_number, source, external_reference,
  lifecycle_status, approval_status, signature_status, signature_requirement, is_primary,
  starts_on, ends_on, probation_ends_on,
  contract_type_id, job_position_id, department_id, site_id, calendar_group_id,
  weekly_hours, fte, work_entry_source,
  supersedes_contract_id, termination_reason_code, termination_notes,
  template_id, template_locale_id, template_snapshot, variables_snapshot,
  generated_document_id, final_document_version_id, signing_submission_id,
  approved_by, approved_at, fully_signed_at, activated_at, ended_at,
  cancelled_at, cancellation_reason,
  created_by, created_at, updated_at, metadata
FROM data.employment_contracts;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.employment_contracts TO authenticated;

-- ─── Helpers: resolve default locale + build variables ───────────────────────

CREATE OR REPLACE FUNCTION data.default_employment_contract_template_locale_id()
RETURNS uuid
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT '71000000-0000-0000-0000-000000000001'::uuid;
$$;

CREATE OR REPLACE FUNCTION data.build_employment_contract_variables(
  p_contract data.employment_contracts,
  p_employee data.employees
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_doc_id text;
  v_salary text := '';
  v_include_comp boolean;
BEGIN
  SELECT coalesce(pp.document_number, p_employee.document_id, '')
  INTO v_doc_id
  FROM data.employees e
  LEFT JOIN data.employee_private_profiles pp
    ON pp.employee_id = e.id AND pp.tenant_id = e.tenant_id
  WHERE e.id = p_employee.id;

  v_include_comp := data.jwt_can_view_employment_compensation(p_contract.tenant_id);

  IF v_include_comp THEN
    SELECT coalesce(c.annual_gross::text, c.gross_amount::text, '')
    INTO v_salary
    FROM data.employment_contract_compensation c
    WHERE c.contract_id = p_contract.id;
  END IF;

  RETURN jsonb_build_object(
    'full_name', coalesce(p_employee.full_name, ''),
    'document_id', coalesce(v_doc_id, ''),
    'job_title', coalesce(p_employee.job_title, ''),
    'data_inici', coalesce(p_contract.starts_on::text, ''),
    'salari_anual', coalesce(v_salary, ''),
    'jornada_hores', coalesce(p_contract.weekly_hours::text, '')
  );
END;
$$;

CREATE OR REPLACE FUNCTION data.render_employment_contract_html(
  p_html text,
  p_vars jsonb
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_out text := coalesce(p_html, '');
  v_key text;
  v_val text;
BEGIN
  FOR v_key, v_val IN SELECT * FROM jsonb_each_text(coalesce(p_vars, '{}'::jsonb))
  LOOP
    -- Plain {{key}}
    v_out := replace(v_out, '{{' || v_key || '}}', coalesce(v_val, ''));
    -- Liquid-ish {{ key | date: "..." }} — replace whole token with raw value
    v_out := regexp_replace(
      v_out,
      '\{\{\s*' || v_key || '\s*\|[^}]*\}\}',
      coalesce(v_val, ''),
      'g'
    );
  END LOOP;
  RETURN v_out;
END;
$$;

-- ─── generate_employment_contract_document ───────────────────────────────────

CREATE OR REPLACE FUNCTION api.generate_employment_contract_document(
  p_contract_id         uuid,
  p_template_locale_id  uuid DEFAULT NULL,
  p_force               boolean DEFAULT false
)
RETURNS api.employment_contracts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_c         data.employment_contracts%ROWTYPE;
  v_emp       data.employees%ROWTYPE;
  v_locale    data.document_template_locales%ROWTYPE;
  v_tmpl      data.document_templates%ROWTYPE;
  v_vars      jsonb;
  v_snapshot  jsonb;
  v_rendered  text;
  v_doc_id    uuid;
  v_ver_id    uuid;
  v_title     text;
  v_out       api.employment_contracts;
  v_locale_id uuid;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT * INTO v_c
  FROM data.employment_contracts
  WHERE id = p_contract_id AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'contract_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT * INTO v_emp FROM data.employees WHERE id = v_c.employee_id;
  IF NOT data.jwt_can_manage_employment_contracts(v_emp.tenant_id, v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Idempotent: return existing unless force (and not fully signed)
  IF v_c.generated_document_id IS NOT NULL AND NOT p_force THEN
    IF EXISTS (SELECT 1 FROM data.documents d WHERE d.id = v_c.generated_document_id) THEN
      SELECT * INTO v_out FROM api.employment_contracts WHERE id = v_c.id;
      RETURN v_out;
    END IF;
  END IF;

  IF p_force AND v_c.signature_status IN ('partial', 'completed') THEN
    RAISE EXCEPTION 'cannot_regenerate_signed_contract' USING ERRCODE = 'check_violation';
  END IF;

  v_locale_id := coalesce(
    p_template_locale_id,
    v_c.template_locale_id,
    data.default_employment_contract_template_locale_id()
  );

  SELECT * INTO v_locale
  FROM data.document_template_locales
  WHERE id = v_locale_id AND is_active;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'template_locale_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT * INTO v_tmpl FROM data.document_templates WHERE id = v_locale.template_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'template_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  -- Platform templates (tenant_id null) or same tenant
  IF v_tmpl.tenant_id IS NOT NULL AND v_tmpl.tenant_id <> v_tenant_id THEN
    RAISE EXCEPTION 'template_tenant_mismatch' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_vars := data.build_employment_contract_variables(v_c, v_emp);
  v_rendered := data.render_employment_contract_html(v_locale.html_content, v_vars);

  v_snapshot := jsonb_build_object(
    'template_id', v_tmpl.id,
    'template_name', v_tmpl.name,
    'template_locale_id', v_locale.id,
    'locale', v_locale.locale,
    'mime_type', v_locale.mime_type,
    'variables_schema', coalesce(v_locale.variables_schema, '{}'::jsonb),
    'signing_roles_schema', coalesce(v_locale.signing_roles_schema, '{}'::jsonb),
    'html_content', v_locale.html_content,
    'rendered_html', v_rendered,
    'snapshotted_at', now()
  );

  v_title := format(
    'Contracte — %s — %s',
    coalesce(v_emp.full_name, 'empleat'),
    coalesce(v_c.starts_on::text, CURRENT_DATE::text)
  );

  IF p_force AND v_c.generated_document_id IS NOT NULL THEN
    -- Soft-replace: keep old doc; create a new one and point contract at it
    NULL;
  END IF;

  INSERT INTO data.documents (
    tenant_id, site_id, title, category, entity_type, entity_id,
    required_permissions
  )
  VALUES (
    v_tenant_id,
    coalesce(v_c.site_id, v_emp.site_id),
    v_title,
    'hr',
    'employment_contract',
    v_c.id,
    ARRAY['owner', 'manager']
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
    format('employment-contract://%s/v1', v_c.id),
    'text/html',
    octet_length(coalesce(v_rendered, '')),
    auth.uid()
  )
  RETURNING id INTO v_ver_id;

  -- Store rendered HTML on version metadata if column exists; else contract snapshot only
  UPDATE data.employment_contracts SET
    template_id = v_tmpl.id,
    template_locale_id = v_locale.id,
    template_snapshot = v_snapshot,
    variables_snapshot = v_vars,
    generated_document_id = v_doc_id,
    updated_at = now()
  WHERE id = v_c.id;

  SELECT * INTO v_out FROM api.employment_contracts WHERE id = v_c.id;
  RETURN v_out;
END;
$$;

REVOKE EXECUTE ON FUNCTION api.generate_employment_contract_document(uuid, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.generate_employment_contract_document(uuid, uuid, boolean) TO authenticated;

-- Link a document created externally (e.g. DocumentOrchestrator / sign-document-router)
CREATE OR REPLACE FUNCTION api.link_employment_contract_document(
  p_contract_id         uuid,
  p_document_id         uuid,
  p_template_locale_id  uuid DEFAULT NULL,
  p_variables_snapshot  jsonb DEFAULT NULL,
  p_template_snapshot   jsonb DEFAULT NULL
)
RETURNS api.employment_contracts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_c         data.employment_contracts%ROWTYPE;
  v_emp       data.employees%ROWTYPE;
  v_doc       data.documents%ROWTYPE;
  v_locale    data.document_template_locales%ROWTYPE;
  v_out       api.employment_contracts;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT * INTO v_c FROM data.employment_contracts WHERE id = p_contract_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'contract_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT * INTO v_emp FROM data.employees WHERE id = v_c.employee_id;
  IF NOT data.jwt_can_manage_employment_contracts(v_emp.tenant_id, v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_doc FROM data.documents WHERE id = p_document_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  -- Ensure entity link on document
  UPDATE data.documents SET
    entity_type = coalesce(nullif(entity_type, ''), 'employment_contract'),
    entity_id = coalesce(entity_id, v_c.id),
    required_permissions = CASE
      WHEN required_permissions IS NULL OR cardinality(required_permissions) = 0
        THEN ARRAY['owner', 'manager']
      ELSE required_permissions
    END,
    updated_at = now()
  WHERE id = v_doc.id;

  IF p_template_locale_id IS NOT NULL THEN
    SELECT * INTO v_locale FROM data.document_template_locales WHERE id = p_template_locale_id;
  END IF;

  UPDATE data.employment_contracts SET
    generated_document_id = v_doc.id,
    template_locale_id = coalesce(p_template_locale_id, template_locale_id),
    template_id = coalesce(v_locale.template_id, template_id),
    variables_snapshot = coalesce(p_variables_snapshot, variables_snapshot),
    template_snapshot = coalesce(p_template_snapshot, template_snapshot),
    updated_at = now()
  WHERE id = v_c.id;

  SELECT * INTO v_out FROM api.employment_contracts WHERE id = v_c.id;
  RETURN v_out;
END;
$$;

REVOKE EXECUTE ON FUNCTION api.link_employment_contract_document(uuid, uuid, uuid, jsonb, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.link_employment_contract_document(uuid, uuid, uuid, jsonb, jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ═══ Recreate RPCs dropped when replacing api.employment_contracts view ═══

-- Fix get_effective_employment_contract: SELECT from api view (38 cols),
-- not data table (43 cols) — positional INTO was mapping jsonb {} onto uuid.

CREATE OR REPLACE FUNCTION api.get_effective_employment_contract(
  p_employee_id uuid,
  p_on date DEFAULT CURRENT_DATE
)
RETURNS api.employment_contracts
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_emp data.employees%ROWTYPE;
  v_out api.employment_contracts;
  v_on date := coalesce(p_on, CURRENT_DATE);
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT * INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT (
    data.jwt_can_view_employment_contracts(v_emp.tenant_id, v_emp.site_id)
    OR (v_emp.user_id IS NOT NULL AND v_emp.user_id = auth.uid())
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT c.* INTO v_out
  FROM api.employment_contracts c
  WHERE c.tenant_id = v_tenant_id
    AND c.employee_id = p_employee_id
    AND c.is_primary
    AND c.lifecycle_status IN ('active', 'scheduled', 'ended')
    AND c.starts_on <= v_on
    AND (c.ends_on IS NULL OR c.ends_on >= v_on)
  ORDER BY
    CASE c.lifecycle_status WHEN 'active' THEN 0 WHEN 'scheduled' THEN 1 ELSE 2 END,
    c.starts_on DESC
  LIMIT 1;

  RETURN v_out;
END;
$$;

REVOKE EXECUTE ON FUNCTION api.get_effective_employment_contract(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_effective_employment_contract(uuid, date) TO authenticated;

NOTIFY pgrst, 'reload schema';

CREATE OR REPLACE FUNCTION api.transition_employment_contract(
  p_contract_id uuid,
  p_to_status text,
  p_reason text DEFAULT NULL
)
RETURNS api.employment_contracts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_c data.employment_contracts%ROWTYPE;
  v_emp data.employees%ROWTYPE;
  v_out api.employment_contracts;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT * INTO v_c FROM data.employment_contracts WHERE id = p_contract_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'contract_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT * INTO v_emp FROM data.employees WHERE id = v_c.employee_id;
  IF NOT data.jwt_can_manage_employment_contracts(v_emp.tenant_id, v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_to_status = 'scheduled' THEN
    IF v_c.lifecycle_status <> 'draft' THEN
      RAISE EXCEPTION 'invalid_contract_transition' USING ERRCODE = 'check_violation';
    END IF;
    -- EC-5 will enforce signature; mínim: requirement none OR already completed
    IF v_c.signature_requirement <> 'none' AND v_c.signature_status <> 'completed' THEN
      RAISE EXCEPTION 'signature_required' USING ERRCODE = 'check_violation';
    END IF;
    UPDATE data.employment_contracts SET
      lifecycle_status = 'scheduled',
      approval_status = CASE WHEN approval_status = 'pending' THEN 'approved' ELSE approval_status END,
      approved_by = coalesce(approved_by, auth.uid()),
      approved_at = coalesce(approved_at, now()),
      updated_at = now()
    WHERE id = v_c.id;

  ELSIF p_to_status = 'active' THEN
    IF v_c.lifecycle_status NOT IN ('scheduled', 'draft') THEN
      RAISE EXCEPTION 'invalid_contract_transition' USING ERRCODE = 'check_violation';
    END IF;
    IF v_c.starts_on > CURRENT_DATE THEN
      RAISE EXCEPTION 'contract_not_started' USING ERRCODE = 'check_violation';
    END IF;
    UPDATE data.employment_contracts SET
      lifecycle_status = 'active',
      activated_at = coalesce(activated_at, now()),
      updated_at = now()
    WHERE id = v_c.id;

  ELSIF p_to_status = 'ended' THEN
    IF v_c.lifecycle_status NOT IN ('active', 'scheduled') THEN
      RAISE EXCEPTION 'invalid_contract_transition' USING ERRCODE = 'check_violation';
    END IF;
    UPDATE data.employment_contracts SET
      lifecycle_status = 'ended',
      ended_at = coalesce(ended_at, now()),
      ends_on = coalesce(ends_on, CURRENT_DATE),
      termination_notes = coalesce(p_reason, termination_notes),
      updated_at = now()
    WHERE id = v_c.id;

  ELSIF p_to_status = 'cancelled' THEN
    IF v_c.lifecycle_status IN ('ended', 'cancelled') THEN
      RAISE EXCEPTION 'invalid_contract_transition' USING ERRCODE = 'check_violation';
    END IF;
    UPDATE data.employment_contracts SET
      lifecycle_status = 'cancelled',
      cancelled_at = now(),
      cancellation_reason = p_reason,
      updated_at = now()
    WHERE id = v_c.id;

  ELSE
    RAISE EXCEPTION 'invalid_contract_status' USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_out FROM api.employment_contracts WHERE id = v_c.id;
  RETURN v_out;
END;
$$;

REVOKE EXECUTE ON FUNCTION api.transition_employment_contract(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.transition_employment_contract(uuid, text, text) TO authenticated;

