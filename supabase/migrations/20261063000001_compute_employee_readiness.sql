-- =============================================================================
-- M-CR-05 — compute_employee_readiness (MVP: només scope_type='tenant')
-- =============================================================================

CREATE OR REPLACE FUNCTION data.compute_employee_readiness(
  p_employee_id uuid,
  p_as_of       date DEFAULT CURRENT_DATE,
  p_required_requirement_codes text[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id     uuid := data.active_tenant_id();
  v_employee_id   uuid;
  v_rule          record;
  v_reasons       text[] := '{}';
  v_has_valid     boolean;
  v_rule_count    int := 0;
  v_config_status text;
  v_has_uneval    boolean;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Guarda de tenant obligatòria (CR-D8): mai retorna dades d'un altre tenant.
  SELECT e.id INTO v_employee_id
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND e.tenant_id = v_tenant_id;

  IF v_employee_id IS NULL THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id
      USING ERRCODE = 'no_data_found';
  END IF;

  -- MVP (CR-2): només s'avaluen regles scope_type='tenant'.
  -- Regles department/job_position/site es poden crear (CR-0) però no bloquegen
  -- fins a CR-2b (requereix EHR-2 job_position_id / EC).
  FOR v_rule IN
    SELECT
      r.id,
      r.requirement_type_id,
      r.is_blocking,
      r.grace_period_days,
      t.code AS requirement_code,
      t.category
    FROM data.compliance_requirement_rules r
    JOIN data.compliance_requirement_types t ON t.id = r.requirement_type_id
    WHERE r.tenant_id = v_tenant_id
      AND r.is_active
      AND r.scope_type = 'tenant'
  LOOP
    v_rule_count := v_rule_count + 1;

    SELECT EXISTS (
      SELECT 1
      FROM data.employee_certifications c
      WHERE c.employee_id = p_employee_id
        AND c.requirement_type_id = v_rule.requirement_type_id
        AND c.revoked_at IS NULL
        AND c.valid_from <= p_as_of
        AND (
          c.valid_until IS NULL
          OR (c.valid_until + v_rule.grace_period_days) >= p_as_of
        )
    ) INTO v_has_valid;

    IF NOT v_has_valid AND v_rule.is_blocking THEN
      -- CR-D9: només el codi de requisit, sense detall clínic.
      v_reasons := array_append(v_reasons, 'MISSING_OR_EXPIRED:' || v_rule.requirement_code);
    END IF;
  END LOOP;

  -- Context operacional puntual (Dispatcher futur / ES-D10)
  IF p_required_requirement_codes IS NOT NULL AND cardinality(p_required_requirement_codes) > 0 THEN
    FOR v_rule IN
      SELECT t.id AS requirement_type_id, t.code AS requirement_code
      FROM data.compliance_requirement_types t
      WHERE t.is_active
        AND (t.tenant_id IS NULL OR t.tenant_id = v_tenant_id)
        AND t.code = ANY (p_required_requirement_codes)
    LOOP
      SELECT EXISTS (
        SELECT 1
        FROM data.employee_certifications c
        WHERE c.employee_id = p_employee_id
          AND c.requirement_type_id = v_rule.requirement_type_id
          AND c.revoked_at IS NULL
          AND c.valid_from <= p_as_of
          AND (c.valid_until IS NULL OR c.valid_until >= p_as_of)
      ) INTO v_has_valid;

      IF NOT v_has_valid THEN
        v_reasons := array_append(v_reasons, 'MISSING_REQUIRED_CONTEXT:' || v_rule.requirement_code);
      END IF;
    END LOOP;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM data.compliance_requirement_rules r
    WHERE r.tenant_id = v_tenant_id
      AND r.is_active
      AND r.scope_type <> 'tenant'
  ) INTO v_has_uneval;

  v_config_status := CASE
    WHEN v_rule_count = 0 AND NOT v_has_uneval THEN 'unconfigured'
    WHEN v_has_uneval THEN 'partial'
    ELSE 'configured'
  END;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'as_of', p_as_of,
    'is_ready', (cardinality(v_reasons) = 0),
    'blocking_reasons', to_jsonb(v_reasons),
    'configuration_status', v_config_status
  );
END;
$$;

GRANT EXECUTE ON FUNCTION data.compute_employee_readiness(uuid, date, text[])
  TO authenticated, service_role;

-- RPC UI / consumers
CREATE OR REPLACE FUNCTION api.get_employee_readiness(
  p_employee_id uuid,
  p_as_of date DEFAULT CURRENT_DATE,
  p_required_requirement_codes text[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_site_id   uuid;
  v_user_id   uuid;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT e.site_id, e.user_id INTO v_site_id, v_user_id
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT (
    data.jwt_can_view_employee(v_tenant_id, v_site_id, v_user_id)
    OR data.jwt_has_permission(v_tenant_id, 'compliance.certifications.view')
    OR data.jwt_has_permission(v_tenant_id, 'compliance.requirements.manage')
    OR (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN data.compute_employee_readiness(
    p_employee_id,
    COALESCE(p_as_of, CURRENT_DATE),
    p_required_requirement_codes
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_employee_readiness(uuid, date, text[])
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
