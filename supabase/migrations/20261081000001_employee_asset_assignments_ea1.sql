-- =============================================================================
-- M-EA-03 — EA-1: employee_asset_assignments (append-only) + assign/return RPCs
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Permissions in get_role_permissions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.get_role_permissions(
  p_role              text,
  p_custom_perms      jsonb DEFAULT NULL
)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_viewer_base  text[] := ARRAY[
    'storage.view', 'calendar.view', 'email.view', 'invoices.view',
    'members.view', 'sites.view', 'settings.view',
    'attendance.view_own', 'labor_calendar.view',
    'employees.directory.view',
    'assets.view'
  ];
  v_member_base  text[] := ARRAY[
    'storage.upload', 'calendar.edit', 'email.send', 'invoices.edit',
    'attendance.punch_own', 'absences.request',
    'ai.use',
    'employees.directory.view', 'employees.view',
    'assets.view'
  ];
  v_manager_base text[] := ARRAY[
    'storage.delete', 'calendar.manage', 'email.manage', 'invoices.manage',
    'members.invite', 'sites.create', 'settings.manage', 'permissions.manage',
    'attendance.view_all', 'attendance.adjust', 'attendance.approve',
    'attendance.export', 'attendance.devices.manage',
    'labor_calendar.manage', 'absences.approve',
    'ai.configure', 'ai.tools.write',
    'employees.directory.view', 'employees.view', 'employees.manage',
    'employees.private.view', 'employees.private.manage',
    'employees.skills.manage',
    'employees.lifecycle.view', 'employees.lifecycle.manage',
    'compliance.requirements.manage',
    'compliance.certifications.view', 'compliance.certifications.manage',
    'assets.view', 'assets.manage',
    'assets.employee_assignments.view', 'assets.employee_assignments.manage'
  ];
  v_accumulated  text[] := '{}';
BEGIN
  IF p_role = 'owner' THEN
    RETURN ARRAY['*'];
  END IF;

  IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'viewer' THEN
    v_accumulated := v_accumulated ||
      ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'viewer'));
  ELSE
    v_accumulated := v_accumulated || v_viewer_base;
  END IF;

  IF p_role IN ('member', 'manager') THEN
    IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'member' THEN
      v_accumulated := v_accumulated ||
        ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'member'));
    ELSE
      v_accumulated := v_accumulated || v_member_base;
    END IF;
  END IF;

  IF p_role = 'manager' THEN
    IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'manager' THEN
      v_accumulated := v_accumulated ||
        ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'manager'));
    ELSE
      v_accumulated := v_accumulated || v_manager_base;
    END IF;
  END IF;

  RETURN ARRAY(SELECT DISTINCT unnest(v_accumulated));
END;
$$;

GRANT EXECUTE ON FUNCTION data.get_role_permissions(text, jsonb)
  TO authenticated, supabase_auth_admin;

