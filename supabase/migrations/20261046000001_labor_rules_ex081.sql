-- =============================================================================
-- EX-08.1 — Motor de regles laborals (descans / jornada / dies consecutius)
-- Valors configurables per tenant/site; NO són xifres legals universals.
-- Defaults de producte (warn): 11h descans, 12h diàries, 6 dies consecutius.
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.labor_rules (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id       uuid REFERENCES data.sites(id) ON DELETE CASCADE,
  rule_key      text NOT NULL
    CONSTRAINT labor_rules_key_chk CHECK (rule_key IN (
      'min_rest_between_shifts_hours',
      'max_daily_hours',
      'max_consecutive_work_days'
    )),
  value_numeric numeric NOT NULL
    CONSTRAINT labor_rules_value_chk CHECK (value_numeric > 0),
  severity      text NOT NULL DEFAULT 'warn_require_reason'
    CONSTRAINT labor_rules_severity_chk CHECK (
      severity IN ('info', 'warn_require_reason', 'block')
    ),
  is_active     boolean NOT NULL DEFAULT true,
  updated_by    uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- Unicitat: una regla per clau a nivell tenant (site NULL) o site
CREATE UNIQUE INDEX IF NOT EXISTS uq_labor_rules_tenant_key
  ON data.labor_rules (tenant_id, rule_key)
  WHERE site_id IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_labor_rules_site_key
  ON data.labor_rules (tenant_id, site_id, rule_key)
  WHERE site_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_labor_rules_tenant_site
  ON data.labor_rules (tenant_id, site_id);

DROP TRIGGER IF EXISTS trg_updated_at_labor_rules ON data.labor_rules;
CREATE TRIGGER trg_updated_at_labor_rules
  BEFORE UPDATE ON data.labor_rules
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

ALTER TABLE data.labor_rules ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS lr_select ON data.labor_rules;
CREATE POLICY lr_select ON data.labor_rules FOR SELECT
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'labor_calendar.view', site_id)
      OR data.jwt_has_permission(tenant_id, 'labor_calendar.manage', site_id)
      OR data.jwt_has_permission(tenant_id, 'attendance.view_all', site_id)
    )
  );

DROP POLICY IF EXISTS lr_write ON data.labor_rules;
CREATE POLICY lr_write ON data.labor_rules FOR ALL
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage', site_id)
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage', site_id)
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON data.labor_rules TO authenticated, service_role;

COMMENT ON TABLE data.labor_rules IS
  'EX-08.1: regles laborals configurables (tenant/site). Defaults de producte, no norma legal fixa.';

-- Vista API
DROP VIEW IF EXISTS api.labor_rules CASCADE;
CREATE VIEW api.labor_rules
  WITH (security_invoker = true)
AS
SELECT
  id, tenant_id, site_id, rule_key, value_numeric, severity, is_active,
  updated_by, created_at, updated_at
FROM data.labor_rules;

GRANT SELECT ON api.labor_rules TO authenticated, service_role;

-- ─── Defaults de producte (no legals) ────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.labor_rule_product_defaults()
RETURNS TABLE (rule_key text, value_numeric numeric, severity text)
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT * FROM (VALUES
    ('min_rest_between_shifts_hours'::text, 11::numeric, 'warn_require_reason'::text),
    ('max_daily_hours', 12::numeric, 'warn_require_reason'),
    ('max_consecutive_work_days', 6::numeric, 'warn_require_reason')
  ) AS d(rule_key, value_numeric, severity);
$$;

