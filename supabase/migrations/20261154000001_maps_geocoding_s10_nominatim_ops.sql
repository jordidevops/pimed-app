-- Maps Geocoding S10 — platform-wide Nominatim throttle + kill switch + ops alerts.
-- Public Nominatim has no account; control = global rate limit + kill switch + BYO Google.

-- ---------------------------------------------------------------------------
-- Platform settings (module = geocoding)
-- ---------------------------------------------------------------------------
INSERT INTO data.system_settings (module, settings)
VALUES (
  'geocoding',
  jsonb_build_object(
    'nominatim_enabled', true,
    'nominatim_global_max_per_second', 1,
    'nominatim_global_max_per_minute', 50
  )
)
ON CONFLICT (module) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Global rate windows (no tenant FK)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.geocoding_platform_rate_windows (
  provider_key  text        NOT NULL REFERENCES data.geocoding_providers(provider_key) ON DELETE CASCADE,
  window_kind   text        NOT NULL CHECK (window_kind IN ('second', 'minute')),
  window_start  timestamptz NOT NULL,
  request_count integer     NOT NULL DEFAULT 0 CHECK (request_count >= 0),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (provider_key, window_kind, window_start)
);

CREATE INDEX IF NOT EXISTS idx_geocoding_platform_rate_windows_updated
  ON data.geocoding_platform_rate_windows (updated_at DESC);

COMMENT ON TABLE data.geocoding_platform_rate_windows IS
  'S10: platform-wide Nominatim throttle windows (second/minute). Independent of per-tenant limits.';

REVOKE ALL ON TABLE data.geocoding_platform_rate_windows FROM PUBLIC;
REVOKE ALL ON TABLE data.geocoding_platform_rate_windows FROM anon;
REVOKE ALL ON TABLE data.geocoding_platform_rate_windows FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE data.geocoding_platform_rate_windows TO service_role;
GRANT SELECT ON TABLE data.geocoding_platform_rate_windows TO prisma_admin;

-- ---------------------------------------------------------------------------
-- reserve_nominatim_global — service_role only
-- ---------------------------------------------------------------------------
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

  -- Harden boolean parse (jsonb boolean via ->> is 'true'/'false'; missing → enabled).
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

REVOKE ALL ON FUNCTION api.reserve_nominatim_global() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.reserve_nominatim_global() TO service_role;

-- ---------------------------------------------------------------------------
-- Ops alert helper (upstream 429 / custom reasons)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.record_geocoding_ops_alert(
  p_tenant_id        uuid,
  p_provider_key     text,
  p_reason           text,
  p_blocked_requests integer DEFAULT 0,
  p_threshold        integer DEFAULT 0,
  p_payload          jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_today date := CURRENT_DATE;
  v_id uuid;
  v_is_new boolean := false;
  v_payload jsonb;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  v_payload := COALESCE(p_payload, '{}'::jsonb)
    || jsonb_build_object(
      'source', 'geocoding-proxy',
      'reason', COALESCE(NULLIF(trim(p_reason), ''), 'ops_alert')
    );

  INSERT INTO data.geocoding_abuse_alerts (
    tenant_id, provider_key, usage_date, blocked_requests, threshold, payload
  )
  VALUES (
    p_tenant_id,
    p_provider_key,
    v_today,
    GREATEST(COALESCE(p_blocked_requests, 0), 0),
    GREATEST(COALESCE(p_threshold, 0), 0),
    v_payload
  )
  ON CONFLICT (tenant_id, provider_key, usage_date)
  DO UPDATE SET
    blocked_requests = GREATEST(
      data.geocoding_abuse_alerts.blocked_requests,
      EXCLUDED.blocked_requests
    ),
    threshold = GREATEST(data.geocoding_abuse_alerts.threshold, EXCLUDED.threshold),
    payload = data.geocoding_abuse_alerts.payload || EXCLUDED.payload
  RETURNING id, (xmax = 0) INTO v_id, v_is_new;

  RETURN jsonb_build_object(
    'alerted', true,
    'is_new', COALESCE(v_is_new, false),
    'alert_id', v_id,
    'reason', v_payload ->> 'reason'
  );
END;
$$;

REVOKE ALL ON FUNCTION api.record_geocoding_ops_alert(uuid, text, text, integer, integer, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.record_geocoding_ops_alert(uuid, text, text, integer, integer, jsonb) TO service_role;

COMMENT ON FUNCTION api.reserve_nominatim_global() IS
  'S10: reserve one platform Nominatim slot (1/s + N/min) or deny with hard block reason.';
COMMENT ON FUNCTION api.record_geocoding_ops_alert(uuid, text, text, integer, integer, jsonb) IS
  'Record platform/ops geocoding alert (e.g. upstream_429) for admin visibility.';
