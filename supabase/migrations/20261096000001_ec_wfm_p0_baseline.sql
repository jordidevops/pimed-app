-- =============================================================================
-- EC-WFM P0 — Baseline: vacation entitlement, work context, consumers, lock,
--             projection empty-value semantics.
-- Annex: plan-employment-contracts-inspiracio-orquest.md §4
-- Fallback legacy (sense contracte) preservat. No reobre EC-0..8.
-- Deferred: §4.6 snapshots immutables; §5 evaluate_employee_assignment complet;
--           ADRs formals abans de P1.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §4.1 — Effective vacation entitlement (same precedence as get_vacation_entitlement)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.resolve_effective_vacation_entitlement_id(
  p_tenant_id   uuid,
  p_employee_id uuid,
  p_year        int,
  p_leave_type  text DEFAULT 'vacation'
)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_dept uuid;
  v_id uuid;
BEGIN
  SELECT e.department_id INTO v_dept
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.tenant_id = p_tenant_id;

  SELECT ve.id INTO v_id
  FROM data.vacation_entitlements ve
  WHERE ve.tenant_id = p_tenant_id
    AND ve.year = p_year
    AND ve.leave_type = p_leave_type
    AND (
      (ve.scope = 'employee' AND ve.employee_id = p_employee_id)
      OR (ve.scope = 'department' AND ve.department_id = v_dept)
      OR (ve.scope = 'tenant')
    )
  ORDER BY CASE ve.scope
    WHEN 'employee' THEN 1
    WHEN 'department' THEN 2
    WHEN 'tenant' THEN 3
  END
  LIMIT 1;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION data.resolve_effective_vacation_entitlement_id(uuid, uuid, int, text) IS
  'EC-WFM P0 §4.1: single effective entitlement row (employee > department > tenant).';