-- ─── Resolve regla efectiva ──────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.resolve_labor_rule(
  p_tenant_id uuid,
  p_site_id   uuid,
  p_rule_key  text
)
RETURNS TABLE (value_numeric numeric, severity text, source text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_row record;
BEGIN
  IF p_site_id IS NOT NULL THEN
    SELECT r.value_numeric, r.severity INTO v_row
    FROM data.labor_rules r
    WHERE r.tenant_id = p_tenant_id
      AND r.site_id = p_site_id
      AND r.rule_key = p_rule_key
      AND r.is_active = true
    LIMIT 1;
    IF FOUND THEN
      value_numeric := v_row.value_numeric;
      severity := v_row.severity;
      source := 'site';
      RETURN NEXT;
      RETURN;
    END IF;
  END IF;

  SELECT r.value_numeric, r.severity INTO v_row
  FROM data.labor_rules r
  WHERE r.tenant_id = p_tenant_id
    AND r.site_id IS NULL
    AND r.rule_key = p_rule_key
    AND r.is_active = true
  LIMIT 1;
  IF FOUND THEN
    value_numeric := v_row.value_numeric;
    severity := v_row.severity;
    source := 'tenant';
    RETURN NEXT;
    RETURN;
  END IF;

  SELECT d.value_numeric, d.severity INTO v_row
  FROM data.labor_rule_product_defaults() d
  WHERE d.rule_key = p_rule_key
  LIMIT 1;
  IF FOUND THEN
    value_numeric := v_row.value_numeric;
    severity := v_row.severity;
    source := 'product_default';
    RETURN NEXT;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION data.resolve_labor_rule(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.resolve_labor_rule(uuid, uuid, text) TO authenticated, service_role;

-- ─── Helpers temps (reutilitza shift_slot_*_ts existents; afegeix duration) ───

CREATE OR REPLACE FUNCTION data.shift_slot_duration_hours(p_start time, p_end time)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT ROUND((EXTRACT(EPOCH FROM CASE
    WHEN p_end > p_start THEN p_end - p_start
    ELSE interval '24 hours' + (p_end - p_start)
  END) / 3600.0)::numeric, 2);
$$;

-- ─── Evaluate per franja ─────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.evaluate_labor_rules_for_window(
  p_employee_id uuid,
  p_site_id     uuid,
  p_slot_date   date,
  p_start_time  time,
  p_end_time    time,
  p_exclude_slot_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant uuid;
  v_issues jsonb := '[]'::jsonb;
  v_rule record;
  v_prev record;
  v_gap_h numeric;
  v_day_h numeric;
  v_consec int;
  v_start_ts timestamp;
  v_d date;
  v_has boolean;
BEGIN
  SELECT e.tenant_id INTO v_tenant FROM data.employees e WHERE e.id = p_employee_id;
  IF v_tenant IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'issues', '[]'::jsonb);
  END IF;

  v_start_ts := data.shift_slot_start_ts(p_slot_date, p_start_time);

  -- 1) Descans mínim entre torns
  SELECT * INTO v_rule FROM data.resolve_labor_rule(v_tenant, p_site_id, 'min_rest_between_shifts_hours');
  IF FOUND THEN
    SELECT ss.id, ss.slot_date, ss.start_time, ss.end_time,
           data.shift_slot_end_ts(ss.slot_date, ss.start_time, ss.end_time) AS end_ts
    INTO v_prev
    FROM data.shift_slots ss
    WHERE ss.employee_id = p_employee_id
      AND ss.status <> 'cancelled'
      AND (p_exclude_slot_id IS NULL OR ss.id <> p_exclude_slot_id)
      AND data.shift_slot_end_ts(ss.slot_date, ss.start_time, ss.end_time) <= v_start_ts
      AND ss.slot_date BETWEEN p_slot_date - 3 AND p_slot_date
    ORDER BY data.shift_slot_end_ts(ss.slot_date, ss.start_time, ss.end_time) DESC
    LIMIT 1;

    IF FOUND THEN
      v_gap_h := ROUND((EXTRACT(EPOCH FROM (v_start_ts - v_prev.end_ts)) / 3600.0)::numeric, 2);
      IF v_gap_h < v_rule.value_numeric THEN
        v_issues := v_issues || jsonb_build_array(jsonb_build_object(
          'code', 'MIN_REST_BETWEEN_SHIFTS',
          'severity', v_rule.severity,
          'rule_key', 'min_rest_between_shifts_hours',
          'required_hours', v_rule.value_numeric,
          'actual_hours', v_gap_h,
          'employee_id', p_employee_id,
          'work_date', p_slot_date,
          'previous_slot_id', v_prev.id,
          'message', format('Descans insuficient: %s h (mínim %s h)', v_gap_h, v_rule.value_numeric)
        ));
      END IF;
    END IF;
  END IF;

  -- 2) Màxim hores diàries
  SELECT * INTO v_rule FROM data.resolve_labor_rule(v_tenant, p_site_id, 'max_daily_hours');
  IF FOUND THEN
    SELECT COALESCE(SUM(data.shift_slot_duration_hours(ss.start_time, ss.end_time)), 0)
    INTO v_day_h
    FROM data.shift_slots ss
    WHERE ss.employee_id = p_employee_id
      AND ss.slot_date = p_slot_date
      AND ss.status <> 'cancelled'
      AND (p_exclude_slot_id IS NULL OR ss.id <> p_exclude_slot_id);

    v_day_h := v_day_h + data.shift_slot_duration_hours(p_start_time, p_end_time);

    IF v_day_h > v_rule.value_numeric THEN
      v_issues := v_issues || jsonb_build_array(jsonb_build_object(
        'code', 'MAX_DAILY_HOURS',
        'severity', v_rule.severity,
        'rule_key', 'max_daily_hours',
        'required_hours', v_rule.value_numeric,
        'actual_hours', v_day_h,
        'employee_id', p_employee_id,
        'work_date', p_slot_date,
        'message', format('Jornada diària %s h (màxim %s h)', v_day_h, v_rule.value_numeric)
      ));
    END IF;
  END IF;

  -- 3) Dies consecutius amb treball
  SELECT * INTO v_rule FROM data.resolve_labor_rule(v_tenant, p_site_id, 'max_consecutive_work_days');
  IF FOUND THEN
    v_consec := 1; -- el dia candidat
    -- cap enrere
    v_d := p_slot_date - 1;
    LOOP
      SELECT EXISTS (
        SELECT 1 FROM data.shift_slots ss
        WHERE ss.employee_id = p_employee_id
          AND ss.slot_date = v_d
          AND ss.status <> 'cancelled'
          AND (p_exclude_slot_id IS NULL OR ss.id <> p_exclude_slot_id)
      ) INTO v_has;
      EXIT WHEN NOT v_has;
      v_consec := v_consec + 1;
      v_d := v_d - 1;
      EXIT WHEN v_consec > (v_rule.value_numeric::int + 2);
    END LOOP;
    -- cap endavant (dies ja planificats després)
    v_d := p_slot_date + 1;
    LOOP
      SELECT EXISTS (
        SELECT 1 FROM data.shift_slots ss
        WHERE ss.employee_id = p_employee_id
          AND ss.slot_date = v_d
          AND ss.status <> 'cancelled'
          AND (p_exclude_slot_id IS NULL OR ss.id <> p_exclude_slot_id)
      ) INTO v_has;
      EXIT WHEN NOT v_has;
      v_consec := v_consec + 1;
      v_d := v_d + 1;
      EXIT WHEN v_consec > (v_rule.value_numeric::int + 2);
    END LOOP;

    IF v_consec > v_rule.value_numeric THEN
      v_issues := v_issues || jsonb_build_array(jsonb_build_object(
        'code', 'MAX_CONSECUTIVE_WORK_DAYS',
        'severity', v_rule.severity,
        'rule_key', 'max_consecutive_work_days',
        'required_days', v_rule.value_numeric,
        'actual_days', v_consec,
        'employee_id', p_employee_id,
        'work_date', p_slot_date,
        'message', format('%s dies consecutius (màxim %s)', v_consec, v_rule.value_numeric)
      ));
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_issues) i WHERE i->>'severity' = 'block'
    ),
    'issues', v_issues
  );
