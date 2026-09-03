-- =============================================================================
-- M-EHR-09 / EHR-8.1 — HR reporting KPIs (headcount per contracte efectiu)
-- Cap salari ni DNI. Site-scope via JWT. Cleanup legacy (M-EHR-10) diferit.
-- =============================================================================

-- Índex de suport per headcount as-of
CREATE INDEX IF NOT EXISTS idx_employment_contracts_effective_asof
  ON data.employment_contracts (tenant_id, starts_on, ends_on)
  WHERE is_primary
    AND lifecycle_status IN ('scheduled', 'active', 'ended');

-- ---------------------------------------------------------------------------
-- Helper: scope de sites per reporting (global vs site-scoped)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.hr_reporting_caller_scope(p_tenant_id uuid)
RETURNS TABLE (
  is_global boolean,
  allowed_site_ids uuid[]
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_sites jsonb;
  v_global_role text;
  v_is_global boolean;
  v_ids uuid[];
BEGIN
  v_global_role := data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role';
  v_sites := coalesce(data.jwt_user_tenants() -> p_tenant_id::text -> 'sites', '{}'::jsonb);

  v_is_global :=
    coalesce(data.jwt_user_permissions() -> p_tenant_id::text -> 'global_permissions', '[]'::jsonb)
      @> '["*"]'::jsonb
    OR coalesce(v_global_role, '') IN ('owner', 'manager')
    OR coalesce(data.jwt_has_employee_permission(p_tenant_id, 'employees.directory.view'), false)
    OR coalesce(data.jwt_has_employee_permission(p_tenant_id, 'employees.view'), false)
    OR coalesce(data.jwt_has_employee_permission(p_tenant_id, 'employees.manage'), false);

  SELECT coalesce(array_agg(k::uuid), ARRAY[]::uuid[])
  INTO v_ids
  FROM jsonb_object_keys(v_sites) AS k;

  RETURN QUERY SELECT v_is_global, v_ids;
END;
$$;

GRANT EXECUTE ON FUNCTION data.hr_reporting_caller_scope(uuid) TO authenticated;

COMMENT ON FUNCTION data.hr_reporting_caller_scope(uuid) IS
  'EHR-8: si is_global=false, només sites presents al JWT.';

-- ---------------------------------------------------------------------------
-- api.get_hr_reporting_summary
-- Definicions temporals (documentades al JSON `definitions`):
--   headcount_effective: empleats amb contracte primary covering as_of
--     (lifecycle active|scheduled|ended), mateixa regla que get_effective.
--   legacy_without_contract: status=active sense contracte efectiu (visibilitat gap).
--   hires: starts_on del contracte primary en [period_from, as_of] (no cancelled).
--   terminations: ends_on en període amb lifecycle ended, o baixa empleat.
--   incomplete_profiles: directory incompleta (sense email o sense job_position).
--   onboardings_blocked: null fins EHR-6.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_hr_reporting_summary(
  p_as_of         date DEFAULT CURRENT_DATE,
  p_period_days   int DEFAULT 30,
  p_site_id       uuid DEFAULT NULL,
  p_department_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_as_of date := coalesce(p_as_of, CURRENT_DATE);
  v_period int := least(greatest(coalesce(p_period_days, 30), 1), 366);
  v_period_from date;
  v_is_global boolean;
  v_allowed uuid[];
  v_filter_sites uuid[];
  v_out jsonb;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT s.is_global, s.allowed_site_ids
  INTO v_is_global, v_allowed
  FROM data.hr_reporting_caller_scope(v_tenant_id) s;

  IF NOT (
    v_is_global
    OR coalesce(cardinality(v_allowed), 0) > 0
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Site filter: JWT scope ∩ optional p_site_id
  IF v_is_global THEN
    IF p_site_id IS NOT NULL THEN
      v_filter_sites := ARRAY[p_site_id];
    ELSE
      v_filter_sites := NULL; -- all sites
    END IF;
  ELSE
    IF p_site_id IS NOT NULL THEN
      IF NOT (p_site_id = ANY (v_allowed)) THEN
        RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
      END IF;
      v_filter_sites := ARRAY[p_site_id];
    ELSE
      v_filter_sites := v_allowed;
    END IF;
  END IF;

  v_period_from := v_as_of - (v_period - 1);

  WITH
  emp AS (
    SELECT e.*
    FROM data.employees e
    WHERE e.tenant_id = v_tenant_id
      AND (v_filter_sites IS NULL OR e.site_id = ANY (v_filter_sites))
      AND (p_department_id IS NULL OR e.department_id = p_department_id)
  ),
  effective AS (
    SELECT DISTINCT ON (c.employee_id)
      c.employee_id,
      c.id AS contract_id,
      c.lifecycle_status,
      c.starts_on,
      c.ends_on,
      c.job_position_id AS contract_job_position_id,
      c.site_id AS contract_site_id,
      c.department_id AS contract_department_id
    FROM data.employment_contracts c
    JOIN emp e ON e.id = c.employee_id
    WHERE c.tenant_id = v_tenant_id
      AND c.is_primary
      AND c.lifecycle_status IN ('active', 'scheduled', 'ended')
      AND c.starts_on <= v_as_of
      AND (c.ends_on IS NULL OR c.ends_on >= v_as_of)
    ORDER BY
      c.employee_id,
      CASE c.lifecycle_status WHEN 'active' THEN 0 WHEN 'scheduled' THEN 1 ELSE 2 END,
      c.starts_on DESC
  ),
  headcount AS (
    SELECT
      (SELECT count(*)::int FROM effective) AS effective_count,
      (
        SELECT count(*)::int
        FROM emp e
        WHERE e.status = 'active'
          AND coalesce(e.lifecycle_state, 'active') IS DISTINCT FROM 'terminated'
          AND NOT EXISTS (SELECT 1 FROM effective x WHERE x.employee_id = e.id)
      ) AS legacy_without_contract
  ),
  hires AS (
    SELECT count(DISTINCT c.employee_id)::int AS n
    FROM data.employment_contracts c
    JOIN emp e ON e.id = c.employee_id
    WHERE c.tenant_id = v_tenant_id
      AND c.is_primary
      AND c.lifecycle_status <> 'cancelled'
      AND c.starts_on BETWEEN v_period_from AND v_as_of
  ),
  terminations AS (
    SELECT (
      (
        SELECT count(DISTINCT c.employee_id)::int
        FROM data.employment_contracts c
        JOIN emp e ON e.id = c.employee_id
        WHERE c.tenant_id = v_tenant_id
          AND c.is_primary
          AND c.lifecycle_status = 'ended'
          AND c.ends_on BETWEEN v_period_from AND v_as_of
      )
      +
      (
        SELECT count(*)::int
        FROM emp e
        WHERE (
          e.status = 'terminated'
          OR coalesce(e.lifecycle_state, '') = 'terminated'
        )
        AND e.ends_on BETWEEN v_period_from AND v_as_of
        AND NOT EXISTS (
          SELECT 1
          FROM data.employment_contracts c
          WHERE c.tenant_id = v_tenant_id
            AND c.employee_id = e.id
            AND c.is_primary
            AND c.lifecycle_status = 'ended'
            AND c.ends_on BETWEEN v_period_from AND v_as_of
        )
      )
    ) AS n
  ),
  by_site AS (
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'site_id', s.site_id,
          'name', s.name,
          'count', s.cnt
        )
        ORDER BY s.cnt DESC, s.name
      ),
      '[]'::jsonb
    ) AS j
    FROM (
      SELECT
        e.site_id,
        coalesce(si.name, '(sense site)') AS name,
        count(*)::int AS cnt
      FROM effective x
      JOIN emp e ON e.id = x.employee_id
      LEFT JOIN data.sites si ON si.id = e.site_id
      GROUP BY e.site_id, si.name
    ) s
  ),
  by_dept AS (
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'department_id', d.department_id,
          'name', d.name,
          'count', d.cnt
        )
        ORDER BY d.cnt DESC, d.name
      ),
      '[]'::jsonb
    ) AS j
    FROM (
      SELECT
        e.department_id,
        coalesce(dep.name, '(sense departament)') AS name,
        count(*)::int AS cnt
      FROM effective x
      JOIN emp e ON e.id = x.employee_id
      LEFT JOIN data.departments dep ON dep.id = e.department_id
      GROUP BY e.department_id, dep.name
    ) d
  ),
  by_pos AS (
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'job_position_id', p.job_position_id,
          'name', p.name,
          'count', p.cnt
        )
        ORDER BY p.cnt DESC, p.name
      ),
      '[]'::jsonb
    ) AS j
    FROM (
      SELECT
        coalesce(x.contract_job_position_id, e.job_position_id) AS job_position_id,
        coalesce(jp.name, '(sense posició)') AS name,
        count(*)::int AS cnt
      FROM effective x
      JOIN emp e ON e.id = x.employee_id
      LEFT JOIN data.job_positions jp
        ON jp.id = coalesce(x.contract_job_position_id, e.job_position_id)
      GROUP BY coalesce(x.contract_job_position_id, e.job_position_id), jp.name
    ) p
  ),
  contracts_status AS (
    SELECT coalesce(
      jsonb_object_agg(lifecycle_status, cnt),
      '{}'::jsonb
    ) AS j
    FROM (
      SELECT c.lifecycle_status, count(*)::int AS cnt
      FROM data.employment_contracts c
      JOIN emp e ON e.id = c.employee_id
      WHERE c.tenant_id = v_tenant_id
      GROUP BY c.lifecycle_status
    ) s
  ),
  expiring AS (
    SELECT count(*)::int AS n
    FROM data.employment_contracts c
    JOIN emp e ON e.id = c.employee_id
    WHERE c.tenant_id = v_tenant_id
      AND c.is_primary
      AND c.lifecycle_status IN ('active', 'scheduled')
      AND c.ends_on IS NOT NULL
      AND c.ends_on BETWEEN v_as_of AND (v_as_of + 90)
  ),
  incomplete AS (
    SELECT count(*)::int AS n
    FROM emp e
    WHERE e.status = 'active'
      AND coalesce(e.lifecycle_state, 'active') IS DISTINCT FROM 'terminated'
      AND (
        e.email IS NULL OR btrim(e.email) = ''
        OR e.job_position_id IS NULL
      )
  ),
  onboarding AS (
    SELECT count(*)::int AS n
    FROM emp e
    WHERE coalesce(e.lifecycle_state, '') = 'onboarding'
  )
  SELECT jsonb_build_object(
    'as_of', v_as_of,
    'period_days', v_period,
    'period_from', v_period_from,
    'site_id', p_site_id,
    'department_id', p_department_id,
    'site_scoped', NOT v_is_global,
    'definitions', jsonb_build_object(
      'headcount_effective',
        'Primary employment_contract covering as_of (active|scheduled|ended); same coverage rule as get_effective_employment_contract.',
      'legacy_without_contract',
        'employees.status=active without effective primary contract on as_of (migration gap).',
      'hires',
        'Distinct employees whose primary contract starts_on falls in [period_from, as_of] (lifecycle <> cancelled).',
      'terminations',
        'Primary contracts ended with ends_on in period, plus employee terminations without such contract row.',
      'incomplete_profiles',
        'Active employees missing directory email or job_position_id (directory fields only).',
      'onboardings_blocked',
        'Deferred until EHR-6 checklist; always null in this release.',
      'certifications',
        'Use CR-4 get_employee_readiness_projection_summary / list_tenant_certifications — not duplicated here.'
    ),
    'headcount', jsonb_build_object(
      'effective', (SELECT effective_count FROM headcount),
      'legacy_without_contract', (SELECT legacy_without_contract FROM headcount)
    ),
    'hires', (SELECT n FROM hires),
    'terminations', (SELECT n FROM terminations),
    'by_site', (SELECT j FROM by_site),
    'by_department', (SELECT j FROM by_dept),
    'by_job_position', (SELECT j FROM by_pos),
    'contracts_by_status', (SELECT j FROM contracts_status),
    'contracts_expiring_90d', (SELECT n FROM expiring),
    'incomplete_profiles', (SELECT n FROM incomplete),
    'onboarding_count', (SELECT n FROM onboarding),
    'onboardings_blocked', NULL
  )
  INTO v_out;

  RETURN v_out;
END;
$$;

COMMENT ON FUNCTION api.get_hr_reporting_summary(date, int, uuid, uuid) IS
  'EHR-8.1: KPIs HR (headcount per contracte efectiu). Sense salari/DNI. Site-scope JWT.';

REVOKE EXECUTE ON FUNCTION api.get_hr_reporting_summary(date, int, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_hr_reporting_summary(date, int, uuid, uuid) TO authenticated;
