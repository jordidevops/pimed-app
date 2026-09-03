-- =============================================================================
-- Migration 20260506000002: Document Share Links (Phase 3)
-- =============================================================================
-- Implements temporary, revocable public share links for the Documents module.
--
-- Changes:
--   1. data.document_share_links — share link tokens with expiry + revocation
--   2. RLS policies
--   3. api.document_share_links — view for authenticated owner/manager
--   4. api.create_document_share_link() — SECURITY DEFINER, creates token
--   5. api.revoke_document_share_link() — SECURITY DEFINER, marks revoked
--   6. api.resolve_document_share_link() — SECURITY DEFINER, public resolver
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. data.document_share_links
-- ---------------------------------------------------------------------------
CREATE TABLE data.document_share_links (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid        NOT NULL REFERENCES data.tenants(id)           ON DELETE CASCADE,
  document_id         uuid        NOT NULL REFERENCES data.documents(id)         ON DELETE CASCADE,
  document_version_id uuid        NOT NULL REFERENCES data.document_versions(id) ON DELETE CASCADE,
  token               text        NOT NULL UNIQUE,              -- 64-char hex, cryptographically random
  expires_at          timestamptz NOT NULL,
  revoked_at          timestamptz,                              -- NULL = active; NOT NULL = revoked
  created_by          uuid        REFERENCES auth.users(id)    ON DELETE SET NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  last_accessed_at    timestamptz,
  access_count        integer     NOT NULL DEFAULT 0
);

CREATE INDEX idx_doc_share_token    ON data.document_share_links (token);
CREATE INDEX idx_doc_share_tenant   ON data.document_share_links (tenant_id, created_at DESC);
CREATE INDEX idx_doc_share_document ON data.document_share_links (document_id, created_at DESC);
CREATE INDEX idx_doc_share_expires  ON data.document_share_links (expires_at)
  WHERE revoked_at IS NULL;

COMMENT ON TABLE data.document_share_links
  IS 'Temporary public share tokens for the DMS (Documents) module. Separate from data.share_links (Drive/BYOS).';
COMMENT ON COLUMN data.document_share_links.token
  IS '64-character hex string (256-bit random). Stored in plaintext; transmitted over HTTPS only.';

-- ---------------------------------------------------------------------------
-- 2. RLS
-- ---------------------------------------------------------------------------
ALTER TABLE data.document_share_links ENABLE ROW LEVEL SECURITY;

-- Owner/manager can see share links for their tenant
CREATE POLICY "doc_share_links: owner/manager select"
  ON data.document_share_links FOR SELECT
  TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

-- INSERT and UPDATE only via SECURITY DEFINER RPCs (service_role context)
CREATE POLICY "doc_share_links: service_role insert"
  ON data.document_share_links FOR INSERT
  TO service_role
  WITH CHECK (true);

CREATE POLICY "doc_share_links: service_role update"
  ON data.document_share_links FOR UPDATE
  TO service_role
  USING (true)
  WITH CHECK (true);

-- ---------------------------------------------------------------------------
-- 3. api.document_share_links view
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.document_share_links
  WITH (security_invoker = true) AS
  SELECT
    dsl.id,
    dsl.tenant_id,
    dsl.document_id,
    dsl.document_version_id,
    dsl.token,
    dsl.expires_at,
    dsl.revoked_at,
    dsl.created_by,
    dsl.created_at,
    dsl.last_accessed_at,
    dsl.access_count,
    -- Computed: link is still usable
    (dsl.revoked_at IS NULL AND dsl.expires_at > now()) AS is_active
  FROM data.document_share_links dsl;

