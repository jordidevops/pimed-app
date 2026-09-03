-- =============================================================================
-- M-CR-04 — RLS per category + RPCs certificacions (CR-D9)
-- =============================================================================

-- SELECT no-mèdic: certifications.view (o owner/manager)
DROP POLICY IF EXISTS employee_certifications_select_non_medical ON data.employee_certifications;
CREATE POLICY employee_certifications_select_non_medical ON data.employee_certifications
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND EXISTS (
      SELECT 1 FROM data.compliance_requirement_types t
      WHERE t.id = requirement_type_id
        AND t.category IN ('legal', 'technical', 'other')
    )
    AND (
      data.jwt_has_permission(tenant_id, 'compliance.certifications.view')
      OR data.jwt_has_permission(tenant_id, 'compliance.certifications.manage')
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  );

-- SELECT mèdic: medical_clearance.view (o owner) — NO heretat per manager
DROP POLICY IF EXISTS employee_certifications_select_medical ON data.employee_certifications;
CREATE POLICY employee_certifications_select_medical ON data.employee_certifications
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND EXISTS (
      SELECT 1 FROM data.compliance_requirement_types t
      WHERE t.id = requirement_type_id
        AND t.category = 'medical'
    )
    AND (
      data.jwt_has_permission(tenant_id, 'compliance.medical_clearance.view')
      OR data.jwt_has_permission(tenant_id, 'compliance.medical_clearance.manage')
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') = 'owner'
    )
  );

CREATE OR REPLACE FUNCTION api.list_employee_certifications(
  p_employee_id uuid,
  p_include_revoked boolean DEFAULT false
)
RETURNS SETOF api.employee_certifications
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = api, data
AS $$
  SELECT c.*
  FROM api.employee_certifications c
  WHERE c.employee_id = p_employee_id
    AND c.tenant_id = data.active_tenant_id()
    AND (p_include_revoked OR c.revoked_at IS NULL)
  ORDER BY c.valid_from DESC, c.created_at DESC;
$$;

CREATE OR REPLACE FUNCTION api.upsert_employee_certification(
  p_id                  uuid DEFAULT NULL,
  p_employee_id         uuid DEFAULT NULL,
  p_requirement_type_id uuid DEFAULT NULL,
  p_issuer              text DEFAULT NULL,
  p_credential_number   text DEFAULT NULL,
  p_issued_on           date DEFAULT NULL,
  p_valid_from          date DEFAULT NULL,
  p_valid_until         date DEFAULT NULL,
  p_document_id         uuid DEFAULT NULL,
  p_notes               text DEFAULT NULL
)
RETURNS api.employee_certifications
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_user_id   uuid := auth.uid();
  v_employee  data.employees;
  v_type      data.compliance_requirement_types;
  v_row       data.employee_certifications;
  v_out       api.employee_certifications;
  v_is_medical boolean;
  v_can_manage boolean;
BEGIN
  IF v_tenant_id IS NULL OR v_user_id IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  IF p_id IS NOT NULL THEN
    SELECT * INTO v_row FROM data.employee_certifications
    WHERE id = p_id AND tenant_id = v_tenant_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'certification_not_found' USING ERRCODE = 'no_data_found';
    END IF;
    IF v_row.revoked_at IS NOT NULL THEN
      RAISE EXCEPTION 'certification_revoked' USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO v_type FROM data.compliance_requirement_types
    WHERE id = v_row.requirement_type_id;
  ELSE
    IF p_employee_id IS NULL OR p_requirement_type_id IS NULL THEN
      RAISE EXCEPTION 'employee_and_requirement_required' USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT * INTO v_employee FROM data.employees
    WHERE id = p_employee_id AND tenant_id = v_tenant_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
    END IF;

    SELECT * INTO v_type FROM data.compliance_requirement_types
    WHERE id = p_requirement_type_id
      AND (tenant_id IS NULL OR tenant_id = v_tenant_id);
    IF NOT FOUND THEN
      RAISE EXCEPTION 'requirement_type_not_found' USING ERRCODE = 'no_data_found';
    END IF;
  END IF;

  v_is_medical := (v_type.category = 'medical');
  v_can_manage := CASE
    WHEN v_is_medical THEN
      data.jwt_has_permission(v_tenant_id, 'compliance.medical_clearance.manage')
      OR (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') = 'owner'
    ELSE
      data.jwt_has_permission(v_tenant_id, 'compliance.certifications.manage')
      OR (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  END;

  IF NOT v_can_manage THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_id IS NOT NULL THEN
    UPDATE data.employee_certifications
    SET
      issuer = COALESCE(p_issuer, issuer),
      credential_number = COALESCE(p_credential_number, credential_number),
      issued_on = COALESCE(p_issued_on, issued_on),
      valid_from = COALESCE(p_valid_from, valid_from),
      valid_until = COALESCE(p_valid_until, valid_until),
      document_id = COALESCE(p_document_id, document_id),
      notes = COALESCE(p_notes, notes)
    WHERE id = p_id
    RETURNING * INTO v_row;
  ELSE
    INSERT INTO data.employee_certifications (
      tenant_id, employee_id, requirement_type_id,
      issuer, credential_number, issued_on,
      valid_from, valid_until, document_id, notes, created_by
    ) VALUES (
      v_tenant_id, p_employee_id, p_requirement_type_id,
      NULLIF(btrim(p_issuer), ''), NULLIF(btrim(p_credential_number), ''), p_issued_on,
      COALESCE(p_valid_from, CURRENT_DATE), p_valid_until, p_document_id,
      NULLIF(btrim(p_notes), ''), v_user_id
    )
    RETURNING * INTO v_row;
  END IF;

  SELECT * INTO v_out FROM api.employee_certifications WHERE id = v_row.id;
  RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION api.revoke_employee_certification(
  p_id     uuid,
  p_reason text DEFAULT NULL
)
RETURNS api.employee_certifications
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_user_id   uuid := auth.uid();
  v_row       data.employee_certifications;
  v_out       api.employee_certifications;
  v_type      data.compliance_requirement_types;
  v_is_medical boolean;
  v_can_manage boolean;
BEGIN
  IF v_tenant_id IS NULL OR v_user_id IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT * INTO v_row FROM data.employee_certifications
  WHERE id = p_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'certification_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_row.revoked_at IS NOT NULL THEN
    RAISE EXCEPTION 'already_revoked' USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_type FROM data.compliance_requirement_types
  WHERE id = v_row.requirement_type_id;

  v_is_medical := (v_type.category = 'medical');
  v_can_manage := CASE
    WHEN v_is_medical THEN
      data.jwt_has_permission(v_tenant_id, 'compliance.medical_clearance.manage')
      OR (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') = 'owner'
    ELSE
      data.jwt_has_permission(v_tenant_id, 'compliance.certifications.manage')
      OR (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  END;

  IF NOT v_can_manage THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.employee_certifications
  SET
    revoked_at = now(),
    revoked_reason = NULLIF(btrim(p_reason), '')
  WHERE id = p_id
  RETURNING * INTO v_row;

  SELECT * INTO v_out FROM api.employee_certifications WHERE id = v_row.id;
  RETURN v_out;
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_employee_certifications(uuid, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.upsert_employee_certification(
  uuid, uuid, uuid, text, text, date, date, date, uuid, text
) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.revoke_employee_certification(uuid, text) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
