-- =============================================================================
-- Maps Fase 3: tenant_routes_provider_configs + Vault RPCs (BYO only, S8)
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.tenant_routes_provider_configs (
  tenant_id                 uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  provider_key              text NOT NULL DEFAULT 'google'
    CHECK (provider_key IN ('google')),
  mode                      text NOT NULL DEFAULT 'byo'
    CHECK (mode IN ('byo')),
  is_enabled                boolean NOT NULL DEFAULT true,
  api_key_secret_id         uuid,
  pending_api_key_secret_id uuid,
  pending_expires_at        timestamptz,
  last_used_at              timestamptz,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, provider_key)
);

COMMENT ON TABLE data.tenant_routes_provider_configs IS
  'BYO Google Routes API keys per tenant. No platform mode (too expensive to subsidize).';

COMMENT ON COLUMN data.tenant_routes_provider_configs.pending_api_key_secret_id IS
  'Vault secret for a candidate API key awaiting verification; active key stays in api_key_secret_id until promote.';

CREATE INDEX IF NOT EXISTS idx_tenant_routes_provider_configs_enabled
  ON data.tenant_routes_provider_configs (tenant_id)
  WHERE is_enabled AND api_key_secret_id IS NOT NULL;

ALTER TABLE data.tenant_routes_provider_configs ENABLE ROW LEVEL SECURITY;
-- No policies for authenticated: reads/writes go through service_role RPCs / Edge only.
-- Secret metadata for UI comes from api.list_tenant_secrets (routes_api_key).

REVOKE ALL ON data.tenant_routes_provider_configs FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.tenant_routes_provider_configs TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.tenant_routes_provider_configs TO prisma_admin;

DROP TRIGGER IF EXISTS trg_tenant_routes_provider_configs_updated_at
  ON data.tenant_routes_provider_configs;
CREATE TRIGGER trg_tenant_routes_provider_configs_updated_at
  BEFORE UPDATE ON data.tenant_routes_provider_configs
  FOR EACH ROW
  EXECUTE FUNCTION data.set_updated_at();

