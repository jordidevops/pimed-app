-- EC-WFM P1: §7 workload terms, §8 leave terms + grants, §9 placement periods
-- Updates resolve_employee_work_context → ec_wfm_p1_v1
-- Depends on: 20261099000001 (P0 convenio/snapshots), EC1 (btree_gist, employment_contracts)

BEGIN;

-- =============================================================================
-- §7 - employment_contract_workload_terms (1:1)
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.employment_contract_workload_terms (
  id                               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                        uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  contract_id                      uuid NOT NULL UNIQUE
    REFERENCES data.employment_contracts(id) ON DELETE CASCADE,
  commitment_basis                 text NOT NULL DEFAULT 'week',
  ordinary_commitment_minutes      integer NOT NULL,
  complementary_commitment_minutes integer NOT NULL DEFAULT 0,
  fte_ratio                        numeric,
  source                           text NOT NULL DEFAULT 'manual',
  metadata                         jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at                       timestamptz NOT NULL DEFAULT now(),
  updated_at                       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employment_workload_basis_check CHECK (
    commitment_basis IN ('day', 'week', 'year')
  ),
  CONSTRAINT employment_workload_ordinary_nonneg CHECK (ordinary_commitment_minutes >= 0),
  CONSTRAINT employment_workload_complementary_nonneg CHECK (complementary_commitment_minutes >= 0)
);

CREATE INDEX IF NOT EXISTS idx_employment_workload_terms_tenant
  ON data.employment_contract_workload_terms (tenant_id);

CREATE OR REPLACE FUNCTION data.enforce_employment_workload_terms()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_contract data.employment_contracts%ROWTYPE;
  v_hours numeric(5,2);
BEGIN
  SELECT * INTO v_contract
  FROM data.employment_contracts
  WHERE id = NEW.contract_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'workload_terms_contract_not_found'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF v_contract.tenant_id IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'workload_terms_tenant_mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Draft/scheduled only: project week basis onto contract.weekly_hours (immutable when active).
  IF NEW.commitment_basis = 'week'
     AND v_contract.lifecycle_status IN ('draft', 'scheduled') THEN
    v_hours := round(NEW.ordinary_commitment_minutes / 60.0, 2)::numeric(5,2);
    UPDATE data.employment_contracts
    SET weekly_hours = v_hours
    WHERE id = NEW.contract_id
      AND weekly_hours IS DISTINCT FROM v_hours;
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_employment_workload_terms
  ON data.employment_contract_workload_terms;
CREATE TRIGGER trg_enforce_employment_workload_terms
  BEFORE INSERT OR UPDATE ON data.employment_contract_workload_terms
  FOR EACH ROW EXECUTE FUNCTION data.enforce_employment_workload_terms();

DROP TRIGGER IF EXISTS trg_set_updated_at_employment_workload_terms
  ON data.employment_contract_workload_terms;
CREATE TRIGGER trg_set_updated_at_employment_workload_terms
  BEFORE UPDATE ON data.employment_contract_workload_terms
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

ALTER TABLE data.employment_contract_workload_terms ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS employment_workload_terms_select ON data.employment_contract_workload_terms;
CREATE POLICY employment_workload_terms_select ON data.employment_contract_workload_terms
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_can_view_employment_contracts(tenant_id, NULL)
  );

DROP POLICY IF EXISTS employment_workload_terms_write ON data.employment_contract_workload_terms;
CREATE POLICY employment_workload_terms_write ON data.employment_contract_workload_terms
  FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_can_manage_employment_contracts(tenant_id, NULL)
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_can_manage_employment_contracts(tenant_id, NULL)
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON data.employment_contract_workload_terms TO authenticated;

CREATE OR REPLACE VIEW api.employment_contract_workload_terms
  WITH (security_invoker = true, security_barrier = true) AS
SELECT
  id, tenant_id, contract_id, commitment_basis,
  ordinary_commitment_minutes, complementary_commitment_minutes,
  fte_ratio, source, metadata, created_at, updated_at
FROM data.employment_contract_workload_terms;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.employment_contract_workload_terms TO authenticated;

-- =============================================================================
-- §8 - employment_contract_leave_terms (1:1)
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.employment_contract_leave_terms (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  contract_id        uuid NOT NULL UNIQUE
    REFERENCES data.employment_contracts(id) ON DELETE CASCADE,
  paid_leave_allowance numeric NOT NULL,
  allowance_unit     text NOT NULL DEFAULT 'days',
  counting_method    text NOT NULL DEFAULT 'working_days',
  proration_method   text NOT NULL DEFAULT 'calendar_ratio',
  metadata           jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employment_leave_allowance_nonneg CHECK (paid_leave_allowance >= 0),
  CONSTRAINT employment_leave_unit_check CHECK (allowance_unit IN ('days', 'minutes')),
  CONSTRAINT employment_leave_counting_check CHECK (
    counting_method IN ('working_days', 'calendar_days')
  ),
  CONSTRAINT employment_leave_proration_check CHECK (
    proration_method IN ('calendar_ratio', 'baseline_weighted', 'none')
  )
);

