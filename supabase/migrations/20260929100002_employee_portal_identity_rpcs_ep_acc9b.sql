-- EP-ACC-9b: identity verify/confirm RPCs, pin_setup gate, challenge window.

-- -----------------------------------------------------------------------------
-- 1. Challenge window (verify → confirm within 15 min)
-- -----------------------------------------------------------------------------

ALTER TABLE data.employee_portal_tokens
  ADD COLUMN IF NOT EXISTS identity_challenge_at timestamptz;

COMMENT ON COLUMN data.employee_portal_tokens.identity_challenge_at IS
  'DNI verificat correctament; cal confirmar identitat abans de caducar.';

-- -----------------------------------------------------------------------------
-- 2. Verify document
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.employee_portal_verify_identity_document(
  p_token_hash_hex text,
  p_document_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_hash bytea;
  v_row record;
  v_attempts int;
  v_locked_until timestamptz;
  v_threshold constant int := 5;
  v_lock_minutes constant int := 15;
  v_challenge_ttl constant interval := make_interval(mins => 15);
BEGIN
  IF p_token_hash_hex IS NULL OR btrim(p_token_hash_hex) = '' THEN
    RETURN jsonb_build_object('status', 'token_invalid');
  END IF;

  IF p_document_id IS NULL OR btrim(p_document_id) = '' THEN
    RETURN jsonb_build_object('status', 'mismatch');
  END IF;

  v_hash := decode(regexp_replace(p_token_hash_hex, '^\\x', ''), 'hex');

  SELECT
    t.id,
    t.tenant_id,
    t.employee_id,
    t.is_active,
    t.revoked_at,
    t.expires_at,
    t.shared_device,
    t.identity_verified_at,
    t.identity_attempts,
    t.identity_locked_until,
    e.full_name,
    e.document_id AS employee_document_id,
    (e.document_id IS NOT NULL AND btrim(e.document_id) <> '') AS has_document_id
  INTO v_row
  FROM data.employee_portal_tokens t
  JOIN data.employees e ON e.id = t.employee_id
  WHERE t.token_hash = v_hash
  FOR UPDATE OF t;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'token_invalid');
  END IF;

  IF NOT v_row.is_active
     OR v_row.revoked_at IS NOT NULL
     OR (v_row.expires_at IS NOT NULL AND v_row.expires_at <= now()) THEN
    RETURN jsonb_build_object('status', 'token_invalid');
  END IF;

  IF COALESCE(v_row.shared_device, false) THEN
    RETURN jsonb_build_object('status', 'match', 'full_name', v_row.full_name);
  END IF;

  IF v_row.identity_verified_at IS NOT NULL THEN
    RETURN jsonb_build_object(
      'status', 'match',
      'full_name', v_row.full_name,
      'already_verified', true
    );
  END IF;

  IF NOT v_row.has_document_id THEN
    RETURN jsonb_build_object('status', 'identity_not_configured');
  END IF;

  IF v_row.identity_locked_until IS NOT NULL AND v_row.identity_locked_until <= now() THEN
    UPDATE data.employee_portal_tokens
    SET identity_attempts = 0,
        identity_locked_until = NULL
    WHERE id = v_row.id;
    v_row.identity_attempts := 0;
    v_row.identity_locked_until := NULL;
  END IF;

  IF v_row.identity_locked_until IS NOT NULL AND v_row.identity_locked_until > now() THEN
    RETURN jsonb_build_object(
      'status', 'identity_locked',
      'identity_attempts', v_row.identity_attempts,
      'token_id', v_row.id,
      'tenant_id', v_row.tenant_id,
      'employee_id', v_row.employee_id,
      'retry_after_seconds', GREATEST(
        1,
        CEIL(EXTRACT(EPOCH FROM (v_row.identity_locked_until - now())))::int
      )
    );
  END IF;

  IF api.employee_portal_document_id_matches(v_row.employee_document_id, p_document_id) THEN
    UPDATE data.employee_portal_tokens
    SET identity_attempts = 0,
        identity_locked_until = NULL,
        identity_challenge_at = now()
    WHERE id = v_row.id;

    RETURN jsonb_build_object(
      'status', 'match',
      'full_name', v_row.full_name,
      'token_id', v_row.id,
      'tenant_id', v_row.tenant_id,
      'employee_id', v_row.employee_id
    );
  END IF;

  v_attempts := v_row.identity_attempts + 1;
  v_locked_until := NULL;

  IF v_attempts >= v_threshold THEN
    v_locked_until := now() + make_interval(mins => v_lock_minutes);
    v_attempts := v_threshold;
  END IF;

  UPDATE data.employee_portal_tokens
  SET identity_attempts = v_attempts,
      identity_locked_until = v_locked_until,
      identity_challenge_at = NULL
  WHERE id = v_row.id;

  IF v_locked_until IS NOT NULL THEN
    RETURN jsonb_build_object(
      'status', 'identity_locked',
      'identity_attempts', v_attempts,
      'token_id', v_row.id,
      'tenant_id', v_row.tenant_id,
      'employee_id', v_row.employee_id,
      'retry_after_seconds', GREATEST(
        1,
        CEIL(EXTRACT(EPOCH FROM (v_locked_until - now())))::int
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'status', 'mismatch',
    'identity_attempts', v_attempts,
    'token_id', v_row.id,
    'tenant_id', v_row.tenant_id,
    'employee_id', v_row.employee_id
  );
END;
$$;

COMMENT ON FUNCTION api.employee_portal_verify_identity_document(text, text) IS
  'Verifica DNI/NIE del token personal; rate limit 5/15min; estableix identity_challenge_at si coincideix.';

-- -----------------------------------------------------------------------------
-- 3. Confirm identity
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.employee_portal_confirm_identity(p_token_hash_hex text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_hash bytea;
  v_row record;
  v_next text;
  v_challenge_ttl constant interval := make_interval(mins => 15);
BEGIN
  IF p_token_hash_hex IS NULL OR btrim(p_token_hash_hex) = '' THEN
    RETURN jsonb_build_object('status', 'token_invalid');
  END IF;

  v_hash := decode(regexp_replace(p_token_hash_hex, '^\\x', ''), 'hex');

  SELECT
    t.id,
    t.tenant_id,
    t.employee_id,
    t.is_active,
    t.revoked_at,
    t.expires_at,
    t.shared_device,
    t.identity_verified_at,
    t.identity_challenge_at,
    t.pin_hash,
    t.pin_must_set,
    e.full_name,
    (e.document_id IS NOT NULL AND btrim(e.document_id) <> '') AS has_document_id
  INTO v_row
  FROM data.employee_portal_tokens t
  JOIN data.employees e ON e.id = t.employee_id
  WHERE t.token_hash = v_hash
  FOR UPDATE OF t;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'token_invalid');
  END IF;

  IF NOT v_row.is_active
     OR v_row.revoked_at IS NOT NULL
     OR (v_row.expires_at IS NOT NULL AND v_row.expires_at <= now()) THEN
    RETURN jsonb_build_object('status', 'token_invalid');
  END IF;

  IF COALESCE(v_row.shared_device, false) THEN
    v_next := CASE
      WHEN v_row.pin_must_set OR v_row.pin_hash IS NULL THEN 'pin_setup'
      WHEN v_row.pin_hash IS NOT NULL THEN 'pin'
      ELSE 'ready'
    END;
    RETURN jsonb_build_object(
      'status', 'ok',
      'next', v_next,
      'full_name', v_row.full_name,
      'token_id', v_row.id,
      'tenant_id', v_row.tenant_id,
      'employee_id', v_row.employee_id
    );
  END IF;

  IF NOT v_row.has_document_id THEN
    RETURN jsonb_build_object('status', 'identity_not_configured');
  END IF;

  IF v_row.identity_verified_at IS NULL THEN
    IF v_row.identity_challenge_at IS NULL
       OR v_row.identity_challenge_at < now() - v_challenge_ttl THEN
      RETURN jsonb_build_object('status', 'identity_challenge_required');
    END IF;

    UPDATE data.employee_portal_tokens
    SET identity_verified_at = now(),
        identity_challenge_at = NULL,
        identity_attempts = 0,
        identity_locked_until = NULL
    WHERE id = v_row.id;

    v_row.identity_verified_at := now();
  END IF;

  v_next := CASE
    WHEN v_row.pin_must_set OR v_row.pin_hash IS NULL THEN 'pin_setup'
    WHEN v_row.pin_hash IS NOT NULL THEN 'pin'
    ELSE 'ready'
  END;

  RETURN jsonb_build_object(
    'status', 'ok',
    'next', v_next,
    'full_name', v_row.full_name,
    'token_id', v_row.id,
    'tenant_id', v_row.tenant_id,
    'employee_id', v_row.employee_id
  );
END;
$$;

COMMENT ON FUNCTION api.employee_portal_confirm_identity(text) IS
  'Confirma identitat després de verify; retorna next pin_setup|pin|ready.';

-- -----------------------------------------------------------------------------
-- 4. Clear identity challenge (reject flow)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.employee_portal_clear_identity_challenge(p_token_hash_hex text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_hash bytea;
  v_token_id uuid;
BEGIN
  IF p_token_hash_hex IS NULL OR btrim(p_token_hash_hex) = '' THEN
    RETURN jsonb_build_object('status', 'token_invalid');
  END IF;

  v_hash := decode(regexp_replace(p_token_hash_hex, '^\\x', ''), 'hex');

  UPDATE data.employee_portal_tokens t
  SET identity_challenge_at = NULL
  WHERE t.token_hash = v_hash
    AND t.is_active = true
    AND t.revoked_at IS NULL
    AND (t.expires_at IS NULL OR t.expires_at > now())
  RETURNING t.id INTO v_token_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'token_invalid');
  END IF;

  RETURN jsonb_build_object('status', 'ok', 'token_id', v_token_id);
END;
$$;

-- -----------------------------------------------------------------------------
-- 5. Pin setup — block without identity
-- -----------------------------------------------------------------------------

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
  v_identity_required boolean;
BEGIN
  IF p_token_hash_hex IS NULL OR btrim(p_token_hash_hex) = ''
     OR p_pin_hash IS NULL OR btrim(p_pin_hash) = '' THEN
    RAISE EXCEPTION 'invalid_input' USING ERRCODE = 'check_violation';
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
    t.identity_verified_at
  INTO v_row
  FROM data.employee_portal_tokens t
  WHERE t.token_hash = v_hash
  LIMIT 1;

  IF NOT FOUND
     OR NOT v_row.is_active
     OR v_row.revoked_at IS NOT NULL
     OR (v_row.expires_at IS NOT NULL AND v_row.expires_at <= now()) THEN
    RETURN jsonb_build_object('status', 'token_invalid');
  END IF;

  v_identity_required := api.employee_portal_identity_required(
    v_row.shared_device,
    v_row.identity_verified_at
  );

  IF v_identity_required THEN
    RETURN jsonb_build_object('status', 'identity_required');
  END IF;

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

-- -----------------------------------------------------------------------------
-- 6. Grants
-- -----------------------------------------------------------------------------

REVOKE ALL ON FUNCTION api.employee_portal_verify_identity_document(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.employee_portal_confirm_identity(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.employee_portal_clear_identity_challenge(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.employee_portal_verify_identity_document(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION api.employee_portal_confirm_identity(text) TO service_role;
GRANT EXECUTE ON FUNCTION api.employee_portal_clear_identity_challenge(text) TO service_role;
