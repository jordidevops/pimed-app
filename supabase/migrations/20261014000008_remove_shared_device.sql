-- Remove shared_device (replaced by attendance stations ST-1…ST-4)

-- 1. Revoke legacy kiosk/taulell tokens
UPDATE data.employee_portal_tokens
SET is_active = false,
    revoked_at = now(),
    revoke_reason = 'shared_device_removed',
    session_version = session_version + 1
WHERE shared_device = true
  AND is_active = true
  AND revoked_at IS NULL;

-- 2. One active personal token per employee
DROP INDEX IF EXISTS data.uq_employee_portal_tokens_active_per_type;

WITH ranked AS (
  SELECT id,
         row_number() OVER (
           PARTITION BY employee_id
           ORDER BY created_at DESC, id DESC
         ) AS rn
  FROM data.employee_portal_tokens
  WHERE is_active AND revoked_at IS NULL
)
UPDATE data.employee_portal_tokens t
SET is_active = false,
    revoked_at = now(),
    revoke_reason = 'superseded',
    session_version = t.session_version + 1
FROM ranked r
WHERE t.id = r.id
  AND r.rn > 1;

CREATE UNIQUE INDEX IF NOT EXISTS uq_employee_portal_tokens_active_per_employee
  ON data.employee_portal_tokens (employee_id)
  WHERE is_active AND revoked_at IS NULL;

-- 3. Identity helper (no shared_device exempt)
DROP FUNCTION IF EXISTS api.employee_portal_identity_required(boolean, timestamptz);

