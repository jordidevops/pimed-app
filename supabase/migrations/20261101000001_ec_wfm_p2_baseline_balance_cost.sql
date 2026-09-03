-- EC-WFM P2: baseline plan, hour balance policy, external provenance, planning cost
-- Spec: plan-employment-contracts-inspiracio-orquest.md §10–§12

BEGIN;

-- =============================================================================
-- §10 - hour_balance_policies
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.hour_balance_policies (
  tenant_id uuid PRIMARY KEY REFERENCES data.tenants(id) ON DELETE CASCADE,
  window_type text NOT NULL DEFAULT 'month'
    CHECK (window_type IN ('week', 'month', 'year')),
  window_length int NOT NULL DEFAULT 1
    CHECK (window_length > 0),
  rounding_rule text NOT NULL DEFAULT 'nearest'
    CHECK (rounding_rule IN ('floor', 'ceil', 'nearest')),
  carry_enabled boolean NOT NULL DEFAULT true,
  expire_after_days int NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_set_updated_at_hour_balance_policies
  ON data.hour_balance_policies;
CREATE TRIGGER trg_set_updated_at_hour_balance_policies
  BEFORE UPDATE ON data.hour_balance_policies
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

ALTER TABLE data.hour_balance_policies ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS hour_balance_policies_select ON data.hour_balance_policies;
CREATE POLICY hour_balance_policies_select ON data.hour_balance_policies
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      data.jwt_has_permission(tenant_id, 'attendance.view_all', NULL)
      OR data.jwt_can_view_employment_contracts(tenant_id, NULL)
    )
  );

DROP POLICY IF EXISTS hour_balance_policies_write ON data.hour_balance_policies;
CREATE POLICY hour_balance_policies_write ON data.hour_balance_policies
  FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_can_manage_employment_contracts(tenant_id, NULL)
      OR data.jwt_has_permission(tenant_id, 'settings.manage', NULL)
    )
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_can_manage_employment_contracts(tenant_id, NULL)
      OR data.jwt_has_permission(tenant_id, 'settings.manage', NULL)
    )
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON data.hour_balance_policies TO authenticated;

CREATE OR REPLACE VIEW api.hour_balance_policies
  WITH (security_invoker = true) AS
SELECT
  tenant_id, window_type, window_length, rounding_rule,
  carry_enabled, expire_after_days, metadata, created_at, updated_at
FROM data.hour_balance_policies;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.hour_balance_policies TO authenticated;

COMMENT ON TABLE data.hour_balance_policies IS
  'EC-WFM P2 §10: per-tenant hour balance window/rounding/carry policy. Ledger remains time_compensation_ledger.';

-- =============================================================================
-- §10 - resolve_employee_baseline_plan (calendar only; no absences / shift slots)
-- =============================================================================

