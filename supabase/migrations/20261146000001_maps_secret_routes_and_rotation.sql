-- =============================================================================
-- Maps secrets: routes_api_key + pending candidate key for geocoding BYOK (S8)
-- =============================================================================

-- ─── secret_type CHECK: routes_api_key ───────────────────────────────────────

ALTER TABLE data.tenant_secret_refs
  DROP CONSTRAINT IF EXISTS tenant_secret_refs_secret_type_check;

ALTER TABLE data.tenant_secret_refs
  ADD CONSTRAINT tenant_secret_refs_secret_type_check
  CHECK (secret_type IN (
    'ai_api_key', 'twilio_auth_token', 'onesignal_key', 'docuseal_key',
    'storage_secret_key', 'webhook_secret', 'geocoding_api_key',
    'smtp_password', 'mcp_key',
    'tenant_field_dek',
    'routes_api_key'
  ));

-- ─── rotation_status: pending_verification / failed (candidate flow) ─────────

DO $$
DECLARE
  v_con text;
BEGIN
  FOR v_con IN
    SELECT c.conname
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'data'
      AND t.relname = 'tenant_secret_refs'
      AND c.contype = 'c'
      AND pg_get_constraintdef(c.oid) ILIKE '%rotation_status%'
  LOOP
    EXECUTE format('ALTER TABLE data.tenant_secret_refs DROP CONSTRAINT %I', v_con);
  END LOOP;
END;
$$;

ALTER TABLE data.tenant_secret_refs
  ADD CONSTRAINT tenant_secret_refs_rotation_status_check
  CHECK (rotation_status IN (
    'active', 'rotating', 'deprecated', 'revoked',
    'pending_verification', 'failed'
  ));

-- ─── pending candidate columns on geocoding provider configs ─────────────────

ALTER TABLE data.tenant_geocoding_provider_configs
  ADD COLUMN IF NOT EXISTS pending_api_key_secret_id uuid,
  ADD COLUMN IF NOT EXISTS pending_expires_at timestamptz;

COMMENT ON COLUMN data.tenant_geocoding_provider_configs.pending_api_key_secret_id IS
  'Vault secret for a candidate API key awaiting verification; active key stays in api_key_secret_id until promote.';

-- ─── RPC: upsert candidate (does not replace active key) ─────────────────────

