-- =============================================================================
-- M-EHR-05 — Employee private profiles (document + contacte privat)
-- IBAN / bank fields intentionally omitted until encryption decision.
-- employees.document_id remains a synced projection for portal identity gate.
-- =============================================================================

-- ─── Helper: manage private ──────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.jwt_can_manage_employee_private(
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
    WHEN data.jwt_has_employee_permission(p_tenant_id, 'employees.private.manage')
      THEN true
    WHEN data.jwt_has_employee_permission(p_tenant_id, 'employees.manage')
      THEN true
    WHEN p_site_id IS NOT NULL
      AND data.jwt_has_employee_permission(p_tenant_id, 'employees.private.manage', p_site_id)
      THEN true
    WHEN p_site_id IS NOT NULL
      AND data.jwt_has_employee_permission(p_tenant_id, 'employees.manage', p_site_id)
      THEN true
    ELSE false
  END;
$$;

GRANT EXECUTE ON FUNCTION data.jwt_can_manage_employee_private(uuid, uuid) TO authenticated;

-- ─── Table ───────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS data.employee_private_profiles (
  employee_id                     uuid PRIMARY KEY REFERENCES data.employees(id) ON DELETE CASCADE,
  tenant_id                       uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  personal_email                  text,
  personal_phone                  text,
  birth_date                      date,
  address                         text,
  postal_code                     text,
  city                            text,
  country_code                    text,
  nationality_code                text,
  document_type                   text,
  document_number                 text,
  social_security_number          text,
  emergency_contact_name          text,
  emergency_contact_phone         text,
  emergency_contact_relationship  text,
  metadata                        jsonb,
  created_at                      timestamptz NOT NULL DEFAULT now(),
  updated_at                      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_employee_private_profiles_tenant
  ON data.employee_private_profiles (tenant_id);

CREATE UNIQUE INDEX IF NOT EXISTS uq_employee_private_profiles_tenant_document
  ON data.employee_private_profiles (tenant_id, upper(btrim(document_number)))
  WHERE document_number IS NOT NULL AND btrim(document_number) <> '';

COMMENT ON TABLE data.employee_private_profiles IS
  'Dades personals sensibles 1:1 amb empleat. No exposades al directori. Sense IBAN en clar (EHR-3).';

COMMENT ON COLUMN data.employee_private_profiles.document_number IS
  'DNI/NIE/passaport. Font de veritat; employees.document_id és projecció per portal.';

-- ─── Backfill from employees.document_id / metadata ──────────────────────────

INSERT INTO data.employee_private_profiles (
  employee_id, tenant_id, document_number, metadata, created_at, updated_at
)
SELECT
  e.id,
  e.tenant_id,
  NULLIF(btrim(e.document_id), ''),
  e.metadata,
  coalesce(e.created_at, now()),
  now()
FROM data.employees e
WHERE NOT EXISTS (
  SELECT 1 FROM data.employee_private_profiles pp WHERE pp.employee_id = e.id
)
ON CONFLICT (employee_id) DO NOTHING;

-- ─── Ensure row on employee insert ───────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.ensure_employee_private_profile()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  INSERT INTO data.employee_private_profiles (employee_id, tenant_id, document_number, metadata)
  VALUES (NEW.id, NEW.tenant_id, NULLIF(btrim(NEW.document_id), ''), NEW.metadata)
  ON CONFLICT (employee_id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_employees_ensure_private_profile ON data.employees;
CREATE TRIGGER trg_employees_ensure_private_profile
  AFTER INSERT ON data.employees
  FOR EACH ROW
  EXECUTE FUNCTION data.ensure_employee_private_profile();

-- ─── Sync document_number ↔ employees.document_id ────────────────────────────

CREATE OR REPLACE FUNCTION data.sync_private_document_to_employee()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF current_setting('data.skip_private_document_sync', true) = '1' THEN
    RETURN NEW;
  END IF;
  PERFORM set_config('data.skip_private_document_sync', '1', true);
  UPDATE data.employees
  SET document_id = NEW.document_number,
      metadata = coalesce(NEW.metadata, metadata),
      updated_at = now()
  WHERE id = NEW.employee_id
    AND (
      document_id IS DISTINCT FROM NEW.document_number
      OR (NEW.metadata IS NOT NULL AND metadata IS DISTINCT FROM NEW.metadata)
    );
  PERFORM set_config('data.skip_private_document_sync', '0', true);
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_private_document_to_employee ON data.employee_private_profiles;
CREATE TRIGGER trg_private_document_to_employee
  BEFORE INSERT OR UPDATE OF document_number, metadata ON data.employee_private_profiles
  FOR EACH ROW
  EXECUTE FUNCTION data.sync_private_document_to_employee();

CREATE OR REPLACE FUNCTION data.sync_employee_document_to_private()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF current_setting('data.skip_private_document_sync', true) = '1' THEN
    RETURN NEW;
  END IF;
  IF NEW.document_id IS NOT DISTINCT FROM OLD.document_id
     AND NEW.metadata IS NOT DISTINCT FROM OLD.metadata THEN
    RETURN NEW;
  END IF;
  PERFORM set_config('data.skip_private_document_sync', '1', true);
  INSERT INTO data.employee_private_profiles (employee_id, tenant_id, document_number, metadata)
  VALUES (NEW.id, NEW.tenant_id, NULLIF(btrim(NEW.document_id), ''), NEW.metadata)
  ON CONFLICT (employee_id) DO UPDATE
  SET document_number = EXCLUDED.document_number,
      metadata = coalesce(EXCLUDED.metadata, data.employee_private_profiles.metadata),
      updated_at = now();
  PERFORM set_config('data.skip_private_document_sync', '0', true);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_employee_document_to_private ON data.employees;
CREATE TRIGGER trg_employee_document_to_private
  AFTER UPDATE OF document_id, metadata ON data.employees
  FOR EACH ROW
  EXECUTE FUNCTION data.sync_employee_document_to_private();

-- Tenant consistency
CREATE OR REPLACE FUNCTION data.enforce_private_profile_tenant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM data.employees e
    WHERE e.id = NEW.employee_id AND e.tenant_id = NEW.tenant_id
  ) THEN
    RAISE EXCEPTION 'private_profile_tenant_mismatch' USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_private_profile_tenant ON data.employee_private_profiles;
CREATE TRIGGER trg_private_profile_tenant
  BEFORE INSERT OR UPDATE ON data.employee_private_profiles
  FOR EACH ROW
  EXECUTE FUNCTION data.enforce_private_profile_tenant();

-- ─── RLS ─────────────────────────────────────────────────────────────────────

ALTER TABLE data.employee_private_profiles ENABLE ROW LEVEL SECURITY;

-- No grants for direct table DML to authenticated (RPC + view only)
REVOKE ALL ON data.employee_private_profiles FROM PUBLIC;
REVOKE ALL ON data.employee_private_profiles FROM authenticated;
GRANT SELECT, INSERT, UPDATE ON data.employee_private_profiles TO service_role;

-- Policies still useful for SECURITY INVOKER views / future; deny by default
DROP POLICY IF EXISTS employee_private_profiles_select ON data.employee_private_profiles;
CREATE POLICY employee_private_profiles_select ON data.employee_private_profiles
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND EXISTS (
      SELECT 1 FROM data.employees e
      WHERE e.id = employee_id
        AND e.tenant_id = employee_private_profiles.tenant_id
        AND data.jwt_can_view_employee_private(e.tenant_id, e.site_id, e.user_id)
    )
  );

DROP POLICY IF EXISTS employee_private_profiles_insert ON data.employee_private_profiles;
CREATE POLICY employee_private_profiles_insert ON data.employee_private_profiles
  FOR INSERT TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND EXISTS (
      SELECT 1 FROM data.employees e
      WHERE e.id = employee_id
        AND e.tenant_id = employee_private_profiles.tenant_id
        AND data.jwt_can_manage_employee_private(e.tenant_id, e.site_id)
    )
  );