END;
$$;

REVOKE ALL ON FUNCTION data.evaluate_labor_rules_for_window(uuid, uuid, date, time, time, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.evaluate_labor_rules_for_window(uuid, uuid, date, time, time, uuid)
  TO authenticated, service_role;

-- ─── CRUD RPCs ───────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.list_labor_rules(
  p_site_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant uuid;
  v_items jsonb;
BEGIN
  v_tenant := data.active_tenant_id();
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT (
    COALESCE(data.jwt_has_permission(v_tenant, 'labor_calendar.view', p_site_id), false)
    OR COALESCE(data.jwt_has_permission(v_tenant, 'labor_calendar.manage', p_site_id), false)
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.rule_key, x.site_id NULLS FIRST), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT
      r.id, r.tenant_id, r.site_id, r.rule_key, r.value_numeric, r.severity, r.is_active,
      r.created_at, r.updated_at,
      'configured'::text AS source
    FROM data.labor_rules r
    WHERE r.tenant_id = v_tenant
      AND (p_site_id IS NULL OR r.site_id IS NULL OR r.site_id = p_site_id)
    UNION ALL
    SELECT
      NULL::uuid, v_tenant, NULL::uuid, d.rule_key, d.value_numeric, d.severity, true,
      NULL::timestamptz, NULL::timestamptz,
      'product_default'::text
    FROM data.labor_rule_product_defaults() d
    WHERE NOT EXISTS (
      SELECT 1 FROM data.labor_rules r
      WHERE r.tenant_id = v_tenant AND r.site_id IS NULL AND r.rule_key = d.rule_key
    )
    AND p_site_id IS NULL
  ) x;

  RETURN jsonb_build_object(
    'tenant_id', v_tenant,
    'site_id', p_site_id,
    'rules', COALESCE(v_items, '[]'::jsonb)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_labor_rules(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.upsert_labor_rule(
  p_rule_key      text,
  p_value_numeric numeric,
  p_severity       text DEFAULT 'warn_require_reason',
  p_site_id       uuid DEFAULT NULL,
  p_is_active     boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant uuid;
  v_row data.labor_rules;
BEGIN
  v_tenant := data.active_tenant_id();
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT COALESCE(data.jwt_has_permission(v_tenant, 'labor_calendar.manage', p_site_id), false) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_rule_key NOT IN (
    'min_rest_between_shifts_hours', 'max_daily_hours', 'max_consecutive_work_days'
  ) THEN
    RAISE EXCEPTION 'invalid_rule_key' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_severity NOT IN ('info', 'warn_require_reason', 'block') THEN
    RAISE EXCEPTION 'invalid_severity' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_value_numeric IS NULL OR p_value_numeric <= 0 THEN
    RAISE EXCEPTION 'invalid_value' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_site_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM data.sites s WHERE s.id = p_site_id AND s.tenant_id = v_tenant
  ) THEN
    RAISE EXCEPTION 'site_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF p_site_id IS NULL THEN
    UPDATE data.labor_rules
    SET value_numeric = p_value_numeric,
        severity = p_severity,
        is_active = COALESCE(p_is_active, true),
        updated_by = auth.uid(),
        updated_at = now()
    WHERE tenant_id = v_tenant AND site_id IS NULL AND rule_key = p_rule_key
    RETURNING * INTO v_row;

    IF NOT FOUND THEN
      INSERT INTO data.labor_rules (tenant_id, site_id, rule_key, value_numeric, severity, is_active, updated_by)
      VALUES (v_tenant, NULL, p_rule_key, p_value_numeric, p_severity, COALESCE(p_is_active, true), auth.uid())
      RETURNING * INTO v_row;
    END IF;
  ELSE
    UPDATE data.labor_rules
    SET value_numeric = p_value_numeric,
        severity = p_severity,
        is_active = COALESCE(p_is_active, true),
        updated_by = auth.uid(),
        updated_at = now()
    WHERE tenant_id = v_tenant AND site_id = p_site_id AND rule_key = p_rule_key
    RETURNING * INTO v_row;

    IF NOT FOUND THEN
      INSERT INTO data.labor_rules (tenant_id, site_id, rule_key, value_numeric, severity, is_active, updated_by)
      VALUES (v_tenant, p_site_id, p_rule_key, p_value_numeric, p_severity, COALESCE(p_is_active, true), auth.uid())
      RETURNING * INTO v_row;
    END IF;
  END IF;

  RETURN to_jsonb(v_row);
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_labor_rule(text, numeric, text, uuid, boolean)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.evaluate_labor_rules_for_window(
  p_employee_id uuid,
  p_site_id uuid,
  p_slot_date date,
  p_start_time time,
  p_end_time time,
  p_exclude_slot_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant uuid;
BEGIN
  SELECT e.tenant_id INTO v_tenant FROM data.employees e WHERE e.id = p_employee_id;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT (
    COALESCE(data.jwt_has_permission(v_tenant, 'labor_calendar.view', p_site_id), false)
    OR COALESCE(data.jwt_has_permission(v_tenant, 'labor_calendar.manage', p_site_id), false)
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN data.evaluate_labor_rules_for_window(
    p_employee_id, p_site_id, p_slot_date, p_start_time, p_end_time, p_exclude_slot_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.evaluate_labor_rules_for_window(uuid, uuid, date, time, time, uuid)
  TO authenticated, service_role;

-- ─── Integrar a evaluate_opening_claim_eligibility ───────────────────────────

CREATE OR REPLACE FUNCTION data.evaluate_opening_claim_eligibility(
  p_opening_id  uuid,
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_opening data.shift_openings;
  v_emp record;
  v_blocks text[] := '{}';
  v_warnings text[] := '{}';
  v_avail text;
  v_week_start date;
  v_shift_min int;
  v_week_min int;
  v_labor jsonb;
  v_issue jsonb;
BEGIN
  SELECT * INTO v_opening FROM data.shift_openings WHERE id = p_opening_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'blocks', jsonb_build_array('opening_not_found'), 'warnings', '[]'::jsonb);
  END IF;

  SELECT e.id, e.tenant_id, e.site_id, e.status, e.weekly_hours, e.full_name
  INTO v_emp
  FROM data.employees e WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    v_blocks := array_append(v_blocks, 'employee_not_found');
  ELSIF v_emp.status <> 'active' THEN
    v_blocks := array_append(v_blocks, 'employee_not_active');
  ELSIF v_emp.site_id IS DISTINCT FROM v_opening.site_id THEN
    v_blocks := array_append(v_blocks, 'employee_wrong_site');
  END IF;

  IF v_opening.status <> 'open' THEN
    v_blocks := array_append(v_blocks, 'opening_not_open');
  END IF;

  IF v_opening.places_filled >= v_opening.places_total THEN
    v_blocks := array_append(v_blocks, 'opening_full');
  END IF;

  IF v_opening.opens_at IS NOT NULL AND v_opening.opens_at > clock_timestamp() THEN
    v_blocks := array_append(v_blocks, 'opening_not_yet_open');
  END IF;

  IF v_opening.closes_at IS NOT NULL AND v_opening.closes_at < clock_timestamp() THEN
    v_blocks := array_append(v_blocks, 'opening_closed');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM data.employee_absences ea
    WHERE ea.employee_id = p_employee_id
      AND ea.status IN ('approved', 'active', 'closed')
      AND ea.start_date <= v_opening.opening_date
      AND COALESCE(ea.end_date, ea.start_date) >= v_opening.opening_date
  ) THEN
    v_blocks := array_append(v_blocks, 'employee_on_absence');
  END IF;

  IF v_opening.role_id IS NOT NULL AND v_emp.id IS NOT NULL THEN
    IF NOT data.employee_meets_role_qualifications(p_employee_id, v_opening.role_id, v_opening.opening_date) THEN
      v_blocks := array_append(v_blocks, 'role_qualifications_unmet');
    END IF;
  END IF;

  IF v_emp.id IS NOT NULL AND EXISTS (
    SELECT 1
    FROM data.shift_slots ss
    WHERE ss.employee_id = p_employee_id
      AND ss.status <> 'cancelled'
      AND ss.slot_date BETWEEN v_opening.opening_date - 1 AND v_opening.opening_date + 1
      AND data.shift_slots_overlap(
        v_opening.opening_date, v_opening.start_time, v_opening.end_time,
        ss.slot_date, ss.start_time, ss.end_time
      )
  ) THEN
    v_blocks := array_append(v_blocks, 'SHIFT_OVERLAP');
  END IF;

  IF v_emp.id IS NOT NULL THEN
    v_avail := data.employee_availability_for_window(
      p_employee_id, v_opening.opening_date, v_opening.start_time, v_opening.end_time
    );
    IF v_avail = 'unavailable' THEN
      v_blocks := array_append(v_blocks, 'availability_unavailable');
    ELSIF v_avail = 'unknown' THEN
      v_warnings := array_append(v_warnings, 'availability_unknown');
    END IF;
  END IF;

  IF v_emp.id IS NOT NULL THEN
    v_week_start := date_trunc('week', v_opening.opening_date::timestamptz)::date;
    v_shift_min := ROUND(EXTRACT(EPOCH FROM CASE
      WHEN v_opening.end_time > v_opening.start_time THEN v_opening.end_time - v_opening.start_time
      ELSE interval '24 hours' + (v_opening.end_time - v_opening.start_time)
    END) / 60)::int;

    SELECT COALESCE(SUM(ROUND(EXTRACT(EPOCH FROM CASE
      WHEN ss.end_time > ss.start_time THEN ss.end_time - ss.start_time
      ELSE interval '24 hours' + (ss.end_time - ss.start_time)
    END) / 60)), 0)::int
    INTO v_week_min
    FROM data.shift_slots ss
    WHERE ss.employee_id = p_employee_id
      AND ss.slot_date >= v_week_start
      AND ss.slot_date <= v_week_start + 6
      AND ss.status <> 'cancelled';

    IF v_emp.weekly_hours IS NOT NULL
       AND (v_week_min + v_shift_min) > (v_emp.weekly_hours * 60)
    THEN
      v_warnings := array_append(v_warnings, 'WEEKLY_HOURS_EXCEEDED');
    END IF;
  END IF;

  -- EX-08.1 labor rules
  IF v_emp.id IS NOT NULL THEN
    v_labor := data.evaluate_labor_rules_for_window(
      p_employee_id, v_opening.site_id, v_opening.opening_date,
      v_opening.start_time, v_opening.end_time, NULL
    );
    FOR v_issue IN SELECT * FROM jsonb_array_elements(COALESCE(v_labor->'issues', '[]'::jsonb))
    LOOP
      IF v_issue->>'severity' = 'block' THEN
        v_blocks := array_append(v_blocks, v_issue->>'code');
      ELSE
        v_warnings := array_append(v_warnings, v_issue->>'code');
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'ok', cardinality(v_blocks) = 0,
    'blocks', to_jsonb(v_blocks),
    'warnings', to_jsonb(v_warnings),
    'availability', v_avail,
    'labor', v_labor,
    'opening_id', p_opening_id,
    'employee_id', p_employee_id
  );
END;
$$;

-- ─── Preflight: EX-04.3 + labor rules EX-08.1 ────────────────────────────────

CREATE OR REPLACE FUNCTION api.preflight_publish_shifts(
  p_site_id    uuid,
  p_week_start date
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid;
  v_week_end date;
  v_draft_count int := 0;
  v_blockers jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_pairs jsonb := '[]'::jsonb;
  v_closed jsonb;
  v_affected uuid[] := ARRAY[]::uuid[];
  v_slot record;
  v_plan jsonb;
  v_labor_day text;
  v_day_type text;
  v_other record;
  v_week_min numeric;
  v_slot_min numeric;
  v_weekly_hours numeric;
  v_cov record;
  v_emp_ids uuid[];
  v_labor jsonb;
  v_issue jsonb;
BEGIN
  IF EXTRACT(DOW FROM p_week_start)::int <> 1 THEN
    RAISE EXCEPTION 'invalid_week_start: p_week_start ha de ser dilluns'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT s.tenant_id INTO v_tenant_id FROM data.sites s WHERE s.id = p_site_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_not_found: %', p_site_id USING ERRCODE = 'P0002';
  END IF;

  IF NOT COALESCE(data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage', p_site_id), false) THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_week_end := p_week_start + 6;

  SELECT count(*)::int,
         coalesce(array_agg(DISTINCT ss.employee_id), ARRAY[]::uuid[])
  INTO v_draft_count, v_emp_ids
  FROM data.shift_slots ss
  WHERE ss.site_id = p_site_id
    AND ss.slot_date BETWEEN p_week_start AND v_week_end
    AND ss.status = 'draft';

  v_affected := coalesce(v_emp_ids, ARRAY[]::uuid[]);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'employee_id', ss.employee_id,
    'work_date', ss.slot_date
  )), '[]'::jsonb)
  INTO v_pairs
  FROM data.shift_slots ss
  WHERE ss.site_id = p_site_id
    AND ss.slot_date BETWEEN p_week_start AND v_week_end
    AND ss.status = 'draft';

  v_closed := data.shift_closed_period_issues(v_pairs);
  IF jsonb_array_length(v_closed) > 0 THEN
    v_blockers := v_blockers || v_closed;
  END IF;

  FOR v_slot IN
    SELECT ss.id, ss.employee_id, ss.slot_date, ss.start_time, ss.end_time, ss.site_id
    FROM data.shift_slots ss
    WHERE ss.site_id = p_site_id
      AND ss.slot_date BETWEEN p_week_start AND v_week_end
      AND ss.status = 'draft'
    ORDER BY ss.slot_date, ss.start_time, ss.id
  LOOP
    SELECT ss2.id, ss2.slot_date, ss2.start_time, ss2.end_time
    INTO v_other
    FROM data.shift_slots ss2
    WHERE ss2.employee_id = v_slot.employee_id
      AND ss2.id <> v_slot.id
      AND ss2.status <> 'cancelled'
      AND ss2.slot_date BETWEEN v_slot.slot_date - 1 AND v_slot.slot_date + 1
      AND data.shift_slots_overlap(
        v_slot.slot_date, v_slot.start_time, v_slot.end_time,
        ss2.slot_date, ss2.start_time, ss2.end_time
      )
    LIMIT 1;

    IF FOUND THEN
      v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
        'code', 'SHIFT_OVERLAP',
        'severity', 'warn_require_reason',
        'employee_id', v_slot.employee_id,
        'work_date', v_slot.slot_date,
        'slot_id', v_slot.id,
        'message', 'Solapament amb un altre torn'
      ));
    END IF;

    SELECT e.weekly_hours INTO v_weekly_hours
    FROM data.employees e WHERE e.id = v_slot.employee_id;

    v_slot_min := ROUND(EXTRACT(EPOCH FROM CASE
      WHEN v_slot.end_time > v_slot.start_time THEN v_slot.end_time - v_slot.start_time
      ELSE interval '24 hours' + (v_slot.end_time - v_slot.start_time)
    END) / 60);

    SELECT COALESCE(SUM(ROUND(EXTRACT(EPOCH FROM CASE
      WHEN ss2.end_time > ss2.start_time THEN ss2.end_time - ss2.start_time
      ELSE interval '24 hours' + (ss2.end_time - ss2.start_time)
    END) / 60)), 0)
    INTO v_week_min
    FROM data.shift_slots ss2
    WHERE ss2.employee_id = v_slot.employee_id
      AND ss2.slot_date BETWEEN p_week_start AND v_week_end
      AND ss2.status <> 'cancelled';

    IF v_weekly_hours IS NOT NULL AND v_week_min > (v_weekly_hours * 60) THEN
      v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
        'code', 'WEEKLY_HOURS_EXCEEDED',
        'severity', 'warn_require_reason',
        'employee_id', v_slot.employee_id,
        'work_date', v_slot.slot_date,
        'slot_id', v_slot.id,
        'message', format('Hores setmanals superades (%s min / %s h)', round(v_week_min)::int, v_weekly_hours)
      ));
    END IF;

    v_plan := data.resolve_employee_work_plan(v_slot.employee_id, v_slot.slot_date);
    v_labor_day := v_plan->>'labor_day_type';
    v_day_type := v_plan->>'day_type';

    IF COALESCE(v_labor_day, '') IN ('holiday', 'vacation', 'leave')
       OR COALESCE(v_day_type, '') IN ('holiday', 'half_holiday', 'non_working', 'absence')
    THEN
      IF COALESCE(v_day_type, '') <> 'absence'
         AND COALESCE(v_labor_day, '') IN ('holiday', 'vacation', 'leave') THEN
        v_blockers := v_blockers || jsonb_build_array(jsonb_build_object(
          'code', 'NON_WORK_DAY',
          'severity', 'block',
          'employee_id', v_slot.employee_id,
          'work_date', v_slot.slot_date,
          'slot_id', v_slot.id,
          'labor_day_type', v_labor_day,
          'message', 'Cal override laboral (work) abans de publicar un torn en festiu/vacances/leave'
        ));
      END IF;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM data.employee_absences ea
      WHERE ea.employee_id = v_slot.employee_id
        AND ea.status IN ('approved', 'active', 'closed')
        AND ea.start_date <= v_slot.slot_date
        AND COALESCE(ea.end_date, '9999-12-31'::date) >= v_slot.slot_date
    ) THEN
      v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
        'code', 'APPROVED_ABSENCE',
        'severity', 'warn_require_reason',
        'employee_id', v_slot.employee_id,
        'work_date', v_slot.slot_date,
        'slot_id', v_slot.id,
        'message', 'Hi ha una absència aprovada/activa aquest dia'
      ));
    END IF;

    -- EX-08.1 labor rules
    v_labor := data.evaluate_labor_rules_for_window(
      v_slot.employee_id, v_slot.site_id, v_slot.slot_date,
      v_slot.start_time, v_slot.end_time, v_slot.id
    );
    FOR v_issue IN SELECT * FROM jsonb_array_elements(COALESCE(v_labor->'issues', '[]'::jsonb))
    LOOP
      IF v_issue->>'severity' = 'block' THEN
        v_blockers := v_blockers || jsonb_build_array(v_issue || jsonb_build_object('slot_id', v_slot.id));
      ELSE
        v_warnings := v_warnings || jsonb_build_array(v_issue || jsonb_build_object('slot_id', v_slot.id));
      END IF;
    END LOOP;
  END LOOP;

  FOR v_cov IN
    SELECT *
    FROM jsonb_array_elements(
      COALESCE(api.get_coverage_for_period(p_site_id, p_week_start, v_week_end), '[]'::jsonb)
    ) AS x(day)
  LOOP
    IF COALESCE((v_cov.day->>'coverage_delta')::int, 0) < 0 THEN
      v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
        'code', 'COVERAGE_SHORTAGE',
        'severity', 'warn',
        'work_date', v_cov.day->>'work_date',
        'coverage_delta', (v_cov.day->>'coverage_delta')::int,
        'message', format(
          'Cobertura insuficient: %s/%s',
          v_cov.day->>'employee_count',
          v_cov.day->>'required_employee_count'
        )
      ));
    END IF;
  END LOOP;

  SELECT COALESCE(jsonb_agg(DISTINCT w), '[]'::jsonb)
  INTO v_warnings
  FROM jsonb_array_elements(v_warnings) AS w;

  SELECT COALESCE(jsonb_agg(DISTINCT b), '[]'::jsonb)
  INTO v_blockers
  FROM jsonb_array_elements(v_blockers) AS b;

  RETURN jsonb_build_object(
    'site_id', p_site_id,
    'week_start', p_week_start,
    'week_end', v_week_end,
    'draft_count', v_draft_count,
    'can_publish', jsonb_array_length(COALESCE(v_blockers, '[]'::jsonb)) = 0 AND v_draft_count > 0,
    'blockers', COALESCE(v_blockers, '[]'::jsonb),
    'warnings', COALESCE(v_warnings, '[]'::jsonb),
    'affected_employee_ids', to_jsonb(v_affected),
    'required_warning_codes', (
      SELECT COALESCE(jsonb_agg(DISTINCT w->>'code'), '[]'::jsonb)
      FROM jsonb_array_elements(COALESCE(v_warnings, '[]'::jsonb)) w
      WHERE w->>'severity' = 'warn_require_reason'
    )
  );
END;
$$;

COMMENT ON FUNCTION api.preflight_publish_shifts(uuid, date) IS
  'EX-04.3 + EX-08.1: validació prèvia a publish_shifts (blockers + warnings + labor rules).';

GRANT EXECUTE ON FUNCTION api.preflight_publish_shifts(uuid, date) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
