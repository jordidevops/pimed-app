-- =============================================================================
-- M-CR-07 / CR-2c — Projecció escalable de readiness
-- Taula employee_readiness_projection + refresh real + BLOCKED/UNBLOCKED + triggers
-- Dispatch / assert_* segueixen calculant en viu (mai llegeixen la projecció).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Projection table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.employee_readiness_projection (
  employee_id          uuid PRIMARY KEY REFERENCES data.employees(id) ON DELETE CASCADE,
  tenant_id            uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  is_ready             boolean NOT NULL,
  blocking_reasons     jsonb NOT NULL DEFAULT '[]'::jsonb,
  configuration_status text NOT NULL
                         CHECK (configuration_status IN ('unconfigured', 'partial', 'configured')),
  payload              jsonb NOT NULL DEFAULT '{}'::jsonb,
  computed_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_employee_readiness_projection_tenant
  ON data.employee_readiness_projection (tenant_id, is_ready);

CREATE INDEX IF NOT EXISTS idx_employee_readiness_projection_computed
  ON data.employee_readiness_projection (tenant_id, computed_at DESC);

ALTER TABLE data.employee_readiness_projection ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS employee_readiness_projection_select ON data.employee_readiness_projection;
CREATE POLICY employee_readiness_projection_select ON data.employee_readiness_projection
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      coalesce(data.jwt_has_permission(tenant_id, 'compliance.certifications.view'), false)
      OR coalesce(data.jwt_has_permission(tenant_id, 'compliance.requirements.manage'), false)
      OR coalesce(data.jwt_has_permission(tenant_id, 'employees.directory.view'), false)
      OR coalesce(data.jwt_has_permission(tenant_id, 'employees.manage'), false)
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  );

GRANT SELECT ON data.employee_readiness_projection TO authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON data.employee_readiness_projection TO service_role;

CREATE OR REPLACE VIEW api.employee_readiness_projection
  WITH (security_invoker = true) AS
SELECT * FROM data.employee_readiness_projection;

