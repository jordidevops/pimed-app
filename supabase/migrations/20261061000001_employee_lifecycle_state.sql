-- =============================================================================
-- M-ES-01 — lifecycle_state persistit + backfill + guarda d'escriptura directa
-- =============================================================================

ALTER TABLE data.employees
  ADD COLUMN IF NOT EXISTS lifecycle_state text,
  ADD COLUMN IF NOT EXISTS lifecycle_since date,
  ADD COLUMN IF NOT EXISTS lifecycle_updated_at timestamptz;

UPDATE data.employees
SET lifecycle_state = CASE
  WHEN status = 'terminated' THEN 'terminated'
  ELSE 'active'
END
WHERE lifecycle_state IS NULL;

ALTER TABLE data.employees
  ALTER COLUMN lifecycle_state SET DEFAULT 'active',
  ALTER COLUMN lifecycle_state SET NOT NULL;

ALTER TABLE data.employees
  DROP CONSTRAINT IF EXISTS employees_lifecycle_state_chk;

ALTER TABLE data.employees
  ADD CONSTRAINT employees_lifecycle_state_chk
  CHECK (lifecycle_state IN (
    'candidate', 'onboarding', 'active',
    'on_leave', 'departure', 'offboarding', 'terminated'
  ));

COMMENT ON COLUMN data.employees.lifecycle_state IS
  'Estat de cicle de vida ELM. Només el modifica trg_sync_employee_lifecycle_state.';

-- Impedeix UPDATE directe des d''authenticated (single-writer ES-D2).
CREATE OR REPLACE FUNCTION data.trg_guard_employee_lifecycle_state()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.lifecycle_state IS DISTINCT FROM NEW.lifecycle_state
     OR OLD.lifecycle_since IS DISTINCT FROM NEW.lifecycle_since
     OR OLD.lifecycle_updated_at IS DISTINCT FROM NEW.lifecycle_updated_at THEN
    IF current_setting('data.lifecycle_state_write', true) IS DISTINCT FROM '1' THEN
      RAISE EXCEPTION 'lifecycle_state_readonly'
        USING ERRCODE = 'check_violation',
              HINT = 'Use employee_lifecycle_events via api.transition_employee_lifecycle';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_employee_lifecycle_state ON data.employees;
CREATE TRIGGER trg_guard_employee_lifecycle_state
  BEFORE UPDATE OF lifecycle_state, lifecycle_since, lifecycle_updated_at
  ON data.employees
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_guard_employee_lifecycle_state();

-- Actualitza api.employees amb camps lifecycle
DROP VIEW IF EXISTS api.employee_hr_profiles CASCADE;
DROP VIEW IF EXISTS api.employee_directory CASCADE;
DROP VIEW IF EXISTS api.employees CASCADE;

CREATE VIEW api.employees
  WITH (security_invoker = true) AS
SELECT
  e.id,
  e.tenant_id,
  e.site_id,
  e.user_id,
  e.department_id,
  e.full_name,
  e.email,
  e.phone,
  e.job_title,
  e.status,
  e.starts_on,
  e.ends_on,
  e.weekly_hours,
  e.calendar_group_id,
  e.location_consent_given,
  e.location_consent_at,
  e.location_consent_version,
  e.attendance_geo_enabled,
  e.attendance_work_profile,
  e.punch_only_at_stations,
  e.lifecycle_state,
  e.lifecycle_since,
  e.lifecycle_updated_at,
  e.created_at,
  e.updated_at
FROM data.employees e;

CREATE VIEW api.employee_directory
  WITH (security_invoker = true) AS
SELECT
  e.id,
  e.tenant_id,
  e.site_id,
  e.department_id,
  e.user_id,
  e.full_name,
  e.job_title,
  e.status,
  e.lifecycle_state,
  e.starts_on,
  e.ends_on,
  e.created_at,
  e.updated_at
FROM data.employees e;

CREATE VIEW api.employee_hr_profiles
  WITH (security_invoker = true, security_barrier = true) AS
SELECT
  e.id,
  e.tenant_id,
  e.document_id,
  e.metadata,
  e.created_at,
  e.updated_at
FROM data.employees e
WHERE data.jwt_can_view_employee_private(e.tenant_id, e.site_id, e.user_id);

GRANT SELECT ON api.employee_directory TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.employees TO authenticated;
GRANT SELECT, UPDATE ON api.employee_hr_profiles TO authenticated;

NOTIFY pgrst, 'reload schema';
