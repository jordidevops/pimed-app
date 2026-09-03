-- EC-WFM P0 §6 convenio/categoria catalogs + §4.6 immutable work context snapshots
-- Depends on: 20261096000001 (resolve_employee_work_context), employment_contracts EC1

BEGIN;

-- =============================================================================
-- §6 — Catalogs: collective_agreements / professional_categories
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.collective_agreements (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  code         text NOT NULL,
  name         text NOT NULL,
  valid_from   date,
  valid_to     date,
  document_id  uuid REFERENCES data.documents(id) ON DELETE SET NULL,
  is_active    boolean NOT NULL DEFAULT true,
  metadata     jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT collective_agreements_code_not_blank CHECK (btrim(code) <> ''),
  CONSTRAINT collective_agreements_name_not_blank CHECK (btrim(name) <> ''),
  CONSTRAINT collective_agreements_valid_range CHECK (
    valid_to IS NULL OR valid_from IS NULL OR valid_to >= valid_from
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_collective_agreements_tenant_code
  ON data.collective_agreements (tenant_id, code);

CREATE INDEX IF NOT EXISTS idx_collective_agreements_tenant_active
  ON data.collective_agreements (tenant_id, is_active)
  WHERE is_active = true;

CREATE TABLE IF NOT EXISTS data.professional_categories (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  collective_agreement_id  uuid REFERENCES data.collective_agreements(id) ON DELETE SET NULL,
  code                     text NOT NULL,
  name                     text NOT NULL,
  professional_group       text,
  contribution_group       text,
  default_weekly_hours     numeric,
  is_active                boolean NOT NULL DEFAULT true,
  metadata                 jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT professional_categories_code_not_blank CHECK (btrim(code) <> ''),
  CONSTRAINT professional_categories_name_not_blank CHECK (btrim(name) <> '')
);

-- PG15+: NULLS NOT DISTINCT so (tenant, NULL, code) is unique
CREATE UNIQUE INDEX IF NOT EXISTS uq_professional_categories_tenant_agreement_code
  ON data.professional_categories (tenant_id, collective_agreement_id, code) NULLS NOT DISTINCT;

CREATE INDEX IF NOT EXISTS idx_professional_categories_tenant_active
  ON data.professional_categories (tenant_id, is_active)
  WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_professional_categories_agreement
  ON data.professional_categories (collective_agreement_id)
  WHERE collective_agreement_id IS NOT NULL;

DROP TRIGGER IF EXISTS trg_set_updated_at_collective_agreements ON data.collective_agreements;
CREATE TRIGGER trg_set_updated_at_collective_agreements
  BEFORE UPDATE ON data.collective_agreements
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

DROP TRIGGER IF EXISTS trg_set_updated_at_professional_categories ON data.professional_categories;
CREATE TRIGGER trg_set_updated_at_professional_categories
  BEFORE UPDATE ON data.professional_categories
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

-- Category tenant + agreement tenant consistency
CREATE OR REPLACE FUNCTION data.enforce_professional_category_tenant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF NEW.collective_agreement_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM data.collective_agreements ca
    WHERE ca.id = NEW.collective_agreement_id AND ca.tenant_id = NEW.tenant_id
  ) THEN
    RAISE EXCEPTION 'professional_category_agreement_tenant_mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_professional_category_tenant ON data.professional_categories;
CREATE TRIGGER trg_enforce_professional_category_tenant
  BEFORE INSERT OR UPDATE ON data.professional_categories
  FOR EACH ROW EXECUTE FUNCTION data.enforce_professional_category_tenant();

-- Cannot hard-delete catalog rows referenced by employment_contracts
CREATE OR REPLACE FUNCTION data.trg_prevent_delete_referenced_collective_agreement()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM data.employment_contracts c
    WHERE c.collective_agreement_id = OLD.id
  ) THEN
    RAISE EXCEPTION 'collective_agreement_in_use_deactivate_instead'
      USING ERRCODE = 'foreign_key_violation',
            HINT = 'Set is_active=false instead of deleting a referenced collective agreement.';
  END IF;
  RETURN OLD;
END;
$$;

CREATE OR REPLACE FUNCTION data.trg_prevent_delete_referenced_professional_category()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM data.employment_contracts c
    WHERE c.professional_category_id = OLD.id
  ) THEN
    RAISE EXCEPTION 'professional_category_in_use_deactivate_instead'
      USING ERRCODE = 'foreign_key_violation',
            HINT = 'Set is_active=false instead of deleting a referenced professional category.';
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_prevent_delete_referenced_collective_agreement ON data.collective_agreements;
CREATE TRIGGER trg_prevent_delete_referenced_collective_agreement
  BEFORE DELETE ON data.collective_agreements
  FOR EACH ROW EXECUTE FUNCTION data.trg_prevent_delete_referenced_collective_agreement();

