-- EP9: pauses, sol·licitud absències, access logs empleat, web push subscriptions

ALTER TABLE data.employee_portal_access_logs
  DROP CONSTRAINT IF EXISTS employee_portal_access_logs_action_check;

ALTER TABLE data.employee_portal_access_logs
  ADD CONSTRAINT employee_portal_access_logs_action_check CHECK (action IN (
    'view_schedule',
    'view_history',
    'view_monthly_report',
    'monthly_confirm',
    'view_access_logs',
    'request_absence',
    'push_subscribe',
    'punch_in',
    'punch_out',
    'pause_start',
    'pause_end',
    'pin_failed',
    'token_invalid',
    'token_expired',
    'session_create',
    'session_refresh'
  ));

-- ─── Push subscriptions (web push per token) ─────────────────────────────────

CREATE TABLE IF NOT EXISTS data.employee_portal_push_subscriptions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  token_id     uuid NOT NULL REFERENCES data.employee_portal_tokens(id) ON DELETE CASCADE,
  employee_id  uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  tenant_id    uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  endpoint     text NOT NULL,
  p256dh       text NOT NULL,
  auth         text NOT NULL,
  user_agent   text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (token_id, endpoint)
);

CREATE INDEX IF NOT EXISTS idx_ep_push_sub_employee
  ON data.employee_portal_push_subscriptions (employee_id, updated_at DESC);

ALTER TABLE data.employee_portal_push_subscriptions ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE, DELETE ON data.employee_portal_push_subscriptions TO service_role;

-- ─── Pause configs per al portal ─────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.employee_portal_get_pause_configs(
  p_employee_id uuid,
  p_tenant_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_rows jsonb;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM data.employees e
    WHERE e.id = p_employee_id AND e.tenant_id = p_tenant_id
  ) THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT COALESCE(jsonb_agg(row_to_json(c)::jsonb ORDER BY c.sort_order, c.key), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      pc.id,
      pc.key,
      pc.label_i18n,
      pc.counts_as_work,
      pc.max_duration_minutes,
      pc.sort_order
    FROM data.tenant_pause_configs pc
    WHERE pc.tenant_id = p_tenant_id
      AND pc.is_active = true
    ORDER BY pc.sort_order, pc.key
  ) c;

  RETURN v_rows;
END;
$$;

REVOKE ALL ON FUNCTION api.employee_portal_get_pause_configs(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_portal_get_pause_configs(uuid, uuid) TO service_role;

-- ─── Today ampliat amb estat pausa ───────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.employee_portal_get_today(
  p_employee_id uuid,
  p_tenant_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp record;
  v_today date;
  v_punches jsonb;
  v_last record;
  v_status text;
  v_active_pause_type text;
  v_open_pause_since timestamptz;
BEGIN
  SELECT e.id, e.tenant_id, e.status
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND e.tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  v_today := (now() AT TIME ZONE 'Europe/Madrid')::date;

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
      AND (tp.occurred_at AT TIME ZONE 'Europe/Madrid')::date = v_today
    ORDER BY tp.occurred_at ASC, tp.id ASC
  ) p;

  SELECT punch_type, occurred_at, pause_type
  INTO v_last
  FROM data.time_punches
  WHERE employee_id = p_employee_id
    AND (occurred_at AT TIME ZONE 'Europe/Madrid')::date = v_today
  ORDER BY occurred_at DESC, id DESC
  LIMIT 1;

  v_status := 'outside';
  v_active_pause_type := NULL;
  v_open_pause_since := NULL;

  IF v_last.punch_type IS NOT NULL THEN
    CASE v_last.punch_type
      WHEN 'in' THEN
        v_status := 'working';
      WHEN 'break_start' THEN
        v_status := 'on_pause';
        v_active_pause_type := v_last.pause_type;
        v_open_pause_since := v_last.occurred_at;
      WHEN 'break_end' THEN
        v_status := 'working';
      WHEN 'out' THEN
        v_status := 'outside';
      ELSE
        v_status := 'unknown';
    END CASE;
  END IF;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'tenant_id', p_tenant_id,
    'work_date', v_today,
    'punches', v_punches,
    'last_punch_type', v_last.punch_type,
    'last_punch_at', v_last.occurred_at,
    'current_status', v_status,
    'active_pause_type', v_active_pause_type,
    'open_pause_since', v_open_pause_since
  );
