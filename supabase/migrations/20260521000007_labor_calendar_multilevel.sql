-- =============================================================================
-- Migration: 20260521000007_labor_calendar_multilevel.sql
-- Propòsit : Arquitectura multi-nivell per a calendaris laborals i horaris
--
-- Conté:
--   1.  Fix grants api.holiday_calendars (INSERT/UPDATE/DELETE manquen → 403)
--       + api.work_schedules, api.work_schedule_intervals, api.holidays
--   2.  data.tenant_holiday_calendar_assignments
--         → Calendaris de festius per defecte a nivell de tenant
--         → Fallback quan el site no té cap calendari assignat
--   3.  data.employee_day_overrides
--         → Sobreescriptura per empleat d'un dia concret
--         → override_type: 'force_work' (treballa en dia festiu)
--                           'force_holiday' (festiu en dia laborable)
--   4.  RLS, índexs, vistes api.*
--   5.  RPCs: assign_tenant_holiday_calendar / remove_tenant_holiday_calendar_assignment
--   6.  api.resolve_work_day — actualitzat amb cadena de prioritats:
--         1) Absència aprovada
--         2) Sobreescriptura per empleat (employee_day_overrides)
--         3) Calendari de festius del site
--         4) Calendari de festius del tenant (fallback si site sense calendari)
--         5) Resolució d'horari: employee assignment → site default → tenant default
--
-- Cadena de fallback per a horaris de treball (ja implementada en migració 000001):
--   employee_schedule_assignment → site default work_schedule → tenant default work_schedule
-- =============================================================================


-- =============================================================================
-- 1. Fix: GRANT INSERT/UPDATE/DELETE en api views que el frontend escriu
-- =============================================================================

-- api.holiday_calendars — createHolidayCalendar() del frontend fa INSERT directe
GRANT INSERT, UPDATE, DELETE ON api.holiday_calendars               TO authenticated;

-- api.work_schedules — per quan s'implementi la creació d'horaris al frontend
GRANT INSERT, UPDATE, DELETE ON api.work_schedules                  TO authenticated;

-- api.work_schedule_intervals — intervals d'horari
GRANT INSERT, UPDATE, DELETE ON api.work_schedule_intervals         TO authenticated;

-- api.holidays — per insercions manuals de festius (a més dels RPCs import_holidays)
GRANT INSERT, UPDATE, DELETE ON api.holidays                        TO authenticated;

-- api.employee_schedule_assignments — assignació d'horari a empleat
GRANT INSERT, UPDATE, DELETE ON api.employee_schedule_assignments   TO authenticated;


-- =============================================================================
-- 2. data.tenant_holiday_calendar_assignments
-- =============================================================================

CREATE TABLE data.tenant_holiday_calendar_assignments (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid        NOT NULL REFERENCES data.tenants(id)           ON DELETE CASCADE,
  calendar_id  uuid        NOT NULL REFERENCES data.holiday_calendars(id) ON DELETE CASCADE,
  priority     smallint    NOT NULL DEFAULT 0,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_tenant_calendar UNIQUE (tenant_id, calendar_id)
);

COMMENT ON TABLE data.tenant_holiday_calendar_assignments IS
  'Calendaris de festius assignats a nivell de tenant. '
  'Serveixen com a valors per defecte per a tots els sites que no tinguin '
  'cap site_holiday_calendar_assignment propi.';

CREATE INDEX idx_thca_tenant_id    ON data.tenant_holiday_calendar_assignments (tenant_id);
CREATE INDEX idx_thca_calendar_id  ON data.tenant_holiday_calendar_assignments (calendar_id);


-- =============================================================================
-- 3. data.employee_day_overrides
-- =============================================================================