CREATE INDEX IF NOT EXISTS idx_employment_leave_terms_tenant
  ON data.employment_contract_leave_terms (tenant_id);

CREATE OR REPLACE FUNCTION data.enforce_employment_leave_terms_tenant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM data.employment_contracts c
    WHERE c.id = NEW.contract_id AND c.tenant_id = NEW.tenant_id
  ) THEN
    RAISE EXCEPTION 'leave_terms_tenant_mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_employment_leave_terms_tenant
  ON data.employment_contract_leave_terms;
CREATE TRIGGER trg_enforce_employment_leave_terms_tenant
  BEFORE INSERT OR UPDATE ON data.employment_contract_leave_terms
  FOR EACH ROW EXECUTE FUNCTION data.enforce_employment_leave_terms_tenant();

DROP TRIGGER IF EXISTS trg_set_updated_at_employment_leave_terms
  ON data.employment_contract_leave_terms;
CREATE TRIGGER trg_set_updated_at_employment_leave_terms
  BEFORE UPDATE ON data.employment_contract_leave_terms
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

ALTER TABLE data.employment_contract_leave_terms ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS employment_leave_terms_select ON data.employment_contract_leave_terms;
CREATE POLICY employment_leave_terms_select ON data.employment_contract_leave_terms
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_can_view_employment_contracts(tenant_id, NULL)
  );

DROP POLICY IF EXISTS employment_leave_terms_write ON data.employment_contract_leave_terms;
CREATE POLICY employment_leave_terms_write ON data.employment_contract_leave_terms
  FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_can_manage_employment_contracts(tenant_id, NULL)
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_can_manage_employment_contracts(tenant_id, NULL)
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON data.employment_contract_leave_terms TO authenticated;

CREATE OR REPLACE VIEW api.employment_contract_leave_terms
  WITH (security_invoker = true, security_barrier = true) AS
SELECT
  id, tenant_id, contract_id, paid_leave_allowance, allowance_unit,
  counting_method, proration_method, metadata, created_at, updated_at
FROM data.employment_contract_leave_terms;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.employment_contract_leave_terms TO authenticated;

-- =============================================================================
-- §8 - leave_entitlement_grants (append-only)
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.leave_entitlement_grants (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id      uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  contract_id      uuid REFERENCES data.employment_contracts(id) ON DELETE SET NULL,
  leave_type       text NOT NULL DEFAULT 'vacation',
  period_year      integer NOT NULL,
  period_start     date,
  period_end       date,
  quantity         numeric NOT NULL,
  unit             text NOT NULL DEFAULT 'days',
  reason           text,
  source_event     text NOT NULL,
  idempotency_key  text NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid,
  CONSTRAINT leave_grants_unit_check CHECK (unit IN ('days', 'minutes')),
  CONSTRAINT leave_grants_tenant_idempotency UNIQUE (tenant_id, idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_leave_entitlement_grants_employee
  ON data.leave_entitlement_grants (tenant_id, employee_id, period_year);

CREATE INDEX IF NOT EXISTS idx_leave_entitlement_grants_contract
  ON data.leave_entitlement_grants (contract_id)
  WHERE contract_id IS NOT NULL;

CREATE OR REPLACE FUNCTION data.trg_leave_entitlement_grants_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'leave_grant_immutable'
    USING ERRCODE = 'check_violation',
          HINT = 'leave_entitlement_grants are append-only; insert an adjustment grant instead.';
END;
$$;

DROP TRIGGER IF EXISTS trg_leave_entitlement_grants_immutable
  ON data.leave_entitlement_grants;
CREATE TRIGGER trg_leave_entitlement_grants_immutable
  BEFORE UPDATE OR DELETE ON data.leave_entitlement_grants
  FOR EACH ROW EXECUTE FUNCTION data.trg_leave_entitlement_grants_immutable();

ALTER TABLE data.leave_entitlement_grants ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS leave_entitlement_grants_select ON data.leave_entitlement_grants;
CREATE POLICY leave_entitlement_grants_select ON data.leave_entitlement_grants
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_can_view_employment_contracts(tenant_id, NULL)
  );

DROP POLICY IF EXISTS leave_entitlement_grants_insert ON data.leave_entitlement_grants;
CREATE POLICY leave_entitlement_grants_insert ON data.leave_entitlement_grants
  FOR INSERT TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_can_manage_employment_contracts(tenant_id, NULL)
  );

-- No UPDATE/DELETE policies (append-only + immutability trigger)

GRANT SELECT, INSERT ON data.leave_entitlement_grants TO authenticated;
REVOKE UPDATE, DELETE ON data.leave_entitlement_grants FROM authenticated;

CREATE OR REPLACE VIEW api.leave_entitlement_grants
  WITH (security_invoker = true, security_barrier = true) AS
SELECT
  id, tenant_id, employee_id, contract_id, leave_type,
  period_year, period_start, period_end, quantity, unit,
  reason, source_event, idempotency_key, created_at, created_by
FROM data.leave_entitlement_grants;

GRANT SELECT, INSERT ON api.leave_entitlement_grants TO authenticated;

-- =============================================================================
-- §8 - generate leave grant on contract activation
-- =============================================================================

