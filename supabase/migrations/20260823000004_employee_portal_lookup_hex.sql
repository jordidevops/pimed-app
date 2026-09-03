-- PostgREST bytea encoding is brittle; accept hex text from Edge Functions.

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
    'pin_required', (v_row.pin_hash IS NOT NULL)
  );
END;
$$;

DROP FUNCTION IF EXISTS api.lookup_employee_portal_token_by_hash(bytea);

REVOKE ALL ON FUNCTION api.lookup_employee_portal_token_by_hash(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.lookup_employee_portal_token_by_hash(text) TO service_role;

NOTIFY pgrst, 'reload schema';