CREATE OR REPLACE FUNCTION api.employee_portal_identity_required(
  p_identity_verified_at timestamptz
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT p_identity_verified_at IS NULL;
$$;

REVOKE ALL ON FUNCTION api.employee_portal_identity_required(timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_portal_identity_required(timestamptz) TO service_role;

-- 4. Token create (single type)
DROP FUNCTION IF EXISTS api._employee_portal_token_create_locked(uuid, uuid, bytea, text, text, boolean, timestamptz, boolean);
DROP FUNCTION IF EXISTS api.create_employee_portal_token(uuid, bytea, text, text, timestamptz, boolean, boolean);

CREATE OR REPLACE FUNCTION api._employee_portal_token_create_locked(
  p_employee_id    uuid,
  p_tenant_id      uuid,
  p_token_hash     bytea,
  p_label          text DEFAULT NULL,
  p_pin_hash       text DEFAULT NULL,
  p_pin_must_set   boolean DEFAULT false,
  p_expires_at     timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_token_id uuid;
  v_superseded_id uuid;
BEGIN
  IF p_token_hash IS NULL OR length(p_token_hash) = 0 THEN
    RAISE EXCEPTION 'invalid_token_hash' USING ERRCODE = 'check_violation';
  END IF;

  UPDATE data.employee_portal_tokens t
  SET is_active = false,
      revoked_at = now(),
      revoke_reason = 'superseded',
      session_version = t.session_version + 1
  WHERE t.employee_id = p_employee_id
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
    created_by_user_id
  ) VALUES (
    p_tenant_id,
    p_employee_id,
    p_token_hash,
    p_pin_hash,
    COALESCE(p_pin_must_set, false),
    CASE WHEN p_pin_hash IS NOT NULL THEN now() ELSE NULL END,
    CASE WHEN p_pin_hash IS NOT NULL THEN 'manager' ELSE NULL END,
    p_expires_at,
    NULLIF(btrim(p_label), ''),
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

CREATE OR REPLACE FUNCTION api.create_employee_portal_token(
  p_employee_id   uuid,
  p_token_hash    bytea,
  p_label         text DEFAULT NULL,
  p_pin_hash      text DEFAULT NULL,
  p_expires_at    timestamptz DEFAULT NULL,
  p_pin_must_set  boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp record;
  v_pin_must_set boolean := false;
  v_settings jsonb;
BEGIN
  SELECT e.id, e.tenant_id, e.site_id, e.status, e.document_id
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

  IF api.normalize_employee_document_id(v_emp.document_id) IS NULL THEN
    RAISE EXCEPTION 'employee_missing_document_id' USING ERRCODE = 'check_violation';
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

  RETURN api._employee_portal_token_create_locked(
    p_employee_id   => v_emp.id,
    p_tenant_id     => v_emp.tenant_id,
    p_token_hash    => p_token_hash,
    p_label         => p_label,
    p_pin_hash      => p_pin_hash,
    p_pin_must_set  => v_pin_must_set,
    p_expires_at    => p_expires_at
  );
END;
$$;

REVOKE ALL ON FUNCTION api._employee_portal_token_create_locked(uuid, uuid, bytea, text, text, boolean, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api._employee_portal_token_create_locked(uuid, uuid, bytea, text, text, boolean, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION api.create_employee_portal_token(uuid, bytea, text, text, timestamptz, boolean) TO authenticated, service_role;

-- 5. Session lookup helpers
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
    'identity_verified_at', v_row.identity_verified_at,
    'identity_attempts', v_row.identity_attempts,
    'identity_locked_until', v_row.identity_locked_until,
    'identity_required', api.employee_portal_identity_required(v_row.identity_verified_at),
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
    'identity_verified_at', v_row.identity_verified_at,
    'identity_attempts', v_row.identity_attempts,
    'identity_locked_until', v_row.identity_locked_until,
    'identity_required', api.employee_portal_identity_required(v_row.identity_verified_at),
    'has_document_id', v_row.has_document_id
  );
END;
$$;

-- 6. Public policy (drop idle timeout for shared devices)
CREATE OR REPLACE FUNCTION api.get_employee_portal_public_policy(p_employee_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp      record;
  v_settings jsonb;
BEGIN
  SELECT e.id, e.tenant_id, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  v_settings := data.merge_effective_settings_for_service(v_emp.tenant_id, v_emp.site_id);

  RETURN jsonb_build_object(
    'default_pin_required',
      COALESCE((v_settings->>'employee_portal.default_pin_required')::boolean, true)
  );
END;
$$;

-- 7. Batch fetch/list without shared_device
CREATE OR REPLACE FUNCTION api.fetch_employee_portal_token_batch_results(p_batch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_job record;
  v_rows jsonb;
  v_audit_token uuid;
  v_audit_employee uuid;
BEGIN
  SELECT * INTO v_job
  FROM data.employee_portal_token_batch_jobs j
  WHERE j.id = p_batch_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'batch_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT (
    v_job.created_by = auth.uid()
    OR data.jwt_has_permission(v_job.tenant_id, 'attendance.manage', NULL)
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.manage required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_job.status = 'expired' OR v_job.expires_at <= now() THEN
    RAISE EXCEPTION 'batch_expired' USING ERRCODE = 'check_violation';
  END IF;

  IF v_job.status IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'batch_not_completed' USING ERRCODE = 'check_violation';
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'employee_id', i.employee_id,
      'employee_name', i.employee_name,
      'employee_code', i.employee_code,
      'status', i.status,
      'error_code', i.error_code,
      'portal_url', CASE WHEN i.status = 'created' THEN i.portal_url ELSE NULL END,
      'secret', CASE WHEN i.status = 'created' THEN i.secret_plaintext ELSE NULL END,
      'token_id', i.token_id,
      'superseded_token_id', i.superseded_token_id,
      'label', i.label
    )
    ORDER BY i.employee_name NULLS LAST, i.employee_id
  )
  INTO v_rows
  FROM data.employee_portal_token_batch_items i
  WHERE i.batch_job_id = p_batch_id;

  UPDATE data.employee_portal_token_batch_jobs
  SET last_fetched_at = now(),
      fetch_count = fetch_count + 1
  WHERE id = p_batch_id;

  SELECT i.token_id, i.employee_id
  INTO v_audit_token, v_audit_employee
  FROM data.employee_portal_token_batch_items i
  WHERE i.batch_job_id = p_batch_id
    AND i.status = 'created'
    AND i.token_id IS NOT NULL
  ORDER BY i.created_at ASC
  LIMIT 1;

  IF v_audit_token IS NOT NULL THEN
    INSERT INTO data.employee_portal_access_logs (
      token_id, employee_id, tenant_id, action, metadata
    ) VALUES (
      v_audit_token,
      v_audit_employee,
      v_job.tenant_id,
      'batch_fetch',
      jsonb_build_object(
        'batch_job_id', p_batch_id,
        'fetch_count', v_job.fetch_count + 1
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'batch_id', p_batch_id,
    'expires_at', v_job.expires_at,
    'rows', COALESCE(v_rows, '[]'::jsonb)
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.list_employee_portal_token_batches(p_limit int DEFAULT 10)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_rows jsonb;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'check_violation';
  END IF;

  IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.manage', NULL) THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.manage required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT jsonb_agg(row_to_json(s)::jsonb ORDER BY s.created_at DESC)
  INTO v_rows
  FROM (
    SELECT
      j.id AS batch_id,
      j.status,
      j.expires_at,
      j.label,
      j.employee_count,
      j.created_count,
      j.skipped_count,
      j.error_count,
      j.created_at
    FROM data.employee_portal_token_batch_jobs j
    WHERE j.tenant_id = v_tenant_id
    ORDER BY j.created_at DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 10), 1), 50)
  ) s;

  RETURN jsonb_build_object('batches', COALESCE(v_rows, '[]'::jsonb));
END;
$$;

-- Identity + pin RPCs (no shared_device exempt)
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
    WHEN v_row.pin_hash IS NULL AND v_row.pin_must_set THEN 'pin_setup'
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

  IF api.employee_portal_identity_required(v_row.identity_verified_at) THEN
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
    t.pin_locked_until
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

DROP FUNCTION IF EXISTS api.start_employee_portal_token_batch(text, uuid[], boolean, boolean, text, boolean, boolean);

CREATE OR REPLACE FUNCTION api.start_employee_portal_token_batch(
  p_idempotency_key text,
  p_employee_ids    uuid[],
  p_pin_must_set    boolean DEFAULT NULL,
  p_label           text DEFAULT NULL,
  p_skip_inactive   boolean DEFAULT true,
  p_force_new       boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, extensions, public
AS $$
DECLARE
  v_tenant_id uuid;
  v_active_tenant uuid := data.active_tenant_id();
  v_existing record;
  v_job_id uuid;
  v_expires_at timestamptz;
  v_default_pin_must_set boolean := true;
  v_pin_must_set boolean;
  v_employee_id uuid;
  v_emp record;
  v_site jsonb;
  v_secret text;
  v_token_hash bytea;
  v_create jsonb;
  v_portal_url text;
  v_item_label text;
  v_created int := 0;
  v_skipped int := 0;
  v_errors int := 0;
  v_requested int;
  v_first_audit_token uuid;
  v_first_audit_employee uuid;
  v_settings jsonb;
  v_deduped uuid[];
BEGIN
  IF p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) < 8
     OR char_length(btrim(p_idempotency_key)) > 128 THEN
    RAISE EXCEPTION 'invalid_idempotency_key' USING ERRCODE = 'check_violation';
  END IF;

  IF p_employee_ids IS NULL OR array_length(p_employee_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'batch_empty' USING ERRCODE = 'check_violation';
  END IF;

  SELECT array_agg(x ORDER BY x) INTO v_deduped
  FROM (SELECT DISTINCT unnest(p_employee_ids) AS x) s;

  v_requested := coalesce(array_length(v_deduped, 1), 0);
  IF v_requested < 1 OR v_requested > 100 THEN
    RAISE EXCEPTION 'batch_invalid_size' USING ERRCODE = 'check_violation';
  END IF;

  SELECT e.tenant_id INTO v_tenant_id FROM data.employees e WHERE e.id = v_deduped[1];
  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF EXISTS (
    SELECT 1 FROM unnest(v_deduped) AS emp_id
    LEFT JOIN data.employees e ON e.id = emp_id
    WHERE e.id IS NULL OR e.tenant_id IS DISTINCT FROM v_tenant_id
  ) THEN
    RAISE EXCEPTION 'batch_invalid_employees' USING ERRCODE = 'check_violation';
  END IF;

  IF v_active_tenant IS NOT NULL AND v_active_tenant IS DISTINCT FROM v_tenant_id THEN
    RAISE EXCEPTION 'tenant_mismatch' USING ERRCODE = 'check_violation';
  END IF;

  IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.manage', NULL) THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.manage required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT j.id, j.status, j.expires_at, j.employee_count, j.created_count, j.skipped_count, j.error_count
  INTO v_existing
  FROM data.employee_portal_token_batch_jobs j
  WHERE j.tenant_id = v_tenant_id AND j.idempotency_key = btrim(p_idempotency_key)
  LIMIT 1;

  IF FOUND THEN
    IF v_existing.status IN ('pending', 'processing', 'completed') AND v_existing.expires_at > now() THEN
      RETURN jsonb_build_object(
        'batch_id', v_existing.id,
        'status', v_existing.status,
        'expires_at', v_existing.expires_at,
        'summary', jsonb_build_object(
          'requested', v_existing.employee_count,
          'created', v_existing.created_count,
          'skipped', v_existing.skipped_count,
          'errors', v_existing.error_count
        ),
        'idempotent_replay', true
      );
    END IF;
    IF NOT COALESCE(p_force_new, false) THEN
      RAISE EXCEPTION 'idempotency_key_exhausted: use force_new to start a new batch'
        USING ERRCODE = 'check_violation';
    END IF;
    DELETE FROM data.employee_portal_token_batch_jobs WHERE id = v_existing.id;
  END IF;

  PERFORM api._employee_portal_assert_batch_rate_limit(v_tenant_id);

  v_expires_at := now() + interval '1 hour';
  v_item_label := NULLIF(btrim(p_label), '');
  v_settings := data.merge_effective_settings_for_service(v_tenant_id, NULL);
  v_default_pin_must_set := COALESCE((v_settings->>'employee_portal.default_pin_required')::boolean, true);
  v_pin_must_set := COALESCE(p_pin_must_set, v_default_pin_must_set);

  INSERT INTO data.employee_portal_token_batch_jobs (
    tenant_id, created_by, idempotency_key, status, pin_must_set, label, expires_at, employee_count
  ) VALUES (
    v_tenant_id, auth.uid(), btrim(p_idempotency_key), 'processing',
    v_pin_must_set, v_item_label, v_expires_at, v_requested
  )
  RETURNING id INTO v_job_id;

  FOREACH v_employee_id IN ARRAY v_deduped LOOP
  BEGIN
    SELECT e.id, e.tenant_id, e.site_id, e.status, e.full_name, e.document_id
    INTO v_emp FROM data.employees e WHERE e.id = v_employee_id FOR UPDATE;

    IF NOT FOUND THEN
      INSERT INTO data.employee_portal_token_batch_items (
        batch_job_id, tenant_id, employee_id, status, error_code, label
      ) VALUES (v_job_id, v_tenant_id, v_employee_id, 'error', 'employee_not_found', v_item_label);
      v_errors := v_errors + 1;
      CONTINUE;
    END IF;

    IF v_emp.status IS DISTINCT FROM 'active' THEN
      IF COALESCE(p_skip_inactive, true) THEN
        INSERT INTO data.employee_portal_token_batch_items (
          batch_job_id, tenant_id, employee_id, status, error_code, employee_name, employee_code, label
        ) VALUES (v_job_id, v_tenant_id, v_emp.id, 'skipped', 'employee_not_active', v_emp.full_name, v_emp.document_id, v_item_label);
        v_skipped := v_skipped + 1;
      ELSE
        INSERT INTO data.employee_portal_token_batch_items (
          batch_job_id, tenant_id, employee_id, status, error_code, employee_name, employee_code, label
        ) VALUES (v_job_id, v_tenant_id, v_emp.id, 'error', 'employee_not_active', v_emp.full_name, v_emp.document_id, v_item_label);
        v_errors := v_errors + 1;
      END IF;
      CONTINUE;
    END IF;

    IF api.normalize_employee_document_id(v_emp.document_id) IS NULL THEN
      INSERT INTO data.employee_portal_token_batch_items (
        batch_job_id, tenant_id, employee_id, status, error_code, employee_name, employee_code, label
      ) VALUES (v_job_id, v_tenant_id, v_emp.id, 'skipped', 'employee_missing_document_id', v_emp.full_name, v_emp.document_id, v_item_label);
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.manage', v_emp.site_id) THEN
      INSERT INTO data.employee_portal_token_batch_items (
        batch_job_id, tenant_id, employee_id, status, error_code, employee_name, employee_code, label
      ) VALUES (v_job_id, v_tenant_id, v_emp.id, 'error', 'insufficient_privilege', v_emp.full_name, v_emp.document_id, v_item_label);
      v_errors := v_errors + 1;
      CONTINUE;
    END IF;

    v_site := api.resolve_public_site_for_employee(v_emp.id);
    IF NOT COALESCE((v_site ->> 'site_configured')::boolean, false) THEN
      INSERT INTO data.employee_portal_token_batch_items (
        batch_job_id, tenant_id, employee_id, status, error_code, employee_name, employee_code, label
      ) VALUES (v_job_id, v_tenant_id, v_emp.id, 'error', 'no_published_public_site', v_emp.full_name, v_emp.document_id, v_item_label);
      v_errors := v_errors + 1;
      CONTINUE;
    END IF;

    v_secret := api._employee_portal_generate_secret();
    v_token_hash := api._employee_portal_secret_hash_bytea(v_secret);
    v_create := api._employee_portal_token_create_locked(
      p_employee_id => v_emp.id,
      p_tenant_id => v_emp.tenant_id,
      p_token_hash => v_token_hash,
      p_label => v_item_label,
      p_pin_hash => NULL,
      p_pin_must_set => v_pin_must_set,
      p_expires_at => NULL
    );
    v_portal_url := api._employee_portal_build_bootstrap_url(v_site, v_secret);

    INSERT INTO data.employee_portal_token_batch_items (
      batch_job_id, tenant_id, employee_id, status, token_id, superseded_token_id,
      secret_plaintext, portal_url, employee_name, employee_code, label
    ) VALUES (
      v_job_id, v_tenant_id, v_emp.id, 'created',
      (v_create ->> 'token_id')::uuid,
      NULLIF(v_create ->> 'superseded_token_id', '')::uuid,
      v_secret, v_portal_url, v_emp.full_name, v_emp.document_id, v_item_label
    );
    v_created := v_created + 1;
    IF v_first_audit_token IS NULL THEN
      v_first_audit_token := (v_create ->> 'token_id')::uuid;
      v_first_audit_employee := v_emp.id;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO data.employee_portal_token_batch_items (
      batch_job_id, tenant_id, employee_id, status, error_code, employee_name, employee_code, label
    ) VALUES (v_job_id, v_tenant_id, v_employee_id, 'error', 'unexpected_error', v_emp.full_name, v_emp.document_id, v_item_label);
    v_errors := v_errors + 1;
  END;
  END LOOP;

  UPDATE data.employee_portal_token_batch_jobs
  SET status = CASE WHEN v_created > 0 THEN 'completed' ELSE 'failed' END,
      created_count = v_created,
      skipped_count = v_skipped,
      error_count = v_errors,
      completed_at = now(),
      error_message = CASE WHEN v_created = 0 THEN 'no_tokens_created' ELSE NULL END
  WHERE id = v_job_id;

  IF v_first_audit_token IS NOT NULL THEN
    INSERT INTO data.employee_portal_access_logs (token_id, employee_id, tenant_id, action, metadata)
    VALUES (v_first_audit_token, v_first_audit_employee, v_tenant_id, 'batch_start',
      jsonb_build_object('batch_job_id', v_job_id, 'employee_count', v_requested,
        'created_count', v_created, 'skipped_count', v_skipped, 'error_count', v_errors));
  END IF;

  RETURN jsonb_build_object(
    'batch_id', v_job_id,
    'status', CASE WHEN v_created > 0 THEN 'completed' ELSE 'failed' END,
    'expires_at', v_expires_at,
    'summary', jsonb_build_object('requested', v_requested, 'created', v_created, 'skipped', v_skipped, 'errors', v_errors),
    'idempotent_replay', false
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.start_employee_portal_token_batch(text, uuid[], boolean, text, boolean, boolean) TO authenticated, service_role;

-- 8. Manager view + drop columns
DROP VIEW IF EXISTS api.employee_portal_tokens;

ALTER TABLE data.employee_portal_token_batch_jobs
  DROP COLUMN IF EXISTS shared_device;

ALTER TABLE data.employee_portal_tokens
  DROP COLUMN IF EXISTS shared_device;

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
    first_accessed_at,
    last_accessed_at,
    identity_verified_at,
    created_by_user_id,
    created_at,
    revoked_at,
    revoke_reason
  FROM data.employee_portal_tokens;

GRANT SELECT ON api.employee_portal_tokens TO authenticated;
