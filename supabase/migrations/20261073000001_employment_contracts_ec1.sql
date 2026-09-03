-- =============================================================================
-- M-EC-01 — Employment contracts (EHR-4 / EC-0..EC-2 mínim)
-- Model + RLS + overlap + get_effective. Firma/plantilles/assistència diferits.
-- signature_requirement default 'none' fins EC-5.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ─── Helpers ─────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.jwt_can_view_employment_contracts(
  p_tenant_id uuid,
  p_site_id   uuid DEFAULT NULL
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
    WHEN data.jwt_has_employee_permission(p_tenant_id, 'employees.contracts.view')
      THEN true
    WHEN data.jwt_has_employee_permission(p_tenant_id, 'employees.contracts.manage')
      THEN true
    WHEN data.jwt_has_employee_permission(p_tenant_id, 'employees.manage')
      THEN true
    WHEN p_site_id IS NOT NULL
      AND (
        data.jwt_has_employee_permission(p_tenant_id, 'employees.contracts.view', p_site_id)
        OR data.jwt_has_employee_permission(p_tenant_id, 'employees.contracts.manage', p_site_id)
        OR data.jwt_has_employee_permission(p_tenant_id, 'employees.manage', p_site_id)
      )
      THEN true
    ELSE false
  END;
$$;

CREATE OR REPLACE FUNCTION data.jwt_can_manage_employment_contracts(
  p_tenant_id uuid,
  p_site_id   uuid DEFAULT NULL
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
    WHEN data.jwt_has_employee_permission(p_tenant_id, 'employees.contracts.manage')
      THEN true
    WHEN data.jwt_has_employee_permission(p_tenant_id, 'employees.manage')
      THEN true
    WHEN p_site_id IS NOT NULL
      AND (
        data.jwt_has_employee_permission(p_tenant_id, 'employees.contracts.manage', p_site_id)
        OR data.jwt_has_employee_permission(p_tenant_id, 'employees.manage', p_site_id)
      )
      THEN true
    ELSE false
  END;
$$;

CREATE OR REPLACE FUNCTION data.jwt_can_view_employment_compensation(p_tenant_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT CASE
    WHEN (data.jwt_user_permissions() -> p_tenant_id::text -> 'global_permissions') @> '["*"]'::jsonb
      THEN true
    WHEN (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') = 'owner'
      THEN true
    WHEN data.jwt_has_employee_permission(p_tenant_id, 'employees.compensation.view')
      THEN true
    WHEN data.jwt_has_employee_permission(p_tenant_id, 'employees.compensation.edit')
      THEN true
    ELSE false
  END;
$$;

GRANT EXECUTE ON FUNCTION data.jwt_can_view_employment_contracts(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION data.jwt_can_manage_employment_contracts(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION data.jwt_can_view_employment_compensation(uuid) TO authenticated;

-- Sync permissions into get_role_permissions (manager gets contracts view/manage; not compensation)
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
    'employees.directory.view'
  ];
  v_member_base  text[] := ARRAY[
    'storage.upload', 'calendar.edit', 'email.send', 'invoices.edit',
    'attendance.punch_own', 'absences.request',
    'ai.use',
    'employees.directory.view', 'employees.view'
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
    'employees.contracts.view', 'employees.contracts.manage',
    'compliance.requirements.manage',
    'compliance.certifications.view', 'compliance.certifications.manage'
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

  RETURN (SELECT ARRAY(SELECT DISTINCT unnest(v_accumulated)));
END;
$$;

-- ─── Catalog: contract types ─────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS data.employment_contract_types (
  id                            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  code                          text,
  name                          text NOT NULL,
  is_indefinite                 boolean NOT NULL DEFAULT false,
  default_signature_requirement text NOT NULL DEFAULT 'none',
  is_active                     boolean NOT NULL DEFAULT true,
  metadata                      jsonb NOT NULL DEFAULT '{}',
  created_at                    timestamptz NOT NULL DEFAULT now(),
  updated_at                    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employment_contract_types_name_not_blank CHECK (btrim(name) <> ''),
  CONSTRAINT employment_contract_types_sig_req CHECK (
    default_signature_requirement IN ('none', 'employee_only', 'employer_only', 'employee_and_employer')
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_employment_contract_types_tenant_name
  ON data.employment_contract_types (tenant_id, lower(btrim(name)));

CREATE UNIQUE INDEX IF NOT EXISTS uq_employment_contract_types_tenant_code
  ON data.employment_contract_types (tenant_id, code)
  WHERE code IS NOT NULL AND btrim(code) <> '';

-- ─── employment_contracts ────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS data.employment_contracts (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                   uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id                 uuid NOT NULL REFERENCES data.employees(id) ON DELETE RESTRICT,

  contract_number             text,
  source                      text NOT NULL DEFAULT 'manual',
  external_reference          text,

  lifecycle_status            text NOT NULL DEFAULT 'draft',
  approval_status             text NOT NULL DEFAULT 'pending',
  signature_status            text NOT NULL DEFAULT 'not_required',
  signature_requirement       text NOT NULL DEFAULT 'none',
  is_primary                  boolean NOT NULL DEFAULT true,

  starts_on                   date NOT NULL,
  ends_on                     date,
  probation_ends_on           date,

  contract_type_id            uuid REFERENCES data.employment_contract_types(id) ON DELETE SET NULL,
  job_position_id             uuid REFERENCES data.job_positions(id) ON DELETE SET NULL,
  department_id               uuid REFERENCES data.departments(id) ON DELETE SET NULL,
  site_id                     uuid REFERENCES data.sites(id) ON DELETE SET NULL,
  calendar_group_id           uuid,

  weekly_hours                numeric(5,2),
  fte                         numeric(5,4),
  work_entry_source           text NOT NULL DEFAULT 'schedule',

  supersedes_contract_id      uuid REFERENCES data.employment_contracts(id) ON DELETE SET NULL,
  termination_reason_code     text,
  termination_notes           text,

  template_id                 uuid,
  template_locale_id          uuid,
  template_snapshot           jsonb NOT NULL DEFAULT '{}',
  variables_snapshot          jsonb NOT NULL DEFAULT '{}',
  generated_document_id       uuid,
  final_document_version_id   uuid,
  signing_submission_id       uuid,

  approved_by                 uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  approved_at                 timestamptz,
  fully_signed_at             timestamptz,
  activated_at                timestamptz,
  ended_at                    timestamptz,
  cancelled_at                timestamptz,
  cancellation_reason         text,

  created_by                  uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  metadata                    jsonb NOT NULL DEFAULT '{}',

  CONSTRAINT employment_contracts_dates CHECK (ends_on IS NULL OR ends_on >= starts_on),
  CONSTRAINT employment_contracts_probation CHECK (probation_ends_on IS NULL OR probation_ends_on >= starts_on),
  CONSTRAINT employment_contracts_hours CHECK (weekly_hours IS NULL OR weekly_hours >= 0),
  CONSTRAINT employment_contracts_fte CHECK (fte IS NULL OR (fte > 0 AND fte <= 1.5)),
  CONSTRAINT employment_contracts_no_self_supersede CHECK (supersedes_contract_id IS NULL OR supersedes_contract_id <> id),
  CONSTRAINT employment_contracts_lifecycle CHECK (
    lifecycle_status IN ('draft', 'scheduled', 'active', 'ended', 'cancelled')
  ),
  CONSTRAINT employment_contracts_approval CHECK (
    approval_status IN ('pending', 'approved', 'rejected', 'not_required')
  ),
  CONSTRAINT employment_contracts_signature CHECK (
    signature_status IN ('not_required', 'pending', 'partial', 'completed', 'rejected', 'expired')
  ),
  CONSTRAINT employment_contracts_sig_req CHECK (
    signature_requirement IN ('none', 'employee_only', 'employer_only', 'employee_and_employer')
  ),
  CONSTRAINT employment_contracts_work_entry CHECK (
    work_entry_source IN ('schedule', 'attendance', 'manual')
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_employment_contracts_tenant_number
  ON data.employment_contracts (tenant_id, contract_number)
  WHERE contract_number IS NOT NULL AND btrim(contract_number) <> '';

CREATE INDEX IF NOT EXISTS idx_employment_contracts_employee
  ON data.employment_contracts (tenant_id, employee_id, starts_on);

CREATE INDEX IF NOT EXISTS idx_employment_contracts_status
  ON data.employment_contracts (tenant_id, lifecycle_status);

-- No overlapping primary scheduled/active/ended intervals
ALTER TABLE data.employment_contracts
  DROP CONSTRAINT IF EXISTS employment_contracts_no_primary_overlap;

ALTER TABLE data.employment_contracts
  ADD CONSTRAINT employment_contracts_no_primary_overlap
  EXCLUDE USING gist (
    employee_id WITH =,
    daterange(
      starts_on,
      CASE WHEN ends_on IS NULL THEN NULL ELSE (ends_on + 1) END,
      '[)'
    ) WITH &&
  )
  WHERE (is_primary AND lifecycle_status IN ('scheduled', 'active', 'ended'));

COMMENT ON TABLE data.employment_contracts IS
  'Contractes laborals temporals. Compensació a taula separada. Firma multi-signant a EC-5.';

-- ─── Compensation (stricter RLS) ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS data.employment_contract_compensation (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  contract_id         uuid NOT NULL UNIQUE REFERENCES data.employment_contracts(id) ON DELETE CASCADE,
  currency            text NOT NULL DEFAULT 'EUR',
  gross_amount        numeric(12,2),
  pay_period          text NOT NULL DEFAULT 'monthly',
  annual_gross        numeric(14,2),
  employer_annual_cost numeric(14,2),
  effective_from      date,
  effective_to        date,
  metadata            jsonb NOT NULL DEFAULT '{}',
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employment_comp_pay_period CHECK (
    pay_period IN ('hourly', 'monthly', 'annual')
  )
);

-- ─── Tenant consistency ──────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.enforce_employment_contract_tenant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_emp data.employees%ROWTYPE;
BEGIN
  SELECT * INTO v_emp FROM data.employees WHERE id = NEW.employee_id;
  IF NOT FOUND OR v_emp.tenant_id <> NEW.tenant_id THEN
    RAISE EXCEPTION 'contract_employee_tenant_mismatch' USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF NEW.department_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM data.departments d WHERE d.id = NEW.department_id AND d.tenant_id = NEW.tenant_id
  ) THEN
    RAISE EXCEPTION 'contract_department_tenant_mismatch' USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF NEW.site_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM data.sites s WHERE s.id = NEW.site_id AND s.tenant_id = NEW.tenant_id
  ) THEN
    RAISE EXCEPTION 'contract_site_tenant_mismatch' USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF NEW.job_position_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM data.job_positions jp WHERE jp.id = NEW.job_position_id AND jp.tenant_id = NEW.tenant_id
  ) THEN
    RAISE EXCEPTION 'contract_job_position_tenant_mismatch' USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF NEW.contract_type_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM data.employment_contract_types t
    WHERE t.id = NEW.contract_type_id AND t.tenant_id = NEW.tenant_id
  ) THEN
    RAISE EXCEPTION 'contract_type_tenant_mismatch' USING ERRCODE = 'foreign_key_violation';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_employment_contracts_tenant ON data.employment_contracts;
CREATE TRIGGER trg_employment_contracts_tenant
  BEFORE INSERT OR UPDATE ON data.employment_contracts
  FOR EACH ROW EXECUTE FUNCTION data.enforce_employment_contract_tenant();

-- ─── RLS ─────────────────────────────────────────────────────────────────────

ALTER TABLE data.employment_contract_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.employment_contracts ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.employment_contract_compensation ENABLE ROW LEVEL SECURITY;

CREATE POLICY employment_contract_types_select ON data.employment_contract_types
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_can_view_employment_contracts(tenant_id, NULL)
  );

CREATE POLICY employment_contract_types_write ON data.employment_contract_types
  FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_can_manage_employment_contracts(tenant_id, NULL)
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_can_manage_employment_contracts(tenant_id, NULL)
  );

CREATE POLICY employment_contracts_select ON data.employment_contracts
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND EXISTS (
      SELECT 1 FROM data.employees e
      WHERE e.id = employee_id AND e.tenant_id = employment_contracts.tenant_id
        AND (
          data.jwt_can_view_employment_contracts(e.tenant_id, e.site_id)
          OR (e.user_id IS NOT NULL AND e.user_id = auth.uid()
              AND lifecycle_status IN ('scheduled', 'active', 'ended'))
        )
    )
  );

CREATE POLICY employment_contracts_insert ON data.employment_contracts
  FOR INSERT TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND EXISTS (
      SELECT 1 FROM data.employees e
      WHERE e.id = employee_id AND e.tenant_id = employment_contracts.tenant_id
        AND data.jwt_can_manage_employment_contracts(e.tenant_id, e.site_id)
    )
  );

CREATE POLICY employment_contracts_update ON data.employment_contracts
  FOR UPDATE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND EXISTS (
      SELECT 1 FROM data.employees e
      WHERE e.id = employee_id AND e.tenant_id = employment_contracts.tenant_id
        AND data.jwt_can_manage_employment_contracts(e.tenant_id, e.site_id)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM data.employees e
      WHERE e.id = employee_id AND e.tenant_id = employment_contracts.tenant_id
        AND data.jwt_can_manage_employment_contracts(e.tenant_id, e.site_id)
    )
  );

CREATE POLICY employment_contracts_delete ON data.employment_contracts
  FOR DELETE TO authenticated
  USING (
    lifecycle_status = 'draft'
    AND data.jwt_user_tenants() ? tenant_id::text
    AND EXISTS (
      SELECT 1 FROM data.employees e
      WHERE e.id = employee_id AND e.tenant_id = employment_contracts.tenant_id
        AND data.jwt_can_manage_employment_contracts(e.tenant_id, e.site_id)
    )
  );

CREATE POLICY employment_comp_select ON data.employment_contract_compensation
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_can_view_employment_compensation(tenant_id)
  );

