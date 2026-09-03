-- =============================================================================
-- M-EC-06 — Employment contract as attendance driver (EC-6 mínim)
-- Propagate calendar_group_id + weekly_hours (+ dates) onto employees on activate.
-- resolve_employee_contract_terms for effective terms. NOT a work-plan cascade layer.
-- =============================================================================

-- Optional FK (column already exists)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'employment_contracts_calendar_group_id_fkey'
  ) THEN
    ALTER TABLE data.employment_contracts
      ADD CONSTRAINT employment_contracts_calendar_group_id_fkey
      FOREIGN KEY (calendar_group_id) REFERENCES data.calendar_groups(id) ON DELETE SET NULL;
  END IF;
END $$;

-- Project active primary contract → employee flat fields (driver)
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

  -- Tenant match for calendar group
  IF v_c.calendar_group_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM data.calendar_groups g
    WHERE g.id = v_c.calendar_group_id AND g.tenant_id = v_c.tenant_id
  ) THEN
    RAISE EXCEPTION 'contract_calendar_group_tenant_mismatch' USING ERRCODE = 'foreign_key_violation';
  END IF;

  UPDATE data.employees e
  SET
    weekly_hours = CASE
      WHEN v_c.weekly_hours IS NOT NULL THEN v_c.weekly_hours
      ELSE e.weekly_hours
    END,
    calendar_group_id = CASE
      WHEN v_c.calendar_group_id IS NOT NULL THEN v_c.calendar_group_id
      ELSE e.calendar_group_id
    END,
    starts_on = CASE
      WHEN v_c.starts_on IS NOT NULL THEN v_c.starts_on
      ELSE e.starts_on
    END,
    ends_on = CASE
      WHEN v_c.ends_on IS NOT NULL THEN v_c.ends_on
      ELSE e.ends_on
    END,
    site_id = CASE
      WHEN v_c.site_id IS NOT NULL THEN v_c.site_id
      ELSE e.site_id
    END,
    department_id = CASE
      WHEN v_c.department_id IS NOT NULL THEN v_c.department_id
      ELSE e.department_id
    END,
    updated_at = now()
  WHERE e.id = v_c.employee_id
    AND e.tenant_id = v_c.tenant_id;
END;
$$;

REVOKE ALL ON FUNCTION data.project_employment_contract_onto_employee(uuid) FROM PUBLIC;

-- Effective contractual terms for a date (not daily schedule)
CREATE OR REPLACE FUNCTION data.resolve_employee_contract_terms(
  p_employee_id uuid,
  p_work_date   date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_on  date := coalesce(p_work_date, CURRENT_DATE);
  v_emp data.employees%ROWTYPE;
  v_c   data.employment_contracts%ROWTYPE;
BEGIN
  SELECT * INTO v_emp FROM data.employees WHERE id = p_employee_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT c.* INTO v_c
  FROM data.employment_contracts c
  WHERE c.tenant_id = v_emp.tenant_id
    AND c.employee_id = p_employee_id
    AND c.is_primary
    AND c.lifecycle_status IN ('active', 'scheduled', 'ended')
    AND c.starts_on <= v_on
    AND (c.ends_on IS NULL OR c.ends_on >= v_on)
  ORDER BY
    CASE c.lifecycle_status WHEN 'active' THEN 0 WHEN 'scheduled' THEN 1 ELSE 2 END,
    c.starts_on DESC
  LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'contract_id', v_c.id,
      'weekly_hours', v_c.weekly_hours,
      'fte', v_c.fte,
      'calendar_group_id', v_c.calendar_group_id,
      'site_id', v_c.site_id,
      'department_id', v_c.department_id,
      'job_position_id', v_c.job_position_id,
      'work_entry_source', v_c.work_entry_source,
      'starts_on', v_c.starts_on,
      'ends_on', v_c.ends_on,
      'source', 'employment_contract'
    );
  END IF;

  RETURN jsonb_build_object(
    'contract_id', NULL,
    'weekly_hours', v_emp.weekly_hours,
    'fte', NULL,
    'calendar_group_id', v_emp.calendar_group_id,
    'site_id', v_emp.site_id,
    'department_id', v_emp.department_id,
    'job_position_id', v_emp.job_position_id,
    'work_entry_source', 'schedule',
    'starts_on', v_emp.starts_on,
    'ends_on', v_emp.ends_on,
    'source', 'employee_fallback'
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.resolve_employee_contract_terms(
  p_employee_id uuid,
  p_work_date   date DEFAULT CURRENT_DATE
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
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN data.resolve_employee_contract_terms(p_employee_id, p_work_date);
END;
$$;

REVOKE EXECUTE ON FUNCTION api.resolve_employee_contract_terms(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.resolve_employee_contract_terms(uuid, date) TO authenticated;

-- Wire projection into transition (active)
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

  IF p_to_status IN ('scheduled', 'active')
     AND v_c.signature_requirement <> 'none'
     AND v_c.signature_status IN ('rejected', 'expired') THEN
    RAISE EXCEPTION 'signature_blocked' USING ERRCODE = 'check_violation';
  END IF;

  IF p_to_status = 'scheduled' THEN
    IF v_c.lifecycle_status <> 'draft' THEN
      RAISE EXCEPTION 'invalid_contract_transition' USING ERRCODE = 'check_violation';
    END IF;
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
    IF v_c.lifecycle_status = 'draft'
       AND v_c.signature_requirement <> 'none'
       AND v_c.signature_status <> 'completed' THEN
      RAISE EXCEPTION 'signature_required' USING ERRCODE = 'check_violation';
    END IF;
    IF v_c.starts_on > CURRENT_DATE THEN
      RAISE EXCEPTION 'contract_not_started' USING ERRCODE = 'check_violation';
    END IF;
    UPDATE data.employment_contracts SET
      lifecycle_status = 'active',
      activated_at = coalesce(activated_at, now()),
      updated_at = now()
    WHERE id = v_c.id;

    PERFORM data.project_employment_contract_onto_employee(v_c.id);

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

-- Reconcile + project newly activated contracts
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
  v_id uuid;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  IF NOT data.jwt_can_manage_employment_contracts(v_tenant_id, NULL) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  FOR v_id IN
    UPDATE data.employment_contracts c
    SET lifecycle_status = 'active',
        activated_at = coalesce(activated_at, now()),
        updated_at = now()
    WHERE c.tenant_id = v_tenant_id
      AND (p_employee_id IS NULL OR c.employee_id = p_employee_id)
      AND c.lifecycle_status = 'scheduled'
      AND c.starts_on <= v_on
      AND (c.ends_on IS NULL OR c.ends_on >= v_on)
    RETURNING c.id
  LOOP
    PERFORM data.project_employment_contract_onto_employee(v_id);
    v_count := v_count + 1;
  END LOOP;

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