END;
$$;

-- ─── Tipus d'absència sol·licitables ─────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.employee_portal_get_absence_types(
  p_employee_id uuid,
  p_tenant_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_rows jsonb;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM data.employees e
    WHERE e.id = p_employee_id AND e.tenant_id = p_tenant_id
  ) THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT COALESCE(jsonb_agg(row_to_json(t)::jsonb ORDER BY t.sort_order, t.absence_type), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT DISTINCT ON (absence_type)
      c.id,
      c.absence_type,
      c.name_i18n,
      c.counts_as_worked,
      c.requires_approval,
      c.requires_document,
      c.max_days_per_year,
      c.is_partial,
      c.sort_order
    FROM data.tenant_absence_type_configs c
    WHERE c.is_active = true
      AND c.is_it = false
      AND (
        c.tenant_id = p_tenant_id
        OR (c.tenant_id IS NULL AND c.is_system = true)
      )
    ORDER BY absence_type, (c.tenant_id IS NOT NULL) DESC, c.sort_order
  ) t;

  RETURN v_rows;
END;
$$;

REVOKE ALL ON FUNCTION api.employee_portal_get_absence_types(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_portal_get_absence_types(uuid, uuid) TO service_role;

-- ─── Llistat absències de l'empleat ──────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.employee_portal_list_absences(
  p_employee_id uuid,
  p_tenant_id   uuid,
  p_limit       integer DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_rows jsonb;
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM data.employees e
    WHERE e.id = p_employee_id AND e.tenant_id = p_tenant_id
  ) THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT COALESCE(jsonb_agg(row_to_json(a)::jsonb ORDER BY a.start_date DESC), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      ea.id,
      ea.absence_type,
      ea.start_date,
      ea.end_date,
      ea.status,
      ea.notes,
      ea.partial_start_time,
      ea.partial_end_time,
      ea.created_at
    FROM data.employee_absences ea
    WHERE ea.employee_id = p_employee_id
      AND ea.tenant_id = p_tenant_id
    ORDER BY ea.start_date DESC
    LIMIT v_limit
  ) a;

  RETURN v_rows;
END;
$$;

