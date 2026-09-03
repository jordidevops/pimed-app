-- =============================================================================
-- EX-07.1 — Disponibilitat recurrent i excepcions
-- No-objectius: shift_openings/claims (EX-07.2+), portal autoservei complet, swaps.
-- =============================================================================

-- ─── 1. Regles recurrents ────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS data.employee_availability_rules (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id      uuid        NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  day_of_week      smallint    NOT NULL
    CONSTRAINT employee_availability_rules_dow_chk CHECK (day_of_week BETWEEN 0 AND 6),
  start_time       time        NOT NULL,
  end_time         time        NOT NULL,
  preference       text        NOT NULL DEFAULT 'available'
    CONSTRAINT employee_availability_rules_pref_chk
      CHECK (preference IN ('preferred', 'available', 'unavailable')),
  notes            text,
  editable_until   date,
  effective_from   date        NOT NULL DEFAULT CURRENT_DATE,
  effective_to     date,
  is_active        boolean     NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employee_availability_rules_dates_chk
    CHECK (effective_to IS NULL OR effective_to > effective_from),
  CONSTRAINT employee_availability_rules_times_chk
    CHECK (start_time <> end_time)
);

CREATE INDEX IF NOT EXISTS idx_emp_avail_rules_emp_active
  ON data.employee_availability_rules (employee_id, is_active, day_of_week);

CREATE INDEX IF NOT EXISTS idx_emp_avail_rules_tenant
  ON data.employee_availability_rules (tenant_id, is_active);

COMMENT ON TABLE data.employee_availability_rules IS
  'EX-07.1: disponibilitat recurrent per dia de la setmana (0=diumenge). No és absència ni garanteix torn.';

DROP TRIGGER IF EXISTS trg_updated_at_employee_availability_rules ON data.employee_availability_rules;
CREATE TRIGGER trg_updated_at_employee_availability_rules
  BEFORE UPDATE ON data.employee_availability_rules
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

ALTER TABLE data.employee_availability_rules ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ear_select ON data.employee_availability_rules;
CREATE POLICY ear_select ON data.employee_availability_rules FOR SELECT
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'attendance.view_all')
      OR data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
      OR data.jwt_has_permission(tenant_id, 'labor_calendar.view')
      OR EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = employee_availability_rules.employee_id AND e.user_id = auth.uid()
      )
    )
  );

DROP POLICY IF EXISTS ear_write ON data.employee_availability_rules;
CREATE POLICY ear_write ON data.employee_availability_rules FOR ALL
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
      OR EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = employee_availability_rules.employee_id AND e.user_id = auth.uid()
      )
    )
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
      OR EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = employee_availability_rules.employee_id AND e.user_id = auth.uid()
      )
    )
  );

GRANT SELECT ON data.employee_availability_rules TO authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON data.employee_availability_rules TO service_role;

CREATE OR REPLACE VIEW api.employee_availability_rules
WITH (security_invoker = true) AS
SELECT * FROM data.employee_availability_rules;

GRANT SELECT ON api.employee_availability_rules TO authenticated, service_role;

-- ─── 2. Excepcions per data ──────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS data.employee_availability_exceptions (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id      uuid        NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  exception_date   date        NOT NULL,
  start_time       time,
  end_time         time,
  preference       text        NOT NULL DEFAULT 'unavailable'
    CONSTRAINT employee_availability_exceptions_pref_chk
      CHECK (preference IN ('preferred', 'available', 'unavailable')),
  notes            text,
  editable_until   date,
  is_active        boolean     NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employee_availability_exceptions_times_chk
    CHECK (
      (start_time IS NULL AND end_time IS NULL)
      OR (start_time IS NOT NULL AND end_time IS NOT NULL AND start_time <> end_time)
    )
);

CREATE INDEX IF NOT EXISTS idx_emp_avail_exc_emp_date
  ON data.employee_availability_exceptions (employee_id, exception_date)
  WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_emp_avail_exc_tenant_date
  ON data.employee_availability_exceptions (tenant_id, exception_date)
  WHERE is_active = true;

