-- Phase B: Calendar Groups + Employee/Group overrides
-- Cascade: Tenant → Site → Holiday → CalendarGroup → Employee
-- ----------------------------------------------------------------------------

-- ─── 1. data.calendar_groups ────────────────────────────────────────────────

CREATE TABLE data.calendar_groups (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid        NOT NULL REFERENCES data.tenants(id)  ON DELETE CASCADE,
  site_id     uuid        NULL     REFERENCES data.sites(id)    ON DELETE CASCADE,
  name        text        NOT NULL,
  color       text        NOT NULL DEFAULT '#6366f1',
  description text        NULL,
  is_active   boolean     NOT NULL DEFAULT true,
  sort_order  int         NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX uq_calendar_groups_name
  ON data.calendar_groups (tenant_id, COALESCE(site_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(name));

CREATE INDEX idx_calendar_groups_tenant ON data.calendar_groups (tenant_id);

-- ─── 2. Ampliar labor_calendar_overrides ────────────────────────────────────

ALTER TABLE data.labor_calendar_overrides
  ADD COLUMN group_id    uuid NULL REFERENCES data.calendar_groups(id) ON DELETE CASCADE,
  ADD COLUMN employee_id uuid NULL REFERENCES data.employees(id)       ON DELETE CASCADE;

-- Nova restricció única (5 dimensions + data, NULLS NOT DISTINCT per tractar NULL com igual)
ALTER TABLE data.labor_calendar_overrides
  DROP CONSTRAINT labor_calendar_overrides_unique;

CREATE UNIQUE INDEX labor_calendar_overrides_unique
  ON data.labor_calendar_overrides
    (tenant_id, site_id, group_id, employee_id, calendar_date)
  NULLS NOT DISTINCT;

CREATE INDEX idx_lco_group   ON data.labor_calendar_overrides (group_id)    WHERE group_id    IS NOT NULL;
CREATE INDEX idx_lco_employee ON data.labor_calendar_overrides (employee_id) WHERE employee_id IS NOT NULL;

-- ─── 3. Afegir calendar_group_id a employees ────────────────────────────────

ALTER TABLE data.employees
  ADD COLUMN calendar_group_id uuid NULL REFERENCES data.calendar_groups(id) ON DELETE SET NULL;

-- ─── 4. Vista i RLS per calendar_groups ─────────────────────────────────────

CREATE OR REPLACE VIEW api.calendar_groups AS
SELECT id, tenant_id, site_id, name, color, description, is_active, sort_order, created_at, updated_at
FROM data.calendar_groups;

GRANT SELECT ON api.calendar_groups TO authenticated;

ALTER TABLE data.calendar_groups ENABLE ROW LEVEL SECURITY;

CREATE POLICY "tenant members can read calendar groups"
  ON data.calendar_groups FOR SELECT
  USING (tenant_id = data.active_tenant_id());

CREATE POLICY "managers can write calendar groups"
  ON data.calendar_groups FOR ALL
  USING (
    tenant_id = data.active_tenant_id()
    AND data.jwt_has_permission(tenant_id, 'attendance.manage')
  );

-- ─── 5. RPC: list_calendar_groups ───────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.list_calendar_groups(
  p_site_id uuid DEFAULT NULL
)
RETURNS SETOF api.calendar_groups
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = api, data, public
AS $$
  SELECT id, tenant_id, site_id, name, color, description, is_active, sort_order, created_at, updated_at
  FROM data.calendar_groups
  WHERE tenant_id = data.active_tenant_id()
    AND is_active = true
    AND (p_site_id IS NULL OR site_id IS NULL OR site_id = p_site_id)
  ORDER BY sort_order, name;
$$;

GRANT EXECUTE ON FUNCTION api.list_calendar_groups(uuid) TO authenticated;

-- ─── 6. RPC: upsert_calendar_group ──────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.upsert_calendar_group(
  p_name        text,
  p_color       text    DEFAULT '#6366f1',
  p_description text    DEFAULT NULL,
  p_site_id     uuid    DEFAULT NULL,
  p_is_active   boolean DEFAULT true,
  p_sort_order  int     DEFAULT 0,
  p_id          uuid    DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = api, data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_id        uuid := COALESCE(p_id, gen_random_uuid());
BEGIN
  IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.manage required';
  END IF;

  INSERT INTO data.calendar_groups (id, tenant_id, site_id, name, color, description, is_active, sort_order)
  VALUES (v_id, v_tenant_id, p_site_id, p_name, p_color, p_description, p_is_active, p_sort_order)
  ON CONFLICT (id) DO UPDATE SET
    name        = EXCLUDED.name,
    color       = EXCLUDED.color,
    description = EXCLUDED.description,
    site_id     = EXCLUDED.site_id,
    is_active   = EXCLUDED.is_active,
    sort_order  = EXCLUDED.sort_order,
    updated_at  = now();

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_calendar_group TO authenticated;

-- ─── 7. RPC: set_employee_calendar_group ────────────────────────────────────

CREATE OR REPLACE FUNCTION api.set_employee_calendar_group(
  p_employee_id       uuid,
  p_calendar_group_id uuid DEFAULT NULL  -- NULL per desassignar
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = api, data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF NOT data.jwt_has_permission(v_tenant_id, 'employees.write') THEN
    RAISE EXCEPTION 'insufficient_privilege: employees.write required';
  END IF;

  UPDATE data.employees
  SET calendar_group_id = p_calendar_group_id,
      updated_at        = now()
  WHERE id = p_employee_id
    AND tenant_id = v_tenant_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_employee_calendar_group TO authenticated;

-- ─── 8. Actualitzar upsert_labor_calendar_days (suport group/employee) ──────

DROP FUNCTION IF EXISTS api.upsert_labor_calendar_days(
  date[], text, text, time, time, jsonb, uuid
);

CREATE OR REPLACE FUNCTION api.upsert_labor_calendar_days(
  p_dates         date[],
  p_day_type      text,
  p_day_name      text    DEFAULT NULL,
  p_work_start    time    DEFAULT NULL,
  p_work_end      time    DEFAULT NULL,
  p_work_intervals jsonb  DEFAULT NULL,
  p_site_id       uuid    DEFAULT NULL,
  p_group_id      uuid    DEFAULT NULL,
  p_employee_id   uuid    DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = api, data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_intervals jsonb;
  v_first     jsonb;
BEGIN
  IF NOT data.is_labor_cal_manager(v_tenant_id) THEN
    RAISE EXCEPTION 'insufficient_privilege: manager role required to manage labor calendar';
  END IF;

  -- leave only allowed on employee calendars
  IF p_day_type = 'leave' AND p_employee_id IS NULL THEN
    RAISE EXCEPTION 'invalid_day_type: leave is only allowed on employee calendars';
  END IF;

  v_intervals := p_work_intervals;
  IF v_intervals IS NULL AND p_work_start IS NOT NULL AND p_work_end IS NOT NULL THEN
    v_intervals := jsonb_build_array(
      jsonb_build_object('start', to_char(p_work_start, 'HH24:MI'), 'end', to_char(p_work_end, 'HH24:MI'))
    );
  END IF;

  IF p_day_type = 'undefined' THEN
    DELETE FROM data.labor_calendar_overrides
    WHERE tenant_id   = v_tenant_id
      AND (site_id     = p_site_id     OR (site_id     IS NULL AND p_site_id     IS NULL))
      AND (group_id    = p_group_id    OR (group_id    IS NULL AND p_group_id    IS NULL))
      AND (employee_id = p_employee_id OR (employee_id IS NULL AND p_employee_id IS NULL))
      AND calendar_date = ANY(p_dates);
  ELSE
    v_first := CASE WHEN jsonb_array_length(COALESCE(v_intervals, '[]'::jsonb)) > 0
      THEN v_intervals->0 ELSE NULL END;

    INSERT INTO data.labor_calendar_overrides
      (tenant_id, site_id, group_id, employee_id, calendar_date, day_type, day_name,
       work_start, work_end, work_intervals, updated_at)
    SELECT
      v_tenant_id,
      p_site_id,
      p_group_id,
      p_employee_id,
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
      day_type       = EXCLUDED.day_type,
      day_name       = EXCLUDED.day_name,
      work_start     = EXCLUDED.work_start,
      work_end       = EXCLUDED.work_end,
      work_intervals = EXCLUDED.work_intervals,
      updated_at     = now();
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_labor_calendar_days TO authenticated;

-- ─── 9. Actualitzar apply_weekly_pattern_to_calendar ────────────────────────

DROP FUNCTION IF EXISTS api.apply_weekly_pattern_to_calendar(
  int, int[], text, text, time, time, jsonb, uuid
);

CREATE OR REPLACE FUNCTION api.apply_weekly_pattern_to_calendar(
  p_year          int,
  p_dow_array     int[],
  p_day_type      text,
  p_day_name      text   DEFAULT NULL,
  p_work_intervals jsonb DEFAULT NULL,
  p_site_id       uuid  DEFAULT NULL,
  p_group_id      uuid  DEFAULT NULL,
  p_employee_id   uuid  DEFAULT NULL
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
  ) INTO v_dates;

  IF array_length(v_dates, 1) IS NULL THEN RETURN 0; END IF;

  v_intervals := p_work_intervals;
  IF v_intervals IS NULL THEN v_intervals := '[]'::jsonb; END IF;

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

GRANT EXECUTE ON FUNCTION api.apply_weekly_pattern_to_calendar TO authenticated;
