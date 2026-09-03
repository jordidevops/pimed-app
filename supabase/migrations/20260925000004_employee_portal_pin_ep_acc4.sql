-- EP-ACC-4 + EP-ACC-4a: PIN empleat (mode B) + lockout atòmic.

ALTER TABLE data.employee_portal_tokens
  ADD COLUMN IF NOT EXISTS pin_must_set boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS pin_set_at timestamptz,
  ADD COLUMN IF NOT EXISTS pin_set_by text;

ALTER TABLE data.employee_portal_tokens
  DROP CONSTRAINT IF EXISTS employee_portal_tokens_pin_set_by_check;

ALTER TABLE data.employee_portal_tokens
  ADD CONSTRAINT employee_portal_tokens_pin_set_by_check
  CHECK (pin_set_by IS NULL OR pin_set_by IN ('employee', 'manager'));

COMMENT ON COLUMN data.employee_portal_tokens.pin_must_set IS
  'L''empleat ha de definir el PIN al primer accés (mode B).';
COMMENT ON COLUMN data.employee_portal_tokens.pin_set_at IS
  'Quan es va establir o canviar el PIN per última vegada.';
COMMENT ON COLUMN data.employee_portal_tokens.pin_set_by IS
  'Qui va establir el PIN: employee o manager (legacy).';

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
    'pin_locked',
    'pin_setup',
    'pin_changed',
    'token_invalid',
    'token_expired',
    'session_create',
    'session_refresh'
  ));

DROP VIEW IF EXISTS api.employee_portal_tokens;

CREATE VIEW api.employee_portal_tokens
  WITH (security_invoker = true)
AS
  SELECT
    id,
    tenant_id,
    employee_id,
    (pin_hash IS NOT NULL OR pin_must_set) AS pin_required,
    pin_must_set,
    pin_set_at,
    pin_set_by,
    pin_attempts,
    pin_locked_until,
    session_version,
    compromised,
    expires_at,
    is_active,
    label,
    shared_device,
    first_accessed_at,
    last_accessed_at,
    created_by_user_id,
    created_at,
    revoked_at,
    revoke_reason
  FROM data.employee_portal_tokens;

GRANT SELECT ON api.employee_portal_tokens TO authenticated;

