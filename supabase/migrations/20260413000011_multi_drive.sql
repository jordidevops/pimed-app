-- =============================================================================
-- Migration: Multi-Drive Storage Architecture
-- =============================================================================
-- Extends data.storage_providers to support up to 3 BYOS drives per tenant.
-- Changes:
--   1. Drop UNIQUE(tenant_id) — allow multiple providers per tenant
--   2. Add columns: nickname, allowed_mime_types, max_file_size_bytes,
--      quota_limit_bytes, is_locked
--   3. Trigger: enforce max 3 BYOS providers per tenant
--   4. Rebuild api.storage_provider view with new columns
--   5. Replace api.save_storage_config — support p_provider_id for UPDATE
--   6. Replace api.get_storage_provider_with_secret — add p_provider_id param
--   7. NEW api.delete_storage_config — remove a BYOS drive
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Drop UNIQUE(tenant_id) — multiple BYOS providers per tenant allowed now
-- ---------------------------------------------------------------------------
ALTER TABLE data.storage_providers
  DROP CONSTRAINT IF EXISTS storage_providers_tenant_id_key;

-- ---------------------------------------------------------------------------
-- 2. Add new columns
-- ---------------------------------------------------------------------------
ALTER TABLE data.storage_providers
  ADD COLUMN IF NOT EXISTS nickname            text,
  ADD COLUMN IF NOT EXISTS allowed_mime_types  text[],
  ADD COLUMN IF NOT EXISTS max_file_size_bytes bigint  DEFAULT 52428800,  -- 50 MB default
  ADD COLUMN IF NOT EXISTS quota_limit_bytes   bigint,
  ADD COLUMN IF NOT EXISTS is_locked           boolean NOT NULL DEFAULT false;

-- ---------------------------------------------------------------------------
-- 3. Trigger: enforce max 3 BYOS providers per tenant
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.enforce_byos_limit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF (
    SELECT count(*)
    FROM data.storage_providers
    WHERE tenant_id = NEW.tenant_id
      AND provider_type != 'supabase'
  ) >= 3 THEN
    RAISE EXCEPTION 'max_drives_exceeded'
      USING HINT = 'Un tenant pot tenir un màxim de 3 proveïdors BYOS';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_storage_providers_byos_limit
  BEFORE INSERT ON data.storage_providers
  FOR EACH ROW
  WHEN (NEW.provider_type != 'supabase')
  EXECUTE FUNCTION data.enforce_byos_limit();

-- ---------------------------------------------------------------------------
-- 4. Rebuild api.storage_provider view — expose new columns
-- ---------------------------------------------------------------------------
-- DROP + CREATE is required because CREATE OR REPLACE VIEW cannot change
-- column order when the view already exists with a different column definition.
DROP VIEW IF EXISTS api.storage_provider;

CREATE VIEW api.storage_provider
  WITH (security_invoker = true) AS
  SELECT
    id,
    tenant_id,
    provider_type,
    endpoint_url,
    bucket_name,
    region,
    is_verified,
    is_active,
    is_locked,
    nickname,
    allowed_mime_types,
    max_file_size_bytes,
    quota_limit_bytes,
    created_at,
    updated_at
  FROM data.storage_providers;

GRANT SELECT, INSERT, UPDATE ON api.storage_provider TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Replace api.save_storage_config
--    New params: p_provider_id (UPDATE existing), p_nickname, p_allowed_mime_types,
--    p_max_file_size_bytes, p_quota_limit_bytes.
--    Old 7-param signature is dropped; Supabase RPC uses named params so existing
--    callers passing named params continue to work with defaults for new params.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.save_storage_config(uuid, text, text, text, text, text, text);