DROP TRIGGER IF EXISTS trg_prevent_delete_referenced_professional_category ON data.professional_categories;
CREATE TRIGGER trg_prevent_delete_referenced_professional_category
  BEFORE DELETE ON data.professional_categories
  FOR EACH ROW EXECUTE FUNCTION data.trg_prevent_delete_referenced_professional_category();

-- =============================================================================
-- employment_contracts FK columns
-- =============================================================================

ALTER TABLE data.employment_contracts
  ADD COLUMN IF NOT EXISTS collective_agreement_id uuid
    REFERENCES data.collective_agreements(id) ON DELETE SET NULL;

ALTER TABLE data.employment_contracts
  ADD COLUMN IF NOT EXISTS professional_category_id uuid
    REFERENCES data.professional_categories(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_employment_contracts_collective_agreement
  ON data.employment_contracts (collective_agreement_id)
  WHERE collective_agreement_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_employment_contracts_professional_category
  ON data.employment_contracts (professional_category_id)
  WHERE professional_category_id IS NOT NULL;

-- Extend tenant match + category/agreement consistency on contracts
CREATE OR REPLACE FUNCTION data.enforce_employment_contract_tenant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_emp data.employees%ROWTYPE;
  v_cat_agreement uuid;
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

  IF NEW.collective_agreement_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM data.collective_agreements ca
    WHERE ca.id = NEW.collective_agreement_id AND ca.tenant_id = NEW.tenant_id
  ) THEN
    RAISE EXCEPTION 'contract_collective_agreement_tenant_mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF NEW.professional_category_id IS NOT NULL THEN
    SELECT pc.collective_agreement_id INTO v_cat_agreement
    FROM data.professional_categories pc
    WHERE pc.id = NEW.professional_category_id AND pc.tenant_id = NEW.tenant_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'contract_professional_category_tenant_mismatch'
        USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF NEW.collective_agreement_id IS NOT NULL
       AND v_cat_agreement IS NOT NULL
       AND NEW.collective_agreement_id IS DISTINCT FROM v_cat_agreement THEN
      RAISE EXCEPTION 'contract_category_agreement_mismatch'
        USING ERRCODE = 'check_violation',
              HINT = 'professional_category.collective_agreement_id must match contract.collective_agreement_id when both are set.';
    END IF;
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

-- Material fields: convenio / categoria
CREATE OR REPLACE FUNCTION data.trg_employment_contracts_draft_only_edit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.lifecycle_status IN ('active', 'ended', 'cancelled')
     AND NEW.lifecycle_status = OLD.lifecycle_status THEN
    IF NEW.starts_on IS DISTINCT FROM OLD.starts_on
       OR NEW.ends_on IS DISTINCT FROM OLD.ends_on
       OR NEW.weekly_hours IS DISTINCT FROM OLD.weekly_hours
       OR NEW.fte IS DISTINCT FROM OLD.fte
       OR NEW.site_id IS DISTINCT FROM OLD.site_id
       OR NEW.department_id IS DISTINCT FROM OLD.department_id
       OR NEW.job_position_id IS DISTINCT FROM OLD.job_position_id
       OR NEW.calendar_group_id IS DISTINCT FROM OLD.calendar_group_id
       OR NEW.is_primary IS DISTINCT FROM OLD.is_primary
       OR NEW.contract_type_id IS DISTINCT FROM OLD.contract_type_id
       OR NEW.collective_agreement_id IS DISTINCT FROM OLD.collective_agreement_id
       OR NEW.professional_category_id IS DISTINCT FROM OLD.professional_category_id THEN
      RAISE EXCEPTION 'contract_immutable_use_successor'
        USING ERRCODE = 'check_violation',
              HINT = 'Material changes on active/ended/cancelled contracts require successor/renewal RPCs.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- =============================================================================
-- RLS + grants + api views (catalogs)
-- =============================================================================

ALTER TABLE data.collective_agreements ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.professional_categories ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS collective_agreements_select ON data.collective_agreements;
CREATE POLICY collective_agreements_select ON data.collective_agreements
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_can_view_employment_contracts(tenant_id, NULL)
  );

DROP POLICY IF EXISTS collective_agreements_write ON data.collective_agreements;
CREATE POLICY collective_agreements_write ON data.collective_agreements
  FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_can_manage_employment_contracts(tenant_id, NULL)
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_can_manage_employment_contracts(tenant_id, NULL)
  );

DROP POLICY IF EXISTS professional_categories_select ON data.professional_categories;
CREATE POLICY professional_categories_select ON data.professional_categories
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_can_view_employment_contracts(tenant_id, NULL)
  );