CREATE OR REPLACE FUNCTION api.lookup_employee_portal_token_by_hash(p_token_hash_hex text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_hash bytea;
  v_row record;
BEGIN
  IF p_token_hash_hex IS NULL OR btrim(p_token_hash_hex) = '' THEN
    RETURN NULL;
  END IF;

  v_hash := decode(regexp_replace(p_token_hash_hex, '^\\x', ''), 'hex');

  SELECT
    t.id,
    t.tenant_id,
    t.employee_id,
    t.session_version,
    t.is_active,
    t.revoked_at,
    t.expires_at,
    t.compromised,
    t.pin_hash,
    t.pin_must_set,
    t.pin_attempts,
    t.pin_locked_until,
    t.shared_device,
    e.full_name
  INTO v_row
  FROM data.employee_portal_tokens t
  JOIN data.employees e ON e.id = t.employee_id
  WHERE t.token_hash = v_hash
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'token_id', v_row.id,
    'tenant_id', v_row.tenant_id,
    'employee_id', v_row.employee_id,
    'full_name', v_row.full_name,
    'session_version', v_row.session_version,
    'is_active', v_row.is_active,
    'revoked_at', v_row.revoked_at,
    'expires_at', v_row.expires_at,
    'compromised', v_row.compromised,
    'pin_required', (v_row.pin_hash IS NOT NULL OR v_row.pin_must_set),
    'pin_must_set', v_row.pin_must_set,
    'pin_attempts', v_row.pin_attempts,
    'pin_locked_until', v_row.pin_locked_until,
    'pin_hash', v_row.pin_hash,
    'shared_device', v_row.shared_device
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.get_employee_portal_token_session(p_token_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_row record;
BEGIN
  SELECT
    t.id,
    t.tenant_id,
    t.employee_id,
    t.session_version,
    t.is_active,
    t.revoked_at,
    t.expires_at,
    t.compromised,
    t.pin_hash,
    t.pin_must_set,
    t.pin_attempts,
    t.pin_locked_until,
    t.shared_device,
    e.full_name
  INTO v_row
  FROM data.employee_portal_tokens t
  JOIN data.employees e ON e.id = t.employee_id
  WHERE t.id = p_token_id
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'token_id', v_row.id,
    'tenant_id', v_row.tenant_id,
    'employee_id', v_row.employee_id,
    'full_name', v_row.full_name,
    'session_version', v_row.session_version,
    'is_active', v_row.is_active,
    'revoked_at', v_row.revoked_at,
    'expires_at', v_row.expires_at,
    'compromised', v_row.compromised,
    'pin_required', (v_row.pin_hash IS NOT NULL OR v_row.pin_must_set),
    'pin_must_set', v_row.pin_must_set,
    'pin_attempts', v_row.pin_attempts,
    'pin_locked_until', v_row.pin_locked_until,
    'pin_hash', v_row.pin_hash,
    'shared_device', v_row.shared_device
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.employee_portal_attempt_pin(
  p_token_id uuid,
  p_pin_hash text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_row record;
  v_attempts int;
  v_locked_until timestamptz;
  v_threshold constant int := 5;
  v_lock_minutes constant int := 15;
BEGIN
  SELECT
    t.id,
    t.tenant_id,
    t.employee_id,
    t.pin_hash,
    t.pin_must_set,
    t.pin_attempts,
    t.pin_locked_until
  INTO v_row
  FROM data.employee_portal_tokens t
  WHERE t.id = p_token_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'invalid_token');
  END IF;

  IF v_row.pin_must_set OR v_row.pin_hash IS NULL THEN
    RETURN jsonb_build_object('status', 'not_required');
  END IF;

  IF v_row.pin_locked_until IS NOT NULL AND v_row.pin_locked_until <= now() THEN
    UPDATE data.employee_portal_tokens
    SET pin_attempts = 0,
        pin_locked_until = NULL
    WHERE id = p_token_id;
    v_row.pin_attempts := 0;
    v_row.pin_locked_until := NULL;
  END IF;

  IF v_row.pin_locked_until IS NOT NULL AND v_row.pin_locked_until > now() THEN
    RETURN jsonb_build_object(
      'status', 'locked',
      'pin_attempts', v_row.pin_attempts,
      'retry_after_seconds', GREATEST(
        1,
        CEIL(EXTRACT(EPOCH FROM (v_row.pin_locked_until - now())))::int
      )
    );
  END IF;

  IF v_row.pin_hash = p_pin_hash THEN
    UPDATE data.employee_portal_tokens
    SET pin_attempts = 0,
        pin_locked_until = NULL
    WHERE id = p_token_id;

    RETURN jsonb_build_object('status', 'ok', 'pin_attempts', 0);
  END IF;

  v_attempts := v_row.pin_attempts + 1;
  v_locked_until := NULL;

  IF v_attempts >= v_threshold THEN
    v_locked_until := now() + make_interval(mins => v_lock_minutes);
    v_attempts := v_threshold;
  END IF;

  UPDATE data.employee_portal_tokens
  SET pin_attempts = v_attempts,
      pin_locked_until = v_locked_until
  WHERE id = p_token_id;

  IF v_locked_until IS NOT NULL THEN
    RETURN jsonb_build_object(
      'status', 'locked',
      'pin_attempts', v_attempts,
      'retry_after_seconds', GREATEST(
        1,
        CEIL(EXTRACT(EPOCH FROM (v_locked_until - now())))::int
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'status', 'invalid',
    'pin_attempts', v_attempts
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.employee_portal_setup_pin(
  p_token_hash_hex text,
  p_pin_hash text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_hash bytea;
  v_row record;
BEGIN
  IF p_token_hash_hex IS NULL OR btrim(p_token_hash_hex) = ''
     OR p_pin_hash IS NULL OR btrim(p_pin_hash) = '' THEN
    RAISE EXCEPTION 'invalid_input' USING ERRCODE = 'check_violation';
  END IF;

  v_hash := decode(regexp_replace(p_token_hash_hex, '^\\x', ''), 'hex');

  UPDATE data.employee_portal_tokens t
  SET pin_hash = p_pin_hash,
      pin_must_set = false,
      pin_set_at = now(),
      pin_set_by = 'employee',
      pin_attempts = 0,
      pin_locked_until = NULL
  WHERE t.token_hash = v_hash
    AND t.pin_must_set = true
    AND t.pin_hash IS NULL
    AND t.is_active = true
    AND t.revoked_at IS NULL
    AND (t.expires_at IS NULL OR t.expires_at > now())
  RETURNING
    t.id,
    t.tenant_id,
    t.employee_id,
    t.session_version,
    t.is_active,
    t.revoked_at,
    t.expires_at,
    t.compromised,
    t.pin_hash,
    t.pin_must_set,
    t.pin_attempts,
    t.pin_locked_until,
    t.shared_device
  INTO v_row;

  IF FOUND THEN
  RETURN (
    SELECT jsonb_build_object(
      'status', 'ok',
      'token_id', v_row.id,
      'tenant_id', v_row.tenant_id,
      'employee_id', v_row.employee_id,
      'session_version', v_row.session_version,
      'is_active', v_row.is_active,
      'revoked_at', v_row.revoked_at,
      'expires_at', v_row.expires_at,
      'compromised', v_row.compromised,
      'pin_required', true,
      'pin_must_set', false,
      'pin_attempts', 0,
      'pin_locked_until', NULL,
      'pin_hash', v_row.pin_hash,
      'shared_device', v_row.shared_device,
      'full_name', e.full_name
    )
    FROM data.employees e
    WHERE e.id = v_row.employee_id
  );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM data.employee_portal_tokens t
    WHERE t.token_hash = v_hash
      AND t.pin_hash IS NOT NULL
  ) THEN
    RETURN jsonb_build_object('status', 'pin_already_set');
  END IF;

  RETURN jsonb_build_object('status', 'token_invalid');
END;
$$;

CREATE OR REPLACE FUNCTION api.employee_portal_change_pin(
  p_token_id uuid,
  p_new_pin_hash text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_row record;
BEGIN
  IF p_new_pin_hash IS NULL OR btrim(p_new_pin_hash) = '' THEN
    RAISE EXCEPTION 'invalid_input' USING ERRCODE = 'check_violation';
  END IF;

  UPDATE data.employee_portal_tokens t
  SET pin_hash = p_new_pin_hash,
      pin_set_at = now(),
      pin_set_by = 'employee',
      pin_attempts = 0,
      pin_locked_until = NULL
  WHERE t.id = p_token_id
    AND t.pin_hash IS NOT NULL
    AND t.pin_must_set = false
    AND t.is_active = true
    AND t.revoked_at IS NULL
  RETURNING
    t.id,
    t.tenant_id,
    t.employee_id,
    t.session_version,
    t.is_active,
    t.revoked_at,
    t.expires_at,
    t.compromised,
    t.pin_hash,
    t.pin_must_set,
    t.pin_attempts,
    t.pin_locked_until,
    t.shared_device
  INTO v_row;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'token_invalid');
  END IF;

  RETURN (
    SELECT jsonb_build_object(
      'status', 'ok',
      'token_id', v_row.id,
      'tenant_id', v_row.tenant_id,
      'employee_id', v_row.employee_id,
      'session_version', v_row.session_version,
      'is_active', v_row.is_active,
      'revoked_at', v_row.revoked_at,
      'expires_at', v_row.expires_at,
      'compromised', v_row.compromised,
      'pin_required', true,
      'pin_must_set', false,
      'pin_attempts', 0,
      'pin_locked_until', NULL,
      'pin_hash', v_row.pin_hash,
      'shared_device', v_row.shared_device,
      'full_name', e.full_name
    )
    FROM data.employees e
    WHERE e.id = v_row.employee_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.create_employee_portal_token(
  p_employee_id   uuid,
  p_token_hash    bytea,
  p_label         text DEFAULT NULL,
  p_pin_hash      text DEFAULT NULL,
  p_expires_at    timestamptz DEFAULT NULL,
  p_shared_device boolean DEFAULT false,
  p_pin_must_set  boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp record;
  v_token_id uuid;
  v_superseded_id uuid;
  v_shared boolean := COALESCE(p_shared_device, false);
  v_pin_must_set boolean := false;
  v_settings jsonb;
BEGIN
  IF p_token_hash IS NULL OR length(p_token_hash) = 0 THEN
    RAISE EXCEPTION 'invalid_token_hash' USING ERRCODE = 'check_violation';
  END IF;

  SELECT e.id, e.tenant_id, e.site_id, e.status
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id USING ERRCODE = 'no_data_found';
  END IF;

  IF v_emp.status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'employee_not_active' USING ERRCODE = 'check_violation';
  END IF;

  IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.manage', v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.manage required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_pin_hash IS NOT NULL THEN
    v_pin_must_set := false;
  ELSIF p_pin_must_set IS NOT NULL THEN
    v_pin_must_set := p_pin_must_set;
  ELSE
    v_settings := data.merge_effective_settings_for_service(v_emp.tenant_id, v_emp.site_id);
    v_pin_must_set := COALESCE(
      (v_settings->>'employee_portal.default_pin_required')::boolean,
      true
    );
  END IF;

  UPDATE data.employee_portal_tokens t
  SET is_active = false,
      revoked_at = now(),
      revoke_reason = 'superseded',
      session_version = t.session_version + 1
  WHERE t.employee_id = p_employee_id
    AND t.shared_device = v_shared
    AND t.is_active = true
    AND t.revoked_at IS NULL
  RETURNING t.id INTO v_superseded_id;

  INSERT INTO data.employee_portal_tokens (
    tenant_id,
    employee_id,
    token_hash,
    pin_hash,
    pin_must_set,
    pin_set_at,
    pin_set_by,
    expires_at,
    label,
    shared_device,
    created_by_user_id
  ) VALUES (
    v_emp.tenant_id,
    v_emp.id,
    p_token_hash,
    p_pin_hash,
    v_pin_must_set,
    CASE WHEN p_pin_hash IS NOT NULL THEN now() ELSE NULL END,
    CASE WHEN p_pin_hash IS NOT NULL THEN 'manager' ELSE NULL END,
    p_expires_at,
    NULLIF(btrim(p_label), ''),
    v_shared,
    auth.uid()
  )
  RETURNING id INTO v_token_id;

  RETURN jsonb_build_object(
    'token_id', v_token_id,
    'superseded_token_id', v_superseded_id
  );
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'duplicate_active_label'
      USING ERRCODE = 'unique_violation',
            DETAIL = 'Ja existeix un token permanent actiu amb aquesta etiqueta per l''empleat.';
END;
$$;

REVOKE ALL ON FUNCTION api.employee_portal_attempt_pin(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.employee_portal_setup_pin(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.employee_portal_change_pin(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.employee_portal_attempt_pin(uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION api.employee_portal_setup_pin(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION api.employee_portal_change_pin(uuid, text) TO service_role;
