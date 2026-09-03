-- =============================================================================
-- Migration 7: BYOS (Bring Your Own Storage) configuration RPC
-- =============================================================================
-- api.save_storage_config is the single privileged entrypoint for persisting
-- a tenant's external storage credentials. It is only callable by service_role
-- (i.e., the configure-byos Edge Function) — never directly by end users.
--
-- Security model:
--   • The secret_access_key is stored exclusively in Supabase Vault (pgsodium).
--     It is never written to data.storage_providers in plaintext.
--   • The public access_key (access key ID) is safe to store in plaintext.
--   • SECURITY DEFINER is required to access vault.* functions, which are
--     not callable by authenticated / anon roles.
--   • Explicit REVOKE + GRANT ensures PostgREST cannot expose this function
--     even if the api schema config changes.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- api.save_storage_config
--
-- Upserts a BYOS storage provider record for the given tenant and stores the
-- secret_access_key in Vault.  If a provider already exists for the tenant
-- (UNIQUE constraint on tenant_id), the existing record and vault secret are
-- both updated in-place.  The function marks the provider as is_verified=true
-- because the Edge Function validates the credentials before calling it.
--
-- Parameters:
--   p_tenant_id         — tenant UUID
--   p_provider_type     — 's3' | 'r2' | 'gcs'
--   p_endpoint_url      — custom endpoint (required for r2/gcs; optional for s3)
--   p_region            — AWS/GCS region (nullable for providers that ignore it)
--   p_bucket_name       — target bucket name
--   p_access_key        — public access key ID (stored in plaintext)
--   p_secret_access_key — secret access key   (stored in Vault)
--
-- Returns: uuid of the upserted data.storage_providers row
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.save_storage_config(
  p_tenant_id         uuid,
  p_provider_type     text,
  p_endpoint_url      text,
  p_region            text,
  p_bucket_name       text,
  p_access_key        text,
  p_secret_access_key text
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
  -- -------------------------------------------------------------------------
  -- Guard: only allow the three BYOS provider types. 'supabase' is the default
  -- (no BYOS) and must never be set via this RPC.
  -- -------------------------------------------------------------------------
  IF p_provider_type NOT IN ('s3', 'r2', 'gcs') THEN
    RAISE EXCEPTION 'invalid_provider_type'
      USING HINT = 'provider_type must be one of: s3, r2, gcs';
  END IF;

  -- -------------------------------------------------------------------------
  -- Build a recognisable Vault secret name scoped to this tenant + provider.
  -- Format: byos_<provider>_<tenant_id_no_hyphens>
  -- Example: byos_s3_a1b2c3d4e5f6...
  -- -------------------------------------------------------------------------
  v_secret_name := format(
    'byos_%s_%s',
    p_provider_type,
    replace(p_tenant_id::text, '-', '')
  );
  v_secret_desc := format(
    'BYOS %s secret access key for tenant %s',
    upper(p_provider_type),
    p_tenant_id
  );

  -- -------------------------------------------------------------------------
  -- Check whether a provider record already exists for this tenant.
  -- data.storage_providers has a UNIQUE constraint on tenant_id, so at most
  -- one row is returned.
  -- -------------------------------------------------------------------------
  SELECT * INTO v_existing
  FROM data.storage_providers
  WHERE tenant_id = p_tenant_id;

  IF FOUND THEN
    -- -----------------------------------------------------------------------
    -- UPDATE path: provider exists → manage vault secret then update row
    -- -----------------------------------------------------------------------
    IF v_existing.secret_key_id IS NOT NULL THEN
      -- Rotate the existing secret in-place (Vault keeps the same UUID)
      PERFORM vault.update_secret(
        v_existing.secret_key_id,
        p_secret_access_key,
        v_secret_name,
        v_secret_desc
      );
      v_secret_id := v_existing.secret_key_id;
    ELSE
      -- Provider existed without a secret (e.g., previously set to 'supabase')
      v_secret_id := vault.create_secret(
        p_secret_access_key,
        v_secret_name,
        v_secret_desc
      );
    END IF;

    UPDATE data.storage_providers
    SET
      provider_type  = p_provider_type,
      endpoint_url   = p_endpoint_url,
      region         = p_region,
      bucket_name    = p_bucket_name,
      access_key     = p_access_key,
      secret_key_id  = v_secret_id,
      is_verified    = true,
      is_active      = true,
      updated_at     = now()
    WHERE tenant_id = p_tenant_id
    RETURNING id INTO v_provider_id;

  ELSE
    -- -----------------------------------------------------------------------
    -- INSERT path: no provider yet for this tenant
    -- -----------------------------------------------------------------------
    v_secret_id := vault.create_secret(
      p_secret_access_key,
      v_secret_name,
      v_secret_desc
    );

    INSERT INTO data.storage_providers (
      tenant_id,
      provider_type,
      endpoint_url,
      region,
      bucket_name,
      access_key,
      secret_key_id,
      is_verified,
      is_active
    ) VALUES (
      p_tenant_id,
      p_provider_type,
      p_endpoint_url,
      p_region,
      p_bucket_name,
      p_access_key,
      v_secret_id,
      true,
      true
    )
    RETURNING id INTO v_provider_id;

  END IF;

  RETURN v_provider_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- Security: strip all default grants, then allow only service_role.
-- authenticated / anon can never call this function directly or via PostgREST.
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION api.save_storage_config(uuid, text, text, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.save_storage_config(uuid, text, text, text, text, text, text) FROM authenticated;
REVOKE ALL ON FUNCTION api.save_storage_config(uuid, text, text, text, text, text, text) FROM anon;
GRANT  EXECUTE ON FUNCTION api.save_storage_config(uuid, text, text, text, text, text, text) TO service_role;
