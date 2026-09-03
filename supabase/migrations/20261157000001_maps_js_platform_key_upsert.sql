-- =============================================================================
-- Maps JS platform trial key: upsert into Vault + presence check (Fase B)
-- =============================================================================

CREATE OR REPLACE FUNCTION api.upsert_maps_js_platform_api_key_service(
  p_api_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_existing_id uuid;
  v_name text := 'maps_js_platform_trial_api_key';
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_api_key IS NULL OR length(trim(p_api_key)) < 20 THEN
    RAISE EXCEPTION 'api_key cannot be empty';
  END IF;

  SELECT id INTO v_existing_id
  FROM vault.secrets
  WHERE name = v_name
  LIMIT 1;

  IF v_existing_id IS NOT NULL THEN
    PERFORM vault.update_secret(v_existing_id, trim(p_api_key), v_name, 'Maps JS platform trial / limited entitlement key');
  ELSE
    PERFORM vault.create_secret(trim(p_api_key), v_name, 'Maps JS platform trial / limited entitlement key');
  END IF;

  UPDATE data.platform_secret_registry
  SET key_version = key_version + 1,
      last_rotated_at = now(),
      updated_at = now(),
      rotation_status = 'active'
  WHERE secret_key = v_name;

  IF NOT FOUND THEN
    INSERT INTO data.platform_secret_registry (secret_key, description, category, rotation_due_at)
    VALUES (
      v_name,
      'Maps JS platform trial / limited entitlement key',
      'maps_js',
      now() + interval '365 days'
    )
    ON CONFLICT (secret_key) DO NOTHING;
  END IF;

  RETURN jsonb_build_object('ok', true, 'status', 'stored');
END;
$$;

REVOKE ALL ON FUNCTION api.upsert_maps_js_platform_api_key_service(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.upsert_maps_js_platform_api_key_service(text) TO service_role;

-- Presence check (no secret value returned).
CREATE OR REPLACE FUNCTION api.has_maps_js_platform_api_key_service()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_key text;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT decrypted_secret INTO v_key
  FROM vault.decrypted_secrets
  WHERE name = 'maps_js_platform_trial_api_key'
  LIMIT 1;

  RETURN v_key IS NOT NULL AND length(trim(v_key)) > 0;
END;
$$;

REVOKE ALL ON FUNCTION api.has_maps_js_platform_api_key_service() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.has_maps_js_platform_api_key_service() TO service_role;
