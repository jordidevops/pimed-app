-- EX-01.4 fix: mètriques en transacció separada (INSERT abans de RAISE es revertia).

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

    RAISE EXCEPTION '%', COALESCE(NULLIF(btrim(p_error_code), ''), 'station_rate_limited')
      USING ERRCODE = 'check_violation',
            DETAIL = jsonb_build_object(
              'retry_after_seconds', v_retry_after,
              'attempts', v_attempt_count,
              'max_attempts', p_max_attempts,
              'window_minutes', p_window_minutes,
              'bucket_type', p_bucket_type,
              'client_key', v_key,
              'tenant_id', p_tenant_id,
              'employee_id', p_employee_id
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

CREATE OR REPLACE FUNCTION api.record_station_rate_limit_block(
  p_bucket_type     text,
  p_client_key      text,
  p_attempt_count   int,
  p_max_attempts    int,
  p_window_minutes  int,
  p_tenant_id       uuid DEFAULT NULL,
  p_employee_id     uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF p_bucket_type NOT IN ('register', 'identity_resolve', 'identity_issue') THEN
    RAISE EXCEPTION 'invalid_rate_limit_bucket_type' USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO data.station_rate_limit_events (
    bucket_type, client_key, tenant_id, employee_id,
    attempt_count, max_attempts, window_minutes
  ) VALUES (
    p_bucket_type,
    left(COALESCE(NULLIF(btrim(p_client_key), ''), 'unknown'), 128),
    p_tenant_id,
    p_employee_id,
    GREATEST(p_attempt_count, 1),
    GREATEST(p_max_attempts, 1),
    GREATEST(p_window_minutes, 1)
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.record_station_rate_limit_block(text, text, int, int, int, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.record_station_rate_limit_block(text, text, int, int, int, uuid, uuid) TO service_role;
