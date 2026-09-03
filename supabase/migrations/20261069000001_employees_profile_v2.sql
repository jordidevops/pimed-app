-- =============================================================================
-- M-EHR-01 — Employees profile V2 (directori: code, names, photo path)
-- =============================================================================

ALTER TABLE data.employees
  ADD COLUMN IF NOT EXISTS employee_code text,
  ADD COLUMN IF NOT EXISTS legal_name text,
  ADD COLUMN IF NOT EXISTS preferred_name text,
  ADD COLUMN IF NOT EXISTS photo_object_path text;

COMMENT ON COLUMN data.employees.employee_code IS
  'Codi intern opcional per tenant. Únic quan informat.';
COMMENT ON COLUMN data.employees.legal_name IS
  'Nom legal (contractes / nòmina). full_name resta el label canònic UI.';
COMMENT ON COLUMN data.employees.preferred_name IS
  'Nom preferit / àlies visible al directori.';
COMMENT ON COLUMN data.employees.photo_object_path IS
  'Path a storage.objects al bucket privat employee-photos (sense URL pública).';

CREATE UNIQUE INDEX IF NOT EXISTS uq_employees_tenant_employee_code
  ON data.employees (tenant_id, employee_code)
  WHERE employee_code IS NOT NULL AND btrim(employee_code) <> '';

-- Recrear vistes API amb camps de perfil (mantenir security_invoker)
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
  e.legal_name,
  e.preferred_name,
  e.employee_code,
  e.photo_object_path,
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
  e.preferred_name,
  e.employee_code,
  e.photo_object_path,
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
