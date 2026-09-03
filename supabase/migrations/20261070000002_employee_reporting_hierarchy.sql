-- =============================================================================
-- M-EHR-04 — Reporting hierarchy (manager_employee_id) + org tree RPCs
-- =============================================================================

-- ─── Columns ─────────────────────────────────────────────────────────────────

ALTER TABLE data.employees
  ADD COLUMN IF NOT EXISTS manager_employee_id uuid REFERENCES data.employees(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_employees_manager_employee_id
  ON data.employees (manager_employee_id)
  WHERE manager_employee_id IS NOT NULL;

ALTER TABLE data.departments
  ADD COLUMN IF NOT EXISTS manager_employee_id uuid REFERENCES data.employees(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_departments_manager_employee_id
  ON data.departments (manager_employee_id)
  WHERE manager_employee_id IS NOT NULL;

-- FK for job_positions.default_manager_employee_id (deferred from M-EHR-03)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'job_positions_default_manager_employee_id_fkey'
  ) THEN
    ALTER TABLE data.job_positions
      ADD CONSTRAINT job_positions_default_manager_employee_id_fkey
      FOREIGN KEY (default_manager_employee_id) REFERENCES data.employees(id) ON DELETE SET NULL;
  END IF;
END $$;

COMMENT ON COLUMN data.employees.manager_employee_id IS
  'Manager directe (empleat). Opcional; sense cicles ni cross-tenant.';
COMMENT ON COLUMN data.departments.manager_employee_id IS
  'Manager del departament (empleat). Independent del manager individual.';

-- ─── Validation trigger: self / tenant / cycle ───────────────────────────────

CREATE OR REPLACE FUNCTION data.enforce_employee_manager_hierarchy()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_cursor uuid;
  v_depth int := 0;
BEGIN
  IF NEW.manager_employee_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.manager_employee_id = NEW.id THEN
    RAISE EXCEPTION 'manager_self_reference' USING ERRCODE = 'check_violation';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.employees m
    WHERE m.id = NEW.manager_employee_id AND m.tenant_id = NEW.tenant_id
  ) THEN
    RAISE EXCEPTION 'manager_tenant_mismatch' USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Walk up from proposed manager; must never reach NEW.id
  v_cursor := NEW.manager_employee_id;
  WHILE v_cursor IS NOT NULL AND v_depth < 64 LOOP
    IF v_cursor = NEW.id THEN
      RAISE EXCEPTION 'manager_cycle_detected' USING ERRCODE = 'check_violation';
    END IF;
    SELECT manager_employee_id INTO v_cursor
    FROM data.employees
    WHERE id = v_cursor;
    v_depth := v_depth + 1;
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_employees_manager_hierarchy ON data.employees;
CREATE TRIGGER trg_employees_manager_hierarchy
  BEFORE INSERT OR UPDATE OF manager_employee_id ON data.employees
  FOR EACH ROW
  EXECUTE FUNCTION data.enforce_employee_manager_hierarchy();

CREATE OR REPLACE FUNCTION data.enforce_department_manager_employee()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF NEW.manager_employee_id IS NULL THEN
    RETURN NEW;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM data.employees e
    WHERE e.id = NEW.manager_employee_id AND e.tenant_id = NEW.tenant_id
  ) THEN
    RAISE EXCEPTION 'department_manager_tenant_mismatch' USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_departments_manager_employee ON data.departments;
CREATE TRIGGER trg_departments_manager_employee
  BEFORE INSERT OR UPDATE OF manager_employee_id ON data.departments
  FOR EACH ROW
  EXECUTE FUNCTION data.enforce_department_manager_employee();

CREATE OR REPLACE FUNCTION data.enforce_job_position_default_manager()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF NEW.default_manager_employee_id IS NULL THEN
    RETURN NEW;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM data.employees e
    WHERE e.id = NEW.default_manager_employee_id AND e.tenant_id = NEW.tenant_id
  ) THEN
    RAISE EXCEPTION 'job_position_manager_tenant_mismatch' USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_job_position_default_manager ON data.job_positions;
CREATE TRIGGER trg_job_position_default_manager
  BEFORE INSERT OR UPDATE OF default_manager_employee_id ON data.job_positions
  FOR EACH ROW
  EXECUTE FUNCTION data.enforce_job_position_default_manager();

-- ─── Migrate departments.manager_id (profile) → manager_employee_id ──────────

UPDATE data.departments d
SET manager_employee_id = e.id
FROM data.employees e
WHERE d.manager_employee_id IS NULL
  AND d.manager_id IS NOT NULL
  AND e.tenant_id = d.tenant_id
  AND e.user_id = d.manager_id;

-- ─── Recreate API views (employees + departments) ────────────────────────────

DROP VIEW IF EXISTS api.employee_hr_profiles CASCADE;
DROP VIEW IF EXISTS api.employee_directory CASCADE;
DROP VIEW IF EXISTS api.employees CASCADE;

