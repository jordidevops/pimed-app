-- Patró setmanal: per defecte no sobreescriu dies amb festiu assignat (calendari importat).

DROP FUNCTION IF EXISTS api.apply_weekly_pattern_to_calendar(
  int, int[], text, text, jsonb, uuid, uuid, uuid
);

CREATE OR REPLACE FUNCTION api.apply_weekly_pattern_to_calendar(
  p_year                    int,
  p_dow_array               int[],
  p_day_type                text,
  p_day_name                text    DEFAULT NULL,
  p_work_intervals          jsonb   DEFAULT NULL,
  p_site_id                 uuid    DEFAULT NULL,
  p_group_id                uuid    DEFAULT NULL,
  p_employee_id             uuid    DEFAULT NULL,
  p_skip_assigned_holidays  boolean DEFAULT true
)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = api, data, public
AS $$
DECLARE
  v_tenant_id  uuid := data.active_tenant_id();
  v_dates      date[];
  v_intervals  jsonb;
  v_first      jsonb;
  v_count      int;
BEGIN
  IF NOT data.is_labor_cal_manager(v_tenant_id) THEN
    RAISE EXCEPTION 'insufficient_privilege: manager role required';
  END IF;

  SELECT ARRAY(
    SELECT d::date
    FROM generate_series(
      make_date(p_year, 1, 1),
      make_date(p_year, 12, 31),
      '1 day'::interval
    ) AS d
    WHERE EXTRACT(DOW FROM d) = ANY(p_dow_array)
      AND (
        NOT COALESCE(p_skip_assigned_holidays, true)
        OR NOT EXISTS (
          SELECT 1
          FROM data.planner_site_holidays(
            v_tenant_id,
            p_site_id,
            d::date,
            d::date
          ) h
        )
      )
  ) INTO v_dates;

  IF array_length(v_dates, 1) IS NULL THEN RETURN 0; END IF;

  v_intervals := COALESCE(p_work_intervals, '[]'::jsonb);
  v_first := CASE WHEN jsonb_array_length(v_intervals) > 0 THEN v_intervals->0 ELSE NULL END;

  IF p_day_type = 'undefined' THEN
    DELETE FROM data.labor_calendar_overrides
    WHERE tenant_id   = v_tenant_id
      AND (site_id     = p_site_id     OR (site_id     IS NULL AND p_site_id     IS NULL))
      AND (group_id    = p_group_id    OR (group_id    IS NULL AND p_group_id    IS NULL))
      AND (employee_id = p_employee_id OR (employee_id IS NULL AND p_employee_id IS NULL))
      AND calendar_date = ANY(v_dates);
    GET DIAGNOSTICS v_count = ROW_COUNT;
  ELSE
    INSERT INTO data.labor_calendar_overrides
      (tenant_id, site_id, group_id, employee_id, calendar_date, day_type, day_name,
       work_start, work_end, work_intervals, updated_at)
    SELECT
      v_tenant_id, p_site_id, p_group_id, p_employee_id,
      d, p_day_type, p_day_name,
      CASE WHEN v_first IS NOT NULL THEN (v_first->>'start')::time ELSE NULL END,
      CASE WHEN v_first IS NOT NULL THEN (v_first->>'end')::time   ELSE NULL END,
      v_intervals, now()
    FROM unnest(v_dates) AS d
    ON CONFLICT ON CONSTRAINT labor_calendar_overrides_unique
    DO UPDATE SET
      day_type       = EXCLUDED.day_type,
      day_name       = EXCLUDED.day_name,
      work_start     = EXCLUDED.work_start,
      work_end       = EXCLUDED.work_end,
      work_intervals = EXCLUDED.work_intervals,
      updated_at     = now();
    GET DIAGNOSTICS v_count = ROW_COUNT;
  END IF;

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION api.apply_weekly_pattern_to_calendar(
  int, int[], text, text, jsonb, uuid, uuid, uuid, boolean
) TO authenticated;