GRANT SELECT ON api.employee_readiness_projection TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. refresh (real) — works with JWT tenant or service/cron (sets x-tenant-id)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.refresh_employee_readiness_projection(
  p_employee_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_emp_tenant uuid;
  v_site_id uuid;
  v_result jsonb;
  v_was_ready boolean;
  v_is_ready boolean;
  v_headers jsonb;
BEGIN
  IF p_employee_id IS NULL THEN
    RETURN;
  END IF;

  SELECT e.tenant_id, e.site_id
  INTO v_emp_tenant, v_site_id
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF v_emp_tenant IS NULL THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id
      USING ERRCODE = 'no_data_found';
  END IF;

  -- Interactive caller: tenant must match
  IF v_tenant_id IS NOT NULL AND v_emp_tenant IS DISTINCT FROM v_tenant_id THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id
      USING ERRCODE = 'no_data_found';
  END IF;

  -- Cron / service_role sense x-tenant-id: injecta el tenant de l'empleat
  IF v_tenant_id IS NULL THEN
    BEGIN
      v_headers := coalesce(current_setting('request.headers', true)::jsonb, '{}'::jsonb);
    EXCEPTION WHEN OTHERS THEN
      v_headers := '{}'::jsonb;
    END;
    v_headers := v_headers || jsonb_build_object('x-tenant-id', v_emp_tenant::text);
    PERFORM set_config('request.headers', v_headers::text, true);
    v_tenant_id := v_emp_tenant;
  END IF;

  SELECT is_ready INTO v_was_ready
  FROM data.employee_readiness_projection
  WHERE employee_id = p_employee_id;

  v_result := data.compute_employee_readiness(p_employee_id, CURRENT_DATE);
  v_is_ready := coalesce((v_result->>'is_ready')::boolean, false);

  INSERT INTO data.employee_readiness_projection AS erp (
    employee_id, tenant_id, is_ready, blocking_reasons,
    configuration_status, payload, computed_at
  ) VALUES (
    p_employee_id,
    v_emp_tenant,
    v_is_ready,
    coalesce(v_result->'blocking_reasons', '[]'::jsonb),
    coalesce(v_result->>'configuration_status', 'unconfigured'),
    v_result,
    now()
  )
  ON CONFLICT (employee_id) DO UPDATE SET
    tenant_id = EXCLUDED.tenant_id,
    is_ready = EXCLUDED.is_ready,
    blocking_reasons = EXCLUDED.blocking_reasons,
    configuration_status = EXCLUDED.configuration_status,
    payload = EXCLUDED.payload,
    computed_at = now();

  -- Only real transitions true↔false (skip first materialization)
  IF v_was_ready IS NOT NULL AND v_was_ready IS DISTINCT FROM v_is_ready THEN
    PERFORM data.log_audit_event(
      v_emp_tenant,
      auth.uid(),
      v_site_id,
      CASE WHEN v_is_ready THEN 'EMPLOYEE_UNBLOCKED' ELSE 'EMPLOYEE_BLOCKED_DUE_TO_COMPLIANCE' END,
      'employee',
      p_employee_id,
      v_result,
      true
    );
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION data.refresh_employee_readiness_projection(uuid)
  TO service_role, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Tenant / stale batch refresh
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.refresh_tenant_readiness_projection(
  p_tenant_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_emp record;
  v_count int := 0;
  v_headers jsonb;
BEGIN
  IF p_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  BEGIN
    v_headers := coalesce(current_setting('request.headers', true)::jsonb, '{}'::jsonb);
  EXCEPTION WHEN OTHERS THEN
    v_headers := '{}'::jsonb;
  END;
  v_headers := v_headers || jsonb_build_object('x-tenant-id', p_tenant_id::text);
  PERFORM set_config('request.headers', v_headers::text, true);

  FOR v_emp IN
    SELECT id
    FROM data.employees
    WHERE tenant_id = p_tenant_id
      AND coalesce(lifecycle_state, 'active') IS DISTINCT FROM 'terminated'
  LOOP
    PERFORM data.refresh_employee_readiness_projection(v_emp.id);
    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('tenant_id', p_tenant_id, 'refreshed', v_count);
END;
$$;

CREATE OR REPLACE FUNCTION data.refresh_stale_employee_readiness_projections(
  p_as_of date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_emp record;
  v_count int := 0;
  v_as_of date := coalesce(p_as_of, CURRENT_DATE);
BEGIN
  FOR v_emp IN
    SELECT e.id, e.tenant_id
    FROM data.employees e
    LEFT JOIN data.employee_readiness_projection p ON p.employee_id = e.id
    WHERE coalesce(e.lifecycle_state, 'active') IS DISTINCT FROM 'terminated'
      AND (p.employee_id IS NULL OR p.computed_at::date < v_as_of)
  LOOP
    PERFORM data.refresh_employee_readiness_projection(v_emp.id);
    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('as_of', v_as_of, 'refreshed', v_count);
END;
$$;

GRANT EXECUTE ON FUNCTION data.refresh_tenant_readiness_projection(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION data.refresh_stale_employee_readiness_projections(date) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Triggers: certifications + requirement rules
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_refresh_readiness_on_certification()
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
  RETURN coalesce(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_refresh_readiness_on_certification ON data.employee_certifications;
CREATE TRIGGER trg_refresh_readiness_on_certification
  AFTER INSERT OR UPDATE OR DELETE ON data.employee_certifications
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_refresh_readiness_on_certification();

CREATE OR REPLACE FUNCTION data.trg_refresh_readiness_on_requirement_rule()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id uuid;
BEGIN
  v_tenant_id := coalesce(NEW.tenant_id, OLD.tenant_id);
  IF v_tenant_id IS NOT NULL THEN
    PERFORM data.refresh_tenant_readiness_projection(v_tenant_id);
  END IF;
  RETURN coalesce(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_refresh_readiness_on_requirement_rule ON data.compliance_requirement_rules;
CREATE TRIGGER trg_refresh_readiness_on_requirement_rule
  AFTER INSERT OR UPDATE OR DELETE ON data.compliance_requirement_rules
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_refresh_readiness_on_requirement_rule();

-- ---------------------------------------------------------------------------
-- 5. API wrappers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.run_refresh_employee_readiness_projection(
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF auth.uid() IS NOT NULL THEN
    IF v_tenant_id IS NULL THEN
      RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF NOT (
      coalesce(data.jwt_has_permission(v_tenant_id, 'compliance.requirements.manage'), false)
      OR (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  PERFORM data.refresh_employee_readiness_projection(p_employee_id);

  RETURN (
    SELECT row_to_json(p)::jsonb
    FROM api.employee_readiness_projection p
    WHERE p.employee_id = p_employee_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.run_refresh_stale_readiness_projections(
  p_as_of date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF auth.uid() IS NOT NULL THEN
    IF v_tenant_id IS NULL THEN
      RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF NOT (
      coalesce(data.jwt_has_permission(v_tenant_id, 'compliance.requirements.manage'), false)
      OR (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  RETURN data.refresh_stale_employee_readiness_projections(coalesce(p_as_of, CURRENT_DATE));
END;
$$;

CREATE OR REPLACE FUNCTION api.get_employee_readiness_projection_summary(
  p_as_of date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_total int;
  v_ready int;
  v_not_ready int;
  v_unconfigured int;
  v_partial int;
  v_missing int;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  IF NOT (
    coalesce(data.jwt_has_permission(v_tenant_id, 'compliance.certifications.view'), false)
    OR coalesce(data.jwt_has_permission(v_tenant_id, 'compliance.requirements.manage'), false)
    OR coalesce(data.jwt_has_permission(v_tenant_id, 'employees.directory.view'), false)
    OR (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT count(*) INTO v_total
  FROM data.employees e
  WHERE e.tenant_id = v_tenant_id
    AND coalesce(e.lifecycle_state, 'active') IS DISTINCT FROM 'terminated';

  SELECT
    count(*) FILTER (WHERE p.is_ready),
    count(*) FILTER (WHERE NOT p.is_ready),
    count(*) FILTER (WHERE p.configuration_status = 'unconfigured'),
    count(*) FILTER (WHERE p.configuration_status = 'partial')
  INTO v_ready, v_not_ready, v_unconfigured, v_partial
  FROM data.employee_readiness_projection p
  JOIN data.employees e ON e.id = p.employee_id
  WHERE p.tenant_id = v_tenant_id
    AND coalesce(e.lifecycle_state, 'active') IS DISTINCT FROM 'terminated';

  v_missing := greatest(v_total - coalesce(v_ready, 0) - coalesce(v_not_ready, 0), 0);

  RETURN jsonb_build_object(
    'as_of', coalesce(p_as_of, CURRENT_DATE),
    'total_employees', v_total,
    'ready', coalesce(v_ready, 0),
    'not_ready', coalesce(v_not_ready, 0),
    'unconfigured', coalesce(v_unconfigured, 0),
    'partial', coalesce(v_partial, 0),
    'missing_projection', v_missing,
    'ready_pct', CASE
      WHEN v_total = 0 THEN NULL
      ELSE round(100.0 * coalesce(v_ready, 0) / v_total, 1)
    END
  );
END;
$$;

REVOKE ALL ON FUNCTION api.run_refresh_employee_readiness_projection(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.run_refresh_stale_readiness_projections(date) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_employee_readiness_projection_summary(date) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.run_refresh_employee_readiness_projection(uuid)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.run_refresh_stale_readiness_projections(date)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.get_employee_readiness_projection_summary(date)
  TO authenticated, service_role;

COMMENT ON TABLE data.employee_readiness_projection IS
  'CR-2c: projecció per dashboards/llistes. No és font de veritat per dispatch.';
COMMENT ON FUNCTION data.refresh_employee_readiness_projection(uuid) IS
  'CR-2c: recalcula projecció i emet BLOCKED/UNBLOCKED només en transicions true↔false.';

-- ---------------------------------------------------------------------------
-- 6. Cron diari (stale / missing projections)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('employee-readiness-projection-refresh');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;

    PERFORM cron.schedule(
      'employee-readiness-projection-refresh',
      '30 4 * * *',
      $cron$SELECT api.run_refresh_stale_readiness_projections(CURRENT_DATE)$cron$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'CR-2c: no s''ha pogut programar cron employee-readiness-projection-refresh: %', SQLERRM;
END;
$$;

NOTIFY pgrst, 'reload schema';
