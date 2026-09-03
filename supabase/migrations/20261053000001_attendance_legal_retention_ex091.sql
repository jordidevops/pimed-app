-- =============================================================================
-- EX-09.1 — Retenció legal configurable + purge batched (RD 8/2019)
-- =============================================================================
-- Settings (JSONB tenants.settings):
--   attendance_retention_purge_enabled  boolean  default false
--   attendance_retention_years          int      default 4  (≥ 4)
-- Purge només via cron / service_role. Sense «Executar ara» manual.
-- Cascada: segments → entries → summaries → rollup days → compensation →
--          monthly reports (mes complet) → punches (bypass immutability GUC).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Bypass immutability per purge (GUC de sessió)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.trg_immutable_time_punches()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  -- EX-09.1: permet DELETE només dins purge SECURITY DEFINER
  IF TG_OP = 'DELETE'
     AND COALESCE(current_setting('app.allow_attendance_purge', true), '') = 'on'
  THEN
    RETURN OLD;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    -- GDPR: anonimització geo (E5)
    IF OLD.geo_anonymized_at IS NULL
       AND NEW.geo_anonymized_at IS NOT NULL
       AND NEW.geo_lat IS NULL AND NEW.geo_lng IS NULL
       AND NEW.geo IS NULL
       AND NEW.tenant_id = OLD.tenant_id
       AND NEW.site_id = OLD.site_id
       AND NEW.employee_id = OLD.employee_id
       AND NEW.punch_type = OLD.punch_type
       AND NEW.occurred_at = OLD.occurred_at
       AND NEW.client_op_id = OLD.client_op_id
    THEN
      RETURN NEW;
    END IF;

    -- Append-only anomalies
    IF NEW.tenant_id = OLD.tenant_id
       AND NEW.site_id IS NOT DISTINCT FROM OLD.site_id
       AND NEW.employee_id = OLD.employee_id
       AND NEW.device_id IS NOT DISTINCT FROM OLD.device_id
       AND NEW.location_id IS NOT DISTINCT FROM OLD.location_id
       AND NEW.client_op_id IS NOT DISTINCT FROM OLD.client_op_id
       AND NEW.punch_type = OLD.punch_type
       AND NEW.occurred_at = OLD.occurred_at
       AND NEW.received_at IS NOT DISTINCT FROM OLD.received_at
       AND NEW.source IS NOT DISTINCT FROM OLD.source
       AND NEW.notes IS NOT DISTINCT FROM OLD.notes
       AND NEW.pause_type IS NOT DISTINCT FROM OLD.pause_type
       AND NEW.geo_lat IS NOT DISTINCT FROM OLD.geo_lat
       AND NEW.geo_lng IS NOT DISTINCT FROM OLD.geo_lng
       AND NEW.geo IS NOT DISTINCT FROM OLD.geo
       AND NEW.geo_anonymized_at IS NOT DISTINCT FROM OLD.geo_anonymized_at
       AND NEW.location_name_snapshot IS NOT DISTINCT FROM OLD.location_name_snapshot
       AND NEW.device_name_snapshot IS NOT DISTINCT FROM OLD.device_name_snapshot
       AND COALESCE(NEW.anomaly_codes, ARRAY[]::text[]) @> COALESCE(OLD.anomaly_codes, ARRAY[]::text[])
    THEN
      RETURN NEW;
    END IF;
  END IF;

  RAISE EXCEPTION 'time_punches_immutable: UPDATE i DELETE no permesos (RDL 8/2019)'
    USING ERRCODE = 'check_violation';
END;
$$;

COMMENT ON FUNCTION data.trg_immutable_time_punches() IS
  'Immutabilitat punch: bloqueja mutacions; permet anonimització geo, append-only anomaly_codes i DELETE amb GUC app.allow_attendance_purge=on (EX-09.1).';

-- -----------------------------------------------------------------------------
-- 2. Taula de runs de purge
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS data.attendance_retention_purge_runs (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  cutoff_date     date NOT NULL,
  batch_limit     int  NOT NULL DEFAULT 5000,
  punches_deleted int  NOT NULL DEFAULT 0,
  entries_deleted int  NOT NULL DEFAULT 0,
  summaries_deleted int NOT NULL DEFAULT 0,
  segments_deleted int NOT NULL DEFAULT 0,
  rollups_deleted int  NOT NULL DEFAULT 0,
  ledger_deleted  int  NOT NULL DEFAULT 0,
  reports_deleted int  NOT NULL DEFAULT 0,
  status          text NOT NULL DEFAULT 'running'
                    CHECK (status IN ('running', 'completed', 'idle', 'error')),
  error_message   text,
  started_at      timestamptz NOT NULL DEFAULT now(),
  finished_at     timestamptz
);

