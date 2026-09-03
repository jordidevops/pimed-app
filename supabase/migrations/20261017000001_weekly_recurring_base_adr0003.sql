-- ADR-0003 — Base recurrent setmanal (grup + empleat)
-- Substitueix ADR-0002 (opció B): en lloc de materialitzar el patró setmanal en
-- milers de files de labor_calendar_overrides via apply_weekly_pattern_to_calendar,
-- el resolver consulta directament una capa recurrent per day_of_week.
--
-- 1) data.calendar_group_weekly_intervals — base recurrent per grup de calendari
-- 2) data.employee_weekly_intervals       — base recurrent per empleat (per sobre del grup)
-- 3) RLS + vistes api.* + grants + triggers updated_at
-- 4) RPCs de gestió (get/set pattern setmanal)
-- 5) Integració a data.resolve_schedule_planner_day (noves capes 6-7, abans de festiu/undefined)

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. Taules
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE data.calendar_group_weekly_intervals (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid        NOT NULL REFERENCES data.tenants(id)         ON DELETE CASCADE,
  group_id       uuid        NOT NULL REFERENCES data.calendar_groups(id) ON DELETE CASCADE,
  day_of_week    smallint    NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
  day_type       text        NOT NULL DEFAULT 'work' CHECK (day_type IN ('work', 'non_working')),
  work_start     time,
  work_end       time,
  work_intervals jsonb,
  valid_from     date        NOT NULL DEFAULT CURRENT_DATE,
  valid_to       date,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_cgwi_valid_range CHECK (valid_to IS NULL OR valid_to > valid_from),
  CONSTRAINT uq_cgwi_group_dow_from UNIQUE (group_id, day_of_week, valid_from)
);

COMMENT ON TABLE data.calendar_group_weekly_intervals IS
  'ADR-0003: patró setmanal recurrent d''un grup de calendari, consultat en viu pel '
  'resolver (data.resolve_schedule_planner_day). NO es materialitza en labor_calendar_overrides. '
  'valid_from/valid_to permeten canvis futurs sense esborrar historial (SCD tipus 2).';

