-- Refresh CIR api views so columns added after initial CREATE (content_selection,
-- show_checklists/tasks/materials, retention_*) are visible to PostgREST selects.
-- Postgres expands SELECT * at CREATE VIEW time; new table columns are not picked up
-- until the view is replaced.

CREATE OR REPLACE VIEW api.customer_intervention_report_drafts
  WITH (security_invoker = true) AS
SELECT d.*
FROM data.customer_intervention_report_drafts d
WHERE d.tenant_id = data.active_tenant_id();

CREATE OR REPLACE VIEW api.customer_intervention_report_versions
  WITH (security_invoker = true) AS
SELECT v.*
FROM data.customer_intervention_report_versions v
WHERE v.tenant_id = data.active_tenant_id();

GRANT SELECT ON api.customer_intervention_report_drafts TO authenticated;
GRANT SELECT ON api.customer_intervention_report_versions TO authenticated;

NOTIFY pgrst, 'reload schema';
