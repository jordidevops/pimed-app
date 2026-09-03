-- =============================================================================
-- Migration: 20260513000004_audit_logs_perf_indexes.sql
-- Propòsit : Millora de rendiment per consultes d'auditoria del backoffice.
--
-- Query principal impactada:
--   WHERE tenant_id = ?
--   ORDER BY created_at DESC
--   LIMIT/OFFSET
--
-- Sense índex compost, PostgreSQL fa bitmap scan + sort sobre moltes files del
-- tenant. Amb índex (tenant_id, created_at DESC) pot servir directament els
-- primers resultats ja ordenats.
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_audit_logs_tenant_created_at_desc
  ON data.audit_logs (tenant_id, created_at DESC);