-- ---------------------------------------------------------------------------
-- 2. Table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.employee_asset_assignments (
  id                         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                  uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  asset_id                   uuid NOT NULL REFERENCES data.assets(id) ON DELETE CASCADE,
  employee_id                uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  assigned_at                timestamptz NOT NULL DEFAULT now(),
  assigned_by                uuid NOT NULL REFERENCES data.profiles(id),
  expected_return_at         timestamptz,
  returned_at                timestamptz,
  return_condition           text
    CHECK (return_condition IS NULL OR return_condition IN ('good', 'damaged', 'lost')),
  returned_by                uuid REFERENCES data.profiles(id),
  acknowledgment_document_id uuid REFERENCES data.documents(id) ON DELETE SET NULL,
  return_document_id         uuid REFERENCES data.documents(id) ON DELETE SET NULL,
  notes                      text,
  created_at                 timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employee_asset_assignments_return_consistency CHECK (
    (returned_at IS NULL AND return_condition IS NULL AND returned_by IS NULL)
    OR (returned_at IS NOT NULL AND return_condition IS NOT NULL)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_employee_asset_assignments_open_per_asset
  ON data.employee_asset_assignments (asset_id)
  WHERE returned_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_employee_asset_assignments_employee_open
  ON data.employee_asset_assignments (employee_id)
  WHERE returned_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_employee_asset_assignments_asset
  ON data.employee_asset_assignments (asset_id);

CREATE INDEX IF NOT EXISTS idx_employee_asset_assignments_tenant
  ON data.employee_asset_assignments (tenant_id, employee_id);

-- Append-only: never mutate a closed row; only allow closing an open one
CREATE OR REPLACE FUNCTION data.enforce_employee_asset_assignment_append_only()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'employee_asset_assignment_delete_forbidden'
      USING ERRCODE = 'check_violation';
  END IF;

  IF OLD.returned_at IS NOT NULL THEN
    RAISE EXCEPTION 'employee_asset_assignment_closed_immutable'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Closing: only fill return fields
  IF NEW.returned_at IS NOT NULL AND OLD.returned_at IS NULL THEN
    IF NEW.asset_id IS DISTINCT FROM OLD.asset_id
       OR NEW.employee_id IS DISTINCT FROM OLD.employee_id
       OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
       OR NEW.assigned_at IS DISTINCT FROM OLD.assigned_at
       OR NEW.assigned_by IS DISTINCT FROM OLD.assigned_by THEN
      RAISE EXCEPTION 'employee_asset_assignment_identity_immutable'
        USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'employee_asset_assignment_update_forbidden'
    USING ERRCODE = 'check_violation';
END;
$$;

DROP TRIGGER IF EXISTS trg_employee_asset_assignment_append_only
  ON data.employee_asset_assignments;
CREATE TRIGGER trg_employee_asset_assignment_append_only
  BEFORE UPDATE OR DELETE ON data.employee_asset_assignments
  FOR EACH ROW EXECUTE FUNCTION data.enforce_employee_asset_assignment_append_only();

ALTER TABLE data.employee_asset_assignments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS employee_asset_assignments_select ON data.employee_asset_assignments;
CREATE POLICY employee_asset_assignments_select ON data.employee_asset_assignments
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      data.jwt_has_permission(tenant_id, 'assets.employee_assignments.view')
      OR data.jwt_has_permission(tenant_id, 'assets.employee_assignments.manage')
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  );

-- No INSERT/UPDATE/DELETE policies for authenticated — only SECURITY DEFINER RPCs

GRANT SELECT ON data.employee_asset_assignments TO authenticated, service_role;
GRANT INSERT, UPDATE ON data.employee_asset_assignments TO service_role;

CREATE OR REPLACE VIEW api.employee_asset_assignments
  WITH (security_invoker = true) AS
SELECT
  eaa.*,
  a.name AS asset_name,
  a.asset_tag,
  a.status AS asset_status,
  a.asset_type_id,
  a.site_id AS asset_site_id,
  e.full_name AS employee_name
FROM data.employee_asset_assignments eaa
JOIN data.assets a ON a.id = eaa.asset_id
JOIN data.employees e ON e.id = eaa.employee_id;

GRANT SELECT ON api.employee_asset_assignments TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.can_manage_employee_asset_assignments(
  p_tenant_id uuid,
  p_site_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT
    data.jwt_has_permission(p_tenant_id, 'assets.employee_assignments.manage', p_site_id)
    OR (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager');
$$;

CREATE OR REPLACE FUNCTION data.can_view_employee_asset_assignments(
  p_tenant_id uuid,
  p_site_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT
    data.jwt_has_permission(p_tenant_id, 'assets.employee_assignments.view', p_site_id)
    OR data.jwt_has_permission(p_tenant_id, 'assets.employee_assignments.manage', p_site_id)
    OR (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager');
$$;

-- ---------------------------------------------------------------------------
-- 4. RPCs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.assign_employee_asset(
  p_asset_id uuid,
  p_employee_id uuid,
  p_acknowledgment_document_id uuid DEFAULT NULL,
  p_expected_return_at timestamptz DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS api.employee_asset_assignments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_asset data.assets%ROWTYPE;
  v_emp_tenant uuid;
  v_id uuid;
  v_out api.employee_asset_assignments;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT * INTO v_asset
  FROM data.assets
  WHERE id = p_asset_id AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'asset_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT tenant_id INTO v_emp_tenant
  FROM data.employees
  WHERE id = p_employee_id;

  IF v_emp_tenant IS NULL OR v_emp_tenant IS DISTINCT FROM v_tenant_id THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT data.can_manage_employee_asset_assignments(v_tenant_id, v_asset.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_asset.status = 'retired' THEN
    RAISE EXCEPTION 'asset_retired' USING ERRCODE = 'check_violation';
  END IF;

  IF EXISTS (
    SELECT 1 FROM data.employee_asset_assignments
    WHERE asset_id = p_asset_id AND returned_at IS NULL
  ) THEN
    RAISE EXCEPTION 'asset_already_assigned' USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO data.employee_asset_assignments (
    tenant_id, asset_id, employee_id, assigned_by,
    expected_return_at, acknowledgment_document_id, notes
  ) VALUES (
    v_tenant_id, p_asset_id, p_employee_id, auth.uid(),
    p_expected_return_at, p_acknowledgment_document_id, p_notes
  )
  RETURNING id INTO v_id;

  PERFORM data.log_audit_event(
    v_tenant_id, auth.uid(), v_asset.site_id,
    'ASSET_ASSIGNED', 'employee_asset_assignment', v_id,
    jsonb_build_object('employee_id', p_employee_id, 'asset_id', p_asset_id),
    false
  );

  PERFORM data.refresh_employee_readiness_projection(p_employee_id);

  SELECT * INTO v_out FROM api.employee_asset_assignments WHERE id = v_id;
  RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION api.return_employee_asset(
  p_asset_id uuid,
  p_condition text DEFAULT 'good',
  p_return_document_id uuid DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS api.employee_asset_assignments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_site_id uuid;
  v_assignment_id uuid;
  v_employee_id uuid;
  v_out api.employee_asset_assignments;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  IF p_condition IS NULL OR p_condition NOT IN ('good', 'damaged', 'lost') THEN
    RAISE EXCEPTION 'invalid_return_condition' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT eaa.id, eaa.employee_id, a.site_id
  INTO v_assignment_id, v_employee_id, v_site_id
  FROM data.employee_asset_assignments eaa
  JOIN data.assets a ON a.id = eaa.asset_id
  WHERE eaa.asset_id = p_asset_id
    AND eaa.returned_at IS NULL
    AND eaa.tenant_id = v_tenant_id
  FOR UPDATE OF eaa;

  IF v_assignment_id IS NULL THEN
    RAISE EXCEPTION 'asset_not_assigned' USING ERRCODE = 'check_violation';
  END IF;

  IF NOT data.can_manage_employee_asset_assignments(v_tenant_id, v_site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.employee_asset_assignments
  SET returned_at = now(),
      return_condition = p_condition,
      return_document_id = p_return_document_id,
      returned_by = auth.uid(),
      notes = coalesce(p_notes, notes)
  WHERE id = v_assignment_id;

  IF p_condition = 'lost' THEN
    UPDATE data.assets SET status = 'retired', updated_at = now()
    WHERE id = p_asset_id AND tenant_id = v_tenant_id;
  END IF;

  PERFORM data.log_audit_event(
    v_tenant_id, auth.uid(), v_site_id,
    'ASSET_RETURNED', 'employee_asset_assignment', v_assignment_id,
    jsonb_build_object('condition', p_condition, 'employee_id', v_employee_id, 'asset_id', p_asset_id),
    false
  );

  PERFORM data.refresh_employee_readiness_projection(v_employee_id);

  SELECT * INTO v_out FROM api.employee_asset_assignments WHERE id = v_assignment_id;
  RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION api.list_employee_asset_assignments(
  p_employee_id uuid,
  p_include_returned boolean DEFAULT true
)
RETURNS SETOF api.employee_asset_assignments
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_site_id uuid;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT site_id INTO v_site_id
  FROM data.employees
  WHERE id = p_employee_id AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT data.can_view_employee_asset_assignments(v_tenant_id, v_site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  SELECT *
  FROM api.employee_asset_assignments eaa
  WHERE eaa.employee_id = p_employee_id
    AND eaa.tenant_id = v_tenant_id
    AND (p_include_returned OR eaa.returned_at IS NULL)
  ORDER BY eaa.returned_at NULLS FIRST, eaa.assigned_at DESC;
END;
$$;

CREATE OR REPLACE FUNCTION api.list_assignable_assets(
  p_site_id uuid DEFAULT NULL
)
RETURNS SETOF api.assets
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  IF NOT data.can_view_employee_asset_assignments(v_tenant_id, p_site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  SELECT a.*
  FROM api.assets a
  WHERE a.tenant_id = v_tenant_id
    AND a.status <> 'retired'
    AND (p_site_id IS NULL OR a.site_id = p_site_id)
    AND NOT EXISTS (
      SELECT 1 FROM data.employee_asset_assignments eaa
      WHERE eaa.asset_id = a.id AND eaa.returned_at IS NULL
    )
  ORDER BY a.name;
END;
$$;

COMMENT ON FUNCTION api.assign_employee_asset(uuid, uuid, uuid, timestamptz, text) IS
  'EA-1: assigna un actiu a un empleat (INSERT append-only).';
COMMENT ON FUNCTION api.return_employee_asset(uuid, text, uuid, text) IS
  'EA-1: tanca l''assignació oberta; lost → assets.status=retired.';

REVOKE ALL ON FUNCTION api.assign_employee_asset(uuid, uuid, uuid, timestamptz, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.return_employee_asset(uuid, text, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.list_employee_asset_assignments(uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.list_assignable_assets(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.assign_employee_asset(uuid, uuid, uuid, timestamptz, text)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.return_employee_asset(uuid, text, uuid, text)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.list_employee_asset_assignments(uuid, boolean)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.list_assignable_assets(uuid)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