REVOKE ALL ON FUNCTION api.employee_portal_list_absences(uuid, uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_portal_list_absences(uuid, uuid, integer) TO service_role;

-- ─── Sol·licitar absència (sense auth.users) ─────────────────────────────────

CREATE OR REPLACE FUNCTION api.employee_portal_request_absence(
  p_employee_id        uuid,
  p_tenant_id          uuid,
  p_absence_type       text,
  p_start_date         date,
  p_end_date           date,
  p_notes              text    DEFAULT NULL,
  p_partial_start_time time    DEFAULT NULL,
  p_partial_end_time   time    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp           record;
  v_type_cfg      record;
  v_absence_id    uuid;
  v_workflow      text;
  v_init_status   text := 'requested';
BEGIN
  SELECT e.tenant_id, e.site_id, e.id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND e.tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT DISTINCT ON (absence_type) *
  INTO v_type_cfg
  FROM data.tenant_absence_type_configs
  WHERE absence_type = p_absence_type
    AND is_active = true
    AND (tenant_id = v_emp.tenant_id OR (tenant_id IS NULL AND is_system = true))
  ORDER BY absence_type, (tenant_id IS NOT NULL) DESC;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid_absence_type: %', p_absence_type
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_type_cfg.is_it THEN
    RAISE EXCEPTION 'use_register_it: les baixes IT no es poden sol·licitar des del portal';
  END IF;

  IF p_end_date < p_start_date THEN
    RAISE EXCEPTION 'invalid_date_range: end_date ha de ser >= start_date';
  END IF;

  IF EXISTS (
    SELECT 1 FROM data.employee_absences
    WHERE employee_id = p_employee_id
      AND status IN ('approved', 'requested', 'active')
      AND start_date <= p_end_date
      AND end_date >= p_start_date
  ) THEN
    RAISE EXCEPTION 'absence_overlap: ja existeix una absència que se solapa'
      USING ERRCODE = 'exclusion_violation';
  END IF;

  SELECT COALESCE(
    (data.merge_effective_settings_for_service(v_emp.tenant_id, v_emp.site_id)
      ->> 'attendance_default_absence_workflow'),
    'require_approval'
  ) INTO v_workflow;

  IF v_workflow = 'auto_approve' OR NOT v_type_cfg.requires_approval THEN
    v_init_status := 'approved';
  END IF;

  INSERT INTO data.employee_absences (
    tenant_id, site_id, employee_id,
    absence_type, start_date, end_date,
    status, is_paid, notes,
    partial_start_time, partial_end_time,
    counts_as_worked, affects_entitlement, entitlement_type,
    requested_by,
    reviewed_by, reviewed_at
  ) VALUES (
    v_emp.tenant_id, v_emp.site_id, p_employee_id,
    p_absence_type, p_start_date, p_end_date,
    v_init_status,
    v_type_cfg.counts_as_worked,
    p_notes,
    p_partial_start_time, p_partial_end_time,
    v_type_cfg.counts_as_worked,
    v_type_cfg.affects_entitlement,
    v_type_cfg.entitlement_type,
    NULL,
    CASE WHEN v_init_status = 'approved' THEN NULL ELSE NULL END,
    CASE WHEN v_init_status = 'approved' THEN now() ELSE NULL END
  )
  RETURNING id INTO v_absence_id;

  RETURN jsonb_build_object(
    'absence_id', v_absence_id,
    'status', v_init_status,
    'employee_id', p_employee_id,
    'start_date', p_start_date,
    'end_date', p_end_date
  );
END;
$$;

REVOKE ALL ON FUNCTION api.employee_portal_request_absence(
  uuid, uuid, text, date, date, text, time, time
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_portal_request_absence(
  uuid, uuid, text, date, date, text, time, time
) TO service_role;

-- ─── Access logs visibles per l'empleat (token actual) ───────────────────────

CREATE OR REPLACE FUNCTION api.employee_portal_get_access_logs(
  p_employee_id uuid,
  p_tenant_id   uuid,
  p_token_id    uuid,
  p_limit       integer DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_rows jsonb;
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM data.employee_portal_tokens t
    WHERE t.id = p_token_id
      AND t.employee_id = p_employee_id
      AND t.tenant_id = p_tenant_id
  ) THEN
    RAISE EXCEPTION 'token_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT COALESCE(jsonb_agg(row_to_json(l)::jsonb ORDER BY l.accessed_at DESC), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      l.id,
      l.accessed_at,
      l.action,
      l.http_status,
      l.failure_reason,
      l.ip_address::text AS ip_address
    FROM data.employee_portal_access_logs l
    WHERE l.token_id = p_token_id
      AND l.employee_id = p_employee_id
    ORDER BY l.accessed_at DESC
    LIMIT v_limit
  ) l;

  RETURN v_rows;
END;
$$;

REVOKE ALL ON FUNCTION api.employee_portal_get_access_logs(uuid, uuid, uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_portal_get_access_logs(uuid, uuid, uuid, integer) TO service_role;

-- ─── Web push subscription ───────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.employee_portal_upsert_push_subscription(
  p_employee_id uuid,
  p_tenant_id   uuid,
  p_token_id    uuid,
  p_endpoint    text,
  p_p256dh      text,
  p_auth        text,
  p_user_agent  text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM data.employee_portal_tokens t
    WHERE t.id = p_token_id
      AND t.employee_id = p_employee_id
      AND t.tenant_id = p_tenant_id
      AND t.is_active = true
      AND t.revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'token_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF p_endpoint IS NULL OR btrim(p_endpoint) = '' THEN
    RAISE EXCEPTION 'missing_endpoint';
  END IF;

  INSERT INTO data.employee_portal_push_subscriptions (
    token_id, employee_id, tenant_id,
    endpoint, p256dh, auth, user_agent, updated_at
  ) VALUES (
    p_token_id, p_employee_id, p_tenant_id,
    p_endpoint, p_p256dh, p_auth, p_user_agent, now()
  )
  ON CONFLICT (token_id, endpoint) DO UPDATE SET
    p256dh = EXCLUDED.p256dh,
    auth = EXCLUDED.auth,
    user_agent = EXCLUDED.user_agent,
    updated_at = now()
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('subscription_id', v_id, 'saved', true);
END;
$$;

REVOKE ALL ON FUNCTION api.employee_portal_upsert_push_subscription(
  uuid, uuid, uuid, text, text, text, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_portal_upsert_push_subscription(
  uuid, uuid, uuid, text, text, text, text
) TO service_role;

NOTIFY pgrst, 'reload schema';
