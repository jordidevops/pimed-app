-- ADR-0003 — Retirada definitiva de work_schedules / employee_schedule_assignments.
-- Substituïdes per calendar_group_weekly_intervals + employee_weekly_intervals
-- (20261017000001). Cap consumidor viu de resolve_work_day/resolve_schedule_planner_day
-- les llegia ja des de 20260730000001; l'ADR-0002 (opció B) també queda superseded.
--
-- Entorn de desenvolupament: es permet eliminar taules/columnes legacy sense
-- migració de dades (db reset + reseed).

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. Helper de conversió one-way EX-03.2 — ja no té sentit sense work_schedules
-- ═══════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS api.convert_work_schedule_assignments_to_labor_calendar(uuid, date, date, boolean);

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. Triggers INSTEAD OF sobre api.work_schedule_intervals (20260521000013)
-- ═══════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS api.fn_wsi_instead_of_insert() CASCADE;
DROP FUNCTION IF EXISTS api.fn_wsi_instead_of_delete() CASCADE;

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. Vistes api.* (cascade per si queden grants/triggers residuals)
-- ═══════════════════════════════════════════════════════════════════════════

DROP VIEW IF EXISTS api.employee_schedule_assignments CASCADE;
DROP VIEW IF EXISTS api.work_schedule_intervals         CASCADE;
DROP VIEW IF EXISTS api.work_schedules                  CASCADE;

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. Taules base (ordre: filles abans de pares)
-- ═══════════════════════════════════════════════════════════════════════════

DROP TABLE IF EXISTS data.employee_schedule_assignments CASCADE;
DROP TABLE IF EXISTS data.work_schedule_intervals        CASCADE;
DROP TABLE IF EXISTS data.work_schedules                 CASCADE;

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. Seed helper de materialització massiva (20260913000001) — superseded per
--    calendar_group_weekly_intervals. Es substitueix per seed directe a
--    supabase/seeds/attendance_demo.sql (sense explosió de milers de files).
-- ═══════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS data.seed_acme_labor_calendar_weekly_base();

COMMENT ON FUNCTION data.resolve_schedule_planner_day IS
  'ADR-0003 (supersedeix ADR-0002): cascada = overrides puntuals > festiu assignat > base '
  'recurrent setmanal (employee_weekly > calendar_group_weekly) > undefined. '
  'work_schedules / employee_schedule_assignments retirades — mai van alimentar el resolver.';