CREATE OR REPLACE FUNCTION data.resolve_employee_baseline_plan(
  p_employee_id uuid,
  p_work_date date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_on date := coalesce(p_work_date, CURRENT_DATE);
  v_ctx jsonb;
  v_tenant uuid;
  v_site uuid;
  v_cal uuid;
  v_tz text;
  v_emp_override text;
  v_skip_holiday boolean := false;
  v_labor record;
  v_day_type text := 'unknown';
  v_expected_min int := 0;
  v_work_intervals jsonb := '[]'::jsonb;
  v_is_holiday boolean := false;
  v_holiday_name text;
  v_labor_source text;
BEGIN
  v_ctx := data.resolve_employee_work_context(p_employee_id, v_on, NULL);
  IF v_ctx IS NULL THEN
    -- Missing employee (or unresolvable context)
    RETURN NULL;
  END IF;

  v_tenant := NULLIF(v_ctx->>'tenant_id', '')::uuid;
  v_site := NULLIF(v_ctx->'placement'->>'site_id', '')::uuid;
  v_cal := NULLIF(v_ctx->'calendar'->>'calendar_group_id', '')::uuid;
  v_tz := coalesce(v_ctx->'calendar'->>'timezone', 'Europe/Madrid');

  IF v_site IS NULL THEN
    SELECT e.site_id INTO v_site FROM data.employees e WHERE e.id = p_employee_id;
  END IF;

  SELECT edo.override_type INTO v_emp_override
  FROM data.employee_day_overrides edo
  WHERE edo.employee_id = p_employee_id
    AND edo.override_date = v_on;

  IF FOUND THEN
    IF v_emp_override = 'force_holiday' THEN
      RETURN jsonb_build_object(
        'resolver_version', 'ec_wfm_p2_v1',
        'employee_id', p_employee_id,
        'work_date', v_on,
        'day_type', 'holiday',
        'expected_minutes', 0,
        'work_intervals', '[]'::jsonb,
        'is_holiday', true,
        'holiday_name', NULL,
        'labor_source', 'employee_day_override',
        'placement', v_ctx->'placement',
        'workload', v_ctx->'workload',
        'calendar', v_ctx->'calendar',
        'site_timezone', v_tz,
        'excludes', jsonb_build_object('absences', true, 'shift_slots', true),
        'work_context_resolver_version', coalesce(v_ctx->>'resolver_version', 'ec_wfm_p1_v1')
      );
    ELSIF v_emp_override = 'force_work' THEN
      v_skip_holiday := true;
    END IF;
  END IF;

  SELECT * INTO v_labor
  FROM data.resolve_labor_calendar_for_employee(
    v_tenant, v_site, p_employee_id, v_on, v_skip_holiday
  );

  v_labor_source := v_labor.labor_source;
  v_expected_min := coalesce(v_labor.planned_minutes, 0);
  v_holiday_name := v_labor.labor_day_name;
  v_work_intervals := coalesce(v_labor.work_intervals, '[]'::jsonb);
  v_is_holiday := coalesce(v_labor.labor_day_type, '') = 'holiday'
    OR coalesce(v_labor.labor_source, '') = 'assigned_holiday';

  CASE coalesce(v_labor.labor_day_type, '')
    WHEN 'work' THEN
      v_day_type := 'work';
    WHEN 'holiday' THEN
      v_day_type := 'holiday';
      v_expected_min := 0;
      v_is_holiday := true;
      v_work_intervals := '[]'::jsonb;
    WHEN 'vacation' THEN
      v_day_type := 'rest';
      v_expected_min := 0;
      v_work_intervals := '[]'::jsonb;
    WHEN 'leave' THEN
      v_day_type := 'rest';
      v_expected_min := 0;
      v_work_intervals := '[]'::jsonb;
    WHEN 'rest' THEN
      v_day_type := 'rest';
      v_expected_min := 0;
      v_work_intervals := '[]'::jsonb;
    ELSE
      -- Treat undefined / none as rest when not a work day
      IF coalesce(v_labor.labor_day_type, '') IN ('undefined', '')
         AND coalesce(v_expected_min, 0) = 0 THEN
        v_day_type := CASE
          WHEN coalesce(v_labor_source, 'none') IN ('none', '') THEN 'unknown'
          ELSE 'rest'
        END;
      ELSE
        v_day_type := 'unknown';
      END IF;
      IF v_day_type <> 'work' THEN
        v_expected_min := 0;
      END IF;
  END CASE;

  -- Intentionally NO absence branch and NO published/draft shift overlay.
  RETURN jsonb_build_object(
    'resolver_version', 'ec_wfm_p2_v1',
    'employee_id', p_employee_id,
    'work_date', v_on,
    'day_type', v_day_type,
    'expected_minutes', v_expected_min,
    'work_intervals', v_work_intervals,
    'is_holiday', v_is_holiday,
    'holiday_name', v_holiday_name,
    'labor_source', v_labor_source,
    'placement', v_ctx->'placement',
    'workload', v_ctx->'workload',
    'calendar', jsonb_build_object(
      'calendar_group_id', coalesce(v_cal, NULLIF(v_ctx->'calendar'->>'calendar_group_id', '')::uuid),
      'timezone', v_tz,
      'source', v_ctx->'calendar'->>'source'
    ),
    'site_timezone', v_tz,
    'excludes', jsonb_build_object('absences', true, 'shift_slots', true),
    'work_context_resolver_version', coalesce(v_ctx->>'resolver_version', 'ec_wfm_p1_v1')
  );
END;
$$;

COMMENT ON FUNCTION data.resolve_employee_baseline_plan(uuid, date) IS
  'EC-WFM P2 §10: labor baseline from work_context placement/calendar; excludes absences and shift slots.';

GRANT EXECUTE ON FUNCTION data.resolve_employee_baseline_plan(uuid, date) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.resolve_employee_baseline_plan(
  p_employee_id uuid,
  p_work_date date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_emp data.employees%ROWTYPE;
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
    data.jwt_has_permission(v_emp.tenant_id, 'employees.view', v_emp.site_id)
    OR data.jwt_has_permission(v_emp.tenant_id, 'employees.read', v_emp.site_id)
    OR data.jwt_has_permission(v_emp.tenant_id, 'labor_calendar.view', v_emp.site_id)
    OR data.jwt_can_view_employment_contracts(v_emp.tenant_id, v_emp.site_id)
    OR (v_emp.user_id IS NOT NULL AND v_emp.user_id = auth.uid())
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN data.resolve_employee_baseline_plan(p_employee_id, p_work_date);
END;
$$;

GRANT EXECUTE ON FUNCTION api.resolve_employee_baseline_plan(uuid, date) TO authenticated, service_role;

-- =============================================================================
-- §10 - resolve_employee_hour_balance
-- =============================================================================

CREATE OR REPLACE FUNCTION data.resolve_employee_hour_balance(
  p_employee_id uuid,
  p_as_of date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_on date := coalesce(p_as_of, CURRENT_DATE);
  v_emp data.employees%ROWTYPE;
  v_pol data.hour_balance_policies%ROWTYPE;
  v_has_pol boolean := false;
  v_window_start date;
  v_balance int := 0;
  v_policy jsonb;
BEGIN
  SELECT * INTO v_emp FROM data.employees WHERE id = p_employee_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_pol
  FROM data.hour_balance_policies
  WHERE tenant_id = v_emp.tenant_id;

  v_has_pol := FOUND;

  IF NOT v_has_pol THEN
    v_pol.window_type := 'month';
    v_pol.window_length := 1;
    v_pol.rounding_rule := 'nearest';
    v_pol.carry_enabled := true;
    v_pol.expire_after_days := NULL;
  END IF;

  v_window_start := CASE v_pol.window_type
    WHEN 'week' THEN
      (v_on - ((EXTRACT(ISODOW FROM v_on)::int - 1) * INTERVAL '1 day'))::date
        - ((v_pol.window_length - 1) * 7)
    WHEN 'year' THEN
      make_date(EXTRACT(YEAR FROM v_on)::int - (v_pol.window_length - 1), 1, 1)
    ELSE
      -- month (default)
      (date_trunc('month', v_on)::date - ((v_pol.window_length - 1) || ' months')::interval)::date
  END;

  SELECT coalesce(SUM(
    CASE WHEN l.is_credit THEN l.minutes ELSE -l.minutes END
  ), 0)::int
  INTO v_balance
  FROM data.time_compensation_ledger l
  WHERE l.employee_id = p_employee_id
    AND l.tenant_id = v_emp.tenant_id
    AND (
      -- Prefer source_work_date when present; else created_at::date
      coalesce(l.source_work_date, (l.created_at AT TIME ZONE 'UTC')::date) >= v_window_start
      AND coalesce(l.source_work_date, (l.created_at AT TIME ZONE 'UTC')::date) <= v_on
    );

  v_policy := jsonb_build_object(
    'window_type', v_pol.window_type,
    'window_length', v_pol.window_length,
    'rounding_rule', v_pol.rounding_rule,
    'carry_enabled', v_pol.carry_enabled,
    'expire_after_days', v_pol.expire_after_days,
    'from_row', v_has_pol,
    'window_start', v_window_start,
    'window_end', v_on
  );

  RETURN jsonb_build_object(
    'resolver_version', 'ec_wfm_p2_v1',
    'employee_id', p_employee_id,
    'as_of', v_on,
    'tenant_id', v_emp.tenant_id,
    'balance_minutes', v_balance,
    'ledger_source', 'time_compensation_ledger',
    'policy', v_policy
  );
END;
$$;

COMMENT ON FUNCTION data.resolve_employee_hour_balance(uuid, date) IS
  'EC-WFM P2 §10: net balance from time_compensation_ledger under tenant hour_balance_policies (defaults if no row).';

GRANT EXECUTE ON FUNCTION data.resolve_employee_hour_balance(uuid, date) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.resolve_employee_hour_balance(
  p_employee_id uuid,
  p_as_of date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_emp data.employees%ROWTYPE;
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
    data.jwt_has_permission(v_emp.tenant_id, 'attendance.view_all', v_emp.site_id)
    OR data.jwt_can_view_employment_contracts(v_emp.tenant_id, v_emp.site_id)
    OR (v_emp.user_id IS NOT NULL AND v_emp.user_id = auth.uid())
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN data.resolve_employee_hour_balance(p_employee_id, p_as_of);
END;
$$;

GRANT EXECUTE ON FUNCTION api.resolve_employee_hour_balance(uuid, date) TO authenticated, service_role;

-- =============================================================================
-- §11 - External provenance columns on employment_contracts
-- =============================================================================

ALTER TABLE data.employment_contracts
  ADD COLUMN IF NOT EXISTS external_identity text,
  ADD COLUMN IF NOT EXISTS source_changed_at timestamptz,
  ADD COLUMN IF NOT EXISTS source_payload_digest text,
  ADD COLUMN IF NOT EXISTS external_review_status text,
  ADD COLUMN IF NOT EXISTS correlation_id text,
  ADD COLUMN IF NOT EXISTS import_idempotency_key text,
  ADD COLUMN IF NOT EXISTS field_ownership jsonb NOT NULL DEFAULT '{}'::jsonb;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'employment_contracts_external_review_status_check'
      AND conrelid = 'data.employment_contracts'::regclass
  ) THEN
    ALTER TABLE data.employment_contracts
      ADD CONSTRAINT employment_contracts_external_review_status_check
      CHECK (
        external_review_status IS NULL
        OR external_review_status IN ('pending', 'accepted', 'rejected')
      );
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_employment_contracts_tenant_external_identity
  ON data.employment_contracts (tenant_id, external_identity)
  WHERE external_identity IS NOT NULL AND btrim(external_identity) <> '';

CREATE UNIQUE INDEX IF NOT EXISTS uq_employment_contracts_tenant_import_idempotency
  ON data.employment_contracts (tenant_id, import_idempotency_key)
  WHERE import_idempotency_key IS NOT NULL AND btrim(import_idempotency_key) <> '';

-- Refresh api view: append new columns at end (preserve column order for RPCs)
CREATE OR REPLACE VIEW api.employment_contracts
  WITH (security_invoker = true) AS
SELECT
  id, tenant_id, employee_id, contract_number, source, external_reference,
  lifecycle_status, approval_status, signature_status, signature_requirement, is_primary,
  starts_on, ends_on, probation_ends_on,
  contract_type_id, job_position_id, department_id, site_id, calendar_group_id,
  weekly_hours, fte, work_entry_source,
  supersedes_contract_id, termination_reason_code, termination_notes,
  template_id, template_locale_id, template_snapshot, variables_snapshot,
  generated_document_id, final_document_version_id, signing_submission_id,
  approved_by, approved_at, fully_signed_at, activated_at, ended_at,
  cancelled_at, cancellation_reason,
  created_by, created_at, updated_at, metadata,
  collective_agreement_id, professional_category_id,
  external_identity, source_changed_at, source_payload_digest,
  external_review_status, correlation_id, import_idempotency_key, field_ownership
FROM data.employment_contracts;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.employment_contracts TO authenticated;

-- =============================================================================
-- §11 - preflight_external_contract_import (stub; does not apply)
-- =============================================================================

CREATE OR REPLACE FUNCTION data.preflight_external_contract_import(
  p_tenant_id uuid,
  p_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_blocks jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_ext text := nullif(btrim(coalesce(p_payload->>'external_identity', '')), '');
  v_idem text := nullif(btrim(coalesce(p_payload->>'import_idempotency_key', '')), '');
  v_contract_id uuid := NULLIF(p_payload->>'contract_id', '')::uuid;
  v_c data.employment_contracts%ROWTYPE;
  v_other data.employment_contracts%ROWTYPE;
  v_signed boolean := false;
BEGIN
  IF p_tenant_id IS NULL THEN
    v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
      'code', 'missing_tenant_id',
      'detail', 'p_tenant_id is required'
    ));
    RETURN jsonb_build_object('ok', false, 'blocks', v_blocks, 'warnings', v_warnings);
  END IF;

  IF p_payload IS NULL OR p_payload = '{}'::jsonb THEN
    v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
      'code', 'empty_payload',
      'detail', 'payload is empty'
    ));
    RETURN jsonb_build_object('ok', false, 'blocks', v_blocks, 'warnings', v_warnings);
  END IF;

  -- Resolve target contract: explicit id, else by external_identity
  v_c := NULL;
  IF v_contract_id IS NOT NULL THEN
    SELECT * INTO v_c
    FROM data.employment_contracts
    WHERE id = v_contract_id AND tenant_id = p_tenant_id;
  ELSIF v_ext IS NOT NULL THEN
    SELECT * INTO v_c
    FROM data.employment_contracts
    WHERE tenant_id = p_tenant_id
      AND external_identity = v_ext
    LIMIT 1;
  END IF;

  IF v_c.id IS NOT NULL THEN
    v_signed := (
      v_c.fully_signed_at IS NOT NULL
      OR v_c.signature_status IN ('completed', 'partial')
    );

    IF v_c.lifecycle_status IN ('active', 'ended') AND v_signed THEN
      v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
        'code', 'cannot_overwrite_signed_contract',
        'detail', jsonb_build_object(
          'contract_id', v_c.id,
          'lifecycle_status', v_c.lifecycle_status,
          'signature_status', v_c.signature_status,
          'fully_signed_at', v_c.fully_signed_at
        )
      ));
    END IF;
  END IF;

  -- Idempotency key reused by a different external_identity
  IF v_idem IS NOT NULL THEN
    SELECT * INTO v_other
    FROM data.employment_contracts
    WHERE tenant_id = p_tenant_id
      AND import_idempotency_key = v_idem
    LIMIT 1;

    IF FOUND
       AND v_ext IS NOT NULL
       AND v_other.external_identity IS DISTINCT FROM v_ext THEN
      v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
        'code', 'import_idempotency_key_conflict',
        'detail', jsonb_build_object(
          'import_idempotency_key', v_idem,
          'existing_external_identity', v_other.external_identity,
          'payload_external_identity', v_ext,
          'existing_contract_id', v_other.id
        )
      ));
    ELSIF FOUND AND v_ext IS NULL THEN
      v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
        'code', 'idempotency_key_already_used',
        'detail', v_other.id
      ));
    END IF;
  END IF;

  -- Incomplete required fields (warnings only)
  IF nullif(btrim(coalesce(p_payload->>'employee_id', '')), '') IS NULL
     AND v_c.employee_id IS NULL THEN
    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
      'code', 'missing_employee_id',
      'detail', 'employee_id recommended for import'
    ));
  END IF;

  IF nullif(btrim(coalesce(p_payload->>'starts_on', '')), '') IS NULL
     AND v_c.id IS NULL THEN
    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
      'code', 'missing_starts_on',
      'detail', 'starts_on recommended for import'
    ));
  END IF;

  IF v_ext IS NULL AND v_contract_id IS NULL THEN
    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
      'code', 'missing_external_identity',
      'detail', 'external_identity recommended for idempotent matching'
    ));
  END IF;

  RETURN jsonb_build_object(
    'ok', jsonb_array_length(v_blocks) = 0,
    'blocks', v_blocks,
    'warnings', v_warnings
  );
