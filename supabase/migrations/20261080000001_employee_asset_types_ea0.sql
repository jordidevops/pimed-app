-- =============================================================================
-- M-EA-01/02 — EA-0: asset_types + extensió additiva data.assets
-- No crea inventari paral·lel. entity_types (ES-4) diferit — reservat employee_asset_assignment.
-- Permisos: assets.view / assets.manage (documentats al pla; absents al JWT fins ara).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Permisos JWT (get_role_permissions)
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
    'assets.view', 'assets.manage'
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
-- 2. data.asset_types
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.asset_types (
  id                         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                  uuid REFERENCES data.tenants(id) ON DELETE CASCADE,
  code                       text NOT NULL,
  name                       text NOT NULL,
  category                   text NOT NULL
    CHECK (category IN ('epi', 'vehicle', 'tool', 'device', 'other')),
  requires_return            boolean NOT NULL DEFAULT true,
  requires_calibration       boolean NOT NULL DEFAULT false,
  calibration_interval_days  int CHECK (calibration_interval_days IS NULL OR calibration_interval_days > 0),
  blocks_dispatch_if_missing boolean NOT NULL DEFAULT false,
  is_active                  boolean NOT NULL DEFAULT true,
  created_at                 timestamptz NOT NULL DEFAULT now(),
  updated_at                 timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT asset_types_code_nonempty CHECK (length(btrim(code)) > 0),
  CONSTRAINT asset_types_name_nonempty CHECK (length(btrim(name)) > 0),
  CONSTRAINT asset_types_calibration_consistency CHECK (
    (NOT requires_calibration AND calibration_interval_days IS NULL)
    OR requires_calibration
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_asset_types_tenant_code
  ON data.asset_types (COALESCE(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(code));

CREATE INDEX IF NOT EXISTS idx_asset_types_tenant_active
  ON data.asset_types (tenant_id, is_active);

DROP TRIGGER IF EXISTS trg_asset_types_updated_at ON data.asset_types;
CREATE TRIGGER trg_asset_types_updated_at
  BEFORE UPDATE ON data.asset_types
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

ALTER TABLE data.asset_types ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS asset_types_select ON data.asset_types;
CREATE POLICY asset_types_select ON data.asset_types
  FOR SELECT TO authenticated
  USING (
    tenant_id IS NULL
    OR (
      data.jwt_user_tenants() ? tenant_id::text
      AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
      AND (
        data.jwt_has_permission(tenant_id, 'assets.view')
        OR data.jwt_has_permission(tenant_id, 'assets.manage')
        OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager', 'member', 'viewer')
      )
    )
  );

DROP POLICY IF EXISTS asset_types_insert ON data.asset_types;
CREATE POLICY asset_types_insert ON data.asset_types
  FOR INSERT TO authenticated
  WITH CHECK (
    tenant_id IS NOT NULL
    AND data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      data.jwt_has_permission(tenant_id, 'assets.manage')
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  );

DROP POLICY IF EXISTS asset_types_update ON data.asset_types;
CREATE POLICY asset_types_update ON data.asset_types
  FOR UPDATE TO authenticated
  USING (
    tenant_id IS NOT NULL
    AND data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'assets.manage')
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  )
  WITH CHECK (
    tenant_id IS NOT NULL
    AND (
      data.jwt_has_permission(tenant_id, 'assets.manage')
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  );

GRANT SELECT ON data.asset_types TO authenticated, service_role;
GRANT INSERT, UPDATE ON data.asset_types TO authenticated;
GRANT ALL ON data.asset_types TO service_role;

CREATE OR REPLACE VIEW api.asset_types
  WITH (security_invoker = true) AS
SELECT * FROM data.asset_types;

GRANT SELECT, INSERT, UPDATE ON api.asset_types TO authenticated, service_role;

-- Platform seed (clonable)
INSERT INTO data.asset_types (
  tenant_id, code, name, category,
  requires_return, requires_calibration, calibration_interval_days,
  blocks_dispatch_if_missing
)
SELECT v.tenant_id, v.code, v.name, v.category,
       v.requires_return, v.requires_calibration, v.calibration_interval_days,
       v.blocks_dispatch_if_missing
FROM (VALUES
  (NULL::uuid, 'EPI_CAT_III', 'EPI categoria III', 'epi', true, false, NULL::int, true),
  (NULL::uuid, 'VEHICLE_VAN', 'Furgoneta / vehicle', 'vehicle', true, false, NULL::int, false),
  (NULL::uuid, 'TOOL_CALIBRATED', 'Eina calibrable', 'tool', true, true, 365, false)
) AS v(tenant_id, code, name, category, requires_return, requires_calibration, calibration_interval_days, blocks_dispatch_if_missing)
WHERE NOT EXISTS (
  SELECT 1 FROM data.asset_types t
  WHERE t.tenant_id IS NULL AND lower(t.code) = lower(v.code)
);

-- ---------------------------------------------------------------------------
-- 3. RPCs list / upsert
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.list_asset_types(
  p_include_inactive boolean DEFAULT false
)
RETURNS SETOF api.asset_types
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = api, data
AS $$
  SELECT t.*
  FROM api.asset_types t
  WHERE (
    t.tenant_id IS NULL
    OR t.tenant_id = data.active_tenant_id()
  )
  AND (p_include_inactive OR t.is_active = true)
  ORDER BY t.category, t.name;
$$;

CREATE OR REPLACE FUNCTION api.upsert_asset_type(
  p_id                         uuid DEFAULT NULL,
  p_code                       text DEFAULT NULL,
  p_name                       text DEFAULT NULL,
  p_category                   text DEFAULT NULL,
  p_requires_return            boolean DEFAULT NULL,
  p_requires_calibration       boolean DEFAULT NULL,
  p_calibration_interval_days  int DEFAULT NULL,
  p_blocks_dispatch_if_missing boolean DEFAULT NULL,
  p_is_active                  boolean DEFAULT true
)
RETURNS api.asset_types
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_row       data.asset_types;
  v_req_cal   boolean;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  IF NOT (
    data.jwt_has_permission(v_tenant_id, 'assets.manage')
    OR (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_id IS NOT NULL THEN
    SELECT * INTO v_row FROM data.asset_types
    WHERE id = p_id AND tenant_id = v_tenant_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'asset_type_not_found' USING ERRCODE = 'no_data_found';
    END IF;

    v_req_cal := coalesce(p_requires_calibration, v_row.requires_calibration);

    UPDATE data.asset_types
    SET
      code = coalesce(p_code, code),
      name = coalesce(p_name, name),
      category = coalesce(p_category, category),
      requires_return = coalesce(p_requires_return, requires_return),
      requires_calibration = v_req_cal,
      calibration_interval_days = CASE
        WHEN NOT v_req_cal THEN NULL
        ELSE coalesce(p_calibration_interval_days, calibration_interval_days)
      END,
      blocks_dispatch_if_missing = coalesce(p_blocks_dispatch_if_missing, blocks_dispatch_if_missing),
      is_active = coalesce(p_is_active, is_active),
      updated_at = now()
    WHERE id = p_id
    RETURNING * INTO v_row;
  ELSE
    IF p_code IS NULL OR p_name IS NULL OR p_category IS NULL THEN
      RAISE EXCEPTION 'code_name_category_required' USING ERRCODE = 'invalid_parameter_value';
    END IF;

    v_req_cal := coalesce(p_requires_calibration, false);

    INSERT INTO data.asset_types (
      tenant_id, code, name, category,
      requires_return, requires_calibration, calibration_interval_days,
      blocks_dispatch_if_missing, is_active
    ) VALUES (
      v_tenant_id, upper(btrim(p_code)), btrim(p_name), p_category,
      coalesce(p_requires_return, true),
      v_req_cal,
      CASE WHEN v_req_cal THEN p_calibration_interval_days ELSE NULL END,
      coalesce(p_blocks_dispatch_if_missing, false),
      coalesce(p_is_active, true)
    )
    RETURNING * INTO v_row;
  END IF;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_asset_types(boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.upsert_asset_type(
  uuid, text, text, text, boolean, boolean, int, boolean, boolean
) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Extensió additiva data.assets
-- ---------------------------------------------------------------------------
ALTER TABLE data.assets
  ADD COLUMN IF NOT EXISTS asset_type_id uuid REFERENCES data.asset_types(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS requires_calibration boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS calibration_due_on date,
  ADD COLUMN IF NOT EXISTS blocks_dispatch_if_missing boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS idx_assets_asset_type_id
  ON data.assets (asset_type_id) WHERE asset_type_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_assets_calibration_due_on
  ON data.assets (tenant_id, calibration_due_on) WHERE calibration_due_on IS NOT NULL;

CREATE OR REPLACE FUNCTION data.enforce_asset_type_tenant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_type_tenant uuid;
BEGIN
  IF NEW.asset_type_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT tenant_id INTO v_type_tenant FROM data.asset_types WHERE id = NEW.asset_type_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'asset_type_not_found' USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Platform types (tenant_id NULL) OK; tenant types must match asset tenant
  IF v_type_tenant IS NOT NULL AND v_type_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'asset_type_tenant_mismatch' USING ERRCODE = 'foreign_key_violation';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_assets_asset_type_tenant ON data.assets;
CREATE TRIGGER trg_assets_asset_type_tenant
  BEFORE INSERT OR UPDATE OF asset_type_id, tenant_id ON data.assets
  FOR EACH ROW EXECUTE FUNCTION data.enforce_asset_type_tenant();

-- Recreate api.assets (+ rules) with new columns
-- CREATE OR REPLACE cannot reorder/insert columns mid-view — drop first.
DROP RULE IF EXISTS "api_assets_insert" ON api.assets;
DROP RULE IF EXISTS "api_assets_update" ON api.assets;
DROP RULE IF EXISTS "api_assets_delete" ON api.assets;
DROP VIEW IF EXISTS api.assets;

CREATE VIEW api.assets
  WITH (security_invoker = true) AS
SELECT
  a.id,
  a.tenant_id,
  a.site_id,
  a.location_id,
  a.name,
  a.serial_number,
  a.asset_tag,
  a.status,
  a.metadata,
  a.asset_type_id,
  a.requires_calibration,
  a.calibration_due_on,
  a.blocks_dispatch_if_missing,
  a.created_at,
  a.updated_at,
  l.name AS location_name
FROM data.assets a
LEFT JOIN data.locations l ON l.id = a.location_id;

GRANT SELECT ON api.assets TO authenticated;

CREATE RULE "api_assets_insert" AS ON INSERT TO api.assets
  DO INSTEAD
  INSERT INTO data.assets (
    tenant_id, site_id, location_id, name,
    serial_number, asset_tag, status, metadata,
    asset_type_id, requires_calibration, calibration_due_on, blocks_dispatch_if_missing
  )
  VALUES (
    NEW.tenant_id,
    NEW.site_id,
    NEW.location_id,
    NEW.name,
    NEW.serial_number,
    NEW.asset_tag,
    COALESCE(NEW.status, 'operational'),
    NEW.metadata,
    NEW.asset_type_id,
    COALESCE(NEW.requires_calibration, false),
    NEW.calibration_due_on,
    COALESCE(NEW.blocks_dispatch_if_missing, false)
  );

CREATE RULE "api_assets_update" AS ON UPDATE TO api.assets
  DO INSTEAD
  UPDATE data.assets SET
    site_id = NEW.site_id,
    location_id = NEW.location_id,
    name = NEW.name,
    serial_number = NEW.serial_number,
    asset_tag = NEW.asset_tag,
    status = NEW.status,
    metadata = NEW.metadata,
    asset_type_id = NEW.asset_type_id,
    requires_calibration = COALESCE(NEW.requires_calibration, false),
    calibration_due_on = NEW.calibration_due_on,
    blocks_dispatch_if_missing = COALESCE(NEW.blocks_dispatch_if_missing, false),
    updated_at = now()
  WHERE id = OLD.id;

CREATE RULE "api_assets_delete" AS ON DELETE TO api.assets
  DO INSTEAD
  DELETE FROM data.assets WHERE id = OLD.id;

GRANT INSERT, UPDATE, DELETE ON api.assets TO authenticated;

COMMENT ON COLUMN data.assets.asset_type_id IS
  'EA-0: tipus d''actiu (EPI/vehicle/eina). NULL = actiu EAM clàssic de site.';
COMMENT ON COLUMN data.assets.blocks_dispatch_if_missing IS
  'EA-0: hint a nivell d''instància; el bloqueig real ve de asset_requirement_rules (EA-2).';

NOTIFY pgrst, 'reload schema';
