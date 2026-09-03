-- Track G Phase 1: attendance record policies, work profiles, statutory settings
-- PRD: docs/plans/checkin/plan-effective-work-time.md v4.3
-- Prompt: docs/plans/checkin/prompt-track-g-phase-1.md

-- ─── 1. Schema ───────────────────────────────────────────────────────────────

ALTER TABLE data.employees
  ADD COLUMN IF NOT EXISTS attendance_work_profile text
  CHECK (
    attendance_work_profile IS NULL
    OR attendance_work_profile IN (
      'fixed_site', 'mobile_peripatetic', 'hybrid', 'delivery'
    )
  );

COMMENT ON COLUMN data.employees.attendance_work_profile IS
  'Override perfil de jornada Track G. NULL = hereta política del grup/conveni.';

CREATE TABLE IF NOT EXISTS data.attendance_record_policies (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  scope             text NOT NULL CHECK (scope IN (
    'system', 'tenant', 'group', 'group_site', 'site', 'employee'
  )),
  calendar_group_id uuid REFERENCES data.calendar_groups(id) ON DELETE CASCADE,
  site_id           uuid REFERENCES data.sites(id) ON DELETE CASCADE,
  employee_id       uuid REFERENCES data.employees(id) ON DELETE CASCADE,
  effective_from    date NOT NULL DEFAULT CURRENT_DATE,
  effective_to        date,
  policy              jsonb NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  created_by          uuid REFERENCES auth.users(id),
  CONSTRAINT arp_effective_range CHECK (
    effective_to IS NULL OR effective_to >= effective_from
  ),
  CONSTRAINT arp_scope_fks CHECK (
    (scope = 'system' AND calendar_group_id IS NULL AND site_id IS NULL AND employee_id IS NULL)
    OR (scope = 'tenant' AND calendar_group_id IS NULL AND site_id IS NULL AND employee_id IS NULL)
    OR (scope = 'group' AND calendar_group_id IS NOT NULL AND site_id IS NULL AND employee_id IS NULL)
    OR (scope = 'group_site' AND calendar_group_id IS NOT NULL AND site_id IS NOT NULL AND employee_id IS NULL)
    OR (scope = 'site' AND site_id IS NOT NULL AND calendar_group_id IS NULL AND employee_id IS NULL)
    OR (scope = 'employee' AND employee_id IS NOT NULL AND calendar_group_id IS NULL AND site_id IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_arp_tenant_scope
  ON data.attendance_record_policies (tenant_id, scope, effective_from DESC);

CREATE INDEX IF NOT EXISTS idx_arp_group
  ON data.attendance_record_policies (calendar_group_id, effective_from DESC)
  WHERE calendar_group_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_arp_employee
  ON data.attendance_record_policies (employee_id, effective_from DESC)
  WHERE employee_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_arp_one_system_per_tenant
  ON data.attendance_record_policies (tenant_id)
  WHERE scope = 'system';

DROP TRIGGER IF EXISTS trg_set_updated_at_attendance_record_policies
  ON data.attendance_record_policies;
CREATE TRIGGER trg_set_updated_at_attendance_record_policies
  BEFORE UPDATE ON data.attendance_record_policies
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

COMMENT ON TABLE data.attendance_record_policies IS
  'Polítiques de registre horari / conveni (Track G). Versionades per effective_from/to. '
  'scope=system: una fila seed per tenant (defaults plataforma).';

ALTER TABLE data.attendance_record_policies ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "arp: tenant read" ON data.attendance_record_policies;
CREATE POLICY "arp: tenant read"
  ON data.attendance_record_policies FOR SELECT TO authenticated
  USING (
    tenant_id IN (
      SELECT (jsonb_array_elements_text(data.jwt_user_tenants()))::uuid
    )
  );

DROP POLICY IF EXISTS "arp: manage" ON data.attendance_record_policies;
CREATE POLICY "arp: manage"
  ON data.attendance_record_policies FOR ALL TO authenticated
  USING (data.jwt_has_permission(tenant_id, 'attendance.manage'))
  WITH CHECK (data.jwt_has_permission(tenant_id, 'attendance.manage'));

GRANT SELECT ON data.attendance_record_policies TO authenticated;
GRANT ALL ON data.attendance_record_policies TO service_role;

-- ─── 2. Policy factory + validation ─────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.default_attendance_record_policy(
  p_work_profile text DEFAULT 'fixed_site'
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_profile text := COALESCE(NULLIF(p_work_profile, ''), 'fixed_site');
  v_jornada text;
  v_budget  int;
  v_travel_paid boolean;
  v_travel_effective boolean;
BEGIN
  IF v_profile NOT IN ('fixed_site', 'mobile_peripatetic', 'hybrid', 'delivery') THEN
    v_profile := 'fixed_site';
  END IF;

  IF v_profile = 'mobile_peripatetic' THEN
    v_jornada := 'time_budget';
    v_budget := 480;
    v_travel_paid := true;
    v_travel_effective := false;
  ELSE
    v_jornada := 'schedule_intersection';
    v_budget := NULL;
    v_travel_paid := false;
    v_travel_effective := false;
  END IF;

  RETURN jsonb_build_object(
    'version', 2,
    'work_profile', v_profile,
    'jornada_model', v_jornada,
    'daily_work_budget_minutes', v_budget,
    'activities', jsonb_build_object(
      'WORK', jsonb_build_object(
        'counts_presence', true, 'counts_net_work', true,
        'counts_effective', true, 'counts_paid', true,
        'counts_overtime_base', true, 'counts_annual_work_limit', true,
        'counts_comp_time_accrual', true
      ),
      'TRAVEL', jsonb_build_object(
        'counts_presence', true, 'counts_net_work', false,
        'counts_effective', v_travel_effective, 'counts_paid', v_travel_paid,
        'counts_overtime_base', false, 'counts_annual_work_limit', false,
        'include_home_to_first', v_profile = 'mobile_peripatetic',
        'include_last_to_home', v_profile = 'mobile_peripatetic',
        'include_between_sites', v_profile = 'mobile_peripatetic'
      ),
      'BREAK_UNPAID', jsonb_build_object(
        'counts_presence', true, 'counts_net_work', false,
        'counts_effective', false, 'counts_paid', false
      ),
      'BREAK_PAID', jsonb_build_object(
        'counts_presence', true, 'counts_net_work', true,
        'counts_effective', true, 'counts_paid', true
      ),
      'OFF_DUTY', jsonb_build_object('counts_presence', false, 'counts_paid', false),
      'STANDBY', jsonb_build_object(
        'counts_presence', true, 'counts_paid', true, 'counts_effective', false
      )
    ),
    'depot_rule', jsonb_build_object(
      'required', false, 'site_id', null, 'jornada_starts_at_depot', false
    ),
    'courtesy', jsonb_build_object(
      'early_arrival_minutes', 15,
      'late_arrival_grace_minutes', 5,
      'early_departure_minutes', 15,
      'late_departure_minutes', 15,
      'overflow_early', 'needs_review',
      'apply_to_activity_kinds', jsonb_build_array('WORK')
    ),
    'rounding', jsonb_build_object(
      'mode', 'quarter_hour',
      'direction', 'favor_employee',
      'apply_to_punch_types', jsonb_build_array('in', 'out', 'day_start', 'day_end'),
      'apply_to_activity_kinds', jsonb_build_array('WORK'),
      'never_reduce_paid_below_net', true,
      'asymmetric', jsonb_build_object(
        'in_never_after_real', true,
        'out_never_before_real', true,
        'late_arrival', 'down_to_expected_or_quarter',
        'early_departure', 'exact_or_down'
      )
    ),
    'overtime', jsonb_build_object(
      'allowed', true,
      'requires_prior_authorization', true,
      'overtime_base', 'paid_minutes',
      'max_annual_minutes_convenio', 1800,
      'compensation_mode', 'time_off_or_payroll'
    ),
    'annual_limits', jsonb_build_object('max_work_minutes_convenio', 112800)
  );
END;
$$;

CREATE OR REPLACE FUNCTION data.validate_attendance_record_policy(p_policy jsonb)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_version int;
  v_profile text;
  v_jornada text;
BEGIN
  IF p_policy IS NULL OR jsonb_typeof(p_policy) <> 'object' THEN
    RAISE EXCEPTION 'invalid_policy: must be json object';
  END IF;

  v_version := (p_policy->>'version')::int;
  IF v_version IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'invalid_policy: version must be 2';
  END IF;

  v_profile := p_policy->>'work_profile';
  IF v_profile IS NULL OR v_profile NOT IN (
    'fixed_site', 'mobile_peripatetic', 'hybrid', 'delivery'
  ) THEN
    RAISE EXCEPTION 'invalid_policy: work_profile invalid';
  END IF;

  v_jornada := p_policy->>'jornada_model';
  IF v_jornada IS NULL OR v_jornada NOT IN ('schedule_intersection', 'time_budget') THEN
    RAISE EXCEPTION 'invalid_policy: jornada_model invalid';
  END IF;

  IF p_policy->'activities' IS NULL OR jsonb_typeof(p_policy->'activities') <> 'object' THEN
    RAISE EXCEPTION 'invalid_policy: activities object required';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION data.default_attendance_record_policy(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.validate_attendance_record_policy(jsonb) FROM PUBLIC;

-- ─── 3. Resolve policy (cascada) ─────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.merge_policy_rounding_legacy(
  p_policy   jsonb,
  p_tenant_id uuid,
  p_site_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_policy jsonb := p_policy;
  v_settings jsonb;
  v_legacy text;
BEGIN
  IF v_policy->'rounding' IS NOT NULL
     AND NULLIF(v_policy->'rounding'->>'mode', '') IS NOT NULL THEN
    RETURN v_policy;
  END IF;

  v_settings := api.get_effective_settings(
    p_site_id   => p_site_id,
    p_user_id   => NULL,
    p_tenant_id => p_tenant_id
  );
  v_legacy := COALESCE(v_settings->>'attendance_rounding_mode', 'real_minute');

  v_policy := jsonb_set(
    v_policy,
    '{rounding}',
    COALESCE(v_policy->'rounding', '{}'::jsonb) || jsonb_build_object(
      'mode', v_legacy,
      'direction', 'favor_employee'
    ),
    true
  );

  RETURN v_policy;
END;
$$;

CREATE OR REPLACE FUNCTION data.resolve_attendance_record_policy(
  p_employee_id uuid,
  p_work_date   date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp           record;
  v_row           record;
  v_policy        jsonb;
  v_work_profile  text;
  v_resolved_from text;
BEGIN
  SELECT
    e.tenant_id,
    e.site_id,
    e.calendar_group_id,
    e.attendance_work_profile
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id;
  END IF;

  SELECT
    arp.id,
    arp.scope,
    arp.policy
  INTO v_row
  FROM data.attendance_record_policies arp
  WHERE arp.tenant_id = v_emp.tenant_id
    AND p_work_date >= arp.effective_from
    AND (arp.effective_to IS NULL OR p_work_date <= arp.effective_to)
    AND (
      (arp.scope = 'employee' AND arp.employee_id = p_employee_id)
      OR (arp.scope = 'group_site'
          AND arp.calendar_group_id = v_emp.calendar_group_id
          AND arp.site_id = v_emp.site_id)
      OR (arp.scope = 'site' AND arp.site_id = v_emp.site_id)
      OR (arp.scope = 'group'
          AND arp.calendar_group_id = v_emp.calendar_group_id
          AND arp.site_id IS NULL)
      OR (arp.scope = 'tenant')
      OR (arp.scope = 'system')
    )
  ORDER BY
    CASE arp.scope
      WHEN 'employee' THEN 1
      WHEN 'group_site' THEN 2
      WHEN 'site' THEN 3
      WHEN 'group' THEN 4
      WHEN 'tenant' THEN 5
      WHEN 'system' THEN 6
      ELSE 99
    END,
    arp.effective_from DESC
  LIMIT 1;

  IF FOUND THEN
    v_policy := v_row.policy;
    v_resolved_from := v_row.scope;
  ELSE
    v_policy := data.default_attendance_record_policy('fixed_site');
    v_resolved_from := 'system_default';
    v_row.id := NULL;
  END IF;

  v_policy := data.merge_policy_rounding_legacy(v_policy, v_emp.tenant_id, v_emp.site_id);

  v_work_profile := COALESCE(
    v_emp.attendance_work_profile,
    v_policy->>'work_profile',
    'fixed_site'
  );

  RETURN jsonb_build_object(
    'policy', v_policy,
    'policy_id', v_row.id,
    'resolved_from', v_resolved_from,
    'work_profile', v_work_profile,
    'policy_version', (v_policy->>'version')::int
  );
END;
$$;

REVOKE ALL ON FUNCTION data.resolve_attendance_record_policy(uuid, date) FROM PUBLIC;

CREATE OR REPLACE FUNCTION api.get_attendance_record_policy(
  p_employee_id uuid,
  p_work_date   date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp record;
BEGIN
  SELECT e.user_id, e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF v_emp.user_id IS DISTINCT FROM auth.uid()
       AND NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.view_all', v_emp.site_id)
       AND NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.approve', v_emp.site_id)
       AND NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.manage', v_emp.site_id) THEN
      RAISE EXCEPTION 'insufficient_privilege';
    END IF;
  END IF;

  RETURN data.resolve_attendance_record_policy(p_employee_id, p_work_date);
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_attendance_record_policy(uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_attendance_record_policy(uuid, date) TO service_role;

-- ─── 4. Group policy CRUD ────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.get_calendar_group_record_policy(
  p_group_id    uuid,
  p_work_date   date DEFAULT CURRENT_DATE,
  p_site_id     uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_group     record;
  v_row       record;
BEGIN
  IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.manage required';
  END IF;

  SELECT cg.tenant_id, cg.site_id
  INTO v_group
  FROM data.calendar_groups cg
  WHERE cg.id = p_group_id AND cg.tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'calendar_group_not_found';
  END IF;

  SELECT arp.id, arp.policy, arp.effective_from, arp.effective_to, arp.scope, arp.site_id
  INTO v_row
  FROM data.attendance_record_policies arp
  WHERE arp.tenant_id = v_tenant_id
    AND arp.calendar_group_id = p_group_id
    AND (
      (p_site_id IS NOT NULL AND arp.scope = 'group_site' AND arp.site_id = p_site_id)
      OR (p_site_id IS NULL AND arp.scope = 'group' AND arp.site_id IS NULL)
    )
    AND p_work_date >= arp.effective_from
    AND (arp.effective_to IS NULL OR p_work_date <= arp.effective_to)
  ORDER BY arp.effective_from DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'policy', data.default_attendance_record_policy('fixed_site'),
      'policy_id', null,
      'scope', CASE WHEN p_site_id IS NOT NULL THEN 'group_site' ELSE 'group' END,
      'effective_from', null,
      'effective_to', null,
      'is_default', true
    );
  END IF;

  RETURN jsonb_build_object(
    'policy', v_row.policy,
    'policy_id', v_row.id,
    'scope', v_row.scope,
    'site_id', v_row.site_id,
    'effective_from', v_row.effective_from,
    'effective_to', v_row.effective_to,
    'is_default', false
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.upsert_calendar_group_record_policy(
  p_group_id       uuid,
  p_policy         jsonb,
  p_effective_from date DEFAULT CURRENT_DATE,
  p_site_id        uuid DEFAULT NULL,
  p_policy_id      uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_scope     text;
  v_id        uuid;
  v_group_site uuid;
BEGIN
  IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.manage required';
  END IF;

  PERFORM data.validate_attendance_record_policy(p_policy);

  IF NOT EXISTS (
    SELECT 1 FROM data.calendar_groups cg
    WHERE cg.id = p_group_id AND cg.tenant_id = v_tenant_id
  ) THEN
    RAISE EXCEPTION 'calendar_group_not_found';
  END IF;

  SELECT cg.site_id INTO v_group_site
  FROM data.calendar_groups cg WHERE cg.id = p_group_id;

  IF p_site_id IS NOT NULL THEN
    v_scope := 'group_site';
  ELSIF v_group_site IS NOT NULL THEN
    v_scope := 'group';
    p_site_id := NULL;
  ELSE
    v_scope := 'group';
    p_site_id := NULL;
  END IF;

  IF p_policy_id IS NOT NULL THEN
    UPDATE data.attendance_record_policies arp
    SET policy = p_policy,
        effective_from = p_effective_from,
        updated_at = now()
    WHERE arp.id = p_policy_id
      AND arp.tenant_id = v_tenant_id
      AND arp.calendar_group_id = p_group_id
    RETURNING arp.id INTO v_id;

    IF v_id IS NULL THEN
      RAISE EXCEPTION 'policy_not_found';
    END IF;
  ELSE
    INSERT INTO data.attendance_record_policies (
      tenant_id, scope, calendar_group_id, site_id,
      effective_from, policy, created_by
    ) VALUES (
      v_tenant_id, v_scope, p_group_id, p_site_id,
      p_effective_from, p_policy, auth.uid()
    )
    RETURNING id INTO v_id;
  END IF;

  RETURN jsonb_build_object('policy_id', v_id, 'scope', v_scope, 'status', 'saved');
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_calendar_group_record_policy(uuid, date, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.upsert_calendar_group_record_policy(uuid, jsonb, date, uuid, uuid) TO authenticated;

-- ─── 5. Statutory settings registry ──────────────────────────────────────────

INSERT INTO data.settings_registry
  (setting_key, scope, required_permission, owner_only, is_active, description)
VALUES
  ('attendance_statutory_max_overtime_minutes_year', 'tenant', 'settings.manage', false, true,
   'Màxim hores extra legals per període (minuts)'),
  ('attendance_statutory_overtime_period', 'tenant', 'settings.manage', false, true,
   'Període límit OT: calendar_year | rolling_12m | fiscal_year'),
  ('attendance_statutory_fiscal_year_start_month', 'tenant', 'settings.manage', false, true,
   'Mes inici any fiscal si overtime_period = fiscal_year'),
  ('attendance_statutory_jurisdiction_code', 'tenant', 'settings.manage', false, true,
   'Codi jurisdicció (etiqueta UI)'),
  ('attendance_statutory_max_work_minutes_year', 'tenant', 'settings.manage', false, true,
   'Jornada anual màxima legal opcional (minuts)'),
  ('attendance_statutory_alert_thresholds_pct', 'tenant', 'settings.manage', false, true,
   'Llindars alerta % comptadors legals'),
  ('attendance_statutory_block_punch_on_limit', 'tenant', 'settings.manage', false, true,
   'Bloquejar fitxatge en superar límit legal')
ON CONFLICT (setting_key) DO UPDATE SET
  description = EXCLUDED.description,
  updated_at = now();

INSERT INTO data.system_settings (module, settings)
VALUES (
  'defaults',
  '{
    "attendance_statutory_max_overtime_minutes_year": 4800,
    "attendance_statutory_overtime_period": "calendar_year",
    "attendance_statutory_fiscal_year_start_month": 1,
    "attendance_statutory_jurisdiction_code": "ES",
    "attendance_statutory_max_work_minutes_year": null,
    "attendance_statutory_alert_thresholds_pct": [80, 90, 100],
    "attendance_statutory_block_punch_on_limit": false
  }'::jsonb
)
ON CONFLICT (module) DO UPDATE
  SET settings = data.system_settings.settings || EXCLUDED.settings,
      updated_at = now();

-- ─── 6. Interval intersection (spike Fase 2a) ────────────────────────────────

CREATE OR REPLACE FUNCTION data.interval_intersection_minutes(
  p_range_start timestamptz,
  p_range_end   timestamptz,
  p_intervals   jsonb,
  p_tz          text DEFAULT 'Europe/Madrid'
)
RETURNS int
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_iv       jsonb;
  v_work_date date;
  v_iv_start  timestamptz;
  v_iv_end    timestamptz;
  v_lo        timestamptz;
  v_hi        timestamptz;
  v_total     int := 0;
BEGIN
  IF p_range_end IS NULL OR p_range_start IS NULL OR p_range_end <= p_range_start THEN
    RETURN 0;
  END IF;

  IF p_intervals IS NULL OR jsonb_typeof(p_intervals) <> 'array'
     OR jsonb_array_length(p_intervals) = 0 THEN
    RETURN 0;
  END IF;

  v_work_date := (p_range_start AT TIME ZONE p_tz)::date;

  FOR v_iv IN SELECT value FROM jsonb_array_elements(p_intervals)
  LOOP
    v_iv_start := (v_work_date + (v_iv->>'start')::time) AT TIME ZONE p_tz;
    v_iv_end   := (v_work_date + (v_iv->>'end')::time) AT TIME ZONE p_tz;

    IF (v_iv->>'end')::time <= (v_iv->>'start')::time THEN
      v_iv_end := v_iv_end + interval '1 day';
    END IF;

    v_lo := GREATEST(p_range_start, v_iv_start);
    v_hi := LEAST(p_range_end, v_iv_end);

    IF v_hi > v_lo THEN
      v_total := v_total + (EXTRACT(EPOCH FROM (v_hi - v_lo)) / 60)::int;
    END IF;
  END LOOP;

  RETURN GREATEST(v_total, 0);
END;
$$;

REVOKE ALL ON FUNCTION data.interval_intersection_minutes(timestamptz, timestamptz, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.interval_intersection_minutes(timestamptz, timestamptz, jsonb, text) TO authenticated, service_role;

-- ─── 7. api.employees view + work_day_type ───────────────────────────────────

DROP VIEW IF EXISTS api.employees CASCADE;

CREATE VIEW api.employees AS
SELECT
  id, tenant_id, site_id, user_id, department_id,
  full_name, email, phone, document_id, job_title,
  status, starts_on, ends_on, weekly_hours, metadata,
  calendar_group_id,
  location_consent_given, location_consent_at, location_consent_version,
  attendance_geo_enabled,
  attendance_work_profile,
  created_at, updated_at
FROM data.employees;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.employees TO authenticated;

-- resolve_work_day: afegir work_day_type (sempre 'normal' Fase 1)
CREATE OR REPLACE FUNCTION api.resolve_work_day(
  p_employee_id  uuid,
  p_work_date    date
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp                 record;
  v_tz                  text;
  v_expected_min        int     := 0;
  v_spans_midnight      boolean := false;
  v_shift_start         time;
  v_shift_end           time;
  v_day_type            text    := 'unknown';
  v_absence             record;
  v_emp_override        text;
  v_skip_holiday        boolean := false;
  v_labor               record;
  v_bounds              record;
  v_is_holiday          boolean := false;
  v_holiday_name        text;
  v_work_intervals      jsonb;
BEGIN
  SELECT e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'day_type', 'unknown',
      'expected_minutes', 0,
      'work_day_type', 'normal',
      'error', 'employee_not_found'
    );
  END IF;

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

  v_tz := COALESCE(data.get_site_timezone(v_emp.site_id, v_emp.tenant_id), 'Europe/Madrid');

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
    SELECT lc.planned_minutes, lc.work_intervals
    INTO v_expected_min, v_work_intervals
    FROM data.resolve_labor_calendar_for_employee(
      v_emp.tenant_id, v_emp.site_id, p_employee_id, p_work_date, false
    ) lc
    WHERE lc.labor_day_type = 'work';

    v_expected_min := COALESCE(v_expected_min, 0);
    v_work_intervals := COALESCE(v_work_intervals, '[]'::jsonb);

    RETURN jsonb_build_object(
      'day_type',              'absence',
      'expected_minutes',      v_expected_min,
      'work_day_type',         'normal',
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
      'work_intervals',        v_work_intervals,
      'employee_override',     false,
      'labor_source',          'absence'
    );
  END IF;

  SELECT edo.override_type INTO v_emp_override
  FROM data.employee_day_overrides edo
  WHERE edo.employee_id  = p_employee_id
    AND edo.override_date = p_work_date;

  IF FOUND THEN
    IF v_emp_override = 'force_holiday' THEN
      RETURN jsonb_build_object(
        'day_type', 'holiday',
        'expected_minutes', 0,
        'work_day_type', 'normal',
        'site_timezone', v_tz,
        'is_holiday', true,
        'holiday_name', null,
        'holiday_type', 'tenant_custom',
        'is_half_day', false,
        'is_absence', false,
        'absence_id', null,
        'absence_type', null,
        'schedule_id', null,
        'schedule_name', null,
        'spans_midnight', false,
        'shift_start_time', null,
        'shift_end_time', null,
        'work_intervals', '[]'::jsonb,
        'employee_override', true,
        'labor_source', 'employee_day_override'
      );
    ELSIF v_emp_override = 'force_work' THEN
      v_skip_holiday := true;
    END IF;
  END IF;

  SELECT * INTO v_labor
  FROM data.resolve_labor_calendar_for_employee(
    v_emp.tenant_id, v_emp.site_id, p_employee_id, p_work_date, v_skip_holiday
  );

  v_expected_min := COALESCE(v_labor.planned_minutes, 0);
  v_holiday_name := v_labor.labor_day_name;
  v_is_holiday := v_labor.labor_day_type = 'holiday'
    OR (v_labor.labor_source = 'assigned_holiday');
  v_work_intervals := COALESCE(v_labor.work_intervals, '[]'::jsonb);

  CASE v_labor.labor_day_type
    WHEN 'work' THEN
      v_day_type := 'working';
      SELECT * INTO v_bounds FROM data.labor_intervals_shift_bounds(v_labor.work_intervals);
      v_shift_start := v_bounds.shift_start;
      v_shift_end := v_bounds.shift_end;
      v_spans_midnight := COALESCE(v_bounds.spans_midnight, false);

    WHEN 'holiday' THEN
      v_day_type := CASE WHEN COALESCE(v_labor.is_half_day, false) THEN 'half_holiday' ELSE 'holiday' END;
      v_expected_min := 0;
      v_is_holiday := true;

    WHEN 'vacation', 'leave' THEN
      v_day_type := 'non_working';
      v_expected_min := 0;

    ELSE
      v_day_type := 'unknown';
      v_expected_min := 0;
  END CASE;

  RETURN jsonb_build_object(
    'day_type',          v_day_type,
    'expected_minutes',  v_expected_min,
    'work_day_type',     'normal',
    'site_timezone',     v_tz,
    'is_holiday',        v_is_holiday,
    'holiday_name',      v_holiday_name,
    'holiday_type',      CASE WHEN v_is_holiday THEN 'assigned' ELSE null END,
    'is_half_day',       COALESCE(v_labor.is_half_day, false),
    'is_absence',        false,
    'absence_id',        null,
    'absence_type',      null,
    'schedule_id',       null,
    'schedule_name',     null,
    'spans_midnight',    v_spans_midnight,
    'shift_start_time',  v_shift_start,
    'shift_end_time',    v_shift_end,
    'work_intervals',    v_work_intervals,
    'employee_override', COALESCE(v_emp_override = 'force_work', false),
    'labor_source',      v_labor.labor_source,
    'labor_day_type',    v_labor.labor_day_type
  );
END;
$$;