DROP POLICY IF EXISTS employee_private_profiles_update ON data.employee_private_profiles;
CREATE POLICY employee_private_profiles_update ON data.employee_private_profiles
  FOR UPDATE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND EXISTS (
      SELECT 1 FROM data.employees e
      WHERE e.id = employee_id
        AND e.tenant_id = employee_private_profiles.tenant_id
        AND (
          data.jwt_can_manage_employee_private(e.tenant_id, e.site_id)
          OR (e.user_id IS NOT NULL AND e.user_id = auth.uid())
        )
    )
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND EXISTS (
      SELECT 1 FROM data.employees e
      WHERE e.id = employee_id
        AND e.tenant_id = employee_private_profiles.tenant_id
        AND (
          data.jwt_can_manage_employee_private(e.tenant_id, e.site_id)
          OR (e.user_id IS NOT NULL AND e.user_id = auth.uid())
        )
    )
  );

-- Allow authenticated SELECT via RLS for view; writes via SECURITY DEFINER RPCs
GRANT SELECT ON data.employee_private_profiles TO authenticated;

-- ─── API view (HR only via RLS) ──────────────────────────────────────────────

CREATE OR REPLACE VIEW api.employee_private_profiles
  WITH (security_invoker = true, security_barrier = true) AS
SELECT
  employee_id,
  tenant_id,
  personal_email,
  personal_phone,
  birth_date,
  address,
  postal_code,
  city,
  country_code,
  nationality_code,
  document_type,
  document_number,
  social_security_number,
  emergency_contact_name,
  emergency_contact_phone,
  emergency_contact_relationship,
  metadata,
  created_at,
  updated_at
