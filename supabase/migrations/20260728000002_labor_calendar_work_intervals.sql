-- Add work_intervals JSONB for multiple time slots per day (incl. overnight).
-- Format: [{"start":"09:00","end":"14:00"},{"start":"22:00","end":"06:00"}]
-- When end <= start, the interval ends on the next calendar day.

ALTER TABLE data.labor_calendar_overrides
  ADD COLUMN IF NOT EXISTS work_intervals jsonb;

-- Backfill from legacy single-slot columns
UPDATE data.labor_calendar_overrides
SET work_intervals = jsonb_build_array(
  jsonb_build_object(
    'start', to_char(work_start, 'HH24:MI'),
    'end',   to_char(work_end, 'HH24:MI')
  )
)
WHERE work_start IS NOT NULL
  AND work_end IS NOT NULL
  AND (work_intervals IS NULL OR work_intervals = '[]'::jsonb);

-- ─── Replace upsert RPC ───────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.upsert_labor_calendar_days(
  p_dates            date[],
  p_day_type         text,
  p_day_name         text    DEFAULT NULL,
  p_work_start       time    DEFAULT NULL,
  p_work_end         time    DEFAULT NULL,
  p_work_intervals   jsonb   DEFAULT NULL,
  p_site_id          uuid    DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_intervals jsonb;
  v_first     jsonb;
BEGIN
  IF NOT data.is_labor_cal_manager(v_tenant_id) THEN
    RAISE EXCEPTION 'insufficient_privilege: manager role required to manage labor calendar';
  END IF;

  -- Tenant/site calendars: leave type is employee-only
  IF p_day_type = 'leave' THEN
    RAISE EXCEPTION 'invalid_day_type: leave is only allowed on employee calendars';
  END IF;

  v_intervals := p_work_intervals;
  IF v_intervals IS NULL AND p_work_start IS NOT NULL AND p_work_end IS NOT NULL THEN
    v_intervals := jsonb_build_array(
      jsonb_build_object(
        'start', to_char(p_work_start, 'HH24:MI'),
        'end',   to_char(p_work_end, 'HH24:MI')
      )
    );
  END IF;

  IF p_day_type = 'undefined' THEN
    DELETE FROM data.labor_calendar_overrides
    WHERE tenant_id    = v_tenant_id
      AND (site_id = p_site_id OR (site_id IS NULL AND p_site_id IS NULL))
      AND calendar_date = ANY(p_dates);

  ELSE
    v_first := CASE WHEN jsonb_array_length(COALESCE(v_intervals, '[]'::jsonb)) > 0
      THEN v_intervals->0 ELSE NULL END;

    INSERT INTO data.labor_calendar_overrides
      (tenant_id, site_id, calendar_date, day_type, day_name,
       work_start, work_end, work_intervals, updated_at)
    SELECT
      v_tenant_id,
      p_site_id,
      d,
      p_day_type,
      p_day_name,
      CASE WHEN v_first IS NOT NULL THEN (v_first->>'start')::time ELSE NULL END,
      CASE WHEN v_first IS NOT NULL THEN (v_first->>'end')::time   ELSE NULL END,
      COALESCE(v_intervals, '[]'::jsonb),
      now()
    FROM unnest(p_dates) AS d
    ON CONFLICT ON CONSTRAINT labor_calendar_overrides_unique
    DO UPDATE SET
      day_type        = EXCLUDED.day_type,
      day_name        = EXCLUDED.day_name,
      work_start      = EXCLUDED.work_start,
      work_end        = EXCLUDED.work_end,
      work_intervals  = EXCLUDED.work_intervals,
      updated_at      = now();
  END IF;
END;
$$;

-- ─── Replace weekly pattern RPC ───────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.apply_weekly_pattern_to_calendar(
  p_year             int,
  p_dow_array        int[],
  p_day_type         text,
  p_day_name         text    DEFAULT NULL,
  p_work_start       time    DEFAULT NULL,
  p_work_end         time    DEFAULT NULL,
  p_work_intervals   jsonb   DEFAULT NULL,
  p_site_id          uuid    DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_dates     date[];
  v_affected  int;
  v_intervals jsonb;
  v_first     jsonb;
BEGIN
  IF NOT data.is_labor_cal_manager(v_tenant_id) THEN
    RAISE EXCEPTION 'insufficient_privilege: manager role required to manage labor calendar';
  END IF;

  IF p_day_type = 'leave' THEN
    RAISE EXCEPTION 'invalid_day_type: leave is only allowed on employee calendars';
  END IF;

  v_intervals := p_work_intervals;
  IF v_intervals IS NULL AND p_work_start IS NOT NULL AND p_work_end IS NOT NULL THEN
    v_intervals := jsonb_build_array(
      jsonb_build_object(
        'start', to_char(p_work_start, 'HH24:MI'),
        'end',   to_char(p_work_end, 'HH24:MI')
      )
    );
  END IF;

  v_first := CASE WHEN jsonb_array_length(COALESCE(v_intervals, '[]'::jsonb)) > 0
    THEN v_intervals->0 ELSE NULL END;

  SELECT array_agg(d::date)
  INTO v_dates
  FROM generate_series(
    make_date(p_year, 1, 1),
    make_date(p_year, 12, 31),
    interval '1 day'
  ) AS d
  WHERE extract(dow FROM d)::int = ANY(p_dow_array);

  IF v_dates IS NULL OR array_length(v_dates, 1) = 0 THEN
    RETURN 0;
  END IF;

  IF p_day_type = 'undefined' THEN
    DELETE FROM data.labor_calendar_overrides
    WHERE tenant_id    = v_tenant_id
      AND (site_id = p_site_id OR (site_id IS NULL AND p_site_id IS NULL))
      AND calendar_date = ANY(v_dates);
    GET DIAGNOSTICS v_affected = ROW_COUNT;
  ELSE
    INSERT INTO data.labor_calendar_overrides
      (tenant_id, site_id, calendar_date, day_type, day_name,
       work_start, work_end, work_intervals, updated_at)
    SELECT
      v_tenant_id, p_site_id, d, p_day_type, p_day_name,
      CASE WHEN v_first IS NOT NULL THEN (v_first->>'start')::time ELSE NULL END,
      CASE WHEN v_first IS NOT NULL THEN (v_first->>'end')::time   ELSE NULL END,
      COALESCE(v_intervals, '[]'::jsonb),
      now()
    FROM unnest(v_dates) AS d
    ON CONFLICT ON CONSTRAINT labor_calendar_overrides_unique
    DO UPDATE SET
      day_type        = EXCLUDED.day_type,
      day_name        = EXCLUDED.day_name,
      work_start      = EXCLUDED.work_start,
      work_end        = EXCLUDED.work_end,
      work_intervals  = EXCLUDED.work_intervals,
      updated_at      = now();
    GET DIAGNOSTICS v_affected = ROW_COUNT;
  END IF;

  RETURN v_affected;
END;
$$;
