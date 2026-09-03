-- =============================================================================
-- M-CR-02 — Regles compliance_requirement_rules + RPCs
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.compliance_requirement_rules (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  requirement_type_id uuid NOT NULL REFERENCES data.compliance_requirement_types(id) ON DELETE CASCADE,
  scope_type          text NOT NULL
    CHECK (scope_type IN ('tenant', 'department', 'job_position', 'site')),
  scope_id            uuid,
  is_blocking         boolean NOT NULL DEFAULT true,
  grace_period_days   int NOT NULL DEFAULT 0 CHECK (grace_period_days >= 0),
  is_active           boolean NOT NULL DEFAULT true,
  created_by          uuid NOT NULL REFERENCES data.profiles(id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT compliance_rules_scope_id_check CHECK (
    (scope_type = 'tenant' AND scope_id IS NULL) OR
    (scope_type <> 'tenant' AND scope_id IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_compliance_rules_scope
  ON data.compliance_requirement_rules (tenant_id, scope_type, scope_id)
  WHERE is_active;

CREATE INDEX IF NOT EXISTS idx_compliance_rules_type
  ON data.compliance_requirement_rules (requirement_type_id)
  WHERE is_active;

DROP TRIGGER IF EXISTS trg_compliance_requirement_rules_updated_at ON data.compliance_requirement_rules;
CREATE TRIGGER trg_compliance_requirement_rules_updated_at
  BEFORE UPDATE ON data.compliance_requirement_rules
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

ALTER TABLE data.compliance_requirement_rules ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS compliance_requirement_rules_select ON data.compliance_requirement_rules;
CREATE POLICY compliance_requirement_rules_select ON data.compliance_requirement_rules
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

GRANT SELECT ON data.compliance_requirement_rules TO authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON data.compliance_requirement_rules TO service_role;

CREATE OR REPLACE VIEW api.compliance_requirement_rules
  WITH (security_invoker = true) AS
SELECT * FROM data.compliance_requirement_rules;

GRANT SELECT ON api.compliance_requirement_rules TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.list_compliance_requirement_rules(
  p_include_inactive boolean DEFAULT false
)
RETURNS SETOF api.compliance_requirement_rules
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = api, data
AS $$
  SELECT r.*
  FROM api.compliance_requirement_rules r
  WHERE r.tenant_id = data.active_tenant_id()
    AND (p_include_inactive OR r.is_active = true)
  ORDER BY r.scope_type, r.created_at DESC;
$$;

CREATE OR REPLACE FUNCTION api.upsert_compliance_requirement_rule(
  p_id                  uuid DEFAULT NULL,
  p_requirement_type_id uuid DEFAULT NULL,
  p_scope_type          text DEFAULT NULL,
  p_scope_id            uuid DEFAULT NULL,
  p_is_blocking         boolean DEFAULT true,
  p_grace_period_days   int DEFAULT 0,
  p_is_active           boolean DEFAULT true
)
RETURNS api.compliance_requirement_rules
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_user_id   uuid := auth.uid();
  v_type      data.compliance_requirement_types;
  v_row       data.compliance_requirement_rules;
BEGIN
  IF v_tenant_id IS NULL OR v_user_id IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  IF NOT (
    data.jwt_has_permission(v_tenant_id, 'compliance.requirements.manage')
    OR (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_id IS NOT NULL THEN
    SELECT * INTO v_row FROM data.compliance_requirement_rules
    WHERE id = p_id AND tenant_id = v_tenant_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'requirement_rule_not_found' USING ERRCODE = 'no_data_found';
    END IF;

    UPDATE data.compliance_requirement_rules
    SET
      requirement_type_id = COALESCE(p_requirement_type_id, requirement_type_id),
      scope_type = COALESCE(p_scope_type, scope_type),
      scope_id = CASE
        WHEN p_scope_type IS NOT NULL AND p_scope_type = 'tenant' THEN NULL
        WHEN p_scope_id IS NOT NULL THEN p_scope_id
        ELSE scope_id
      END,
      is_blocking = COALESCE(p_is_blocking, is_blocking),
      grace_period_days = COALESCE(p_grace_period_days, grace_period_days),
      is_active = COALESCE(p_is_active, is_active)
    WHERE id = p_id
    RETURNING * INTO v_row;
  ELSE
    IF p_requirement_type_id IS NULL OR p_scope_type IS NULL THEN
      RAISE EXCEPTION 'requirement_type_and_scope_required' USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT * INTO v_type FROM data.compliance_requirement_types
    WHERE id = p_requirement_type_id
      AND (tenant_id IS NULL OR tenant_id = v_tenant_id);
    IF NOT FOUND THEN
      RAISE EXCEPTION 'requirement_type_not_found' USING ERRCODE = 'no_data_found';
    END IF;

    IF p_scope_type = 'tenant' AND p_scope_id IS NOT NULL THEN
      RAISE EXCEPTION 'tenant_scope_cannot_have_scope_id' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_scope_type <> 'tenant' AND p_scope_id IS NULL THEN
      RAISE EXCEPTION 'scope_id_required' USING ERRCODE = 'invalid_parameter_value';
    END IF;

    INSERT INTO data.compliance_requirement_rules (
      tenant_id, requirement_type_id, scope_type, scope_id,
      is_blocking, grace_period_days, is_active, created_by
    ) VALUES (
      v_tenant_id, p_requirement_type_id, p_scope_type, p_scope_id,
      COALESCE(p_is_blocking, true), COALESCE(p_grace_period_days, 0),
      COALESCE(p_is_active, true), v_user_id
    )
    RETURNING * INTO v_row;
  END IF;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_compliance_requirement_rules(boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.upsert_compliance_requirement_rule(
  uuid, uuid, text, uuid, boolean, int, boolean
) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