CREATE INDEX IF NOT EXISTS idx_attendance_retention_purge_runs_tenant
  ON data.attendance_retention_purge_runs (tenant_id, started_at DESC);

ALTER TABLE data.attendance_retention_purge_runs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS attendance_retention_purge_runs_select ON data.attendance_retention_purge_runs;
CREATE POLICY attendance_retention_purge_runs_select
  ON data.attendance_retention_purge_runs
  FOR SELECT
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR data.jwt_has_permission(tenant_id, 'attendance.export')
    )
  );

-- -----------------------------------------------------------------------------
-- 3. Batch purge SECURITY DEFINER
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.purge_attendance_older_than_batch(
  p_tenant_id uuid,
  p_before    date,
  p_limit     int DEFAULT 5000
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_enabled   boolean;
  v_years     int;
  v_floor     date;
  v_limit     int := GREATEST(COALESCE(p_limit, 5000), 1);
  v_run_id    uuid;
  v_punch_ids uuid[];
  v_days      int;
  v_punches   int := 0;
  v_entries   int := 0;
  v_summaries int := 0;
  v_segments  int := 0;
  v_rollups   int := 0;
  v_ledger    int := 0;
  v_reports   int := 0;
  v_status    text := 'idle';
BEGIN
  IF p_tenant_id IS NULL OR p_before IS NULL THEN
    RAISE EXCEPTION 'invalid_args: tenant_id and before required'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT
    COALESCE((t.settings ->> 'attendance_retention_purge_enabled')::boolean, false),
    GREATEST(COALESCE((t.settings ->> 'attendance_retention_years')::int, 4), 4)
  INTO v_enabled, v_years
  FROM data.tenants t
  WHERE t.id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'tenant_not_found: %', p_tenant_id
      USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT v_enabled THEN
    RAISE EXCEPTION 'retention_purge_disabled'
      USING ERRCODE = 'check_violation';
  END IF;

  v_floor := (CURRENT_DATE - make_interval(years => v_years))::date;
  IF p_before > v_floor THEN
    RAISE EXCEPTION 'retention_floor_violation: cutoff % exceeds legal floor % (% years)',
      p_before, v_floor, v_years
      USING ERRCODE = 'check_violation';
  END IF;

  -- Floor absolut de 4 anys tot i settings
  IF p_before > (CURRENT_DATE - INTERVAL '4 years')::date THEN
    RAISE EXCEPTION 'retention_absolute_floor: cutoff must be ≤ current_date - 4 years'
      USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO data.attendance_retention_purge_runs (
    tenant_id, cutoff_date, batch_limit, status
  ) VALUES (
    p_tenant_id, p_before, v_limit, 'running'
  )
  RETURNING id INTO v_run_id;

  -- Selecciona punches antics (batch)
  SELECT COALESCE(array_agg(id ORDER BY occurred_at), ARRAY[]::uuid[])
  INTO v_punch_ids
  FROM (
    SELECT id, occurred_at
    FROM data.time_punches
    WHERE tenant_id = p_tenant_id
      AND occurred_at < (p_before::timestamptz)
    ORDER BY occurred_at ASC
    LIMIT v_limit
  ) sub;

  v_days := (
    SELECT COUNT(DISTINCT (employee_id, (occurred_at AT TIME ZONE 'Europe/Madrid')::date))
    FROM data.time_punches
    WHERE id = ANY (v_punch_ids)
  );

  BEGIN
    PERFORM set_config('app.allow_attendance_purge', 'on', true);

    -- Dies afectats pels punches del batch + dies òrfens (summaries/entries sense punches)
    CREATE TEMP TABLE _purge_days ON COMMIT DROP AS
    SELECT DISTINCT employee_id, work_date
    FROM (
      SELECT
        tp.employee_id,
        (tp.occurred_at AT TIME ZONE 'Europe/Madrid')::date AS work_date
      FROM data.time_punches tp
      WHERE tp.id = ANY (v_punch_ids)
      UNION
      SELECT tds.employee_id, tds.work_date
      FROM data.time_daily_summaries tds
      WHERE tds.tenant_id = p_tenant_id
        AND tds.work_date < p_before
        AND NOT EXISTS (
          SELECT 1 FROM data.time_punches tp2
          WHERE tp2.tenant_id = p_tenant_id
            AND tp2.employee_id = tds.employee_id
            AND (tp2.occurred_at AT TIME ZONE 'Europe/Madrid')::date = tds.work_date
            AND tp2.occurred_at >= (p_before::timestamptz)
        )
      LIMIT v_limit
    ) d;

    -- 1) segments
    WITH del AS (
      DELETE FROM data.time_activity_segments s
      USING _purge_days d
      WHERE s.tenant_id = p_tenant_id
        AND s.employee_id = d.employee_id
        AND s.work_date = d.work_date
      RETURNING 1
    )
    SELECT COUNT(*) INTO v_segments FROM del;

    -- 2) entries
    WITH del AS (
      DELETE FROM data.time_entries e
      USING _purge_days d
      WHERE e.tenant_id = p_tenant_id
        AND e.employee_id = d.employee_id
        AND e.work_date = d.work_date
      RETURNING 1
    )
    SELECT COUNT(*) INTO v_entries FROM del;

    -- 3) daily summaries
    WITH del AS (
      DELETE FROM data.time_daily_summaries tds
      USING _purge_days d
      WHERE tds.tenant_id = p_tenant_id
        AND tds.employee_id = d.employee_id
        AND tds.work_date = d.work_date
      RETURNING 1
    )
    SELECT COUNT(*) INTO v_summaries FROM del;

    -- 4) rollup day snapshots
    WITH del AS (
      DELETE FROM data.attendance_rollup_day_snapshots r
      USING _purge_days d
      WHERE r.tenant_id = p_tenant_id
        AND r.employee_id = d.employee_id
        AND r.work_date = d.work_date
      RETURNING 1
    )
    SELECT COUNT(*) INTO v_rollups FROM del;

    -- 5) compensation ledger (source date)
    WITH del AS (
      DELETE FROM data.time_compensation_ledger l
      USING _purge_days d
      WHERE l.tenant_id = p_tenant_id
        AND l.employee_id = d.employee_id
        AND l.source_work_date = d.work_date
      RETURNING 1
    )
    SELECT COUNT(*) INTO v_ledger FROM del;

    -- 6) punches (discrepancies CASCADE)
    IF cardinality(v_punch_ids) > 0 THEN
      WITH del AS (
        DELETE FROM data.time_punches tp
        WHERE tp.tenant_id = p_tenant_id
          AND tp.id = ANY (v_punch_ids)
        RETURNING 1
      )
      SELECT COUNT(*) INTO v_punches FROM del;
    END IF;

    -- 7) monthly reports fully before cutoff (un cop per batch si hi ha dies)
    WITH del AS (
      DELETE FROM data.attendance_monthly_reports r
      WHERE r.tenant_id = p_tenant_id
        AND make_date(r.year, r.month, 1) + INTERVAL '1 month' - INTERVAL '1 day'
            < p_before::timestamp
      RETURNING 1
    )
    SELECT COUNT(*) INTO v_reports FROM del;

    PERFORM set_config('app.allow_attendance_purge', '', true);

    v_status := CASE
      WHEN v_punches = 0 AND v_summaries = 0 AND v_entries = 0 THEN 'idle'
      ELSE 'completed'
    END;

  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('app.allow_attendance_purge', '', true);
    UPDATE data.attendance_retention_purge_runs
    SET status = 'error',
        error_message = SQLERRM,
        finished_at = now(),
        punches_deleted = v_punches,
        entries_deleted = v_entries,
        summaries_deleted = v_summaries,
        segments_deleted = v_segments,
        rollups_deleted = v_rollups,
        ledger_deleted = v_ledger,
        reports_deleted = v_reports
    WHERE id = v_run_id;
    RAISE;
  END;

  UPDATE data.attendance_retention_purge_runs
  SET status = v_status,
      finished_at = now(),
      punches_deleted = v_punches,
      entries_deleted = v_entries,
      summaries_deleted = v_summaries,
      segments_deleted = v_segments,
      rollups_deleted = v_rollups,
      ledger_deleted = v_ledger,
      reports_deleted = v_reports
  WHERE id = v_run_id;

  RETURN jsonb_build_object(
    'run_id', v_run_id,
    'tenant_id', p_tenant_id,
    'cutoff_date', p_before,
    'status', v_status,
    'days_touched', COALESCE(v_days, 0),
    'punches_deleted', v_punches,
    'entries_deleted', v_entries,
    'summaries_deleted', v_summaries,
    'segments_deleted', v_segments,
    'rollups_deleted', v_rollups,
    'ledger_deleted', v_ledger,
    'reports_deleted', v_reports
  );