COMMENT ON TABLE data.employee_availability_exceptions IS
  'EX-07.1: excepció de disponibilitat per data (substitueix les regles del dia). start/end NULL = tot el dia.';

DROP TRIGGER IF EXISTS trg_updated_at_employee_availability_exceptions ON data.employee_availability_exceptions;
CREATE TRIGGER trg_updated_at_employee_availability_exceptions
  BEFORE UPDATE ON data.employee_availability_exceptions
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

ALTER TABLE data.employee_availability_exceptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS eae_select ON data.employee_availability_exceptions;
CREATE POLICY eae_select ON data.employee_availability_exceptions FOR SELECT
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'attendance.view_all')
      OR data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
      OR data.jwt_has_permission(tenant_id, 'labor_calendar.view')
      OR EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = employee_availability_exceptions.employee_id AND e.user_id = auth.uid()
      )
    )
  );

DROP POLICY IF EXISTS eae_write ON data.employee_availability_exceptions;
CREATE POLICY eae_write ON data.employee_availability_exceptions FOR ALL
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
      OR EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = employee_availability_exceptions.employee_id AND e.user_id = auth.uid()
      )
    )
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
      OR EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = employee_availability_exceptions.employee_id AND e.user_id = auth.uid()
      )
    )
  );

GRANT SELECT ON data.employee_availability_exceptions TO authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON data.employee_availability_exceptions TO service_role;

CREATE OR REPLACE VIEW api.employee_availability_exceptions
WITH (security_invoker = true) AS
SELECT * FROM data.employee_availability_exceptions;

GRANT SELECT ON api.employee_availability_exceptions TO authenticated, service_role;