COMMENT ON COLUMN data.calendar_group_weekly_intervals.day_type IS
  '''work'': work_intervals defineix l''horari. ''non_working'': dia sense obligació '
  '(diferencia explícita d''''sense patró definit'''', que cau a la capa següent de la cascada).';

CREATE INDEX idx_cgwi_group_dow ON data.calendar_group_weekly_intervals (group_id, day_of_week);
CREATE INDEX idx_cgwi_tenant    ON data.calendar_group_weekly_intervals (tenant_id);

CREATE TABLE data.employee_weekly_intervals (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid        NOT NULL REFERENCES data.tenants(id)    ON DELETE CASCADE,
  employee_id    uuid        NOT NULL REFERENCES data.employees(id)  ON DELETE CASCADE,
  day_of_week    smallint    NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
  day_type       text        NOT NULL DEFAULT 'work' CHECK (day_type IN ('work', 'non_working')),
  work_start     time,
  work_end       time,
  work_intervals jsonb,
  valid_from     date        NOT NULL DEFAULT CURRENT_DATE,
  valid_to       date,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_ewi_valid_range CHECK (valid_to IS NULL OR valid_to > valid_from),
  CONSTRAINT uq_ewi_employee_dow_from UNIQUE (employee_id, day_of_week, valid_from)
);

COMMENT ON TABLE data.employee_weekly_intervals IS
  'ADR-0003: patró setmanal recurrent individual, per sobre del patró de grup i per sota '
  'dels overrides puntuals de labor_calendar_overrides. Útil per a empleats amb horari '
  'diferent del seu grup sense necessitar un grup nou.';

CREATE INDEX idx_ewi_employee_dow ON data.employee_weekly_intervals (employee_id, day_of_week);
CREATE INDEX idx_ewi_tenant       ON data.employee_weekly_intervals (tenant_id);

CREATE TRIGGER trg_updated_at_calendar_group_weekly_intervals
  BEFORE UPDATE ON data.calendar_group_weekly_intervals
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

CREATE TRIGGER trg_updated_at_employee_weekly_intervals
  BEFORE UPDATE ON data.employee_weekly_intervals
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. RLS
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE data.calendar_group_weekly_intervals ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.employee_weekly_intervals       ENABLE ROW LEVEL SECURITY;

CREATE POLICY cgwi_select ON data.calendar_group_weekly_intervals FOR SELECT
  USING (data.jwt_user_tenants() ? tenant_id::text);

CREATE POLICY cgwi_write ON data.calendar_group_weekly_intervals FOR ALL
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  );

CREATE POLICY ewi_select ON data.employee_weekly_intervals FOR SELECT
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'attendance.view_all')
      OR EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = employee_id AND e.user_id = auth.uid()
      )
    )
  );

CREATE POLICY ewi_write ON data.employee_weekly_intervals FOR ALL
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  );

GRANT SELECT ON data.calendar_group_weekly_intervals TO authenticated, service_role;
GRANT SELECT ON data.employee_weekly_intervals       TO authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. Vistes api.* (només lectura directa; escriptura via RPC set_*_weekly_day)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW api.calendar_group_weekly_intervals
  WITH (security_invoker = true)
AS
SELECT
  cgwi.id, cgwi.tenant_id, cgwi.group_id, cgwi.day_of_week, cgwi.day_type,
  cgwi.work_start, cgwi.work_end, cgwi.work_intervals,
  cgwi.valid_from, cgwi.valid_to, cgwi.created_at, cgwi.updated_at
FROM data.calendar_group_weekly_intervals cgwi;

CREATE OR REPLACE VIEW api.employee_weekly_intervals
  WITH (security_invoker = true)
AS
SELECT
  ewi.id, ewi.tenant_id, ewi.employee_id, ewi.day_of_week, ewi.day_type,
  ewi.work_start, ewi.work_end, ewi.work_intervals,
  ewi.valid_from, ewi.valid_to, ewi.created_at, ewi.updated_at
FROM data.employee_weekly_intervals ewi;

GRANT SELECT ON api.calendar_group_weekly_intervals TO authenticated;
GRANT SELECT ON api.employee_weekly_intervals       TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. RPCs de gestió — replace-all per (entitat, day_of_week) a partir d'una data
--    d'efecte (SCD tipus 2: tanca la fila oberta anterior i n'obre una nova).
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION api.set_calendar_group_weekly_day(
  p_group_id       uuid,
  p_day_of_week    smallint,
  p_day_type       text,
  p_work_intervals jsonb    DEFAULT NULL,
  p_effective_from date     DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid;
  v_first     jsonb;
  v_intervals jsonb := COALESCE(p_work_intervals, '[]'::jsonb);
BEGIN
  IF p_day_of_week NOT BETWEEN 0 AND 6 THEN
    RAISE EXCEPTION 'invalid_day_of_week: % (0-6)', p_day_of_week
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_day_type NOT IN ('work', 'non_working') THEN
    RAISE EXCEPTION 'invalid_day_type: % (work|non_working)', p_day_type
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_day_type = 'work' AND jsonb_array_length(v_intervals) = 0 THEN
    RAISE EXCEPTION 'invalid_parameter: work_intervals required when day_type = work'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT cg.tenant_id INTO v_tenant_id
  FROM data.calendar_groups cg
  WHERE cg.id = p_group_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'calendar_group_not_found: %', p_group_id
      USING ERRCODE = 'P0002';
  END IF;

  IF auth.uid() IS NOT NULL AND NOT data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Tancar el període obert anterior (si n'hi ha i comença abans de p_effective_from)
  UPDATE data.calendar_group_weekly_intervals
  SET valid_to = p_effective_from, updated_at = now()
  WHERE group_id = p_group_id
    AND day_of_week = p_day_of_week
    AND valid_to IS NULL
    AND valid_from < p_effective_from;

  v_first := CASE WHEN jsonb_array_length(v_intervals) > 0 THEN v_intervals->0 ELSE NULL END;

  INSERT INTO data.calendar_group_weekly_intervals (
    tenant_id, group_id, day_of_week, day_type,
    work_start, work_end, work_intervals, valid_from
  ) VALUES (
    v_tenant_id, p_group_id, p_day_of_week, p_day_type,
    CASE WHEN v_first IS NOT NULL THEN (v_first->>'start')::time ELSE NULL END,
    CASE WHEN v_first IS NOT NULL THEN (v_first->>'end')::time   ELSE NULL END,
    CASE WHEN p_day_type = 'work' THEN v_intervals ELSE NULL END,
    p_effective_from
  )
  ON CONFLICT ON CONSTRAINT uq_cgwi_group_dow_from DO UPDATE SET
    day_type       = EXCLUDED.day_type,
    work_start     = EXCLUDED.work_start,
    work_end       = EXCLUDED.work_end,
    work_intervals = EXCLUDED.work_intervals,
    valid_to       = NULL,
    updated_at     = now();

  RETURN jsonb_build_object(
    'group_id', p_group_id, 'day_of_week', p_day_of_week,
    'day_type', p_day_type, 'effective_from', p_effective_from
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_calendar_group_weekly_day(uuid, smallint, text, jsonb, date)
  TO authenticated;

CREATE OR REPLACE FUNCTION api.set_employee_weekly_day(
  p_employee_id    uuid,
  p_day_of_week    smallint,
  p_day_type       text,
  p_work_intervals jsonb    DEFAULT NULL,
  p_effective_from date     DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid;
  v_first     jsonb;
  v_intervals jsonb := COALESCE(p_work_intervals, '[]'::jsonb);
BEGIN
  IF p_day_of_week NOT BETWEEN 0 AND 6 THEN
    RAISE EXCEPTION 'invalid_day_of_week: % (0-6)', p_day_of_week
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_day_type NOT IN ('work', 'non_working') THEN
    RAISE EXCEPTION 'invalid_day_type: % (work|non_working)', p_day_type
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_day_type = 'work' AND jsonb_array_length(v_intervals) = 0 THEN
    RAISE EXCEPTION 'invalid_parameter: work_intervals required when day_type = work'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT e.tenant_id INTO v_tenant_id
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id
      USING ERRCODE = 'P0002';
  END IF;

  IF auth.uid() IS NOT NULL AND NOT data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.employee_weekly_intervals
  SET valid_to = p_effective_from, updated_at = now()
  WHERE employee_id = p_employee_id
    AND day_of_week = p_day_of_week
    AND valid_to IS NULL
    AND valid_from < p_effective_from;

  v_first := CASE WHEN jsonb_array_length(v_intervals) > 0 THEN v_intervals->0 ELSE NULL END;

  INSERT INTO data.employee_weekly_intervals (
    tenant_id, employee_id, day_of_week, day_type,
    work_start, work_end, work_intervals, valid_from
  ) VALUES (
    v_tenant_id, p_employee_id, p_day_of_week, p_day_type,
    CASE WHEN v_first IS NOT NULL THEN (v_first->>'start')::time ELSE NULL END,
    CASE WHEN v_first IS NOT NULL THEN (v_first->>'end')::time   ELSE NULL END,
    CASE WHEN p_day_type = 'work' THEN v_intervals ELSE NULL END,
    p_effective_from
  )
  ON CONFLICT ON CONSTRAINT uq_ewi_employee_dow_from DO UPDATE SET
    day_type       = EXCLUDED.day_type,
    work_start     = EXCLUDED.work_start,
    work_end       = EXCLUDED.work_end,
    work_intervals = EXCLUDED.work_intervals,
    valid_to       = NULL,
    updated_at     = now();

  RETURN jsonb_build_object(
    'employee_id', p_employee_id, 'day_of_week', p_day_of_week,
    'day_type', p_day_type, 'effective_from', p_effective_from
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_employee_weekly_day(uuid, smallint, text, jsonb, date)
  TO authenticated;

CREATE OR REPLACE FUNCTION api.clear_calendar_group_weekly_day(
  p_group_id       uuid,
  p_day_of_week    smallint,
  p_effective_from date DEFAULT CURRENT_DATE
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid;
BEGIN
  SELECT cg.tenant_id INTO v_tenant_id FROM data.calendar_groups cg WHERE cg.id = p_group_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'calendar_group_not_found: %', p_group_id USING ERRCODE = 'P0002';
  END IF;
  IF auth.uid() IS NOT NULL AND NOT data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.calendar_group_weekly_intervals
  SET valid_to = p_effective_from, updated_at = now()
  WHERE group_id = p_group_id AND day_of_week = p_day_of_week
    AND valid_to IS NULL AND valid_from < p_effective_from;

  DELETE FROM data.calendar_group_weekly_intervals
  WHERE group_id = p_group_id AND day_of_week = p_day_of_week AND valid_from >= p_effective_from;
END;
$$;

GRANT EXECUTE ON FUNCTION api.clear_calendar_group_weekly_day(uuid, smallint, date) TO authenticated;

CREATE OR REPLACE FUNCTION api.clear_employee_weekly_day(
  p_employee_id    uuid,
  p_day_of_week    smallint,
  p_effective_from date DEFAULT CURRENT_DATE
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid;
BEGIN
  SELECT e.tenant_id INTO v_tenant_id FROM data.employees e WHERE e.id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id USING ERRCODE = 'P0002';
  END IF;
  IF auth.uid() IS NOT NULL AND NOT data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.employee_weekly_intervals
  SET valid_to = p_effective_from, updated_at = now()
  WHERE employee_id = p_employee_id AND day_of_week = p_day_of_week
    AND valid_to IS NULL AND valid_from < p_effective_from;

  DELETE FROM data.employee_weekly_intervals
  WHERE employee_id = p_employee_id AND day_of_week = p_day_of_week AND valid_from >= p_effective_from;
END;
$$;

GRANT EXECUTE ON FUNCTION api.clear_employee_weekly_day(uuid, smallint, date) TO authenticated;

CREATE OR REPLACE FUNCTION api.get_calendar_group_weekly_pattern(
  p_group_id uuid,
  p_at_date  date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'day_of_week', cgwi.day_of_week,
    'day_type', cgwi.day_type,
    'work_intervals', data.labor_effective_intervals(cgwi.work_intervals, cgwi.work_start, cgwi.work_end),
    'valid_from', cgwi.valid_from,
    'valid_to', cgwi.valid_to
  ) ORDER BY cgwi.day_of_week), '[]'::jsonb)
  FROM data.calendar_group_weekly_intervals cgwi
  WHERE cgwi.group_id = p_group_id
    AND cgwi.valid_from <= p_at_date
    AND (cgwi.valid_to IS NULL OR cgwi.valid_to > p_at_date);
$$;

GRANT EXECUTE ON FUNCTION api.get_calendar_group_weekly_pattern(uuid, date) TO authenticated;

CREATE OR REPLACE FUNCTION api.get_employee_weekly_pattern(
  p_employee_id uuid,
  p_at_date     date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'day_of_week', ewi.day_of_week,
    'day_type', ewi.day_type,
    'work_intervals', data.labor_effective_intervals(ewi.work_intervals, ewi.work_start, ewi.work_end),
    'valid_from', ewi.valid_from,
    'valid_to', ewi.valid_to
  ) ORDER BY ewi.day_of_week), '[]'::jsonb)
  FROM data.employee_weekly_intervals ewi
  WHERE ewi.employee_id = p_employee_id
    AND ewi.valid_from <= p_at_date
    AND (ewi.valid_to IS NULL OR ewi.valid_to > p_at_date);
$$;

GRANT EXECUTE ON FUNCTION api.get_employee_weekly_pattern(uuid, date) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. Integració al resolver — data.resolve_schedule_planner_day
--    Noves capes 6 (employee_weekly) i 7 (calendar_group_weekly), entre els
--    overrides puntuals (labor_calendar_overrides) i el festiu assignat.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION data.resolve_schedule_planner_day(
  p_tenant_id              uuid,
  p_context_site_id        uuid,
  p_employee_id            uuid,
  p_calendar_group_id      uuid,
  p_calendar_group_site_id uuid,
  p_date                   date,
  p_holiday_name           text
)
RETURNS TABLE(
  day_type          text,
  day_name          text,
  work_intervals    jsonb,
  planned_minutes   integer,
  source            text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_o              data.labor_calendar_overrides%ROWTYPE;
  v_is_site_bound  boolean := p_calendar_group_site_id IS NOT NULL;
  v_dow            smallint := EXTRACT(DOW FROM p_date)::smallint;
  v_w              record;
BEGIN
  -- Employee override
  IF p_employee_id IS NOT NULL THEN
    SELECT * INTO v_o
    FROM data.labor_calendar_overrides
    WHERE tenant_id = p_tenant_id AND calendar_date = p_date AND employee_id = p_employee_id
    LIMIT 1;
    IF FOUND THEN
      RETURN QUERY SELECT
        v_o.day_type,
        v_o.day_name,
        data.labor_effective_intervals(v_o.work_intervals, v_o.work_start, v_o.work_end),
        CASE WHEN v_o.day_type = 'work'
          THEN data.labor_planned_minutes(v_o.work_intervals, v_o.work_start, v_o.work_end)
          ELSE 0 END,
        'employee_override'::text;
      RETURN;
    END IF;
  END IF;

  -- Group site override
  IF p_calendar_group_id IS NOT NULL AND p_context_site_id IS NOT NULL THEN
    SELECT * INTO v_o
    FROM data.labor_calendar_overrides
    WHERE tenant_id = p_tenant_id AND calendar_date = p_date
      AND group_id = p_calendar_group_id AND site_id = p_context_site_id
    LIMIT 1;
    IF FOUND THEN
      RETURN QUERY SELECT
        v_o.day_type, v_o.day_name,
        data.labor_effective_intervals(v_o.work_intervals, v_o.work_start, v_o.work_end),
        CASE WHEN v_o.day_type = 'work'
          THEN data.labor_planned_minutes(v_o.work_intervals, v_o.work_start, v_o.work_end) ELSE 0 END,
        'group_site_override'::text;
      RETURN;
    END IF;
  END IF;

  -- Site override
  IF p_context_site_id IS NOT NULL THEN
    SELECT * INTO v_o
    FROM data.labor_calendar_overrides
    WHERE tenant_id = p_tenant_id AND calendar_date = p_date
      AND site_id = p_context_site_id AND group_id IS NULL AND employee_id IS NULL
    LIMIT 1;
    IF FOUND THEN
      RETURN QUERY SELECT
        v_o.day_type, v_o.day_name,
        data.labor_effective_intervals(v_o.work_intervals, v_o.work_start, v_o.work_end),
        CASE WHEN v_o.day_type = 'work'
          THEN data.labor_planned_minutes(v_o.work_intervals, v_o.work_start, v_o.work_end) ELSE 0 END,
        'site_override'::text;
      RETURN;
    END IF;
  END IF;

  -- Group global override (skip when group is site-bound)
  IF p_calendar_group_id IS NOT NULL AND NOT v_is_site_bound THEN
    SELECT * INTO v_o
    FROM data.labor_calendar_overrides
    WHERE tenant_id = p_tenant_id AND calendar_date = p_date
      AND group_id = p_calendar_group_id AND site_id IS NULL
    LIMIT 1;
    IF FOUND THEN
      RETURN QUERY SELECT
        v_o.day_type, v_o.day_name,
        data.labor_effective_intervals(v_o.work_intervals, v_o.work_start, v_o.work_end),
        CASE WHEN v_o.day_type = 'work'
          THEN data.labor_planned_minutes(v_o.work_intervals, v_o.work_start, v_o.work_end) ELSE 0 END,
        'group_global_override'::text;
      RETURN;
    END IF;
  END IF;

  -- Tenant override
  SELECT * INTO v_o
  FROM data.labor_calendar_overrides
  WHERE tenant_id = p_tenant_id AND calendar_date = p_date
    AND site_id IS NULL AND group_id IS NULL AND employee_id IS NULL
  LIMIT 1;
  IF FOUND THEN
    RETURN QUERY SELECT
      v_o.day_type, v_o.day_name,
      data.labor_effective_intervals(v_o.work_intervals, v_o.work_start, v_o.work_end),
      CASE WHEN v_o.day_type = 'work'
        THEN data.labor_planned_minutes(v_o.work_intervals, v_o.work_start, v_o.work_end) ELSE 0 END,
      'tenant_override'::text;
    RETURN;
  END IF;

  -- Assigned holiday — guanya a la base recurrent (manté l'ordre de prioritat
  -- previ a ADR-0003: un festiu assignat és sempre "no laborable", encara que
  -- el patró setmanal digui el contrari; només els overrides puntuals de dalt
  -- poden forçar-lo a laborable, p.ex. force_work via employee_day_overrides
  -- o un override puntual amb day_type='work' aquell dia concret).
  IF p_holiday_name IS NOT NULL THEN
    RETURN QUERY SELECT
      'holiday'::text, p_holiday_name, '[]'::jsonb, 0, 'assigned_holiday'::text;
    RETURN;
  END IF;

  -- ADR-0003: Employee weekly recurring base (per sobre del grup, per sota dels punctuals)
  IF p_employee_id IS NOT NULL THEN
    SELECT * INTO v_w
    FROM data.employee_weekly_intervals
    WHERE employee_id = p_employee_id AND day_of_week = v_dow
      AND valid_from <= p_date AND (valid_to IS NULL OR valid_to > p_date)
    ORDER BY valid_from DESC
    LIMIT 1;
    IF FOUND THEN
      RETURN QUERY SELECT
        v_w.day_type,
        NULL::text,
        data.labor_effective_intervals(v_w.work_intervals, v_w.work_start, v_w.work_end),
        CASE WHEN v_w.day_type = 'work'
          THEN data.labor_planned_minutes(v_w.work_intervals, v_w.work_start, v_w.work_end) ELSE 0 END,
        'employee_weekly'::text;
      RETURN;
    END IF;
  END IF;

  -- ADR-0003: Calendar group weekly recurring base
  IF p_calendar_group_id IS NOT NULL THEN
    SELECT * INTO v_w
    FROM data.calendar_group_weekly_intervals
    WHERE group_id = p_calendar_group_id AND day_of_week = v_dow
      AND valid_from <= p_date AND (valid_to IS NULL OR valid_to > p_date)
    ORDER BY valid_from DESC
    LIMIT 1;
    IF FOUND THEN
      RETURN QUERY SELECT
        v_w.day_type,
        NULL::text,
        data.labor_effective_intervals(v_w.work_intervals, v_w.work_start, v_w.work_end),
        CASE WHEN v_w.day_type = 'work'
          THEN data.labor_planned_minutes(v_w.work_intervals, v_w.work_start, v_w.work_end) ELSE 0 END,
        'calendar_group_weekly'::text;
      RETURN;
    END IF;
  END IF;

  RETURN QUERY SELECT 'undefined'::text, NULL::text, '[]'::jsonb, 0, 'none'::text;
END;
$$;

COMMENT ON FUNCTION data.resolve_schedule_planner_day IS
  'ADR-0003: cascada = overrides puntuals (employee > group_site > site > group_global > tenant) '
  '> festiu assignat > base recurrent setmanal (employee_weekly > calendar_group_weekly) > undefined. '
  'El festiu guanya a la base recurrent (manté la prioritat prèvia a ADR-0003).';
