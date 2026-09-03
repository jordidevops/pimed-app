-- Edge Functions no poden consultar data.* via PostgREST (schema data no exposat).
-- RPCs internes service_role per lookup i actualització de sessions de signatura.

CREATE OR REPLACE FUNCTION api.lookup_signing_session_by_token(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_session record;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT
    id,
    tenant_id,
    document_version_id,
    status,
    expires_at,
    signer_name,
    signer_email,
    signer_role,
    signing_type
  INTO v_session
  FROM data.document_signing_sessions
  WHERE signing_token = p_token
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'id',                  v_session.id,
    'tenant_id',           v_session.tenant_id,
    'document_version_id', v_session.document_version_id,
    'status',              v_session.status,
    'expires_at',          v_session.expires_at,
    'signer_name',         v_session.signer_name,
    'signer_email',        v_session.signer_email,
    'signer_role',         v_session.signer_role,
    'signing_type',        v_session.signing_type
  );
END;
$$;

REVOKE ALL ON FUNCTION api.lookup_signing_session_by_token(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.lookup_signing_session_by_token(text) FROM anon;
REVOKE ALL ON FUNCTION api.lookup_signing_session_by_token(text) FROM authenticated;
GRANT EXECUTE ON FUNCTION api.lookup_signing_session_by_token(text) TO service_role;

CREATE OR REPLACE FUNCTION api.update_signing_session_service(
  p_session_id   uuid,
  p_status       text    DEFAULT NULL,
  p_ip_address   text    DEFAULT NULL,
  p_user_agent   text    DEFAULT NULL,
  p_geolocation  jsonb   DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  UPDATE data.document_signing_sessions
     SET status      = COALESCE(p_status, status),
         ip_address  = COALESCE(p_ip_address::inet, ip_address),
         user_agent  = COALESCE(p_user_agent, user_agent),
         geolocation = COALESCE(p_geolocation, geolocation),
         updated_at  = now()
   WHERE id = p_session_id;
END;
$$;

REVOKE ALL ON FUNCTION api.update_signing_session_service(uuid, text, text, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.update_signing_session_service(uuid, text, text, text, jsonb) FROM anon;
REVOKE ALL ON FUNCTION api.update_signing_session_service(uuid, text, text, text, jsonb) FROM authenticated;
GRANT EXECUTE ON FUNCTION api.update_signing_session_service(uuid, text, text, text, jsonb) TO service_role;