DROP POLICY IF EXISTS professional_categories_write ON data.professional_categories;
CREATE POLICY professional_categories_write ON data.professional_categories
  FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_can_manage_employment_contracts(tenant_id, NULL)
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_can_manage_employment_contracts(tenant_id, NULL)
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON data.collective_agreements TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.professional_categories TO authenticated;

CREATE OR REPLACE VIEW api.collective_agreements
  WITH (security_invoker = true) AS
SELECT
  id, tenant_id, code, name, valid_from, valid_to, document_id,
  is_active, metadata, created_at, updated_at
FROM data.collective_agreements;

CREATE OR REPLACE VIEW api.professional_categories
  WITH (security_invoker = true) AS
SELECT
  id, tenant_id, collective_agreement_id, code, name,
  professional_group, contribution_group, default_weekly_hours,
  is_active, metadata, created_at, updated_at
FROM data.professional_categories;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.collective_agreements TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.professional_categories TO authenticated;

-- Refresh employment_contracts api view with convenio FKs (append cols; keep order for REPLACE)
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
  collective_agreement_id, professional_category_id
FROM data.employment_contracts;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.employment_contracts TO authenticated;

-- =============================================================================
-- resolve_employee_work_context — real convenio_categoria (keep resolver_version v1)
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

  v_site := coalesce(v_site, v_emp.site_id);
  v_dept := coalesce(v_dept, v_emp.department_id);
  v_cal := coalesce(v_cal, v_emp.calendar_group_id);
  v_hours := coalesce(v_hours, v_emp.weekly_hours);
  v_job := coalesce(v_job, v_emp.job_position_id);

  v_site_eligible := CASE
    WHEN p_requested_site_id IS NULL THEN true
    WHEN v_site IS NULL THEN true
    ELSE p_requested_site_id = v_site
  END;

  v_tz := coalesce(data.get_site_timezone(coalesce(p_requested_site_id, v_site), v_emp.tenant_id), 'Europe/Madrid');

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
    'resolver_version', 'ec_wfm_p0_v1',
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
    'workload', jsonb_build_object(
      'weekly_hours', v_hours,
      'source', CASE WHEN v_source = 'employment_contract' THEN 'contract' ELSE 'employee_fallback' END
    ),
    'placement', jsonb_build_object(
      'site_id', v_site,
      'department_id', v_dept,
      'job_position_id', v_job,
      'source', CASE WHEN v_source = 'employment_contract' THEN 'contract' ELSE 'employee_fallback' END,
      'note', 'placement_periods deferred to P1'
    ),
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
      'flat_employee_used', v_source = 'employee_fallback'
    ),
    'conflicts', v_conflicts
  );
END;
$$;

COMMENT ON FUNCTION data.resolve_employee_work_context(uuid, date, uuid) IS
  'EC-WFM P0 §4.2: unified effective work context; convenio_categoria from contract (§6).';

-- =============================================================================
-- §4.6 — Immutable work context on time_daily_summaries
-- =============================================================================

ALTER TABLE data.time_daily_summaries
  ADD COLUMN IF NOT EXISTS employment_contract_id uuid
    REFERENCES data.employment_contracts(id) ON DELETE SET NULL;

ALTER TABLE data.time_daily_summaries
  ADD COLUMN IF NOT EXISTS work_context_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE data.time_daily_summaries
  ADD COLUMN IF NOT EXISTS work_context_frozen_at timestamptz;

ALTER TABLE data.time_daily_summaries
  ADD COLUMN IF NOT EXISTS resolver_version text;

CREATE INDEX IF NOT EXISTS idx_time_daily_summaries_employment_contract
  ON data.time_daily_summaries (employment_contract_id)
  WHERE employment_contract_id IS NOT NULL;

COMMENT ON COLUMN data.time_daily_summaries.work_context_snapshot IS
  'EC-WFM P0 §4.6: frozen (or live-until-lock) compact resolve_employee_work_context payload.';
COMMENT ON COLUMN data.time_daily_summaries.work_context_frozen_at IS
  'When set (typically at payroll_locked_at), work_context_snapshot is immutable without GUC bypass.';

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
      'resolver_version', 'ec_wfm_p0_v1',
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
    'resolver_version', coalesce(v_ctx->>'resolver_version', 'ec_wfm_p0_v1'),
    'captured_at', v_captured_at
  );
END;
$$;

COMMENT ON FUNCTION data.capture_work_context_snapshot(uuid, date) IS
  'EC-WFM P0 §4.6: compact freeze payload from resolve_employee_work_context.';

