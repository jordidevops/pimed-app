-- EP-ACC-9a: identity gate schema — identity_verified_at, DNI normalisation, grandfather backfill.

-- -----------------------------------------------------------------------------
-- 1. Schema
-- -----------------------------------------------------------------------------

ALTER TABLE data.employee_portal_tokens
  ADD COLUMN IF NOT EXISTS identity_verified_at timestamptz,
  ADD COLUMN IF NOT EXISTS identity_attempts smallint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS identity_locked_until timestamptz;

ALTER TABLE data.employee_portal_tokens
  DROP CONSTRAINT IF EXISTS employee_portal_tokens_identity_attempts_nonneg;

ALTER TABLE data.employee_portal_tokens
  ADD CONSTRAINT employee_portal_tokens_identity_attempts_nonneg
  CHECK (identity_attempts >= 0);

COMMENT ON COLUMN data.employee_portal_tokens.identity_verified_at IS
  'Quan l''empleat va confirmar la seva identitat (DNI/NIE) al primer accés del token personal.';
COMMENT ON COLUMN data.employee_portal_tokens.identity_attempts IS
  'Intents fallits de verificació de document d''identitat (rate limit per token).';
COMMENT ON COLUMN data.employee_portal_tokens.identity_locked_until IS
  'Bloqueig temporal després de massa intents de DNI incorrectes.';

-- Grandfather: tokens ja usats abans de la feature no exigeixen DNI de nou.
UPDATE data.employee_portal_tokens
SET identity_verified_at = COALESCE(identity_verified_at, first_accessed_at)
WHERE first_accessed_at IS NOT NULL
  AND identity_verified_at IS NULL;

-- -----------------------------------------------------------------------------
-- 2. Normalisation + comparison helpers
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.normalize_employee_document_id(p_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT NULLIF(
    upper(
      regexp_replace(btrim(COALESCE(p_value, '')), '[^[:alnum:]]', '', 'g')
    ),
    ''
  );
$$;

COMMENT ON FUNCTION api.normalize_employee_document_id(text) IS
  'Normalitza DNI/NIE/passaport: trim, majúscules, sense espais ni separadors.';

CREATE OR REPLACE FUNCTION api.employee_portal_document_id_matches(
  p_stored text,
  p_provided text
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT
    api.normalize_employee_document_id(p_stored) IS NOT NULL
    AND api.normalize_employee_document_id(p_provided) IS NOT NULL
    AND encode(
      extensions.digest(api.normalize_employee_document_id(p_stored), 'sha256'),
      'hex'
    ) = encode(
      extensions.digest(api.normalize_employee_document_id(p_provided), 'sha256'),
      'hex'
    );
$$;

COMMENT ON FUNCTION api.employee_portal_document_id_matches(text, text) IS
  'Comparació constant-time de documents normalitzats (hash SHA-256).';

CREATE OR REPLACE FUNCTION api.employee_portal_identity_required(
  p_shared_device boolean,
  p_identity_verified_at timestamptz
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT NOT COALESCE(p_shared_device, false)
     AND p_identity_verified_at IS NULL;
$$;

COMMENT ON FUNCTION api.employee_portal_identity_required(boolean, timestamptz) IS
  'True quan el token personal encara no ha verificat identitat.';

-- -----------------------------------------------------------------------------
-- 3. Access log actions (per EP-ACC-9b/9d)
-- -----------------------------------------------------------------------------

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
    'batch_start',
    'batch_fetch',
    'batch_ack',
    'identity_verify_failed',
    'identity_rejected',
    'identity_confirmed',
    'token_invalid',
    'token_expired',
    'session_create',
    'session_refresh'
  ));

-- -----------------------------------------------------------------------------
-- 4. Manager view
-- -----------------------------------------------------------------------------

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
    identity_verified_at,
    created_by_user_id,
    created_at,
    revoked_at,
    revoke_reason
  FROM data.employee_portal_tokens;

GRANT SELECT ON api.employee_portal_tokens TO authenticated;

-- -----------------------------------------------------------------------------
-- 5. Token lookup / session helpers (edge bootstrap)
-- -----------------------------------------------------------------------------

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
    t.identity_verified_at,
    t.identity_attempts,
    t.identity_locked_until,
    e.full_name,
    (e.document_id IS NOT NULL AND btrim(e.document_id) <> '') AS has_document_id
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
    'shared_device', v_row.shared_device,
    'identity_verified_at', v_row.identity_verified_at,
    'identity_attempts', v_row.identity_attempts,
    'identity_locked_until', v_row.identity_locked_until,
    'identity_required', api.employee_portal_identity_required(
      v_row.shared_device,
      v_row.identity_verified_at
    ),
    'has_document_id', v_row.has_document_id
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
    t.identity_verified_at,
    t.identity_attempts,
    t.identity_locked_until,
    e.full_name,
    (e.document_id IS NOT NULL AND btrim(e.document_id) <> '') AS has_document_id
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
    'shared_device', v_row.shared_device,
    'identity_verified_at', v_row.identity_verified_at,
    'identity_attempts', v_row.identity_attempts,
    'identity_locked_until', v_row.identity_locked_until,
    'identity_required', api.employee_portal_identity_required(
      v_row.shared_device,
      v_row.identity_verified_at
    ),
    'has_document_id', v_row.has_document_id
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 6. Grants
-- -----------------------------------------------------------------------------

REVOKE ALL ON FUNCTION api.normalize_employee_document_id(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.employee_portal_document_id_matches(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.employee_portal_identity_required(boolean, timestamptz) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.normalize_employee_document_id(text) TO service_role;
GRANT EXECUTE ON FUNCTION api.employee_portal_document_id_matches(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION api.employee_portal_identity_required(boolean, timestamptz) TO service_role;