END;
$$;

COMMENT ON FUNCTION data.preflight_external_contract_import(uuid, jsonb) IS
  'EC-WFM P2 §11: preflight stub for external contract imports; does not apply changes.';

GRANT EXECUTE ON FUNCTION data.preflight_external_contract_import(uuid, jsonb)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.preflight_external_contract_import(
  p_payload jsonb
)
RETURNS jsonb
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

  IF NOT data.jwt_can_manage_employment_contracts(v_tenant_id, NULL) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN data.preflight_external_contract_import(v_tenant_id, p_payload);
END;
$$;

GRANT EXECUTE ON FUNCTION api.preflight_external_contract_import(jsonb)
  TO authenticated, service_role;

-- =============================================================================
-- §12 - planning_cost_snapshots + resolve_contract_planning_cost
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.planning_cost_snapshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  contract_id uuid NOT NULL REFERENCES data.employment_contracts(id) ON DELETE CASCADE,
  on_date date NOT NULL,
  snapshot jsonb NOT NULL,
  frozen_at timestamptz NOT NULL DEFAULT now(),
  frozen_by uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  budget_label text
);

CREATE INDEX IF NOT EXISTS idx_planning_cost_snapshots_contract
  ON data.planning_cost_snapshots (tenant_id, contract_id, on_date);