CREATE OR REPLACE FUNCTION data.freeze_time_daily_summary_work_context(p_summary_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_row data.time_daily_summaries%ROWTYPE;
  v_capture jsonb;
BEGIN
  SELECT * INTO v_row FROM data.time_daily_summaries WHERE id = p_summary_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'time_daily_summary_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_row.work_context_frozen_at IS NOT NULL THEN
    RETURN;
  END IF;

  v_capture := data.capture_work_context_snapshot(v_row.employee_id, v_row.work_date);

  UPDATE data.time_daily_summaries
  SET
    work_context_snapshot = v_capture,
    employment_contract_id = NULLIF(v_capture->>'employment_contract_id', '')::uuid,
    resolver_version = v_capture->>'resolver_version',
    work_context_frozen_at = now()
  WHERE id = p_summary_id;
END;
$$;

COMMENT ON FUNCTION data.freeze_time_daily_summary_work_context(uuid) IS
  'EC-WFM P0 §4.6: capture+freeze work context once if not already frozen.';

CREATE OR REPLACE FUNCTION data.trg_time_daily_summaries_work_context()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_capture jsonb;
  v_bypass boolean;
BEGIN
  v_bypass := coalesce(current_setting('data.work_context_amendment', true), '') = '1';

  IF TG_OP = 'INSERT' THEN
    v_capture := data.capture_work_context_snapshot(NEW.employee_id, NEW.work_date);
    NEW.work_context_snapshot := v_capture;
    NEW.employment_contract_id := NULLIF(v_capture->>'employment_contract_id', '')::uuid;
    NEW.resolver_version := v_capture->>'resolver_version';
    IF NEW.payroll_locked_at IS NOT NULL THEN
      NEW.work_context_frozen_at := coalesce(NEW.work_context_frozen_at, now());
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE: immutable once locked or frozen (unless amendment GUC)
  IF (OLD.payroll_locked_at IS NOT NULL OR OLD.work_context_frozen_at IS NOT NULL)
     AND NOT v_bypass THEN
    IF NEW.employment_contract_id IS DISTINCT FROM OLD.employment_contract_id
       OR NEW.work_context_snapshot IS DISTINCT FROM OLD.work_context_snapshot
       OR NEW.resolver_version IS DISTINCT FROM OLD.resolver_version
       OR NEW.work_context_frozen_at IS DISTINCT FROM OLD.work_context_frozen_at THEN
      RAISE EXCEPTION 'work_context_immutable'
        USING ERRCODE = 'check_violation',
              HINT = 'Work context is frozen; use data.work_context_amendment=1 for audited amendments.';
    END IF;
    RETURN NEW;
  END IF;

  -- Transition into payroll lock: refresh once then freeze
  IF NEW.payroll_locked_at IS NOT NULL AND OLD.payroll_locked_at IS NULL THEN
    v_capture := data.capture_work_context_snapshot(NEW.employee_id, NEW.work_date);
    NEW.work_context_snapshot := v_capture;
    NEW.employment_contract_id := NULLIF(v_capture->>'employment_contract_id', '')::uuid;
    NEW.resolver_version := v_capture->>'resolver_version';
    NEW.work_context_frozen_at := now();
    RETURN NEW;
  END IF;

  -- Unlocked + unfrozen: keep snapshot in sync with live context
  IF NEW.payroll_locked_at IS NULL AND coalesce(NEW.work_context_frozen_at, OLD.work_context_frozen_at) IS NULL THEN
    v_capture := data.capture_work_context_snapshot(NEW.employee_id, NEW.work_date);
    NEW.work_context_snapshot := v_capture;
    NEW.employment_contract_id := NULLIF(v_capture->>'employment_contract_id', '')::uuid;
    NEW.resolver_version := v_capture->>'resolver_version';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_time_daily_summaries_work_context ON data.time_daily_summaries;
CREATE TRIGGER trg_time_daily_summaries_work_context
  BEFORE INSERT OR UPDATE ON data.time_daily_summaries
  FOR EACH ROW EXECUTE FUNCTION data.trg_time_daily_summaries_work_context();

-- api view: expose snapshot columns (append; keep order for REPLACE)
CREATE OR REPLACE VIEW api.time_daily_summaries
  WITH (security_invoker = true) AS
SELECT
  id, tenant_id, site_id, employee_id, work_date, day_type,
  expected_minutes, worked_minutes, break_minutes, overtime_minutes, absence_minutes,
  punch_count, presence_minutes, work_minutes, travel_minutes, effective_minutes,
  paid_minutes, regular_minutes, overtime_authorized_minutes,
  consolidation_meta, work_profile_snapshot,
  anomaly_codes, needs_review, status,
  approved_by, approved_at, exported_at, payroll_locked_at, recomputed_at,
  created_at, updated_at,
  employment_contract_id, work_context_snapshot, work_context_frozen_at, resolver_version
FROM data.time_daily_summaries;

GRANT SELECT ON api.time_daily_summaries TO authenticated;

COMMIT;


