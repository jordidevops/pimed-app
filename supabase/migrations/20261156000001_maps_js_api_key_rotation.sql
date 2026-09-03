-- =============================================================================
-- Maps JS secrets (BYOK): maps_js_api_key candidate → verify → activate (Fase A)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Extend secret_type CHECK: add maps_js_api_key
-- -----------------------------------------------------------------------------

ALTER TABLE data.tenant_secret_refs
  DROP CONSTRAINT IF EXISTS tenant_secret_refs_secret_type_check;

ALTER TABLE data.tenant_secret_refs
  ADD CONSTRAINT tenant_secret_refs_secret_type_check
  CHECK (secret_type IN (
    'ai_api_key', 'twilio_auth_token', 'onesignal_key', 'docuseal_key',
    'storage_secret_key', 'webhook_secret', 'geocoding_api_key',
    'smtp_password', 'mcp_key',
    'tenant_field_dek',
    'routes_api_key',
    'maps_js_api_key'
  ));

-- -----------------------------------------------------------------------------
-- 2) RPC: upsert candidate maps_js_api_key (service_role only)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.upsert_tenant_maps_js_api_key_candidate(
  p_tenant_id    uuid,
  p_provider_key text, -- e.g. 'google'
  p_api_key      text,
  p_ttl_hours    integer DEFAULT 24
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_expires   timestamptz;
  v_secret_id uuid;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_api_key IS NULL OR length(trim(p_api_key)) = 0 THEN
    RAISE EXCEPTION 'api_key cannot be empty';
  END IF;

  v_secret_id := api.upsert_tenant_secret(
    p_tenant_id,
    'maps_js_api_key',
    p_provider_key || '_pending',
    p_api_key,
    'Maps JS ' || p_provider_key || ' (pending)'
  );

  v_expires := now() + make_interval(hours => GREATEST(COALESCE(p_ttl_hours, 24), 1));

  UPDATE data.tenant_secret_refs
  SET rotation_status = 'pending_verification',
      updated_at = now(),
      rotation_due_at = v_expires
  WHERE tenant_id = p_tenant_id
    AND secret_type = 'maps_js_api_key'
    AND provider = p_provider_key || '_pending';

  RETURN jsonb_build_object(
    'ok', true,
    'status', 'pending_verification',
    'expires_at', v_expires
  );
END;
$$;

REVOKE ALL ON FUNCTION api.upsert_tenant_maps_js_api_key_candidate(uuid, text, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.upsert_tenant_maps_js_api_key_candidate(uuid, text, text, integer) TO service_role;

-- -----------------------------------------------------------------------------
-- 3) RPC: read pending maps_js_api_key (test only)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.get_maps_js_pending_api_key_service(
  p_tenant_id    uuid,
  p_provider_key text -- e.g. 'google'
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_ref    data.tenant_secret_refs%ROWTYPE;
  v_key    text;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_ref
  FROM data.tenant_secret_refs
  WHERE tenant_id = p_tenant_id
    AND secret_type = 'maps_js_api_key'
    AND provider = p_provider_key || '_pending'
    AND rotation_status = 'pending_verification'
    AND (rotation_due_at IS NULL OR rotation_due_at >= now());

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT decrypted_secret INTO v_key
  FROM vault.decrypted_secrets
  WHERE id = v_ref.secret_id;

  PERFORM data.log_secret_access(
    p_tenant_id, 'maps_js_api_key', p_provider_key || '_pending',
    'get_maps_js_pending_api_key_service', 'maps_js_key_test'
  );

  RETURN v_key;
END;
$$;

REVOKE ALL ON FUNCTION api.get_maps_js_pending_api_key_service(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_maps_js_pending_api_key_service(uuid, text) TO service_role;

-- -----------------------------------------------------------------------------
-- 4) RPC: promote candidate → active
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.activate_tenant_maps_js_api_key_candidate(
  p_tenant_id    uuid,
  p_provider_key text -- e.g. 'google'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_pending data.tenant_secret_refs%ROWTYPE;
  v_active  data.tenant_secret_refs%ROWTYPE;
  v_key     text;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_pending
  FROM data.tenant_secret_refs
  WHERE tenant_id = p_tenant_id
    AND secret_type = 'maps_js_api_key'
    AND provider = p_provider_key || '_pending'
    AND rotation_status = 'pending_verification'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no_pending_key';
  END IF;

  IF v_pending.rotation_due_at IS NOT NULL AND v_pending.rotation_due_at < now() THEN
    RAISE EXCEPTION 'pending_key_expired';
  END IF;

  SELECT decrypted_secret INTO v_key
  FROM vault.decrypted_secrets
  WHERE id = v_pending.secret_id;

  SELECT * INTO v_active
  FROM data.tenant_secret_refs
  WHERE tenant_id = p_tenant_id
    AND secret_type = 'maps_js_api_key'
    AND provider = p_provider_key
    AND rotation_status = 'active'
  FOR UPDATE;

  -- If different, mark the previous active as deprecated (best-effort).
  IF FOUND AND v_active.secret_id IS DISTINCT FROM v_pending.secret_id THEN
    UPDATE data.tenant_secret_refs
    SET rotation_status = 'deprecated',
        updated_at = now()
    WHERE tenant_id = p_tenant_id
      AND secret_type = 'maps_js_api_key'
      AND provider = p_provider_key
      AND secret_id = v_active.secret_id;
  END IF;

  PERFORM data.log_secret_access(
    p_tenant_id, 'maps_js_api_key', p_provider_key || '_pending',
    'activate_tenant_maps_js_api_key_candidate', 'maps_js_key_activation'
  );

  -- Promote pending value into the active slot.
  PERFORM api.upsert_tenant_secret(
    p_tenant_id,
    'maps_js_api_key',
    p_provider_key,
    v_key,
    'Maps JS ' || p_provider_key
  );

  UPDATE data.tenant_secret_refs
  SET rotation_status = 'revoked',
      updated_at = now()
  WHERE tenant_id = p_tenant_id
    AND secret_type = 'maps_js_api_key'
    AND provider = p_provider_key || '_pending'
    AND secret_id = v_pending.secret_id;

  RETURN jsonb_build_object('ok', true, 'status', 'active');
END;
$$;

REVOKE ALL ON FUNCTION api.activate_tenant_maps_js_api_key_candidate(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.activate_tenant_maps_js_api_key_candidate(uuid, text) TO service_role;

-- -----------------------------------------------------------------------------
-- 5) RPC: mark pending failed (test KO)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.fail_tenant_maps_js_api_key_candidate(
  p_tenant_id    uuid,
  p_provider_key text -- e.g. 'google'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  UPDATE data.tenant_secret_refs
  SET rotation_status = 'failed',
      updated_at = now()
  WHERE tenant_id = p_tenant_id
    AND secret_type = 'maps_js_api_key'
    AND provider = p_provider_key || '_pending';

  RETURN jsonb_build_object('ok', true, 'status', 'failed');
END;
$$;

REVOKE ALL ON FUNCTION api.fail_tenant_maps_js_api_key_candidate(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.fail_tenant_maps_js_api_key_candidate(uuid, text) TO service_role;