CREATE OR REPLACE FUNCTION api.upsert_tenant_geocoding_api_key_candidate(
  p_tenant_id    uuid,
  p_provider_key text,
  p_api_key      text,
  p_ttl_hours    integer DEFAULT 24
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_secret_id uuid;
  v_expires   timestamptz;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_api_key IS NULL OR length(trim(p_api_key)) = 0 THEN
    RAISE EXCEPTION 'api_key cannot be empty';
  END IF;

  -- Store under provider suffix so UNIQUE (tenant, type, provider) allows
  -- active 'google' + pending 'google_pending' simultaneously.
  v_secret_id := api.upsert_tenant_secret(
    p_tenant_id,
    'geocoding_api_key',
    p_provider_key || '_pending',
    p_api_key,
    'Geocoding ' || p_provider_key || ' (pending)'
  );

  UPDATE data.tenant_secret_refs
  SET rotation_status = 'pending_verification',
      updated_at = now()
  WHERE tenant_id = p_tenant_id
    AND secret_type = 'geocoding_api_key'
    AND provider = p_provider_key || '_pending';

  v_expires := now() + make_interval(hours => GREATEST(COALESCE(p_ttl_hours, 24), 1));

  INSERT INTO data.tenant_geocoding_provider_configs (
    tenant_id, provider_key, mode, is_enabled, priority,
    pending_api_key_secret_id, pending_expires_at
  ) VALUES (
    p_tenant_id, p_provider_key, 'byo', true, 100,
    v_secret_id, v_expires
  )
  ON CONFLICT (tenant_id, provider_key) DO UPDATE SET
    pending_api_key_secret_id = v_secret_id,
    pending_expires_at = v_expires,
    updated_at = now();

  RETURN jsonb_build_object(
    'ok', true,
    'status', 'pending_verification',
    'expires_at', v_expires
  );
END;
$$;

REVOKE ALL ON FUNCTION api.upsert_tenant_geocoding_api_key_candidate(uuid, text, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.upsert_tenant_geocoding_api_key_candidate(uuid, text, text, integer) TO service_role;

-- ─── RPC: read pending key (test only) ───────────────────────────────────────

CREATE OR REPLACE FUNCTION api.get_geocoding_pending_api_key_service(
  p_tenant_id    uuid,
  p_provider_key text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_cfg data.tenant_geocoding_provider_configs%ROWTYPE;
  v_key text;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_cfg
  FROM data.tenant_geocoding_provider_configs
  WHERE tenant_id = p_tenant_id AND provider_key = p_provider_key;

  IF NOT FOUND
     OR v_cfg.pending_api_key_secret_id IS NULL
     OR (v_cfg.pending_expires_at IS NOT NULL AND v_cfg.pending_expires_at < now())
  THEN
    RETURN NULL;
  END IF;

  SELECT decrypted_secret INTO v_key
  FROM vault.decrypted_secrets
  WHERE id = v_cfg.pending_api_key_secret_id;

  PERFORM data.log_secret_access(
    p_tenant_id, 'geocoding_api_key', p_provider_key || '_pending',
    'get_geocoding_pending_api_key_service', 'geocoding_key_test'
  );

  RETURN v_key;
END;
$$;

REVOKE ALL ON FUNCTION api.get_geocoding_pending_api_key_service(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_geocoding_pending_api_key_service(uuid, text) TO service_role;

-- ─── RPC: promote candidate → active (after successful test) ─────────────────

CREATE OR REPLACE FUNCTION api.activate_tenant_geocoding_api_key_candidate(
  p_tenant_id    uuid,
  p_provider_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_cfg data.tenant_geocoding_provider_configs%ROWTYPE;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_cfg
  FROM data.tenant_geocoding_provider_configs
  WHERE tenant_id = p_tenant_id AND provider_key = p_provider_key
  FOR UPDATE;

  IF NOT FOUND OR v_cfg.pending_api_key_secret_id IS NULL THEN
    RAISE EXCEPTION 'no_pending_key';
  END IF;

  IF v_cfg.pending_expires_at IS NOT NULL AND v_cfg.pending_expires_at < now() THEN
    RAISE EXCEPTION 'pending_key_expired';
  END IF;

  -- Mark previous active secret as deprecated (if different)
  IF v_cfg.api_key_secret_id IS NOT NULL
     AND v_cfg.api_key_secret_id IS DISTINCT FROM v_cfg.pending_api_key_secret_id
  THEN
    UPDATE data.tenant_secret_refs
    SET rotation_status = 'deprecated', updated_at = now()
    WHERE tenant_id = p_tenant_id
      AND secret_type = 'geocoding_api_key'
      AND provider = p_provider_key
      AND secret_id = v_cfg.api_key_secret_id;
  END IF;

  -- Promote pending vault secret into the canonical provider slot via upsert
  -- by copying decrypted pending into active provider name.
  PERFORM data.log_secret_access(
    p_tenant_id,
    'geocoding_api_key',
    p_provider_key || '_pending',
    'activate_tenant_geocoding_api_key_candidate',
    'geocoding_key_activation'
  );

  PERFORM api.upsert_tenant_geocoding_api_key(
    p_tenant_id,
    p_provider_key,
    (
      SELECT decrypted_secret
      FROM vault.decrypted_secrets
      WHERE id = v_cfg.pending_api_key_secret_id
    )
  );

  UPDATE data.tenant_geocoding_provider_configs
  SET pending_api_key_secret_id = NULL,
      pending_expires_at = NULL,
      updated_at = now()
  WHERE tenant_id = p_tenant_id AND provider_key = p_provider_key;

  UPDATE data.tenant_secret_refs
  SET rotation_status = 'revoked', updated_at = now()
  WHERE tenant_id = p_tenant_id
    AND secret_type = 'geocoding_api_key'
    AND provider = p_provider_key || '_pending';

  RETURN jsonb_build_object('ok', true, 'status', 'active');
END;
$$;

REVOKE ALL ON FUNCTION api.activate_tenant_geocoding_api_key_candidate(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.activate_tenant_geocoding_api_key_candidate(uuid, text) TO service_role;

-- ─── RPC: mark pending failed (test KO — keep active intact) ─────────────────

CREATE OR REPLACE FUNCTION api.fail_tenant_geocoding_api_key_candidate(
  p_tenant_id    uuid,
  p_provider_key text
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
  SET rotation_status = 'failed', updated_at = now()
  WHERE tenant_id = p_tenant_id
    AND secret_type = 'geocoding_api_key'
    AND provider = p_provider_key || '_pending';

  RETURN jsonb_build_object('ok', true, 'status', 'failed');
END;
$$;

REVOKE ALL ON FUNCTION api.fail_tenant_geocoding_api_key_candidate(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.fail_tenant_geocoding_api_key_candidate(uuid, text) TO service_role;
