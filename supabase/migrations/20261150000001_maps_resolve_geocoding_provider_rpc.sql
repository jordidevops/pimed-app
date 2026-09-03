-- Resolve geocoding provider without PostgREST schema "data" (not exposed).
-- Used by geocoding-proxy (service_role only).

CREATE OR REPLACE FUNCTION api.resolve_effective_geocoding_provider(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_mode text;
  v_nominatim_active boolean;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  -- Prefer Google BYO when active provider + tenant config with secret.
  SELECT c.mode INTO v_mode
  FROM data.tenant_geocoding_provider_configs c
  JOIN data.geocoding_providers p ON p.provider_key = c.provider_key
  WHERE c.tenant_id = p_tenant_id
    AND c.provider_key = 'google'
    AND c.is_enabled = true
    AND c.mode = 'byo'
    AND c.api_key_secret_id IS NOT NULL
    AND p.is_active = true
  ORDER BY c.priority ASC, c.created_at ASC
  LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object('provider_key', 'google', 'mode', 'byo');
  END IF;

  SELECT p.is_active INTO v_nominatim_active
  FROM data.geocoding_providers p
  WHERE p.provider_key = 'nominatim';

  IF COALESCE(v_nominatim_active, false) THEN
    SELECT c.mode INTO v_mode
    FROM data.tenant_geocoding_provider_configs c
    WHERE c.tenant_id = p_tenant_id
      AND c.provider_key = 'nominatim'
      AND c.is_enabled = true
    ORDER BY c.priority ASC
    LIMIT 1;

    RETURN jsonb_build_object(
      'provider_key', 'nominatim',
      'mode', COALESCE(v_mode, 'platform')
    );
  END IF;

  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION api.resolve_effective_geocoding_provider(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.resolve_effective_geocoding_provider(uuid) TO service_role;
