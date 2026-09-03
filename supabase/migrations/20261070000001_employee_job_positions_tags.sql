-- =============================================================================
-- M-EHR-03 — Job positions, employee tags & assignments
-- =============================================================================

-- ─── job_positions ───────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS data.job_positions (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                   uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  code                        text,
  name                        text NOT NULL,
  description                 text,
  department_id               uuid REFERENCES data.departments(id) ON DELETE SET NULL,
  default_manager_employee_id uuid, -- FK added after employees.manager exists (M-EHR-04)
  default_site_id             uuid REFERENCES data.sites(id) ON DELETE SET NULL,
  default_calendar_group_id   uuid,
  is_active                   boolean NOT NULL DEFAULT true,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT job_positions_name_not_blank CHECK (btrim(name) <> '')
);

CREATE INDEX IF NOT EXISTS idx_job_positions_tenant
  ON data.job_positions (tenant_id);

CREATE UNIQUE INDEX IF NOT EXISTS uq_job_positions_tenant_code
  ON data.job_positions (tenant_id, code)
  WHERE code IS NOT NULL AND btrim(code) <> '';

CREATE UNIQUE INDEX IF NOT EXISTS uq_job_positions_tenant_name
  ON data.job_positions (tenant_id, lower(btrim(name)));

COMMENT ON TABLE data.job_positions IS
  'Catàleg de posicions estructurades per tenant. job_title a employees és text lliure complementari.';

-- ─── employee_tags ───────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS data.employee_tags (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  name        text NOT NULL,
  color_token text,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employee_tags_name_not_blank CHECK (btrim(name) <> '')
);

CREATE INDEX IF NOT EXISTS idx_employee_tags_tenant
  ON data.employee_tags (tenant_id);

CREATE UNIQUE INDEX IF NOT EXISTS uq_employee_tags_tenant_name
  ON data.employee_tags (tenant_id, lower(btrim(name)));

COMMENT ON TABLE data.employee_tags IS
  'Etiquetes lliures de classificació per tenant (N:M via employee_tag_assignments).';

-- ─── employee_tag_assignments ────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS data.employee_tag_assignments (
  tenant_id   uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  tag_id      uuid NOT NULL REFERENCES data.employee_tags(id) ON DELETE CASCADE,
  assigned_by uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  assigned_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (employee_id, tag_id)
);

CREATE INDEX IF NOT EXISTS idx_employee_tag_assignments_tenant_tag
  ON data.employee_tag_assignments (tenant_id, tag_id);

CREATE INDEX IF NOT EXISTS idx_employee_tag_assignments_tag
  ON data.employee_tag_assignments (tag_id);

COMMENT ON TABLE data.employee_tag_assignments IS
  'Assignació N:M empleat ↔ etiqueta. tenant_id denormalitzat per RLS.';

-- ─── employees.job_position_id ───────────────────────────────────────────────

ALTER TABLE data.employees
  ADD COLUMN IF NOT EXISTS job_position_id uuid REFERENCES data.job_positions(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_employees_job_position_id
  ON data.employees (job_position_id)
  WHERE job_position_id IS NOT NULL;

-- Tenant consistency: position belongs to same tenant
CREATE OR REPLACE FUNCTION data.enforce_employee_job_position_tenant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF NEW.job_position_id IS NULL THEN
    RETURN NEW;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM data.job_positions jp
    WHERE jp.id = NEW.job_position_id AND jp.tenant_id = NEW.tenant_id
  ) THEN
    RAISE EXCEPTION 'job_position_tenant_mismatch' USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_employees_job_position_tenant ON data.employees;
CREATE TRIGGER trg_employees_job_position_tenant
  BEFORE INSERT OR UPDATE OF job_position_id ON data.employees
  FOR EACH ROW
  EXECUTE FUNCTION data.enforce_employee_job_position_tenant();

-- Tag assignment tenant consistency
CREATE OR REPLACE FUNCTION data.enforce_tag_assignment_tenant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_emp_tenant uuid;
  v_tag_tenant uuid;
BEGIN
  SELECT tenant_id INTO v_emp_tenant FROM data.employees WHERE id = NEW.employee_id;
  SELECT tenant_id INTO v_tag_tenant FROM data.employee_tags WHERE id = NEW.tag_id;
  IF v_emp_tenant IS NULL OR v_tag_tenant IS NULL OR v_emp_tenant <> v_tag_tenant THEN
    RAISE EXCEPTION 'tag_assignment_tenant_mismatch' USING ERRCODE = 'foreign_key_violation';
  END IF;
  NEW.tenant_id := v_emp_tenant;
  IF NEW.assigned_by IS NULL THEN
    NEW.assigned_by := auth.uid();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tag_assignment_tenant ON data.employee_tag_assignments;
