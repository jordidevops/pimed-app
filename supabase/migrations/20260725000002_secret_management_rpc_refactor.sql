-- =============================================================================
-- Secret Management — refactor RPCs existents per delegar a get_tenant_secret
-- =============================================================================

-- Fix cleanup en upsert_tenant_secret
CREATE OR REPLACE FUNCTION api.upsert_tenant_secret(
  p_tenant_id    uuid,
  p_secret_type  text,
  p_provider     text,
  p_value        text,
  p_label        text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_secret_id   uuid;
  v_existing    data.tenant_secret_refs%ROWTYPE;
  v_had_existing boolean := false;
  v_vault_name  text;
  v_vault_desc  text;
  v_version     integer;
BEGIN
  IF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) AND COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_value IS NULL OR length(trim(p_value)) = 0 THEN
    RAISE EXCEPTION 'secret value cannot be empty';
  END IF;

  v_vault_name := p_secret_type || '_' || p_provider || '_' || p_tenant_id::text;
  v_vault_desc := coalesce(p_label, p_secret_type || ' (' || p_provider || ')');

  SELECT * INTO v_existing
  FROM data.tenant_secret_refs
  WHERE tenant_id = p_tenant_id
    AND secret_type = p_secret_type
    AND provider = p_provider;

  v_had_existing := FOUND;

  IF v_had_existing AND v_existing.secret_id IS NOT NULL THEN
    PERFORM vault.update_secret(v_existing.secret_id, p_value, v_vault_name, v_vault_desc);
    v_secret_id := v_existing.secret_id;
    v_version := v_existing.key_version + 1;
  ELSE
    BEGIN
      v_secret_id := vault.create_secret(p_value, v_vault_name, v_vault_desc);
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'No s''ha pogut crear el secret al Vault: %', SQLERRM;
    END;
    v_version := 1;
  END IF;

  BEGIN
    INSERT INTO data.tenant_secret_refs (
      tenant_id, secret_id, secret_type, provider, label,
      key_version, rotation_status, last_rotated_at, rotation_due_at, created_by
    ) VALUES (
      p_tenant_id, v_secret_id, p_secret_type, p_provider, p_label,
      v_version, 'active', now(), now() + interval '365 days', auth.uid()
    )
    ON CONFLICT (tenant_id, secret_type, provider) DO UPDATE SET
      secret_id = EXCLUDED.secret_id,
      label = COALESCE(EXCLUDED.label, data.tenant_secret_refs.label),
      key_version = EXCLUDED.key_version,
      rotation_status = 'active',
      last_rotated_at = now(),
      rotation_due_at = now() + interval '365 days',
      updated_at = now();
  EXCEPTION WHEN OTHERS THEN
    IF NOT v_had_existing THEN
      PERFORM vault.delete_secret(v_secret_id);
    END IF;
    RAISE;
  END;

  RETURN v_secret_id;
END;
$$;