CREATE TABLE data.employee_day_overrides (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid        NOT NULL REFERENCES data.tenants(id)   ON DELETE CASCADE,
  employee_id   uuid        NOT NULL REFERENCES data.employees(id)  ON DELETE CASCADE,
  override_date date        NOT NULL,
  override_type text        NOT NULL
                            CHECK (override_type IN ('force_work', 'force_holiday')),
  note          text,
  created_by    uuid        REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_employee_day_override UNIQUE (employee_id, override_date)
);

COMMENT ON TABLE data.employee_day_overrides IS
  'Sobreescriptura per empleat d''un dia concret. '
  'force_work: l''empleat treballa tot i que el calendari del site marca festiu. '
  'force_holiday: l''empleat no treballa tot i que el calendari marca laborable.';

COMMENT ON COLUMN data.employee_day_overrides.override_type IS
  'force_work  → treballa en dia festiu (prioritat sobre site/tenant holiday check). '
  'force_holiday → festiu personal (dia laborable convertit en festiu per a aquest empleat).';

CREATE INDEX idx_edo_employee_date  ON data.employee_day_overrides (employee_id, override_date);
CREATE INDEX idx_edo_tenant_id      ON data.employee_day_overrides (tenant_id);


-- =============================================================================
-- 4. RLS
-- =============================================================================

ALTER TABLE data.tenant_holiday_calendar_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.employee_day_overrides              ENABLE ROW LEVEL SECURITY;

-- ── tenant_holiday_calendar_assignments ──────────────────────────────────────

CREATE POLICY thca_select ON data.tenant_holiday_calendar_assignments FOR SELECT
  USING (data.jwt_user_tenants() ? tenant_id::text);

CREATE POLICY thca_insert ON data.tenant_holiday_calendar_assignments FOR INSERT
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  );

CREATE POLICY thca_delete ON data.tenant_holiday_calendar_assignments FOR DELETE
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  );

-- ── employee_day_overrides ───────────────────────────────────────────────────

CREATE POLICY edo_select ON data.employee_day_overrides FOR SELECT
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

CREATE POLICY edo_insert ON data.employee_day_overrides FOR INSERT
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  );

CREATE POLICY edo_update ON data.employee_day_overrides FOR UPDATE
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  );

CREATE POLICY edo_delete ON data.employee_day_overrides FOR DELETE
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
  );


-- =============================================================================
-- 5. Grants en data.*
-- =============================================================================

GRANT SELECT, INSERT, DELETE ON data.tenant_holiday_calendar_assignments TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.employee_day_overrides       TO authenticated;

GRANT SELECT ON data.tenant_holiday_calendar_assignments TO service_role;
GRANT SELECT ON data.employee_day_overrides              TO service_role;


-- =============================================================================
-- 6. Vistes api.*
-- =============================================================================

CREATE OR REPLACE VIEW api.tenant_holiday_calendar_assignments
  WITH (security_invoker = true)
AS
SELECT
  thca.id,
  thca.tenant_id,
  thca.calendar_id,
  hc.name         AS calendar_name,
  hc.country_code,
  hc.region_code,
  hc.year,
  hc.is_active    AS calendar_active,
  thca.priority,
  thca.created_at
FROM data.tenant_holiday_calendar_assignments thca
JOIN data.holiday_calendars hc ON hc.id = thca.calendar_id;

CREATE OR REPLACE VIEW api.employee_day_overrides
  WITH (security_invoker = true)
AS
SELECT
  edo.id,
  edo.tenant_id,
  edo.employee_id,
  edo.override_date,
  edo.override_type,
  edo.note,
  edo.created_by,
  edo.created_at
FROM data.employee_day_overrides edo;

GRANT SELECT ON api.tenant_holiday_calendar_assignments TO authenticated;
GRANT INSERT, DELETE ON api.tenant_holiday_calendar_assignments TO authenticated;

GRANT SELECT ON api.employee_day_overrides TO authenticated;
GRANT INSERT, UPDATE, DELETE ON api.employee_day_overrides TO authenticated;


