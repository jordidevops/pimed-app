-- =============================================================================
-- M-EC-05 — Employment contract multi-signer (EC-5 mínim)
-- Link submission + trigger complete/decline/expire + prep RPC + template fields.
-- Reuses DocuSeal via sign-document-router (frontend); no new signing engine.
-- =============================================================================

-- FK signing_submission_id
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'employment_contracts_signing_submission_id_fkey'
  ) THEN
    ALTER TABLE data.employment_contracts
      ADD CONSTRAINT employment_contracts_signing_submission_id_fkey
      FOREIGN KEY (signing_submission_id) REFERENCES data.signing_submissions(id) ON DELETE SET NULL;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_employment_contracts_signing_submission
  ON data.employment_contracts (signing_submission_id)
  WHERE signing_submission_id IS NOT NULL;

-- Signature fields on platform HTML template (Contracte de treball indefinit)
UPDATE data.document_template_locales
SET html_content = coalesce(html_content, '')
  || CASE
       WHEN coalesce(html_content, '') ILIKE '%signature-field%role="worker"%' THEN ''
       ELSE '<hr/><p>Signatura treballador/a:</p><signature-field name="FirmaTreballador" role="worker" required="true" style="width:180px;height:60px;display:inline-block;"></signature-field><p>Signatura responsable RRHH:</p><signature-field name="FirmaRRHH" role="hr_manager" required="true" style="width:180px;height:60px;display:inline-block;"></signature-field>'
     END
WHERE id = '71000000-0000-0000-0000-000000000001';

