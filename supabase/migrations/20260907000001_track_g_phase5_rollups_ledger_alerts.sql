-- Track G Phase 5: annual rollups, legal alerts, compensation ledger (C3)

-- --- 1. Tables ---

CREATE TABLE IF NOT EXISTS data.attendance_yearly_rollups (
  tenant_id                  uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id                uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  period_key                 text NOT NULL,
  jurisdiction_code          text NOT NULL DEFAULT 'ES',
  work_minutes_ytd           int  NOT NULL DEFAULT 0,
  travel_minutes_ytd         int  NOT NULL DEFAULT 0,
  paid_minutes_ytd           int  NOT NULL DEFAULT 0,
  effective_minutes_ytd      int  NOT NULL DEFAULT 0,
  overtime_authorized_ytd    int  NOT NULL DEFAULT 0,
  overtime_pending_ytd       int  NOT NULL DEFAULT 0,
  updated_at                 timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (employee_id, period_key)
);

CREATE INDEX IF NOT EXISTS idx_attendance_yearly_rollups_tenant
  ON data.attendance_yearly_rollups (tenant_id, period_key);

CREATE TABLE IF NOT EXISTS data.attendance_rollup_day_snapshots (
  tenant_id                    uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id                  uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  work_date                    date NOT NULL,
  period_key                   text NOT NULL,
  work_minutes                 int  NOT NULL DEFAULT 0,
  travel_minutes               int  NOT NULL DEFAULT 0,
  paid_minutes                 int  NOT NULL DEFAULT 0,
  effective_minutes            int  NOT NULL DEFAULT 0,
  overtime_authorized_minutes  int  NOT NULL DEFAULT 0,
  overtime_pending_minutes     int  NOT NULL DEFAULT 0,
  updated_at                   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (employee_id, work_date, period_key)
);

CREATE TABLE IF NOT EXISTS data.time_compensation_ledger (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id      uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  source_work_date date,
  movement_type    text NOT NULL CHECK (movement_type IN (
    'accrued', 'compensated_time_off', 'paid_payroll', 'expired', 'manual_adjustment'
  )),
  source_type      text NOT NULL DEFAULT 'overtime' CHECK (source_type IN (
    'overtime', 'holiday_worked', 'manual'
  )),
  minutes          int  NOT NULL CHECK (minutes > 0),
  is_credit        boolean NOT NULL,
  notes            text,
  created_by       uuid REFERENCES auth.users(id),
  created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_time_compensation_ledger_employee
  ON data.time_compensation_ledger (employee_id, created_at DESC);

CREATE TABLE IF NOT EXISTS data.attendance_legal_alert_fired (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id   uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  alert_kind    text NOT NULL,
  period_key    text NOT NULL,
  threshold_pct int  NOT NULL,
  fired_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (employee_id, alert_kind, period_key, threshold_pct)
);

-- --- 2. RLS ---

ALTER TABLE data.attendance_yearly_rollups ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.attendance_rollup_day_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.time_compensation_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.attendance_legal_alert_fired ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS attendance_yearly_rollups_read ON data.attendance_yearly_rollups;
CREATE POLICY attendance_yearly_rollups_read ON data.attendance_yearly_rollups
  FOR SELECT TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND (
      data.jwt_has_permission(tenant_id, 'attendance.view_all', NULL)
      OR employee_id IN (
        SELECT e.id FROM data.employees e WHERE e.user_id = auth.uid()
      )
    )
  );

DROP POLICY IF EXISTS attendance_rollup_day_snapshots_service ON data.attendance_rollup_day_snapshots;
CREATE POLICY attendance_rollup_day_snapshots_service ON data.attendance_rollup_day_snapshots
  FOR ALL TO service_role
  USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS time_compensation_ledger_read ON data.time_compensation_ledger;
CREATE POLICY time_compensation_ledger_read ON data.time_compensation_ledger
  FOR SELECT TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND (
      data.jwt_has_permission(tenant_id, 'attendance.view_all', NULL)
      OR employee_id IN (
        SELECT e.id FROM data.employees e WHERE e.user_id = auth.uid()
      )
    )
  );

DROP POLICY IF EXISTS attendance_legal_alert_fired_service ON data.attendance_legal_alert_fired;
CREATE POLICY attendance_legal_alert_fired_service ON data.attendance_legal_alert_fired
  FOR ALL TO service_role
  USING (true) WITH CHECK (true);

