-- =============================================================================
-- M-EA-04/05 — Regles readiness d'actius (MISSING_ASSET)
-- asset_requirement_rules + extensió compute_employee_readiness + triggers projecció
-- Multi-scope OR (com CR-2b): tenant / department / job_position / site
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. data.asset_requirement_rules
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.asset_requirement_rules (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  asset_type_id  uuid NOT NULL REFERENCES data.asset_types(id) ON DELETE CASCADE,
  scope_type     text NOT NULL
    CHECK (scope_type IN ('tenant', 'department', 'job_position', 'site')),
  scope_id       uuid,
  is_blocking    boolean NOT NULL DEFAULT true,
  is_active      boolean NOT NULL DEFAULT true,
  created_by     uuid NOT NULL REFERENCES data.profiles(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT asset_rules_scope_id_check CHECK (
    (scope_type = 'tenant' AND scope_id IS NULL) OR
    (scope_type <> 'tenant' AND scope_id IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_asset_requirement_rules_scope
  ON data.asset_requirement_rules (tenant_id, scope_type, scope_id)
  WHERE is_active;

CREATE INDEX IF NOT EXISTS idx_asset_requirement_rules_type
  ON data.asset_requirement_rules (asset_type_id)
  WHERE is_active;

DROP TRIGGER IF EXISTS trg_asset_requirement_rules_updated_at ON data.asset_requirement_rules;
CREATE TRIGGER trg_asset_requirement_rules_updated_at
  BEFORE UPDATE ON data.asset_requirement_rules
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

ALTER TABLE data.asset_requirement_rules ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS asset_requirement_rules_select ON data.asset_requirement_rules;
CREATE POLICY asset_requirement_rules_select ON data.asset_requirement_rules
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

GRANT SELECT ON data.asset_requirement_rules TO authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON data.asset_requirement_rules TO service_role;

CREATE OR REPLACE VIEW api.asset_requirement_rules
  WITH (security_invoker = true) AS
SELECT * FROM data.asset_requirement_rules;

GRANT SELECT ON api.asset_requirement_rules TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. RPCs list / upsert
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.list_asset_requirement_rules(
  p_include_inactive boolean DEFAULT false
)
RETURNS SETOF api.asset_requirement_rules
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = api, data
AS $$
  SELECT r.*
  FROM api.asset_requirement_rules r
  WHERE r.tenant_id = data.active_tenant_id()
    AND (p_include_inactive OR r.is_active = true)
  ORDER BY r.scope_type, r.created_at DESC;
$$;

CREATE OR REPLACE FUNCTION api.upsert_asset_requirement_rule(
  p_id            uuid DEFAULT NULL,
  p_asset_type_id uuid DEFAULT NULL,
  p_scope_type    text DEFAULT NULL,
  p_scope_id      uuid DEFAULT NULL,
  p_is_blocking   boolean DEFAULT true,
  p_is_active     boolean DEFAULT true
)
RETURNS api.asset_requirement_rules
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_user_id   uuid := auth.uid();
  v_type      data.asset_types;
  v_row       data.asset_requirement_rules;
BEGIN
  IF v_tenant_id IS NULL OR v_user_id IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  IF NOT (
    coalesce(data.jwt_has_permission(v_tenant_id, 'assets.manage'), false)
    OR coalesce(data.jwt_has_permission(v_tenant_id, 'compliance.requirements.manage'), false)
    OR (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_id IS NOT NULL THEN
    SELECT * INTO v_row FROM data.asset_requirement_rules
    WHERE id = p_id AND tenant_id = v_tenant_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'asset_requirement_rule_not_found' USING ERRCODE = 'no_data_found';
    END IF;

    UPDATE data.asset_requirement_rules
    SET
      asset_type_id = COALESCE(p_asset_type_id, asset_type_id),
      scope_type = COALESCE(p_scope_type, scope_type),
      scope_id = CASE
        WHEN p_scope_type IS NOT NULL AND p_scope_type = 'tenant' THEN NULL
        WHEN p_scope_id IS NOT NULL THEN p_scope_id
        ELSE scope_id
      END,
      is_blocking = COALESCE(p_is_blocking, is_blocking),
      is_active = COALESCE(p_is_active, is_active)
    WHERE id = p_id
    RETURNING * INTO v_row;
  ELSE
    IF p_asset_type_id IS NULL OR p_scope_type IS NULL THEN
      RAISE EXCEPTION 'asset_type_and_scope_required' USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT * INTO v_type FROM data.asset_types
    WHERE id = p_asset_type_id
      AND (tenant_id IS NULL OR tenant_id = v_tenant_id);
    IF NOT FOUND THEN
      RAISE EXCEPTION 'asset_type_not_found' USING ERRCODE = 'no_data_found';
    END IF;

    IF p_scope_type = 'tenant' AND p_scope_id IS NOT NULL THEN
      RAISE EXCEPTION 'tenant_scope_cannot_have_scope_id' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_scope_type <> 'tenant' AND p_scope_id IS NULL THEN
      RAISE EXCEPTION 'scope_id_required' USING ERRCODE = 'invalid_parameter_value';
    END IF;

    INSERT INTO data.asset_requirement_rules (
      tenant_id, asset_type_id, scope_type, scope_id,
      is_blocking, is_active, created_by
    ) VALUES (
      v_tenant_id, p_asset_type_id, p_scope_type, p_scope_id,
      COALESCE(p_is_blocking, true), COALESCE(p_is_active, true), v_user_id
    )
    RETURNING * INTO v_row;
  END IF;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_asset_requirement_rules(boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.upsert_asset_requirement_rule(
  uuid, uuid, text, uuid, boolean, boolean
) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Extensió compute_employee_readiness (actius + config status combinat)
-- ---------------------------------------------------------------------------
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
  v_has_asset       boolean;
  v_rule_count      int := 0;
  v_config_status   text;
  v_has_any_rules   boolean;
  v_has_uneval      boolean;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT e.id INTO v_employee_id
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND e.tenant_id = v_tenant_id;

  IF v_employee_id IS NULL THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id
      USING ERRCODE = 'no_data_found';
  END IF;

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

  -- Compliance rules (CR-2b)
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
      v_reasons := array_append(v_reasons, 'MISSING_OR_EXPIRED:' || v_rule.requirement_code);
    END IF;
  END LOOP;

  -- Asset rules (EA readiness)
  FOR v_rule IN
    SELECT
      r.id,
      r.asset_type_id,
      r.is_blocking,
      r.scope_type,
      t.code AS asset_code
    FROM data.asset_requirement_rules r
    JOIN data.asset_types t ON t.id = r.asset_type_id
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

    -- Assignació oberta del tipus + calibratge no caducat (si aplica)
    SELECT EXISTS (
      SELECT 1
      FROM data.employee_asset_assignments eaa
      JOIN data.assets a ON a.id = eaa.asset_id
      WHERE eaa.employee_id = p_employee_id
        AND eaa.returned_at IS NULL
        AND a.asset_type_id = v_rule.asset_type_id
        AND (a.calibration_due_on IS NULL OR a.calibration_due_on >= v_as_of)
    ) INTO v_has_asset;

    IF NOT v_has_asset AND v_rule.is_blocking THEN
      v_reasons := array_append(v_reasons, 'MISSING_ASSET:' || v_rule.asset_code);
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
  ) OR EXISTS (
    SELECT 1
    FROM data.asset_requirement_rules r
    WHERE r.tenant_id = v_tenant_id
      AND r.is_active
  ) INTO v_has_any_rules;

  SELECT EXISTS (
    SELECT 1
    FROM (
      SELECT scope_type, scope_id
      FROM data.compliance_requirement_rules
      WHERE tenant_id = v_tenant_id AND is_active
      UNION ALL
      SELECT scope_type, scope_id
      FROM data.asset_requirement_rules
      WHERE tenant_id = v_tenant_id AND is_active
    ) r
    WHERE (
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
  'CR-2b + EA: readiness multi-scope (compliance + actius MISSING_ASSET); àmbit via contract terms.';

GRANT EXECUTE ON FUNCTION data.compute_employee_readiness(uuid, date, text[])
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Triggers projecció: regles actius + assignacions + calibratge actiu
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_refresh_readiness_on_asset_requirement_rule
  ON data.asset_requirement_rules;
CREATE TRIGGER trg_refresh_readiness_on_asset_requirement_rule
  AFTER INSERT OR UPDATE OR DELETE ON data.asset_requirement_rules
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_refresh_readiness_on_requirement_rule();

CREATE OR REPLACE FUNCTION data.trg_refresh_readiness_on_asset_assignment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_employee_id uuid;
BEGIN
  v_employee_id := coalesce(NEW.employee_id, OLD.employee_id);
  IF v_employee_id IS NOT NULL THEN
    PERFORM data.refresh_employee_readiness_projection(v_employee_id);
  END IF;
  -- Si es reassigna a un altre empleat (no passa amb append-only tancament), refresca OLD
  IF TG_OP = 'UPDATE'
     AND OLD.employee_id IS DISTINCT FROM NEW.employee_id
     AND OLD.employee_id IS NOT NULL THEN
    PERFORM data.refresh_employee_readiness_projection(OLD.employee_id);
  END IF;
  RETURN coalesce(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_refresh_readiness_on_asset_assignment
  ON data.employee_asset_assignments;
CREATE TRIGGER trg_refresh_readiness_on_asset_assignment
  AFTER INSERT OR UPDATE OR DELETE ON data.employee_asset_assignments
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_refresh_readiness_on_asset_assignment();

CREATE OR REPLACE FUNCTION data.trg_refresh_readiness_on_asset_calibration()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_emp record;
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.calibration_due_on IS NOT DISTINCT FROM OLD.calibration_due_on
     AND NEW.asset_type_id IS NOT DISTINCT FROM OLD.asset_type_id THEN
    RETURN NEW;
  END IF;

  FOR v_emp IN
    SELECT DISTINCT eaa.employee_id
    FROM data.employee_asset_assignments eaa
    WHERE eaa.asset_id = coalesce(NEW.id, OLD.id)
      AND eaa.returned_at IS NULL
  LOOP
    PERFORM data.refresh_employee_readiness_projection(v_emp.employee_id);
  END LOOP;

  RETURN coalesce(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_refresh_readiness_on_asset_calibration ON data.assets;
CREATE TRIGGER trg_refresh_readiness_on_asset_calibration
  AFTER UPDATE OF calibration_due_on, asset_type_id ON data.assets
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_refresh_readiness_on_asset_calibration();

NOTIFY pgrst, 'reload schema';
