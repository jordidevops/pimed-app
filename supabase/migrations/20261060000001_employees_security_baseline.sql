-- =============================================================================
-- EHR-0 / M-EHR-00 — Employees security baseline
-- Restaura security_invoker, separa capes directori/HR/privat i alinea RLS
-- amb permisos employees.* (+ aliases hr.view / hr.manage).
-- =============================================================================

-- ─── Helpers de permisos amb aliases temporals ───────────────────────────────

CREATE OR REPLACE FUNCTION data.jwt_has_employee_permission(
  p_tenant_id  uuid,
  p_permission text,
  p_site_id    uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT
    data.jwt_has_permission(p_tenant_id, p_permission, p_site_id)
    OR (
      p_permission = 'employees.view'
      AND data.jwt_has_permission(p_tenant_id, 'hr.view', p_site_id)
    )
    OR (
      p_permission = 'employees.manage'
      AND data.jwt_has_permission(p_tenant_id, 'hr.manage', p_site_id)
    )
    OR (
      p_permission = 'employees.directory.view'
      AND (
        data.jwt_has_permission(p_tenant_id, 'employees.view', p_site_id)
        OR data.jwt_has_permission(p_tenant_id, 'hr.view', p_site_id)
      )
    )
    OR (
      p_permission = 'employees.private.view'
      AND (
        data.jwt_has_permission(p_tenant_id, 'employees.manage', p_site_id)
        OR data.jwt_has_permission(p_tenant_id, 'hr.manage', p_site_id)
      )
    )
    OR (
      p_permission = 'employees.private.manage'
      AND (
        data.jwt_has_permission(p_tenant_id, 'employees.manage', p_site_id)
        OR data.jwt_has_permission(p_tenant_id, 'hr.manage', p_site_id)
      )
    );
$$;

GRANT EXECUTE ON FUNCTION data.jwt_has_employee_permission(uuid, text, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION data.jwt_can_view_employee(
  p_tenant_id         uuid,
  p_site_id           uuid,
  p_employee_user_id  uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT CASE
    WHEN (data.jwt_user_permissions() -> p_tenant_id::text -> 'global_permissions') @> '["*"]'::jsonb
      THEN true
    WHEN (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      THEN true
    WHEN data.jwt_has_employee_permission(p_tenant_id, 'employees.view')
      THEN true
    WHEN data.jwt_has_employee_permission(p_tenant_id, 'employees.directory.view')
      THEN true
    WHEN p_employee_user_id IS NOT NULL AND p_employee_user_id = auth.uid()
      THEN true
    WHEN p_site_id IS NOT NULL
      AND (data.jwt_user_tenants() -> p_tenant_id::text -> 'sites') ? p_site_id::text
      AND (
        data.jwt_has_employee_permission(p_tenant_id, 'employees.view', p_site_id)
        OR data.jwt_has_employee_permission(p_tenant_id, 'employees.directory.view', p_site_id)
        OR (data.jwt_user_tenants() -> p_tenant_id::text -> 'sites' -> p_site_id::text ->> 'role')
           IN ('owner', 'manager')
      )
      THEN true
    WHEN p_site_id IS NULL
      AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('member', 'viewer')
      THEN true
    WHEN (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('member', 'viewer')
      THEN true
    ELSE false
  END;
$$;

GRANT EXECUTE ON FUNCTION data.jwt_can_view_employee(uuid, uuid, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION data.jwt_can_view_employee_private(
  p_tenant_id         uuid,
  p_site_id           uuid,
  p_employee_user_id  uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT CASE
    WHEN (data.jwt_user_permissions() -> p_tenant_id::text -> 'global_permissions') @> '["*"]'::jsonb
      THEN true
    WHEN (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      THEN true
    WHEN data.jwt_has_employee_permission(p_tenant_id, 'employees.private.view')
      THEN true
    WHEN data.jwt_has_employee_permission(p_tenant_id, 'employees.manage')
      THEN true
    WHEN p_employee_user_id IS NOT NULL AND p_employee_user_id = auth.uid()
      THEN true
    WHEN p_site_id IS NOT NULL
      AND data.jwt_has_employee_permission(p_tenant_id, 'employees.private.view', p_site_id)
      THEN true
    WHEN p_site_id IS NOT NULL
      AND data.jwt_has_employee_permission(p_tenant_id, 'employees.manage', p_site_id)
      THEN true
    ELSE false
  END;
$$;

GRANT EXECUTE ON FUNCTION data.jwt_can_view_employee_private(uuid, uuid, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION data.jwt_can_manage_employee(
  p_tenant_id uuid,
  p_site_id   uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT CASE
    WHEN (data.jwt_user_permissions() -> p_tenant_id::text -> 'global_permissions') @> '["*"]'::jsonb
      THEN true
    WHEN (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      THEN true
    WHEN data.jwt_has_employee_permission(p_tenant_id, 'employees.manage')
      THEN true
    WHEN p_site_id IS NOT NULL
      AND data.jwt_has_employee_permission(p_tenant_id, 'employees.manage', p_site_id)
      THEN true
    ELSE false
  END;
$$;

GRANT EXECUTE ON FUNCTION data.jwt_can_manage_employee(uuid, uuid) TO authenticated;

-- ─── RLS actualitzada ────────────────────────────────────────────────────────

DROP POLICY IF EXISTS "employees: membres del tenant poden veure empleats" ON data.employees;
DROP POLICY IF EXISTS "employees: owner/manager pot crear empleats" ON data.employees;
DROP POLICY IF EXISTS "employees: owner/manager pot modificar empleats" ON data.employees;
DROP POLICY IF EXISTS "employees: owner/manager pot eliminar empleats" ON data.employees;

CREATE POLICY "employees: lectura segons permís o rol"
  ON data.employees FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_can_view_employee(tenant_id, site_id, user_id)
  );

CREATE POLICY "employees: escriptura segons permís manage"
  ON data.employees FOR INSERT
  TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_can_manage_employee(tenant_id, site_id)
  );

CREATE POLICY "employees: actualització segons permís manage"
  ON data.employees FOR UPDATE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_can_manage_employee(tenant_id, site_id)
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_can_manage_employee(tenant_id, site_id)
  );

CREATE POLICY "employees: eliminació segons permís manage"
  ON data.employees FOR DELETE
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_can_manage_employee(tenant_id, site_id)
  );

-- ─── Vistes API amb security_invoker ─────────────────────────────────────────

DROP VIEW IF EXISTS api.employee_hr_profiles CASCADE;
DROP VIEW IF EXISTS api.employee_directory CASCADE;
DROP VIEW IF EXISTS api.employees CASCADE;

-- Capa 1: directori intern (sense contacte ni dades sensibles)
CREATE VIEW api.employee_directory
  WITH (security_invoker = true) AS
SELECT
  e.id,
  e.tenant_id,
  e.site_id,
  e.department_id,
  e.user_id,
  e.full_name,
  e.job_title,
  e.status,
  e.starts_on,
  e.ends_on,
  e.created_at,
  e.updated_at
FROM data.employees e;

-- Capa 2: HR operatiu (sense document_id ni metadata)
CREATE VIEW api.employees
  WITH (security_invoker = true) AS
SELECT
  e.id,
  e.tenant_id,
  e.site_id,
  e.user_id,
  e.department_id,
  e.full_name,
  e.email,
  e.phone,
  e.job_title,
  e.status,
  e.starts_on,
  e.ends_on,
  e.weekly_hours,
  e.calendar_group_id,
  e.location_consent_given,
  e.location_consent_at,
  e.location_consent_version,
  e.attendance_geo_enabled,
  e.attendance_work_profile,
  e.punch_only_at_stations,
  e.created_at,
  e.updated_at
FROM data.employees e;

-- Capa 3: perfil HR sensible (pont fins EHR-3 employee_private_profiles)
CREATE VIEW api.employee_hr_profiles
  WITH (security_invoker = true, security_barrier = true) AS
SELECT
  e.id,
  e.tenant_id,
  e.document_id,
  e.metadata,
  e.created_at,
  e.updated_at
FROM data.employees e
WHERE data.jwt_can_view_employee_private(e.tenant_id, e.site_id, e.user_id);

GRANT SELECT ON api.employee_directory TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.employees TO authenticated;
GRANT SELECT, UPDATE ON api.employee_hr_profiles TO authenticated;

NOTIFY pgrst, 'reload schema';
