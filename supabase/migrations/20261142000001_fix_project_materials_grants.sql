-- =============================================================================
-- Migration: 20261142000001_fix_project_materials_grants.sql
-- Purpose : Fix 403 on api.project_materials / api.project_expenses
--
-- Why:
-- - Both views are WITH (security_invoker = true), so Postgres checks the
--   caller's privileges on the underlying data.* tables.
-- - authenticated had RLS policies but was missing table GRANTs
--   (same class of bug as 20260511000007_fix_work_logs_select_grant).
--
-- Result:
-- - GRANT SELECT/INSERT/UPDATE/DELETE on data.project_materials and
--   data.project_expenses to authenticated.
-- - RLS remains the effective row filter.
-- =============================================================================

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE data.project_materials TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE data.project_expenses TO authenticated;