-- ─── Active key: upsert / get ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.upsert_tenant_routes_api_key(
  p_tenant_id    uuid,
  p_provider_key text,
  p_api_key      text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_secret_id uuid;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_provider_key IS DISTINCT FROM 'google' THEN
    RAISE EXCEPTION 'invalid_provider';
  END IF;

  IF p_api_key IS NULL OR length(trim(p_api_key)) = 0 THEN
    RAISE EXCEPTION 'api_key cannot be empty';
  END IF;

  v_secret_id := api.upsert_tenant_secret(
    p_tenant_id,
    'routes_api_key',
    p_provider_key,
    p_api_key,
    'Routes ' || p_provider_key
  );

  INSERT INTO data.tenant_routes_provider_configs (
    tenant_id, provider_key, mode, is_enabled, api_key_secret_id
  ) VALUES (
    p_tenant_id, p_provider_key, 'byo', true, v_secret_id
  )
  ON CONFLICT (tenant_id, provider_key) DO UPDATE SET
    mode = 'byo',
    is_enabled = true,
    api_key_secret_id = v_secret_id,
    updated_at = now();
END;
$$;

REVOKE ALL ON FUNCTION api.upsert_tenant_routes_api_key(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.upsert_tenant_routes_api_key(uuid, text, text) TO service_role;

CREATE OR REPLACE FUNCTION api.get_routes_api_key_service(
  p_tenant_id    uuid,
  p_provider_key text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_cfg data.tenant_routes_provider_configs%ROWTYPE;
  v_key text;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_cfg
  FROM data.tenant_routes_provider_configs
  WHERE tenant_id = p_tenant_id AND provider_key = p_provider_key;

  IF NOT FOUND
     OR NOT v_cfg.is_enabled
     OR v_cfg.mode <> 'byo'
     OR v_cfg.api_key_secret_id IS NULL
  THEN
    RETURN NULL;
  END IF;

  v_key := api.get_tenant_secret(
    p_tenant_id, 'routes_api_key', p_provider_key,
    'get_routes_api_key_service', 'routes_request'
  );

  IF v_key IS NULL THEN
    SELECT decrypted_secret INTO v_key
    FROM vault.decrypted_secrets WHERE id = v_cfg.api_key_secret_id;
    PERFORM data.log_secret_access(
      p_tenant_id, 'routes_api_key', p_provider_key,
      'get_routes_api_key_service', 'routes_request'
    );
  END IF;

  RETURN v_key;
END;
$$;

REVOKE ALL ON FUNCTION api.get_routes_api_key_service(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_routes_api_key_service(uuid, text) TO service_role;

-- ─── Candidate flow (save → test → activate / fail) ──────────────────────────

CREATE OR REPLACE FUNCTION api.upsert_tenant_routes_api_key_candidate(
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

  IF p_provider_key IS DISTINCT FROM 'google' THEN
    RAISE EXCEPTION 'invalid_provider';
  END IF;

  IF p_api_key IS NULL OR length(trim(p_api_key)) = 0 THEN
    RAISE EXCEPTION 'api_key cannot be empty';
  END IF;

  v_secret_id := api.upsert_tenant_secret(
    p_tenant_id,
    'routes_api_key',
    p_provider_key || '_pending',
    p_api_key,
    'Routes ' || p_provider_key || ' (pending)'
  );

  UPDATE data.tenant_secret_refs
  SET rotation_status = 'pending_verification',
      updated_at = now()
  WHERE tenant_id = p_tenant_id
    AND secret_type = 'routes_api_key'
    AND provider = p_provider_key || '_pending';

  v_expires := now() + make_interval(hours => GREATEST(COALESCE(p_ttl_hours, 24), 1));

  INSERT INTO data.tenant_routes_provider_configs (
    tenant_id, provider_key, mode, is_enabled,
    pending_api_key_secret_id, pending_expires_at
  ) VALUES (
    p_tenant_id, p_provider_key, 'byo', true,
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

REVOKE ALL ON FUNCTION api.upsert_tenant_routes_api_key_candidate(uuid, text, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.upsert_tenant_routes_api_key_candidate(uuid, text, text, integer) TO service_role;

CREATE OR REPLACE FUNCTION api.get_routes_pending_api_key_service(
  p_tenant_id    uuid,
  p_provider_key text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_cfg data.tenant_routes_provider_configs%ROWTYPE;
  v_key text;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_cfg
  FROM data.tenant_routes_provider_configs
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
    p_tenant_id, 'routes_api_key', p_provider_key || '_pending',
    'get_routes_pending_api_key_service', 'routes_key_test'
  );

  RETURN v_key;
END;
$$;

REVOKE ALL ON FUNCTION api.get_routes_pending_api_key_service(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_routes_pending_api_key_service(uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION api.activate_tenant_routes_api_key_candidate(
  p_tenant_id    uuid,
  p_provider_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_cfg data.tenant_routes_provider_configs%ROWTYPE;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_cfg
  FROM data.tenant_routes_provider_configs
  WHERE tenant_id = p_tenant_id AND provider_key = p_provider_key
  FOR UPDATE;

  IF NOT FOUND OR v_cfg.pending_api_key_secret_id IS NULL THEN
    RAISE EXCEPTION 'no_pending_key';
  END IF;

  IF v_cfg.pending_expires_at IS NOT NULL AND v_cfg.pending_expires_at < now() THEN
    RAISE EXCEPTION 'pending_key_expired';
  END IF;

  IF v_cfg.api_key_secret_id IS NOT NULL
     AND v_cfg.api_key_secret_id IS DISTINCT FROM v_cfg.pending_api_key_secret_id
  THEN
    UPDATE data.tenant_secret_refs
    SET rotation_status = 'deprecated', updated_at = now()
    WHERE tenant_id = p_tenant_id
      AND secret_type = 'routes_api_key'
      AND provider = p_provider_key
      AND secret_id = v_cfg.api_key_secret_id;
  END IF;

  PERFORM data.log_secret_access(
    p_tenant_id,
    'routes_api_key',
    p_provider_key || '_pending',
    'activate_tenant_routes_api_key_candidate',
    'routes_key_activation'
  );

  PERFORM api.upsert_tenant_routes_api_key(
    p_tenant_id,
    p_provider_key,
    (
      SELECT decrypted_secret
      FROM vault.decrypted_secrets
      WHERE id = v_cfg.pending_api_key_secret_id
    )
  );

  UPDATE data.tenant_routes_provider_configs
  SET pending_api_key_secret_id = NULL,
      pending_expires_at = NULL,
      updated_at = now()
  WHERE tenant_id = p_tenant_id AND provider_key = p_provider_key;

  UPDATE data.tenant_secret_refs
  SET rotation_status = 'revoked', updated_at = now()
  WHERE tenant_id = p_tenant_id
    AND secret_type = 'routes_api_key'
    AND provider = p_provider_key || '_pending';

  RETURN jsonb_build_object('ok', true, 'status', 'active');
END;
$$;

REVOKE ALL ON FUNCTION api.activate_tenant_routes_api_key_candidate(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.activate_tenant_routes_api_key_candidate(uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION api.fail_tenant_routes_api_key_candidate(
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
    AND secret_type = 'routes_api_key'
    AND provider = p_provider_key || '_pending';

  RETURN jsonb_build_object('ok', true, 'status', 'failed');
END;
$$;

REVOKE ALL ON FUNCTION api.fail_tenant_routes_api_key_candidate(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.fail_tenant_routes_api_key_candidate(uuid, text) TO service_role;

-- ─── Touch last_used_at (routes-proxy) ───────────────────────────────────────

CREATE OR REPLACE FUNCTION api.touch_tenant_routes_provider(
  p_tenant_id    uuid,
  p_provider_key text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  UPDATE data.tenant_routes_provider_configs
  SET last_used_at = now(), updated_at = now()
  WHERE tenant_id = p_tenant_id AND provider_key = p_provider_key;
END;
$$;

REVOKE ALL ON FUNCTION api.touch_tenant_routes_provider(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.touch_tenant_routes_provider(uuid, text) TO service_role;
