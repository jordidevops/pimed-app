-- =============================================================================
-- Secret Management Core — inventari, audit, rotació i RPCs unificades
-- Pla: docs/plans/crypto/plan.md
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Tipus i taules
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS data.tenant_secret_refs (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id               uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  secret_id               uuid NOT NULL,
  secret_type             text NOT NULL
    CHECK (secret_type IN (
      'ai_api_key', 'twilio_auth_token', 'onesignal_key', 'docuseal_key',
      'storage_secret_key', 'webhook_secret', 'geocoding_api_key',
      'smtp_password', 'mcp_key'
    )),
  provider                text NOT NULL,
  label                   text,
  key_version             integer NOT NULL DEFAULT 1,
  rotation_status         text NOT NULL DEFAULT 'active'
    CHECK (rotation_status IN ('active', 'rotating', 'deprecated', 'revoked')),
  last_rotated_at         timestamptz,
  rotation_due_at         timestamptz,
  last_rotation_alert_at  timestamptz,
  created_by              uuid REFERENCES data.profiles(id),
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, secret_type, provider)
);

CREATE INDEX IF NOT EXISTS idx_tenant_secret_refs_tenant_status
  ON data.tenant_secret_refs (tenant_id, rotation_status);

CREATE INDEX IF NOT EXISTS idx_tenant_secret_refs_rotation_due
  ON data.tenant_secret_refs (rotation_due_at)
  WHERE rotation_status = 'active' AND rotation_due_at IS NOT NULL;

COMMENT ON TABLE data.tenant_secret_refs IS
  'Metadades de secrets de tenant al Vault. Mai emmagatzema el valor en clar.';