CREATE POLICY employment_comp_write ON data.employment_contract_compensation
  FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_employee_permission(tenant_id, 'employees.compensation.edit')
      OR (data.jwt_user_permissions() -> tenant_id::text -> 'global_permissions') @> '["*"]'::jsonb
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') = 'owner'
    )
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_employee_permission(tenant_id, 'employees.compensation.edit')
      OR (data.jwt_user_permissions() -> tenant_id::text -> 'global_permissions') @> '["*"]'::jsonb
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') = 'owner'
    )
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON data.employment_contract_types TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.employment_contracts TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.employment_contract_compensation TO authenticated;

-- ─── API views ───────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW api.employment_contract_types
  WITH (security_invoker = true) AS
SELECT
  id, tenant_id, code, name, is_indefinite, default_signature_requirement,
  is_active, metadata, created_at, updated_at
FROM data.employment_contract_types;

CREATE OR REPLACE VIEW api.employment_contracts
  WITH (security_invoker = true) AS
SELECT
  id, tenant_id, employee_id, contract_number, source, external_reference,
  lifecycle_status, approval_status, signature_status, signature_requirement, is_primary,
  starts_on, ends_on, probation_ends_on,
  contract_type_id, job_position_id, department_id, site_id, calendar_group_id,
  weekly_hours, fte, work_entry_source,
  supersedes_contract_id, termination_reason_code, termination_notes,
  generated_document_id, signing_submission_id,
  approved_by, approved_at, fully_signed_at, activated_at, ended_at,
  cancelled_at, cancellation_reason,
  created_by, created_at, updated_at, metadata
