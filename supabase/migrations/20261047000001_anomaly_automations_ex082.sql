-- =============================================================================
-- EX-08.2 — Automatitzacions d'anomalies (AP-08)
-- In-app via NotificationService; dedup + quiet hours; sense canals externs nous.
-- Triggers: PAUSE_NOT_CLOSED, PUNCH_OUT_MISSING, OVERTIME (reutilitza G5),
--           SHIFT_COVERAGE_GAP (vacants obertes sense omplir).
-- =============================================================================

-- ─── 1. Dedup / fired ────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS data.attendance_anomaly_automation_fired (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id       uuid REFERENCES data.sites(id) ON DELETE CASCADE,
  trigger_code  text NOT NULL
    CONSTRAINT aaa_trigger_chk CHECK (trigger_code IN (
      'PAUSE_NOT_CLOSED',
      'PUNCH_OUT_MISSING',
      'OVERTIME_THRESHOLD_EXCEEDED',
      'SHIFT_COVERAGE_GAP'
    )),
  entity_key    text NOT NULL,
  work_date     date,
  employee_id   uuid REFERENCES data.employees(id) ON DELETE SET NULL,
  payload       jsonb NOT NULL DEFAULT '{}'::jsonb,
  fired_at      timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_aaa_fired_dedup
  ON data.attendance_anomaly_automation_fired (tenant_id, trigger_code, entity_key);

CREATE INDEX IF NOT EXISTS idx_aaa_fired_tenant_date
  ON data.attendance_anomaly_automation_fired (tenant_id, work_date DESC);

COMMENT ON TABLE data.attendance_anomaly_automation_fired IS
  'EX-08.2: deduplicació d''emissions d''automatització d''anomalies (1× per entity_key).';

ALTER TABLE data.attendance_anomaly_automation_fired ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS aaa_fired_select ON data.attendance_anomaly_automation_fired;
CREATE POLICY aaa_fired_select ON data.attendance_anomaly_automation_fired FOR SELECT
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'attendance.view_all', site_id)
      OR data.jwt_has_permission(tenant_id, 'labor_calendar.view', site_id)
      OR data.jwt_has_permission(tenant_id, 'labor_calendar.manage', site_id)
    )
  );

GRANT SELECT ON data.attendance_anomaly_automation_fired TO authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON data.attendance_anomaly_automation_fired TO service_role;

-- ─── 2. Catalog ──────────────────────────────────────────────────────────────

INSERT INTO data.notification_event_catalog (
  event_code, category, entity_type, deep_link_template,
  default_channels, requires_legal, digest_eligible, description
) VALUES
  ('ATTENDANCE_PAUSE_NOT_CLOSED', 'operations', 'employee',
   '/employees/{entity_id}?tab=timesheet', '{in_app}', false, true,
   'Pausa no tancada (AP-08 / EX-08.2)'),
  ('ATTENDANCE_PUNCH_OUT_MISSING', 'operations', 'employee',
   '/employees/{entity_id}?tab=timesheet', '{in_app}', false, true,
   'Sortida no fitxada (AP-08 / EX-08.2)'),
  ('ATTENDANCE_SHIFT_COVERAGE_GAP', 'operations', 'site',
   '/attendance/planificacio?tab=demand', '{in_app}', false, true,
   'Gap de cobertura / vacant oberta (AP-08 / EX-08.2)')
ON CONFLICT (event_code) DO NOTHING;

-- OVERTIME_THRESHOLD_EXCEEDED = ATTENDANCE_OVERTIME_THRESHOLD (G5 ja operatiu)