CREATE OR REPLACE FUNCTION data.generate_leave_grant_for_contract_activation(
  p_contract_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_c data.employment_contracts%ROWTYPE;
  v_lt data.employment_contract_leave_terms%ROWTYPE;
  v_year int;
  v_year_start date;
  v_year_end date;
  v_from date;
  v_to date;
  v_overlap int;
  v_days_in_year int;
  v_quantity numeric;
  v_key text;
  v_id uuid;
BEGIN
  SELECT * INTO v_c FROM data.employment_contracts WHERE id = p_contract_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_lt
  FROM data.employment_contract_leave_terms
  WHERE contract_id = p_contract_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  v_year := EXTRACT(YEAR FROM v_c.starts_on)::int;
  v_year_start := make_date(v_year, 1, 1);
  v_year_end := make_date(v_year, 12, 31);
  v_days_in_year := (v_year_end - v_year_start) + 1;

  v_from := greatest(v_c.starts_on, v_year_start);
  v_to := least(coalesce(v_c.ends_on, v_year_end), v_year_end);

  IF v_to < v_from THEN
    v_overlap := 0;
  ELSE
    v_overlap := (v_to - v_from) + 1;
  END IF;

  IF v_lt.proration_method = 'none' THEN
    v_quantity := v_lt.paid_leave_allowance;
  ELSE
    -- calendar_ratio and baseline_weighted (P1 treats baseline_weighted as calendar_ratio)
    IF v_days_in_year <= 0 THEN
      v_quantity := 0;
    ELSE
      v_quantity := v_lt.paid_leave_allowance * (v_overlap::numeric / v_days_in_year::numeric);
    END IF;
  END IF;

  v_key := p_contract_id::text || ':activate:' || v_year::text;

  INSERT INTO data.leave_entitlement_grants (
    tenant_id, employee_id, contract_id, leave_type,
    period_year, period_start, period_end,
    quantity, unit, reason, source_event, idempotency_key, created_by
  ) VALUES (
    v_c.tenant_id, v_c.employee_id, v_c.id, 'vacation',
    v_year, v_year_start, v_year_end,
    v_quantity, v_lt.allowance_unit,
    'Contract activation leave grant',
    'contract_activated',
    v_key,
    auth.uid()
  )
  ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT g.id INTO v_id
    FROM data.leave_entitlement_grants g
    WHERE g.tenant_id = v_c.tenant_id AND g.idempotency_key = v_key;
  END IF;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION data.generate_leave_grant_for_contract_activation(uuid) IS
  'EC-WFM P1 §8: idempotent leave grant on contract activation (calendar_ratio / none).';

GRANT EXECUTE ON FUNCTION data.generate_leave_grant_for_contract_activation(uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.trg_employment_contract_activate_leave_grant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF NEW.lifecycle_status = 'active'
     AND OLD.lifecycle_status IS DISTINCT FROM 'active' THEN
    PERFORM data.generate_leave_grant_for_contract_activation(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_employment_contract_activate_leave_grant
  ON data.employment_contracts;
CREATE TRIGGER trg_employment_contract_activate_leave_grant
  AFTER UPDATE OF lifecycle_status ON data.employment_contracts
  FOR EACH ROW EXECUTE FUNCTION data.trg_employment_contract_activate_leave_grant();

-- =============================================================================
-- §9 - employee_placement_periods
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.employee_placement_periods (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id     uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  site_id         uuid NOT NULL REFERENCES data.sites(id),
  department_id   uuid REFERENCES data.departments(id),
  job_position_id uuid REFERENCES data.job_positions(id),
  starts_on       date NOT NULL,
  ends_on         date,
  source          text NOT NULL DEFAULT 'manual',
  reason          text,
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  created_by      uuid,
  CONSTRAINT employee_placement_half_open CHECK (
    ends_on IS NULL OR ends_on > starts_on
  ),
  CONSTRAINT employee_placement_no_overlap EXCLUDE USING gist (
    employee_id WITH =,
    daterange(starts_on, coalesce(ends_on, 'infinity'::date), '[)') WITH &&
  )
);

CREATE INDEX IF NOT EXISTS idx_employee_placement_periods_employee
  ON data.employee_placement_periods (tenant_id, employee_id, starts_on);

CREATE INDEX IF NOT EXISTS idx_employee_placement_periods_site
  ON data.employee_placement_periods (tenant_id, site_id);

CREATE OR REPLACE FUNCTION data.enforce_employee_placement_tenant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_emp data.employees%ROWTYPE;
BEGIN
  SELECT * INTO v_emp FROM data.employees WHERE id = NEW.employee_id;
  IF NOT FOUND OR v_emp.tenant_id IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'placement_employee_tenant_mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.sites s WHERE s.id = NEW.site_id AND s.tenant_id = NEW.tenant_id
  ) THEN
    RAISE EXCEPTION 'placement_site_tenant_mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF NEW.department_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM data.departments d
    WHERE d.id = NEW.department_id AND d.tenant_id = NEW.tenant_id
  ) THEN
    RAISE EXCEPTION 'placement_department_tenant_mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF NEW.job_position_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM data.job_positions jp
    WHERE jp.id = NEW.job_position_id AND jp.tenant_id = NEW.tenant_id
  ) THEN
    RAISE EXCEPTION 'placement_job_position_tenant_mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF TG_OP = 'INSERT' AND NEW.created_by IS NULL THEN
    NEW.created_by := auth.uid();
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_employee_placement_tenant
  ON data.employee_placement_periods;
