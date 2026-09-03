-- =============================================================================
-- Migration: 20260521000012_fix_site_rls_policies.sql
--
-- Propòsit: Corregir bug d'ambigüitat de columna a les policies SELECT de
--           site_holiday_calendar_assignments i site_holiday_exclusions.
--
-- Bug: La policy original:
--   USING (EXISTS (
--     SELECT 1
--     FROM data.sites s
--     JOIN data.tenant_members tm ON tm.tenant_id = s.tenant_id
--      AND tm.user_id = auth.uid() AND tm.is_active = true
--     WHERE s.id = site_id   -- ← 'site_id' resolt com tm.site_id (no la col de la taula protegida)
--   ))
--
-- Resultat: global_members (tm.site_id IS NULL) mai veurien files.
--
-- Fix: Eliminar el JOIN amb tenant_members (que tenia la columna 'site_id' homònima)
--      i usar jwt_user_tenants() directament per comprovar pertinença al tenant.
-- =============================================================================

-- ─── 1. site_holiday_calendar_assignments ─────────────────────────────────────

DROP POLICY IF EXISTS shca_select ON data.site_holiday_calendar_assignments;

CREATE POLICY shca_select ON data.site_holiday_calendar_assignments FOR SELECT
  USING (EXISTS (
    SELECT 1
    FROM data.sites s
    WHERE s.id = site_holiday_calendar_assignments.site_id
      AND data.jwt_user_tenants() ? s.tenant_id::text
  ));


-- ─── 2. site_holiday_exclusions ───────────────────────────────────────────────

DROP POLICY IF EXISTS she_select ON data.site_holiday_exclusions;

CREATE POLICY she_select ON data.site_holiday_exclusions FOR SELECT
  USING (EXISTS (
    SELECT 1
    FROM data.sites s
    WHERE s.id = site_holiday_exclusions.site_id
      AND data.jwt_user_tenants() ? s.tenant_id::text
  ));