CREATE OR REPLACE FUNCTION data.apply_vacation_entitlement_delta(
  p_tenant_id   uuid,
  p_employee_id uuid,
  p_year        int,
  p_delta_days  numeric,
  p_leave_type  text DEFAULT 'vacation'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF p_delta_days IS NULL OR p_delta_days = 0 THEN
    RETURN;
  END IF;

  v_id := data.resolve_effective_vacation_entitlement_id(
    p_tenant_id, p_employee_id, p_year, p_leave_type
  );

  IF v_id IS NULL THEN
    RETURN;
  END IF;

  UPDATE data.vacation_entitlements
  SET
    days_used = GREATEST(0, days_used + p_delta_days),
    updated_at = now()
  WHERE id = v_id;
END;
$$;

CREATE OR REPLACE FUNCTION data.trg_absence_entitlement_on_approve()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_old_days numeric := 0;
  v_new_days numeric := 0;
  v_year int;
BEGIN
  IF NEW.absence_type IS DISTINCT FROM 'vacation'
     AND (OLD.absence_type IS DISTINCT FROM 'vacation') THEN
    RETURN NEW;
  END IF;

  -- Days counted only while status is approved (and type vacation)
  IF OLD.absence_type = 'vacation' AND OLD.status = 'approved' THEN
    v_old_days := (OLD.end_date - OLD.start_date + 1)::numeric;
  END IF;

  IF NEW.absence_type = 'vacation' AND NEW.status = 'approved' THEN
    v_new_days := (NEW.end_date - NEW.start_date + 1)::numeric;
  END IF;

  IF v_old_days = v_new_days
     AND OLD.start_date IS NOT DISTINCT FROM NEW.start_date
     AND OLD.end_date IS NOT DISTINCT FROM NEW.end_date
     AND OLD.status IS NOT DISTINCT FROM NEW.status
     AND OLD.absence_type IS NOT DISTINCT FROM NEW.absence_type THEN
    RETURN NEW;
  END IF;

  -- Reverse old year consumption
  IF v_old_days <> 0 THEN
    v_year := EXTRACT(YEAR FROM OLD.start_date)::int;
    PERFORM data.apply_vacation_entitlement_delta(
      OLD.tenant_id, OLD.employee_id, v_year, -v_old_days, 'vacation'
    );
  END IF;

  -- Apply new year consumption
  IF v_new_days <> 0 THEN
    v_year := EXTRACT(YEAR FROM NEW.start_date)::int;
    PERFORM data.apply_vacation_entitlement_delta(
      NEW.tenant_id, NEW.employee_id, v_year, v_new_days, 'vacation'
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_absence_entitlement_on_approve ON data.employee_absences;
CREATE TRIGGER trg_absence_entitlement_on_approve
  AFTER UPDATE OF status, start_date, end_date, absence_type ON data.employee_absences
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_absence_entitlement_on_approve();

COMMENT ON FUNCTION data.trg_absence_entitlement_on_approve() IS
  'EC-WFM P0 §4.1: adjust exactly one effective entitlement on approve/cancel/date change.';

-- ---------------------------------------------------------------------------
-- §4.2 — resolve_employee_work_context
-- ---------------------------------------------------------------------------

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

  -- Divergences vs flat projection (informational)
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

  -- Effective site for ops: terms site, else flat
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
    'convenio_categoria', jsonb_build_object(
      'note', 'deferred until contract leave/convenio terms (P1)'
    ),
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
  'EC-WFM P0 §4.2: unified effective work context; legacy fallback when no contract.';

CREATE OR REPLACE FUNCTION api.resolve_employee_work_context(
  p_employee_id uuid,
  p_work_date date DEFAULT CURRENT_DATE,
  p_requested_site_id uuid DEFAULT NULL
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
    data.jwt_can_view_employment_contracts(v_emp.tenant_id, v_emp.site_id)
    OR (v_emp.user_id IS NOT NULL AND v_emp.user_id = auth.uid())
    OR data.jwt_has_permission(v_emp.tenant_id, 'employees.view', v_emp.site_id)
    OR data.jwt_has_permission(v_emp.tenant_id, 'attendance.view_all', v_emp.site_id)
    OR data.jwt_has_permission(v_emp.tenant_id, 'labor_calendar.view', v_emp.site_id)
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN data.resolve_employee_work_context(p_employee_id, p_work_date, p_requested_site_id);
END;
$$;

REVOKE EXECUTE ON FUNCTION api.resolve_employee_work_context(uuid, date, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.resolve_employee_work_context(uuid, date, uuid) TO authenticated;

-- Thin helpers for consumers (§4.3)
CREATE OR REPLACE FUNCTION data.employee_effective_weekly_hours(
  p_employee_id uuid,
  p_on date DEFAULT CURRENT_DATE
)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT NULLIF(data.resolve_employee_work_context(p_employee_id, p_on, NULL)->'workload'->>'weekly_hours', '')::numeric;
$$;

CREATE OR REPLACE FUNCTION data.employee_effective_site_id(
  p_employee_id uuid,
  p_on date DEFAULT CURRENT_DATE
)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT NULLIF(data.resolve_employee_work_context(p_employee_id, p_on, NULL)->'placement'->>'site_id', '')::uuid;
$$;

GRANT EXECUTE ON FUNCTION data.employee_effective_weekly_hours(uuid, date) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION data.employee_effective_site_id(uuid, date) TO authenticated, service_role;

-- Local calendar date for tenant/site (activation/end without bare CURRENT_DATE)
CREATE OR REPLACE FUNCTION data.local_work_date(
  p_tenant_id uuid,
  p_site_id uuid DEFAULT NULL,
  p_at timestamptz DEFAULT clock_timestamp()
)
RETURNS date
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT (coalesce(p_at, clock_timestamp())
    AT TIME ZONE coalesce(data.get_site_timezone(p_site_id, p_tenant_id), 'Europe/Madrid'))::date;
$$;

GRANT EXECUTE ON FUNCTION data.local_work_date(uuid, uuid, timestamptz) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- §4.3 — Key consumers use effective weekly_hours / site
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.evaluate_opening_claim_eligibility(
  p_opening_id uuid,
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_opening data.shift_openings;
  v_emp record;
  v_blocks text[] := '{}';
  v_warnings text[] := '{}';
  v_avail text;
  v_week_start date;
  v_shift_min int;
  v_week_min int;
  v_labor jsonb;
  v_issue jsonb;
  v_eff_site uuid;
  v_eff_hours numeric;
BEGIN
  SELECT * INTO v_opening FROM data.shift_openings WHERE id = p_opening_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'blocks', jsonb_build_array('opening_not_found'), 'warnings', '[]'::jsonb);
  END IF;

  SELECT e.id, e.tenant_id, e.status, e.full_name
  INTO v_emp
  FROM data.employees e WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    v_blocks := array_append(v_blocks, 'employee_not_found');
  ELSE
    v_eff_site := data.employee_effective_site_id(p_employee_id, v_opening.opening_date);
    v_eff_hours := data.employee_effective_weekly_hours(p_employee_id, v_opening.opening_date);

    IF v_emp.status <> 'active' THEN
      v_blocks := array_append(v_blocks, 'employee_not_active');
    ELSIF v_eff_site IS DISTINCT FROM v_opening.site_id THEN
      v_blocks := array_append(v_blocks, 'employee_wrong_site');
    END IF;
  END IF;

  IF v_opening.status <> 'open' THEN
    v_blocks := array_append(v_blocks, 'opening_not_open');
  END IF;

  IF v_opening.places_filled >= v_opening.places_total THEN
    v_blocks := array_append(v_blocks, 'opening_full');
  END IF;

  IF v_opening.opens_at IS NOT NULL AND v_opening.opens_at > clock_timestamp() THEN
    v_blocks := array_append(v_blocks, 'opening_not_yet_open');
  END IF;

  IF v_opening.closes_at IS NOT NULL AND v_opening.closes_at < clock_timestamp() THEN
    v_blocks := array_append(v_blocks, 'opening_closed');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM data.employee_absences ea
    WHERE ea.employee_id = p_employee_id
      AND ea.status IN ('approved', 'active', 'closed')
      AND ea.start_date <= v_opening.opening_date
      AND COALESCE(ea.end_date, ea.start_date) >= v_opening.opening_date
  ) THEN
    v_blocks := array_append(v_blocks, 'employee_on_absence');
  END IF;

  IF v_opening.role_id IS NOT NULL AND v_emp.id IS NOT NULL THEN
    IF NOT data.employee_meets_role_qualifications(p_employee_id, v_opening.role_id, v_opening.opening_date) THEN
      v_blocks := array_append(v_blocks, 'role_qualifications_unmet');
    END IF;
  END IF;

  IF v_emp.id IS NOT NULL AND EXISTS (
    SELECT 1
    FROM data.shift_slots ss
    WHERE ss.employee_id = p_employee_id
      AND ss.status <> 'cancelled'
      AND ss.slot_date BETWEEN v_opening.opening_date - 1 AND v_opening.opening_date + 1
      AND data.shift_slots_overlap(
        v_opening.opening_date, v_opening.start_time, v_opening.end_time,
        ss.slot_date, ss.start_time, ss.end_time
      )
  ) THEN
    v_blocks := array_append(v_blocks, 'SHIFT_OVERLAP');
  END IF;

  IF v_emp.id IS NOT NULL THEN
    v_avail := data.employee_availability_for_window(
      p_employee_id, v_opening.opening_date, v_opening.start_time, v_opening.end_time
    );
    IF v_avail = 'unavailable' THEN
      v_blocks := array_append(v_blocks, 'availability_unavailable');
    ELSIF v_avail = 'unknown' THEN
      v_warnings := array_append(v_warnings, 'availability_unknown');
    END IF;
  END IF;

  IF v_emp.id IS NOT NULL THEN
    v_week_start := date_trunc('week', v_opening.opening_date::timestamptz)::date;
    v_shift_min := ROUND(EXTRACT(EPOCH FROM CASE
      WHEN v_opening.end_time > v_opening.start_time THEN v_opening.end_time - v_opening.start_time
      ELSE interval '24 hours' + (v_opening.end_time - v_opening.start_time)
    END) / 60)::int;

    SELECT COALESCE(SUM(ROUND(EXTRACT(EPOCH FROM CASE
      WHEN ss.end_time > ss.start_time THEN ss.end_time - ss.start_time
      ELSE interval '24 hours' + (ss.end_time - ss.start_time)
    END) / 60)), 0)::int
    INTO v_week_min
    FROM data.shift_slots ss
    WHERE ss.employee_id = p_employee_id
      AND ss.slot_date >= v_week_start
      AND ss.slot_date <= v_week_start + 6
      AND ss.status <> 'cancelled';

    IF v_eff_hours IS NOT NULL
       AND (v_week_min + v_shift_min) > (v_eff_hours * 60)
    THEN
      v_warnings := array_append(v_warnings, 'WEEKLY_HOURS_EXCEEDED');
    END IF;
  END IF;

  IF v_emp.id IS NOT NULL THEN
    v_labor := data.evaluate_labor_rules_for_window(
      p_employee_id, v_opening.site_id, v_opening.opening_date,
      v_opening.start_time, v_opening.end_time, NULL
    );
    FOR v_issue IN SELECT * FROM jsonb_array_elements(COALESCE(v_labor->'issues', '[]'::jsonb))
    LOOP
      IF v_issue->>'severity' = 'block' THEN
        v_blocks := array_append(v_blocks, v_issue->>'code');
      ELSE
        v_warnings := array_append(v_warnings, v_issue->>'code');
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'ok', cardinality(v_blocks) = 0,
    'blocks', to_jsonb(v_blocks),
    'warnings', to_jsonb(v_warnings),
    'availability', v_avail,
    'labor', v_labor,
    'opening_id', p_opening_id,
    'employee_id', p_employee_id
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- §4.4 — lock_version on employment_contracts
-- ---------------------------------------------------------------------------

ALTER TABLE data.employment_contracts
  ADD COLUMN IF NOT EXISTS lock_version int NOT NULL DEFAULT 1;

COMMENT ON COLUMN data.employment_contracts.lock_version IS
  'EC-WFM P0 §4.4: optimistic concurrency; bump on every update.';

CREATE OR REPLACE FUNCTION data.trg_employment_contracts_lock_version()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    NEW.lock_version := coalesce(OLD.lock_version, 1) + 1;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_employment_contracts_lock_version ON data.employment_contracts;
CREATE TRIGGER trg_employment_contracts_lock_version
  BEFORE UPDATE ON data.employment_contracts
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_employment_contracts_lock_version();

-- Guard: only draft (or scheduled unsigned edge) may be edited in place for material fields.
-- Active/ended/cancelled/cancelled changes go through transition/renewal RPCs.
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
       OR NEW.contract_type_id IS DISTINCT FROM OLD.contract_type_id THEN
      RAISE EXCEPTION 'contract_immutable_use_successor'
        USING ERRCODE = 'check_violation',
              HINT = 'Material changes on active/ended/cancelled contracts require successor/renewal RPCs.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_employment_contracts_draft_only_edit ON data.employment_contracts;
CREATE TRIGGER trg_employment_contracts_draft_only_edit
  BEFORE UPDATE ON data.employment_contracts
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_employment_contracts_draft_only_edit();

-- Prefer local_work_date in transition activate path (patch transition_employment_contract)
-- Soft: helper available; full RPC rewrite deferred — callers can pass explicit dates.

-- ---------------------------------------------------------------------------
-- §4.5 — Projection: weekly_hours/ends_on always from contract; site/dept/cal coalesce
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.project_employment_contract_onto_employee(
  p_contract_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_c data.employment_contracts%ROWTYPE;
BEGIN
  SELECT * INTO v_c FROM data.employment_contracts WHERE id = p_contract_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF NOT (v_c.is_primary AND v_c.lifecycle_status = 'active') THEN
    RETURN;
  END IF;

  IF v_c.calendar_group_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM data.calendar_groups g
    WHERE g.id = v_c.calendar_group_id AND g.tenant_id = v_c.tenant_id
  ) THEN
    RAISE EXCEPTION 'contract_calendar_group_tenant_mismatch' USING ERRCODE = 'foreign_key_violation';
  END IF;

  PERFORM set_config('data.legacy_employee_projection', '1', true);

  -- Owned by contract when active primary: weekly_hours + ends_on always applied (incl. NULL).
  -- site/dept/calendar_group: NULL on contract = not governed → keep flat.
  UPDATE data.employees e
  SET
    weekly_hours = v_c.weekly_hours,
    starts_on = v_c.starts_on,
    ends_on = v_c.ends_on,
    calendar_group_id = COALESCE(v_c.calendar_group_id, e.calendar_group_id),
    site_id = COALESCE(v_c.site_id, e.site_id),
    department_id = COALESCE(v_c.department_id, e.department_id),
    updated_at = now()
  WHERE e.id = v_c.employee_id
    AND e.tenant_id = v_c.tenant_id;
END;
$$;

REVOKE ALL ON FUNCTION data.project_employment_contract_onto_employee(uuid) FROM PUBLIC;

COMMENT ON FUNCTION data.project_employment_contract_onto_employee(uuid) IS
  'EC-6/P0 §4.5: project active primary contract; weekly_hours/ends_on always overwrite (no silent keep).';

NOTIFY pgrst, 'reload schema';
