-- WS-B1: punch reminder idempotency, day context RPC, enqueue + cron scan

-- ─── Idempotency ledger ───────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS data.employee_portal_punch_reminder_sent (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id   uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  work_date     date NOT NULL,
  reminder_kind text NOT NULL,
  sent_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employee_portal_punch_reminder_sent_kind_chk CHECK (
    reminder_kind IN (
      'missing_entry',
      'missing_afternoon_entry',
      'missing_morning_exit',
      'missing_exit',
      'starting_soon',
      'afternoon_starting_soon'
    )
  ),
  CONSTRAINT employee_portal_punch_reminder_sent_unique
    UNIQUE (employee_id, work_date, reminder_kind)
);

CREATE INDEX IF NOT EXISTS idx_ep_punch_reminder_sent_work_date
  ON data.employee_portal_punch_reminder_sent (work_date);

CREATE INDEX IF NOT EXISTS idx_ep_punch_reminder_sent_employee_day
  ON data.employee_portal_punch_reminder_sent (employee_id, work_date);

ALTER TABLE data.employee_portal_punch_reminder_sent ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, DELETE ON data.employee_portal_punch_reminder_sent TO service_role;

-- ─── Day punch context (timezone-aware work_date) ────────────────────────────

CREATE OR REPLACE FUNCTION api.employee_portal_get_day_punch_context(
  p_employee_id uuid,
  p_tenant_id   uuid,
  p_work_date   date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp record;
  v_tz text := 'Europe/Madrid';
  v_punches jsonb;
  v_last record;
  v_status text;
  v_active_pause_type text;
  v_open_pause_since timestamptz;
  v_resolved jsonb;
  v_profile text;
  v_legacy boolean;
  v_day_state text := 'off';
  v_next_state text;
  v_punch record;
BEGIN
  SELECT e.id, e.tenant_id, e.status, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND e.tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF p_work_date IS NULL THEN
    RAISE EXCEPTION 'invalid_work_date' USING ERRCODE = 'check_violation';
  END IF;

  v_tz := COALESCE(
    NULLIF((api.resolve_work_day(p_employee_id, p_work_date) ->> 'site_timezone'), ''),
    data.get_site_timezone(v_emp.site_id, v_emp.tenant_id),
    'Europe/Madrid'
  );

  SELECT data.resolve_attendance_record_policy(p_employee_id, p_work_date)
  INTO v_resolved;

  v_profile := COALESCE(v_resolved->>'work_profile', 'fixed_site');
  v_legacy := data.policy_legacy_in_out_only(v_resolved->'policy', v_profile);

  SELECT COALESCE(jsonb_agg(row_to_json(p)::jsonb ORDER BY p.occurred_at ASC, p.id ASC), '[]'::jsonb)
  INTO v_punches
  FROM (
    SELECT
      tp.id,
      tp.punch_type,
      tp.occurred_at,
      tp.received_at,
      tp.anomaly_codes,
      tp.source,
      tp.pause_type,
      tp.is_remote
    FROM data.time_punches tp
    WHERE tp.employee_id = p_employee_id
      AND (tp.occurred_at AT TIME ZONE v_tz)::date = p_work_date
    ORDER BY tp.occurred_at ASC, tp.id ASC
  ) p;

  FOR v_punch IN
    SELECT punch_type
    FROM data.time_punches
    WHERE employee_id = p_employee_id
      AND (occurred_at AT TIME ZONE v_tz)::date = p_work_date
    ORDER BY occurred_at ASC, id ASC
  LOOP
    v_next_state := data.punch_day_state_after(v_day_state, v_punch.punch_type);
    IF v_next_state IS NULL THEN
      v_status := 'unknown';
      EXIT;
    END IF;
    v_day_state := v_next_state;
  END LOOP;

  SELECT punch_type, occurred_at, pause_type
  INTO v_last
  FROM data.time_punches
  WHERE employee_id = p_employee_id
    AND (occurred_at AT TIME ZONE v_tz)::date = p_work_date
  ORDER BY occurred_at DESC, id DESC
  LIMIT 1;

  IF v_status IS NULL THEN
    v_status := CASE v_day_state
      WHEN 'off' THEN 'outside'
      WHEN 'day' THEN
        CASE
          WHEN data.is_mobile_work_profile(v_profile) AND NOT v_legacy THEN 'on_day'
          ELSE 'outside'
        END
      WHEN 'work' THEN 'working'
      WHEN 'break' THEN 'on_pause'
      WHEN 'travel' THEN 'traveling'
      ELSE 'unknown'
    END;
  END IF;

  v_active_pause_type := NULL;
  v_open_pause_since := NULL;

  IF v_status = 'on_pause' AND v_last.punch_type IS NOT NULL THEN
    v_active_pause_type := v_last.pause_type;
    v_open_pause_since := v_last.occurred_at;
  END IF;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'tenant_id', p_tenant_id,
    'work_date', p_work_date,
    'site_timezone', v_tz,
    'punches', v_punches,
    'last_punch_type', v_last.punch_type,
    'last_punch_at', v_last.occurred_at,
    'current_status', v_status,
    'active_pause_type', v_active_pause_type,
    'open_pause_since', v_open_pause_since,
    'work_profile', v_profile,
    'legacy_in_out_only', v_legacy,
    'day_state', v_day_state
  );
