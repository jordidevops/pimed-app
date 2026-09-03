-- EP-ACC-9d: manager access logs include metadata (e.g. document_id_last4).

CREATE OR REPLACE FUNCTION api.list_employee_portal_access_logs(
  p_token_id uuid,
  p_limit    integer DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_token record;
  v_rows jsonb;
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
BEGIN
  SELECT t.id, t.tenant_id, t.employee_id
  INTO v_token
  FROM data.employee_portal_tokens t
  WHERE t.id = p_token_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'token_not_found: %', p_token_id USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT data.jwt_has_permission(v_token.tenant_id, 'attendance.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.manage required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT COALESCE(jsonb_agg(row_to_json(l)::jsonb ORDER BY l.accessed_at DESC), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      l.id,
      l.token_id,
      l.employee_id,
      l.tenant_id,
      l.accessed_at,
      l.ip_address::text AS ip_address,
      l.user_agent,
      l.action,
      l.http_status,
      l.failure_reason,
      l.metadata
    FROM data.employee_portal_access_logs l
    WHERE l.token_id = p_token_id
    ORDER BY l.accessed_at DESC
    LIMIT v_limit
  ) l;

  RETURN v_rows;
END;
$$;