-- =============================================================================
-- 7. RPCs: assign/remove tenant holiday calendar
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 7.1 api.assign_tenant_holiday_calendar
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.assign_tenant_holiday_calendar(
  p_tenant_id   uuid,
  p_calendar_id uuid,
  p_priority    smallint DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, api
AS $$
DECLARE
  v_assignment_id uuid;
BEGIN
  IF p_tenant_id IS NULL OR p_calendar_id IS NULL THEN
    RAISE EXCEPTION 'invalid_params: tenant_id and calendar_id are required'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Verificar que el calendari pertany al tenant o és de sistema (tenant_id IS NULL)
  IF NOT EXISTS (
    SELECT 1 FROM data.holiday_calendars hc
    WHERE hc.id = p_calendar_id
      AND (hc.tenant_id = p_tenant_id OR hc.tenant_id IS NULL)
  ) THEN
    RAISE EXCEPTION 'calendar_not_found_or_tenant_mismatch'
      USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO data.tenant_holiday_calendar_assignments (tenant_id, calendar_id, priority)
  VALUES (p_tenant_id, p_calendar_id, COALESCE(p_priority, 0))
  ON CONFLICT (tenant_id, calendar_id) DO NOTHING
  RETURNING id INTO v_assignment_id;

  IF v_assignment_id IS NULL THEN
    SELECT thca.id INTO v_assignment_id
    FROM data.tenant_holiday_calendar_assignments thca
    WHERE thca.tenant_id = p_tenant_id AND thca.calendar_id = p_calendar_id;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'assignment_id', v_assignment_id,
    'tenant_id', p_tenant_id,
    'calendar_id', p_calendar_id,
    'priority', COALESCE(p_priority, 0)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.assign_tenant_holiday_calendar(uuid, uuid, smallint)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7.2 api.remove_tenant_holiday_calendar_assignment
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.remove_tenant_holiday_calendar_assignment(
  p_assignment_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, api
AS $$
DECLARE
  v_tenant_id   uuid;
  v_calendar_id uuid;
  v_deleted     integer := 0;
BEGIN
  IF p_assignment_id IS NULL THEN
    RAISE EXCEPTION 'invalid_params: assignment_id is required'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT thca.tenant_id, thca.calendar_id
    INTO v_tenant_id, v_calendar_id
  FROM data.tenant_holiday_calendar_assignments thca
  WHERE thca.id = p_assignment_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', true, 'deleted', false, 'assignment_id', p_assignment_id);
  END IF;

  DELETE FROM data.tenant_holiday_calendar_assignments WHERE id = p_assignment_id;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RETURN jsonb_build_object(
    'success', true,
    'deleted', (v_deleted = 1),
    'assignment_id', p_assignment_id,
    'tenant_id', v_tenant_id,
    'calendar_id', v_calendar_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.remove_tenant_holiday_calendar_assignment(uuid)
  TO authenticated, service_role;


-- =============================================================================
-- 8. api.resolve_work_day — actualitzat amb multi-nivell complet
--
--  Cadena de prioritats:
--    1) Absència aprovada de l'empleat
--    2) Sobreescriptura personal (employee_day_overrides)
--       · force_holiday → retorna 'holiday' ignorant el calendari
--       · force_work    → salta la comprovació de festius, va a resolució d'horari
--    3) Calendaris de festius del site (site_holiday_calendar_assignments)
--    4) Calendaris de festius del tenant (tenant_holiday_calendar_assignments)
--       · S'aplica NOMÉS si el site no té cap calendari assignat (fallback pur)
--    5) Resolució d'horari: empleat → per defecte del site → per defecte del tenant
-- =============================================================================