CREATE OR REPLACE FUNCTION api.save_storage_config(
  p_tenant_id              uuid,
  p_provider_type          text,
  p_endpoint_url           text,
  p_region                 text,
  p_bucket_name            text,
  p_access_key             text,
  p_secret_access_key      text,
  p_provider_id            uuid    DEFAULT NULL,
  p_nickname               text    DEFAULT NULL,
  p_allowed_mime_types     text[]  DEFAULT NULL,
  p_max_file_size_bytes    bigint  DEFAULT NULL,
  p_quota_limit_bytes      bigint  DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_existing    data.storage_providers%ROWTYPE;
  v_secret_id   uuid;
  v_secret_name text;
  v_secret_desc text;
  v_provider_id uuid;
BEGIN
  -- Guard: only BYOS provider types
  IF p_provider_type NOT IN ('s3', 'r2', 'gcs') THEN
    RAISE EXCEPTION 'invalid_provider_type'
      USING HINT = 'provider_type must be one of: s3, r2, gcs';
  END IF;

  IF p_provider_id IS NOT NULL THEN
    -- -----------------------------------------------------------------------
    -- UPDATE existing provider by id
    -- -----------------------------------------------------------------------
    SELECT * INTO v_existing
    FROM data.storage_providers
    WHERE id = p_provider_id AND tenant_id = p_tenant_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'provider_not_found'
        USING HINT = 'El proveïdor especificat no existeix o no pertany al tenant';
    END IF;

    v_secret_id := v_existing.secret_key_id;
    IF p_secret_access_key IS NOT NULL AND p_secret_access_key != '' THEN
      v_secret_name := format('byos_%s_%s', p_provider_type, replace(p_provider_id::text, '-', ''));
      v_secret_desc := format('BYOS %s secret for provider %s', upper(p_provider_type), p_provider_id);
      IF v_existing.secret_key_id IS NOT NULL THEN
        PERFORM vault.update_secret(v_existing.secret_key_id, p_secret_access_key, v_secret_name, v_secret_desc);
      ELSE
        v_secret_id := vault.create_secret(p_secret_access_key, v_secret_name, v_secret_desc);
      END IF;
    END IF;

    UPDATE data.storage_providers
    SET
      provider_type         = p_provider_type,
      endpoint_url          = p_endpoint_url,
      region                = p_region,
      bucket_name           = p_bucket_name,
      access_key            = CASE
                                WHEN p_access_key IS NOT NULL AND p_access_key != ''
                                THEN p_access_key
                                ELSE access_key
                              END,
      secret_key_id         = v_secret_id,
      is_verified           = true,
      is_active             = true,
      nickname              = COALESCE(p_nickname, nickname),
      allowed_mime_types    = COALESCE(p_allowed_mime_types, allowed_mime_types),
      max_file_size_bytes   = COALESCE(p_max_file_size_bytes, max_file_size_bytes),
      quota_limit_bytes     = CASE
                                WHEN p_quota_limit_bytes = 0 THEN NULL
                                WHEN p_quota_limit_bytes IS NULL THEN quota_limit_bytes
                                ELSE p_quota_limit_bytes
                              END,
      updated_at            = now()
    WHERE id = p_provider_id
    RETURNING id INTO v_provider_id;

  ELSE
    -- -----------------------------------------------------------------------
    -- INSERT new provider
    -- -----------------------------------------------------------------------
    v_provider_id := gen_random_uuid();
    v_secret_name := format('byos_%s_%s', p_provider_type, replace(v_provider_id::text, '-', ''));
    v_secret_desc := format('BYOS %s secret for provider %s', upper(p_provider_type), v_provider_id);

    v_secret_id := vault.create_secret(p_secret_access_key, v_secret_name, v_secret_desc);

    INSERT INTO data.storage_providers (
      id, tenant_id, provider_type, endpoint_url, region, bucket_name,
      access_key, secret_key_id, is_verified, is_active,
      nickname, allowed_mime_types, max_file_size_bytes, quota_limit_bytes
    ) VALUES (
      v_provider_id, p_tenant_id, p_provider_type, p_endpoint_url, p_region, p_bucket_name,
      p_access_key, v_secret_id, true, true,
      p_nickname, p_allowed_mime_types,
      COALESCE(p_max_file_size_bytes, 52428800),
      CASE WHEN p_quota_limit_bytes = 0 THEN NULL ELSE p_quota_limit_bytes END
    );

  END IF;

  RETURN v_provider_id;
END;
$$;

REVOKE ALL ON FUNCTION api.save_storage_config(uuid, text, text, text, text, text, text, uuid, text, text[], bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.save_storage_config(uuid, text, text, text, text, text, text, uuid, text, text[], bigint, bigint) FROM authenticated;
REVOKE ALL ON FUNCTION api.save_storage_config(uuid, text, text, text, text, text, text, uuid, text, text[], bigint, bigint) FROM anon;
GRANT  EXECUTE ON FUNCTION api.save_storage_config(uuid, text, text, text, text, text, text, uuid, text, text[], bigint, bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- 6. Replace api.get_storage_provider_with_secret
--    Adds p_provider_id param: when set, fetch by provider id;
--    otherwise fetch by tenant_id (backward compat).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.get_storage_provider_with_secret(uuid);

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
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT
    sp.id,
    sp.provider_type,
    sp.endpoint_url,
    sp.bucket_name,
    sp.access_key,
    vs.decrypted_secret AS secret_key,
    sp.region,
    sp.allowed_mime_types,
    sp.max_file_size_bytes,
    sp.is_locked
  FROM data.storage_providers sp
  LEFT JOIN vault.decrypted_secrets vs ON vs.id = sp.secret_key_id
  WHERE sp.is_active    = true
    AND sp.is_verified  = true
    AND (
      (p_provider_id IS NOT NULL AND sp.id         = p_provider_id)
      OR
      (p_provider_id IS NULL     AND sp.tenant_id  = p_tenant_id)
    );
$$;

REVOKE ALL ON FUNCTION api.get_storage_provider_with_secret(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_storage_provider_with_secret(uuid, uuid) FROM authenticated;
REVOKE ALL ON FUNCTION api.get_storage_provider_with_secret(uuid, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION api.get_storage_provider_with_secret(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 7. NEW api.delete_storage_config — removes a BYOS provider + vault secret
--    Callable by service_role only (configure-byos Edge Function).
--    Validates that the provider belongs to the tenant and is not 'supabase'.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.delete_storage_config(
  p_provider_id uuid,
  p_tenant_id   uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_provider data.storage_providers%ROWTYPE;
BEGIN
  SELECT * INTO v_provider
  FROM data.storage_providers
  WHERE id = p_provider_id AND tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'provider_not_found'
      USING HINT = 'El proveïdor especificat no existeix o no pertany al tenant';
  END IF;

  IF v_provider.provider_type = 'supabase' THEN
    RAISE EXCEPTION 'cannot_delete_default_provider'
      USING HINT = 'El proveïdor Supabase per defecte no es pot eliminar';
  END IF;

  -- Delete Vault secret if it exists
  IF v_provider.secret_key_id IS NOT NULL THEN
    DELETE FROM vault.secrets WHERE id = v_provider.secret_key_id;
  END IF;

  -- Delete the provider record
  DELETE FROM data.storage_providers WHERE id = p_provider_id;
END;
$$;

REVOKE ALL ON FUNCTION api.delete_storage_config(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.delete_storage_config(uuid, uuid) FROM authenticated;
REVOKE ALL ON FUNCTION api.delete_storage_config(uuid, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION api.delete_storage_config(uuid, uuid) TO service_role;
