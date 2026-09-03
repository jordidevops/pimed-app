-- EP-ACC-4b: reset PIN per enllaç d'un sol ús (separat del secret /e/{secret}).

ALTER TABLE data.employee_portal_tokens
  DROP CONSTRAINT IF EXISTS employee_portal_tokens_pin_set_by_check;

ALTER TABLE data.employee_portal_tokens
  ADD CONSTRAINT employee_portal_tokens_pin_set_by_check
  CHECK (pin_set_by IS NULL OR pin_set_by IN ('employee', 'manager', 'reset'));

CREATE TABLE IF NOT EXISTS data.employee_portal_pin_reset_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_portal_token_id uuid NOT NULL REFERENCES data.employee_portal_tokens(id) ON DELETE CASCADE,
  reset_token_hash bytea NOT NULL,
  expires_at timestamptz NOT NULL,
  used_at timestamptz,
  revoked_at timestamptz,
  created_by uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employee_portal_pin_reset_tokens_hash_nonempty
    CHECK (reset_token_hash IS NOT NULL AND length(reset_token_hash) > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_employee_portal_pin_reset_hash
  ON data.employee_portal_pin_reset_tokens (reset_token_hash);

CREATE UNIQUE INDEX IF NOT EXISTS uq_employee_portal_pin_reset_one_pending
  ON data.employee_portal_pin_reset_tokens (employee_portal_token_id)
  WHERE used_at IS NULL AND revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_employee_portal_pin_reset_token
  ON data.employee_portal_pin_reset_tokens (employee_portal_token_id, created_at DESC);

COMMENT ON TABLE data.employee_portal_pin_reset_tokens IS
  'Enllaços d''un sol ús per restablir el PIN d''un token de portal. Secret independent de /e/{secret}.';

ALTER TABLE data.employee_portal_pin_reset_tokens ENABLE ROW LEVEL SECURITY;

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
    'pin_reset',
    'token_invalid',
    'token_expired',
    'session_create',
    'session_refresh'
  ));