-- Widen resolve_employee_signer_email for HR / contracts managers
CREATE OR REPLACE FUNCTION api.resolve_employee_signer_email(p_employee_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp   record;
  v_email text;
BEGIN
  SELECT e.tenant_id, e.site_id, e.user_id, e.email AS emp_email
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF NOT (
      v_emp.user_id = auth.uid()
      OR data.jwt_has_permission(v_emp.tenant_id, 'attendance.manage', v_emp.site_id)
      OR data.jwt_has_permission(v_emp.tenant_id, 'attendance.approve', v_emp.site_id)
      OR data.jwt_has_permission(v_emp.tenant_id, 'attendance.export', v_emp.site_id)
      OR data.jwt_can_manage_employment_contracts(v_emp.tenant_id, v_emp.site_id)
      OR data.jwt_has_permission(v_emp.tenant_id, 'employees.manage', v_emp.site_id)
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege';
    END IF;
  END IF;

  v_email := NULLIF(trim(COALESCE(v_emp.emp_email, '')), '');

  IF v_email IS NULL AND v_emp.user_id IS NOT NULL THEN
    SELECT NULLIF(trim(COALESCE(p.email, '')), '')
    INTO v_email
    FROM data.profiles p
    WHERE p.id = v_emp.user_id;
  END IF;

  RETURN v_email;
END;
$$;

-- Prep payload for frontend → sign-document-router (no DocuSeal call here)
CREATE OR REPLACE FUNCTION api.prepare_employment_contract_signing(
  p_contract_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_c         data.employment_contracts%ROWTYPE;
  v_emp       data.employees%ROWTYPE;
  v_vars      jsonb;
  v_locale_id uuid;
  v_email     text;
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

  IF v_c.lifecycle_status <> 'draft' THEN
    RAISE EXCEPTION 'contract_not_draft' USING ERRCODE = 'check_violation';
  END IF;

  IF v_c.signature_status IN ('partial', 'completed') THEN
    RAISE EXCEPTION 'contract_already_signed' USING ERRCODE = 'check_violation';
  END IF;

  v_locale_id := coalesce(
    v_c.template_locale_id,
    data.default_employment_contract_template_locale_id()
  );

  v_vars := data.build_employment_contract_variables(v_c, v_emp);
  v_email := api.resolve_employee_signer_email(v_emp.id);

  RETURN jsonb_build_object(
    'contract_id', v_c.id,
    'employee_id', v_emp.id,
    'employee_name', coalesce(v_emp.full_name, ''),
    'employee_email', v_email,
    'template_locale_id', v_locale_id,
    'variables', v_vars,
    'document_title', format(
      'Contracte — %s — %s',
      coalesce(v_emp.full_name, 'empleat'),
      coalesce(v_c.starts_on::text, CURRENT_DATE::text)
    )
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION api.prepare_employment_contract_signing(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.prepare_employment_contract_signing(uuid) TO authenticated;

-- Link after sign-document-router returns
CREATE OR REPLACE FUNCTION api.link_employment_contract_signing(
  p_contract_id           uuid,
  p_signing_submission_id uuid,
  p_document_id           uuid DEFAULT NULL
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
  v_sub       data.signing_submissions%ROWTYPE;
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

  IF v_c.lifecycle_status <> 'draft' THEN
    RAISE EXCEPTION 'contract_not_draft' USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_sub
  FROM data.signing_submissions
  WHERE id = p_signing_submission_id AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'signing_submission_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF p_document_id IS NOT NULL THEN
    UPDATE data.documents SET
      entity_type = coalesce(nullif(entity_type, ''), 'employment_contract'),
      entity_id = coalesce(entity_id, v_c.id),
      required_permissions = CASE
        WHEN required_permissions IS NULL OR cardinality(required_permissions) = 0
          THEN ARRAY['owner', 'manager']
        ELSE required_permissions
      END,
      updated_at = now()
    WHERE id = p_document_id AND tenant_id = v_tenant_id;
  END IF;

  UPDATE data.employment_contracts SET
    signing_submission_id = p_signing_submission_id,
    generated_document_id = coalesce(p_document_id, generated_document_id),
    template_locale_id = coalesce(
      template_locale_id,
      v_sub.source_template_locale_id,
      data.default_employment_contract_template_locale_id()
    ),
    signature_requirement = CASE
      WHEN signature_requirement = 'none' THEN 'employee_and_employer'
      ELSE signature_requirement
    END,
    signature_status = CASE
      WHEN v_sub.status = 'completed' THEN 'completed'
      WHEN v_sub.status IN ('declined') THEN 'rejected'
      WHEN v_sub.status = 'expired' THEN 'expired'
      ELSE 'pending'
    END,
    fully_signed_at = CASE WHEN v_sub.status = 'completed' THEN coalesce(fully_signed_at, now()) ELSE NULL END,
    final_document_version_id = CASE
      WHEN v_sub.status = 'completed' THEN coalesce(v_sub.result_document_version_id, final_document_version_id)
      ELSE NULL
    END,
    updated_at = now()
  WHERE id = v_c.id;

  SELECT * INTO v_out FROM api.employment_contracts WHERE id = v_c.id;
  RETURN v_out;
END;
$$;

REVOKE EXECUTE ON FUNCTION api.link_employment_contract_signing(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.link_employment_contract_signing(uuid, uuid, uuid) TO authenticated;

-- Completion / rejection trigger
CREATE OR REPLACE FUNCTION data.trg_sync_employment_contract_signing()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_doc_id uuid;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  IF NEW.status = 'completed' THEN
    IF NEW.result_document_version_id IS NOT NULL THEN
      SELECT document_id INTO v_doc_id
      FROM data.document_versions
      WHERE id = NEW.result_document_version_id;
    END IF;

    UPDATE data.employment_contracts c
    SET
      signature_status = 'completed',
      fully_signed_at = coalesce(c.fully_signed_at, now()),
      final_document_version_id = coalesce(NEW.result_document_version_id, c.final_document_version_id),
      generated_document_id = coalesce(v_doc_id, c.generated_document_id),
      updated_at = now()
    WHERE c.signing_submission_id = NEW.id;

  ELSIF NEW.status = 'declined' THEN
    UPDATE data.employment_contracts c
    SET signature_status = 'rejected', updated_at = now()
    WHERE c.signing_submission_id = NEW.id
      AND c.signature_status IS DISTINCT FROM 'completed';

  ELSIF NEW.status = 'expired' THEN
    UPDATE data.employment_contracts c
    SET signature_status = 'expired', updated_at = now()
    WHERE c.signing_submission_id = NEW.id
      AND c.signature_status IS DISTINCT FROM 'completed';

  ELSIF NEW.status IN ('cancelled', 'error') THEN
    -- Allow retry: keep requirement, clear submission link, leave status pending
    UPDATE data.employment_contracts c
    SET
      signing_submission_id = NULL,
      signature_status = CASE
        WHEN c.signature_requirement = 'none' THEN 'not_required'
        ELSE 'pending'
      END,
      updated_at = now()
    WHERE c.signing_submission_id = NEW.id
      AND c.signature_status IS DISTINCT FROM 'completed';

  ELSIF NEW.status IN ('pending', 'in_progress') THEN
    UPDATE data.employment_contracts c
    SET signature_status = 'pending', updated_at = now()
    WHERE c.signing_submission_id = NEW.id
      AND c.signature_status IS DISTINCT FROM 'completed';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_employment_contract_signing ON data.signing_submissions;
CREATE TRIGGER trg_employment_contract_signing
  AFTER UPDATE OF status ON data.signing_submissions
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_sync_employment_contract_signing();

-- Tighten transition: draft→active also requires completed signature when required;
-- rejected/expired block scheduled/active
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

  IF p_to_status IN ('scheduled', 'active')
     AND v_c.signature_requirement <> 'none'
     AND v_c.signature_status IN ('rejected', 'expired') THEN
    RAISE EXCEPTION 'signature_blocked' USING ERRCODE = 'check_violation';
  END IF;

  IF p_to_status = 'scheduled' THEN
    IF v_c.lifecycle_status <> 'draft' THEN
      RAISE EXCEPTION 'invalid_contract_transition' USING ERRCODE = 'check_violation';
    END IF;
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
    IF v_c.lifecycle_status = 'draft'
       AND v_c.signature_requirement <> 'none'
       AND v_c.signature_status <> 'completed' THEN
      RAISE EXCEPTION 'signature_required' USING ERRCODE = 'check_violation';
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

NOTIFY pgrst, 'reload schema';
