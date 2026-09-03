-- =============================================================================
-- Fase 6 — triggers pendents (extensió EX-08.2)
-- PUNCH_IN_UNUSUAL_HOUR | ABSENCE_REQUEST_PENDING | MONTH_CLOSED_REPORT
-- =============================================================================

-- ─── 1. Ampliar CHECK trigger_code ───────────────────────────────────────────

ALTER TABLE data.attendance_anomaly_automation_fired
  DROP CONSTRAINT IF EXISTS aaa_trigger_chk;

ALTER TABLE data.attendance_anomaly_automation_fired
  ADD CONSTRAINT aaa_trigger_chk CHECK (trigger_code IN (
    'PAUSE_NOT_CLOSED',
    'PUNCH_OUT_MISSING',
    'OVERTIME_THRESHOLD_EXCEEDED',
    'SHIFT_COVERAGE_GAP',
    'PUNCH_IN_UNUSUAL_HOUR',
    'ABSENCE_REQUEST_PENDING',
    'MONTH_CLOSED_REPORT'
  ));

-- ─── 2. Catalog ──────────────────────────────────────────────────────────────

INSERT INTO data.notification_event_catalog (
  event_code, category, entity_type, deep_link_template,
  default_channels, requires_legal, digest_eligible, description
) VALUES
  ('ATTENDANCE_PUNCH_IN_UNUSUAL_HOUR', 'operations', 'employee',
   '/employees/{entity_id}?tab=timesheet', '{in_app}', false, true,
   'Fitxatge d''entrada fora de franja (Fase 6)'),
  ('ATTENDANCE_ABSENCE_REQUEST_PENDING', 'operations', 'employee',
   '/employees/{entity_id}?tab=absences', '{in_app}', false, true,
   'Sol·licitud d''absència pendent (Fase 6)'),
  ('ATTENDANCE_MONTH_CLOSED_REPORT', 'operations', 'employee',
   '/employees/{entity_id}?tab=timesheet', '{in_app}', false, true,
   'Mes tancat — generar registre (Fase 6)')
ON CONFLICT (event_code) DO NOTHING;

-- ─── 3. Settings map ─────────────────────────────────────────────────────────

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

  IF v_cfg ? 'enabled' AND (v_cfg->>'enabled')::boolean = false THEN
    RETURN false;
  END IF;

  v_key := CASE p_trigger
    WHEN 'PAUSE_NOT_CLOSED' THEN 'pause_not_closed'
    WHEN 'PUNCH_OUT_MISSING' THEN 'punch_out_missing'
    WHEN 'OVERTIME_THRESHOLD_EXCEEDED' THEN 'overtime_threshold'
    WHEN 'SHIFT_COVERAGE_GAP' THEN 'shift_coverage_gap'
    WHEN 'PUNCH_IN_UNUSUAL_HOUR' THEN 'punch_in_unusual_hour'
    WHEN 'ABSENCE_REQUEST_PENDING' THEN 'absence_request_pending'
    WHEN 'MONTH_CLOSED_REPORT' THEN 'month_closed_report'
    ELSE NULL
  END;

  IF v_key IS NULL THEN
    RETURN false;
  END IF;

  IF v_cfg ? v_key THEN
    RETURN COALESCE((v_cfg->>v_key)::boolean, true);
  END IF;

  RETURN true;
END;
$$;

-- ─── 4. Emit (nous triggers) ─────────────────────────────────────────────────

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
    'OVERTIME_THRESHOLD_EXCEEDED', 'SHIFT_COVERAGE_GAP',
    'PUNCH_IN_UNUSUAL_HOUR', 'ABSENCE_REQUEST_PENDING', 'MONTH_CLOSED_REPORT'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'unknown_trigger');
  END IF;

  IF NOT data.attendance_anomaly_automation_enabled(p_tenant_id, p_site_id, p_trigger) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'disabled');
  END IF;

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
    WHEN 'PUNCH_IN_UNUSUAL_HOUR' THEN 'ATTENDANCE_PUNCH_IN_UNUSUAL_HOUR'
    WHEN 'ABSENCE_REQUEST_PENDING' THEN 'ATTENDANCE_ABSENCE_REQUEST_PENDING'
    WHEN 'MONTH_CLOSED_REPORT' THEN 'ATTENDANCE_MONTH_CLOSED_REPORT'
  END;

  IF p_employee_id IS NOT NULL THEN
    SELECT e.user_id, e.full_name INTO v_emp_user, v_emp_name
    FROM data.employees e WHERE e.id = p_employee_id;
  END IF;

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