CREATE TRIGGER trg_tag_assignment_tenant
  BEFORE INSERT OR UPDATE ON data.employee_tag_assignments
  FOR EACH ROW
  EXECUTE FUNCTION data.enforce_tag_assignment_tenant();

-- Job position department tenant
CREATE OR REPLACE FUNCTION data.enforce_job_position_refs_tenant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF NEW.department_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM data.departments d
    WHERE d.id = NEW.department_id AND d.tenant_id = NEW.tenant_id
  ) THEN
    RAISE EXCEPTION 'job_position_department_tenant_mismatch' USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF NEW.default_site_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM data.sites s
    WHERE s.id = NEW.default_site_id AND s.tenant_id = NEW.tenant_id
  ) THEN
    RAISE EXCEPTION 'job_position_site_tenant_mismatch' USING ERRCODE = 'foreign_key_violation';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_job_position_refs_tenant ON data.job_positions;
CREATE TRIGGER trg_job_position_refs_tenant
  BEFORE INSERT OR UPDATE ON data.job_positions
  FOR EACH ROW
  EXECUTE FUNCTION data.enforce_job_position_refs_tenant();

CREATE OR REPLACE FUNCTION data.touch_employee_tags_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_employee_tags_touch ON data.employee_tags;
CREATE TRIGGER trg_employee_tags_touch
  BEFORE UPDATE ON data.employee_tags
  FOR EACH ROW
  EXECUTE FUNCTION data.touch_employee_tags_updated_at();

-- ─── RLS ─────────────────────────────────────────────────────────────────────

ALTER TABLE data.job_positions ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.employee_tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.employee_tag_assignments ENABLE ROW LEVEL SECURITY;

-- job_positions: view any member; write owner/manager or employees.manage
DROP POLICY IF EXISTS job_positions_select ON data.job_positions;
CREATE POLICY job_positions_select ON data.job_positions
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

DROP POLICY IF EXISTS job_positions_insert ON data.job_positions;
CREATE POLICY job_positions_insert ON data.job_positions
  FOR INSERT TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      data.jwt_has_permission(tenant_id, 'employees.manage')
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  );

DROP POLICY IF EXISTS job_positions_update ON data.job_positions;
CREATE POLICY job_positions_update ON data.job_positions
  FOR UPDATE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      data.jwt_has_permission(tenant_id, 'employees.manage')
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'employees.manage')
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  );

DROP POLICY IF EXISTS job_positions_delete ON data.job_positions;
CREATE POLICY job_positions_delete ON data.job_positions
  FOR DELETE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      data.jwt_has_permission(tenant_id, 'employees.manage')
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') = 'owner'
    )
  );

-- employee_tags: same pattern
DROP POLICY IF EXISTS employee_tags_select ON data.employee_tags;
CREATE POLICY employee_tags_select ON data.employee_tags
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

DROP POLICY IF EXISTS employee_tags_insert ON data.employee_tags;
CREATE POLICY employee_tags_insert ON data.employee_tags
  FOR INSERT TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      data.jwt_has_permission(tenant_id, 'employees.manage')
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  );

DROP POLICY IF EXISTS employee_tags_update ON data.employee_tags;
CREATE POLICY employee_tags_update ON data.employee_tags
  FOR UPDATE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      data.jwt_has_permission(tenant_id, 'employees.manage')
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'employees.manage')
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  );

DROP POLICY IF EXISTS employee_tags_delete ON data.employee_tags;
CREATE POLICY employee_tags_delete ON data.employee_tags
  FOR DELETE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      data.jwt_has_permission(tenant_id, 'employees.manage')
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') = 'owner'
    )
  );

-- assignments: view if can view employee; write if can manage employee
DROP POLICY IF EXISTS employee_tag_assignments_select ON data.employee_tag_assignments;
CREATE POLICY employee_tag_assignments_select ON data.employee_tag_assignments
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND EXISTS (
      SELECT 1 FROM data.employees e
      WHERE e.id = employee_id
        AND e.tenant_id = employee_tag_assignments.tenant_id
        AND data.jwt_can_view_employee(e.tenant_id, e.site_id, e.user_id)
    )
  );

