-- EX-03.2 / ADR-0002 — Opció B: congelar work_schedules (no reactivar al resolver).
-- Font de veritat setmanal: labor_calendar_overrides (+ apply_weekly_pattern_to_calendar).
--
-- 1) REVOKE escriptura API sobre plantilles/assignacions setmanals legacy
-- 2) Helper one-way: expandir assignments → labor_calendar_overrides (horitzó acotat)
-- 3) seed_acme_attendance_punches: llegir intervals del calendari laboral, no work_schedules

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. Freeze writes (SELECT roman per lectura / migració / tests)
-- ═══════════════════════════════════════════════════════════════════════════

REVOKE INSERT, UPDATE, DELETE ON api.work_schedules FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON api.work_schedule_intervals FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON api.employee_schedule_assignments FROM authenticated;

COMMENT ON TABLE data.work_schedules IS
  'LEGACY (EX-03.2 opció B). Plantilles setmanals desconnectades del resolver des de 20260730. '
  'Escriptura API revocada. SoT setmanal: labor_calendar_overrides / apply_weekly_pattern_to_calendar. '
  'No reactivar sense ADR nou.';

COMMENT ON TABLE data.employee_schedule_assignments IS
  'LEGACY (EX-03.2 opció B). Assignacions a work_schedules; no alimenten resolve_work_day. '
  'Usar convert_work_schedule_assignments_to_labor_calendar per migració one-way.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. Conversió one-way (manager/owner)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION api.convert_work_schedule_assignments_to_labor_calendar(
  p_tenant_id   uuid,
  p_from_date   date,
  p_to_date     date,
  p_dry_run     boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_day           date;
  v_dow           int;
  v_emp           record;
  v_sched_id      uuid;
  v_intervals     jsonb;
  v_work_start    time;
  v_work_end      time;
  v_inserted      int := 0;
  v_skipped_exist int := 0;
  v_skipped_empty int := 0;
  v_employees     int := 0;
  v_is_holiday    boolean;