-- ─── 3. Settings helpers ─────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.attendance_anomaly_automation_enabled(
  p_tenant_id uuid,
  p_site_id   uuid,
  p_trigger   text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_settings jsonb;
  v_cfg jsonb;
  v_key text;
BEGIN
  v_settings := data.merge_effective_settings_for_service(p_tenant_id, p_site_id);
  v_cfg := COALESCE(v_settings->'attendance_anomaly_automations', '{}'::jsonb);

  -- Master switch (default true)
  IF v_cfg ? 'enabled' AND (v_cfg->>'enabled')::boolean = false THEN
    RETURN false;
  END IF;

  v_key := CASE p_trigger
    WHEN 'PAUSE_NOT_CLOSED' THEN 'pause_not_closed'
    WHEN 'PUNCH_OUT_MISSING' THEN 'punch_out_missing'
    WHEN 'OVERTIME_THRESHOLD_EXCEEDED' THEN 'overtime_threshold'
    WHEN 'SHIFT_COVERAGE_GAP' THEN 'shift_coverage_gap'
    ELSE NULL
  END;

  IF v_key IS NULL THEN
    RETURN false;
  END IF;

  -- Default ON si no configurat
  IF v_cfg ? v_key THEN
    RETURN COALESCE((v_cfg->>v_key)::boolean, true);
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION data.attendance_anomaly_automation_enabled(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.attendance_anomaly_automation_enabled(uuid, uuid, text)
  TO authenticated, service_role;

-- ─── 4. Emit (quiet hours + dedup + in-app) ──────────────────────────────────

CREATE OR REPLACE FUNCTION data.emit_attendance_anomaly_automation(
  p_tenant_id   uuid,
  p_site_id     uuid,
  p_trigger     text,
  p_entity_key  text,
  p_employee_id uuid DEFAULT NULL,
  p_work_date   date DEFAULT NULL,
  p_payload     jsonb DEFAULT '{}'::jsonb,
  p_urgent      boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_fired_id uuid;
  v_event text;
  v_emp record;
  v_emp_name text;
  v_emp_user uuid;
  v_mgr record;
  v_notified int := 0;
  v_corr text;
BEGIN
  IF p_tenant_id IS NULL OR p_trigger IS NULL OR COALESCE(btrim(p_entity_key), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_args');
  END IF;

  IF p_trigger NOT IN (
    'PAUSE_NOT_CLOSED', 'PUNCH_OUT_MISSING',
    'OVERTIME_THRESHOLD_EXCEEDED', 'SHIFT_COVERAGE_GAP'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'unknown_trigger');
  END IF;

  IF NOT data.attendance_anomaly_automation_enabled(p_tenant_id, p_site_id, p_trigger) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'disabled');
  END IF;

  -- Quiet hours (reutilitza EX-07.6) excepte urgent
  IF NOT COALESCE(p_urgent, false)
     AND p_site_id IS NOT NULL
     AND data.planning_push_in_quiet_hours(p_site_id, clock_timestamp())
  THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'quiet_hours');
  END IF;

  INSERT INTO data.attendance_anomaly_automation_fired (
    tenant_id, site_id, trigger_code, entity_key, work_date, employee_id, payload
  ) VALUES (
    p_tenant_id, p_site_id, p_trigger, p_entity_key, p_work_date, p_employee_id,
    COALESCE(p_payload, '{}'::jsonb)
  )
  ON CONFLICT (tenant_id, trigger_code, entity_key) DO NOTHING
  RETURNING id INTO v_fired_id;

  IF v_fired_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_fired');
  END IF;

  v_event := CASE p_trigger
    WHEN 'PAUSE_NOT_CLOSED' THEN 'ATTENDANCE_PAUSE_NOT_CLOSED'
    WHEN 'PUNCH_OUT_MISSING' THEN 'ATTENDANCE_PUNCH_OUT_MISSING'
    WHEN 'OVERTIME_THRESHOLD_EXCEEDED' THEN 'ATTENDANCE_OVERTIME_THRESHOLD'
    WHEN 'SHIFT_COVERAGE_GAP' THEN 'ATTENDANCE_SHIFT_COVERAGE_GAP'
  END;

  IF p_employee_id IS NOT NULL THEN
    SELECT e.user_id, e.full_name INTO v_emp_user, v_emp_name
    FROM data.employees e WHERE e.id = p_employee_id;
  END IF;

  -- Notificar empleat (si té user) per pause / punch-out
  IF p_trigger IN ('PAUSE_NOT_CLOSED', 'PUNCH_OUT_MISSING')
     AND v_emp_user IS NOT NULL
  THEN
    v_corr := format('aaa-%s-%s-emp', p_trigger, p_entity_key);
    BEGIN
      PERFORM api.enqueue_notification(jsonb_build_object(
        'tenantId', p_tenant_id,
        'siteId', p_site_id,
        'eventType', v_event,
        'correlationId', left(v_corr, 200),
        'recipient', jsonb_build_object('kind', 'tenant_member', 'userId', v_emp_user),
        'entityType', 'employee',
        'entityId', p_employee_id,
        'payload', COALESCE(p_payload, '{}'::jsonb) || jsonb_build_object(
          'trigger', p_trigger,
          'employee_name', v_emp_name
        )
      ));
      v_notified := v_notified + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'emit_aaa employee notify: %', SQLERRM;
    END;
  END IF;

  -- Notificar managers (tots els triggers)
  FOR v_mgr IN
    SELECT tm.user_id
    FROM data.tenant_members tm
    WHERE tm.tenant_id = p_tenant_id
      AND tm.role IN ('owner', 'manager')
      AND tm.is_active IS DISTINCT FROM false
      AND (v_emp_user IS NULL OR tm.user_id IS DISTINCT FROM v_emp_user)
  LOOP
    v_corr := format('aaa-%s-%s-mgr-%s', p_trigger, p_entity_key, v_mgr.user_id);
    BEGIN
      PERFORM api.enqueue_notification(jsonb_build_object(
        'tenantId', p_tenant_id,
        'siteId', p_site_id,
        'eventType', v_event,
        'correlationId', left(v_corr, 200),
        'recipient', jsonb_build_object('kind', 'tenant_member', 'userId', v_mgr.user_id),
        'entityType', CASE WHEN p_employee_id IS NOT NULL THEN 'employee' ELSE 'site' END,
        'entityId', COALESCE(p_employee_id, p_site_id),
        'payload', COALESCE(p_payload, '{}'::jsonb) || jsonb_build_object(
          'trigger', p_trigger,
          'employee_name', v_emp_name
        )
      ));
      v_notified := v_notified + 1;
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'fired_id', v_fired_id,
    'notified', v_notified,
    'event', v_event
  );
END;
$$;

REVOKE ALL ON FUNCTION data.emit_attendance_anomaly_automation(uuid, uuid, text, text, uuid, date, jsonb, boolean)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.emit_attendance_anomaly_automation(uuid, uuid, text, text, uuid, date, jsonb, boolean)
  TO service_role;

-- ─── 5. Wire PAUSE_NOT_CLOSED a check_unclosed_pauses ────────────────────────

CREATE OR REPLACE FUNCTION api.check_unclosed_pauses(
  p_tenant_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data, public
AS $$
DECLARE
  v_tenant_id   uuid;
  v_default_max int := 240;
  v_rec         record;
  v_max_min     int;
  v_elapsed_min numeric;
  v_count       int := 0;
  v_notified    int := 0;
  v_site_id     uuid;
  v_emit        jsonb;
BEGIN
  v_tenant_id := COALESCE(p_tenant_id, data.active_tenant_id());

  FOR v_rec IN
    SELECT DISTINCT ON (tp.employee_id)
      tp.id         AS punch_id,
      tp.employee_id,
      tp.tenant_id,
      tp.occurred_at AS break_start_at,
      tp.pause_type,
      e.site_id,
      (tp.occurred_at AT TIME ZONE COALESCE(data.get_site_timezone(e.site_id, tp.tenant_id), 'Europe/Madrid'))::date AS work_date
    FROM data.time_punches tp
    JOIN data.employees e ON e.id = tp.employee_id
    WHERE tp.punch_type = 'break_start'
      AND (v_tenant_id IS NULL OR tp.tenant_id = v_tenant_id)
      AND tp.occurred_at >= now() - interval '2 days'
      AND NOT ('PAUSE_NOT_CLOSED' = ANY(tp.anomaly_codes))
    ORDER BY tp.employee_id, tp.occurred_at DESC
  LOOP
    IF EXISTS (
      SELECT 1 FROM data.time_punches tp2
      WHERE tp2.employee_id = v_rec.employee_id
        AND tp2.occurred_at > v_rec.break_start_at
        AND tp2.punch_type IN ('break_end', 'out', 'in')
    ) THEN
      CONTINUE;
    END IF;

    SELECT COALESCE(
      (SELECT MIN(max_duration_minutes)
       FROM data.tenant_pause_configs
       WHERE tenant_id = v_rec.tenant_id
         AND is_active = true
         AND max_duration_minutes IS NOT NULL
         AND (pause_type = v_rec.pause_type OR v_rec.pause_type IS NULL)),
      v_default_max
    ) INTO v_max_min;

    v_elapsed_min := EXTRACT(EPOCH FROM (now() - v_rec.break_start_at)) / 60;

    IF v_elapsed_min > v_max_min THEN
      UPDATE data.time_punches
      SET anomaly_codes = array_append(anomaly_codes, 'PAUSE_NOT_CLOSED')
      WHERE id = v_rec.punch_id
        AND NOT ('PAUSE_NOT_CLOSED' = ANY(anomaly_codes));

      UPDATE data.time_daily_summaries
      SET
        anomaly_codes = CASE
          WHEN NOT ('PAUSE_NOT_CLOSED' = ANY(anomaly_codes))
            THEN array_append(anomaly_codes, 'PAUSE_NOT_CLOSED')
          ELSE anomaly_codes
        END,
        needs_review = true,
        updated_at   = now()
      WHERE employee_id = v_rec.employee_id
        AND work_date   = v_rec.work_date
        AND NOT ('PAUSE_NOT_CLOSED' = ANY(anomaly_codes));

      v_count := v_count + 1;
      v_site_id := v_rec.site_id;

      v_emit := data.emit_attendance_anomaly_automation(
        v_rec.tenant_id,
        v_site_id,
        'PAUSE_NOT_CLOSED',
        format('pause:%s:%s', v_rec.employee_id, v_rec.work_date),
        v_rec.employee_id,
        v_rec.work_date,
        jsonb_build_object(
          'punch_id', v_rec.punch_id,
          'elapsed_minutes', round(v_elapsed_min)::int,
          'max_minutes', v_max_min
        ),
        false
      );
      IF COALESCE((v_emit->>'ok')::boolean, false) THEN
        v_notified := v_notified + COALESCE((v_emit->>'notified')::int, 0);
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'processed', v_count,
    'notified', v_notified,
    'tenant_id', v_tenant_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.check_unclosed_pauses(uuid) TO authenticated, service_role;

-- ─── 6. Scan PUNCH_OUT_MISSING ───────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.scan_punch_out_missing(
  p_as_of timestamptz DEFAULT clock_timestamp(),
  p_grace_minutes int DEFAULT 30,
  p_ignore_quiet_hours boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_rec record;
  v_tz text;
  v_local_ts timestamp;
  v_work_date date;
  v_plan jsonb;
  v_end_time time;
  v_end_ts timestamp;
  v_first_in timestamptz;
  v_emit jsonb;
  v_count int := 0;
  v_notified int := 0;
  v_grace int := GREATEST(0, COALESCE(p_grace_minutes, 30));
BEGIN
  FOR v_rec IN
    SELECT DISTINCT ON (tp.employee_id)
      tp.employee_id,
      tp.tenant_id,
      tp.punch_type,
      tp.occurred_at,
      e.site_id,
      e.full_name
    FROM data.time_punches tp
    JOIN data.employees e ON e.id = tp.employee_id AND e.status = 'active'
    WHERE tp.occurred_at >= p_as_of - interval '36 hours'
    ORDER BY tp.employee_id, tp.occurred_at DESC
  LOOP
    IF v_rec.punch_type NOT IN ('in', 'break_start', 'break_end') THEN
      CONTINUE;
    END IF;

    v_tz := COALESCE(data.get_site_timezone(v_rec.site_id, v_rec.tenant_id), 'Europe/Madrid');
    v_local_ts := p_as_of AT TIME ZONE v_tz;
    v_work_date := (v_rec.occurred_at AT TIME ZONE v_tz)::date;

    IF v_work_date < (v_local_ts::date - 1) OR v_work_date > v_local_ts::date THEN
      CONTINUE;
    END IF;

    v_plan := data.resolve_employee_work_plan(v_rec.employee_id, v_work_date);
    v_end_time := NULL;
    IF v_plan IS NOT NULL THEN
      IF NULLIF(v_plan->>'shift_end_time', '') IS NOT NULL THEN
        v_end_time := (v_plan->>'shift_end_time')::time;
      ELSIF jsonb_typeof(v_plan->'work_intervals') = 'array' THEN
        SELECT MAX(COALESCE(
          NULLIF(i->>'end_time', '')::time,
          NULLIF(i->>'end', '')::time
        ))
        INTO v_end_time
        FROM jsonb_array_elements(v_plan->'work_intervals') i;
      END IF;
    END IF;

    IF v_end_time IS NOT NULL THEN
      v_end_ts := (v_work_date + v_end_time);
      IF v_end_time < '06:00'::time THEN
        v_end_ts := v_end_ts + interval '1 day';
      END IF;
      IF v_local_ts < (v_end_ts + make_interval(mins => v_grace)) THEN
        CONTINUE;
      END IF;
    ELSE
      SELECT MIN(tp2.occurred_at) INTO v_first_in
      FROM data.time_punches tp2
      WHERE tp2.employee_id = v_rec.employee_id
        AND tp2.punch_type = 'in'
        AND (tp2.occurred_at AT TIME ZONE v_tz)::date = v_work_date;
      IF v_first_in IS NULL OR p_as_of < v_first_in + interval '10 hours' THEN
        CONTINUE;
      END IF;
    END IF;

    v_emit := data.emit_attendance_anomaly_automation(
      v_rec.tenant_id,
      v_rec.site_id,
      'PUNCH_OUT_MISSING',
      format('pout:%s:%s', v_rec.employee_id, v_work_date),
      v_rec.employee_id,
      v_work_date,
      jsonb_build_object(
        'last_punch_type', v_rec.punch_type,
        'last_punch_at', v_rec.occurred_at,
        'planned_end', v_end_time
      ),
      COALESCE(p_ignore_quiet_hours, false)
    );
    v_count := v_count + 1;
    IF COALESCE((v_emit->>'ok')::boolean, false) THEN
      v_notified := v_notified + COALESCE((v_emit->>'notified')::int, 0);
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'candidates', v_count,
    'notified', v_notified,
    'as_of', p_as_of
  );
END;
$$;

REVOKE ALL ON FUNCTION data.scan_punch_out_missing(timestamptz, int, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.scan_punch_out_missing(timestamptz, int, boolean) TO service_role;

CREATE OR REPLACE FUNCTION data.scan_shift_coverage_gaps(
  p_as_of timestamptz DEFAULT clock_timestamp(),
  p_ignore_quiet_hours boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_rec record;
  v_tz text;
  v_local_date date;
  v_emit jsonb;
  v_count int := 0;
  v_notified int := 0;
  v_open_places int;
BEGIN
  FOR v_rec IN
    SELECT
      o.tenant_id,
      o.site_id,
      o.opening_date,
      sum(o.places_total - o.places_filled)::int AS open_places,
      count(*)::int AS opening_count
    FROM data.shift_openings o
    WHERE o.status = 'open'
      AND o.places_filled < o.places_total
      AND o.opening_date BETWEEN (p_as_of::date - 1) AND (p_as_of::date + 1)
    GROUP BY o.tenant_id, o.site_id, o.opening_date
  LOOP
    v_tz := COALESCE(data.get_site_timezone(v_rec.site_id, v_rec.tenant_id), 'Europe/Madrid');
    v_local_date := (p_as_of AT TIME ZONE v_tz)::date;

    IF v_rec.opening_date NOT IN (v_local_date, v_local_date - 1) THEN
      CONTINUE;
    END IF;

    v_open_places := v_rec.open_places;
    IF v_open_places <= 0 THEN
      CONTINUE;
    END IF;

    v_emit := data.emit_attendance_anomaly_automation(
      v_rec.tenant_id,
      v_rec.site_id,
      'SHIFT_COVERAGE_GAP',
      format('cov:%s:%s', v_rec.site_id, v_rec.opening_date),
      NULL,
      v_rec.opening_date,
      jsonb_build_object(
        'open_places', v_open_places,
        'opening_count', v_rec.opening_count
      ),
      COALESCE(p_ignore_quiet_hours, false)
    );
    v_count := v_count + 1;
    IF COALESCE((v_emit->>'ok')::boolean, false) THEN
      v_notified := v_notified + COALESCE((v_emit->>'notified')::int, 0);
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'candidates', v_count,
    'notified', v_notified,
    'as_of', p_as_of
  );
END;
$$;

REVOKE ALL ON FUNCTION data.scan_shift_coverage_gaps(timestamptz, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.scan_shift_coverage_gaps(timestamptz, boolean) TO service_role;

-- ─── 8. Orchestrator + API ───────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.run_attendance_anomaly_automations(
  p_as_of timestamptz DEFAULT clock_timestamp(),
  p_tenant_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_pause jsonb;
  v_pout jsonb;
  v_cov jsonb;
BEGIN
  v_pause := api.check_unclosed_pauses(p_tenant_id);
  v_pout := data.scan_punch_out_missing(p_as_of, 30, false);
  v_cov := data.scan_shift_coverage_gaps(p_as_of, false);

  RETURN jsonb_build_object(
    'pause_not_closed', v_pause,
    'punch_out_missing', v_pout,
    'shift_coverage_gap', v_cov,
    'overtime_note', 'OVERTIME_THRESHOLD_EXCEEDED cobert per ATTENDANCE_OVERTIME_THRESHOLD (G5)',
    'as_of', p_as_of
  );
END;
$$;

REVOKE ALL ON FUNCTION api.run_attendance_anomaly_automations(timestamptz, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.run_attendance_anomaly_automations(timestamptz, uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.run_attendance_anomaly_automations IS
  'EX-08.2: escaneja i emet automatitzacions AP-08 (pause / punch-out / coverage).';

CREATE OR REPLACE FUNCTION api.list_attendance_anomaly_automation_firings(
  p_from date DEFAULT (CURRENT_DATE - 7),
  p_to   date DEFAULT CURRENT_DATE
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
    COALESCE(data.jwt_has_permission(v_tenant, 'attendance.view_all', NULL), false)
    OR COALESCE(data.jwt_has_permission(v_tenant, 'labor_calendar.view', NULL), false)
    OR COALESCE(data.jwt_has_permission(v_tenant, 'labor_calendar.manage', NULL), false)
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(f) ORDER BY f.fired_at DESC), '[]'::jsonb)
  INTO v_items
  FROM data.attendance_anomaly_automation_fired f
  WHERE f.tenant_id = v_tenant
    AND (f.work_date IS NULL OR f.work_date BETWEEN p_from AND p_to);

  RETURN jsonb_build_object('firings', COALESCE(v_items, '[]'::jsonb));
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_attendance_anomaly_automation_firings(date, date)
  TO authenticated, service_role;

-- Cron cada 15 min
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('attendance-anomaly-automations');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;

    PERFORM cron.schedule(
      'attendance-anomaly-automations',
      '*/15 * * * *',
      $cron$SELECT api.run_attendance_anomaly_automations(clock_timestamp(), NULL)$cron$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'EX-08.2: no s''ha pogut programar cron attendance-anomaly-automations: %', SQLERRM;
END;
$$;

NOTIFY pgrst, 'reload schema';