ALTER TABLE data.planning_cost_snapshots ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS planning_cost_snapshots_select ON data.planning_cost_snapshots;
CREATE POLICY planning_cost_snapshots_select ON data.planning_cost_snapshots
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_can_view_employment_compensation(tenant_id)
  );

DROP POLICY IF EXISTS planning_cost_snapshots_write ON data.planning_cost_snapshots;
CREATE POLICY planning_cost_snapshots_write ON data.planning_cost_snapshots
  FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_employee_permission(tenant_id, 'employees.compensation.edit')
      OR data.jwt_can_manage_employment_contracts(tenant_id, NULL)
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') = 'owner'
      OR (data.jwt_user_permissions() -> tenant_id::text -> 'global_permissions') @> '["*"]'::jsonb
    )
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_employee_permission(tenant_id, 'employees.compensation.edit')
      OR data.jwt_can_manage_employment_contracts(tenant_id, NULL)
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') = 'owner'
      OR (data.jwt_user_permissions() -> tenant_id::text -> 'global_permissions') @> '["*"]'::jsonb
    )
  );

GRANT SELECT, INSERT ON data.planning_cost_snapshots TO authenticated;
REVOKE UPDATE, DELETE ON data.planning_cost_snapshots FROM authenticated;

CREATE OR REPLACE VIEW api.planning_cost_snapshots
  WITH (security_invoker = true) AS
