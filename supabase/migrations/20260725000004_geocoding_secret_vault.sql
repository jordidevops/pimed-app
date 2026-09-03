-- =============================================================================
-- Geocoding BYO — api_key_secret_ref (text) → Vault + tenant_secret_refs
-- =============================================================================

ALTER TABLE data.tenant_geocoding_provider_configs
  ADD COLUMN IF NOT EXISTS api_key_secret_id uuid;

-- Si algun entorn tenia ref text amb valor directe (legacy), migrar al Vault
DO $$
DECLARE
  v_row record;
  v_sid uuid;
BEGIN
  FOR v_row IN
    SELECT *
    FROM data.tenant_geocoding_provider_configs
    WHERE api_key_secret_ref IS NOT NULL
      AND length(trim(api_key_secret_ref)) > 0
      AND api_key_secret_ref NOT LIKE 'env://%'
      AND api_key_secret_id IS NULL
  LOOP
    v_sid := vault.create_secret(
      v_row.api_key_secret_ref,
      'geocoding_' || v_row.provider_key || '_' || v_row.tenant_id::text,
      'Geocoding API key BYO'
    );

    UPDATE data.tenant_geocoding_provider_configs
    SET api_key_secret_id = v_sid
    WHERE tenant_id = v_row.tenant_id AND provider_key = v_row.provider_key;

    INSERT INTO data.tenant_secret_refs (
      tenant_id, secret_id, secret_type, provider, label,
      key_version, rotation_status, last_rotated_at, rotation_due_at
    ) VALUES (
      v_row.tenant_id, v_sid, 'geocoding_api_key', v_row.provider_key,
      'Geocoding ' || v_row.provider_key,
      1, 'active', now(), now() + interval '365 days'
    )
    ON CONFLICT (tenant_id, secret_type, provider) DO UPDATE SET
      secret_id = EXCLUDED.secret_id,
      updated_at = now();
  END LOOP;
END;
$$;

ALTER TABLE data.tenant_geocoding_provider_configs
  DROP COLUMN IF EXISTS api_key_secret_ref;

-- -----------------------------------------------------------------------------
-- Audit trigger: has_api_key (mai el valor ni l'ID)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_tenant_geocoding_provider_configs()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_actor uuid := auth.uid();
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id, v_actor, NULL,
      'TENANT_GEOCODING_PROVIDER_CONFIG_CREATED',
      'tenant_geocoding_provider_config', NULL,
      jsonb_build_object(
        'provider_key', NEW.provider_key,
        'mode', NEW.mode,
        'is_enabled', NEW.is_enabled,
        'priority', NEW.priority,
        'has_api_key', (NEW.api_key_secret_id IS NOT NULL)
      )
    );
  ELSIF TG_OP = 'UPDATE' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id, v_actor, NULL,
      'TENANT_GEOCODING_PROVIDER_CONFIG_UPDATED',
      'tenant_geocoding_provider_config', NULL,
      jsonb_build_object(
        'provider_key', NEW.provider_key,
        'old', jsonb_build_object(
          'mode', OLD.mode,
          'is_enabled', OLD.is_enabled,
          'priority', OLD.priority,
          'has_api_key', (OLD.api_key_secret_id IS NOT NULL)
        ),
        'new', jsonb_build_object(
          'mode', NEW.mode,
          'is_enabled', NEW.is_enabled,
          'priority', NEW.priority,
          'has_api_key', (NEW.api_key_secret_id IS NOT NULL)
        )
      )
    );
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id, v_actor, NULL,
      'TENANT_GEOCODING_PROVIDER_CONFIG_DELETED',
      'tenant_geocoding_provider_config', NULL,
      jsonb_build_object(
        'provider_key', OLD.provider_key,
        'mode', OLD.mode,
        'is_enabled', OLD.is_enabled,
        'priority', OLD.priority
      )
    );
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;

-- -----------------------------------------------------------------------------
-- RPC: get_geocoding_api_key_service
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_geocoding_api_key_service(
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

  IF NOT FOUND OR v_cfg.mode <> 'byo' OR v_cfg.api_key_secret_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_key := api.get_tenant_secret(
    p_tenant_id, 'geocoding_api_key', p_provider_key,
    'get_geocoding_api_key_service', 'geocoding_request'
  );

  IF v_key IS NULL THEN
    SELECT decrypted_secret INTO v_key
    FROM vault.decrypted_secrets WHERE id = v_cfg.api_key_secret_id;
    PERFORM data.log_secret_access(
      p_tenant_id, 'geocoding_api_key', p_provider_key,
      'get_geocoding_api_key_service', 'geocoding_request'
    );
  END IF;

  RETURN v_key;
END;
$$;

REVOKE ALL ON FUNCTION api.get_geocoding_api_key_service(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_geocoding_api_key_service(uuid, text) TO service_role;

-- -----------------------------------------------------------------------------
-- RPC: upsert_tenant_geocoding_api_key (admin / service_role)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.upsert_tenant_geocoding_api_key(
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

  IF p_api_key IS NULL OR length(trim(p_api_key)) = 0 THEN
    RAISE EXCEPTION 'api_key cannot be empty';
  END IF;

  v_secret_id := api.upsert_tenant_secret(
    p_tenant_id,
    'geocoding_api_key',
    p_provider_key,
    p_api_key,
    'Geocoding ' || p_provider_key
  );

  INSERT INTO data.tenant_geocoding_provider_configs (
    tenant_id, provider_key, mode, is_enabled, priority, api_key_secret_id
  ) VALUES (
    p_tenant_id, p_provider_key, 'byo', true, 100, v_secret_id
  )
  ON CONFLICT (tenant_id, provider_key) DO UPDATE SET
    mode = 'byo',
    api_key_secret_id = v_secret_id,
    updated_at = now();
END;
$$;

REVOKE ALL ON FUNCTION api.upsert_tenant_geocoding_api_key(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.upsert_tenant_geocoding_api_key(uuid, text, text) TO service_role;
