-- CF-28 F9 Tall 1: commercial /sign rate-limit helpers + revoke direct resolve bypass.

-- Soft check wrapper (no raise to client) for Edge service_role callers.
CREATE OR REPLACE FUNCTION api.check_commercial_sign_rate_limit(
  p_bucket_type text,
  p_client_key text,
  p_max_attempts integer DEFAULT 60,
  p_window_minutes integer DEFAULT 1
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NULLIF(btrim(COALESCE(p_bucket_type, '')), '') IS NULL
     OR NULLIF(btrim(COALESCE(p_client_key, '')), '') IS NULL
  THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  BEGIN
    PERFORM data.assert_customer_portal_rate_limit(
      left(btrim(p_bucket_type), 64),
      left(btrim(p_client_key), 128),
      GREATEST(1, LEAST(COALESCE(p_max_attempts, 60), 200)),
      GREATEST(1, LEAST(COALESCE(p_window_minutes, 1), 1440)),
      NULL
    );
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      IF SQLERRM LIKE '%customer_portal_rate_limited%' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'rate_limited');
      END IF;
      RAISE;
  END;

  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION api.check_commercial_sign_rate_limit(text, text, integer, integer)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.check_commercial_sign_rate_limit(text, text, integer, integer)
  TO service_role;

COMMENT ON FUNCTION api.check_commercial_sign_rate_limit(text, text, integer, integer) IS
  'F9: rate-limit buckets for commercial /sign (IP / token_miss / decide). service_role only.';

-- Close anon/authenticated bypass of resolve (must go through Edge with IP).
REVOKE ALL ON FUNCTION api.resolve_commercial_decision_token(text, boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION api.resolve_commercial_decision_token(text, boolean)
  TO service_role;

NOTIFY pgrst, 'reload schema';