BEGIN
  IF p_tenant_id IS NULL OR p_from_date IS NULL OR p_to_date IS NULL THEN
    RAISE EXCEPTION 'invalid_parameter: tenant_id, from_date i to_date són obligatoris'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_to_date < p_from_date THEN
    RAISE EXCEPTION 'invalid_date_range: to_date ha de ser >= from_date'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF (p_to_date - p_from_date) > 400 THEN
    RAISE EXCEPTION 'invalid_date_range: horitzó màxim 400 dies'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF NOT (
      data.jwt_has_permission(p_tenant_id, 'labor_calendar.manage')
      OR data.jwt_has_permission(p_tenant_id, 'attendance.manage')
      OR ((data.jwt_user_tenants() -> p_tenant_id::text) ->> 'global_role') = ANY (ARRAY['owner', 'manager'])
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage o rol manager/owner requerit'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  FOR v_emp IN
    SELECT e.id AS employee_id, e.site_id
    FROM data.employees e
    WHERE e.tenant_id = p_tenant_id
      AND e.status = 'active'
    ORDER BY e.id
  LOOP
    v_employees := v_employees + 1;

    SELECT esa.schedule_id INTO v_sched_id
    FROM data.employee_schedule_assignments esa
    WHERE esa.employee_id = v_emp.employee_id
      AND esa.tenant_id = p_tenant_id
      AND esa.effective_from <= p_to_date
      AND (esa.effective_to IS NULL OR esa.effective_to > p_from_date)
    ORDER BY esa.effective_from DESC
    LIMIT 1;

    IF v_sched_id IS NULL THEN
      CONTINUE;
    END IF;

    v_day := p_from_date;
    WHILE v_day <= p_to_date LOOP
      -- Respectar vigència de l'assignació
      IF NOT EXISTS (
        SELECT 1 FROM data.employee_schedule_assignments esa
        WHERE esa.employee_id = v_emp.employee_id
          AND esa.schedule_id = v_sched_id
          AND esa.effective_from <= v_day
          AND (esa.effective_to IS NULL OR esa.effective_to > v_day)
      ) THEN
        v_day := v_day + 1;
        CONTINUE;
      END IF;

      -- No sobreescriure festius assignats
      SELECT EXISTS (
        SELECT 1 FROM data.planner_site_holidays(p_tenant_id, v_emp.site_id, v_day, v_day)
      ) INTO v_is_holiday;
      IF v_is_holiday THEN
        v_day := v_day + 1;
        CONTINUE;
      END IF;

      -- Ja hi ha override (qualsevol capa) per aquest empleat/data → no tocar
      IF EXISTS (
        SELECT 1
        FROM data.resolve_labor_calendar_for_employee(
          p_tenant_id, v_emp.site_id, v_emp.employee_id, v_day, false
        ) lc
        WHERE lc.labor_day_type IS DISTINCT FROM 'undefined'
      ) THEN
        v_skipped_exist := v_skipped_exist + 1;
        v_day := v_day + 1;
        CONTINUE;
      END IF;

      v_dow := EXTRACT(DOW FROM v_day)::int;

      SELECT COALESCE(
               jsonb_agg(
                 jsonb_build_object(
                   'start', to_char(wsi.start_time, 'HH24:MI'),
                   'end',   to_char(wsi.end_time, 'HH24:MI')
                 )
                 ORDER BY wsi.start_time
               ),
               '[]'::jsonb
             ),
             MIN(wsi.start_time),
             MAX(wsi.end_time)
        INTO v_intervals, v_work_start, v_work_end
      FROM data.work_schedule_intervals wsi
      WHERE wsi.schedule_id = v_sched_id
        AND wsi.day_of_week = v_dow;

      IF v_intervals IS NULL OR jsonb_array_length(v_intervals) = 0 THEN
        v_skipped_empty := v_skipped_empty + 1;
        v_day := v_day + 1;
        CONTINUE;
      END IF;

      IF NOT p_dry_run THEN
        INSERT INTO data.labor_calendar_overrides (
          tenant_id, site_id, group_id, employee_id,
          calendar_date, day_type, day_name,
          work_start, work_end, work_intervals
        ) VALUES (
          p_tenant_id, v_emp.site_id, NULL, v_emp.employee_id,
          v_day, 'work', 'Migrat des de work_schedules (EX-03.2)',
          v_work_start, v_work_end, v_intervals
        )
        ON CONFLICT ON CONSTRAINT labor_calendar_overrides_unique DO NOTHING;
      END IF;

      v_inserted := v_inserted + 1;
      v_day := v_day + 1;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object(
    'tenant_id', p_tenant_id,
    'from_date', p_from_date,
    'to_date', p_to_date,
    'dry_run', p_dry_run,
    'employees_scanned', v_employees,
    'would_insert_or_inserted', v_inserted,
    'skipped_existing_labor', v_skipped_exist,
    'skipped_no_intervals', v_skipped_empty,
    'decision', 'EX-03.2 option_b'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.convert_work_schedule_assignments_to_labor_calendar(uuid, date, date, boolean)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.convert_work_schedule_assignments_to_labor_calendar(uuid, date, date, boolean) IS
  'EX-03.2 opció B: expansió one-way d''assignacions work_schedules cap a labor_calendar_overrides '
  'només on el dia encara és undefined. dry_run=true per defecte. No sobreescriu overrides ni festius.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. Seed punches: calendari laboral (no work_schedules)
--    Conserva el recompute set-based; només canvia la font d'intervals.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION data.seed_acme_attendance_punches()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id   uuid := '10000000-0000-0000-0000-000000000001';
  v_tz          text := 'Europe/Madrid';
  v_today       date := (now() AT TIME ZONE v_tz)::date;
  v_month_start date := date_trunc('month', v_today)::date;
  v_prev_start  date := (v_month_start - interval '1 month')::date;
  v_day         date;
  v_emp         record;
  v_labor       record;
  v_hash        int;
  v_scenario    int;
  v_margin_in   int;
  v_margin_out  int;
  v_now         timestamptz := now();
  v_geo         jsonb := '{"latitude":41.40210,"longitude":2.16120,"accuracy_meters":15}'::jsonb;
  v_punch_seq   bigint := 0;
  v_punch_id    uuid;
  v_client_op   uuid;
  v_ts          timestamptz;
  v_first_start time;
  v_first_end   time;
  v_last_start  time;
  v_last_end    time;
  v_has_split   boolean;
  v_skip_day    boolean;
  v_missing_out boolean;
  v_open_break  boolean;
  v_do_break    boolean;
  v_days_done   int := 0;
  v_punches     int := 0;
  v_recomputes  int := 0;
  v_pont_day    date;
  v_iv_count    int;
BEGIN
  v_pont_day := make_date(EXTRACT(year FROM v_today)::int, 6, 25);

  DELETE FROM data.time_daily_summaries
  WHERE tenant_id = v_tenant_id AND work_date >= v_prev_start AND work_date <= v_today;
  DELETE FROM data.time_entries
  WHERE tenant_id = v_tenant_id AND work_date >= v_prev_start AND work_date <= v_today;
  DELETE FROM data.time_punches
  WHERE tenant_id = v_tenant_id
    AND (occurred_at AT TIME ZONE v_tz)::date >= v_prev_start
    AND (occurred_at AT TIME ZONE v_tz)::date <= v_today;

  FOR v_emp IN
    SELECT e.id, e.site_id, e.full_name
    FROM data.employees e
    WHERE e.tenant_id = v_tenant_id AND e.status = 'active'
    ORDER BY e.id
  LOOP
    v_day := v_prev_start;
    WHILE v_day <= v_today LOOP
      v_hash := abs(hashtext(v_emp.id::text || v_day::text));
      v_scenario := v_hash % 100;
      v_margin_in  := v_hash % 21;
      v_margin_out := (v_hash / 21) % 21;
      IF (v_hash / 441) % 2 = 1 THEN v_margin_in  := -v_margin_in;  END IF;
      IF (v_hash / 882) % 2 = 1 THEN v_margin_out := -v_margin_out; END IF;

      v_skip_day    := false;
      v_missing_out := false;
      v_open_break  := false;

      IF v_emp.id = '40000000-0000-0000-0000-000000000005' AND v_day = v_today - 1 THEN
        v_open_break := true;
      ELSIF v_emp.id = '40000000-0000-0000-0000-000000000006' AND v_day = v_today - 2 THEN
        v_missing_out := true;
      ELSIF v_emp.id = '40000000-0000-0000-0000-000000000007' AND v_day = v_today - 5 THEN
        v_skip_day := true;
      ELSIF v_emp.id = '40000000-0000-0000-0000-000000000003' AND v_day = v_today THEN
        v_missing_out := true;
      ELSIF v_scenario < 3 THEN
        v_skip_day := true;
      ELSIF v_scenario BETWEEN 3 AND 4 THEN
        v_missing_out := true;
      ELSIF v_scenario = 5 THEN
        v_open_break := true;
      END IF;

      IF v_emp.site_id = '30000000-0000-0000-0000-000000000001'
         AND v_day = v_pont_day THEN
        v_skip_day := true;
      END IF;

      -- EX-03.2: intervals des del calendari laboral (SoT), no work_schedules
      SELECT * INTO v_labor
      FROM data.resolve_labor_calendar_for_employee(
        v_tenant_id, v_emp.site_id, v_emp.id, v_day, false
      );

      IF v_labor.labor_day_type IS DISTINCT FROM 'work'
         OR v_labor.work_intervals IS NULL
         OR jsonb_typeof(v_labor.work_intervals) <> 'array'
         OR jsonb_array_length(v_labor.work_intervals) = 0 THEN
        v_skip_day := true;
      END IF;

      IF NOT v_skip_day THEN
        v_iv_count := jsonb_array_length(v_labor.work_intervals);
        v_first_start := (split_part(v_labor.work_intervals->0->>'start', ':', 1)
                          || ':' || split_part(v_labor.work_intervals->0->>'start', ':', 2))::time;
        v_first_end   := (split_part(v_labor.work_intervals->0->>'end', ':', 1)
                          || ':' || split_part(v_labor.work_intervals->0->>'end', ':', 2))::time;

        IF v_iv_count > 1 THEN
          v_last_start := (split_part(v_labor.work_intervals->(v_iv_count - 1)->>'start', ':', 1)
                           || ':' || split_part(v_labor.work_intervals->(v_iv_count - 1)->>'start', ':', 2))::time;
          v_last_end   := (split_part(v_labor.work_intervals->(v_iv_count - 1)->>'end', ':', 1)
                           || ':' || split_part(v_labor.work_intervals->(v_iv_count - 1)->>'end', ':', 2))::time;
        ELSE
          v_last_start := v_first_start;
          v_last_end   := v_first_end;
        END IF;

        v_has_split := v_iv_count > 1;

        v_ts := timezone(v_tz, v_day + v_first_start + (v_margin_in || ' minutes')::interval);
        IF v_day <> v_today OR v_ts <= v_now THEN
          v_punch_seq := v_punch_seq + 1;
          v_punch_id  := ('65000000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
          v_client_op := ('66000000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
          INSERT INTO data.time_punches (
            id, tenant_id, site_id, employee_id, client_op_id, punch_type,
            occurred_at, received_at, geo, location_permission, source
          ) VALUES (
            v_punch_id, v_tenant_id, v_emp.site_id, v_emp.id, v_client_op, 'in',
            v_ts, v_ts + interval '2 seconds', v_geo, 'granted', 'mobile'
          );
          v_punches := v_punches + 1;

        v_do_break := v_has_split OR (v_hash % 4 = 0 AND NOT v_open_break);
        IF v_do_break AND NOT v_open_break THEN
          IF v_has_split THEN
            v_ts := timezone(v_tz, v_day + v_first_end - interval '2 minutes');
          ELSE
            v_ts := timezone(v_tz, v_day + time '11:00' + ((v_hash % 15) || ' minutes')::interval);
          END IF;
          IF v_day <> v_today OR v_ts <= v_now THEN
            v_punch_seq := v_punch_seq + 1;
            v_punch_id  := ('65000000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
            v_client_op := ('66000000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
            INSERT INTO data.time_punches (
              id, tenant_id, site_id, employee_id, client_op_id, punch_type,
              occurred_at, received_at, geo, location_permission, source
            ) VALUES (
              v_punch_id, v_tenant_id, v_emp.site_id, v_emp.id, v_client_op, 'break_start',
              v_ts, v_ts + interval '2 seconds', v_geo, 'granted', 'mobile'
            );
            v_punches := v_punches + 1;

            IF v_has_split THEN
              v_ts := timezone(v_tz, v_day + v_last_start + interval '3 minutes');
            ELSE
              v_ts := v_ts + interval '15 minutes';
            END IF;
            IF v_day <> v_today OR v_ts <= v_now THEN
              v_punch_seq := v_punch_seq + 1;
              v_punch_id  := ('65000000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
              v_client_op := ('66000000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
              INSERT INTO data.time_punches (
                id, tenant_id, site_id, employee_id, client_op_id, punch_type,
                occurred_at, received_at, geo, location_permission, source
              ) VALUES (
                v_punch_id, v_tenant_id, v_emp.site_id, v_emp.id, v_client_op, 'break_end',
                v_ts, v_ts + interval '2 seconds', v_geo, 'granted', 'mobile'
              );
              v_punches := v_punches + 1;
            END IF;
          END IF;
        ELSIF v_open_break THEN
          IF v_has_split THEN
            v_ts := timezone(v_tz, v_day + v_first_end - interval '2 minutes');
          ELSE
            v_ts := timezone(v_tz, v_day + time '11:00');
          END IF;
          IF v_day <> v_today OR v_ts <= v_now THEN
            v_punch_seq := v_punch_seq + 1;
            v_punch_id  := ('65000000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
            v_client_op := ('66000000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
            INSERT INTO data.time_punches (
              id, tenant_id, site_id, employee_id, client_op_id, punch_type,
              occurred_at, received_at, geo, location_permission, source
            ) VALUES (
              v_punch_id, v_tenant_id, v_emp.site_id, v_emp.id, v_client_op, 'break_start',
              v_ts, v_ts + interval '2 seconds', v_geo, 'granted', 'mobile'
            );
            v_punches := v_punches + 1;
          END IF;
        END IF;

        IF NOT v_missing_out THEN
          v_ts := timezone(v_tz, v_day + v_last_end + (v_margin_out || ' minutes')::interval);
          IF v_day <> v_today OR v_ts <= v_now THEN
            v_punch_seq := v_punch_seq + 1;
            v_punch_id  := ('65000000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
            v_client_op := ('66000000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
            INSERT INTO data.time_punches (
              id, tenant_id, site_id, employee_id, client_op_id, punch_type,
              occurred_at, received_at, geo, location_permission, source
            ) VALUES (
              v_punch_id, v_tenant_id, v_emp.site_id, v_emp.id, v_client_op, 'out',
              v_ts, v_ts + interval '2 seconds', v_geo, 'granted', 'mobile'
            );
            v_punches := v_punches + 1;
          END IF;
        END IF;

        v_days_done := v_days_done + 1;
        END IF;
      END IF;

      v_day := v_day + 1;
    END LOOP;
  END LOOP;

  -- Recompute set-based (igual que pre-EX-03.2)
  WITH day_agg AS (
    SELECT
      tp.employee_id,
      (tp.occurred_at AT TIME ZONE v_tz)::date AS work_date,
      e.tenant_id,
      e.site_id,
      COUNT(*)::int AS punch_count,
      COUNT(*) FILTER (WHERE tp.punch_type = 'in')::int          AS in_c,
      COUNT(*) FILTER (WHERE tp.punch_type = 'out')::int         AS out_c,
      COUNT(*) FILTER (WHERE tp.punch_type = 'break_start')::int AS bs_c,
      COUNT(*) FILTER (WHERE tp.punch_type = 'break_end')::int   AS be_c,
      MIN(tp.occurred_at) FILTER (WHERE tp.punch_type = 'in')    AS first_in_at,
      MAX(tp.occurred_at) FILTER (WHERE tp.punch_type = 'out')   AS last_out_at
    FROM data.time_punches tp
    JOIN data.employees e ON e.id = tp.employee_id
    WHERE tp.tenant_id = v_tenant_id
      AND (tp.occurred_at AT TIME ZONE v_tz)::date BETWEEN v_prev_start AND v_today
    GROUP BY tp.employee_id, (tp.occurred_at AT TIME ZONE v_tz)::date, e.tenant_id, e.site_id
  ),
  first_in AS (
    SELECT DISTINCT ON (tp.employee_id, (tp.occurred_at AT TIME ZONE v_tz)::date)
      tp.employee_id,
      (tp.occurred_at AT TIME ZONE v_tz)::date AS work_date,
      tp.id AS punch_in_id
    FROM data.time_punches tp
    WHERE tp.tenant_id = v_tenant_id
      AND tp.punch_type = 'in'
      AND (tp.occurred_at AT TIME ZONE v_tz)::date BETWEEN v_prev_start AND v_today
    ORDER BY tp.employee_id, (tp.occurred_at AT TIME ZONE v_tz)::date, tp.occurred_at ASC
  ),
  last_out AS (
    SELECT DISTINCT ON (tp.employee_id, (tp.occurred_at AT TIME ZONE v_tz)::date)
      tp.employee_id,
      (tp.occurred_at AT TIME ZONE v_tz)::date AS work_date,
      tp.id AS punch_out_id
    FROM data.time_punches tp
    WHERE tp.tenant_id = v_tenant_id
      AND tp.punch_type = 'out'
      AND (tp.occurred_at AT TIME ZONE v_tz)::date BETWEEN v_prev_start AND v_today
    ORDER BY tp.employee_id, (tp.occurred_at AT TIME ZONE v_tz)::date, tp.occurred_at DESC
  ),
  computed AS (
    SELECT
      da.*,
      fi.punch_in_id,
      lo.punch_out_id,
      CASE
        WHEN da.first_in_at IS NOT NULL AND da.last_out_at IS NOT NULL
          THEN ROUND(EXTRACT(EPOCH FROM (da.last_out_at - da.first_in_at)) / 60)::int
        ELSE NULL
      END AS gross_min,
      CASE
        WHEN da.first_in_at IS NOT NULL AND da.last_out_at IS NOT NULL THEN 'closed'
        WHEN da.first_in_at IS NOT NULL THEN 'open'
        WHEN da.punch_count = 0 THEN 'missing'
        ELSE 'open'
      END AS entry_status,
      ARRAY_REMOVE(ARRAY[
        CASE WHEN da.punch_count > 0 AND da.in_c = 0 THEN 'MISSING_IN' END,
        CASE WHEN da.in_c > da.out_c AND da.out_c > 0 THEN 'EXTRA_IN' END,
        CASE WHEN da.out_c > da.in_c THEN 'EXTRA_OUT' END,
        CASE WHEN da.bs_c != da.be_c THEN 'BREAK_MISMATCH' END
      ], NULL) AS anomaly_codes
    FROM day_agg da
    LEFT JOIN first_in fi ON fi.employee_id = da.employee_id AND fi.work_date = da.work_date
    LEFT JOIN last_out lo ON lo.employee_id = da.employee_id AND lo.work_date = da.work_date
  ),
  upsert_entries AS (
    INSERT INTO data.time_entries (
      tenant_id, site_id, employee_id, work_date,
      starts_at, ends_at, punch_in_id, punch_out_id,
      gross_minutes, break_minutes, net_minutes,
      regular_minutes, overtime_minutes, status, updated_at
    )
    SELECT
      c.tenant_id, c.site_id, c.employee_id, c.work_date,
      c.first_in_at, c.last_out_at, c.punch_in_id, c.punch_out_id,
      c.gross_min, 0,
      CASE WHEN c.gross_min IS NOT NULL THEN c.gross_min ELSE NULL END,
      CASE WHEN c.gross_min IS NOT NULL THEN c.gross_min ELSE NULL END,
      0, c.entry_status, now()
    FROM computed c
    ON CONFLICT (employee_id, work_date) DO UPDATE SET
      starts_at        = EXCLUDED.starts_at,
      ends_at          = EXCLUDED.ends_at,
      punch_in_id      = EXCLUDED.punch_in_id,
      punch_out_id     = EXCLUDED.punch_out_id,
      gross_minutes    = EXCLUDED.gross_minutes,
      break_minutes    = EXCLUDED.break_minutes,
      net_minutes      = EXCLUDED.net_minutes,
      regular_minutes  = EXCLUDED.regular_minutes,
      overtime_minutes = EXCLUDED.overtime_minutes,
      status           = EXCLUDED.status,
      updated_at       = EXCLUDED.updated_at
    WHERE data.time_entries.status != 'adjusted'
    RETURNING 1
  ),
  upsert_summaries AS (
    INSERT INTO data.time_daily_summaries (
      tenant_id, site_id, employee_id, work_date,
      day_type, expected_minutes, worked_minutes, break_minutes,
      overtime_minutes, absence_minutes, punch_count,
      anomaly_codes, needs_review, recomputed_at, updated_at
    )
    SELECT
      c.tenant_id, c.site_id, c.employee_id, c.work_date,
      CASE COALESCE(r.resolve->>'day_type', 'unknown')
        WHEN 'working' THEN 'work'
        WHEN 'half_holiday' THEN 'holiday'
        WHEN 'non_working' THEN 'weekend'
        ELSE COALESCE(r.resolve->>'day_type', 'unknown')
      END,
      COALESCE((r.resolve->>'expected_minutes')::int, 0),
      COALESCE(CASE WHEN c.gross_min IS NOT NULL THEN c.gross_min ELSE 0 END, 0),
      0, 0, 0, c.punch_count,
      c.anomaly_codes,
      (cardinality(c.anomaly_codes) > 0 OR c.entry_status IN ('missing', 'open')),
      now(), now()
    FROM computed c
    CROSS JOIN LATERAL (
      SELECT api.resolve_work_day(c.employee_id, c.work_date) AS resolve
    ) r
    ON CONFLICT (employee_id, work_date) DO UPDATE SET
      day_type         = EXCLUDED.day_type,
      expected_minutes = EXCLUDED.expected_minutes,
      worked_minutes   = EXCLUDED.worked_minutes,
      break_minutes    = EXCLUDED.break_minutes,
      punch_count      = EXCLUDED.punch_count,
      anomaly_codes    = EXCLUDED.anomaly_codes,
      needs_review     = EXCLUDED.needs_review,
      recomputed_at    = EXCLUDED.recomputed_at,
      updated_at       = EXCLUDED.updated_at
    WHERE data.time_daily_summaries.status = 'draft'
    RETURNING 1
  )
  SELECT COUNT(*)::int INTO v_recomputes FROM computed;

  RETURN jsonb_build_object(
    'tenant_id',     v_tenant_id,
    'range_from',    v_prev_start,
    'range_to',      v_today,
    'punches',       v_punches,
    'employee_days', v_days_done,
    'recomputes',    v_recomputes,
    'interval_source', 'labor_calendar'
  );
END;
$$;

COMMENT ON FUNCTION data.seed_acme_attendance_punches() IS
  'Seed demo Acme: genera punches a partir de resolve_labor_calendar_for_employee (EX-03.2), '
  'no des de work_schedules.';