SELECT
  id, tenant_id, contract_id, on_date, snapshot,
  frozen_at, frozen_by, budget_label
FROM data.planning_cost_snapshots;

GRANT SELECT, INSERT ON api.planning_cost_snapshots TO authenticated;

CREATE OR REPLACE FUNCTION data.resolve_contract_planning_cost(
  p_contract_id uuid,
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
  v_c data.employment_contracts%ROWTYPE;
  v_comp data.employment_contract_compensation%ROWTYPE;
  v_wt data.employment_contract_workload_terms%ROWTYPE;
  v_has_comp boolean := false;
  v_has_wt boolean := false;
  v_method text := 'unavailable';
  v_currency text := 'EUR';
  v_hourly numeric;
  v_annual_minutes numeric;
  v_cost_per_minute numeric;
  v_employer_annual numeric;
  v_sources jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO v_c FROM data.employment_contracts WHERE id = p_contract_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_comp
  FROM data.employment_contract_compensation
  WHERE contract_id = p_contract_id;
  v_has_comp := FOUND;

  IF v_has_comp THEN
    v_currency := coalesce(v_comp.currency, 'EUR');
    v_sources := v_sources || jsonb_build_array('employment_contract_compensation');
  END IF;

  SELECT * INTO v_wt
  FROM data.employment_contract_workload_terms
  WHERE contract_id = p_contract_id;
  v_has_wt := FOUND;

  IF v_has_comp
     AND v_comp.pay_period = 'hourly'
     AND v_comp.gross_amount IS NOT NULL THEN
    v_method := 'hourly_rate';
    v_hourly := v_comp.gross_amount;
    RETURN jsonb_build_object(
      'formula_version', 'ec_wfm_p2_cost_v1',
      'method', v_method,
      'currency', v_currency,
      'contract_id', p_contract_id,
      'on_date', v_on,
      'hourly_cost', v_hourly,
      'cost_per_minute', round(v_hourly / 60.0, 6),
      'employer_annual_cost', v_comp.employer_annual_cost,
      'gross_amount', v_comp.gross_amount,
      'pay_period', v_comp.pay_period,
      'sources', v_sources
    );
  END IF;

  IF v_has_comp AND v_comp.employer_annual_cost IS NOT NULL THEN
    v_employer_annual := v_comp.employer_annual_cost;
    IF v_has_wt THEN
      v_sources := v_sources || jsonb_build_array('employment_contract_workload_terms');
      v_annual_minutes := CASE v_wt.commitment_basis
        WHEN 'week' THEN v_wt.ordinary_commitment_minutes::numeric * 52
        WHEN 'day' THEN v_wt.ordinary_commitment_minutes::numeric * 260
        WHEN 'year' THEN v_wt.ordinary_commitment_minutes::numeric
        ELSE NULL
      END;
    END IF;

    IF v_annual_minutes IS NULL THEN
      v_sources := v_sources || jsonb_build_array('employment_contracts.weekly_hours');
      v_annual_minutes := coalesce(v_c.weekly_hours, 0) * 60 * 52;
    END IF;

    v_cost_per_minute := v_employer_annual / nullif(v_annual_minutes, 0);
    v_method := 'derived_annual_cost';

    RETURN jsonb_build_object(
      'formula_version', 'ec_wfm_p2_cost_v1',
      'method', v_method,
      'currency', v_currency,
      'contract_id', p_contract_id,
      'on_date', v_on,
      'employer_annual_cost', v_employer_annual,
      'annual_ordinary_minutes', v_annual_minutes,
      'cost_per_minute', v_cost_per_minute,
      'hourly_cost', CASE
        WHEN v_cost_per_minute IS NULL THEN NULL
        ELSE round(v_cost_per_minute * 60, 4)
      END,
      'sources', v_sources
    );
  END IF;

  RETURN jsonb_build_object(
    'formula_version', 'ec_wfm_p2_cost_v1',
    'method', 'unavailable',
    'currency', v_currency,
    'contract_id', p_contract_id,
    'on_date', v_on,
    'sources', v_sources
  );
END;
$$;

COMMENT ON FUNCTION data.resolve_contract_planning_cost(uuid, date) IS
  'EC-WFM P2 §12: planning cost from hourly compensation or derived employer_annual_cost / annual minutes.';

GRANT EXECUTE ON FUNCTION data.resolve_contract_planning_cost(uuid, date)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.resolve_contract_planning_cost(
  p_contract_id uuid,
  p_on_date date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_c data.employment_contracts%ROWTYPE;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT * INTO v_c
  FROM data.employment_contracts
  WHERE id = p_contract_id AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'contract_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT data.jwt_can_view_employment_compensation(v_c.tenant_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN data.resolve_contract_planning_cost(p_contract_id, p_on_date);
END;
$$;

GRANT EXECUTE ON FUNCTION api.resolve_contract_planning_cost(uuid, date)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.freeze_planning_cost_snapshot(
  p_contract_id uuid,
  p_on_date date DEFAULT CURRENT_DATE,
  p_budget_label text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_c data.employment_contracts%ROWTYPE;
  v_snap jsonb;
  v_id uuid;
  v_can_manage boolean;
BEGIN
  SELECT * INTO v_c FROM data.employment_contracts WHERE id = p_contract_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'contract_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  v_can_manage := (
    data.jwt_has_employee_permission(v_c.tenant_id, 'employees.compensation.edit')
    OR data.jwt_can_manage_employment_contracts(v_c.tenant_id, NULL)
    OR (data.jwt_user_tenants() -> v_c.tenant_id::text ->> 'global_role') = 'owner'
    OR (data.jwt_user_permissions() -> v_c.tenant_id::text -> 'global_permissions') @> '["*"]'::jsonb
  );

  IF NOT v_can_manage THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT data.jwt_can_view_employment_compensation(v_c.tenant_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_snap := data.resolve_contract_planning_cost(p_contract_id, p_on_date);
  IF v_snap IS NULL THEN
    RAISE EXCEPTION 'contract_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  INSERT INTO data.planning_cost_snapshots (
    tenant_id, contract_id, on_date, snapshot, frozen_by, budget_label
  ) VALUES (
    v_c.tenant_id,
    p_contract_id,
    coalesce(p_on_date, CURRENT_DATE),
    v_snap,
    auth.uid(),
    p_budget_label
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION data.freeze_planning_cost_snapshot(uuid, date, text) IS
  'EC-WFM P2 §12: freeze resolve_contract_planning_cost output into planning_cost_snapshots.';

GRANT EXECUTE ON FUNCTION data.freeze_planning_cost_snapshot(uuid, date, text)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.freeze_planning_cost_snapshot(
  p_contract_id uuid,
  p_on_date date DEFAULT CURRENT_DATE,
  p_budget_label text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_c data.employment_contracts%ROWTYPE;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT * INTO v_c
  FROM data.employment_contracts
  WHERE id = p_contract_id AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'contract_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  RETURN data.freeze_planning_cost_snapshot(p_contract_id, p_on_date, p_budget_label);
END;
$$;

GRANT EXECUTE ON FUNCTION api.freeze_planning_cost_snapshot(uuid, date, text)
  TO authenticated, service_role;

COMMIT;