-- ─── 5. PUNCH_IN_UNUSUAL_HOUR helper + trigger ───────────────────────────────

CREATE OR REPLACE FUNCTION data.maybe_emit_punch_in_unusual_hour(
  p_punch data.time_punches
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tz text;
  v_work_date date;
  v_local_t time;
  v_plan jsonb;
  v_policy jsonb;
  v_early int := 30;
  v_late int := 30;
  v_iv jsonb;
  v_start time;
  v_end time;
  v_lo time;
  v_hi time;
  v_usual boolean := false;
  v_site uuid;
BEGIN
  IF p_punch.punch_type NOT IN ('in', 'day_start') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_in_punch');
  END IF;

  SELECT e.site_id INTO v_site FROM data.employees e WHERE e.id = p_punch.employee_id;
  v_site := COALESCE(p_punch.site_id, v_site);
  v_tz := COALESCE(data.get_site_timezone(v_site, p_punch.tenant_id), 'Europe/Madrid');
  v_work_date := (p_punch.occurred_at AT TIME ZONE v_tz)::date;
  v_local_t := (p_punch.occurred_at AT TIME ZONE v_tz)::time;

  v_plan := data.resolve_employee_work_plan(p_punch.employee_id, v_work_date);
  IF v_plan IS NULL OR jsonb_typeof(v_plan->'work_intervals') <> 'array'
     OR jsonb_array_length(v_plan->'work_intervals') = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_plan');
  END IF;

  BEGIN
    v_policy := data.resolve_attendance_record_policy(p_punch.employee_id, v_work_date)->'policy';
    v_early := COALESCE((v_policy->'courtesy'->>'early_arrival_minutes')::int, 30);
    v_late := COALESCE((v_policy->'courtesy'->>'late_departure_minutes')::int, 30);
  EXCEPTION WHEN OTHERS THEN
    v_early := 30;
    v_late := 30;
  END;

  FOR v_iv IN SELECT value FROM jsonb_array_elements(v_plan->'work_intervals')
  LOOP
    v_start := COALESCE(NULLIF(v_iv->>'start_time', '')::time, NULLIF(v_iv->>'start', '')::time);
    v_end := COALESCE(NULLIF(v_iv->>'end_time', '')::time, NULLIF(v_iv->>'end', '')::time);
    IF v_start IS NULL OR v_end IS NULL THEN
      CONTINUE;
    END IF;
    v_lo := ((TIMESTAMP '2000-01-01' + v_start) - (v_early * interval '1 minute'))::time;
    v_hi := ((TIMESTAMP '2000-01-01' + v_end) + (v_late * interval '1 minute'))::time;

    IF v_end > v_start THEN
      IF v_local_t >= v_lo AND v_local_t <= v_hi THEN
        v_usual := true;
        EXIT;
      END IF;
    ELSE
      -- overnight interval
      IF v_local_t >= v_lo OR v_local_t <= v_hi THEN
        v_usual := true;
        EXIT;
      END IF;
    END IF;
  END LOOP;

  IF v_usual THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'within_window');
  END IF;

  RETURN data.emit_attendance_anomaly_automation(
    p_punch.tenant_id,
    v_site,
    'PUNCH_IN_UNUSUAL_HOUR',
    format('punch:%s', p_punch.id),
    p_punch.employee_id,
    v_work_date,
    jsonb_build_object(
      'punch_id', p_punch.id,
      'punch_type', p_punch.punch_type,
      'occurred_at', p_punch.occurred_at,
      'local_time', v_local_t
    ),
    false
  );
END;
$$;