CREATE TRIGGER trg_enforce_employee_placement_tenant
  BEFORE INSERT OR UPDATE ON data.employee_placement_periods
  FOR EACH ROW EXECUTE FUNCTION data.enforce_employee_placement_tenant();

DROP TRIGGER IF EXISTS trg_set_updated_at_employee_placement_periods
  ON data.employee_placement_periods;
CREATE TRIGGER trg_set_updated_at_employee_placement_periods
  BEFORE UPDATE ON data.employee_placement_periods
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

ALTER TABLE data.employee_placement_periods ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS employee_placement_periods_select ON data.employee_placement_periods;
CREATE POLICY employee_placement_periods_select ON data.employee_placement_periods
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      data.jwt_can_view_employment_contracts(tenant_id, NULL)
      OR data.jwt_has_employee_permission(tenant_id, 'employees.manage')
      OR data.jwt_has_permission(tenant_id, 'employees.manage', NULL)
    )
  );

DROP POLICY IF EXISTS employee_placement_periods_write ON data.employee_placement_periods;
CREATE POLICY employee_placement_periods_write ON data.employee_placement_periods
  FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_can_manage_employment_contracts(tenant_id, NULL)
      OR data.jwt_has_employee_permission(tenant_id, 'employees.manage')
      OR data.jwt_has_permission(tenant_id, 'employees.manage', NULL)
    )
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_can_manage_employment_contracts(tenant_id, NULL)
      OR data.jwt_has_employee_permission(tenant_id, 'employees.manage')
      OR data.jwt_has_permission(tenant_id, 'employees.manage', NULL)
    )
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON data.employee_placement_periods TO authenticated;

CREATE OR REPLACE VIEW api.employee_placement_periods
  WITH (security_invoker = true, security_barrier = true) AS
SELECT
  id, tenant_id, employee_id, site_id, department_id, job_position_id,
  starts_on, ends_on, source, reason, metadata,
  created_at, updated_at, created_by
FROM data.employee_placement_periods;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.employee_placement_periods TO authenticated;

CREATE OR REPLACE FUNCTION data.get_employee_placement_on(
  p_employee_id uuid,
  p_on_date date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_on date := coalesce(p_on_date, CURRENT_DATE);
  v_row data.employee_placement_periods%ROWTYPE;
BEGIN
  SELECT * INTO v_row
  FROM data.employee_placement_periods p
  WHERE p.employee_id = p_employee_id
    AND p.starts_on <= v_on
    AND (p.ends_on IS NULL OR v_on < p.ends_on)
  ORDER BY p.starts_on DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'tenant_id', v_row.tenant_id,
    'employee_id', v_row.employee_id,
    'site_id', v_row.site_id,
    'department_id', v_row.department_id,
    'job_position_id', v_row.job_position_id,
    'starts_on', v_row.starts_on,
    'ends_on', v_row.ends_on,
    'source', v_row.source,
    'reason', v_row.reason
  );
END;
$$;

COMMENT ON FUNCTION data.get_employee_placement_on(uuid, date) IS
  'EC-WFM P1 §9: effective placement period for half-open [starts_on, ends_on).';

GRANT EXECUTE ON FUNCTION data.get_employee_placement_on(uuid, date)
  TO authenticated, service_role;

-- =============================================================================
-- Resolver bump → ec_wfm_p1_v1 (+ workload / leave / placement)
-- =============================================================================