-- --- 3. Period keys ---

CREATE OR REPLACE FUNCTION data.attendance_period_keys_for_date(
  p_work_date           date,
  p_overtime_period     text,
  p_fiscal_start_month  int
)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_keys text[] := ARRAY[]::text[];
  v_fy   int;
BEGIN
  v_keys := v_keys || format('cy:%s', EXTRACT(YEAR FROM p_work_date)::int);

  IF COALESCE(p_overtime_period, 'calendar_year') = 'fiscal_year' THEN
    IF EXTRACT(MONTH FROM p_work_date)::int >= GREATEST(1, LEAST(12, COALESCE(p_fiscal_start_month, 1))) THEN
      v_fy := EXTRACT(YEAR FROM p_work_date)::int;
    ELSE
      v_fy := EXTRACT(YEAR FROM p_work_date)::int - 1;
    END IF;
    v_keys := v_keys || format('fy:%s', v_fy);
  END IF;

  IF COALESCE(p_overtime_period, 'calendar_year') = 'rolling_12m' THEN
    v_keys := v_keys || 'rolling_12m';
  END IF;

  RETURN v_keys;
END;
$$;

-- --- 4. Incremental rollup sync ---

CREATE OR REPLACE FUNCTION data.apply_attendance_rollup_delta(
  p_tenant_id    uuid,
  p_employee_id  uuid,
  p_period_key   text,
  p_jurisdiction text,
  p_delta_work   int,
  p_delta_travel int,
  p_delta_paid   int,
  p_delta_effective int,
  p_delta_ot_auth int,
  p_delta_ot_pending int
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF p_delta_work = 0 AND p_delta_travel = 0 AND p_delta_paid = 0
     AND p_delta_effective = 0 AND p_delta_ot_auth = 0 AND p_delta_ot_pending = 0 THEN
    RETURN;
  END IF;

  INSERT INTO data.attendance_yearly_rollups (
    tenant_id, employee_id, period_key, jurisdiction_code,
    work_minutes_ytd, travel_minutes_ytd, paid_minutes_ytd,
    effective_minutes_ytd, overtime_authorized_ytd, overtime_pending_ytd
  ) VALUES (
    p_tenant_id, p_employee_id, p_period_key, COALESCE(NULLIF(p_jurisdiction, ''), 'ES'),
    GREATEST(0, p_delta_work),
    GREATEST(0, p_delta_travel),
    GREATEST(0, p_delta_paid),
    GREATEST(0, p_delta_effective),
    GREATEST(0, p_delta_ot_auth),
    GREATEST(0, p_delta_ot_pending)
  )
  ON CONFLICT (employee_id, period_key) DO UPDATE SET
    work_minutes_ytd        = GREATEST(0, data.attendance_yearly_rollups.work_minutes_ytd + p_delta_work),
    travel_minutes_ytd      = GREATEST(0, data.attendance_yearly_rollups.travel_minutes_ytd + p_delta_travel),
    paid_minutes_ytd        = GREATEST(0, data.attendance_yearly_rollups.paid_minutes_ytd + p_delta_paid),
    effective_minutes_ytd   = GREATEST(0, data.attendance_yearly_rollups.effective_minutes_ytd + p_delta_effective),
    overtime_authorized_ytd = GREATEST(0, data.attendance_yearly_rollups.overtime_authorized_ytd + p_delta_ot_auth),
    overtime_pending_ytd    = GREATEST(0, data.attendance_yearly_rollups.overtime_pending_ytd + p_delta_ot_pending),
    updated_at              = now();
END;
$$;

CREATE OR REPLACE FUNCTION data.sync_attendance_rollups_for_day(
  p_employee_id uuid,
  p_work_date   date,
  p_tenant_id   uuid,
  p_site_id     uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_settings           jsonb;
  v_jurisdiction       text := 'ES';
  v_period             text := 'calendar_year';
  v_fiscal_month       int  := 1;
  v_period_keys        text[];
  v_period_key         text;
  v_cy_key             text;
  v_summary            record;
  v_old                record;
  v_old_ot_auth        int := 0;
  v_new_work           int;
  v_new_travel         int;
  v_new_paid           int;
  v_new_effective      int;
  v_new_ot_auth        int;
  v_new_ot_pending     int;
  v_today              date := (now() AT TIME ZONE COALESCE(data.get_site_timezone(p_site_id, p_tenant_id), 'Europe/Madrid'))::date;
  v_exit_date          date;
BEGIN
  v_settings := data.merge_effective_settings_for_service(p_tenant_id, p_site_id);
  IF COALESCE((v_settings->>'attendance_effective_time_enabled')::boolean, false) IS NOT TRUE THEN
    RETURN;
  END IF;

  v_jurisdiction := COALESCE(NULLIF(v_settings->>'attendance_statutory_jurisdiction_code', ''), 'ES');
  v_period       := COALESCE(NULLIF(v_settings->>'attendance_statutory_overtime_period', ''), 'calendar_year');
  v_fiscal_month := COALESCE((v_settings->>'attendance_statutory_fiscal_year_start_month')::int, 1);

  SELECT
    COALESCE(work_minutes, 0),
    COALESCE(travel_minutes, 0),
    COALESCE(paid_minutes, 0),
    COALESCE(effective_minutes, 0),
    COALESCE(overtime_authorized_minutes, 0),
    GREATEST(0, COALESCE(overtime_minutes, 0) - COALESCE(overtime_authorized_minutes, 0))
  INTO
    v_new_work, v_new_travel, v_new_paid, v_new_effective, v_new_ot_auth, v_new_ot_pending
  FROM data.time_daily_summaries
  WHERE employee_id = p_employee_id AND work_date = p_work_date;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_cy_key := format('cy:%s', EXTRACT(YEAR FROM p_work_date)::int);
  SELECT COALESCE(overtime_authorized_minutes, 0) INTO v_old_ot_auth
  FROM data.attendance_rollup_day_snapshots
  WHERE employee_id = p_employee_id
    AND work_date = p_work_date
    AND period_key = v_cy_key;

  IF v_new_ot_auth > COALESCE(v_old_ot_auth, 0) THEN
    INSERT INTO data.time_compensation_ledger (
      tenant_id, employee_id, source_work_date,
      movement_type, source_type, minutes, is_credit
    ) VALUES (
      p_tenant_id, p_employee_id, p_work_date,
      'accrued', 'overtime', v_new_ot_auth - COALESCE(v_old_ot_auth, 0), true
    );
  END IF;

  v_period_keys := data.attendance_period_keys_for_date(p_work_date, v_period, v_fiscal_month);

  FOREACH v_period_key IN ARRAY v_period_keys LOOP
    IF v_period_key = 'rolling_12m' AND p_work_date < v_today - 365 THEN
      CONTINUE;
    END IF;

    SELECT * INTO v_old
    FROM data.attendance_rollup_day_snapshots
    WHERE employee_id = p_employee_id
      AND work_date = p_work_date
      AND period_key = v_period_key;

    PERFORM data.apply_attendance_rollup_delta(
      p_tenant_id, p_employee_id, v_period_key, v_jurisdiction,
      v_new_work - COALESCE(v_old.work_minutes, 0),
      v_new_travel - COALESCE(v_old.travel_minutes, 0),
      v_new_paid - COALESCE(v_old.paid_minutes, 0),
      v_new_effective - COALESCE(v_old.effective_minutes, 0),
      v_new_ot_auth - COALESCE(v_old.overtime_authorized_minutes, 0),
      v_new_ot_pending - COALESCE(v_old.overtime_pending_minutes, 0)
    );

    INSERT INTO data.attendance_rollup_day_snapshots (
      tenant_id, employee_id, work_date, period_key,
      work_minutes, travel_minutes, paid_minutes, effective_minutes,
      overtime_authorized_minutes, overtime_pending_minutes
    ) VALUES (
      p_tenant_id, p_employee_id, p_work_date, v_period_key,
      v_new_work, v_new_travel, v_new_paid, v_new_effective,
      v_new_ot_auth, v_new_ot_pending
    )
    ON CONFLICT (employee_id, work_date, period_key) DO UPDATE SET
      work_minutes = EXCLUDED.work_minutes,
      travel_minutes = EXCLUDED.travel_minutes,
      paid_minutes = EXCLUDED.paid_minutes,
      effective_minutes = EXCLUDED.effective_minutes,
      overtime_authorized_minutes = EXCLUDED.overtime_authorized_minutes,
      overtime_pending_minutes = EXCLUDED.overtime_pending_minutes,
      updated_at = now();
  END LOOP;

  -- Rolling window exit: subtract day falling out when consolidating today
  IF v_period = 'rolling_12m' AND p_work_date = v_today THEN
    v_exit_date := v_today - 365;
    SELECT * INTO v_old
    FROM data.attendance_rollup_day_snapshots
    WHERE employee_id = p_employee_id
      AND work_date = v_exit_date
      AND period_key = 'rolling_12m';

    IF FOUND THEN
      PERFORM data.apply_attendance_rollup_delta(
        p_tenant_id, p_employee_id, 'rolling_12m', v_jurisdiction,
        -v_old.work_minutes, -v_old.travel_minutes, -v_old.paid_minutes,
        -v_old.effective_minutes, -v_old.overtime_authorized_minutes,
        -v_old.overtime_pending_minutes
      );
    END IF;
  END IF;

  PERFORM data.check_attendance_legal_alerts(p_employee_id, p_work_date, p_tenant_id, p_site_id);
END;
$$;

-- --- 5. Compensation ledger (C3) ---

CREATE OR REPLACE FUNCTION data.get_compensation_balance_minutes(p_employee_id uuid)
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT COALESCE(SUM(CASE WHEN is_credit THEN minutes ELSE -minutes END), 0)::int
  FROM data.time_compensation_ledger
  WHERE employee_id = p_employee_id;
$$;

-- --- 6. Legal alerts (event-driven) ---

CREATE OR REPLACE FUNCTION data.check_attendance_legal_alerts(
  p_employee_id uuid,
  p_work_date   date,
  p_tenant_id   uuid,
  p_site_id     uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_settings       jsonb;
  v_emp            record;
  v_policy         jsonb;
  v_period         text;
  v_fiscal_month   int;
  v_period_keys    text[];
  v_period_key     text;
  v_rollup         record;
  v_thresholds     jsonb;
  v_threshold      int;
  v_limit_ot       int;
  v_limit_work     int;
  v_limit_convenio int;
  v_current        int;
  v_limit          int;
  v_pct            int;
  v_alert_kind     text;
  v_title          jsonb;
  v_body           jsonb;
  v_manager        record;
  v_alert_id       uuid;
BEGIN
  v_settings := data.merge_effective_settings_for_service(p_tenant_id, p_site_id);
  IF COALESCE((v_settings->>'attendance_effective_time_enabled')::boolean, false) IS NOT TRUE THEN
    RETURN;
  END IF;

  SELECT e.id, e.full_name, e.user_id INTO v_emp
  FROM data.employees e WHERE e.id = p_employee_id;

  v_period       := COALESCE(NULLIF(v_settings->>'attendance_statutory_overtime_period', ''), 'calendar_year');
  v_fiscal_month := COALESCE((v_settings->>'attendance_statutory_fiscal_year_start_month')::int, 1);
  v_thresholds   := COALESCE(v_settings->'attendance_statutory_alert_thresholds_pct', '[80,90,100]'::jsonb);

  v_limit_ot := COALESCE((v_settings->>'attendance_statutory_max_overtime_minutes_year')::int, 4800);
  v_limit_work := (v_settings->>'attendance_statutory_max_work_minutes_year')::int;

  v_policy := data.resolve_attendance_record_policy(p_employee_id, p_work_date)->'policy';
  v_limit_convenio := COALESCE((v_policy->'overtime'->>'max_annual_minutes_convenio')::int, 0);

  v_period_keys := data.attendance_period_keys_for_date(p_work_date, v_period, v_fiscal_month);

  FOREACH v_period_key IN ARRAY v_period_keys LOOP
    SELECT * INTO v_rollup
    FROM data.attendance_yearly_rollups
    WHERE employee_id = p_employee_id AND period_key = v_period_key;

    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    FOR v_threshold IN
      SELECT (jsonb_array_elements_text(v_thresholds))::int
    LOOP
      -- Statutory overtime
      IF v_limit_ot > 0 THEN
        v_current := v_rollup.overtime_authorized_ytd;
        v_limit   := v_limit_ot;
        v_pct     := (v_current * 100) / NULLIF(v_limit, 0);
        v_alert_kind := 'overtime_statutory';
        IF v_pct >= v_threshold THEN
          INSERT INTO data.attendance_legal_alert_fired (
            tenant_id, employee_id, alert_kind, period_key, threshold_pct
          ) VALUES (p_tenant_id, p_employee_id, v_alert_kind, v_period_key, v_threshold)
          ON CONFLICT DO NOTHING
          RETURNING id INTO v_alert_id;

          IF v_alert_id IS NOT NULL THEN
            v_title := jsonb_build_object(
              'ca', 'Límit d''hores extra',
              'es', 'Límite de horas extra'
            );
            v_body := jsonb_build_object(
              'ca', format('%s ha assolit el %s%% del límit legal d''hores extra (%s/%s min).',
                COALESCE(v_emp.full_name, 'Empleat'), v_threshold, v_current, v_limit),
              'es', format('%s ha alcanzado el %s%% del límite legal de horas extra (%s/%s min).',
                COALESCE(v_emp.full_name, 'Empleado'), v_threshold, v_current, v_limit)
            );

            IF v_emp.user_id IS NOT NULL THEN
              BEGIN
                PERFORM api.enqueue_notification(jsonb_build_object(
                  'tenantId', p_tenant_id,
                  'siteId', p_site_id,
                  'eventType', 'ATTENDANCE_OVERTIME_THRESHOLD',
                  'correlationId', format('att-ot-%s-%s-%s-%s', p_employee_id, v_period_key, v_threshold, v_threshold),
                  'recipient', jsonb_build_object('kind', 'tenant_member', 'userId', v_emp.user_id),
                  'entityType', 'employee',
                  'entityId', p_employee_id,
                  'payload', jsonb_build_object(
                    'employee_name', v_emp.full_name,
                    'threshold_pct', v_threshold,
                    'current_minutes', v_current,
                    'limit_minutes', v_limit,
                    'period_key', v_period_key
                  )
                ));
              EXCEPTION WHEN OTHERS THEN
                RAISE WARNING 'check_attendance_legal_alerts employee notify: %', SQLERRM;
              END;
            END IF;

            FOR v_manager IN
              SELECT tm.user_id
              FROM data.tenant_members tm
              WHERE tm.tenant_id = p_tenant_id
                AND tm.role IN ('owner', 'manager')
                AND (v_emp.user_id IS NULL OR tm.user_id IS DISTINCT FROM v_emp.user_id)
            LOOP
              BEGIN
                PERFORM api.enqueue_notification(jsonb_build_object(
                  'tenantId', p_tenant_id,
                  'siteId', p_site_id,
                  'eventType', 'ATTENDANCE_OVERTIME_THRESHOLD',
                  'correlationId', format('att-ot-mgr-%s-%s-%s-%s', p_employee_id, v_period_key, v_threshold, v_manager.user_id),
                  'recipient', jsonb_build_object('kind', 'tenant_member', 'userId', v_manager.user_id),
                  'entityType', 'employee',
                  'entityId', p_employee_id,
                  'payload', jsonb_build_object(
                    'employee_name', v_emp.full_name,
                    'threshold_pct', v_threshold,
                    'current_minutes', v_current,
                    'limit_minutes', v_limit,
                    'period_key', v_period_key
                  )
                ));
              EXCEPTION WHEN OTHERS THEN
                NULL;
              END;
            END LOOP;
          END IF;
        END IF;
      END IF;

      -- Convenio overtime
      IF v_limit_convenio > 0 THEN
        v_current := v_rollup.overtime_authorized_ytd;
        v_limit   := v_limit_convenio;
        v_pct     := (v_current * 100) / NULLIF(v_limit, 0);
        v_alert_kind := 'convenio_overtime';
        IF v_pct >= v_threshold THEN
          INSERT INTO data.attendance_legal_alert_fired (
            tenant_id, employee_id, alert_kind, period_key, threshold_pct
          ) VALUES (p_tenant_id, p_employee_id, v_alert_kind, v_period_key, v_threshold)
          ON CONFLICT DO NOTHING;
        END IF;
      END IF;

      -- Annual work limit
      IF v_limit_work IS NOT NULL AND v_limit_work > 0 THEN
        v_current := v_rollup.paid_minutes_ytd;
        v_limit   := v_limit_work;
        v_pct     := (v_current * 100) / NULLIF(v_limit, 0);
        v_alert_kind := 'work_annual';
        IF v_pct >= v_threshold THEN
          INSERT INTO data.attendance_legal_alert_fired (
            tenant_id, employee_id, alert_kind, period_key, threshold_pct
          ) VALUES (p_tenant_id, p_employee_id, v_alert_kind, v_period_key, v_threshold)
          ON CONFLICT DO NOTHING;
        END IF;
      END IF;
    END LOOP;
  END LOOP;
END;
$$;

-- Notification catalog
INSERT INTO data.notification_event_catalog (
  event_code, category, entity_type, deep_link_template,
  default_channels, requires_legal, digest_eligible, description
) VALUES
  ('ATTENDANCE_OVERTIME_THRESHOLD', 'operations', 'employee', '/employees/{entity_id}?tab=timesheet',
   '{in_app,push}', false, false, 'Llindar d''hores extra legal/conveni assolit'),
  ('ATTENDANCE_WORK_THRESHOLD', 'operations', 'employee', '/employees/{entity_id}?tab=timesheet',
   '{in_app,push}', false, false, 'Llindar de jornada anual assolit')
ON CONFLICT (event_code) DO NOTHING;

-- --- 7. API: legal counters + compensation ---

CREATE OR REPLACE FUNCTION api.get_attendance_legal_counters(
  p_employee_id uuid,
  p_as_of_date  date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp            record;
  v_as_of          date;
  v_settings       jsonb;
  v_policy         jsonb;
  v_period         text;
  v_fiscal_month   int;
  v_period_keys    text[];
  v_period_key     text;
  v_rollup         record;
  v_limit_ot       int;
  v_limit_work     int;
  v_limit_convenio int;
  v_balance        int;
  v_counters       jsonb := '[]'::jsonb;
  v_pct            numeric;
BEGIN
  SELECT e.id, e.tenant_id, e.site_id, e.user_id, e.full_name
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF NOT (
      data.jwt_has_permission(v_emp.tenant_id, 'attendance.view_all', v_emp.site_id)
      OR v_emp.user_id = auth.uid()
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege';
    END IF;
  END IF;

  v_as_of := COALESCE(p_as_of_date, (now() AT TIME ZONE COALESCE(data.get_site_timezone(v_emp.site_id, v_emp.tenant_id), 'Europe/Madrid'))::date);

  v_settings := data.merge_effective_settings_for_service(v_emp.tenant_id, v_emp.site_id);
  v_period       := COALESCE(NULLIF(v_settings->>'attendance_statutory_overtime_period', ''), 'calendar_year');
  v_fiscal_month := COALESCE((v_settings->>'attendance_statutory_fiscal_year_start_month')::int, 1);
  v_limit_ot     := COALESCE((v_settings->>'attendance_statutory_max_overtime_minutes_year')::int, 4800);
  v_limit_work   := (v_settings->>'attendance_statutory_max_work_minutes_year')::int;

  v_policy := data.resolve_attendance_record_policy(p_employee_id, v_as_of)->'policy';
  v_limit_convenio := COALESCE((v_policy->'overtime'->>'max_annual_minutes_convenio')::int, 0);

  v_period_keys := data.attendance_period_keys_for_date(v_as_of, v_period, v_fiscal_month);
  v_balance := data.get_compensation_balance_minutes(p_employee_id);

  FOREACH v_period_key IN ARRAY v_period_keys LOOP
    SELECT * INTO v_rollup
    FROM data.attendance_yearly_rollups
    WHERE employee_id = p_employee_id AND period_key = v_period_key;

    v_counters := v_counters || jsonb_build_array(jsonb_build_object(
      'period_key', v_period_key,
      'work_minutes_ytd', COALESCE(v_rollup.work_minutes_ytd, 0),
      'travel_minutes_ytd', COALESCE(v_rollup.travel_minutes_ytd, 0),
      'paid_minutes_ytd', COALESCE(v_rollup.paid_minutes_ytd, 0),
      'effective_minutes_ytd', COALESCE(v_rollup.effective_minutes_ytd, 0),
      'overtime_authorized_ytd', COALESCE(v_rollup.overtime_authorized_ytd, 0),
      'overtime_pending_ytd', COALESCE(v_rollup.overtime_pending_ytd, 0),
      'limits', jsonb_build_object(
        'statutory_overtime_minutes', v_limit_ot,
        'convenio_overtime_minutes', NULLIF(v_limit_convenio, 0),
        'statutory_work_minutes', v_limit_work
      ),
      'pct', jsonb_build_object(
        'statutory_overtime', CASE WHEN v_limit_ot > 0
          THEN ROUND(COALESCE(v_rollup.overtime_authorized_ytd, 0)::numeric * 100 / v_limit_ot, 1) ELSE NULL END,
        'convenio_overtime', CASE WHEN v_limit_convenio > 0
          THEN ROUND(COALESCE(v_rollup.overtime_authorized_ytd, 0)::numeric * 100 / v_limit_convenio, 1) ELSE NULL END,
        'statutory_work', CASE WHEN v_limit_work IS NOT NULL AND v_limit_work > 0
          THEN ROUND(COALESCE(v_rollup.paid_minutes_ytd, 0)::numeric * 100 / v_limit_work, 1) ELSE NULL END
      )
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'as_of_date', v_as_of,
    'period_type', v_period,
    'compensation_balance_minutes', v_balance,
    'counters', v_counters
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.list_site_legal_risk_employees(
  p_site_id         uuid,
  p_threshold_pct   int DEFAULT 80
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid;
  v_today     date;
  v_period    text;
  v_fiscal    int;
  v_period_key text;
  v_limit_ot  int;
  v_rows      jsonb := '[]'::jsonb;
  v_rec       record;
BEGIN
  SELECT s.tenant_id INTO v_tenant_id FROM data.sites s WHERE s.id = p_site_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_not_found';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.view_all', p_site_id) THEN
      RAISE EXCEPTION 'insufficient_privilege';
    END IF;
  END IF;

  v_today := (now() AT TIME ZONE COALESCE(data.get_site_timezone(p_site_id, v_tenant_id), 'Europe/Madrid'))::date;
  v_period := COALESCE(
    NULLIF((data.merge_effective_settings_for_service(v_tenant_id, p_site_id)->>'attendance_statutory_overtime_period'), ''),
    'calendar_year'
  );
  v_fiscal := COALESCE(
    (data.merge_effective_settings_for_service(v_tenant_id, p_site_id)->>'attendance_statutory_fiscal_year_start_month')::int,
    1
  );
  v_limit_ot := COALESCE(
    (data.merge_effective_settings_for_service(v_tenant_id, p_site_id)->>'attendance_statutory_max_overtime_minutes_year')::int,
    4800
  );

  v_period_key := (data.attendance_period_keys_for_date(v_today, v_period, v_fiscal))[1];

  FOR v_rec IN
    SELECT e.id, e.full_name,
           r.overtime_authorized_ytd,
           r.overtime_pending_ytd,
           r.paid_minutes_ytd
    FROM data.employees e
    JOIN data.attendance_yearly_rollups r ON r.employee_id = e.id AND r.period_key = v_period_key
    WHERE e.site_id = p_site_id
      AND e.status = 'active'
      AND v_limit_ot > 0
      AND (r.overtime_authorized_ytd * 100 / v_limit_ot) >= p_threshold_pct
    ORDER BY (r.overtime_authorized_ytd * 100 / v_limit_ot) DESC
    LIMIT 25
  LOOP
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'employee_id', v_rec.id,
      'employee_name', v_rec.full_name,
      'overtime_authorized_ytd', v_rec.overtime_authorized_ytd,
      'overtime_pending_ytd', v_rec.overtime_pending_ytd,
      'paid_minutes_ytd', v_rec.paid_minutes_ytd,
      'pct_statutory_overtime', ROUND(v_rec.overtime_authorized_ytd::numeric * 100 / v_limit_ot, 1)
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'site_id', p_site_id,
    'period_key', v_period_key,
    'threshold_pct', p_threshold_pct,
    'employees', v_rows
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_attendance_legal_counters(uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION api.list_site_legal_risk_employees(uuid, int) TO authenticated;

REVOKE ALL ON FUNCTION data.sync_attendance_rollups_for_day(uuid, date, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.sync_attendance_rollups_for_day(uuid, date, uuid, uuid) TO service_role;

NOTIFY pgrst, 'reload schema';
