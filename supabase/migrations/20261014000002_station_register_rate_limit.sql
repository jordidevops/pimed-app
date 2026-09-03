-- ST-3b: rate limiting per POST /station-api/register (força bruta codis d'aparellament)
-- Finestra fixa 15 min per client_key (p. ex. ip:203.0.113.42)

CREATE TABLE IF NOT EXISTS data.station_register_rate_limits (
  client_key    text        NOT NULL,
  window_start  timestamptz NOT NULL,
  attempt_count integer     NOT NULL DEFAULT 0,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (client_key, window_start)
);

CREATE INDEX IF NOT EXISTS idx_station_register_rate_limits_updated
  ON data.station_register_rate_limits (updated_at);

ALTER TABLE data.station_register_rate_limits ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "station_register_rate_limits: service_role full access"
  ON data.station_register_rate_limits;

CREATE POLICY "station_register_rate_limits: service_role full access"
  ON data.station_register_rate_limits FOR ALL TO service_role
  USING (true) WITH CHECK (true);

GRANT ALL ON data.station_register_rate_limits TO service_role;

CREATE OR REPLACE FUNCTION data.station_register_rate_window_start(
  p_window_minutes int DEFAULT 15
)
RETURNS timestamptz
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT to_timestamp(
    floor(extract(epoch FROM now()) / (GREATEST(p_window_minutes, 1) * 60))
      * (GREATEST(p_window_minutes, 1) * 60)
  );
$$;

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
    RAISE EXCEPTION 'station_register_rate_limited'
      USING ERRCODE = 'check_violation',
            DETAIL = jsonb_build_object(
              'retry_after_seconds', v_retry_after,
              'attempts', v_attempt_count,
              'max_attempts', p_max_attempts,
              'window_minutes', p_window_minutes
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
    'window_minutes', p_window_minutes
  );
END;
$$;

REVOKE ALL ON FUNCTION api.assert_station_register_rate_limit(text, int, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.assert_station_register_rate_limit(text, int, int) FROM authenticated;
REVOKE ALL ON FUNCTION api.assert_station_register_rate_limit(text, int, int) FROM anon;
GRANT EXECUTE ON FUNCTION api.assert_station_register_rate_limit(text, int, int) TO service_role;

COMMENT ON FUNCTION api.assert_station_register_rate_limit IS
  'Rate limit per aparellament d''estació (defecte 20 intents / 15 min / client_key).';

-- Purga best-effort (crons futurs poden reutilitzar)
CREATE OR REPLACE FUNCTION data.purge_station_register_rate_limits(p_keep_days int DEFAULT 2)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_deleted int;
BEGIN
  DELETE FROM data.station_register_rate_limits
  WHERE updated_at < now() - make_interval(days => GREATEST(p_keep_days, 1));
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION data.purge_station_register_rate_limits(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.purge_station_register_rate_limits(int) TO service_role;