CREATE OR REPLACE FUNCTION data.trg_time_punch_unusual_hour()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF NEW.punch_type IN ('in', 'day_start') THEN
    PERFORM data.maybe_emit_punch_in_unusual_hour(NEW);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_time_punch_unusual_hour ON data.time_punches;
CREATE TRIGGER trg_time_punch_unusual_hour
  AFTER INSERT ON data.time_punches
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_time_punch_unusual_hour();

-- ─── 6. ABSENCE_REQUEST_PENDING trigger ──────────────────────────────────────

CREATE OR REPLACE FUNCTION data.trg_absence_request_pending()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_site uuid;
BEGIN
  IF NEW.status IS DISTINCT FROM 'requested' THEN
    RETURN NEW;
  END IF;

  SELECT e.site_id INTO v_site FROM data.employees e WHERE e.id = NEW.employee_id;

  PERFORM data.emit_attendance_anomaly_automation(
    NEW.tenant_id,
    v_site,
    'ABSENCE_REQUEST_PENDING',
    format('absence:%s', NEW.id),
    NEW.employee_id,
    NEW.start_date,
    jsonb_build_object(
      'absence_id', NEW.id,
      'absence_type', NEW.absence_type,
      'start_date', NEW.start_date,
      'end_date', NEW.end_date
    ),
    false
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_absence_request_pending ON data.employee_absences;
CREATE TRIGGER trg_absence_request_pending
  AFTER INSERT ON data.employee_absences
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_absence_request_pending();

-- Also when status flips to requested on UPDATE (rare)
CREATE OR REPLACE FUNCTION data.trg_absence_request_pending_upd()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_site uuid;
BEGIN
  IF NEW.status = 'requested' AND OLD.status IS DISTINCT FROM 'requested' THEN
    SELECT e.site_id INTO v_site FROM data.employees e WHERE e.id = NEW.employee_id;
    PERFORM data.emit_attendance_anomaly_automation(
      NEW.tenant_id,
      v_site,
      'ABSENCE_REQUEST_PENDING',
      format('absence:%s', NEW.id),
      NEW.employee_id,
      NEW.start_date,
      jsonb_build_object(
        'absence_id', NEW.id,
        'absence_type', NEW.absence_type,
        'start_date', NEW.start_date,
        'end_date', NEW.end_date
      ),
      false
    );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_absence_request_pending_upd ON data.employee_absences;
CREATE TRIGGER trg_absence_request_pending_upd
  AFTER UPDATE OF status ON data.employee_absences
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_absence_request_pending_upd();

-- ─── 7. MONTH_CLOSED_REPORT: invoke edge + wire approve ──────────────────────

CREATE OR REPLACE FUNCTION data.invoke_generate_attendance_report(
  p_tenant_id   uuid,
  p_employee_id uuid,
  p_year        int,
  p_month       int
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_url text;
  v_key text;
  v_req bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RAISE WARNING 'invoke_generate_attendance_report: pg_net not installed';
    RETURN -2;
  END IF;
  SELECT decrypted_secret INTO v_url FROM vault.decrypted_secrets WHERE name = 'supabase_url' LIMIT 1;
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'service_role_key' LIMIT 1;
  IF v_url IS NULL OR v_key IS NULL THEN
    RAISE WARNING 'invoke_generate_attendance_report: vault secrets missing';
    RETURN -1;
  END IF;
  BEGIN
    SELECT net.http_post(
      url := v_url || '/functions/v1/generate-attendance-report',
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || v_key,
        'Content-Type', 'application/json'
      ),
      body := jsonb_build_object(
        'tenant_id', p_tenant_id,
        'employee_id', p_employee_id,
        'year', p_year,
        'month', p_month
      )
    ) INTO v_req;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'invoke_generate_attendance_report http_post failed: %', SQLERRM;
    RETURN NULL;
  END;
  RETURN v_req;
END;
$$;

REVOKE ALL ON FUNCTION data.invoke_generate_attendance_report(uuid, uuid, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.invoke_generate_attendance_report(uuid, uuid, int, int) TO service_role;

CREATE OR REPLACE FUNCTION api.approve_attendance_month(
  p_employee_id uuid, p_year int, p_month int
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = data, api
AS $$
DECLARE
  v_id                    uuid;
  v_emp                   record;
  v_check                 jsonb;
  v_settings              jsonb;
  v_require_confirm       boolean := true;
  v_can_close_without     boolean := true;
  v_bulk_approve          boolean := true;
  v_report_status         text;
  v_month_start           date;
  v_month_end             date;
BEGIN
  v_month_start := make_date(p_year, p_month, 1);
  v_month_end   := (v_month_start + interval '1 month' - interval '1 day')::date;

  SELECT * INTO v_emp FROM data.employees WHERE id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.approve', v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege';
  END IF;

  v_check := api.validate_attendance_month_close(p_employee_id, p_year, p_month);
  IF NOT COALESCE((v_check->>'closable')::boolean, false) THEN
    RAISE EXCEPTION 'month_not_closable'
      USING ERRCODE = 'check_violation',
            DETAIL = v_check::text;
  END IF;

  v_settings := api.get_effective_settings(
    p_site_id   => v_emp.site_id,
    p_tenant_id => v_emp.tenant_id
  );
  v_require_confirm := COALESCE(
    (v_settings->>'attendance_monthly_employee_confirm_required')::boolean,
    true
  );
  v_can_close_without := COALESCE(
    (v_settings->>'attendance_monthly_manager_can_close_without_employee')::boolean,
    true
  );
  v_bulk_approve := COALESCE(
    (v_settings->>'attendance_monthly_bulk_approve_days_on_close')::boolean,
    true
  );

  SELECT amr.status INTO v_report_status
  FROM data.attendance_monthly_reports amr
  WHERE amr.employee_id = p_employee_id
    AND amr.year = p_year
    AND amr.month = p_month;

  IF v_report_status IS NULL THEN
    v_report_status := 'draft';
  END IF;

  IF v_require_confirm
     AND NOT v_can_close_without
     AND NOT data.attendance_month_employee_confirm_satisfied(
       p_employee_id, p_year, p_month, v_report_status
     ) THEN
    RAISE EXCEPTION 'employee_confirmation_required'
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_bulk_approve THEN
    UPDATE data.time_daily_summaries tds
    SET
      status      = 'approved',
      approved_by = auth.uid(),
      approved_at = now(),
      updated_at  = now()
    WHERE tds.employee_id = p_employee_id
      AND tds.work_date BETWEEN v_month_start AND v_month_end
      AND tds.status = 'draft'
      AND tds.payroll_locked_at IS NULL;
  END IF;

  INSERT INTO data.attendance_monthly_reports (tenant_id, employee_id, year, month, status, approved_by, approved_at)
  VALUES (v_emp.tenant_id, p_employee_id, p_year, p_month, 'manager_approved', auth.uid(), now())
  ON CONFLICT (employee_id, year, month) DO UPDATE SET
    status = 'manager_approved', approved_by = auth.uid(), approved_at = now(), updated_at = now()
  RETURNING id INTO v_id;

  PERFORM data.log_attendance_employee_audit(
    v_emp.tenant_id,
    auth.uid(),
    v_emp.site_id,
    p_employee_id,
    'ATTENDANCE_MONTH_MANAGER_CLOSED',
    jsonb_build_object(
      'year', p_year,
      'month', p_month,
      'report_id', v_id,
      'previous_status', v_report_status,
      'bulk_approve_days', v_bulk_approve
    )
  );

  -- Fase 6: MONTH_CLOSED_REPORT
  PERFORM data.emit_attendance_anomaly_automation(
    v_emp.tenant_id,
    v_emp.site_id,
    'MONTH_CLOSED_REPORT',
    format('month:%s:%s-%s', p_employee_id, p_year, lpad(p_month::text, 2, '0')),
    p_employee_id,
    v_month_start,
    jsonb_build_object(
      'year', p_year,
      'month', p_month,
      'report_id', v_id
    ),
    true  -- urgent: tancament no ha d'esperar quiet hours
  );

  PERFORM data.invoke_generate_attendance_report(
    v_emp.tenant_id, p_employee_id, p_year, p_month
  );

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.approve_attendance_month(uuid, int, int) TO authenticated;

NOTIFY pgrst, 'reload schema';