CREATE TABLE IF NOT EXISTS data.platform_secret_registry (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  secret_key          text NOT NULL UNIQUE,
  description         text,
  category            text NOT NULL,
  key_version         integer NOT NULL DEFAULT 1,
  rotation_status     text NOT NULL DEFAULT 'active'
    CHECK (rotation_status IN ('active', 'rotating', 'deprecated')),
  last_rotated_at     timestamptz,
  rotation_due_at     timestamptz,
  last_rotation_alert_at timestamptz,
  rotated_by          text,
  notes               text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE data.platform_secret_registry IS
  'Registre de secrets de plataforma (env vars). Sense valors, només metadades.';

CREATE TABLE IF NOT EXISTS data.secret_access_log (
  id              uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id       uuid REFERENCES data.tenants(id) ON DELETE SET NULL,
  secret_type     text NOT NULL,
  provider        text,
  accessed_by_fn  text NOT NULL,
  access_reason   text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

CREATE TABLE IF NOT EXISTS data.secret_access_log_2026_q3
  PARTITION OF data.secret_access_log
  FOR VALUES FROM ('2026-07-01') TO ('2026-10-01');

CREATE TABLE IF NOT EXISTS data.secret_access_log_2026_q4
  PARTITION OF data.secret_access_log
  FOR VALUES FROM ('2026-10-01') TO ('2027-01-01');

CREATE TABLE IF NOT EXISTS data.secret_access_log_default
  PARTITION OF data.secret_access_log DEFAULT;

CREATE INDEX IF NOT EXISTS idx_secret_access_log_tenant_created
  ON data.secret_access_log (tenant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_secret_access_log_fn_created
  ON data.secret_access_log (accessed_by_fn, created_at DESC);

CREATE TABLE IF NOT EXISTS data.secret_rotation_log (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid REFERENCES data.tenants(id) ON DELETE SET NULL,
  secret_type         text NOT NULL,
  provider            text,
  old_key_version     integer NOT NULL,
  new_key_version     integer NOT NULL,
  rotation_type       text NOT NULL
    CHECK (rotation_type IN ('manual', 'scheduled', 'emergency', 'master_key_rotation')),
  initiated_by        text,
  completed_at        timestamptz,
  status              text NOT NULL DEFAULT 'in_progress'
    CHECK (status IN ('in_progress', 'completed', 'failed', 'rolled_back')),
  notes               text,
  created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_secret_rotation_log_tenant
  ON data.secret_rotation_log (tenant_id, created_at DESC);

CREATE TRIGGER trg_tenant_secret_refs_updated_at
  BEFORE UPDATE ON data.tenant_secret_refs
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

CREATE TRIGGER trg_platform_secret_registry_updated_at
  BEFORE UPDATE ON data.platform_secret_registry
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

-- -----------------------------------------------------------------------------
-- 2. Permisos de taula (només service_role directe)
-- -----------------------------------------------------------------------------

REVOKE ALL ON TABLE data.tenant_secret_refs FROM PUBLIC;
REVOKE ALL ON TABLE data.platform_secret_registry FROM PUBLIC;
REVOKE ALL ON TABLE data.secret_access_log FROM PUBLIC;
REVOKE ALL ON TABLE data.secret_rotation_log FROM PUBLIC;

GRANT ALL ON TABLE data.tenant_secret_refs TO service_role;
GRANT ALL ON TABLE data.platform_secret_registry TO service_role;
GRANT ALL ON TABLE data.secret_access_log TO service_role;
GRANT ALL ON TABLE data.secret_rotation_log TO service_role;

-- -----------------------------------------------------------------------------
-- 3. Helper: registrar accés (tolerant a errors)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.log_secret_access(
  p_tenant_id       uuid,
  p_secret_type     text,
  p_provider        text,
  p_accessed_by_fn  text,
  p_access_reason   text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  BEGIN
    INSERT INTO data.secret_access_log (
      tenant_id, secret_type, provider, accessed_by_fn, access_reason
    ) VALUES (
      p_tenant_id, p_secret_type, p_provider, p_accessed_by_fn, p_access_reason
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'secret_access_log insert failed: %', SQLERRM;
  END;
END;
$$;

REVOKE ALL ON FUNCTION data.log_secret_access(uuid, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.log_secret_access(uuid, text, text, text, text) TO service_role;

-- -----------------------------------------------------------------------------
-- 4. RPC: get_tenant_secret (service_role only)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.get_tenant_secret(
  p_tenant_id       uuid,
  p_secret_type     text,
  p_provider        text,
  p_accessed_by_fn  text DEFAULT 'unknown',
  p_access_reason   text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_ref    data.tenant_secret_refs%ROWTYPE;
  v_secret text;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_ref
  FROM data.tenant_secret_refs
  WHERE tenant_id = p_tenant_id
    AND secret_type = p_secret_type
    AND provider = p_provider
    AND rotation_status = 'active';

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT decrypted_secret INTO v_secret
  FROM vault.decrypted_secrets
  WHERE id = v_ref.secret_id;

  PERFORM data.log_secret_access(
    p_tenant_id, p_secret_type, p_provider, p_accessed_by_fn, p_access_reason
  );

  RETURN v_secret;
END;
$$;

REVOKE ALL ON FUNCTION api.get_tenant_secret(uuid, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_tenant_secret(uuid, text, text, text, text) FROM authenticated;
REVOKE ALL ON FUNCTION api.get_tenant_secret(uuid, text, text, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION api.get_tenant_secret(uuid, text, text, text, text) TO service_role;

-- -----------------------------------------------------------------------------
-- 5. RPC: upsert_tenant_secret (owner/manager JWT)
-- -----------------------------------------------------------------------------

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
  v_vault_name  text;
  v_vault_desc  text;
  v_version     integer;
BEGIN
  IF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
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

  IF FOUND AND v_existing.secret_id IS NOT NULL THEN
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
    IF NOT FOUND OR v_existing.secret_id IS NULL THEN
      PERFORM vault.delete_secret(v_secret_id);
    END IF;
    RAISE;
  END;

  RETURN v_secret_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_tenant_secret(uuid, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION api.upsert_tenant_secret(uuid, text, text, text, text) TO service_role;

-- -----------------------------------------------------------------------------
-- 6. RPC: revoke_tenant_secret
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.revoke_tenant_secret(
  p_tenant_id   uuid,
  p_secret_type text,
  p_provider    text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') = 'service_role' THEN
    NULL;
  ELSIF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  UPDATE data.tenant_secret_refs
  SET rotation_status = 'revoked', updated_at = now()
  WHERE tenant_id = p_tenant_id
    AND secret_type = p_secret_type
    AND provider = p_provider;
END;
$$;

GRANT EXECUTE ON FUNCTION api.revoke_tenant_secret(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION api.revoke_tenant_secret(uuid, text, text) TO service_role;

-- -----------------------------------------------------------------------------
-- 7. RPC: rotate_tenant_secret
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.rotate_tenant_secret(
  p_tenant_id   uuid,
  p_secret_type text,
  p_provider    text,
  p_new_value   text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_existing   data.tenant_secret_refs%ROWTYPE;
  v_new_id     uuid;
  v_vault_name text;
  v_vault_desc text;
  v_initiated  text;
BEGIN
  IF COALESCE(auth.role(), '') = 'service_role' THEN
    v_initiated := 'admin';
  ELSIF (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    v_initiated := auth.uid()::text;
  ELSE
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_existing
  FROM data.tenant_secret_refs
  WHERE tenant_id = p_tenant_id
    AND secret_type = p_secret_type
    AND provider = p_provider
    AND rotation_status IN ('active', 'rotating');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no active secret ref found';
  END IF;

  v_vault_name := p_secret_type || '_' || p_provider || '_' || p_tenant_id::text;
  v_vault_desc := coalesce(v_existing.label, p_secret_type);

  v_new_id := vault.create_secret(p_new_value, v_vault_name, v_vault_desc);

  -- Si el UPDATE falla, el nou secret del Vault quedaria orfe. Cleanup explícit.
  BEGIN
    UPDATE data.tenant_secret_refs
    SET secret_id = v_new_id,
        key_version = v_existing.key_version + 1,
        rotation_status = 'active',
        last_rotated_at = now(),
        rotation_due_at = now() + interval '365 days',
        updated_at = now()
    WHERE id = v_existing.id;
  EXCEPTION WHEN OTHERS THEN
    BEGIN
      PERFORM vault.delete_secret(v_new_id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'could not clean up orphaned vault secret %: %', v_new_id, SQLERRM;
    END;
    RAISE;
  END;

  BEGIN
    PERFORM vault.delete_secret(v_existing.secret_id);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'could not delete old vault secret %: %', v_existing.secret_id, SQLERRM;
  END;

  INSERT INTO data.secret_rotation_log (
    tenant_id, secret_type, provider,
    old_key_version, new_key_version,
    rotation_type, initiated_by, completed_at, status
  ) VALUES (
    p_tenant_id, p_secret_type, p_provider,
    v_existing.key_version, v_existing.key_version + 1,
    'manual', v_initiated, now(), 'completed'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.rotate_tenant_secret(uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION api.rotate_tenant_secret(uuid, text, text, text) TO service_role;

-- -----------------------------------------------------------------------------
-- 8. RPC: list_tenant_secrets (metadades, sense valor)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.list_tenant_secrets(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) AND COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id', r.id,
      'secret_type', r.secret_type,
      'provider', r.provider,
      'label', r.label,
      'key_version', r.key_version,
      'rotation_status', r.rotation_status,
      'last_rotated_at', r.last_rotated_at,
      'rotation_due_at', r.rotation_due_at,
      'created_at', r.created_at,
      'updated_at', r.updated_at
    ) ORDER BY r.secret_type, r.provider)
    FROM data.tenant_secret_refs r
    WHERE r.tenant_id = p_tenant_id
      AND r.rotation_status <> 'revoked'
  ), '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_tenant_secrets(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.list_tenant_secrets(uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 9. RPC: list_platform_secrets + log_platform_secret_rotation (service_role)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.list_platform_secrets()
RETURNS SETOF data.platform_secret_registry
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT * FROM data.platform_secret_registry ORDER BY category, secret_key;
$$;

REVOKE ALL ON FUNCTION api.list_platform_secrets() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_platform_secrets() TO service_role;

CREATE OR REPLACE FUNCTION api.log_platform_secret_rotation(
  p_secret_key    text,
  p_rotated_by    text DEFAULT NULL,
  p_notes         text DEFAULT NULL,
  p_rotation_due_at timestamptz DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_old_version integer;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT key_version INTO v_old_version
  FROM data.platform_secret_registry
  WHERE secret_key = p_secret_key;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'secret key not in registry: %', p_secret_key;
  END IF;

  UPDATE data.platform_secret_registry
  SET key_version = key_version + 1,
      rotation_status = 'active',
      last_rotated_at = now(),
      rotation_due_at = COALESCE(p_rotation_due_at, now() + interval '365 days'),
      rotated_by = p_rotated_by,
      notes = p_notes,
      updated_at = now()
  WHERE secret_key = p_secret_key;

  INSERT INTO data.secret_rotation_log (
    tenant_id, secret_type, provider,
    old_key_version, new_key_version,
    rotation_type, initiated_by, completed_at, status, notes
  ) VALUES (
    NULL, 'platform', p_secret_key,
    v_old_version, v_old_version + 1,
    'manual', p_rotated_by, now(), 'completed', p_notes
  );
END;
$$;

REVOKE ALL ON FUNCTION api.log_platform_secret_rotation(text, text, text, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.log_platform_secret_rotation(text, text, text, timestamptz) TO service_role;

CREATE OR REPLACE FUNCTION api.list_secret_rotation_log(
  p_tenant_id uuid DEFAULT NULL,
  p_limit     integer DEFAULT 50
)
RETURNS SETOF data.secret_rotation_log
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT *
  FROM data.secret_rotation_log
  WHERE (p_tenant_id IS NULL OR tenant_id = p_tenant_id)
  ORDER BY created_at DESC
  LIMIT GREATEST(1, LEAST(p_limit, 500));
$$;

REVOKE ALL ON FUNCTION api.list_secret_rotation_log(uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_secret_rotation_log(uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION api.list_secret_rotation_log(uuid, integer) TO service_role;

-- -----------------------------------------------------------------------------
-- 10. Seed platform_secret_registry
-- -----------------------------------------------------------------------------

INSERT INTO data.platform_secret_registry (secret_key, description, category, rotation_due_at) VALUES
  ('RESEND_API_KEY', 'Email transaccional Resend', 'email', now() + interval '365 days'),
  ('RESEND_WEBHOOK_SECRET', 'Validació HMAC webhooks Resend', 'email', now() + interval '365 days'),
  ('ONESIGNAL_APP_ID', 'App ID OneSignal (platform push)', 'push', NULL),
  ('ONESIGNAL_REST_API_KEY', 'REST API key OneSignal platform', 'push', now() + interval '365 days'),
  ('DOCUSEAL_API_KEY', 'API key DocuSeal mode platform', 'signing', now() + interval '365 days'),
  ('DOCUSEAL_WEBHOOK_SECRET', 'HMAC webhooks DocuSeal', 'signing', now() + interval '365 days'),
  ('TWILIO_AUTH_TOKEN', 'Auth token Twilio platform (callbacks)', 'sms', now() + interval '365 days'),
  ('GOTENBERG_WEBHOOK_SECRET', 'HMAC callbacks Gotenberg PDF', 'pdf', now() + interval '365 days'),
  ('AI_PROPOSAL_SECRET', 'HMAC tokens propostes escriptura IA', 'ai', now() + interval '365 days'),
  ('UPSTASH_REDIS_REST_TOKEN', 'Token Redis cues email', 'infra', now() + interval '365 days'),
  ('SUPABASE_SERVICE_ROLE_KEY', 'Clau service role (injectada per Supabase)', 'auth', NULL),
  ('app_supabase_url', 'Vault infra: URL per pg_cron workers', 'infra', NULL),
  ('app_service_role_key', 'Vault infra: service role per pg_cron', 'infra', NULL)
ON CONFLICT (secret_key) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 11. Backfill tenant_secret_refs
-- -----------------------------------------------------------------------------

INSERT INTO data.tenant_secret_refs (
  tenant_id, secret_id, secret_type, provider, label,
  key_version, rotation_status, last_rotated_at, rotation_due_at
)
SELECT
  tenant_id, auth_token_secret_id, 'twilio_auth_token', 'twilio', 'Twilio auth token',
  1, 'active', updated_at, updated_at + interval '365 days'
FROM data.tenant_twilio_config
WHERE auth_token_secret_id IS NOT NULL
ON CONFLICT (tenant_id, secret_type, provider) DO NOTHING;

INSERT INTO data.tenant_secret_refs (
  tenant_id, secret_id, secret_type, provider, label,
  key_version, rotation_status, last_rotated_at, rotation_due_at
)
SELECT
  tenant_id, onesignal_rest_key_secret_id, 'onesignal_key', 'onesignal', 'OneSignal REST key',
  1, 'active', updated_at, updated_at + interval '365 days'
FROM data.tenant_push_config
WHERE onesignal_rest_key_secret_id IS NOT NULL
ON CONFLICT (tenant_id, secret_type, provider) DO NOTHING;

INSERT INTO data.tenant_secret_refs (
  tenant_id, secret_id, secret_type, provider, label,
  key_version, rotation_status, last_rotated_at, rotation_due_at
)
SELECT
  tenant_id, docuseal_key_secret_id, 'docuseal_key', 'docuseal', 'DocuSeal API key',
  1, 'active', updated_at, updated_at + interval '365 days'
FROM data.tenant_signing_config
WHERE docuseal_key_secret_id IS NOT NULL
ON CONFLICT (tenant_id, secret_type, provider) DO NOTHING;

INSERT INTO data.tenant_secret_refs (
  tenant_id, secret_id, secret_type, provider, label,
  key_version, rotation_status, last_rotated_at, rotation_due_at
)
SELECT
  tenant_id, ai_key_secret_id, 'ai_api_key', provider::text, provider::text || ' API key',
  1, 'active', updated_at, updated_at + interval '365 days'
FROM data.tenant_ai_provider_config
WHERE ai_key_secret_id IS NOT NULL
ON CONFLICT (tenant_id, secret_type, provider) DO NOTHING;

-- Storage: només secret_key_id (access_key és públic)
INSERT INTO data.tenant_secret_refs (
  tenant_id, secret_id, secret_type, provider, label,
  key_version, rotation_status, last_rotated_at, rotation_due_at
)
SELECT
  tenant_id, secret_key_id, 'storage_secret_key',
  'storage:' || id::text,
  coalesce(nickname, provider_type::text || ' drive'),
  1, 'active', updated_at, updated_at + interval '365 days'
FROM data.storage_providers
WHERE secret_key_id IS NOT NULL
ON CONFLICT (tenant_id, secret_type, provider) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 12. Catàleg notificacions + cron alertes rotació
-- -----------------------------------------------------------------------------

INSERT INTO data.notification_event_catalog (
  event_code, category, entity_type, deep_link_template,
  default_channels, requires_legal, digest_eligible, description
) VALUES (
  'SECRET_ROTATION_DUE', 'system', 'system', '/settings/secrets',
  '{in_app,email}', false, false,
  'Secret BYO proper a la data de rotació programada'
) ON CONFLICT (event_code) DO NOTHING;

CREATE OR REPLACE FUNCTION data.check_secret_rotation_due()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row      record;
  v_platform record;
  v_sent     integer := 0;
BEGIN
  -- Secrets de tenant: un sol JOIN (no N+1) + guard last_rotation_alert_at
  -- evita tant N+1 queries com spam diari de notificacions.
  -- BETWEEN limita la finestra: ni secrets vells oblidats ni alertes infinites.
  FOR v_row IN
    WITH due_refs AS (
      UPDATE data.tenant_secret_refs
      SET last_rotation_alert_at = now(), updated_at = now()
      WHERE rotation_status = 'active'
        AND rotation_due_at IS NOT NULL
        AND rotation_due_at BETWEEN now() - interval '60 days' AND now() + interval '30 days'
        AND (last_rotation_alert_at IS NULL
             OR last_rotation_alert_at < now() - interval '7 days')
      RETURNING tenant_id, secret_type, provider, label, rotation_due_at
    )
    SELECT
      r.tenant_id, r.secret_type, r.provider, r.label, r.rotation_due_at,
      m.user_id
    FROM due_refs r
    JOIN data.tenant_members m
      ON m.tenant_id = r.tenant_id
     AND m.site_id IS NULL
     AND m.role IN ('owner', 'manager')
     AND m.is_active = true
  LOOP
    PERFORM data.enqueue_notification_dispatch(jsonb_build_object(
      'tenantId',      v_row.tenant_id,
      'eventType',     'SECRET_ROTATION_DUE',
      -- Inclou setmana ISO per evitar duplicats PGMQ entre execucions setmanals
      'correlationId', 'secret_rotation_due:'
                       || v_row.tenant_id::text || ':' || v_row.secret_type || ':'
                       || v_row.provider || ':' || v_row.user_id::text
                       || ':' || to_char(now(), 'IYYY-IW'),
      'recipient',     jsonb_build_object('kind', 'tenant_member', 'userId', v_row.user_id),
      'entityType',    'system',
      'payload',       jsonb_build_object(
        'secret_type',     v_row.secret_type,
        'provider',        v_row.provider,
        'label',           coalesce(v_row.label, v_row.secret_type),
        'rotation_due_at', v_row.rotation_due_at,
        'deep_link',       '/settings/secrets',
        'message',         'Un secret de configuració caduca aviat. Revisa Configuració → Secrets.'
      )
    ));
    v_sent := v_sent + 1;
  END LOOP;

  -- Secrets de plataforma: marcar alerta per admin UI
  FOR v_platform IN
    SELECT id
    FROM data.platform_secret_registry
    WHERE rotation_status = 'active'
      AND rotation_due_at IS NOT NULL
      AND rotation_due_at BETWEEN now() - interval '60 days' AND now() + interval '30 days'
      AND (last_rotation_alert_at IS NULL
           OR last_rotation_alert_at < now() - interval '7 days')
  LOOP
    UPDATE data.platform_secret_registry
    SET last_rotation_alert_at = now(), updated_at = now()
    WHERE id = v_platform.id;
    v_sent := v_sent + 1;
  END LOOP;

  RETURN v_sent;
END;
$$;

REVOKE ALL ON FUNCTION data.check_secret_rotation_due() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.check_secret_rotation_due() TO service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid)
    FROM cron.job
    WHERE jobname = 'check-secret-rotation-due';

    PERFORM cron.schedule(
      'check-secret-rotation-due',
      '0 8 * * *',
      'SELECT data.check_secret_rotation_due()'
    );
  END IF;
END;
$$;