END;
$$;

COMMENT ON FUNCTION data.purge_attendance_older_than_batch(uuid, date, int) IS
  'EX-09.1: esborra un batch de dades d''assistència més antigues que cutoff (floor ≥4 anys). Només service_role.';

REVOKE ALL ON FUNCTION data.purge_attendance_older_than_batch(uuid, date, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.purge_attendance_older_than_batch(uuid, date, int) TO service_role;

-- -----------------------------------------------------------------------------
-- 4. Orchestrator diari (un tenant per tick, pressup de temps)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.run_attendance_retention_purge(
  p_tenant_id uuid DEFAULT NULL,
  p_batch_limit int DEFAULT 5000,
  p_max_batches int DEFAULT 10
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant    record;
  v_years     int;
  v_cutoff    date;
  v_batches   int := 0;
  v_max       int := GREATEST(COALESCE(p_max_batches, 10), 1);
  v_limit     int := GREATEST(COALESCE(p_batch_limit, 5000), 1);
  v_result    jsonb;
  v_results   jsonb := '[]'::jsonb;
  v_started   timestamptz := clock_timestamp();
BEGIN
  -- Un tenant: explícit o el primer amb flag ON (round-robin per darrer run)
  FOR v_tenant IN
    SELECT t.id,
           GREATEST(COALESCE((t.settings ->> 'attendance_retention_years')::int, 4), 4) AS years
    FROM data.tenants t
    WHERE COALESCE((t.settings ->> 'attendance_retention_purge_enabled')::boolean, false) = true
      AND (p_tenant_id IS NULL OR t.id = p_tenant_id)
    ORDER BY (
      SELECT MAX(r.started_at)
      FROM data.attendance_retention_purge_runs r
      WHERE r.tenant_id = t.id
    ) NULLS FIRST,
    t.id
    LIMIT 1
  LOOP
    v_years := v_tenant.years;
    v_cutoff := (CURRENT_DATE - make_interval(years => v_years))::date;

    WHILE v_batches < v_max
      AND (clock_timestamp() - v_started) < interval '30 seconds'
    LOOP
      v_result := data.purge_attendance_older_than_batch(v_tenant.id, v_cutoff, v_limit);
      v_results := v_results || jsonb_build_array(v_result);
      v_batches := v_batches + 1;

      IF (v_result ->> 'status') = 'idle'
         OR COALESCE((v_result ->> 'punches_deleted')::int, 0) = 0
      THEN
        EXIT;
      END IF;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object(
    'batches', v_batches,
    'results', v_results,
    'elapsed_ms', (EXTRACT(EPOCH FROM (clock_timestamp() - v_started)) * 1000)::int
  );
END;
$$;

REVOKE ALL ON FUNCTION api.run_attendance_retention_purge(uuid, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.run_attendance_retention_purge(uuid, int, int) TO service_role;

-- -----------------------------------------------------------------------------
-- 5. RPC lectura darrer run (gestors)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.get_attendance_retention_purge_status()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_row       record;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_active_tenant'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT (
    (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    OR data.jwt_has_permission(v_tenant_id, 'attendance.export')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT *
  INTO v_row
  FROM data.attendance_retention_purge_runs
  WHERE tenant_id = v_tenant_id
  ORDER BY started_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('has_run', false);
  END IF;

  RETURN jsonb_build_object(
    'has_run', true,
    'id', v_row.id,
    'cutoff_date', v_row.cutoff_date,
    'status', v_row.status,
    'punches_deleted', v_row.punches_deleted,
    'entries_deleted', v_row.entries_deleted,
    'summaries_deleted', v_row.summaries_deleted,
    'started_at', v_row.started_at,
    'finished_at', v_row.finished_at,
    'error_message', v_row.error_message
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_attendance_retention_purge_status() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_attendance_retention_purge_status() TO authenticated;

-- -----------------------------------------------------------------------------
-- 6. Cron diari (03:20 UTC)
-- -----------------------------------------------------------------------------

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('attendance-retention-purge');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;

    PERFORM cron.schedule(
      'attendance-retention-purge',
      '20 3 * * *',
      $cron$SELECT api.run_attendance_retention_purge(NULL, 5000, 10)$cron$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'EX-09.1: no s''ha pogut programar cron attendance-retention-purge: %', SQLERRM;
END;
$$;

NOTIFY pgrst, 'reload schema';
