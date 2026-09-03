-- =============================================================================
-- Migration: 20260511000007_fix_work_logs_select_grant.sql
-- Purpose : Fix 403 on api.work_logs (security_invoker view)
--
-- Why:
-- - api.work_logs is defined WITH (security_invoker = true), so Postgres checks
--   the caller privileges on underlying relation data.work_logs.
-- - authenticated had RLS policies on data.work_logs but was missing SELECT grant.
--
-- Result:
-- - GRANT SELECT on data.work_logs to authenticated.
-- - RLS remains the effective row filter (no broad data exposure).
-- =============================================================================

GRANT SELECT ON TABLE data.work_logs TO authenticated;
