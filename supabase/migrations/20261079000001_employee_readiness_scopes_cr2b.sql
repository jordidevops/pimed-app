-- =============================================================================
-- M-CR-2b — Readiness multi-scope (department / job_position / site)
-- Resolve scope via resolve_employee_contract_terms; flat employees as fallback.
-- Multi-scope OR: all matching rules evaluated (no precedence).
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
  v_tenant_id       uuid := data.active_tenant_id();
  v_employee_id     uuid;
  v_as_of           date := coalesce(p_as_of, CURRENT_DATE);
  v_terms           jsonb;
  v_scope_dept      uuid;
  v_scope_position  uuid;
  v_scope_site      uuid;
  v_scope_source    text;
  v_rule            record;
  v_reasons         text[] := '{}';
  v_has_valid       boolean;
  v_rule_count      int := 0;
  v_config_status   text;
  v_has_any_rules   boolean;
  v_has_uneval      boolean;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Guarda de tenant (CR-D8)
  SELECT e.id INTO v_employee_id
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND e.tenant_id = v_tenant_id;

  IF v_employee_id IS NULL THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id
      USING ERRCODE = 'no_data_found';
  END IF;

  -- CR-D3bis: contract terms first, flat fallback inside resolve_*
  v_terms := data.resolve_employee_contract_terms(p_employee_id, v_as_of);
  IF v_terms IS NULL THEN
    v_terms := '{}'::jsonb;
  END IF;

  v_scope_dept := nullif(v_terms ->> 'department_id', '')::uuid;
  v_scope_position := nullif(v_terms ->> 'job_position_id', '')::uuid;
  v_scope_site := nullif(v_terms ->> 'site_id', '')::uuid;
  v_scope_source := CASE
    WHEN v_terms ->> 'source' = 'employment_contract' THEN 'employment_contract'
    ELSE 'employee_flat'
  END;

  -- Multi-scope OR (CR-D3): evaluate all matching active rules
  FOR v_rule IN
    SELECT
      r.id,
      r.requirement_type_id,
      r.is_blocking,
      r.grace_period_days,
      r.scope_type,
      t.code AS requirement_code,
      t.category
    FROM data.compliance_requirement_rules r
    JOIN data.compliance_requirement_types t ON t.id = r.requirement_type_id
    WHERE r.tenant_id = v_tenant_id
      AND r.is_active
      AND (
        r.scope_type = 'tenant'
        OR (r.scope_type = 'department' AND r.scope_id IS NOT DISTINCT FROM v_scope_dept)
        OR (r.scope_type = 'job_position' AND r.scope_id IS NOT DISTINCT FROM v_scope_position)
        OR (r.scope_type = 'site' AND r.scope_id IS NOT DISTINCT FROM v_scope_site)
      )
  LOOP
    v_rule_count := v_rule_count + 1;

    SELECT EXISTS (
      SELECT 1
      FROM data.employee_certifications c
      WHERE c.employee_id = p_employee_id
        AND c.requirement_type_id = v_rule.requirement_type_id
        AND c.revoked_at IS NULL
        AND c.valid_from <= v_as_of
        AND (
          c.valid_until IS NULL
          OR (c.valid_until + v_rule.grace_period_days) >= v_as_of
        )
    ) INTO v_has_valid;

    IF NOT v_has_valid AND v_rule.is_blocking THEN
      -- CR-D9: només el codi de requisit, sense detall clínic.
      v_reasons := array_append(v_reasons, 'MISSING_OR_EXPIRED:' || v_rule.requirement_code);
    END IF;
  END LOOP;

  -- Context operacional puntual (Dispatcher / ES-D10)
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
          AND c.valid_from <= v_as_of
          AND (c.valid_until IS NULL OR c.valid_until >= v_as_of)
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
  ) INTO v_has_any_rules;

  -- partial: hi ha regles scoped però l'empleat no té l'àmbit resolt (NULL)
  SELECT EXISTS (
    SELECT 1
    FROM data.compliance_requirement_rules r
    WHERE r.tenant_id = v_tenant_id
      AND r.is_active
      AND (
        (r.scope_type = 'job_position' AND v_scope_position IS NULL)
        OR (r.scope_type = 'department' AND v_scope_dept IS NULL)
        OR (r.scope_type = 'site' AND v_scope_site IS NULL)
      )
  ) INTO v_has_uneval;

  v_config_status := CASE
    WHEN NOT v_has_any_rules THEN 'unconfigured'
    WHEN v_has_uneval AND v_rule_count = 0 THEN 'partial'
    ELSE 'configured'
  END;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'as_of', v_as_of,
    'is_ready', (cardinality(v_reasons) = 0),
    'blocking_reasons', to_jsonb(v_reasons),
    'configuration_status', v_config_status,
    'scope_source', v_scope_source,
    'resolved_scope', jsonb_build_object(
      'department_id', v_scope_dept,
      'job_position_id', v_scope_position,
      'site_id', v_scope_site
    )
  );
END;
$$;

COMMENT ON FUNCTION data.compute_employee_readiness(uuid, date, text[]) IS
  'CR-2b: readiness multi-scope; àmbit via resolve_employee_contract_terms (fallback flat).';

GRANT EXECUTE ON FUNCTION data.compute_employee_readiness(uuid, date, text[])
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
