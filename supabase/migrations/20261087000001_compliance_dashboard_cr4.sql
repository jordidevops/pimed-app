-- =============================================================================
-- M-CR-08 / CR-4 — Dashboard i llistes globals (certificacions + readiness)
-- Llegeix projecció (O(1) agregats) i vista certificacions amb filtres.
-- Mai itera compute_employee_readiness per empleat.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Llista global de certificacions (filtres status / site / dept)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.list_tenant_certifications(
  p_computed_status  text DEFAULT NULL,
  p_site_id          uuid DEFAULT NULL,
  p_department_id    uuid DEFAULT NULL,
  p_include_revoked  boolean DEFAULT false,
  p_limit            int DEFAULT 200,
  p_offset           int DEFAULT 0
)
RETURNS TABLE (
  id                     uuid,
  tenant_id              uuid,
  employee_id            uuid,
  employee_name          text,
  site_id                uuid,
  department_id          uuid,
  requirement_type_id    uuid,
  requirement_code       text,
  requirement_name       text,
  requirement_category   text,
  issuer                 text,
  credential_number      text,
  issued_on              date,
  valid_from             date,
  valid_until            date,
  document_id            uuid,
  revoked_at             timestamptz,
  computed_status        text,
  created_at             timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_limit int := least(greatest(coalesce(p_limit, 200), 1), 500);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  IF p_computed_status IS NOT NULL
     AND p_computed_status NOT IN (
       'active', 'expiring_soon', 'expired', 'indefinite', 'not_yet_valid'
     ) THEN
    RAISE EXCEPTION 'invalid_computed_status' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  RETURN QUERY
  SELECT
    c.id,
    c.tenant_id,
    c.employee_id,
    e.full_name AS employee_name,
    e.site_id,
    e.department_id,
    c.requirement_type_id,
    c.requirement_code,
    c.requirement_name,
    c.requirement_category::text,
    c.issuer,
    c.credential_number,
    c.issued_on,
    c.valid_from,
    c.valid_until,
    c.document_id,
    c.revoked_at,
    c.computed_status,
    c.created_at
  FROM api.employee_certifications c
  JOIN data.employees e ON e.id = c.employee_id AND e.tenant_id = c.tenant_id
  WHERE c.tenant_id = v_tenant_id
    AND (p_include_revoked OR c.revoked_at IS NULL)
    AND (p_computed_status IS NULL OR c.computed_status = p_computed_status)
    AND (p_site_id IS NULL OR e.site_id = p_site_id)
    AND (p_department_id IS NULL OR e.department_id = p_department_id)
    AND coalesce(e.lifecycle_state, 'active') IS DISTINCT FROM 'terminated'
  ORDER BY
    CASE c.computed_status
      WHEN 'expired' THEN 0
      WHEN 'expiring_soon' THEN 1
      WHEN 'not_yet_valid' THEN 2
      WHEN 'active' THEN 3
      ELSE 4
    END,
    c.valid_until NULLS LAST,
    e.full_name
  LIMIT v_limit
  OFFSET v_offset;
END;
$$;

COMMENT ON FUNCTION api.list_tenant_certifications(text, uuid, uuid, boolean, int, int) IS
  'CR-4: llista global de certificacions amb filtres computed_status/site/department. Respecta RLS mèdic.';

-- ---------------------------------------------------------------------------
-- 2. Llista projecció readiness (drill-down dashboard; consulta única)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.list_employee_readiness_projection(
  p_is_ready        boolean DEFAULT NULL,
  p_site_id         uuid DEFAULT NULL,
  p_department_id   uuid DEFAULT NULL,
  p_limit           int DEFAULT 100,
  p_offset          int DEFAULT 0
)
RETURNS TABLE (
  employee_id            uuid,
  employee_name          text,
  site_id                uuid,
  department_id          uuid,
  is_ready               boolean,
  blocking_reasons       jsonb,
  configuration_status   text,
  computed_at            timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_limit int := least(greatest(coalesce(p_limit, 100), 1), 500);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
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

  RETURN QUERY
  SELECT
    p.employee_id,
    e.full_name AS employee_name,
    e.site_id,
    e.department_id,
    p.is_ready,
    p.blocking_reasons,
    p.configuration_status,
    p.computed_at
  FROM data.employee_readiness_projection p
  JOIN data.employees e ON e.id = p.employee_id
  WHERE p.tenant_id = v_tenant_id
    AND coalesce(e.lifecycle_state, 'active') IS DISTINCT FROM 'terminated'
    AND (p_is_ready IS NULL OR p.is_ready = p_is_ready)
    AND (p_site_id IS NULL OR e.site_id = p_site_id)
    AND (p_department_id IS NULL OR e.department_id = p_department_id)
  ORDER BY p.is_ready ASC, e.full_name
  LIMIT v_limit
  OFFSET v_offset;
END;
$$;

COMMENT ON FUNCTION api.list_employee_readiness_projection(boolean, uuid, uuid, int, int) IS
  'CR-4: llista projecció readiness (mai compute en viu). Filtres is_ready/site/dept.';

-- ---------------------------------------------------------------------------
-- 3. Summary amb filtres opcionals site/dept (segueix O(1) agregat)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_employee_readiness_projection_summary(
  p_as_of           date DEFAULT CURRENT_DATE,
  p_site_id         uuid DEFAULT NULL,
  p_department_id   uuid DEFAULT NULL
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
    AND coalesce(e.lifecycle_state, 'active') IS DISTINCT FROM 'terminated'
    AND (p_site_id IS NULL OR e.site_id = p_site_id)
    AND (p_department_id IS NULL OR e.department_id = p_department_id);

  SELECT
    count(*) FILTER (WHERE p.is_ready),
    count(*) FILTER (WHERE NOT p.is_ready),
    count(*) FILTER (WHERE p.configuration_status = 'unconfigured'),
    count(*) FILTER (WHERE p.configuration_status = 'partial')
  INTO v_ready, v_not_ready, v_unconfigured, v_partial
  FROM data.employee_readiness_projection p
  JOIN data.employees e ON e.id = p.employee_id
  WHERE p.tenant_id = v_tenant_id
    AND coalesce(e.lifecycle_state, 'active') IS DISTINCT FROM 'terminated'
    AND (p_site_id IS NULL OR e.site_id = p_site_id)
    AND (p_department_id IS NULL OR e.department_id = p_department_id);

  v_missing := greatest(v_total - coalesce(v_ready, 0) - coalesce(v_not_ready, 0), 0);

  RETURN jsonb_build_object(
    'as_of', coalesce(p_as_of, CURRENT_DATE),
    'site_id', p_site_id,
    'department_id', p_department_id,
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

REVOKE ALL ON FUNCTION api.list_tenant_certifications(text, uuid, uuid, boolean, int, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.list_employee_readiness_projection(boolean, uuid, uuid, int, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_employee_readiness_projection_summary(date, uuid, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.list_tenant_certifications(text, uuid, uuid, boolean, int, int)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.list_employee_readiness_projection(boolean, uuid, uuid, int, int)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.get_employee_readiness_projection_summary(date, uuid, uuid)
  TO authenticated, service_role;

-- Substitueix l'overload 1-arg de CR-2c (DEFAULTS del 3-arg cobreixen p_as_of sol)
DROP FUNCTION IF EXISTS api.get_employee_readiness_projection_summary(date);

NOTIFY pgrst, 'reload schema';
