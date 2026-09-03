-- =============================================================================
-- Migration 20260526000001: Fix document share links RPC + view permissions
-- =============================================================================
-- Fixes:
--   1. api.create_document_share_link: gen_random_bytes not found because
--      SET search_path = data excluded the extensions schema.
--      Fix: add extensions to the search path.
--   2. api.document_share_links (security_invoker = true): authenticated role
--      had no SELECT grant on data.document_share_links. The view runs as the
--      invoking user, so the underlying table must be accessible.
--      Fix: GRANT SELECT on data.document_share_links TO authenticated.
--      RLS policies already restrict rows to owner/manager of the tenant.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Fix gen_random_bytes: add extensions to search_path
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.create_document_share_link(
  p_tenant_id           uuid,
  p_document_id         uuid,
  p_document_version_id uuid,
  p_expiry_seconds      integer DEFAULT 86400
)
RETURNS TABLE (
  id         uuid,
  token      text,
  expires_at timestamptz
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = data, extensions AS $$
DECLARE
  v_global_role text;
  v_token       text;
  v_expires_at  timestamptz;
  v_id          uuid;
BEGIN
  -- Auth: must be owner or manager of the tenant
  v_global_role := data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role';
  IF v_global_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'insufficient_permissions'
      USING HINT = 'owner or manager role required to create share links';
  END IF;

  -- Tenant context coherence
  IF data.active_tenant_id() IS NOT NULL AND data.active_tenant_id() <> p_tenant_id THEN
    RAISE EXCEPTION 'tenant_mismatch'
      USING HINT = 'p_tenant_id does not match the active tenant context';
  END IF;

  -- Validate document belongs to tenant
  IF NOT EXISTS (
    SELECT 1 FROM data.documents d
    WHERE d.id = p_document_id AND d.tenant_id = p_tenant_id
  ) THEN
    RAISE EXCEPTION 'document_not_found';
  END IF;

  -- Validate version belongs to document and is native storage
  IF NOT EXISTS (
    SELECT 1 FROM data.document_versions dv
    WHERE dv.id = p_document_version_id
      AND dv.document_id = p_document_id
      AND dv.storage_type = 'native'
  ) THEN
    RAISE EXCEPTION 'version_not_found_or_not_native'
      USING HINT = 'Share links require native storage; external_link versions are already public URLs';
  END IF;

  -- Generate token and expiry
  v_token      := encode(extensions.gen_random_bytes(32), 'hex');
  v_expires_at := now() + (p_expiry_seconds || ' seconds')::interval;

  -- Insert (bypasses RLS via SECURITY DEFINER / postgres role)
  INSERT INTO data.document_share_links (
    tenant_id, document_id, document_version_id, token, expires_at, created_by
  )
  VALUES (
    p_tenant_id, p_document_id, p_document_version_id, v_token, v_expires_at, auth.uid()
  )
  RETURNING data.document_share_links.id INTO v_id;

  -- Audit (fire-and-forget)
  PERFORM data.log_audit_event(
    p_tenant_id,
    auth.uid(),
    NULL,
    'DOCUMENT_SHARE_LINK_CREATED',
    'document_share_link',
    v_id,
    jsonb_build_object(
      'document_id',         p_document_id,
      'document_version_id', p_document_version_id,
      'expires_at',          v_expires_at
    )
  );

  RETURN QUERY SELECT v_id, v_token, v_expires_at;
END;
$$;

REVOKE ALL   ON FUNCTION api.create_document_share_link(uuid, uuid, uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_document_share_link(uuid, uuid, uuid, integer) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Fix view permission: authenticated needs SELECT on the underlying table
--    (security_invoker = true runs queries as the calling user)
-- ---------------------------------------------------------------------------
GRANT SELECT ON data.document_share_links TO authenticated;