CREATE OR REPLACE FUNCTION data.resolve_employee_work_context(
  p_employee_id uuid,
  p_work_date date DEFAULT CURRENT_DATE,
  p_requested_site_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_on date := coalesce(p_work_date, CURRENT_DATE);
  v_emp data.employees%ROWTYPE;
  v_terms jsonb;
  v_source text;
  v_contract_id uuid;
  v_site uuid;
  v_dept uuid;
  v_cal uuid;
  v_hours numeric;
  v_job uuid;
  v_conflicts jsonb := '[]'::jsonb;
  v_site_eligible boolean;
  v_tz text;
  v_ca_id uuid;
  v_pc_id uuid;
  v_ca_code text;
  v_ca_name text;
  v_pc_code text;
  v_pc_name text;
  v_convenio jsonb;
  v_wt data.employment_contract_workload_terms%ROWTYPE;
  v_workload jsonb;
  v_wl_source text;
  v_placement jsonb;
  v_pl jsonb;
  v_pl_source text;
  v_lt data.employment_contract_leave_terms%ROWTYPE;
  v_leave jsonb;
  v_contract_hours numeric;
BEGIN
  SELECT * INTO v_emp FROM data.employees WHERE id = p_employee_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  v_terms := data.resolve_employee_contract_terms(p_employee_id, v_on);
  IF v_terms IS NULL THEN
    RETURN NULL;
  END IF;

  v_source := coalesce(v_terms->>'source', 'employee_fallback');
  v_contract_id := NULLIF(v_terms->>'contract_id', '')::uuid;
  v_site := NULLIF(v_terms->>'site_id', '')::uuid;
  v_dept := NULLIF(v_terms->>'department_id', '')::uuid;
  v_cal := NULLIF(v_terms->>'calendar_group_id', '')::uuid;
  v_hours := NULLIF(v_terms->>'weekly_hours', '')::numeric;
  v_job := NULLIF(v_terms->>'job_position_id', '')::uuid;
  v_contract_hours := v_hours;

  IF v_source = 'employment_contract' THEN
    IF v_emp.weekly_hours IS DISTINCT FROM v_hours THEN
      v_conflicts := v_conflicts || jsonb_build_array(jsonb_build_object(
        'dimension', 'weekly_hours',
        'contract', v_hours,
        'employee_flat', v_emp.weekly_hours
      ));
    END IF;
    IF v_emp.site_id IS DISTINCT FROM v_site AND v_site IS NOT NULL THEN
      v_conflicts := v_conflicts || jsonb_build_array(jsonb_build_object(
        'dimension', 'site_id',
        'contract', v_site,
        'employee_flat', v_emp.site_id
      ));
    END IF;
    IF v_emp.calendar_group_id IS DISTINCT FROM v_cal AND v_cal IS NOT NULL THEN
      v_conflicts := v_conflicts || jsonb_build_array(jsonb_build_object(
        'dimension', 'calendar_group_id',
        'contract', v_cal,
        'employee_flat', v_emp.calendar_group_id
      ));
    END IF;
  END IF;

  -- Contract / flat placement defaults
  v_site := coalesce(v_site, v_emp.site_id);
  v_dept := coalesce(v_dept, v_emp.department_id);
  v_cal := coalesce(v_cal, v_emp.calendar_group_id);
  v_hours := coalesce(v_hours, v_emp.weekly_hours);
  v_job := coalesce(v_job, v_emp.job_position_id);

  v_pl_source := CASE
    WHEN v_source = 'employment_contract' THEN 'contract'
    ELSE 'employee_fallback'
  END;
  v_wl_source := CASE
    WHEN v_source = 'employment_contract' THEN 'contract'
    ELSE 'employee_fallback'
  END;

  -- Workload terms override
  IF v_contract_id IS NOT NULL THEN
    SELECT * INTO v_wt
    FROM data.employment_contract_workload_terms
    WHERE contract_id = v_contract_id;

    IF FOUND THEN
      v_wl_source := 'workload_terms';
      IF v_wt.commitment_basis = 'week' THEN
        v_hours := round(v_wt.ordinary_commitment_minutes / 60.0, 2);
        IF v_contract_hours IS NOT NULL
           AND v_hours IS DISTINCT FROM v_contract_hours THEN
          v_conflicts := v_conflicts || jsonb_build_array(jsonb_build_object(
            'dimension', 'weekly_hours',
            'workload_terms', v_hours,
            'contract', v_contract_hours
          ));
        END IF;
      END IF;

      v_workload := jsonb_build_object(
        'weekly_hours', v_hours,
        'commitment_basis', v_wt.commitment_basis,
        'ordinary_commitment_minutes', v_wt.ordinary_commitment_minutes,
        'complementary_commitment_minutes', v_wt.complementary_commitment_minutes,
        'fte_ratio', v_wt.fte_ratio,
        'source', v_wl_source
      );
    END IF;
  END IF;

  IF v_workload IS NULL THEN
    v_workload := jsonb_build_object(
      'weekly_hours', v_hours,
      'source', v_wl_source
    );
  END IF;

  -- Placement period override (highest precedence for site/dept/job)
  v_pl := data.get_employee_placement_on(p_employee_id, v_on);
  IF v_pl IS NOT NULL THEN
    v_site := NULLIF(v_pl->>'site_id', '')::uuid;
    v_dept := coalesce(NULLIF(v_pl->>'department_id', '')::uuid, v_dept);
    v_job := coalesce(NULLIF(v_pl->>'job_position_id', '')::uuid, v_job);
    v_pl_source := 'placement_period';
  END IF;

  v_placement := jsonb_build_object(
    'site_id', v_site,
    'department_id', v_dept,
    'job_position_id', v_job,
    'source', v_pl_source
  );

  -- Leave terms summary (policy; grants are separate)
  IF v_contract_id IS NOT NULL THEN
    SELECT * INTO v_lt
    FROM data.employment_contract_leave_terms
    WHERE contract_id = v_contract_id;

    IF FOUND THEN
      v_leave := jsonb_build_object(
        'paid_leave_allowance', v_lt.paid_leave_allowance,
        'allowance_unit', v_lt.allowance_unit,
        'counting_method', v_lt.counting_method,
        'proration_method', v_lt.proration_method,
        'source', 'leave_terms'
      );
    END IF;
  END IF;

  IF v_leave IS NULL THEN
    v_leave := jsonb_build_object(
      'note', 'no leave_terms on effective contract'
    );
  END IF;

  v_site_eligible := CASE
    WHEN p_requested_site_id IS NULL THEN true
    WHEN v_site IS NULL THEN true
    ELSE p_requested_site_id = v_site
  END;

  v_tz := coalesce(
    data.get_site_timezone(coalesce(p_requested_site_id, v_site), v_emp.tenant_id),
    'Europe/Madrid'
  );

  IF v_contract_id IS NOT NULL THEN
    SELECT c.collective_agreement_id, c.professional_category_id,
           ca.code, ca.name, pc.code, pc.name
    INTO v_ca_id, v_pc_id, v_ca_code, v_ca_name, v_pc_code, v_pc_name
    FROM data.employment_contracts c
    LEFT JOIN data.collective_agreements ca ON ca.id = c.collective_agreement_id
    LEFT JOIN data.professional_categories pc ON pc.id = c.professional_category_id
    WHERE c.id = v_contract_id;
  END IF;

  v_convenio := jsonb_build_object(
    'collective_agreement_id', v_ca_id,
    'collective_agreement_code', v_ca_code,
    'collective_agreement_name', v_ca_name,
    'professional_category_id', v_pc_id,
    'professional_category_code', v_pc_code,
    'professional_category_name', v_pc_name
  );

  RETURN jsonb_build_object(
    'resolver_version', 'ec_wfm_p1_v1',
    'employee_id', p_employee_id,
    'work_date', v_on,
    'tenant_id', v_emp.tenant_id,
    'lifecycle_state', v_emp.lifecycle_state,
    'employee_status', v_emp.status,
    'contract', jsonb_build_object(
      'id', v_contract_id,
      'source', v_source,
      'starts_on', v_terms->'starts_on',
      'ends_on', v_terms->'ends_on',
      'work_entry_source', v_terms->'work_entry_source',
      'fte', v_terms->'fte'
    ),
    'workload', v_workload,
    'placement', v_placement,
    'leave_terms', v_leave,
    'calendar', jsonb_build_object(
      'calendar_group_id', v_cal,
      'timezone', v_tz,
      'source', CASE WHEN v_source = 'employment_contract' THEN 'contract' ELSE 'employee_fallback' END
    ),
    'requested_site', jsonb_build_object(
      'site_id', p_requested_site_id,
      'eligible', v_site_eligible
    ),
    'convenio_categoria', v_convenio,
    'policies', jsonb_build_object(
      'note', 'labor_rules / attendance policies resolved by callers'
    ),
    'provenance', jsonb_build_object(
      'terms_source', v_source,
      'flat_employee_used', v_source = 'employee_fallback',
      'workload_source', v_wl_source,
      'placement_source', v_pl_source
    ),
    'conflicts', v_conflicts
  );
END;
$$;

COMMENT ON FUNCTION data.resolve_employee_work_context(uuid, date, uuid) IS
  'EC-WFM P1: work context with workload_terms, leave_terms, placement_periods (ec_wfm_p1_v1).';

-- Snapshot capture: take resolver_version from ctx (no hardcoded P0)
CREATE OR REPLACE FUNCTION data.capture_work_context_snapshot(
  p_employee_id uuid,
  p_work_date date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_ctx jsonb;
  v_captured_at timestamptz := clock_timestamp();
BEGIN
  v_ctx := data.resolve_employee_work_context(p_employee_id, p_work_date, NULL);
  IF v_ctx IS NULL THEN
    RETURN jsonb_build_object(
      'employment_contract_id', NULL,
      'workload', '{}'::jsonb,
      'placement', '{}'::jsonb,
      'calendar', '{}'::jsonb,
      'policies', '{}'::jsonb,
      'convenio_categoria', '{}'::jsonb,
      'leave_terms', '{}'::jsonb,
      'resolver_version', NULL,
      'captured_at', v_captured_at
    );
  END IF;

  RETURN jsonb_build_object(
    'employment_contract_id', NULLIF(v_ctx->'contract'->>'id', '')::uuid,
    'workload', coalesce(v_ctx->'workload', '{}'::jsonb),
    'placement', coalesce(v_ctx->'placement', '{}'::jsonb),
    'calendar', coalesce(v_ctx->'calendar', '{}'::jsonb),
    'policies', coalesce(v_ctx->'policies', '{}'::jsonb),
    'convenio_categoria', coalesce(v_ctx->'convenio_categoria', '{}'::jsonb),
    'leave_terms', coalesce(v_ctx->'leave_terms', '{}'::jsonb),
    'resolver_version', v_ctx->>'resolver_version',
    'captured_at', v_captured_at
  );
END;
$$;

COMMENT ON FUNCTION data.capture_work_context_snapshot(uuid, date) IS
  'EC-WFM P1 §4.6/ADR-05: compact freeze payload; resolver_version from live context.';

-- evaluate_employee_assignment: resolver_version from work_context (not hardcoded P0)
CREATE OR REPLACE FUNCTION data.evaluate_employee_assignment(p_employee_id uuid, p_site_id uuid, p_starts_at timestamp with time zone, p_ends_at timestamp with time zone, p_role_id uuid DEFAULT NULL::uuid, p_exclude_slot_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'data'
AS $function$
DECLARE
  v_work_date date;
  v_start_time time;
  v_end_time time;
  v_emp record;
  v_ctx jsonb;
  v_blocks jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_status text := 'ready';
  v_avail text;
  v_labor jsonb;
  v_issue jsonb;
  v_closed jsonb;
  v_eff_hours numeric;
  v_week_start date;
  v_shift_min int;
  v_week_min int;
  v_holiday_name text;
  v_life text;
BEGIN
  IF p_employee_id IS NULL OR p_starts_at IS NULL OR p_ends_at IS NULL THEN
    RETURN jsonb_build_object(
      'status', 'blocked',
      'blocks', jsonb_build_array(jsonb_build_object(
        'code', 'invalid_args',
        'rule', 'input',
        'source', 'evaluate_employee_assignment'
      )),
      'warnings', '[]'::jsonb,
      'resolver_version', coalesce(v_ctx->>'resolver_version', 'ec_wfm_p1_v1')
    );
  END IF;

  IF p_ends_at <= p_starts_at THEN
    -- overnight window: still valid for time extraction via date of start
    NULL;
  END IF;

  SELECT e.id, e.tenant_id, e.status, e.lifecycle_state, e.site_id, e.full_name
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'status', 'blocked',
      'blocks', jsonb_build_array(jsonb_build_object(
        'code', 'employee_not_found',
        'rule', 'lifecycle',
        'source', 'data.employees'
      )),
      'warnings', '[]'::jsonb,
      'resolver_version', coalesce(v_ctx->>'resolver_version', 'ec_wfm_p1_v1')
    );
  END IF;

  DECLARE
    v_tz text := 'Europe/Madrid';
  BEGIN
    IF p_site_id IS NOT NULL THEN
      v_tz := coalesce(data.get_site_timezone(p_site_id, v_emp.tenant_id), 'Europe/Madrid');
    END IF;
    v_work_date := (p_starts_at AT TIME ZONE v_tz)::date;
    v_start_time := (p_starts_at AT TIME ZONE v_tz)::time;
    v_end_time := (p_ends_at AT TIME ZONE v_tz)::time;
  END;

  v_ctx := data.resolve_employee_work_context(p_employee_id, v_work_date, p_site_id);

  IF v_ctx IS NULL THEN
    v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
      'code', 'work_context_unavailable',
      'rule', 'work_context',
      'source', 'resolve_employee_work_context'
    ));
  ELSE
    v_work_date := coalesce((v_ctx->>'work_date')::date, v_work_date);
  END IF;

  -- Lifecycle / employee status
  v_life := coalesce(v_emp.lifecycle_state, v_emp.status);
  IF v_emp.status = 'terminated'
     OR v_life IN ('terminated', 'offboarding') THEN
    v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
      'code', 'employee_not_active',
      'rule', 'lifecycle',
      'source', 'employees.lifecycle_state',
      'detail', v_life
    ));
  ELSIF v_emp.status IS DISTINCT FROM 'active'
        AND v_life IS DISTINCT FROM 'active' THEN
    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
      'code', 'employee_lifecycle_non_active',
      'rule', 'lifecycle',
      'source', 'employees.lifecycle_state',
      'detail', v_life
    ));
  END IF;

  -- Site eligibility from work context
  IF p_site_id IS NOT NULL AND v_ctx IS NOT NULL THEN
    IF coalesce((v_ctx->'requested_site'->>'eligible')::boolean, true) = false THEN
      v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
        'code', 'employee_wrong_site',
        'rule', 'placement',
        'source', 'resolve_employee_work_context',
        'detail', jsonb_build_object(
          'requested', p_site_id,
          'placement', v_ctx->'placement'->>'site_id'
        )
      ));
    END IF;
  END IF;

  -- Closed periods
  v_closed := data.shift_closed_period_issues(
    jsonb_build_array(jsonb_build_object(
      'employee_id', p_employee_id,
      'work_date', v_work_date
    ))
  );
  FOR v_issue IN SELECT * FROM jsonb_array_elements(coalesce(v_closed, '[]'::jsonb))
  LOOP
    v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
      'code', v_issue->>'code',
      'rule', 'closed_period',
      'source', 'shift_closed_period_issues',
      'detail', v_issue->>'message'
    ));
  END LOOP;

  -- Absences
  IF EXISTS (
    SELECT 1
    FROM data.employee_absences ea
    WHERE ea.employee_id = p_employee_id
      AND ea.status IN ('approved', 'active', 'closed')
      AND ea.start_date <= v_work_date
      AND coalesce(ea.end_date, ea.start_date) >= v_work_date
  ) THEN
    v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
      'code', 'employee_on_absence',
      'rule', 'absence',
      'source', 'employee_absences'
    ));
  END IF;

  -- Role qualifications
  IF p_role_id IS NOT NULL THEN
    IF NOT data.employee_meets_role_qualifications(p_employee_id, p_role_id, v_work_date) THEN
      v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
        'code', 'role_qualifications_unmet',
        'rule', 'certification',
        'source', 'employee_meets_role_qualifications'
      ));
    END IF;
  END IF;

  -- Shift overlap (warning ÔÇö assign historically soft-flags; openings may still hard-block)
  IF EXISTS (
    SELECT 1
    FROM data.shift_slots ss
    WHERE ss.employee_id = p_employee_id
      AND ss.status <> 'cancelled'
      AND (p_exclude_slot_id IS NULL OR ss.id <> p_exclude_slot_id)
      AND ss.slot_date BETWEEN v_work_date - 1 AND v_work_date + 1
      AND data.shift_slots_overlap(
        v_work_date, v_start_time, v_end_time,
        ss.slot_date, ss.start_time, ss.end_time
      )
  ) THEN
    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
      'code', 'SHIFT_OVERLAP',
      'rule', 'overlap',
      'source', 'shift_slots'
    ));
  END IF;

  -- Availability
  v_avail := data.employee_availability_for_window(
    p_employee_id, v_work_date, v_start_time, v_end_time
  );
  IF v_avail = 'unavailable' THEN
    v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
      'code', 'availability_unavailable',
      'rule', 'availability',
      'source', 'employee_availability_for_window'
    ));
  ELSIF v_avail = 'unknown' THEN
    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
      'code', 'availability_unknown',
      'rule', 'availability',
      'source', 'employee_availability_for_window'
    ));
  END IF;

  -- Weekly hours (warning)
  v_eff_hours := NULLIF(v_ctx->'workload'->>'weekly_hours', '')::numeric;
  IF v_eff_hours IS NULL THEN
    v_eff_hours := data.employee_effective_weekly_hours(p_employee_id, v_work_date);
  END IF;

  v_week_start := date_trunc('week', v_work_date::timestamptz)::date;
  v_shift_min := ROUND(EXTRACT(EPOCH FROM CASE
    WHEN v_end_time > v_start_time THEN v_end_time - v_start_time
    ELSE interval '24 hours' + (v_end_time - v_start_time)
  END) / 60)::int;

  SELECT coalesce(SUM(ROUND(EXTRACT(EPOCH FROM CASE
    WHEN ss.end_time > ss.start_time THEN ss.end_time - ss.start_time
    ELSE interval '24 hours' + (ss.end_time - ss.start_time)
  END) / 60)), 0)::int
  INTO v_week_min
  FROM data.shift_slots ss
  WHERE ss.employee_id = p_employee_id
    AND ss.slot_date >= v_week_start
    AND ss.slot_date <= v_week_start + 6
    AND ss.status <> 'cancelled'
    AND (p_exclude_slot_id IS NULL OR ss.id <> p_exclude_slot_id);

  IF v_eff_hours IS NOT NULL
     AND (v_week_min + v_shift_min) > (v_eff_hours * 60) THEN
    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
      'code', 'WEEKLY_HOURS_EXCEEDED',
      'rule', 'workload',
      'source', 'resolve_employee_work_context',
      'detail', jsonb_build_object(
        'weekly_hours', v_eff_hours,
        'week_minutes', v_week_min,
        'shift_minutes', v_shift_min
      )
    ));
  END IF;

  -- Labor rules
  IF p_site_id IS NOT NULL THEN
    v_labor := data.evaluate_labor_rules_for_window(
      p_employee_id, p_site_id, v_work_date, v_start_time, v_end_time, NULL
    );
    FOR v_issue IN SELECT * FROM jsonb_array_elements(coalesce(v_labor->'issues', '[]'::jsonb))
    LOOP
      IF v_issue->>'severity' = 'block' THEN
        v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
          'code', v_issue->>'code',
          'rule', 'labor_rules',
          'source', 'evaluate_labor_rules_for_window',
          'detail', v_issue
        ));
      ELSE
        v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
          'code', v_issue->>'code',
          'rule', 'labor_rules',
          'source', 'evaluate_labor_rules_for_window',
          'detail', v_issue
        ));
      END IF;
    END LOOP;
  END IF;

  -- Site holiday (warning)
  IF p_site_id IS NOT NULL THEN
    SELECT h.holiday_name INTO v_holiday_name
    FROM data.planner_site_holidays(v_emp.tenant_id, p_site_id, v_work_date, v_work_date) h
    WHERE h.holiday_date = v_work_date
    LIMIT 1;

    IF FOUND THEN
      v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
        'code', 'SITE_HOLIDAY',
        'rule', 'holiday',
        'source', 'planner_site_holidays',
        'detail', v_holiday_name
      ));
    END IF;
  END IF;

  IF jsonb_array_length(v_blocks) > 0 THEN
    v_status := 'blocked';
  ELSIF jsonb_array_length(v_warnings) > 0 THEN
    v_status := 'warning';
  ELSE
    v_status := 'ready';
  END IF;

  RETURN jsonb_build_object(
    'status', v_status,
    'ready', v_status = 'ready',
    'blocks', v_blocks,
    'warnings', v_warnings,
    'availability', v_avail,
    'labor', v_labor,
    'work_context', v_ctx,
    'work_date', v_work_date,
    'start_time', v_start_time,
    'end_time', v_end_time,
    'employee_id', p_employee_id,
    'site_id', p_site_id,
    'role_id', p_role_id,
    'resolver_version', coalesce(v_ctx->>'resolver_version', 'ec_wfm_p1_v1')
  );
END;
$function$

;


COMMIT;