DROP POLICY IF EXISTS employee_tag_assignments_insert ON data.employee_tag_assignments;
CREATE POLICY employee_tag_assignments_insert ON data.employee_tag_assignments
  FOR INSERT TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND EXISTS (
      SELECT 1 FROM data.employees e
      WHERE e.id = employee_id
        AND e.tenant_id = employee_tag_assignments.tenant_id
        AND data.jwt_can_manage_employee(e.tenant_id, e.site_id)
    )
  );

DROP POLICY IF EXISTS employee_tag_assignments_delete ON data.employee_tag_assignments;
CREATE POLICY employee_tag_assignments_delete ON data.employee_tag_assignments
  FOR DELETE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND EXISTS (
      SELECT 1 FROM data.employees e
      WHERE e.id = employee_id
        AND e.tenant_id = employee_tag_assignments.tenant_id
        AND data.jwt_can_manage_employee(e.tenant_id, e.site_id)
    )
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON data.job_positions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.employee_tags TO authenticated;
GRANT SELECT, INSERT, DELETE ON data.employee_tag_assignments TO authenticated;

-- ─── API views ───────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW api.job_positions
  WITH (security_invoker = true) AS
SELECT
  id, tenant_id, code, name, description, department_id,
  default_manager_employee_id, default_site_id, default_calendar_group_id,
  is_active, created_at, updated_at
FROM data.job_positions;

CREATE OR REPLACE VIEW api.employee_tags
  WITH (security_invoker = true) AS
SELECT id, tenant_id, name, color_token, is_active, created_at, updated_at
FROM data.employee_tags;

CREATE OR REPLACE VIEW api.employee_tag_assignments
  WITH (security_invoker = true) AS
SELECT tenant_id, employee_id, tag_id, assigned_by, assigned_at
FROM data.employee_tag_assignments;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.job_positions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.employee_tags TO authenticated;
GRANT SELECT, INSERT, DELETE ON api.employee_tag_assignments TO authenticated;

-- Recreate employees views with job_position_id
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

-- Replace-all tags for an employee
CREATE OR REPLACE FUNCTION api.set_employee_tags(
  p_employee_id uuid,
  p_tag_ids uuid[]
)
RETURNS SETOF api.employee_tag_assignments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_emp data.employees%ROWTYPE;
  v_tag_id uuid;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT * INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT data.jwt_can_manage_employee(v_emp.tenant_id, v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  DELETE FROM data.employee_tag_assignments
  WHERE employee_id = v_emp.id;

  IF p_tag_ids IS NOT NULL THEN
    FOREACH v_tag_id IN ARRAY p_tag_ids LOOP
      IF v_tag_id IS NULL THEN
        CONTINUE;
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM data.employee_tags t
        WHERE t.id = v_tag_id AND t.tenant_id = v_tenant_id AND t.is_active
      ) THEN
        RAISE EXCEPTION 'tag_not_found' USING ERRCODE = 'foreign_key_violation';
      END IF;
      INSERT INTO data.employee_tag_assignments (tenant_id, employee_id, tag_id, assigned_by)
      VALUES (v_tenant_id, v_emp.id, v_tag_id, auth.uid());
    END LOOP;
  END IF;

  RETURN QUERY
  SELECT * FROM api.employee_tag_assignments WHERE employee_id = v_emp.id;
END;
$$;

REVOKE EXECUTE ON FUNCTION api.set_employee_tags(uuid, uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_employee_tags(uuid, uuid[]) TO authenticated;

-- Ensure / find tag by name (creatable multi-select)
CREATE OR REPLACE FUNCTION api.ensure_employee_tag(p_name text, p_color_token text DEFAULT NULL)
RETURNS api.employee_tags
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_name text := btrim(p_name);
  v_out api.employee_tags;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;
  IF v_name IS NULL OR v_name = '' THEN
    RAISE EXCEPTION 'tag_name_required' USING ERRCODE = 'check_violation';
  END IF;
  IF NOT (
    data.jwt_has_permission(v_tenant_id, 'employees.manage')
    OR (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_out
  FROM api.employee_tags t
  WHERE t.tenant_id = v_tenant_id AND lower(btrim(t.name)) = lower(v_name)
  LIMIT 1;

  IF FOUND THEN
    RETURN v_out;
  END IF;

  INSERT INTO data.employee_tags (tenant_id, name, color_token)
  VALUES (v_tenant_id, v_name, p_color_token)
  RETURNING * INTO v_out;

  RETURN v_out;
END;
$$;

REVOKE EXECUTE ON FUNCTION api.ensure_employee_tag(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.ensure_employee_tag(text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
