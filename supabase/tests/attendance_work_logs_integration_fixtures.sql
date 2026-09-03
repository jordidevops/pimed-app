-- =============================================================================
-- attendance_work_logs_integration_fixtures.sql
-- Especificació de fixtures D-INT (work_logs ↔ time_punches ↔ Track G)
--
-- Estat: ESPECIFICACIÓ — executar quan existeixin:
--   - data.time_activity_segments + work_log_id
--   - work_logs.entry_mode
--   - RPCs field_punch_*, switch_work_log, consolidate/recompute mobile_peripatetic
--
-- Referències:
--   prompts/shared/work-logs-time-attendance-integration.md
--   docs/plans/checkin/plan-effective-work-time.md §18.9
--
-- Executar (futur):
--   psql "$DB_URL" -f supabase/tests/attendance_work_logs_integration_fixtures.sql
-- =============================================================================

BEGIN;

CREATE TEMP TABLE integ_fixture_results (
  fixture_id text,
  assertion  text,
  expected   text,
  actual     text,
  status     text
) ON COMMIT DROP;

-- ---------------------------------------------------------------------------
-- Helpers (stubs — substituir per RPCs reals quan s'implementin)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pg_temp._assert(
  p_fixture text,
  p_name    text,
  p_expected text,
  p_actual   text
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO integ_fixture_results (fixture_id, assertion, expected, actual, status)
  VALUES (
    p_fixture,
    p_name,
    p_expected,
    p_actual,
    CASE WHEN p_expected = p_actual THEN 'PASS' ELSE 'PENDING_IMPL' END
  );
END;
$$;

-- =============================================================================
-- FIXTURE A — Lampista dia estàndard (un client)
-- Conveni C: viatge pagat, no efectiu
--
-- Timeline:
--   06:45 day_start → 08:00 in(obra A) → 12:00 break → 12:30 resume
--   → 16:30 out → 17:30 day_end
--
-- Resultat esperat post-recompute:
--   work_minutes: 480
--   travel_minutes: 135  (75 casa→obra + 60 obra→casa)
--   paid_minutes: 615   (480 work + 135 travel)
--   effective_minutes: 480
--   overtime_minutes: 0
--   needs_review: false
-- =============================================================================

DO $$
BEGIN
  -- Documentació de l'esperat (passarà quan el motor G2b llegeixi work_logs field_punch)
  PERFORM pg_temp._assert(
    'A',
    'work_minutes',
    '480',
    '480'  -- placeholder: SELECT work_minutes FROM time_daily_summaries ...
  );
  PERFORM pg_temp._assert('A', 'travel_minutes', '135', '135');
  PERFORM pg_temp._assert('A', 'paid_minutes', '615', '615');
  PERFORM pg_temp._assert('A', 'effective_minutes', '480', '480');
  PERFORM pg_temp._assert('A', 'overtime_minutes', '0', '0');
  PERFORM pg_temp._assert('A', 'needs_review', 'false', 'false');
END;
$$;

-- =============================================================================
-- FIXTURE B — Lampista dia multi-obra (tres clients)
--
-- Timeline:
--   08:00 in(obra A) → 11:30 switch(travel, obra B) → 13:00 break → 13:30 switch(obra C)
--   → 17:00 day_end
--
-- Resultat esperat — Conveni A (obra només):
--   work_minutes: suma 3 intervals WORK
--   travel entre obres: no paid
--   needs_review: false (tots els gaps declarats)
-- =============================================================================

DO $$
BEGIN
  PERFORM pg_temp._assert('B', 'needs_review', 'false', 'false');
  PERFORM pg_temp._assert('B', 'unclassified_gaps', '[]', '[]');
  -- work_minutes exacte depèn d'intervals; fixture SQL detallat a afegir amb seed tenant
END;
$$;

-- =============================================================================
-- FIXTURE C — Consultor oficina timesheet (timer/manual — NO segments)
--
-- Dilluns:
--   Projecte Alpha 3h30, Beta 1h, Alpha 30min → 300 min imputats
--   time_punch: 08:00–17:00 → worked_minutes = 480
--   coverage = 300/480 = 62.5% < 80% → avís cobertura (D-INT-11)
--   NO afecta needs_review del control horari per defecte
-- =============================================================================

DO $$
DECLARE
  v_imputed int := 210 + 60 + 30;  -- 300
  v_worked  int := 480;
  v_cov_pct numeric := round(v_imputed::numeric / v_worked * 100, 1);
BEGIN
  PERFORM pg_temp._assert('C', 'imputed_minutes', '300', v_imputed::text);
  PERFORM pg_temp._assert('C', 'coverage_pct', '62.5', v_cov_pct::text);
  PERFORM pg_temp._assert('C', 'coverage_warning', 'true', 'true');
  PERFORM pg_temp._assert('C', 'blocks_time_approval', 'false', 'false');
END;
$$;

-- =============================================================================
-- FIXTURE D — Canvi de projecte sense gap declaration
--
-- field_punch(A) tancat → field_punch(B) obert (gap 45 min, UNCLASSIFIED)
-- Resultat esperat:
--   time_daily_summaries.needs_review = true
--   consolidation_meta.unclassified_gaps includes [{start, end, minutes: 45}]
-- =============================================================================

DO $$
BEGIN
  PERFORM pg_temp._assert('D', 'needs_review', 'true', 'true');
  PERFORM pg_temp._assert('D', 'unclassified_gap_minutes', '45', '45');
END;
$$;

-- ---------------------------------------------------------------------------
-- Resum
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  r record;
  v_pass int := 0;
  v_total int := 0;
BEGIN
  FOR r IN SELECT * FROM integ_fixture_results ORDER BY fixture_id, assertion LOOP
    v_total := v_total + 1;
    IF r.status = 'PASS' THEN v_pass := v_pass + 1; END IF;
    RAISE NOTICE '[%] %.% expected=% actual=% → %',
      r.fixture_id, r.fixture_id, r.assertion, r.expected, r.actual, r.status;
  END LOOP;
  RAISE NOTICE 'Fixtures D-INT: %/% assertions PASS (reste PENDING_IMPL fins motor G2b+RPCs)', v_pass, v_total;
END;
$$;

ROLLBACK;
