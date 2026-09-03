-- Employee Portal EP4 — punch/today RPCs (service_role via Edge Function)

-- Expose pin_hash to service_role lookup (never to browser)
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
    'pin_required', (v_row.pin_hash IS NOT NULL),
    'pin_hash', v_row.pin_hash
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
    'pin_required', (v_row.pin_hash IS NOT NULL),
    'pin_hash', v_row.pin_hash
  );
END;
$$;

-- Fitxatges d'avui per al portal (Europe/Madrid)
CREATE OR REPLACE FUNCTION api.employee_portal_get_today(
  p_employee_id uuid,
  p_tenant_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp record;
  v_today date;
  v_punches jsonb;
  v_last record;
BEGIN
  SELECT e.id, e.tenant_id, e.status
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND e.tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  v_today := (now() AT TIME ZONE 'Europe/Madrid')::date;

  SELECT COALESCE(jsonb_agg(row_to_json(p)::jsonb ORDER BY p.occurred_at ASC, p.id ASC), '[]'::jsonb)
  INTO v_punches
  FROM (
    SELECT
      tp.id,
      tp.punch_type,
      tp.occurred_at,
      tp.received_at,
      tp.anomaly_codes,
      tp.source,
      tp.pause_type,
      tp.is_remote
    FROM data.time_punches tp
    WHERE tp.employee_id = p_employee_id
      AND (tp.occurred_at AT TIME ZONE 'Europe/Madrid')::date = v_today
    ORDER BY tp.occurred_at ASC, tp.id ASC
  ) p;

  SELECT punch_type, occurred_at
  INTO v_last
  FROM data.time_punches
  WHERE employee_id = p_employee_id
    AND (occurred_at AT TIME ZONE 'Europe/Madrid')::date = v_today
  ORDER BY occurred_at DESC, id DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'tenant_id', p_tenant_id,
    'work_date', v_today,
    'punches', v_punches,
    'last_punch_type', v_last.punch_type,
    'last_punch_at', v_last.occurred_at
  );
END;
$$;

REVOKE ALL ON FUNCTION api.employee_portal_get_today(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_portal_get_today(uuid, uuid) TO service_role;

NOTIFY pgrst, 'reload schema';
