-- EX-01.4: Rate limit emissió QR + mètriques + error codes distints per resolve.

-- -----------------------------------------------------------------------------
-- 1. Mètriques (només es registren intents bloquejats)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS data.station_rate_limit_events (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_type     text        NOT NULL CHECK (bucket_type IN ('register', 'identity_resolve', 'identity_issue')),
  client_key      text        NOT NULL,
  tenant_id       uuid        REFERENCES data.tenants(id) ON DELETE SET NULL,
  employee_id     uuid        REFERENCES data.employees(id) ON DELETE SET NULL,
  attempt_count   integer     NOT NULL,
  max_attempts    integer     NOT NULL,
  window_minutes  integer     NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_station_rate_limit_events_created
  ON data.station_rate_limit_events (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_station_rate_limit_events_bucket_created
  ON data.station_rate_limit_events (bucket_type, created_at DESC);

ALTER TABLE data.station_rate_limit_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "station_rate_limit_events: service_role full access"
  ON data.station_rate_limit_events;

CREATE POLICY "station_rate_limit_events: service_role full access"
  ON data.station_rate_limit_events FOR ALL TO service_role
  USING (true) WITH CHECK (true);

GRANT ALL ON data.station_rate_limit_events TO service_role;

COMMENT ON TABLE data.station_rate_limit_events IS
  'Esdeveniments de rate limit bloquejats per estacions (register / resolve / issue QR).';

-- -----------------------------------------------------------------------------
-- 2. Core bucket (reutilitza station_register_rate_limits)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.assert_station_rate_limit_bucket(
  p_client_key      text,
  p_max_attempts    int,
  p_window_minutes  int,
  p_error_code      text,
  p_bucket_type     text,
  p_tenant_id       uuid DEFAULT NULL,
  p_employee_id     uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_key            text;
  v_window_start   timestamptz;
  v_window_end     timestamptz;
  v_attempt_count  int;
  v_retry_after    int;
BEGIN
  v_key := NULLIF(btrim(COALESCE(p_client_key, '')), '');
  IF v_key IS NULL THEN
    v_key := 'unknown';
  END IF;

  IF char_length(v_key) > 128 THEN
    v_key := left(v_key, 128);
  END IF;

  p_max_attempts := GREATEST(1, LEAST(COALESCE(p_max_attempts, 20), 200));
  p_window_minutes := GREATEST(1, LEAST(COALESCE(p_window_minutes, 15), 60));

  v_window_start := data.station_register_rate_window_start(p_window_minutes);
  v_window_end := v_window_start + make_interval(mins => p_window_minutes);

  INSERT INTO data.station_register_rate_limits (client_key, window_start, attempt_count)
  VALUES (v_key, v_window_start, 1)
  ON CONFLICT (client_key, window_start)
  DO UPDATE SET
    attempt_count = data.station_register_rate_limits.attempt_count + 1,
    updated_at = now()
  RETURNING attempt_count INTO v_attempt_count;

  IF v_attempt_count > p_max_attempts THEN
    v_retry_after := GREATEST(
      1,
      ceil(extract(epoch FROM (v_window_end - now())))::int
    );

    INSERT INTO data.station_rate_limit_events (
      bucket_type, client_key, tenant_id, employee_id,
      attempt_count, max_attempts, window_minutes
    ) VALUES (
      p_bucket_type, v_key, p_tenant_id, p_employee_id,
      v_attempt_count, p_max_attempts, p_window_minutes
    );

    RAISE EXCEPTION '%', COALESCE(NULLIF(btrim(p_error_code), ''), 'station_rate_limited')
      USING ERRCODE = 'check_violation',
            DETAIL = jsonb_build_object(
              'retry_after_seconds', v_retry_after,
              'attempts', v_attempt_count,
              'max_attempts', p_max_attempts,
              'window_minutes', p_window_minutes,
              'bucket_type', p_bucket_type
            )::text;
  END IF;

  v_retry_after := GREATEST(
    0,
    ceil(extract(epoch FROM (v_window_end - now())))::int
  );

  RETURN jsonb_build_object(
    'allowed', true,
    'attempts', v_attempt_count,
    'max_attempts', p_max_attempts,
    'retry_after_seconds', v_retry_after,
    'window_minutes', p_window_minutes,
    'bucket_type', p_bucket_type
  );
END;
$$;

REVOKE ALL ON FUNCTION data.assert_station_rate_limit_bucket(text, int, int, text, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.assert_station_rate_limit_bucket(text, int, int, text, text, uuid, uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 3. Wrappers amb error codes distints
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.assert_station_register_rate_limit(
  p_client_key      text,
  p_max_attempts    int DEFAULT 20,
  p_window_minutes  int DEFAULT 15
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_key text := COALESCE(NULLIF(btrim(p_client_key), ''), 'unknown');
BEGIN
  IF char_length(v_key) > 128 THEN
    v_key := left(v_key, 128);
  END IF;

  RETURN data.assert_station_rate_limit_bucket(
    v_key,
    p_max_attempts,
    p_window_minutes,
    'station_register_rate_limited',
    'register',
    NULL,
    NULL
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.assert_station_identity_resolve_rate_limit(
  p_client_key      text,
  p_max_attempts    int DEFAULT 30,
  p_window_minutes  int DEFAULT 15
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_key text := COALESCE(NULLIF(btrim(p_client_key), ''), 'unknown');
BEGIN
  IF char_length(v_key) > 128 THEN
    v_key := left(v_key, 128);
  END IF;

  RETURN data.assert_station_rate_limit_bucket(
    v_key,
    p_max_attempts,
    p_window_minutes,
    'station_identity_resolve_rate_limited',
    'identity_resolve',
    NULL,
    NULL
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.assert_station_identity_issue_rate_limit(
  p_employee_id     uuid,
  p_max_attempts    int DEFAULT 10,
  p_window_minutes  int DEFAULT 15
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_employee record;
  v_key      text;
BEGIN
  IF p_employee_id IS NULL THEN
    RAISE EXCEPTION 'employee_id_required' USING ERRCODE = 'check_violation';
  END IF;

  SELECT e.id, e.tenant_id, e.status
    INTO v_employee
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND OR v_employee.status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  v_key := 'issue:employee:' || p_employee_id::text;

  RETURN data.assert_station_rate_limit_bucket(
    v_key,
    p_max_attempts,
    p_window_minutes,
    'station_identity_issue_rate_limited',
    'identity_issue',
    v_employee.tenant_id,
    p_employee_id
  );
END;
$$;

REVOKE ALL ON FUNCTION api.assert_station_identity_issue_rate_limit(uuid, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.assert_station_identity_issue_rate_limit(uuid, int, int) TO service_role;

CREATE OR REPLACE FUNCTION data.purge_station_rate_limit_events(p_keep_days int DEFAULT 30)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_deleted int;
BEGIN
  DELETE FROM data.station_rate_limit_events
  WHERE created_at < now() - make_interval(days => GREATEST(p_keep_days, 1));
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION data.purge_station_rate_limit_events(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.purge_station_rate_limit_events(int) TO service_role;

-- -----------------------------------------------------------------------------
-- 4. issue_attendance_identity_token — rate limit per empleat
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.issue_attendance_identity_token(
  p_employee_id uuid,
  p_method      text DEFAULT 'qr'
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
    'ttl_seconds', v_ttl_min * 60
  );
END;
$$;
