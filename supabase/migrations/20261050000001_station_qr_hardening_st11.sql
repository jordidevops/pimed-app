-- =============================================================================
-- ST-11 — Hardening QR (decisió #12): entropia mínima + rate limit al resolve RPC
-- EX-01.4 ja tenia assert + Edge; aquí tanquem el contracte al servidor SQL.
-- =============================================================================

-- ─── Constants / assert entropia ─────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.attendance_identity_token_entropy_bytes()
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 32;
$$;

COMMENT ON FUNCTION data.attendance_identity_token_entropy_bytes() IS
  'ST-11: bytes aleatoris CSPRNG per token QR (256 bits).';

CREATE OR REPLACE FUNCTION data.attendance_identity_token_min_raw_length()
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$
  -- base64url(32 bytes) sense padding → 43 caràcters
  SELECT 43;
$$;

COMMENT ON FUNCTION data.attendance_identity_token_min_raw_length() IS
  'ST-11: longitud mínima del token en clar (base64url de 32 bytes).';

CREATE OR REPLACE FUNCTION data.assert_attendance_identity_token_entropy(p_token text)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_tok text := btrim(COALESCE(p_token, ''));
  v_min int := data.attendance_identity_token_min_raw_length();
BEGIN
  IF v_tok = '' THEN
    RAISE EXCEPTION 'identity_token_required' USING ERRCODE = 'check_violation';
  END IF;

  -- Longitud mínima + alfabet base64url (anti-tokens curts / dumpables)
  IF char_length(v_tok) < v_min
     OR v_tok !~ '^[A-Za-z0-9_-]+$' THEN
    RAISE EXCEPTION 'identity_token_entropy_too_low' USING ERRCODE = 'check_violation';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION data.assert_attendance_identity_token_entropy(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.assert_attendance_identity_token_entropy(text)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.build_attendance_identity_token_raw()
RETURNS text
LANGUAGE plpgsql
SET search_path = extensions, public, data
AS $$
DECLARE
  v_raw text;
  v_min int := data.attendance_identity_token_min_raw_length();
  v_bytes int := data.attendance_identity_token_entropy_bytes();
  v_try int := 0;
BEGIN
  LOOP
    v_try := v_try + 1;
    v_raw := translate(encode(gen_random_bytes(v_bytes), 'base64'), '+/=', '-_');
    EXIT WHEN char_length(v_raw) >= v_min AND v_raw ~ '^[A-Za-z0-9_-]+$';
    IF v_try >= 5 THEN
      RAISE EXCEPTION 'identity_token_entropy_generation_failed'
        USING ERRCODE = 'internal_error';
    END IF;
  END LOOP;
  RETURN v_raw;
END;
$$;

-- ─── issue: valida entropia després de generar ───────────────────────────────

CREATE OR REPLACE FUNCTION api.issue_attendance_identity_token(
  p_employee_id uuid,
  p_method text DEFAULT 'qr'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_employee record;
  v_method   text;
  v_raw      text;
  v_hash     bytea;
  v_expires  timestamptz;
  v_id       uuid;
  v_ttl_min  int := 5;
BEGIN
  IF p_employee_id IS NULL THEN
    RAISE EXCEPTION 'employee_id_required' USING ERRCODE = 'check_violation';
  END IF;

  v_method := lower(btrim(COALESCE(p_method, 'qr')));
  IF v_method NOT IN ('qr', 'barcode') THEN
    RAISE EXCEPTION 'invalid_identity_method' USING ERRCODE = 'check_violation';
  END IF;

  SELECT e.id, e.tenant_id, e.status
    INTO v_employee
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND OR v_employee.status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  PERFORM api.assert_station_identity_issue_rate_limit(p_employee_id);

  v_raw := data.build_attendance_identity_token_raw();
  PERFORM data.assert_attendance_identity_token_entropy(v_raw);
  v_hash := digest(v_raw, 'sha256');
  v_expires := now() + make_interval(mins => v_ttl_min);

  INSERT INTO data.attendance_identity_tokens (
    tenant_id, employee_id, method, token_hash, expires_at
  ) VALUES (
    v_employee.tenant_id, p_employee_id, v_method, v_hash, v_expires
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'token_id', v_id,
    'token', v_raw,
    'method', v_method,
    'expires_at', v_expires,
    'ttl_seconds', v_ttl_min * 60,
    'entropy_bytes', data.attendance_identity_token_entropy_bytes()
  );
END;
$$;

-- ─── resolve: rate limit al RPC + reject entropia baixa ──────────────────────
-- Signature nova amb p_client_key opcional (Edge passa IP+device; fallback = device).

DROP FUNCTION IF EXISTS api.resolve_attendance_identity_token(text, text);

CREATE OR REPLACE FUNCTION api.resolve_attendance_identity_token(
  p_token             text,
  p_device_public_id  text,
  p_client_key        text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_device    record;
  v_row       record;
  v_hash      bytea;
  v_tz        text;
  v_today     date;
  v_day_state text;
  v_next      text;
  v_rl_key    text;
BEGIN
  IF p_token IS NULL OR btrim(p_token) = '' THEN
    RAISE EXCEPTION 'identity_token_required' USING ERRCODE = 'check_violation';
  END IF;

  IF p_device_public_id IS NULL OR btrim(p_device_public_id) = '' THEN
    RAISE EXCEPTION 'device_public_id_required' USING ERRCODE = 'check_violation';
  END IF;

  -- Rate limit abans de qualsevol lookup (ST-11 / #12)
  v_rl_key := COALESCE(
    NULLIF(btrim(p_client_key), ''),
    'device:' || btrim(p_device_public_id)
  );
  PERFORM api.assert_station_identity_resolve_rate_limit(v_rl_key);

  -- Reject tokens curts / no base64url (sense consumir consulta de hash útil)
  PERFORM data.assert_attendance_identity_token_entropy(p_token);

  SELECT d.*
    INTO v_device
  FROM data.attendance_devices d
  WHERE d.device_public_id = btrim(p_device_public_id)
    AND d.type = 'station';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'station_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_device.status IS DISTINCT FROM 'active'
     OR v_device.site_id IS NULL
     OR v_device.location_id IS NULL THEN
    RAISE EXCEPTION 'station_not_ready' USING ERRCODE = 'check_violation';
  END IF;

  IF NOT ('qr' = ANY(COALESCE(v_device.allowed_methods, ARRAY['manual']::text[]))
          OR 'barcode' = ANY(COALESCE(v_device.allowed_methods, ARRAY['manual']::text[]))) THEN
    RAISE EXCEPTION 'station_qr_not_allowed' USING ERRCODE = 'check_violation';
  END IF;

  v_tz := data.get_site_timezone(v_device.site_id, v_device.tenant_id);
  v_today := (now() AT TIME ZONE v_tz)::date;

  v_hash := digest(btrim(p_token), 'sha256');

  SELECT t.*, e.full_name
    INTO v_row
  FROM data.attendance_identity_tokens t
  JOIN data.employees e ON e.id = t.employee_id
  WHERE t.token_hash = v_hash;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'identity_token_invalid' USING ERRCODE = 'check_violation';
  END IF;

  IF v_row.used_at IS NOT NULL THEN
    RAISE EXCEPTION 'identity_token_already_used' USING ERRCODE = 'check_violation';
  END IF;

  IF v_row.expires_at <= now() THEN
    RAISE EXCEPTION 'identity_token_expired' USING ERRCODE = 'check_violation';
  END IF;

  IF v_row.tenant_id IS DISTINCT FROM v_device.tenant_id THEN
    RAISE EXCEPTION 'identity_token_tenant_mismatch' USING ERRCODE = 'check_violation';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.employees e
    WHERE e.id = v_row.employee_id
      AND e.tenant_id = v_device.tenant_id
      AND e.site_id = v_device.site_id
      AND e.status = 'active'
  ) THEN
    RAISE EXCEPTION 'employee_not_allowed_at_station' USING ERRCODE = 'check_violation';
  END IF;

  UPDATE data.attendance_devices
  SET last_seen_at = now(), updated_at = now()
  WHERE id = v_device.id;

  v_day_state := data.compute_employee_punch_day_state(v_row.employee_id, v_today);
  v_next := data.station_kiosk_next_punch(v_day_state);

  RETURN jsonb_build_object(
    'employee_id', v_row.employee_id,
    'full_name', v_row.full_name,
    'method', v_row.method,
    'day_state', v_day_state,
    'next_punch', v_next,
    'token_id', v_row.id,
    'site_timezone', v_tz
  );
END;
$$;

REVOKE ALL ON FUNCTION api.resolve_attendance_identity_token(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.resolve_attendance_identity_token(text, text, text)
  TO service_role;

COMMENT ON FUNCTION api.resolve_attendance_identity_token(text, text, text) IS
  'ST-11: resolve QR amb rate limit (p_client_key o device:) + entropia mínima abans del lookup.';