-- -----------------------------------------------------------------------------
-- get_tenant_twilio_credentials_service
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_tenant_twilio_credentials_service(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_row   record;
  v_token text;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_row FROM data.tenant_twilio_config
  WHERE tenant_id = p_tenant_id AND is_enabled = true;

  IF NOT FOUND THEN RETURN NULL; END IF;

  v_token := api.get_tenant_secret(
    p_tenant_id, 'twilio_auth_token', 'twilio',
    'get_tenant_twilio_credentials_service', 'send_sms'
  );

  IF v_token IS NULL AND v_row.auth_token_secret_id IS NOT NULL THEN
    SELECT decrypted_secret INTO v_token
    FROM vault.decrypted_secrets WHERE id = v_row.auth_token_secret_id;
    PERFORM data.log_secret_access(
      p_tenant_id, 'twilio_auth_token', 'twilio',
      'get_tenant_twilio_credentials_service', 'send_sms'
    );
  END IF;

  RETURN jsonb_build_object(
    'account_sid', v_row.account_sid,
    'auth_token', v_token,
    'sms_from_number', v_row.sms_from_number,
    'whatsapp_from_number', v_row.whatsapp_from_number,
    'messaging_service_sid', v_row.messaging_service_sid
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- get_tenant_push_config_service
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_tenant_push_config_service(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_row record;
  v_key text;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_row
  FROM data.tenant_push_config
  WHERE tenant_id = p_tenant_id AND is_enabled = true;

  IF NOT FOUND OR v_row.onesignal_app_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_key := api.get_tenant_secret(
    p_tenant_id, 'onesignal_key', 'onesignal',
    'get_tenant_push_config_service', 'send_push'
  );

  IF v_key IS NULL AND v_row.onesignal_rest_key_secret_id IS NOT NULL THEN
    SELECT decrypted_secret INTO v_key
    FROM vault.decrypted_secrets WHERE id = v_row.onesignal_rest_key_secret_id;
    PERFORM data.log_secret_access(
      p_tenant_id, 'onesignal_key', 'onesignal',
      'get_tenant_push_config_service', 'send_push'
    );
  END IF;

  IF v_key IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'appId', v_row.onesignal_app_id,
    'restApiKey', v_key,
    'source', 'tenant'
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- get_ai_api_key_for_generation
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_ai_api_key_for_generation(
  p_tenant_id uuid,
  p_provider  text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_settings     data.tenant_ai_config%ROWTYPE;
  v_target       data.ai_provider;
  v_provider_cfg data.tenant_ai_provider_config%ROWTYPE;
  v_api_key      text;
  v_base_url     text;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_settings
  FROM data.tenant_ai_config
  WHERE tenant_id = p_tenant_id;

  IF NOT FOUND OR v_settings.is_active IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'No AI config enabled for tenant %', p_tenant_id;
  END IF;

  v_target := COALESCE(
    NULLIF(lower(trim(p_provider)), '')::data.ai_provider,
    v_settings.default_provider
  );

  SELECT * INTO v_provider_cfg
  FROM data.tenant_ai_provider_config
  WHERE tenant_id = p_tenant_id AND provider = v_target;

  IF NOT FOUND OR v_provider_cfg.ai_key_secret_id IS NULL THEN
    RAISE EXCEPTION 'No AI API key configured for provider % (tenant %)', v_target, p_tenant_id;
  END IF;

  IF v_provider_cfg.key_verified_at IS NULL THEN
    RAISE EXCEPTION 'AI API key for provider % is not verified (tenant %)', v_target, p_tenant_id;
  END IF;

  v_api_key := api.get_tenant_secret(
    p_tenant_id, 'ai_api_key', v_target::text,
    'get_ai_api_key_for_generation', 'ai_completion'
  );

  IF v_api_key IS NULL THEN
    SELECT decrypted_secret INTO v_api_key
    FROM vault.decrypted_secrets WHERE id = v_provider_cfg.ai_key_secret_id;
    PERFORM data.log_secret_access(
      p_tenant_id, 'ai_api_key', v_target::text,
      'get_ai_api_key_for_generation', 'ai_completion'
    );
  END IF;

  IF v_api_key IS NULL THEN
    RAISE EXCEPTION 'AI API key not found in vault for tenant %', p_tenant_id;
  END IF;

  v_base_url := COALESCE(
    v_provider_cfg.base_url,
    api.ai_provider_default_base_url(v_provider_cfg.provider)
  );

  RETURN jsonb_build_object(
    'provider',  v_provider_cfg.provider,
    'model',     v_provider_cfg.model,
    'base_url',  v_base_url,
    'api_key',   v_api_key,
    'system_prompt', v_settings.system_prompt,
    'temperature', COALESCE(v_settings.temperature, 0.20),
    'max_tokens', COALESCE(v_settings.max_tokens, 4096)
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- get_storage_provider_with_secret
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_storage_provider_with_secret(
  p_tenant_id   uuid    DEFAULT NULL,
  p_provider_id uuid    DEFAULT NULL
)
RETURNS TABLE (
  id                   uuid,
  provider_type        text,
  endpoint_url         text,
  bucket_name          text,
  access_key           text,
  secret_key           text,
  region               text,
  allowed_mime_types   text[],
  max_file_size_bytes  bigint,
  is_locked            boolean
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_rec record;
  v_sk  text;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  FOR v_rec IN
    SELECT sp.*
    FROM data.storage_providers sp
    WHERE sp.is_active = true AND sp.is_verified = true
      AND (
        (p_provider_id IS NOT NULL AND sp.id = p_provider_id)
        OR (p_provider_id IS NULL AND sp.tenant_id = p_tenant_id)
      )
  LOOP
    v_sk := api.get_tenant_secret(
      v_rec.tenant_id,
      'storage_secret_key',
      'storage:' || v_rec.id::text,
      'get_storage_provider_with_secret',
      'byos_access'
    );

    IF v_sk IS NULL AND v_rec.secret_key_id IS NOT NULL THEN
      SELECT decrypted_secret INTO v_sk
      FROM vault.decrypted_secrets WHERE id = v_rec.secret_key_id;
      PERFORM data.log_secret_access(
        v_rec.tenant_id, 'storage_secret_key', 'storage:' || v_rec.id::text,
        'get_storage_provider_with_secret', 'byos_access'
      );
    END IF;

    RETURN QUERY SELECT
      v_rec.id,
      v_rec.provider_type::text,
      v_rec.endpoint_url,
      v_rec.bucket_name,
      v_rec.access_key,
      v_sk,
      v_rec.region,
      v_rec.allowed_mime_types,
      v_rec.max_file_size_bytes,
      v_rec.is_locked;
  END LOOP;
END;
$$;

-- -----------------------------------------------------------------------------
-- list_secret_rotation_log — reforçar ACL tenant
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.list_secret_rotation_log(
  p_tenant_id uuid DEFAULT NULL,
  p_limit     integer DEFAULT 50
)
RETURNS SETOF data.secret_rotation_log
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') = 'service_role' THEN
    NULL;
  ELSIF p_tenant_id IS NOT NULL AND (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    NULL;
  ELSE
    RAISE EXCEPTION 'forbidden';
  END IF;

  RETURN QUERY
  SELECT *
  FROM data.secret_rotation_log
  WHERE (p_tenant_id IS NULL OR tenant_id = p_tenant_id)
  ORDER BY created_at DESC
  LIMIT GREATEST(1, LEAST(p_limit, 500));
END;
$$;

-- -----------------------------------------------------------------------------
-- list_secret_access_log (admin / tenant owner)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.list_secret_access_log(
  p_tenant_id       uuid DEFAULT NULL,
  p_secret_type     text DEFAULT NULL,
  p_accessed_by_fn  text DEFAULT NULL,
  p_limit           integer DEFAULT 100
)
RETURNS SETOF data.secret_access_log
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') = 'service_role' THEN
    NULL;
  ELSIF p_tenant_id IS NOT NULL AND (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    NULL;
  ELSE
    RAISE EXCEPTION 'forbidden';
  END IF;

  RETURN QUERY
  SELECT *
  FROM data.secret_access_log
  WHERE (p_tenant_id IS NULL OR tenant_id = p_tenant_id)
    AND (p_secret_type IS NULL OR secret_type = p_secret_type)
    AND (p_accessed_by_fn IS NULL OR accessed_by_fn = p_accessed_by_fn)
  ORDER BY created_at DESC
  LIMIT GREATEST(1, LEAST(p_limit, 1000));
END;
$$;

REVOKE ALL ON FUNCTION api.list_secret_access_log(uuid, text, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_secret_access_log(uuid, text, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION api.list_secret_access_log(uuid, text, text, integer) TO service_role;
