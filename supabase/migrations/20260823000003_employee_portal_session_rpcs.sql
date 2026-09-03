-- Employee Portal — RPCs internes per employee-portal-api (service_role)
-- PostgREST només exposa schema api; les Edge Functions no poden fer .from() sobre data.*

CREATE OR REPLACE FUNCTION api.lookup_employee_portal_token_by_hash(p_token_hash bytea)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_row record;
BEGIN
  IF p_token_hash IS NULL OR length(p_token_hash) = 0 THEN
    RETURN NULL;
  END IF;

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
    e.full_name
  INTO v_row
  FROM data.employee_portal_tokens t
  JOIN data.employees e ON e.id = t.employee_id
  WHERE t.token_hash = p_token_hash
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
    'pin_required', (v_row.pin_hash IS NOT NULL)
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
    'pin_required', (v_row.pin_hash IS NOT NULL)
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.log_employee_portal_access_event(
  p_token_id       uuid,
  p_employee_id    uuid,
  p_tenant_id      uuid,
  p_action         text,
  p_http_status    smallint DEFAULT NULL,
  p_failure_reason text DEFAULT NULL,
  p_ip_address     inet DEFAULT NULL,
  p_user_agent     text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
BEGIN
  INSERT INTO data.employee_portal_access_logs (
    token_id,
    employee_id,
    tenant_id,
    action,
    http_status,
    failure_reason,
    ip_address,
    user_agent
  ) VALUES (
    p_token_id,
    p_employee_id,
    p_tenant_id,
    p_action,
    p_http_status,
    NULLIF(btrim(p_failure_reason), ''),
    p_ip_address,
    NULLIF(btrim(p_user_agent), '')
  );

  IF p_http_status IS NULL OR p_http_status < 400 THEN
    UPDATE data.employee_portal_tokens
    SET last_accessed_at = now()
    WHERE id = p_token_id;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION api.revoke_employee_portal_token_system(
  p_token_id    uuid,
  p_compromised boolean DEFAULT false
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_updated integer;
BEGIN
  UPDATE data.employee_portal_tokens
  SET
    is_active = false,
    revoked_at = now(),
    compromised = COALESCE(p_compromised, false),
    session_version = session_version + 1
  WHERE id = p_token_id
    AND is_active = true
    AND revoked_at IS NULL;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated > 0;
END;
$$;

REVOKE ALL ON FUNCTION api.lookup_employee_portal_token_by_hash(bytea) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_employee_portal_token_session(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.log_employee_portal_access_event(uuid, uuid, uuid, text, smallint, text, inet, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.revoke_employee_portal_token_system(uuid, boolean) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.lookup_employee_portal_token_by_hash(bytea) TO service_role;
GRANT EXECUTE ON FUNCTION api.get_employee_portal_token_session(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION api.log_employee_portal_access_event(uuid, uuid, uuid, text, smallint, text, inet, text) TO service_role;
GRANT EXECUTE ON FUNCTION api.revoke_employee_portal_token_system(uuid, boolean) TO service_role;

NOTIFY pgrst, 'reload schema';
