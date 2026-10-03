-- Gate Tall 2 → Tall 3 (slice): commercial.costs.view + private material cost.
-- Sale price stays on project_materials.unit_price_cents (public to project members).
-- Cost lives in data.project_material_costs so api.project_materials cannot leak it.

-- ---------------------------------------------------------------------------
-- 1. get_role_permissions — key on manager base only (not member).
--    Custom metadata.role_permissions.manager replaces the base; no JSON backfill.
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
    'assets.view',
    'recruitment.view'
  ];
  v_member_base  text[] := ARRAY[
    'storage.upload', 'calendar.edit', 'email.send', 'invoices.edit',
    'attendance.punch_own', 'absences.request',
    'ai.use',
    'employees.directory.view', 'employees.view',
    'assets.view',
    'recruitment.view',
    'field_service.reports.publish',
    'field_service.reports.regenerate',
    'field_service.reports.share',
    'field_service.reports.preview_as_customer',
    'contacts.portal.manage',
    'commercial.pricing.edit'
  ];
  v_manager_base text[] := ARRAY[
    'storage.delete', 'calendar.manage', 'email.manage', 'invoices.manage',
    'members.invite', 'sites.create', 'settings.manage', 'permissions.manage',
    'attendance.view_all', 'attendance.adjust', 'attendance.approve',
    'attendance.export', 'attendance.devices.manage',
    'labor_calendar.manage', 'absences.approve',
    'ai.configure', 'ai.tools.write',
    'employees.directory.view', 'employees.view', 'employees.manage',
    'employees.private.view', 'employees.private.manage', 'employees.private.reveal',
    'employees.skills.manage',
    'employees.lifecycle.view', 'employees.lifecycle.manage',
    'employees.contracts.view', 'employees.contracts.manage',
    'compliance.requirements.manage',
    'compliance.certifications.view', 'compliance.certifications.manage',
    'assets.view', 'assets.manage',
    'assets.employee_assignments.view', 'assets.employee_assignments.manage',
    'recruitment.view', 'recruitment.manage', 'recruitment.interview',
    'field_service.reports.publish',
    'field_service.reports.regenerate',
    'field_service.reports.share',
    'field_service.reports.revoke',
    'field_service.reports.preview_as_customer',
    'contacts.portal.manage',
    'commercial.pricing.edit',
    'commercial.costs.view'
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
-- 2. Owner allowlist so the key can be granted to member.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.update_tenant_role_permissions(
  p_permissions jsonb,
  p_tenant_id   uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id   uuid;
  v_global_role text;
  v_role_key    text;
  v_perm_key    text;
  v_old_perms   jsonb;

  v_valid_keys  text[] := ARRAY[
    'storage.view', 'storage.upload', 'storage.delete', 'storage.manage',
    'calendar.view', 'calendar.edit', 'calendar.manage',
    'email.view', 'email.send', 'email.manage',
    'invoices.view', 'invoices.edit', 'invoices.manage',
    'members.view', 'members.invite', 'members.manage',
    'sites.view', 'sites.create', 'sites.manage',
    'settings.view', 'settings.manage',
    'permissions.manage',
    'ai.use', 'ai.configure', 'ai.tools.write',
    'employees.directory.view', 'employees.view', 'employees.manage',
    'employees.private.view', 'employees.private.manage', 'employees.private.reveal', 'employees.skills.manage',
    'employees.lifecycle.view', 'employees.lifecycle.manage',
    'employees.contracts.view', 'employees.contracts.manage', 'employees.contracts.approve',
    'employees.compensation.view', 'employees.compensation.edit',
    'compliance.requirements.manage',
    'compliance.certifications.view', 'compliance.certifications.manage',
    'compliance.medical_clearance.view', 'compliance.medical_clearance.manage',
    'assets.view', 'assets.manage',
    'assets.employee_assignments.view', 'assets.employee_assignments.manage',
    'recruitment.view', 'recruitment.manage', 'recruitment.interview', 'recruitment.rights',
    'field_service.reports.publish', 'field_service.reports.regenerate',
    'field_service.reports.share', 'field_service.reports.revoke',
    'field_service.reports.preview_as_customer',
    'contacts.portal.manage',
    'commercial.pricing.edit',
    'commercial.costs.view',
    'attendance.punch_own', 'attendance.approve', 'absences.request'
  ];
  v_valid_roles text[] := ARRAY['viewer', 'member', 'manager'];
BEGIN
  v_tenant_id := COALESCE(p_tenant_id, data.active_tenant_id());

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'No active tenant: pass p_tenant_id or set x-tenant-id header';
  END IF;

  IF jsonb_typeof(p_permissions) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'p_permissions must be a JSON object';
  END IF;

  v_global_role := data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role';
  IF COALESCE(v_global_role, '') <> 'owner' THEN
    RAISE EXCEPTION 'Only tenant owners can modify role permissions';
  END IF;

  FOR v_role_key IN SELECT jsonb_object_keys(p_permissions)
  LOOP
    IF NOT (v_role_key = ANY(v_valid_roles)) THEN
      RAISE EXCEPTION 'Invalid role key: %. Valid roles are: viewer, member, manager', v_role_key;
    END IF;

    IF jsonb_typeof(p_permissions -> v_role_key) <> 'array' THEN
      RAISE EXCEPTION 'Permissions for role % must be an array', v_role_key;
    END IF;

    FOR v_perm_key IN
      SELECT jsonb_array_elements_text(p_permissions -> v_role_key)
    LOOP
      IF NOT (v_perm_key = ANY(v_valid_keys)) THEN
        RAISE EXCEPTION 'Invalid permission key: ''%''. Check permissions.ts ALL_PERMISSION_KEYS', v_perm_key;
      END IF;
    END LOOP;
  END LOOP;

  SELECT metadata -> 'role_permissions'
  INTO v_old_perms
  FROM data.tenants
  WHERE id = v_tenant_id;

  UPDATE data.tenants
  SET metadata = COALESCE(metadata, '{}') || jsonb_build_object(
    'role_permissions',       p_permissions,
    'permissions_updated_at', now(),
    'permissions_updated_by', auth.uid()
  )
  WHERE id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Tenant % not found', v_tenant_id;
  END IF;

  PERFORM data.log_audit_event(
    v_tenant_id,
    auth.uid(),
    NULL,
    'ROLE_PERMISSIONS_UPDATED',
    'tenant',
    v_tenant_id,
    jsonb_build_object(
      'old', COALESCE(v_old_perms, '{}'::jsonb),
      'new', p_permissions
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION api.update_tenant_role_permissions(jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.update_tenant_role_permissions(jsonb, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Permission helper (global role, site role, or live grant).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.can_view_commercial_costs(
  p_tenant_id uuid,
  p_site_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_claims jsonb;
  v_role text;
  v_site_role text;
BEGIN
  IF auth.uid() IS NULL OR p_tenant_id IS NULL THEN
    RETURN false;
  END IF;

  v_claims := data.jwt_user_tenants() -> p_tenant_id::text;
  v_role := v_claims ->> 'global_role';
  IF v_role IN ('owner', 'manager') THEN
    RETURN true;
  END IF;

  IF p_site_id IS NOT NULL THEN
    v_site_role := v_claims -> 'sites' ->> p_site_id::text;
    IF v_site_role IN ('owner', 'manager') THEN
      RETURN true;
    END IF;
  END IF;

  RETURN COALESCE(
    data.member_has_live_permission(
      p_tenant_id, auth.uid(), 'commercial.costs.view', p_site_id
    ),
    false
  );
END;
$$;

REVOKE ALL ON FUNCTION data.can_view_commercial_costs(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.can_view_commercial_costs(uuid, uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION data.can_view_commercial_costs(uuid, uuid) IS
  'Owner/manager global, owner/manager de la seu, o concessió live commercial.costs.view.';

-- ---------------------------------------------------------------------------
-- 4. Private cost table + read-only API view.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.project_material_costs (
  material_id uuid PRIMARY KEY
    REFERENCES data.project_materials(id) ON DELETE CASCADE,
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  unit_cost_cents integer NOT NULL CHECK (unit_cost_cents >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_project_material_costs_tenant
  ON data.project_material_costs (tenant_id);

CREATE OR REPLACE FUNCTION data.trg_project_material_costs_tenant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant uuid;
BEGIN
  SELECT m.tenant_id INTO v_tenant
  FROM data.project_materials m
  WHERE m.id = NEW.material_id;

  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'material_not_found' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.tenant_id IS DISTINCT FROM v_tenant THEN
    RAISE EXCEPTION 'tenant_mismatch' USING ERRCODE = 'P0001';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_project_material_costs_tenant ON data.project_material_costs;
CREATE TRIGGER trg_project_material_costs_tenant
  BEFORE INSERT OR UPDATE ON data.project_material_costs
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_project_material_costs_tenant();

CREATE OR REPLACE FUNCTION data.material_cost_visible(p_material_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT data.can_view_commercial_costs(m.tenant_id, p.site_id)
  FROM data.project_materials m
  JOIN data.projects p ON p.id = m.project_id
  WHERE m.id = p_material_id;
$$;

REVOKE ALL ON FUNCTION data.material_cost_visible(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.material_cost_visible(uuid)
  TO authenticated, service_role;

ALTER TABLE data.project_material_costs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS project_material_costs_select ON data.project_material_costs;
CREATE POLICY project_material_costs_select
  ON data.project_material_costs
  FOR SELECT
  TO authenticated
  USING (data.material_cost_visible(material_id));

DROP POLICY IF EXISTS project_material_costs_insert ON data.project_material_costs;
CREATE POLICY project_material_costs_insert
  ON data.project_material_costs
  FOR INSERT
  TO authenticated
  WITH CHECK (data.material_cost_visible(material_id));

DROP POLICY IF EXISTS project_material_costs_update ON data.project_material_costs;
CREATE POLICY project_material_costs_update
  ON data.project_material_costs
  FOR UPDATE
  TO authenticated
  USING (data.material_cost_visible(material_id))
  WITH CHECK (data.material_cost_visible(material_id));

DROP POLICY IF EXISTS project_material_costs_delete ON data.project_material_costs;
CREATE POLICY project_material_costs_delete
  ON data.project_material_costs
  FOR DELETE
  TO authenticated
  USING (data.material_cost_visible(material_id));

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE data.project_material_costs TO authenticated;

CREATE OR REPLACE VIEW api.project_material_costs
  WITH (security_invoker = true) AS
  SELECT material_id, tenant_id, unit_cost_cents, updated_at
  FROM data.project_material_costs;

REVOKE ALL ON api.project_material_costs FROM PUBLIC, anon;
GRANT SELECT ON api.project_material_costs TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Guard sale price on the public materials table.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_project_materials_guard_unit_price()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_site uuid;
BEGIN
  IF TG_OP = 'INSERT' AND NEW.unit_price_cents IS NULL THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.unit_price_cents IS NOT DISTINCT FROM OLD.unit_price_cents THEN
    RETURN NEW;
  END IF;

  SELECT p.site_id INTO v_site
  FROM data.projects p
  WHERE p.id = NEW.project_id;

  IF NOT data.can_edit_commercial_pricing(NEW.tenant_id, v_site) THEN
    RAISE EXCEPTION 'permission_denied:commercial.pricing.edit' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_project_materials_guard_unit_price ON data.project_materials;
CREATE TRIGGER trg_project_materials_guard_unit_price
  BEFORE INSERT OR UPDATE ON data.project_materials
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_project_materials_guard_unit_price();

-- ---------------------------------------------------------------------------
-- 6. Patch RPC. Present JSON keys change; absent keys are left alone.
--    JSON null clears the field (cost row deleted).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.set_project_material_amounts(
  p_material_id uuid,
  p_patch jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_mat data.project_materials%ROWTYPE;
  v_site uuid;
  v_cents integer;
BEGIN
  IF p_material_id IS NULL OR p_patch IS NULL OR p_patch = '{}'::jsonb THEN
    RETURN;
  END IF;

  SELECT * INTO v_mat
  FROM data.project_materials
  WHERE id = p_material_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'material_not_found' USING ERRCODE = 'P0001';
  END IF;

  SELECT p.site_id INTO v_site
  FROM data.projects p
  WHERE p.id = v_mat.project_id;

  IF p_patch ? 'unit_price_cents' THEN
    IF NOT data.can_edit_commercial_pricing(v_mat.tenant_id, v_site) THEN
      RAISE EXCEPTION 'permission_denied:commercial.pricing.edit' USING ERRCODE = 'P0001';
    END IF;
    IF jsonb_typeof(p_patch -> 'unit_price_cents') = 'null' THEN
      UPDATE data.project_materials
      SET unit_price_cents = NULL
      WHERE id = v_mat.id;
    ELSE
      v_cents := (p_patch ->> 'unit_price_cents')::integer;
      IF v_cents IS NULL OR v_cents < 0 THEN
        RAISE EXCEPTION 'invalid_unit_price_cents' USING ERRCODE = 'P0001';
      END IF;
      UPDATE data.project_materials
      SET unit_price_cents = v_cents
      WHERE id = v_mat.id;
    END IF;
  END IF;

  IF p_patch ? 'unit_cost_cents' THEN
    IF NOT data.can_view_commercial_costs(v_mat.tenant_id, v_site) THEN
      RAISE EXCEPTION 'permission_denied:commercial.costs.view' USING ERRCODE = 'P0001';
    END IF;
    IF jsonb_typeof(p_patch -> 'unit_cost_cents') = 'null' THEN
      DELETE FROM data.project_material_costs WHERE material_id = v_mat.id;
    ELSE
      v_cents := (p_patch ->> 'unit_cost_cents')::integer;
      IF v_cents IS NULL OR v_cents < 0 THEN
        RAISE EXCEPTION 'invalid_unit_cost_cents' USING ERRCODE = 'P0001';
      END IF;
      INSERT INTO data.project_material_costs (material_id, tenant_id, unit_cost_cents)
      VALUES (v_mat.id, v_mat.tenant_id, v_cents)
      ON CONFLICT (material_id) DO UPDATE
        SET unit_cost_cents = EXCLUDED.unit_cost_cents,
            tenant_id = EXCLUDED.tenant_id;
    END IF;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION api.set_project_material_amounts(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_project_material_amounts(uuid, jsonb)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.set_project_material_amounts(uuid, jsonb) IS
  'Patch material sale price (commercial.pricing.edit) and private cost (commercial.costs.view). Absent keys are unchanged; JSON null clears.';

NOTIFY pgrst, 'reload schema';