CREATE OR REPLACE FUNCTION api.create_employee_portal_pin_reset(
  p_employee_portal_token_id uuid,
  p_reset_token_hash bytea
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_token record;
  v_reset_id uuid;
  v_expires_at timestamptz := now() + interval '30 minutes';
BEGIN
  IF p_reset_token_hash IS NULL OR length(p_reset_token_hash) = 0 THEN
    RAISE EXCEPTION 'invalid_reset_token_hash' USING ERRCODE = 'check_violation';
  END IF;

  SELECT
    t.id,
    t.tenant_id,
    t.employee_id,
    e.site_id,
    t.pin_hash,
    t.pin_must_set,
    t.is_active,
    t.revoked_at,
    t.expires_at
  INTO v_token
  FROM data.employee_portal_tokens t
  JOIN data.employees e ON e.id = t.employee_id
  WHERE t.id = p_employee_portal_token_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'token_not_found: %', p_employee_portal_token_id USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT data.jwt_has_permission(v_token.tenant_id, 'attendance.manage', v_token.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.manage required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT v_token.is_active OR v_token.revoked_at IS NOT NULL THEN
    RAISE EXCEPTION 'token_not_active' USING ERRCODE = 'check_violation';
  END IF;

  IF v_token.expires_at IS NOT NULL AND v_token.expires_at <= now() THEN
    RAISE EXCEPTION 'token_expired' USING ERRCODE = 'check_violation';
  END IF;

  IF v_token.pin_hash IS NULL AND NOT v_token.pin_must_set THEN
    RAISE EXCEPTION 'pin_not_configured' USING ERRCODE = 'check_violation';
  END IF;

  UPDATE data.employee_portal_pin_reset_tokens r
  SET revoked_at = now()
  WHERE r.employee_portal_token_id = p_employee_portal_token_id
    AND r.used_at IS NULL
    AND r.revoked_at IS NULL;

  INSERT INTO data.employee_portal_pin_reset_tokens (
    tenant_id,
    employee_portal_token_id,
    reset_token_hash,
    expires_at,
    created_by
  ) VALUES (
    v_token.tenant_id,
    p_employee_portal_token_id,
    p_reset_token_hash,
    v_expires_at,
    auth.uid()
  )
  RETURNING id INTO v_reset_id;

  RETURN jsonb_build_object(
    'reset_id', v_reset_id,
    'expires_at', v_expires_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.lookup_employee_portal_pin_reset_by_hash(p_reset_token_hash_hex text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_hash bytea;
  v_row record;
BEGIN
  IF p_reset_token_hash_hex IS NULL OR btrim(p_reset_token_hash_hex) = '' THEN
    RETURN NULL;
  END IF;

  v_hash := decode(regexp_replace(p_reset_token_hash_hex, '^\\x', ''), 'hex');

  SELECT
    r.id,
    r.tenant_id,
    r.employee_portal_token_id,
    r.expires_at,
    r.used_at,
    r.revoked_at,
    t.is_active AS portal_token_active,
    t.revoked_at AS portal_token_revoked_at,
    e.full_name
  INTO v_row
  FROM data.employee_portal_pin_reset_tokens r
  JOIN data.employee_portal_tokens t ON t.id = r.employee_portal_token_id
  JOIN data.employees e ON e.id = t.employee_id
  WHERE r.reset_token_hash = v_hash
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF v_row.used_at IS NOT NULL THEN
    RETURN jsonb_build_object('status', 'used');
  END IF;

  IF v_row.revoked_at IS NOT NULL THEN
    RETURN jsonb_build_object('status', 'revoked');
  END IF;

  IF v_row.expires_at <= now() THEN
    RETURN jsonb_build_object('status', 'expired', 'expires_at', v_row.expires_at);
  END IF;

  IF NOT v_row.portal_token_active OR v_row.portal_token_revoked_at IS NOT NULL THEN
    RETURN jsonb_build_object('status', 'portal_token_inactive');
  END IF;

  RETURN jsonb_build_object(
    'status', 'valid',
    'reset_id', v_row.id,
    'employee_portal_token_id', v_row.employee_portal_token_id,
    'tenant_id', v_row.tenant_id,
    'expires_at', v_row.expires_at,
    'employee_name', v_row.full_name
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.employee_portal_consume_pin_reset(
  p_reset_token_hash_hex text,
  p_new_pin_hash text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_hash bytea;
  v_reset record;
  v_token record;
BEGIN
  IF p_reset_token_hash_hex IS NULL OR btrim(p_reset_token_hash_hex) = ''
     OR p_new_pin_hash IS NULL OR btrim(p_new_pin_hash) = '' THEN
    RAISE EXCEPTION 'invalid_input' USING ERRCODE = 'check_violation';
  END IF;

  v_hash := decode(regexp_replace(p_reset_token_hash_hex, '^\\x', ''), 'hex');

  SELECT
    r.id,
    r.tenant_id,
    r.employee_portal_token_id,
    r.expires_at,
    r.used_at,
    r.revoked_at
  INTO v_reset
  FROM data.employee_portal_pin_reset_tokens r
  WHERE r.reset_token_hash = v_hash
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;

  IF v_reset.used_at IS NOT NULL THEN
    RETURN jsonb_build_object('status', 'used');
  END IF;

  IF v_reset.revoked_at IS NOT NULL THEN
    RETURN jsonb_build_object('status', 'revoked');
  END IF;

  IF v_reset.expires_at <= now() THEN
    RETURN jsonb_build_object('status', 'expired');
  END IF;

  UPDATE data.employee_portal_tokens t
  SET pin_hash = p_new_pin_hash,
      pin_must_set = false,
      pin_set_at = now(),
      pin_set_by = 'reset',
      pin_attempts = 0,
      pin_locked_until = NULL,
      session_version = t.session_version + 1
  WHERE t.id = v_reset.employee_portal_token_id
    AND t.is_active = true
    AND t.revoked_at IS NULL
    AND (t.expires_at IS NULL OR t.expires_at > now())
  RETURNING
    t.id,
    t.tenant_id,
    t.employee_id,
    t.session_version
  INTO v_token;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'portal_token_inactive');
  END IF;

  UPDATE data.employee_portal_pin_reset_tokens
  SET used_at = now()
  WHERE id = v_reset.id;

  RETURN (
    SELECT jsonb_build_object(
      'status', 'ok',
      'token_id', v_token.id,
      'tenant_id', v_token.tenant_id,
      'employee_id', v_token.employee_id,
      'employee_name', e.full_name
    )
    FROM data.employees e
    WHERE e.id = v_token.employee_id
  );
END;
$$;

REVOKE ALL ON FUNCTION api.create_employee_portal_pin_reset(uuid, bytea) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.lookup_employee_portal_pin_reset_by_hash(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.employee_portal_consume_pin_reset(text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.create_employee_portal_pin_reset(uuid, bytea) TO authenticated;
GRANT EXECUTE ON FUNCTION api.lookup_employee_portal_pin_reset_by_hash(text) TO service_role;
GRANT EXECUTE ON FUNCTION api.employee_portal_consume_pin_reset(text, text) TO service_role;
