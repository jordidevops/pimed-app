-- S10 follow-up: safer nominatim_enabled parse in reserve_nominatim_global.

CREATE OR REPLACE FUNCTION api.reserve_nominatim_global()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_settings jsonb := '{}'::jsonb;
  v_enabled boolean := true;
  v_max_second integer := 1;
  v_max_minute integer := 50;
  v_second_start timestamptz;
  v_minute_start timestamptz;
  v_second_used integer := 0;
  v_minute_used integer := 0;
  v_lock_key bigint;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT COALESCE(s.settings, '{}'::jsonb)
  INTO v_settings
  FROM data.system_settings s
  WHERE s.module = 'geocoding';

  v_settings := COALESCE(v_settings, '{}'::jsonb);

  v_enabled := COALESCE(
    CASE lower(COALESCE(v_settings ->> 'nominatim_enabled', 'true'))
      WHEN 'true' THEN true
      WHEN 't' THEN true
      WHEN '1' THEN true
      WHEN 'false' THEN false
      WHEN 'f' THEN false
      WHEN '0' THEN false
      ELSE NULL
    END,
    true
  );
  v_max_second := GREATEST(COALESCE((v_settings ->> 'nominatim_global_max_per_second')::integer, 1), 1);
  v_max_minute := GREATEST(COALESCE((v_settings ->> 'nominatim_global_max_per_minute')::integer, 50), 1);

  IF NOT v_enabled THEN
    RETURN jsonb_build_object(
      'allowed', false,
      'reason', 'nominatim_disabled',
      'second_used', 0,
      'minute_used', 0,
      'max_per_second', v_max_second,
      'max_per_minute', v_max_minute
    );
  END IF;

  v_lock_key := hashtext('nominatim:global');
  PERFORM pg_advisory_xact_lock(v_lock_key);

  v_second_start := date_trunc('second', now());
  v_minute_start := date_trunc('minute', now());

  INSERT INTO data.geocoding_platform_rate_windows (
    provider_key, window_kind, window_start, request_count, updated_at
  )
  VALUES ('nominatim', 'second', v_second_start, 1, now())
  ON CONFLICT (provider_key, window_kind, window_start)
  DO UPDATE SET
    request_count = data.geocoding_platform_rate_windows.request_count + 1,
    updated_at = now()
  RETURNING request_count INTO v_second_used;

  IF v_second_used > v_max_second THEN
    RETURN jsonb_build_object(
      'allowed', false,
      'reason', 'rate_limit_platform_second_exceeded',
      'second_used', v_second_used,
      'minute_used', NULL,
      'max_per_second', v_max_second,
      'max_per_minute', v_max_minute
    );
  END IF;

  INSERT INTO data.geocoding_platform_rate_windows (
    provider_key, window_kind, window_start, request_count, updated_at
  )
  VALUES ('nominatim', 'minute', v_minute_start, 1, now())
  ON CONFLICT (provider_key, window_kind, window_start)
  DO UPDATE SET
    request_count = data.geocoding_platform_rate_windows.request_count + 1,
    updated_at = now()
  RETURNING request_count INTO v_minute_used;

  IF v_minute_used > v_max_minute THEN
    RETURN jsonb_build_object(
      'allowed', false,
      'reason', 'rate_limit_platform_minute_exceeded',
      'second_used', v_second_used,
      'minute_used', v_minute_used,
      'max_per_second', v_max_second,
      'max_per_minute', v_max_minute
    );
  END IF;

  RETURN jsonb_build_object(
    'allowed', true,
    'reason', NULL,
    'second_used', v_second_used,
    'minute_used', v_minute_used,
    'max_per_second', v_max_second,
    'max_per_minute', v_max_minute
  );
END;
$$;
