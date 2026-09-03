-- ============================================================
-- Labor Calendar Overrides
-- Stores explicit day-type assignments per tenant/site/date.
-- Resolution hierarchy for the visual calendar:
--   1. Site-level override (this table, site_id IS NOT NULL)
--   2. Tenant-level override (this table, site_id IS NULL)
--   3. Assigned holiday calendars (existing holiday_calendars/holidays)
--   4. Implicit → 'undefined'
-- ============================================================

CREATE TABLE IF NOT EXISTS data.labor_calendar_overrides (
  id             uuid         NOT NULL DEFAULT gen_random_uuid(),
  tenant_id      uuid         NOT NULL REFERENCES data.tenants(id)  ON DELETE CASCADE,
  site_id        uuid                  REFERENCES data.sites(id)    ON DELETE CASCADE,
  calendar_date  date         NOT NULL,
  day_type       text         NOT NULL CHECK (day_type IN ('work', 'holiday', 'vacation', 'leave', 'undefined')),
  day_name       text,                    -- label (e.g. festiu name, vacation note)
  work_start     time without time zone,  -- for day_type='work'
  work_end       time without time zone,  -- for day_type='work'
  created_at     timestamptz  NOT NULL DEFAULT now(),
  updated_at     timestamptz  NOT NULL DEFAULT now(),

  CONSTRAINT labor_calendar_overrides_pkey PRIMARY KEY (id),
  -- NULLS NOT DISTINCT: two NULLs in site_id treated as equal → one record per (tenant, site|null, date)
  CONSTRAINT labor_calendar_overrides_unique UNIQUE NULLS NOT DISTINCT (tenant_id, site_id, calendar_date)
);

CREATE INDEX IF NOT EXISTS idx_lco_tenant_site_date
  ON data.labor_calendar_overrides (tenant_id, site_id, calendar_date);

CREATE INDEX IF NOT EXISTS idx_lco_tenant_date
  ON data.labor_calendar_overrides (tenant_id, calendar_date);

-- ─── Helper: is current user a manager or owner for a tenant ─────────────────

CREATE OR REPLACE FUNCTION data.is_labor_cal_manager(p_tenant_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT
    (data.jwt_user_tenants() ? p_tenant_id::text)
    AND (
      (data.jwt_user_tenants() -> p_tenant_id::text) ->> 'global_role' = ANY(ARRAY['owner', 'manager'])
      OR data.jwt_has_permission(p_tenant_id, 'hr.manage', NULL)
    );
$$;

-- ─── RLS ─────────────────────────────────────────────────────────────────────

ALTER TABLE data.labor_calendar_overrides ENABLE ROW LEVEL SECURITY;

-- All authenticated tenant members can read
CREATE POLICY lco_select ON data.labor_calendar_overrides
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? (tenant_id)::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

-- Only managers/owners can write
CREATE POLICY lco_insert ON data.labor_calendar_overrides
  FOR INSERT TO authenticated
  WITH CHECK (data.is_labor_cal_manager(tenant_id));

CREATE POLICY lco_update ON data.labor_calendar_overrides
  FOR UPDATE TO authenticated
  USING  (data.is_labor_cal_manager(tenant_id))
  WITH CHECK (data.is_labor_cal_manager(tenant_id));

CREATE POLICY lco_delete ON data.labor_calendar_overrides
  FOR DELETE TO authenticated
  USING  (data.is_labor_cal_manager(tenant_id));

GRANT SELECT, INSERT, UPDATE, DELETE
  ON data.labor_calendar_overrides TO authenticated;

-- ─── API View ─────────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW api.labor_calendar_overrides
  WITH (security_invoker = true)
AS
  SELECT * FROM data.labor_calendar_overrides;

GRANT SELECT ON api.labor_calendar_overrides TO authenticated;

-- ─── RPC: upsert_labor_calendar_days (bulk) ──────────────────────────────────
-- Insert/update multiple day overrides in one call.
-- Passing day_type = 'undefined' DELETES the override for those dates.

CREATE OR REPLACE FUNCTION api.upsert_labor_calendar_days(
  p_dates       date[],
  p_day_type    text,
  p_day_name    text    DEFAULT NULL,
  p_work_start  time    DEFAULT NULL,
  p_work_end    time    DEFAULT NULL,
  p_site_id     uuid    DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF NOT data.is_labor_cal_manager(v_tenant_id) THEN
    RAISE EXCEPTION 'insufficient_privilege: manager role required to manage labor calendar';
  END IF;

  IF p_day_type = 'undefined' THEN
    DELETE FROM data.labor_calendar_overrides
    WHERE tenant_id    = v_tenant_id
      AND (site_id = p_site_id OR (site_id IS NULL AND p_site_id IS NULL))
      AND calendar_date = ANY(p_dates);

  ELSE
    INSERT INTO data.labor_calendar_overrides
      (tenant_id, site_id, calendar_date, day_type, day_name, work_start, work_end, updated_at)
    SELECT
      v_tenant_id,
      p_site_id,
      d,
      p_day_type,
      p_day_name,
      p_work_start,
      p_work_end,
      now()
    FROM unnest(p_dates) AS d
    ON CONFLICT ON CONSTRAINT labor_calendar_overrides_unique
    DO UPDATE SET
      day_type   = EXCLUDED.day_type,
      day_name   = EXCLUDED.day_name,
      work_start = EXCLUDED.work_start,
      work_end   = EXCLUDED.work_end,
      updated_at = now();
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_labor_calendar_days TO authenticated;

-- ─── RPC: apply_weekly_pattern_to_calendar ───────────────────────────────────
-- Applies a DOW pattern (array of 0-6) as a given day_type for the whole year.
-- Used by the "weekly setup panel" in the frontend.
-- dow_array: array of JS day-of-week values (0=Sun, 1=Mon, ..., 6=Sat)

CREATE OR REPLACE FUNCTION api.apply_weekly_pattern_to_calendar(
  p_year        int,
  p_dow_array   int[],     -- days of week to set (0=Sun … 6=Sat)
  p_day_type    text,
  p_day_name    text    DEFAULT NULL,
  p_work_start  time    DEFAULT NULL,
  p_work_end    time    DEFAULT NULL,
  p_site_id     uuid    DEFAULT NULL
)
RETURNS int                -- number of rows affected
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_dates     date[];
  v_affected  int;
BEGIN
  IF NOT data.is_labor_cal_manager(v_tenant_id) THEN
    RAISE EXCEPTION 'insufficient_privilege: manager role required to manage labor calendar';
  END IF;

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
      (tenant_id, site_id, calendar_date, day_type, day_name, work_start, work_end, updated_at)
    SELECT
      v_tenant_id, p_site_id, d, p_day_type, p_day_name, p_work_start, p_work_end, now()
    FROM unnest(v_dates) AS d
    ON CONFLICT ON CONSTRAINT labor_calendar_overrides_unique
    DO UPDATE SET
      day_type   = EXCLUDED.day_type,
      day_name   = EXCLUDED.day_name,
      work_start = EXCLUDED.work_start,
      work_end   = EXCLUDED.work_end,
      updated_at = now();
    GET DIAGNOSTICS v_affected = ROW_COUNT;
  END IF;

  RETURN v_affected;
END;
$$;

GRANT EXECUTE ON FUNCTION api.apply_weekly_pattern_to_calendar TO authenticated;