FROM data.employment_contracts;

CREATE OR REPLACE VIEW api.employment_contract_compensation
  WITH (security_invoker = true, security_barrier = true) AS
SELECT
  id, tenant_id, contract_id, currency, gross_amount, pay_period,
  annual_gross, employer_annual_cost, effective_from, effective_to,
  metadata, created_at, updated_at
FROM data.employment_contract_compensation;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.employment_contract_types TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.employment_contracts TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.employment_contract_compensation TO authenticated;

-- ─── Effective contract resolver ─────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.get_effective_employment_contract(
  p_employee_id uuid,
  p_on date DEFAULT CURRENT_DATE
)
RETURNS api.employment_contracts
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_emp data.employees%ROWTYPE;
  v_out api.employment_contracts;
  v_on date := coalesce(p_on, CURRENT_DATE);
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

  IF NOT (
    data.jwt_can_view_employment_contracts(v_emp.tenant_id, v_emp.site_id)
    OR (v_emp.user_id IS NOT NULL AND v_emp.user_id = auth.uid())
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Prefer primary active/scheduled that covers the date (even if cron late: scheduled counts).
  -- SELECT from api view (same column set as RETURNS), not data.* (extra snapshot cols).
  SELECT c.* INTO v_out
  FROM api.employment_contracts c
  WHERE c.tenant_id = v_tenant_id
    AND c.employee_id = p_employee_id
    AND c.is_primary
    AND c.lifecycle_status IN ('active', 'scheduled', 'ended')
    AND c.starts_on <= v_on
    AND (c.ends_on IS NULL OR c.ends_on >= v_on)
  ORDER BY
    CASE c.lifecycle_status WHEN 'active' THEN 0 WHEN 'scheduled' THEN 1 ELSE 2 END,
    c.starts_on DESC
  LIMIT 1;

  RETURN v_out;
END;
$$;

REVOKE EXECUTE ON FUNCTION api.get_effective_employment_contract(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_effective_employment_contract(uuid, date) TO authenticated;

-- Transition lifecycle (simplified gates until EC-5)
CREATE OR REPLACE FUNCTION api.transition_employment_contract(
  p_contract_id uuid,
  p_to_status text,
  p_reason text DEFAULT NULL
)
RETURNS api.employment_contracts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_c data.employment_contracts%ROWTYPE;
  v_emp data.employees%ROWTYPE;
  v_out api.employment_contracts;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT * INTO v_c FROM data.employment_contracts WHERE id = p_contract_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'contract_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT * INTO v_emp FROM data.employees WHERE id = v_c.employee_id;
  IF NOT data.jwt_can_manage_employment_contracts(v_emp.tenant_id, v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_to_status = 'scheduled' THEN
    IF v_c.lifecycle_status <> 'draft' THEN
      RAISE EXCEPTION 'invalid_contract_transition' USING ERRCODE = 'check_violation';
    END IF;
    -- EC-5 will enforce signature; mínim: requirement none OR already completed
    IF v_c.signature_requirement <> 'none' AND v_c.signature_status <> 'completed' THEN
      RAISE EXCEPTION 'signature_required' USING ERRCODE = 'check_violation';
    END IF;
    UPDATE data.employment_contracts SET
      lifecycle_status = 'scheduled',
      approval_status = CASE WHEN approval_status = 'pending' THEN 'approved' ELSE approval_status END,
      approved_by = coalesce(approved_by, auth.uid()),
      approved_at = coalesce(approved_at, now()),
      updated_at = now()
    WHERE id = v_c.id;

  ELSIF p_to_status = 'active' THEN
    IF v_c.lifecycle_status NOT IN ('scheduled', 'draft') THEN
      RAISE EXCEPTION 'invalid_contract_transition' USING ERRCODE = 'check_violation';
    END IF;
    IF v_c.starts_on > CURRENT_DATE THEN
      RAISE EXCEPTION 'contract_not_started' USING ERRCODE = 'check_violation';
    END IF;
    UPDATE data.employment_contracts SET
      lifecycle_status = 'active',
      activated_at = coalesce(activated_at, now()),
      updated_at = now()
    WHERE id = v_c.id;

  ELSIF p_to_status = 'ended' THEN
    IF v_c.lifecycle_status NOT IN ('active', 'scheduled') THEN
      RAISE EXCEPTION 'invalid_contract_transition' USING ERRCODE = 'check_violation';
    END IF;
    UPDATE data.employment_contracts SET
      lifecycle_status = 'ended',
      ended_at = coalesce(ended_at, now()),
      ends_on = coalesce(ends_on, CURRENT_DATE),
      termination_notes = coalesce(p_reason, termination_notes),
      updated_at = now()
    WHERE id = v_c.id;

  ELSIF p_to_status = 'cancelled' THEN
    IF v_c.lifecycle_status IN ('ended', 'cancelled') THEN
      RAISE EXCEPTION 'invalid_contract_transition' USING ERRCODE = 'check_violation';
    END IF;
    UPDATE data.employment_contracts SET
      lifecycle_status = 'cancelled',
      cancelled_at = now(),
      cancellation_reason = p_reason,
      updated_at = now()
    WHERE id = v_c.id;

  ELSE
    RAISE EXCEPTION 'invalid_contract_status' USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_out FROM api.employment_contracts WHERE id = v_c.id;
  RETURN v_out;
END;
$$;

REVOKE EXECUTE ON FUNCTION api.transition_employment_contract(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.transition_employment_contract(uuid, text, text) TO authenticated;

-- Idempotent reconcile for one employee (scheduled→active, active→ended)
CREATE OR REPLACE FUNCTION api.reconcile_employment_contracts(
  p_employee_id uuid DEFAULT NULL,
  p_on date DEFAULT CURRENT_DATE
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_on date := coalesce(p_on, CURRENT_DATE);
  v_count int := 0;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  IF NOT data.jwt_can_manage_employment_contracts(v_tenant_id, NULL) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.employment_contracts c
  SET lifecycle_status = 'active',
      activated_at = coalesce(activated_at, now()),
      updated_at = now()
  WHERE c.tenant_id = v_tenant_id
    AND (p_employee_id IS NULL OR c.employee_id = p_employee_id)
    AND c.lifecycle_status = 'scheduled'
    AND c.starts_on <= v_on
    AND (c.ends_on IS NULL OR c.ends_on >= v_on);

  GET DIAGNOSTICS v_count = ROW_COUNT;

  UPDATE data.employment_contracts c
  SET lifecycle_status = 'ended',
      ended_at = coalesce(ended_at, now()),
      updated_at = now()
  WHERE c.tenant_id = v_tenant_id
    AND (p_employee_id IS NULL OR c.employee_id = p_employee_id)
    AND c.lifecycle_status = 'active'
    AND c.ends_on IS NOT NULL
    AND c.ends_on < v_on;

  RETURN v_count;
END;
$$;

REVOKE EXECUTE ON FUNCTION api.reconcile_employment_contracts(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.reconcile_employment_contracts(uuid, date) TO authenticated;

NOTIFY pgrst, 'reload schema';
