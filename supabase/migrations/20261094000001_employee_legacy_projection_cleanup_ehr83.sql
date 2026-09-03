-- =============================================================================
-- M-EHR-10 / EHR-8.3 — Legacy projection cleanup
--
-- Camps employees.starts_on / ends_on / weekly_hours queden com a projecció
-- (EC-6 project_employment_contract_onto_employee). Escriptures manuals
-- bloquejades quan hi ha contracte primary covering CURRENT_DATE.
-- Bypass: set_config('data.legacy_employee_projection','1', true) — usat per EC-6.
--
-- Rollback: DROP TRIGGER trg_employees_lock_legacy_terms; DROP FUNCTION ...
-- Les columnes NO es droppegen (lectures / assistència / import encara les usen).
-- =============================================================================

CREATE OR REPLACE FUNCTION data.employee_has_primary_contract_covering(
  p_employee_id uuid,
  p_on date DEFAULT CURRENT_DATE
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM data.employment_contracts c
    WHERE c.employee_id = p_employee_id
      AND c.is_primary
      AND c.lifecycle_status IN ('active', 'scheduled', 'ended')
      AND c.starts_on <= coalesce(p_on, CURRENT_DATE)
      AND (c.ends_on IS NULL OR c.ends_on >= coalesce(p_on, CURRENT_DATE))
  );
$$;

COMMENT ON FUNCTION data.employee_has_primary_contract_covering(uuid, date) IS
  'EHR-8.3: true si hi ha contracte primary covering la data (mateixa regla que get_effective).';

GRANT EXECUTE ON FUNCTION data.employee_has_primary_contract_covering(uuid, date) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.trg_employees_lock_legacy_terms()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  -- Bypass for EC-6 projection / controlled backfills
  IF coalesce(current_setting('data.legacy_employee_projection', true), '') = '1' THEN
    RETURN NEW;
  END IF;

  IF TG_OP <> 'UPDATE' THEN
    RETURN NEW;
  END IF;

  IF NOT (
    NEW.starts_on IS DISTINCT FROM OLD.starts_on
    OR NEW.ends_on IS DISTINCT FROM OLD.ends_on
    OR NEW.weekly_hours IS DISTINCT FROM OLD.weekly_hours
  ) THEN
    RETURN NEW;
  END IF;

  IF data.employee_has_primary_contract_covering(NEW.id, CURRENT_DATE) THEN
    RAISE EXCEPTION 'legacy_terms_locked'
      USING ERRCODE = 'check_violation',
            HINT = 'Edit starts_on/ends_on/weekly_hours via employment_contracts (effective contract exists).';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_employees_lock_legacy_terms ON data.employees;
CREATE TRIGGER trg_employees_lock_legacy_terms
  BEFORE UPDATE OF starts_on, ends_on, weekly_hours ON data.employees
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_employees_lock_legacy_terms();

COMMENT ON TRIGGER trg_employees_lock_legacy_terms ON data.employees IS
  'EHR-8.3: blocks manual edits to legacy projection fields when an effective primary contract exists.';

-- EC-6 projection must set the bypass GUC
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

COMMENT ON FUNCTION data.project_employment_contract_onto_employee(uuid) IS
  'EC-6/EHR-8.3: project active primary contract onto employee flat fields (bypass legacy lock).';