CREATE OR REPLACE FUNCTION api.resolve_work_day(
  p_employee_id  uuid,
  p_work_date    date
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp             record;
  v_tz              text;
  v_schedule_id     uuid;
  v_schedule_name   text;
  v_dow             smallint;
  v_expected_min    int     := 0;
  v_spans_midnight  boolean := false;
  v_shift_start     time;
  v_shift_end       time;
  v_day_type        text    := 'unknown';
  v_holiday         record;
  v_absence         record;
  v_interval_count  int;
  v_emp_override    text;       -- 'force_work' | 'force_holiday' | NULL
  v_skip_holiday    boolean := false;
  v_site_has_calendars boolean := false;
BEGIN
  -- 1. Validar empleat i obtenir tenant/site
  SELECT e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'day_type',        'unknown',
      'expected_minutes', 0,
      'error',           'employee_not_found'
    );
  END IF;

  -- Comprovació d'accés: service_role (auth.uid() IS NULL),
  -- propi empleat, o qui tingui attendance.view_all / labor_calendar.manage
  IF auth.uid() IS NOT NULL THEN
    IF NOT (data.jwt_user_tenants() ? v_emp.tenant_id::text) THEN
      RAISE EXCEPTION 'insufficient_privilege: access denied for employee %', p_employee_id
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NOT (
      data.jwt_has_permission(v_emp.tenant_id, 'attendance.view_all')
      OR data.jwt_has_permission(v_emp.tenant_id, 'labor_calendar.manage')
      OR EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = p_employee_id AND e.user_id = auth.uid()
      )
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege: necessites attendance.view_all o ser l''empleat consultat'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  -- 2. Timezone del site
  v_tz := COALESCE(
    (api.get_effective_settings(
      p_site_id   => v_emp.site_id,
      p_user_id   => NULL,
      p_tenant_id => v_emp.tenant_id
    ) ->> 'site_timezone'),
    'Europe/Madrid'
  );

  -- 3. Comprovar absència aprovada (prioritat màxima)
  SELECT ea.id, ea.absence_type, ea.is_paid, ea.hours_per_day
  INTO v_absence
  FROM data.employee_absences ea
  WHERE ea.employee_id = p_employee_id
    AND ea.status      = 'approved'
    AND ea.start_date  <= p_work_date
    AND ea.end_date    >= p_work_date
  ORDER BY ea.created_at DESC
  LIMIT 1;

  IF FOUND THEN
    -- Calcular expected_minutes de l'horari perquè el worker pugui derivar absence_minutes
    SELECT COALESCE(SUM(ROUND(EXTRACT(EPOCH FROM
      CASE WHEN wsi.end_time > wsi.start_time
           THEN wsi.end_time - wsi.start_time
           ELSE interval '24 hours' + (wsi.end_time - wsi.start_time) END
    ) / 60))::int, 0)
    INTO v_expected_min
    FROM data.work_schedule_intervals wsi
    WHERE wsi.schedule_id = (
      SELECT esa.schedule_id FROM data.employee_schedule_assignments esa
      WHERE esa.employee_id   = p_employee_id
        AND esa.effective_from <= p_work_date
        AND (esa.effective_to IS NULL OR esa.effective_to > p_work_date)
      ORDER BY esa.effective_from DESC LIMIT 1
    )
    AND wsi.day_of_week = EXTRACT(DOW FROM p_work_date)::smallint;

    RETURN jsonb_build_object(
      'day_type',              'absence',
      'expected_minutes',      v_expected_min,
      'site_timezone',         v_tz,
      'is_holiday',            false,
      'holiday_name',          null,
      'is_absence',            true,
      'absence_id',            v_absence.id,
      'absence_type',          v_absence.absence_type,
      'absence_is_paid',       v_absence.is_paid,
      'absence_hours_per_day', v_absence.hours_per_day,
      'schedule_id',           null,
      'schedule_name',         null,
      'spans_midnight',        false,
      'shift_start_time',      null,
      'shift_end_time',        null,
      'employee_override',     false
    );
  END IF;

  -- 4. Sobreescriptura personal de l'empleat per a aquest dia
  SELECT edo.override_type INTO v_emp_override
  FROM data.employee_day_overrides edo
  WHERE edo.employee_id   = p_employee_id
    AND edo.override_date  = p_work_date;

  IF FOUND THEN
    IF v_emp_override = 'force_holiday' THEN
      -- Empleat marca festiu personal (dia que no treballa independentment del calendari)
      RETURN jsonb_build_object(
        'day_type',          'holiday',
        'expected_minutes',  0,
        'site_timezone',     v_tz,
        'is_holiday',        true,
        'holiday_name',      null,
        'holiday_type',      'tenant_custom',
        'is_half_day',       false,
        'is_absence',        false,
        'absence_id',        null,
        'absence_type',      null,
        'schedule_id',       null,
        'schedule_name',     null,
        'spans_midnight',    false,
        'shift_start_time',  null,
        'shift_end_time',    null,
        'employee_override', true
      );
    ELSIF v_emp_override = 'force_work' THEN
      -- Empleat treballa tot i que podria ser festiu → saltar comprovació de festius
      v_skip_holiday := true;
    END IF;
  END IF;

  -- 5. Comprovar festius (si no s'ha forçat laborable via override)
  IF NOT v_skip_holiday THEN

    -- 5a. Calendaris assignats al site (prioritat)
    IF v_emp.site_id IS NOT NULL THEN
      SELECT h.name, h.holiday_type, h.is_half_day
      INTO v_holiday
      FROM data.holidays h
      JOIN data.holiday_calendars hc ON hc.id = h.calendar_id
      JOIN data.site_holiday_calendar_assignments shca ON shca.calendar_id = hc.id
      WHERE shca.site_id = v_emp.site_id
        AND h.date = p_work_date
        AND hc.is_active = true
      ORDER BY shca.priority DESC, hc.tenant_id NULLS LAST
      LIMIT 1;

      -- Anotem si el site té algun calendari (per determinar si cal fallback al tenant)
      v_site_has_calendars := EXISTS (
        SELECT 1 FROM data.site_holiday_calendar_assignments shca2
        WHERE shca2.site_id = v_emp.site_id
      );
    END IF;

    -- 5b. Fallback al tenant: NOMÉS si el site no té cap calendari assignat
    IF NOT FOUND AND NOT v_site_has_calendars THEN
      SELECT h.name, h.holiday_type, h.is_half_day
      INTO v_holiday
      FROM data.holidays h
      JOIN data.holiday_calendars hc ON hc.id = h.calendar_id
      JOIN data.tenant_holiday_calendar_assignments thca ON thca.calendar_id = hc.id
      WHERE thca.tenant_id = v_emp.tenant_id
        AND h.date = p_work_date
        AND hc.is_active = true
      ORDER BY thca.priority DESC
      LIMIT 1;
    END IF;

    IF FOUND THEN
      RETURN jsonb_build_object(
        'day_type',          CASE WHEN v_holiday.is_half_day THEN 'half_holiday' ELSE 'holiday' END,
        'expected_minutes',  0,
        'site_timezone',     v_tz,
        'is_holiday',        true,
        'holiday_name',      v_holiday.name,
        'holiday_type',      v_holiday.holiday_type,
        'is_half_day',       v_holiday.is_half_day,
        'is_absence',        false,
        'absence_id',        null,
        'absence_type',      null,
        'schedule_id',       null,
        'schedule_name',     null,
        'spans_midnight',    false,
        'shift_start_time',  null,
        'shift_end_time',    null,
        'employee_override', false
      );
    END IF;
  END IF;

  -- 6. Obtenir horari actiu de l'empleat per a p_work_date (assignació directa)
  SELECT esa.schedule_id, ws.name
  INTO v_schedule_id, v_schedule_name
  FROM data.employee_schedule_assignments esa
  JOIN data.work_schedules ws ON ws.id = esa.schedule_id
  WHERE esa.employee_id   = p_employee_id
    AND esa.effective_from <= p_work_date
    AND (esa.effective_to IS NULL OR esa.effective_to > p_work_date)
  ORDER BY esa.effective_from DESC
  LIMIT 1;

  -- Fallback: horari per defecte del site
  IF NOT FOUND AND v_emp.site_id IS NOT NULL THEN
    SELECT ws.id, ws.name
    INTO v_schedule_id, v_schedule_name
    FROM data.work_schedules ws
    WHERE ws.tenant_id  = v_emp.tenant_id
      AND ws.site_id    = v_emp.site_id
      AND ws.is_default = true
      AND ws.is_active  = true
    LIMIT 1;
  END IF;

  -- Fallback: horari per defecte del tenant
  IF NOT FOUND THEN
    SELECT ws.id, ws.name
    INTO v_schedule_id, v_schedule_name
    FROM data.work_schedules ws
    WHERE ws.tenant_id  = v_emp.tenant_id
      AND ws.site_id    IS NULL
      AND ws.is_default = true
      AND ws.is_active  = true
    LIMIT 1;
  END IF;

  -- Sense horari → 'unknown'
  IF v_schedule_id IS NULL THEN
    RETURN jsonb_build_object(
      'day_type',          'unknown',
      'expected_minutes',  0,
      'site_timezone',     v_tz,
      'is_holiday',        false,
      'holiday_name',      null,
      'is_absence',        false,
      'absence_id',        null,
      'absence_type',      null,
      'schedule_id',       null,
      'schedule_name',     null,
      'spans_midnight',    false,
      'shift_start_time',  null,
      'shift_end_time',    null,
      'employee_override', COALESCE(v_emp_override = 'force_work', false)
    );
  END IF;

  -- 7. DOW del dia (PG: 0=Diumenge, 1=Dilluns, ..., 6=Dissabte)
  v_dow := EXTRACT(DOW FROM p_work_date)::smallint;

  -- 8. Intervals per a aquest DOW
  SELECT COUNT(*) INTO v_interval_count
  FROM data.work_schedule_intervals
  WHERE schedule_id = v_schedule_id AND day_of_week = v_dow;

  IF v_interval_count = 0 THEN
    RETURN jsonb_build_object(
      'day_type',          'non_working',
      'expected_minutes',  0,
      'site_timezone',     v_tz,
      'is_holiday',        false,
      'holiday_name',      null,
      'is_absence',        false,
      'absence_id',        null,
      'absence_type',      null,
      'schedule_id',       v_schedule_id,
      'schedule_name',     v_schedule_name,
      'spans_midnight',    false,
      'shift_start_time',  null,
      'shift_end_time',    null,
      'employee_override', COALESCE(v_emp_override = 'force_work', false)
    );
  END IF;

  -- 9. Calcular expected_minutes i detectar torn nocturn
  SELECT
    COALESCE(SUM(
      ROUND(
        EXTRACT(EPOCH FROM
          CASE WHEN end_time > start_time
               THEN end_time - start_time
               ELSE interval '24 hours' + (end_time - start_time)
          END
        ) / 60
      )
    )::int, 0),
    bool_or(end_time < start_time),
    MIN(start_time),
    MAX(end_time)
  INTO v_expected_min, v_spans_midnight, v_shift_start, v_shift_end
  FROM data.work_schedule_intervals
  WHERE schedule_id = v_schedule_id AND day_of_week = v_dow;

  RETURN jsonb_build_object(
    'day_type',          'working',
    'expected_minutes',  v_expected_min,
    'site_timezone',     v_tz,
    'is_holiday',        false,
    'holiday_name',      null,
    'is_absence',        false,
    'absence_id',        null,
    'absence_type',      null,
    'schedule_id',       v_schedule_id,
    'schedule_name',     v_schedule_name,
    'spans_midnight',    v_spans_midnight,
    'shift_start_time',  v_shift_start,
    'shift_end_time',    v_shift_end,
    'employee_override', COALESCE(v_emp_override = 'force_work', false)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.resolve_work_day(uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION api.resolve_work_day(uuid, date) TO service_role;
