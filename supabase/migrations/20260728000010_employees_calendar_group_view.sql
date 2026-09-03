-- Afegir calendar_group_id a la vista api.employees per exposar el grup de calendari.
-- Cal DROP + recrear perquè PostgreSQL no permet reordenar columnes amb CREATE OR REPLACE VIEW.
-- IMPORTANT: DROP CASCADE elimina els grants — s'han de restaurar explícitament.
DROP VIEW IF EXISTS api.employees CASCADE;

CREATE VIEW api.employees AS
SELECT
  id, tenant_id, site_id, user_id, department_id,
  full_name, email, phone, document_id, job_title,
  status, starts_on, ends_on, weekly_hours, metadata,
  calendar_group_id,
  created_at, updated_at
FROM data.employees;

-- Restaurar grants eliminats pel CASCADE
GRANT SELECT, INSERT, UPDATE, DELETE ON api.employees TO authenticated;