END;
$$;

REVOKE ALL ON FUNCTION api.employee_portal_get_day_punch_context(uuid, uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_portal_get_day_punch_context(uuid, uuid, date) TO service_role;

-- ─── Candidates for scan ─────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.list_employee_portal_punch_reminder_candidates()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'tenant_id', s.tenant_id,
        'employee_id', s.employee_id,
        'tenant_settings', COALESCE(t.settings, '{}'::jsonb)
      )
      ORDER BY s.tenant_id, s.employee_id
    ),
    '[]'::jsonb
  )
  FROM (
    SELECT DISTINCT ps.tenant_id, ps.employee_id
    FROM data.employee_portal_push_subscriptions ps
    JOIN data.employees e
      ON e.id = ps.employee_id
     AND e.tenant_id = ps.tenant_id
    WHERE e.status = 'active'
  ) s
  JOIN data.tenants t ON t.id = s.tenant_id;
$$;

REVOKE ALL ON FUNCTION api.list_employee_portal_punch_reminder_candidates() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_employee_portal_punch_reminder_candidates() TO service_role;

-- ─── Claim + enqueue ─────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.try_claim_employee_portal_punch_reminder(
  p_tenant_id     uuid,
  p_employee_id   uuid,
  p_work_date     date,
  p_reminder_kind text,
  p_max_per_day   integer DEFAULT 4
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_sent_today integer;
  v_kind       text := lower(btrim(COALESCE(p_reminder_kind, '')));
BEGIN
  IF p_tenant_id IS NULL OR p_employee_id IS NULL OR p_work_date IS NULL THEN
    RETURN false;
  END IF;

  IF v_kind NOT IN (
    'missing_entry',
    'missing_afternoon_entry',
    'missing_morning_exit',
    'missing_exit',
    'starting_soon',
    'afternoon_starting_soon'
  ) THEN
    RETURN false;
  END IF;

  SELECT COUNT(*)::integer
  INTO v_sent_today
  FROM data.employee_portal_punch_reminder_sent s
  WHERE s.employee_id = p_employee_id
    AND s.work_date = p_work_date;

  IF v_sent_today >= GREATEST(COALESCE(p_max_per_day, 4), 1) THEN
    RETURN false;
  END IF;

  INSERT INTO data.employee_portal_punch_reminder_sent (
    tenant_id,
    employee_id,
    work_date,
    reminder_kind
  )
  VALUES (
    p_tenant_id,
    p_employee_id,
    p_work_date,
    v_kind
  )
  ON CONFLICT (employee_id, work_date, reminder_kind) DO NOTHING;

  RETURN FOUND;
END;
$$;

REVOKE ALL ON FUNCTION api.try_claim_employee_portal_punch_reminder(uuid, uuid, date, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.try_claim_employee_portal_punch_reminder(uuid, uuid, date, text, integer) TO service_role;

CREATE OR REPLACE FUNCTION data.enqueue_employee_portal_punch_reminder(
  p_tenant_id     uuid,
  p_employee_id   uuid,
  p_work_date     date,
  p_reminder_kind text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_msg_id bigint;
  v_kind   text := lower(btrim(COALESCE(p_reminder_kind, '')));
BEGIN
  IF p_employee_id IS NULL OR p_tenant_id IS NULL OR p_work_date IS NULL THEN
    RETURN NULL;
  END IF;

  IF v_kind NOT IN (
    'missing_entry',
    'missing_afternoon_entry',
    'missing_morning_exit',
    'missing_exit',
    'starting_soon',
    'afternoon_starting_soon'
  ) THEN
    RETURN NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM data.employee_portal_push_subscriptions s
    WHERE s.employee_id = p_employee_id
      AND s.tenant_id = p_tenant_id
  ) THEN
    RETURN NULL;
  END IF;

  BEGIN
    SELECT pgmq.send(
      'employee_portal_push_queue',
      jsonb_build_object(
        'task', 'punch_reminder',
        'tenant_id', p_tenant_id,
        'employee_id', p_employee_id,
        'work_date', p_work_date,
        'reminder_kind', v_kind,
        'idempotency_key',
          format(
            'portal-punch-reminder-%s-%s-%s',
            p_employee_id,
            p_work_date,
            v_kind
          )
      )
    ) INTO v_msg_id;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'enqueue_employee_portal_punch_reminder failed: %', SQLERRM;
    RETURN NULL;
  END;

  RETURN v_msg_id;
END;
$$;

REVOKE ALL ON FUNCTION data.enqueue_employee_portal_punch_reminder(uuid, uuid, date, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.enqueue_employee_portal_punch_reminder(uuid, uuid, date, text) TO service_role;

CREATE OR REPLACE FUNCTION api.enqueue_employee_portal_punch_reminder(
  p_tenant_id     uuid,
  p_employee_id   uuid,
  p_work_date     date,
  p_reminder_kind text
)
RETURNS bigint
LANGUAGE sql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
  SELECT data.enqueue_employee_portal_punch_reminder(
    p_tenant_id,
    p_employee_id,
    p_work_date,
    p_reminder_kind
  );
$$;

REVOKE ALL ON FUNCTION api.enqueue_employee_portal_punch_reminder(uuid, uuid, date, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.enqueue_employee_portal_punch_reminder(uuid, uuid, date, text) TO service_role;

CREATE OR REPLACE FUNCTION api.release_employee_portal_punch_reminder_claim(
  p_employee_id   uuid,
  p_work_date     date,
  p_reminder_kind text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
BEGIN
  DELETE FROM data.employee_portal_punch_reminder_sent
  WHERE employee_id = p_employee_id
    AND work_date = p_work_date
    AND reminder_kind = lower(btrim(COALESCE(p_reminder_kind, '')));

  RETURN FOUND;
END;
$$;

REVOKE ALL ON FUNCTION api.release_employee_portal_punch_reminder_claim(uuid, date, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.release_employee_portal_punch_reminder_claim(uuid, date, text) TO service_role;

-- ─── Cron → scan Edge Function ───────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.invoke_employee_portal_punch_reminder_scan()
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public, extensions
AS $$
DECLARE
  v_supabase_url text;
  v_service_key  text;
  v_request_id   bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RAISE WARNING 'invoke_employee_portal_punch_reminder_scan: pg_net not installed. Skipping.';
    RETURN -2;
  END IF;

  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets WHERE name = 'app_supabase_url' LIMIT 1;

  SELECT decrypted_secret INTO v_service_key
  FROM vault.decrypted_secrets WHERE name = 'app_service_role_key' LIMIT 1;

  IF v_supabase_url IS NULL OR v_service_key IS NULL THEN
    RAISE WARNING 'invoke_employee_portal_punch_reminder_scan: vault secrets not configured. Skipping.';
    RETURN -1;
  END IF;

  BEGIN
    SELECT extensions.http_post(
      url := v_supabase_url || '/functions/v1/scan-employee-portal-punch-reminders',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || v_service_key
      ),
      body := '{}'::jsonb,
      timeout_milliseconds := 55000
    ) INTO v_request_id;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'invoke_employee_portal_punch_reminder_scan: http_post failed: %', SQLERRM;
    RETURN NULL;
  END;

  RETURN v_request_id;
END;
$$;

REVOKE ALL ON FUNCTION data.invoke_employee_portal_punch_reminder_scan() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.invoke_employee_portal_punch_reminder_scan() TO service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('scan-employee-portal-punch-reminders')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'scan-employee-portal-punch-reminders'
    );

    PERFORM cron.schedule(
      'scan-employee-portal-punch-reminders',
      '*/15 * * * *',
      'SELECT data.invoke_employee_portal_punch_reminder_scan()'
    );
  END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';

-- Settings registry (ACL tenant scope)
INSERT INTO data.settings_registry (setting_key, scope, required_permission, owner_only, is_active, description)
VALUES (
  'attendance_punch_reminders',
  'tenant',
  'settings.manage',
  false,
  true,
  'Portal employee punch reminder push configuration (Work Status Fase B)'
)
ON CONFLICT (setting_key) DO UPDATE SET
  scope = EXCLUDED.scope,
  required_permission = EXCLUDED.required_permission,
  is_active = EXCLUDED.is_active,
  description = EXCLUDED.description;