FROM data.employee_private_profiles;

GRANT SELECT ON api.employee_private_profiles TO authenticated;

-- Compat: employee_hr_profiles still exposes document_id (from private SoT)
DROP VIEW IF EXISTS api.employee_hr_profiles CASCADE;
CREATE VIEW api.employee_hr_profiles
  WITH (security_invoker = true, security_barrier = true) AS
SELECT
  e.id,
  e.tenant_id,
  coalesce(pp.document_number, e.document_id) AS document_id,
  coalesce(pp.metadata, e.metadata) AS metadata,
  e.created_at,
  e.updated_at
FROM data.employees e
LEFT JOIN data.employee_private_profiles pp ON pp.employee_id = e.id
WHERE data.jwt_can_view_employee_private(e.tenant_id, e.site_id, e.user_id);

GRANT SELECT, UPDATE ON api.employee_hr_profiles TO authenticated;

-- INSTEAD OF UPDATE → private profile (keeps old frontend working)
CREATE OR REPLACE FUNCTION api.employee_hr_profiles_instead_of_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_emp data.employees%ROWTYPE;
BEGIN
  SELECT * INTO v_emp FROM data.employees WHERE id = OLD.id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF NOT data.jwt_can_manage_employee_private(v_emp.tenant_id, v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  INSERT INTO data.employee_private_profiles (employee_id, tenant_id, document_number, metadata)
  VALUES (
    v_emp.id,
    v_emp.tenant_id,
    NULLIF(btrim(NEW.document_id), ''),
    NEW.metadata
  )
  ON CONFLICT (employee_id) DO UPDATE
  SET document_number = EXCLUDED.document_number,
      metadata = EXCLUDED.metadata,
      updated_at = now();

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_employee_hr_profiles_upd ON api.employee_hr_profiles;
CREATE TRIGGER trg_employee_hr_profiles_upd
  INSTEAD OF UPDATE ON api.employee_hr_profiles
  FOR EACH ROW
  EXECUTE FUNCTION api.employee_hr_profiles_instead_of_update();

-- ─── RPCs ────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.get_employee_private_profile(p_employee_id uuid)
RETURNS api.employee_private_profiles
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_emp data.employees%ROWTYPE;
  v_row data.employee_private_profiles%ROWTYPE;
  v_out api.employee_private_profiles;
  v_is_self boolean;
  v_can_hr boolean;
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

  IF NOT data.jwt_can_view_employee_private(v_emp.tenant_id, v_emp.site_id, v_emp.user_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_is_self := v_emp.user_id IS NOT NULL AND v_emp.user_id = auth.uid();
  v_can_hr := data.jwt_can_manage_employee_private(v_emp.tenant_id, v_emp.site_id)
    OR data.jwt_has_employee_permission(v_emp.tenant_id, 'employees.private.view')
    OR (v_emp.site_id IS NOT NULL AND data.jwt_has_employee_permission(v_emp.tenant_id, 'employees.private.view', v_emp.site_id))
    OR (data.jwt_user_tenants() -> v_emp.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    OR (data.jwt_user_permissions() -> v_emp.tenant_id::text -> 'global_permissions') @> '["*"]'::jsonb;

  INSERT INTO data.employee_private_profiles (employee_id, tenant_id)
  VALUES (v_emp.id, v_emp.tenant_id)
  ON CONFLICT (employee_id) DO NOTHING;

  SELECT * INTO v_row
  FROM data.employee_private_profiles
  WHERE employee_id = v_emp.id;

  v_out.employee_id := v_row.employee_id;
  v_out.tenant_id := v_row.tenant_id;
  v_out.personal_email := v_row.personal_email;
  v_out.personal_phone := v_row.personal_phone;
  v_out.birth_date := v_row.birth_date;
  v_out.address := v_row.address;
  v_out.postal_code := v_row.postal_code;
  v_out.city := v_row.city;
  v_out.country_code := v_row.country_code;
  v_out.nationality_code := v_row.nationality_code;
  v_out.document_type := v_row.document_type;
  v_out.document_number := v_row.document_number;
  v_out.social_security_number := v_row.social_security_number;
  v_out.emergency_contact_name := v_row.emergency_contact_name;
  v_out.emergency_contact_phone := v_row.emergency_contact_phone;
  v_out.emergency_contact_relationship := v_row.emergency_contact_relationship;
  v_out.metadata := v_row.metadata;
  v_out.created_at := v_row.created_at;
  v_out.updated_at := v_row.updated_at;

  -- Self without HR private access: redact highly sensitive fields
  IF v_is_self AND NOT v_can_hr THEN
    v_out.document_number := NULL;
    v_out.document_type := NULL;
    v_out.social_security_number := NULL;
    v_out.birth_date := NULL;
    v_out.nationality_code := NULL;
    v_out.metadata := NULL;
  END IF;

  RETURN v_out;
END;
$$;

REVOKE EXECUTE ON FUNCTION api.get_employee_private_profile(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_employee_private_profile(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION api.upsert_employee_private_profile(
  p_employee_id uuid,
  p_personal_email text DEFAULT NULL,
  p_personal_phone text DEFAULT NULL,
  p_birth_date date DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_postal_code text DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_country_code text DEFAULT NULL,
  p_nationality_code text DEFAULT NULL,
  p_document_type text DEFAULT NULL,
  p_document_number text DEFAULT NULL,
  p_social_security_number text DEFAULT NULL,
  p_emergency_contact_name text DEFAULT NULL,
  p_emergency_contact_phone text DEFAULT NULL,
  p_emergency_contact_relationship text DEFAULT NULL,
  p_metadata jsonb DEFAULT NULL,
  p_clear_nulls boolean DEFAULT false
)
RETURNS api.employee_private_profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_emp data.employees%ROWTYPE;
  v_is_self boolean;
  v_can_hr boolean;
  v_out api.employee_private_profiles;
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

  v_is_self := v_emp.user_id IS NOT NULL AND v_emp.user_id = auth.uid();
  v_can_hr := data.jwt_can_manage_employee_private(v_emp.tenant_id, v_emp.site_id);

  IF NOT v_can_hr AND NOT v_is_self THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Self-service: only contact + emergency (no document / SSN / birth)
  IF v_is_self AND NOT v_can_hr THEN
    INSERT INTO data.employee_private_profiles AS pp (
      employee_id, tenant_id,
      personal_email, personal_phone,
      emergency_contact_name, emergency_contact_phone, emergency_contact_relationship
    ) VALUES (
      v_emp.id, v_emp.tenant_id,
      NULLIF(btrim(p_personal_email), ''),
      NULLIF(btrim(p_personal_phone), ''),
      NULLIF(btrim(p_emergency_contact_name), ''),
      NULLIF(btrim(p_emergency_contact_phone), ''),
      NULLIF(btrim(p_emergency_contact_relationship), '')
    )
    ON CONFLICT (employee_id) DO UPDATE SET
      personal_email = CASE WHEN p_clear_nulls OR p_personal_email IS NOT NULL
        THEN NULLIF(btrim(p_personal_email), '') ELSE pp.personal_email END,
      personal_phone = CASE WHEN p_clear_nulls OR p_personal_phone IS NOT NULL
        THEN NULLIF(btrim(p_personal_phone), '') ELSE pp.personal_phone END,
      emergency_contact_name = CASE WHEN p_clear_nulls OR p_emergency_contact_name IS NOT NULL
        THEN NULLIF(btrim(p_emergency_contact_name), '') ELSE pp.emergency_contact_name END,
      emergency_contact_phone = CASE WHEN p_clear_nulls OR p_emergency_contact_phone IS NOT NULL
        THEN NULLIF(btrim(p_emergency_contact_phone), '') ELSE pp.emergency_contact_phone END,
      emergency_contact_relationship = CASE WHEN p_clear_nulls OR p_emergency_contact_relationship IS NOT NULL
        THEN NULLIF(btrim(p_emergency_contact_relationship), '') ELSE pp.emergency_contact_relationship END,
      updated_at = now();
  ELSE
    INSERT INTO data.employee_private_profiles AS pp (
      employee_id, tenant_id,
      personal_email, personal_phone, birth_date,
      address, postal_code, city, country_code, nationality_code,
      document_type, document_number, social_security_number,
      emergency_contact_name, emergency_contact_phone, emergency_contact_relationship,
      metadata
    ) VALUES (
      v_emp.id, v_emp.tenant_id,
      NULLIF(btrim(p_personal_email), ''),
      NULLIF(btrim(p_personal_phone), ''),
      p_birth_date,
      NULLIF(btrim(p_address), ''),
      NULLIF(btrim(p_postal_code), ''),
      NULLIF(btrim(p_city), ''),
      NULLIF(btrim(p_country_code), ''),
      NULLIF(btrim(p_nationality_code), ''),
      NULLIF(btrim(p_document_type), ''),
      NULLIF(btrim(p_document_number), ''),
      NULLIF(btrim(p_social_security_number), ''),
      NULLIF(btrim(p_emergency_contact_name), ''),
      NULLIF(btrim(p_emergency_contact_phone), ''),
      NULLIF(btrim(p_emergency_contact_relationship), ''),
      p_metadata
    )
    ON CONFLICT (employee_id) DO UPDATE SET
      personal_email = CASE WHEN p_clear_nulls OR p_personal_email IS NOT NULL
        THEN NULLIF(btrim(p_personal_email), '') ELSE pp.personal_email END,
      personal_phone = CASE WHEN p_clear_nulls OR p_personal_phone IS NOT NULL
        THEN NULLIF(btrim(p_personal_phone), '') ELSE pp.personal_phone END,
      birth_date = CASE WHEN p_clear_nulls OR p_birth_date IS NOT NULL
        THEN p_birth_date ELSE pp.birth_date END,
      address = CASE WHEN p_clear_nulls OR p_address IS NOT NULL
        THEN NULLIF(btrim(p_address), '') ELSE pp.address END,
      postal_code = CASE WHEN p_clear_nulls OR p_postal_code IS NOT NULL
        THEN NULLIF(btrim(p_postal_code), '') ELSE pp.postal_code END,
      city = CASE WHEN p_clear_nulls OR p_city IS NOT NULL
        THEN NULLIF(btrim(p_city), '') ELSE pp.city END,
      country_code = CASE WHEN p_clear_nulls OR p_country_code IS NOT NULL
        THEN NULLIF(btrim(p_country_code), '') ELSE pp.country_code END,
      nationality_code = CASE WHEN p_clear_nulls OR p_nationality_code IS NOT NULL
        THEN NULLIF(btrim(p_nationality_code), '') ELSE pp.nationality_code END,
      document_type = CASE WHEN p_clear_nulls OR p_document_type IS NOT NULL
        THEN NULLIF(btrim(p_document_type), '') ELSE pp.document_type END,
      document_number = CASE WHEN p_clear_nulls OR p_document_number IS NOT NULL
        THEN NULLIF(btrim(p_document_number), '') ELSE pp.document_number END,
      social_security_number = CASE WHEN p_clear_nulls OR p_social_security_number IS NOT NULL
        THEN NULLIF(btrim(p_social_security_number), '') ELSE pp.social_security_number END,
      emergency_contact_name = CASE WHEN p_clear_nulls OR p_emergency_contact_name IS NOT NULL
        THEN NULLIF(btrim(p_emergency_contact_name), '') ELSE pp.emergency_contact_name END,
      emergency_contact_phone = CASE WHEN p_clear_nulls OR p_emergency_contact_phone IS NOT NULL
        THEN NULLIF(btrim(p_emergency_contact_phone), '') ELSE pp.emergency_contact_phone END,
      emergency_contact_relationship = CASE WHEN p_clear_nulls OR p_emergency_contact_relationship IS NOT NULL
        THEN NULLIF(btrim(p_emergency_contact_relationship), '') ELSE pp.emergency_contact_relationship END,
      metadata = CASE WHEN p_clear_nulls OR p_metadata IS NOT NULL
        THEN p_metadata ELSE pp.metadata END,
      updated_at = now();
  END IF;

  SELECT * INTO v_out FROM api.employee_private_profiles WHERE employee_id = v_emp.id;
  RETURN v_out;
END;
$$;

REVOKE EXECUTE ON FUNCTION api.upsert_employee_private_profile(
  uuid, text, text, date, text, text, text, text, text, text, text, text, text, text, text, jsonb, boolean
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.upsert_employee_private_profile(
  uuid, text, text, date, text, text, text, text, text, text, text, text, text, text, text, jsonb, boolean
) TO authenticated;

NOTIFY pgrst, 'reload schema';