GRANT SELECT ON api.document_share_links TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. api.create_document_share_link — creates a new token
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.create_document_share_link(
  p_tenant_id           uuid,
  p_document_id         uuid,
  p_document_version_id uuid,
  p_expiry_seconds      integer DEFAULT 86400  -- 24 h
)
RETURNS TABLE (
  id         uuid,
  token      text,
  expires_at timestamptz
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = data AS $$
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
  v_token      := encode(gen_random_bytes(32), 'hex');
  v_expires_at := now() + (p_expiry_seconds || ' seconds')::interval;

  -- Insert (bypasses RLS via SECURITY DEFINER / service_role context)
  INSERT INTO data.document_share_links (
    tenant_id, document_id, document_version_id, token, expires_at, created_by
  )
  VALUES (
    p_tenant_id, p_document_id, p_document_version_id, v_token, v_expires_at, auth.uid()
  )
  RETURNING data.document_share_links.id INTO v_id;

  -- Audit (fire-and-forget: error here would bubble up but that's acceptable)
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
-- 5. api.revoke_document_share_link — marks a link as revoked
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.revoke_document_share_link(
  p_share_link_id uuid
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = data AS $$
DECLARE
  v_link        data.document_share_links%ROWTYPE;
  v_global_role text;
BEGIN
  -- Fetch link (SECURITY DEFINER bypasses RLS so we see any row)
  SELECT * INTO v_link FROM data.document_share_links WHERE id = p_share_link_id;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  -- Auth: must be owner/manager of the tenant that owns the link
  v_global_role := data.jwt_user_tenants() -> v_link.tenant_id::text ->> 'global_role';
  IF v_global_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'insufficient_permissions';
  END IF;

  -- Already revoked → idempotent success
  IF v_link.revoked_at IS NOT NULL THEN
    RETURN true;
  END IF;

  UPDATE data.document_share_links
  SET revoked_at = now()
  WHERE id = p_share_link_id;

  -- Audit
  PERFORM data.log_audit_event(
    v_link.tenant_id,
    auth.uid(),
    NULL,
    'DOCUMENT_SHARE_LINK_REVOKED',
    'document_share_link',
    p_share_link_id,
    jsonb_build_object('document_id', v_link.document_id)
  );

  RETURN true;
END;
$$;

REVOKE ALL   ON FUNCTION api.revoke_document_share_link(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.revoke_document_share_link(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. api.resolve_document_share_link — public resolver (anon + service_role)
-- ---------------------------------------------------------------------------
-- Returns the version's storage path so the caller can sign a URL.
-- Atomically increments access_count and updates last_accessed_at.
-- Returns empty result if token is unknown (→ 404) or expired/revoked (→ 410).
CREATE OR REPLACE FUNCTION api.resolve_document_share_link(
  p_token text
)
RETURNS TABLE (
  storage_path text,
  document_id  uuid,
  version_id   uuid,
  tenant_id    uuid,
  title        text,
  is_expired   boolean,
  is_revoked   boolean
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = data AS $$
DECLARE
  v_link data.document_share_links%ROWTYPE;
BEGIN
  -- Look up the link (FOR UPDATE SKIP LOCKED prevents thundering-herd on counters)
  SELECT * INTO v_link
  FROM data.document_share_links
  WHERE token = p_token
  FOR UPDATE SKIP LOCKED;

  IF NOT FOUND THEN
    -- Return a sentinel row so the caller knows it's a missing token (not a skip-lock miss)
    RETURN QUERY SELECT NULL::text, NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, false, false
    WHERE false;
    RETURN;
  END IF;

  -- Expired or revoked: return metadata without signing or bumping counter
  IF v_link.revoked_at IS NOT NULL THEN
    RETURN QUERY SELECT
      NULL::text, v_link.document_id, v_link.document_version_id,
      v_link.tenant_id, NULL::text, false, true;
    RETURN;
  END IF;

  IF v_link.expires_at <= now() THEN
    RETURN QUERY SELECT
      NULL::text, v_link.document_id, v_link.document_version_id,
      v_link.tenant_id, NULL::text, true, false;
    RETURN;
  END IF;

  -- Valid: bump counters
  UPDATE data.document_share_links
  SET last_accessed_at = now(),
      access_count     = access_count + 1
  WHERE id = v_link.id;

  -- Return version info
  RETURN QUERY
    SELECT
      dv.file_path_or_url::text AS storage_path,
      d.id                      AS document_id,
      dv.id                     AS version_id,
      d.tenant_id               AS tenant_id,
      d.title                   AS title,
      false                     AS is_expired,
      false                     AS is_revoked
    FROM data.document_versions dv
    JOIN data.documents         d ON d.id = dv.document_id
    WHERE dv.id = v_link.document_version_id;
END;
$$;

REVOKE ALL   ON FUNCTION api.resolve_document_share_link(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.resolve_document_share_link(text) TO anon;
GRANT EXECUTE ON FUNCTION api.resolve_document_share_link(text) TO service_role;

-- Grants for new table
GRANT SELECT, INSERT, UPDATE ON data.document_share_links TO service_role;
GRANT SELECT ON data.document_share_links TO prisma_admin;
