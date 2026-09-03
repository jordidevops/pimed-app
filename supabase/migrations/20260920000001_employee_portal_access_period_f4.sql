-- Fase 4: access logs metadata + confirmacions per període al portal Accessos.

ALTER TABLE data.employee_portal_access_logs
  ADD COLUMN IF NOT EXISTS metadata jsonb;

ALTER TABLE data.employee_portal_access_logs
  DROP CONSTRAINT IF EXISTS employee_portal_access_logs_action_check;

ALTER TABLE data.employee_portal_access_logs
  ADD CONSTRAINT employee_portal_access_logs_action_check CHECK (action IN (
    'view_schedule',
    'view_history',
    'view_monthly_report',
    'monthly_confirm',
    'period_confirm',
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

DROP FUNCTION IF EXISTS api.log_employee_portal_access_event(
  uuid, uuid, uuid, text, smallint, text, inet, text
);

CREATE OR REPLACE FUNCTION api.log_employee_portal_access_event(
  p_token_id       uuid,
  p_employee_id    uuid,
  p_tenant_id      uuid,
  p_action         text,
  p_http_status    smallint DEFAULT NULL,
  p_failure_reason text DEFAULT NULL,
  p_ip_address     inet DEFAULT NULL,
  p_user_agent     text DEFAULT NULL,
  p_metadata       jsonb DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_site_id uuid;
  v_success boolean;
  v_is_first_employee_access boolean;
  v_token_label text;
BEGIN
  v_success := (p_http_status IS NULL OR p_http_status < 400);

  v_is_first_employee_access := (
    v_success
    AND p_action = 'session_create'
    AND NOT EXISTS (
      SELECT 1
      FROM data.employee_portal_access_logs l
      WHERE l.employee_id = p_employee_id
        AND l.action = 'session_create'
        AND (l.http_status IS NULL OR l.http_status < 400)
    )
  );

  INSERT INTO data.employee_portal_access_logs (
    token_id,
    employee_id,
    tenant_id,
    action,
    http_status,
    failure_reason,
    ip_address,
    user_agent,
    metadata
  ) VALUES (
    p_token_id,
    p_employee_id,
    p_tenant_id,
    p_action,
    p_http_status,
    NULLIF(btrim(p_failure_reason), ''),
    p_ip_address,
    NULLIF(btrim(p_user_agent), ''),
    NULLIF(p_metadata, '{}'::jsonb)
  );

  IF v_success THEN
    UPDATE data.employee_portal_tokens
    SET
      last_accessed_at = now(),
      first_accessed_at = COALESCE(first_accessed_at, now())
    WHERE id = p_token_id;

    IF v_is_first_employee_access THEN
      SELECT e.site_id INTO v_site_id
      FROM data.employees e
      WHERE e.id = p_employee_id;

      SELECT t.label INTO v_token_label
      FROM data.employee_portal_tokens t
      WHERE t.id = p_token_id;

      PERFORM data.log_audit_event(
        p_tenant_id,
        NULL,
        v_site_id,
        'EMPLOYEE_PORTAL_FIRST_ACCESS',
        'employee',
        p_employee_id,
        jsonb_build_object(
          'token_id', p_token_id,
          'label', v_token_label
        )
      );
    END IF;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION api.log_employee_portal_access_event(
  uuid, uuid, uuid, text, smallint, text, inet, text, jsonb
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.log_employee_portal_access_event(
  uuid, uuid, uuid, text, smallint, text, inet, text, jsonb
) TO service_role;

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
  v_logs jsonb;
  v_confirmations jsonb;
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
  INTO v_logs
  FROM (
    SELECT
      l.id,
      l.accessed_at,
      l.action,
      l.http_status,
      l.failure_reason,
      l.ip_address::text AS ip_address,
      l.metadata
    FROM data.employee_portal_access_logs l
    WHERE l.token_id = p_token_id
      AND l.employee_id = p_employee_id
    ORDER BY l.accessed_at DESC
    LIMIT v_limit
  ) l;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', c.id,
      'period_from', c.period_from,
      'period_to', c.period_to,
      'cycle_type', c.cycle_type,
      'calendar_year', c.calendar_year,
      'calendar_month', c.calendar_month,
      'confirmed_at', c.confirmed_at,
      'confirmed_via', c.confirmed_via
    )
    ORDER BY c.confirmed_at DESC
  ), '[]'::jsonb)
  INTO v_confirmations
  FROM (
    SELECT c.*
    FROM data.attendance_period_confirmations c
    WHERE c.employee_id = p_employee_id
      AND c.tenant_id = p_tenant_id
      AND c.confirmed_via = 'employee_portal'
    ORDER BY c.confirmed_at DESC
    LIMIT 20
  ) c;

  RETURN jsonb_build_object(
    'logs', v_logs,
    'period_confirmations', v_confirmations
  );
END;
$$;

REVOKE ALL ON FUNCTION api.employee_portal_get_access_logs(uuid, uuid, uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_portal_get_access_logs(uuid, uuid, uuid, integer) TO service_role;

NOTIFY pgrst, 'reload schema';
