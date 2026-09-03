-- =============================================================================
-- 07 — Fitxatges YTD mostrejats (caps 100%, crew ~40%)
-- =============================================================================

CREATE OR REPLACE FUNCTION data.seed_burgervista_attendance_punches()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id   uuid := 'a1000000-0000-0000-0000-000000000001';
  v_tz          text := 'Europe/Madrid';
  v_today       date := (now() AT TIME ZONE v_tz)::date;
  v_year_start  date := date_trunc('year', v_today)::date;
  v_day         date;
  v_emp         record;
  v_labor       record;
  v_hash        int;
  v_scenario    int;
  v_margin_in   int;
  v_margin_out  int;
  v_now         timestamptz := now();
  v_geo         jsonb;
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
  v_iv_count    int;
  v_is_lead     boolean;
  v_sample_ok   boolean;
BEGIN
  DELETE FROM data.time_daily_summaries
  WHERE tenant_id = v_tenant_id AND work_date >= v_year_start AND work_date <= v_today;
  DELETE FROM data.time_entries
  WHERE tenant_id = v_tenant_id AND work_date >= v_year_start AND work_date <= v_today;
  DELETE FROM data.time_punches
  WHERE tenant_id = v_tenant_id
    AND (occurred_at AT TIME ZONE v_tz)::date >= v_year_start
    AND (occurred_at AT TIME ZONE v_tz)::date <= v_today;

  FOR v_emp IN
    SELECT e.id, e.site_id, e.full_name,
           EXISTS (
             SELECT 1 FROM data.employee_role_assignments a
             WHERE a.employee_id = e.id AND a.is_active
               AND a.role_id IN (
                 'a4900000-0000-0000-0000-000000000001',
                 'a4900000-0000-0000-0000-000000000002'
               )
           ) AS is_lead
    FROM data.employees e
    WHERE e.tenant_id = v_tenant_id
      AND e.status = 'active'
      AND e.site_id IS NOT NULL
    ORDER BY e.id
  LOOP
    v_is_lead := v_emp.is_lead;
    v_geo := CASE v_emp.site_id
      WHEN 'a3000000-0000-0000-0000-000000000001'
        THEN '{"latitude":41.39120,"longitude":2.16510,"accuracy_meters":15}'::jsonb
      ELSE '{"latitude":41.39650,"longitude":2.14020,"accuracy_meters":15}'::jsonb
    END;

    v_day := v_year_start;
    WHILE v_day <= v_today LOOP
      v_hash := abs(hashtext(v_emp.id::text || v_day::text));
      v_scenario := v_hash % 100;
      v_margin_in  := v_hash % 21;
      v_margin_out := (v_hash / 21) % 21;
      IF (v_hash / 441) % 2 = 1 THEN v_margin_in  := -v_margin_in;  END IF;
      IF (v_hash / 882) % 2 = 1 THEN v_margin_out := -v_margin_out; END IF;

      -- Mostreig: leads 100%; crew ~40%
      v_sample_ok := v_is_lead OR (v_hash % 100 < 40);

      v_skip_day    := NOT v_sample_ok;
      v_missing_out := false;
      v_open_break  := false;

      IF v_sample_ok THEN
        IF v_emp.id = 'a4000000-0000-0000-0000-000000000004' AND v_day = v_today - 1 THEN
          v_open_break := true;
        ELSIF v_emp.id = 'a4000000-0000-0000-0000-000000000007' AND v_day = v_today - 2 THEN
          v_missing_out := true;
        ELSIF v_scenario < 3 THEN
          v_skip_day := true;
        ELSIF v_scenario BETWEEN 3 AND 4 THEN
          v_missing_out := true;
        ELSIF v_scenario = 5 THEN
          v_open_break := true;
        END IF;
      END IF;

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
          v_punch_id  := ('a6500000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
          v_client_op := ('a6600000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
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
              v_ts := timezone(v_tz, v_day + time '14:00' + ((v_hash % 15) || ' minutes')::interval);
            END IF;
            IF v_day <> v_today OR v_ts <= v_now THEN
              v_punch_seq := v_punch_seq + 1;
              v_punch_id  := ('a6500000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
              v_client_op := ('a6600000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
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
                v_ts := v_ts + interval '20 minutes';
              END IF;
              IF v_day <> v_today OR v_ts <= v_now THEN
                v_punch_seq := v_punch_seq + 1;
                v_punch_id  := ('a6500000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
                v_client_op := ('a6600000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
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
            v_ts := timezone(v_tz, v_day + COALESCE(v_first_end, time '14:00') - interval '2 minutes');
            IF v_day <> v_today OR v_ts <= v_now THEN
              v_punch_seq := v_punch_seq + 1;
              v_punch_id  := ('a6500000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
              v_client_op := ('a6600000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
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
              v_punch_id  := ('a6500000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
              v_client_op := ('a6600000-0000-4000-8000-' || lpad(to_hex(v_punch_seq), 12, '0'))::uuid;
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

  WITH day_agg AS (
    SELECT
      tp.employee_id,
      (tp.occurred_at AT TIME ZONE v_tz)::date AS work_date,
      e.tenant_id,
      e.site_id,
      COUNT(*)::int AS punch_count,
      COUNT(*) FILTER (WHERE tp.punch_type = 'in')::int AS in_c,
      COUNT(*) FILTER (WHERE tp.punch_type = 'out')::int AS out_c,
      COUNT(*) FILTER (WHERE tp.punch_type = 'break_start')::int AS bs_c,
      COUNT(*) FILTER (WHERE tp.punch_type = 'break_end')::int AS be_c,
      MIN(tp.occurred_at) FILTER (WHERE tp.punch_type = 'in') AS first_in_at,
      MAX(tp.occurred_at) FILTER (WHERE tp.punch_type = 'out') AS last_out_at
    FROM data.time_punches tp
    JOIN data.employees e ON e.id = tp.employee_id
    WHERE tp.tenant_id = v_tenant_id
      AND (tp.occurred_at AT TIME ZONE v_tz)::date BETWEEN v_year_start AND v_today
    GROUP BY tp.employee_id, (tp.occurred_at AT TIME ZONE v_tz)::date, e.tenant_id, e.site_id
  ),
  first_in AS (
    SELECT DISTINCT ON (tp.employee_id, (tp.occurred_at AT TIME ZONE v_tz)::date)
      tp.employee_id,
      (tp.occurred_at AT TIME ZONE v_tz)::date AS work_date,
      tp.id AS punch_in_id
    FROM data.time_punches tp
    WHERE tp.tenant_id = v_tenant_id AND tp.punch_type = 'in'
      AND (tp.occurred_at AT TIME ZONE v_tz)::date BETWEEN v_year_start AND v_today
    ORDER BY tp.employee_id, (tp.occurred_at AT TIME ZONE v_tz)::date, tp.occurred_at ASC
  ),
  last_out AS (
    SELECT DISTINCT ON (tp.employee_id, (tp.occurred_at AT TIME ZONE v_tz)::date)
      tp.employee_id,
      (tp.occurred_at AT TIME ZONE v_tz)::date AS work_date,
      tp.id AS punch_out_id
    FROM data.time_punches tp
    WHERE tp.tenant_id = v_tenant_id AND tp.punch_type = 'out'
      AND (tp.occurred_at AT TIME ZONE v_tz)::date BETWEEN v_year_start AND v_today
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
      starts_at = EXCLUDED.starts_at,
      ends_at = EXCLUDED.ends_at,
      punch_in_id = EXCLUDED.punch_in_id,
      punch_out_id = EXCLUDED.punch_out_id,
      gross_minutes = EXCLUDED.gross_minutes,
      net_minutes = EXCLUDED.net_minutes,
      regular_minutes = EXCLUDED.regular_minutes,
      status = EXCLUDED.status,
      updated_at = EXCLUDED.updated_at
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
      COALESCE(c.gross_min, 0),
      0, 0, 0, c.punch_count,
      c.anomaly_codes,
      (cardinality(c.anomaly_codes) > 0 OR c.entry_status IN ('missing', 'open')),
      now(), now()
    FROM computed c
    CROSS JOIN LATERAL (
      SELECT api.resolve_work_day(c.employee_id, c.work_date) AS resolve
    ) r
    ON CONFLICT (employee_id, work_date) DO UPDATE SET
      day_type = EXCLUDED.day_type,
      expected_minutes = EXCLUDED.expected_minutes,
      worked_minutes = EXCLUDED.worked_minutes,
      punch_count = EXCLUDED.punch_count,
      anomaly_codes = EXCLUDED.anomaly_codes,
      needs_review = EXCLUDED.needs_review,
      recomputed_at = EXCLUDED.recomputed_at,
      updated_at = EXCLUDED.updated_at
    WHERE data.time_daily_summaries.status = 'draft'
    RETURNING 1
  )
  SELECT COUNT(*)::int INTO v_recomputes FROM computed;

  RETURN jsonb_build_object(
    'tenant_id', v_tenant_id,
    'range_from', v_year_start,
    'range_to', v_today,
    'punches', v_punches,
    'employee_days', v_days_done,
    'recomputes', v_recomputes,
    'sampling', 'leads_100_crew_40',
    'interval_source', 'labor_calendar'
  );
END;
$$;

SELECT data.seed_burgervista_attendance_punches();