-- ─── 3. Helpers ──────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.can_manage_employee_availability(
  p_tenant_id   uuid,
  p_site_id     uuid,
  p_employee_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT
    data.jwt_has_permission(p_tenant_id, 'labor_calendar.manage', p_site_id)
    OR EXISTS (
      SELECT 1 FROM data.employees e
      WHERE e.id = p_employee_id AND e.user_id = auth.uid()
    );
$$;

CREATE OR REPLACE FUNCTION data.can_view_employee_availability(
  p_tenant_id   uuid,
  p_site_id     uuid,
  p_employee_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT
    data.jwt_has_permission(p_tenant_id, 'labor_calendar.manage', p_site_id)
    OR data.jwt_has_permission(p_tenant_id, 'labor_calendar.view', p_site_id)
    OR data.jwt_has_permission(p_tenant_id, 'attendance.view_all', p_site_id)
    OR EXISTS (
      SELECT 1 FROM data.employees e
      WHERE e.id = p_employee_id AND e.user_id = auth.uid()
    );
$$;

CREATE OR REPLACE FUNCTION data.employee_availability_windows(
  p_employee_id uuid,
  p_on_date     date
)
RETURNS TABLE (
  start_min   int,
  end_min     int,
  preference  text,
  source      text,
  notes       text,
  source_id   uuid
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_has_exc boolean;
  v_dow smallint;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM data.employee_availability_exceptions x
    WHERE x.employee_id = p_employee_id
      AND x.exception_date = p_on_date
      AND x.is_active = true
  ) INTO v_has_exc;

  IF v_has_exc THEN
    RETURN QUERY
    SELECT
      CASE WHEN x.start_time IS NULL THEN 0 ELSE data.time_to_minutes(x.start_time) END,
      CASE
        WHEN x.end_time IS NULL THEN 1440
        WHEN x.end_time <= x.start_time THEN data.time_to_minutes(x.end_time) + 1440
        ELSE data.time_to_minutes(x.end_time)
      END,
      x.preference,
      'exception'::text,
      x.notes,
      x.id
    FROM data.employee_availability_exceptions x
    WHERE x.employee_id = p_employee_id
      AND x.exception_date = p_on_date
      AND x.is_active = true
    ORDER BY 1, 2;
    RETURN;
  END IF;

  v_dow := EXTRACT(DOW FROM p_on_date)::smallint;

  RETURN QUERY
  SELECT
    data.time_to_minutes(r.start_time),
    CASE
      WHEN r.end_time <= r.start_time THEN data.time_to_minutes(r.end_time) + 1440
      ELSE data.time_to_minutes(r.end_time)
    END,
    r.preference,
    'rule'::text,
    r.notes,
    r.id
  FROM data.employee_availability_rules r
  WHERE r.employee_id = p_employee_id
    AND r.is_active = true
    AND r.day_of_week = v_dow
    AND r.effective_from <= p_on_date
    AND (r.effective_to IS NULL OR r.effective_to > p_on_date)
  ORDER BY 1, 2;
END;
$$;

REVOKE ALL ON FUNCTION data.employee_availability_windows(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.employee_availability_windows(uuid, date) TO authenticated, service_role;

-- Preferència efectiva per una franja: unavailable > preferred > available > unknown
CREATE OR REPLACE FUNCTION data.employee_availability_for_window(
  p_employee_id uuid,
  p_on_date     date,
  p_start_time  time,
  p_end_time    time
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_start int;
  v_end int;
  v_pref text;
  v_has_any boolean := false;
  v_has_unavail boolean := false;
  v_has_preferred boolean := false;
  v_has_available boolean := false;
  w record;
BEGIN
  IF p_start_time IS NULL OR p_end_time IS NULL OR p_start_time = p_end_time THEN
    RAISE EXCEPTION 'invalid_window' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  v_start := data.time_to_minutes(p_start_time);
  v_end := CASE
    WHEN p_end_time <= p_start_time THEN data.time_to_minutes(p_end_time) + 1440
    ELSE data.time_to_minutes(p_end_time)
  END;

  FOR w IN
    SELECT * FROM data.employee_availability_windows(p_employee_id, p_on_date)
  LOOP
    IF data.time_range_overlaps_minutes(w.start_min, LEAST(w.end_min, 1440), v_start, LEAST(v_end, 1440))
       OR (w.end_min > 1440 AND data.time_range_overlaps_minutes(0, w.end_min - 1440, v_start, LEAST(v_end, 1440)))
       OR (v_end > 1440 AND data.time_range_overlaps_minutes(w.start_min, LEAST(w.end_min, 1440), 0, v_end - 1440))
    THEN
      v_has_any := true;
      IF w.preference = 'unavailable' THEN
        v_has_unavail := true;
      ELSIF w.preference = 'preferred' THEN
        v_has_preferred := true;
      ELSIF w.preference = 'available' THEN
        v_has_available := true;
      END IF;
    END IF;
  END LOOP;

  IF NOT v_has_any THEN
    RETURN 'unknown';
  END IF;
  IF v_has_unavail THEN
    RETURN 'unavailable';
  END IF;
  IF v_has_preferred THEN
    RETURN 'preferred';
  END IF;
  IF v_has_available THEN
    RETURN 'available';
  END IF;
  RETURN 'unknown';
END;
$$;

REVOKE ALL ON FUNCTION data.employee_availability_for_window(uuid, date, time, time) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.employee_availability_for_window(uuid, date, time, time) TO authenticated, service_role;

COMMENT ON FUNCTION data.employee_availability_for_window IS
  'EX-07.1: preferència efectiva (preferred|available|unavailable|unknown) per franja.';

-- ─── 4. RPCs CRUD regles ─────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.list_employee_availability_rules(
  p_employee_id uuid,
  p_include_inactive boolean DEFAULT false
)
RETURNS SETOF api.employee_availability_rules
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp record;
BEGIN
  SELECT e.id, e.tenant_id, e.site_id INTO v_emp
  FROM data.employees e WHERE e.id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT data.can_view_employee_availability(v_emp.tenant_id, v_emp.site_id, v_emp.id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  SELECT r.*
  FROM data.employee_availability_rules r
  WHERE r.employee_id = p_employee_id
    AND (p_include_inactive OR r.is_active)
  ORDER BY r.day_of_week, r.start_time;
END;
$$;

CREATE OR REPLACE FUNCTION api.upsert_employee_availability_rule(
  p_id             uuid DEFAULT NULL,
  p_employee_id    uuid DEFAULT NULL,
  p_day_of_week    smallint DEFAULT NULL,
  p_start_time     time DEFAULT NULL,
  p_end_time       time DEFAULT NULL,
  p_preference     text DEFAULT 'available',
  p_notes          text DEFAULT NULL,
  p_editable_until date DEFAULT NULL,
  p_effective_from date DEFAULT NULL,
  p_effective_to   date DEFAULT NULL,
  p_is_active      boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp record;
  v_row data.employee_availability_rules;
  v_is_manager boolean;
BEGIN
  IF p_id IS NOT NULL THEN
    SELECT * INTO v_row FROM data.employee_availability_rules WHERE id = p_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'rule_not_found' USING ERRCODE = 'P0002';
    END IF;
    SELECT e.* INTO v_emp FROM data.employees e WHERE e.id = v_row.employee_id;
  ELSE
    IF p_employee_id IS NULL OR p_day_of_week IS NULL OR p_start_time IS NULL OR p_end_time IS NULL THEN
      RAISE EXCEPTION 'employee_dow_times_required' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    SELECT e.* INTO v_emp FROM data.employees e WHERE e.id = p_employee_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  IF NOT data.can_manage_employee_availability(v_emp.tenant_id, v_emp.site_id, v_emp.id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_is_manager := COALESCE(
    data.jwt_has_permission(v_emp.tenant_id, 'labor_calendar.manage', v_emp.site_id),
    false
  );

  IF NOT v_is_manager AND v_row.id IS NOT NULL THEN
    IF v_row.editable_until IS NOT NULL AND CURRENT_DATE > v_row.editable_until THEN
      RAISE EXCEPTION 'editable_until_passed' USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  IF p_preference IS NOT NULL AND p_preference NOT IN ('preferred', 'available', 'unavailable') THEN
    RAISE EXCEPTION 'invalid_preference' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO data.employee_availability_rules (
      tenant_id, employee_id, day_of_week, start_time, end_time, preference,
      notes, editable_until, effective_from, effective_to, is_active
    ) VALUES (
      v_emp.tenant_id, v_emp.id, p_day_of_week, p_start_time, p_end_time,
      COALESCE(p_preference, 'available'),
      NULLIF(btrim(p_notes), ''),
      p_editable_until,
      COALESCE(p_effective_from, CURRENT_DATE),
      p_effective_to,
      COALESCE(p_is_active, true)
    )
    RETURNING * INTO v_row;
  ELSE
    UPDATE data.employee_availability_rules r SET
      day_of_week = COALESCE(p_day_of_week, r.day_of_week),
      start_time = COALESCE(p_start_time, r.start_time),
      end_time = COALESCE(p_end_time, r.end_time),
      preference = COALESCE(p_preference, r.preference),
      notes = CASE WHEN p_notes IS NULL THEN r.notes ELSE NULLIF(btrim(p_notes), '') END,
      editable_until = CASE WHEN v_is_manager THEN COALESCE(p_editable_until, r.editable_until) ELSE r.editable_until END,
      effective_from = COALESCE(p_effective_from, r.effective_from),
      effective_to = CASE WHEN p_effective_to IS NULL AND p_effective_from IS NULL THEN r.effective_to ELSE p_effective_to END,
      is_active = COALESCE(p_is_active, r.is_active),
      updated_at = now()
    WHERE r.id = p_id
    RETURNING * INTO v_row;
  END IF;

  RETURN to_jsonb(v_row);
END;
$$;

CREATE OR REPLACE FUNCTION api.deactivate_employee_availability_rule(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_row data.employee_availability_rules;
  v_emp record;
  v_is_manager boolean;
BEGIN
  SELECT * INTO v_row FROM data.employee_availability_rules WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'rule_not_found' USING ERRCODE = 'P0002';
  END IF;
  SELECT e.* INTO v_emp FROM data.employees e WHERE e.id = v_row.employee_id;

  IF NOT data.can_manage_employee_availability(v_emp.tenant_id, v_emp.site_id, v_emp.id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_is_manager := COALESCE(
    data.jwt_has_permission(v_emp.tenant_id, 'labor_calendar.manage', v_emp.site_id),
    false
  );
  IF NOT v_is_manager AND v_row.editable_until IS NOT NULL AND CURRENT_DATE > v_row.editable_until THEN
    RAISE EXCEPTION 'editable_until_passed' USING ERRCODE = 'check_violation';
  END IF;

  UPDATE data.employee_availability_rules
  SET is_active = false, updated_at = now()
  WHERE id = p_id
  RETURNING * INTO v_row;

  RETURN jsonb_build_object('id', v_row.id, 'is_active', false);
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_employee_availability_rules(uuid, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.upsert_employee_availability_rule(uuid, uuid, smallint, time, time, text, text, date, date, date, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.deactivate_employee_availability_rule(uuid) TO authenticated, service_role;

-- ─── 5. RPCs CRUD excepcions ─────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.list_employee_availability_exceptions(
  p_employee_id uuid,
  p_from date DEFAULT NULL,
  p_to date DEFAULT NULL,
  p_include_inactive boolean DEFAULT false
)
RETURNS SETOF api.employee_availability_exceptions
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp record;
BEGIN
  SELECT e.id, e.tenant_id, e.site_id INTO v_emp
  FROM data.employees e WHERE e.id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT data.can_view_employee_availability(v_emp.tenant_id, v_emp.site_id, v_emp.id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  SELECT x.*
  FROM data.employee_availability_exceptions x
  WHERE x.employee_id = p_employee_id
    AND (p_include_inactive OR x.is_active)
    AND (p_from IS NULL OR x.exception_date >= p_from)
    AND (p_to IS NULL OR x.exception_date <= p_to)
  ORDER BY x.exception_date DESC, x.start_time NULLS FIRST;
END;
$$;

CREATE OR REPLACE FUNCTION api.upsert_employee_availability_exception(
  p_id             uuid DEFAULT NULL,
  p_employee_id    uuid DEFAULT NULL,
  p_exception_date date DEFAULT NULL,
  p_start_time     time DEFAULT NULL,
  p_end_time       time DEFAULT NULL,
  p_preference     text DEFAULT 'unavailable',
  p_notes          text DEFAULT NULL,
  p_editable_until date DEFAULT NULL,
  p_is_active      boolean DEFAULT true,
  p_clear_times    boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp record;
  v_row data.employee_availability_exceptions;
  v_is_manager boolean;
  v_start time;
  v_end time;
BEGIN
  IF p_id IS NOT NULL THEN
    SELECT * INTO v_row FROM data.employee_availability_exceptions WHERE id = p_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'exception_not_found' USING ERRCODE = 'P0002';
    END IF;
    SELECT e.* INTO v_emp FROM data.employees e WHERE e.id = v_row.employee_id;
  ELSE
    IF p_employee_id IS NULL OR p_exception_date IS NULL THEN
      RAISE EXCEPTION 'employee_and_date_required' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    SELECT e.* INTO v_emp FROM data.employees e WHERE e.id = p_employee_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  IF NOT data.can_manage_employee_availability(v_emp.tenant_id, v_emp.site_id, v_emp.id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_is_manager := COALESCE(
    data.jwt_has_permission(v_emp.tenant_id, 'labor_calendar.manage', v_emp.site_id),
    false
  );
  IF NOT v_is_manager AND v_row.id IS NOT NULL THEN
    IF v_row.editable_until IS NOT NULL AND CURRENT_DATE > v_row.editable_until THEN
      RAISE EXCEPTION 'editable_until_passed' USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  IF p_preference IS NOT NULL AND p_preference NOT IN ('preferred', 'available', 'unavailable') THEN
    RAISE EXCEPTION 'invalid_preference' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_clear_times THEN
    v_start := NULL;
    v_end := NULL;
  ELSE
    v_start := p_start_time;
    v_end := p_end_time;
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO data.employee_availability_exceptions (
      tenant_id, employee_id, exception_date, start_time, end_time,
      preference, notes, editable_until, is_active
    ) VALUES (
      v_emp.tenant_id, v_emp.id, p_exception_date, v_start, v_end,
      COALESCE(p_preference, 'unavailable'),
      NULLIF(btrim(p_notes), ''),
      p_editable_until,
      COALESCE(p_is_active, true)
    )
    RETURNING * INTO v_row;
  ELSE
    UPDATE data.employee_availability_exceptions x SET
      exception_date = COALESCE(p_exception_date, x.exception_date),
      start_time = CASE
        WHEN p_clear_times THEN NULL
        WHEN p_start_time IS NOT NULL THEN p_start_time
        ELSE x.start_time
      END,
      end_time = CASE
        WHEN p_clear_times THEN NULL
        WHEN p_end_time IS NOT NULL THEN p_end_time
        ELSE x.end_time
      END,
      preference = COALESCE(p_preference, x.preference),
      notes = CASE WHEN p_notes IS NULL THEN x.notes ELSE NULLIF(btrim(p_notes), '') END,
      editable_until = CASE WHEN v_is_manager THEN COALESCE(p_editable_until, x.editable_until) ELSE x.editable_until END,
      is_active = COALESCE(p_is_active, x.is_active),
      updated_at = now()
    WHERE x.id = p_id
    RETURNING * INTO v_row;
  END IF;

  RETURN to_jsonb(v_row);
END;
$$;

CREATE OR REPLACE FUNCTION api.deactivate_employee_availability_exception(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_row data.employee_availability_exceptions;
  v_emp record;
  v_is_manager boolean;
BEGIN
  SELECT * INTO v_row FROM data.employee_availability_exceptions WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exception_not_found' USING ERRCODE = 'P0002';
  END IF;
  SELECT e.* INTO v_emp FROM data.employees e WHERE e.id = v_row.employee_id;

  IF NOT data.can_manage_employee_availability(v_emp.tenant_id, v_emp.site_id, v_emp.id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_is_manager := COALESCE(
    data.jwt_has_permission(v_emp.tenant_id, 'labor_calendar.manage', v_emp.site_id),
    false
  );
  IF NOT v_is_manager AND v_row.editable_until IS NOT NULL AND CURRENT_DATE > v_row.editable_until THEN
    RAISE EXCEPTION 'editable_until_passed' USING ERRCODE = 'check_violation';
  END IF;

  UPDATE data.employee_availability_exceptions
  SET is_active = false, updated_at = now()
  WHERE id = p_id
  RETURNING * INTO v_row;

  RETURN jsonb_build_object('id', v_row.id, 'is_active', false);
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_employee_availability_exceptions(uuid, date, date, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.upsert_employee_availability_exception(uuid, uuid, date, time, time, text, text, date, boolean, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.deactivate_employee_availability_exception(uuid) TO authenticated, service_role;

-- ─── 6. Resolve + llista site ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.resolve_employee_availability(
  p_employee_id uuid,
  p_date        date,
  p_start_time  time DEFAULT NULL,
  p_end_time    time DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp record;
  v_windows jsonb;
  v_pref text;
BEGIN
  SELECT e.id, e.tenant_id, e.site_id, e.full_name INTO v_emp
  FROM data.employees e WHERE e.id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT data.can_view_employee_availability(v_emp.tenant_id, v_emp.site_id, v_emp.id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'start_min', w.start_min,
      'end_min', w.end_min,
      'start', to_char(make_time((LEAST(w.start_min, 1439) / 60)::int, (LEAST(w.start_min, 1439) % 60)::int, 0), 'HH24:MI'),
      'end', CASE
        WHEN w.end_min >= 1440 THEN '24:00'
        ELSE to_char(make_time((w.end_min / 60)::int, (w.end_min % 60)::int, 0), 'HH24:MI')
      END,
      'preference', w.preference,
      'source', w.source,
      'notes', w.notes,
      'source_id', w.source_id
    )
    ORDER BY w.start_min
  ), '[]'::jsonb)
  INTO v_windows
  FROM data.employee_availability_windows(p_employee_id, p_date) w;

  IF p_start_time IS NOT NULL AND p_end_time IS NOT NULL THEN
    v_pref := data.employee_availability_for_window(p_employee_id, p_date, p_start_time, p_end_time);
  ELSE
    v_pref := CASE
      WHEN jsonb_array_length(v_windows) = 0 THEN 'unknown'
      WHEN EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_windows) x WHERE x->>'preference' = 'unavailable'
      ) AND NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_windows) x WHERE x->>'preference' IN ('preferred', 'available')
      ) THEN 'unavailable'
      WHEN EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_windows) x WHERE x->>'preference' = 'preferred'
      ) THEN 'preferred'
      WHEN EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_windows) x WHERE x->>'preference' = 'available'
      ) THEN 'available'
      ELSE 'unknown'
    END;
  END IF;

  RETURN jsonb_build_object(
    'employee_id', v_emp.id,
    'employee_name', v_emp.full_name,
    'date', p_date,
    'preference', v_pref,
    'windows', v_windows,
    'source', CASE
      WHEN jsonb_array_length(v_windows) = 0 THEN 'none'
      ELSE COALESCE(v_windows->0->>'source', 'none')
    END
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.list_site_availability(
  p_site_id     uuid,
  p_date        date,
  p_start_time  time DEFAULT NULL,
  p_end_time    time DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant uuid;
  v_rows jsonb;
BEGIN
  IF p_site_id IS NULL OR p_date IS NULL THEN
    RAISE EXCEPTION 'site_and_date_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT s.tenant_id INTO v_tenant FROM data.sites s WHERE s.id = p_site_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT (
    data.jwt_has_permission(v_tenant, 'labor_calendar.manage', p_site_id)
    OR data.jwt_has_permission(v_tenant, 'labor_calendar.view', p_site_id)
    OR data.jwt_has_permission(v_tenant, 'attendance.view_all', p_site_id)
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'employee_id', e.id,
      'employee_name', e.full_name,
      'preference', CASE
        WHEN p_start_time IS NOT NULL AND p_end_time IS NOT NULL THEN
          data.employee_availability_for_window(e.id, p_date, p_start_time, p_end_time)
        ELSE (api.resolve_employee_availability(e.id, p_date, NULL, NULL)->>'preference')
      END
    )
    ORDER BY e.full_name
  ), '[]'::jsonb)
  INTO v_rows
  FROM data.employees e
  WHERE e.site_id = p_site_id
    AND e.tenant_id = v_tenant
    AND e.status = 'active';

  RETURN jsonb_build_object(
    'site_id', p_site_id,
    'date', p_date,
    'start_time', p_start_time,
    'end_time', p_end_time,
    'employees', v_rows
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.resolve_employee_availability(uuid, date, time, time) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.list_site_availability(uuid, date, time, time) TO authenticated, service_role;

COMMENT ON FUNCTION api.resolve_employee_availability IS
  'EX-07.1: finestres + preferència efectiva d''un empleat per data (excepcions > regles).';
COMMENT ON FUNCTION api.list_site_availability IS
  'EX-07.1: resum de disponibilitat dels empleats actius d''un centre per data/franja.';

NOTIFY pgrst, 'reload schema';