CREATE VIEW api.employees
  WITH (security_invoker = true) AS
SELECT
  e.id,
  e.tenant_id,
  e.site_id,
  e.user_id,
  e.department_id,
  e.job_position_id,
  e.manager_employee_id,
  e.full_name,
  e.legal_name,
  e.preferred_name,
  e.employee_code,
  e.photo_object_path,
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
  e.lifecycle_state,
  e.lifecycle_since,
  e.lifecycle_updated_at,
  e.created_at,
  e.updated_at
FROM data.employees e;

CREATE VIEW api.employee_directory
  WITH (security_invoker = true) AS
SELECT
  e.id,
  e.tenant_id,
  e.site_id,
  e.department_id,
  e.job_position_id,
  e.manager_employee_id,
  e.user_id,
  e.full_name,
  e.preferred_name,
  e.employee_code,
  e.photo_object_path,
  e.job_title,
  e.status,
  e.lifecycle_state,
  e.starts_on,
  e.ends_on,
  e.created_at,
  e.updated_at
FROM data.employees e;

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

DROP VIEW IF EXISTS api.departments CASCADE;
CREATE VIEW api.departments
  WITH (security_invoker = true) AS
SELECT
  id,
  tenant_id,
  parent_id,
  name,
  code,
  manager_id,
  manager_employee_id,
  is_active,
  attendance_geo_enabled,
  created_at,
  updated_at
FROM data.departments;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.departments TO authenticated;

-- ─── Org RPCs ────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.get_employee_direct_reports(p_employee_id uuid)
RETURNS TABLE (
  id uuid,
  full_name text,
  preferred_name text,
  job_title text,
  job_position_id uuid,
  department_id uuid,
  site_id uuid,
  status text,
  photo_object_path text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_mgr data.employees%ROWTYPE;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT * INTO v_mgr
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT data.jwt_can_view_employee(v_mgr.tenant_id, v_mgr.site_id, v_mgr.user_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  SELECT
    e.id,
    e.full_name,
    e.preferred_name,
    e.job_title,
    e.job_position_id,
    e.department_id,
    e.site_id,
    e.status,
    e.photo_object_path
  FROM data.employees e
  WHERE e.tenant_id = v_tenant_id
    AND e.manager_employee_id = p_employee_id
    AND data.jwt_can_view_employee(e.tenant_id, e.site_id, e.user_id)
  ORDER BY coalesce(e.preferred_name, e.full_name);
END;
$$;

REVOKE EXECUTE ON FUNCTION api.get_employee_direct_reports(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_employee_direct_reports(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION api.get_employee_org_tree(
  p_root_employee_id uuid DEFAULT NULL,
  p_max_depth int DEFAULT 8
)
RETURNS TABLE (
  id uuid,
  manager_employee_id uuid,
  full_name text,
  preferred_name text,
  job_title text,
  job_position_id uuid,
  department_id uuid,
  site_id uuid,
  status text,
  photo_object_path text,
  depth int,
  path uuid[]
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_max int := greatest(1, least(coalesce(p_max_depth, 8), 16));
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  RETURN QUERY
  WITH RECURSIVE tree AS (
    SELECT
      e.id,
      e.manager_employee_id,
      e.full_name,
      e.preferred_name,
      e.job_title,
      e.job_position_id,
      e.department_id,
      e.site_id,
      e.status,
      e.photo_object_path,
      0 AS depth,
      ARRAY[e.id] AS path
    FROM data.employees e
    WHERE e.tenant_id = v_tenant_id
      AND data.jwt_can_view_employee(e.tenant_id, e.site_id, e.user_id)
      AND (
        (p_root_employee_id IS NOT NULL AND e.id = p_root_employee_id)
        OR (p_root_employee_id IS NULL AND e.manager_employee_id IS NULL)
      )

    UNION ALL

    SELECT
      c.id,
      c.manager_employee_id,
      c.full_name,
      c.preferred_name,
      c.job_title,
      c.job_position_id,
      c.department_id,
      c.site_id,
      c.status,
      c.photo_object_path,
      t.depth + 1,
      t.path || c.id
    FROM data.employees c
    JOIN tree t ON c.manager_employee_id = t.id
    WHERE c.tenant_id = v_tenant_id
      AND t.depth + 1 < v_max
      AND NOT (c.id = ANY (t.path))
      AND data.jwt_can_view_employee(c.tenant_id, c.site_id, c.user_id)
  )
  SELECT
    tree.id,
    tree.manager_employee_id,
    tree.full_name,
    tree.preferred_name,
    tree.job_title,
    tree.job_position_id,
    tree.department_id,
    tree.site_id,
    tree.status,
    tree.photo_object_path,
    tree.depth,
    tree.path
  FROM tree
  ORDER BY tree.path;
END;
$$;

REVOKE EXECUTE ON FUNCTION api.get_employee_org_tree(uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_employee_org_tree(uuid, int) TO authenticated;

NOTIFY pgrst, 'reload schema';
