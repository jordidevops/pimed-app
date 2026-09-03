-- =============================================================================
-- CP-C — Customer portal light (named customer access, account+principal model)
-- Additive rollout share_only -> portal, invitations + grants + grant sessions,
-- return-visit login tokens (no JWT in browser), bulletin listing for a grant.
--
-- Scope model (CP-C):
--   * every grant/invitation is scoped to (client_account_contact_id, principal)
--   * principal_kind = 'named_person'   -> principal_contact_id is a real person
--   * principal_kind = 'shared_mailbox' -> principal_contact_id is whoever owns
--     the delivery channel (the company account itself, or a related contact)
--   * a person account can be its own principal (principal_contact_id = account)
--
-- Identity rules (hard constraints):
--   * customers NEVER become data.tenant_members
--   * no new app_role for customers
--   * privileged resolve/list helpers are service_role only (Edge Functions)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Product rollout: share_only -> portal (additive, no downgrades)
-- ---------------------------------------------------------------------------

-- Default channel contract for new plans is now 'portal'
CREATE OR REPLACE FUNCTION data.portal_entitlements_default()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT jsonb_build_object(
    'employee_portal', jsonb_build_object('included', true, 'cms_tier', 'basic'),
    'public_portal', jsonb_build_object('included', false, 'cms_tier', 'none'),
    'customer_portal', jsonb_build_object(
      'included', true,
      'mode', 'portal',
      'customer_users_limit', NULL,
      'active_share_guardrail', 500,
      'customer_mau_alert_threshold', 1000,
      'included_email_deliveries_month', 2000
    )
  );
$$;

-- Plans: ensure customer_portal exists and upgrade mode to 'portal' (merge, keep unknown keys)
UPDATE data.plans p
SET portal_entitlements = COALESCE(p.portal_entitlements, '{}'::jsonb)
  || jsonb_build_object(
    'customer_portal',
    data.merge_customer_portal_entitlements(p.portal_entitlements->'customer_portal')
      || jsonb_build_object('mode', 'portal')
  );

-- Platform rollout cap: portal mode becomes reachable.
-- security_version bump is intentional: it invalidates every in-flight customer
-- portal session (shares included) so nobody keeps a pre-rollout session.
UPDATE data.customer_portal_platform_state
SET
  max_mode = 'portal',
  security_version = security_version + 1,
  updated_at = now(),
  note = 'CP-C rollout: customer portal light enabled (max_mode=portal, account+principal model)'
WHERE id;

-- Tenant snapshots: additive merge so mode upgrades to portal without touching
-- employee/public channels (merge helpers are max/OR based).
UPDATE data.tenants t
SET tenant_portal_entitlements = data.merge_portal_entitlements_up(
  COALESCE(NULLIF(t.tenant_portal_entitlements, '{}'::jsonb), '{}'::jsonb),
  data.tenant_portal_entitlements_from_plan(t.plan_id)
);

-- ---------------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------------

-- 2.1 Invitations (single-use, hashed secret)
CREATE TABLE IF NOT EXISTS data.customer_access_invitations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  -- The client (company or person) whose portal this invitation opens.
  client_account_contact_id uuid NOT NULL REFERENCES data.contacts(id) ON DELETE RESTRICT,
  -- Who logs in: a real person, or whoever owns the shared mailbox channel
  -- (may be the account itself, or a related contact).
  principal_kind text NOT NULL CHECK (principal_kind IN ('named_person', 'shared_mailbox')),
  principal_contact_id uuid NOT NULL REFERENCES data.contacts(id) ON DELETE RESTRICT,
  -- Set only when a company<->person relationship backed this invitation
  -- (named_person under a company account with a distinct principal).
  contact_relationship_id uuid REFERENCES data.contact_relationships(id) ON DELETE SET NULL,
  delivery_channel_id uuid REFERENCES data.contact_delivery_channels(id) ON DELETE SET NULL,
  email_normalized text NOT NULL CHECK (btrim(email_normalized) <> ''),
  invited_by uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  token_hash bytea NOT NULL,
  expires_at timestamptz NOT NULL,
  accepted_at timestamptz,
  accepted_auth_user_id uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  revoked_at timestamptz,
  revoked_by uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  revoke_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT customer_access_invitations_expires_after_create
    CHECK (expires_at > created_at)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_customer_access_invitations_token_hash
  ON data.customer_access_invitations (token_hash);

CREATE INDEX IF NOT EXISTS idx_cai_tenant_created
  ON data.customer_access_invitations (tenant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_cai_tenant_pending
  ON data.customer_access_invitations (tenant_id, expires_at)
  WHERE accepted_at IS NULL AND revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_cai_tuple_pending
  ON data.customer_access_invitations
     (tenant_id, client_account_contact_id, principal_kind, principal_contact_id)
  WHERE accepted_at IS NULL AND revoked_at IS NULL;

COMMENT ON TABLE data.customer_access_invitations IS
  'CP-C: one-shot invitations to named customer portal access. Scope is '
  '(client_account_contact, principal_kind, principal_contact). Only token_hash '
  '(SHA-256) is stored; the plaintext secret is returned once at creation.';

-- 2.2 Grants (a customer identity scoped to account+principal inside one tenant)
CREATE TABLE IF NOT EXISTS data.customer_access_grants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  -- auth.users id. data.profiles is auto-created for every auth user by trigger,
  -- so the FK is safe and gives us cascade-on-user-delete without auth coupling.
  auth_user_id uuid NOT NULL REFERENCES data.profiles(id) ON DELETE CASCADE,
  client_account_contact_id uuid NOT NULL REFERENCES data.contacts(id) ON DELETE RESTRICT,
  principal_kind text NOT NULL CHECK (principal_kind IN ('named_person', 'shared_mailbox')),
  principal_contact_id uuid NOT NULL REFERENCES data.contacts(id) ON DELETE RESTRICT,
  contact_relationship_id uuid REFERENCES data.contact_relationships(id) ON DELETE SET NULL,
  email_normalized text NOT NULL CHECK (btrim(email_normalized) <> ''),
  session_version integer NOT NULL DEFAULT 1 CHECK (session_version >= 1),
  security_version_tenant integer NOT NULL,
  security_version_platform integer NOT NULL,
  invitation_id uuid REFERENCES data.customer_access_invitations(id) ON DELETE SET NULL,
  last_seen_at timestamptz,
  revoked_at timestamptz,
  revoked_by uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  revoke_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_customer_access_grants_active
  ON data.customer_access_grants
     (tenant_id, client_account_contact_id, principal_kind, principal_contact_id, auth_user_id)
  WHERE revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_cag_tenant_email_active
  ON data.customer_access_grants (tenant_id, email_normalized)
  WHERE revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_cag_auth_user_active
  ON data.customer_access_grants (auth_user_id)
  WHERE revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_cag_email_active
  ON data.customer_access_grants (email_normalized)
  WHERE revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_cag_tenant_created
  ON data.customer_access_grants (tenant_id, created_at DESC);

COMMENT ON TABLE data.customer_access_grants IS
  'CP-C: named customer access. Never a tenant_member; scope is exactly '
  '(tenant, client_account_contact, principal_kind, principal_contact). '
  'Revoke bumps session_version.';

DROP TRIGGER IF EXISTS trg_customer_access_grants_updated_at ON data.customer_access_grants;
CREATE TRIGGER trg_customer_access_grants_updated_at
  BEFORE UPDATE ON data.customer_access_grants
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

-- 2.3 Grant sessions (opaque bearer cookie held by the portal edge, hashed here)
CREATE TABLE IF NOT EXISTS data.customer_portal_grant_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  grant_id uuid NOT NULL REFERENCES data.customer_access_grants(id) ON DELETE CASCADE,
  session_token_hash bytea NOT NULL,
  session_version integer NOT NULL,
  security_version_tenant integer NOT NULL,
  security_version_platform integer NOT NULL,
  expires_at timestamptz NOT NULL,
  last_seen_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  ip_address inet,
  user_agent text,
  CONSTRAINT customer_portal_grant_sessions_ttl_positive
    CHECK (expires_at > created_at)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_cpgs_session_hash
  ON data.customer_portal_grant_sessions (session_token_hash);

CREATE INDEX IF NOT EXISTS idx_cpgs_grant
  ON data.customer_portal_grant_sessions (grant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_cpgs_tenant_expires
  ON data.customer_portal_grant_sessions (tenant_id, expires_at)
  WHERE revoked_at IS NULL;

COMMENT ON TABLE data.customer_portal_grant_sessions IS
  'CP-C: opaque portal sessions for a customer grant. No JWT ever reaches the browser.';

-- 2.4 Return-visit login tokens (short TTL magic-link handoff)
CREATE TABLE IF NOT EXISTS data.customer_portal_login_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  grant_id uuid NOT NULL REFERENCES data.customer_access_grants(id) ON DELETE CASCADE,
  email_normalized text NOT NULL CHECK (btrim(email_normalized) <> ''),
  token_hash bytea NOT NULL,
  expires_at timestamptz NOT NULL,
  used_at timestamptz,
  ip_address inet,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT customer_portal_login_tokens_expires_after_create
    CHECK (expires_at > created_at)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_cplt_token_hash
  ON data.customer_portal_login_tokens (token_hash);

CREATE INDEX IF NOT EXISTS idx_cplt_grant
  ON data.customer_portal_login_tokens (grant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_cplt_open
  ON data.customer_portal_login_tokens (expires_at)
  WHERE used_at IS NULL;

COMMENT ON TABLE data.customer_portal_login_tokens IS
  'CP-C: single-use short-TTL (15-30 min) return-visit tokens. Hash only.';

-- ---------------------------------------------------------------------------
-- 3. Bulletin listing indexes
--    customer_intervention_report_versions is append-only: there is no
--    superseded_at column, "current" lives in
--    customer_intervention_reports.current_published_version_id. There is no
--    per-version recipient column: visibility is scoped to the client account
--    contact only (customer_account_contact_id).
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_cirv_tenant_account_published
  ON data.customer_intervention_report_versions
     (tenant_id, customer_account_contact_id, published_at DESC);

CREATE INDEX IF NOT EXISTS idx_cir_tenant_current_version
  ON data.customer_intervention_reports (tenant_id, current_published_version_id)
  WHERE current_published_version_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 4. Access logs: reuse the CP-A2 partitioned ledger for grant traffic
-- ---------------------------------------------------------------------------
ALTER TABLE data.customer_report_share_access_logs
  ADD COLUMN IF NOT EXISTS grant_id uuid;

ALTER TABLE data.customer_report_share_access_logs
  DROP CONSTRAINT IF EXISTS customer_report_share_access_logs_action_check;

ALTER TABLE data.customer_report_share_access_logs
  ADD CONSTRAINT customer_report_share_access_logs_action_check
  CHECK (action IN (
    'session_create',
    'report_view',
    'media_download',
    'resolve_denied',
    'session_denied',
    'rate_limited',
    'list_bulletins',
    'invitation_accepted',
    'login_token_requested',
    'login_token_exchanged'
  ));

CREATE INDEX IF NOT EXISTS idx_crsal_grant_accessed
  ON data.customer_report_share_access_logs (grant_id, accessed_at DESC);

-- ---------------------------------------------------------------------------
-- 5. RLS + grants
-- ---------------------------------------------------------------------------
ALTER TABLE data.customer_access_invitations ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.customer_access_grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.customer_portal_grant_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.customer_portal_login_tokens ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS cai_select ON data.customer_access_invitations;
CREATE POLICY cai_select ON data.customer_access_invitations FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id()));

-- Writes only via SECURITY DEFINER RPCs — no direct INSERT/UPDATE from clients.
DROP POLICY IF EXISTS cai_insert ON data.customer_access_invitations;
DROP POLICY IF EXISTS cai_update ON data.customer_access_invitations;

-- Grants are written by the privileged accept/revoke paths only.
DROP POLICY IF EXISTS cag_select ON data.customer_access_grants;
CREATE POLICY cag_select ON data.customer_access_grants FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id()));

-- Grant sessions / login tokens: no authenticated policies at all (service_role only).

GRANT SELECT ON data.customer_access_invitations TO authenticated;
GRANT SELECT ON data.customer_access_grants TO authenticated;

GRANT ALL ON data.customer_access_invitations TO service_role;
GRANT ALL ON data.customer_access_grants TO service_role;
GRANT ALL ON data.customer_portal_grant_sessions TO service_role;
GRANT ALL ON data.customer_portal_login_tokens TO service_role;

-- ---------------------------------------------------------------------------
-- 6. API views (never expose token hashes)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.customer_access_invitations
WITH (security_invoker = true) AS
SELECT
  i.id,
  i.tenant_id,
  i.client_account_contact_id,
  i.principal_kind,
  i.principal_contact_id,
  i.contact_relationship_id,
  i.delivery_channel_id,
  i.email_normalized,
  i.invited_by,
  i.expires_at,
  i.accepted_at,
  i.accepted_auth_user_id,
  i.revoked_at,
  i.revoked_by,
  i.revoke_reason,
  i.created_at,
  (i.accepted_at IS NULL AND i.revoked_at IS NULL AND i.expires_at > now()) AS is_pending
FROM data.customer_access_invitations i;

CREATE OR REPLACE VIEW api.customer_access_grants
WITH (security_invoker = true) AS
SELECT
  g.id,
  g.tenant_id,
  g.auth_user_id,
  g.client_account_contact_id,
  g.principal_kind,
  g.principal_contact_id,
  g.contact_relationship_id,
  g.email_normalized,
  g.session_version,
  g.invitation_id,
  g.last_seen_at,
  g.revoked_at,
  g.revoked_by,
  g.revoke_reason,
  g.created_at,
  g.updated_at,
  (g.revoked_at IS NULL) AS is_active
FROM data.customer_access_grants g;

GRANT SELECT ON api.customer_access_invitations TO authenticated;
GRANT SELECT ON api.customer_access_grants TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. Internal helpers / asserts
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.count_active_customer_access_grants(p_tenant_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT COUNT(DISTINCT g.auth_user_id)::integer
  FROM data.customer_access_grants g
  WHERE g.tenant_id = p_tenant_id
    AND g.revoked_at IS NULL;
$$;

REVOKE ALL ON FUNCTION data.count_active_customer_access_grants(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.count_active_customer_access_grants(uuid)
  TO authenticated, service_role;

-- Mirrors data.assert_can_create_customer_report_share but for named access.
-- p_count_new = false when re-activating an already existing live grant (no new seat).
CREATE OR REPLACE FUNCTION data.assert_can_grant_customer_portal_access(
  p_tenant_id uuid,
  p_count_new boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_ent jsonb;
  v_cp jsonb;
  v_limit integer;
  v_active integer;
BEGIN
  v_ent := data.resolve_portal_entitlements(p_tenant_id);
  v_cp := v_ent->'customer_portal';

  IF NOT COALESCE((v_cp->>'can_grant_portal_access')::boolean, false) THEN
    RAISE EXCEPTION 'customer_portal_access_grants_not_allowed'
      USING ERRCODE = 'P0001', DETAIL = v_cp::text;
  END IF;

  IF COALESCE(p_count_new, true)
     AND jsonb_typeof(v_cp->'customer_users_limit') = 'number' THEN
    v_limit := (v_cp->>'customer_users_limit')::integer;
    v_active := data.count_active_customer_access_grants(p_tenant_id);
    IF v_active >= v_limit THEN
      RAISE EXCEPTION 'customer_users_limit_reached'
        USING ERRCODE = 'P0001',
              DETAIL = jsonb_build_object('active', v_active, 'limit', v_limit)::text;
    END IF;
  END IF;

  RETURN v_cp;
END;
$$;

REVOKE ALL ON FUNCTION data.assert_can_grant_customer_portal_access(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.assert_can_grant_customer_portal_access(uuid, boolean)
  TO authenticated, service_role;

-- Bulletins currently visible to a grant: current published version of every
-- report addressed to the grant's client_account_contact_id inside the tenant.
-- There is no per-version recipient column, so visibility is account-scoped
-- only (any principal on that account sees the same bulletins).
-- Privileged: never granted to authenticated.
CREATE OR REPLACE FUNCTION data.list_customer_portal_bulletins_for_grant(
  p_grant_id uuid,
  p_limit integer DEFAULT 200
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT COALESCE(jsonb_agg(b ORDER BY b->>'published_at' DESC), '[]'::jsonb)
  FROM (
    SELECT jsonb_build_object(
      'report_version_id', v.id,
      'report_id', v.report_id,
      'project_id', v.project_id,
      'version_number', v.version_number,
      'content_digest', v.content_digest,
      'locale', v.locale,
      'published_at', v.published_at,
      'title', COALESCE(
        NULLIF(btrim(COALESCE(v.projection->'intervention'->>'title', '')), ''),
        p.name
      ),
      'media_count', CASE
        WHEN jsonb_typeof(v.media_manifest) = 'array'
        THEN jsonb_array_length(v.media_manifest)
        ELSE 0
      END
    ) AS b
    FROM data.customer_access_grants g
    JOIN data.customer_intervention_report_versions v
      ON v.tenant_id = g.tenant_id
     AND v.customer_account_contact_id = g.client_account_contact_id
    JOIN data.customer_intervention_reports r
      ON r.id = v.report_id
     AND r.current_published_version_id = v.id
    LEFT JOIN data.projects p ON p.id = v.project_id
    WHERE g.id = p_grant_id
      AND g.revoked_at IS NULL
    ORDER BY v.published_at DESC
    LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 200), 500))
  ) s;
$$;

REVOKE ALL ON FUNCTION data.list_customer_portal_bulletins_for_grant(uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.list_customer_portal_bulletins_for_grant(uuid, integer)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 8. Tenant RPCs
-- ---------------------------------------------------------------------------

-- Create invitation. Secret is returned exactly once.
--
-- Relationship requirement:
--   * required ONLY for principal_kind = 'named_person' when the principal is
--     NOT the account itself AND the account is a company (a related person
--     being invited under a company account)
--   * NOT required for shared_mailbox (channel lives on the company account
--     or on a related contact, either way) nor for a person account inviting
--     itself (named_person self-account)
-- When a relationship exists and applies, its id is stored on the invitation
-- for later revocation checks at accept time.
CREATE OR REPLACE FUNCTION api.create_customer_access_invitation(
  p_client_account_contact_id uuid,
  p_principal_kind text,
  p_principal_contact_id uuid,
  p_delivery_channel_id uuid,
  p_ttl_hours integer DEFAULT 72
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public, extensions
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_account data.contacts%ROWTYPE;
  v_principal data.contacts%ROWTYPE;
  v_rel data.contact_relationships%ROWTYPE;
  v_channel data.contact_delivery_channels%ROWTYPE;
  v_cp jsonb;
  v_secret text;
  v_hash bytea;
  v_id uuid;
  v_expires timestamptz;
  v_has_live_grant boolean;
  v_needs_relationship boolean;
  v_relationship_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'P0001';
  END IF;

  IF p_principal_kind NOT IN ('named_person', 'shared_mailbox') THEN
    RAISE EXCEPTION 'invalid_principal_kind' USING ERRCODE = 'P0001';
  END IF;

  -- Same capability surface as managing customer portal access on Contacts.
  PERFORM data.require_fresh_tenant_permission(
    v_tenant, 'contacts.portal.manage', NULL::uuid
  );

  SELECT * INTO v_account
  FROM data.contacts
  WHERE id = p_client_account_contact_id
    AND tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'client_account_not_found' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_principal
  FROM data.contacts
  WHERE id = p_principal_contact_id
    AND tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'principal_not_found' USING ERRCODE = 'P0001';
  END IF;

  -- shared_mailbox: mailbox lives on the client account itself
  IF p_principal_kind = 'shared_mailbox' THEN
    IF p_principal_contact_id IS DISTINCT FROM p_client_account_contact_id THEN
      RAISE EXCEPTION 'shared_mailbox_must_be_account' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  -- named_person: must be a person; person-account ⇒ principal = account
  IF p_principal_kind = 'named_person' THEN
    IF v_principal.kind IS DISTINCT FROM 'person' THEN
      RAISE EXCEPTION 'named_person_requires_person_contact' USING ERRCODE = 'P0001';
    END IF;
    IF v_account.kind = 'person'
       AND p_principal_contact_id IS DISTINCT FROM p_client_account_contact_id THEN
      RAISE EXCEPTION 'person_account_self_principal_required' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  v_needs_relationship := (
    p_principal_kind = 'named_person'
    AND p_principal_contact_id <> p_client_account_contact_id
    AND v_account.kind = 'company'
  );

  v_relationship_id := NULL;
  IF v_needs_relationship THEN
    SELECT * INTO v_rel
    FROM data.contact_relationships r
    WHERE r.tenant_id = v_tenant
      AND r.organization_contact_id = p_client_account_contact_id
      AND r.person_contact_id = p_principal_contact_id
      AND data.contact_relationship_is_live(r.revoked_at, r.starts_at, r.ends_at, now())
    ORDER BY r.created_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'recipient_relationship_required' USING ERRCODE = 'P0001';
    END IF;
    v_relationship_id := v_rel.id;
  END IF;

  SELECT * INTO v_channel
  FROM data.contact_delivery_channels c
  WHERE c.id = p_delivery_channel_id
    AND c.tenant_id = v_tenant
    AND c.contact_id = p_principal_contact_id
    AND c.channel_type = 'email'
    AND c.disabled_at IS NULL
    AND c.verified_at IS NOT NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'delivery_channel_invalid' USING ERRCODE = 'P0001';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM data.customer_access_grants g
    WHERE g.tenant_id = v_tenant
      AND g.client_account_contact_id = p_client_account_contact_id
      AND g.principal_kind = p_principal_kind
      AND g.principal_contact_id = p_principal_contact_id
      AND g.revoked_at IS NULL
  ) INTO v_has_live_grant;

  v_cp := data.assert_can_grant_customer_portal_access(v_tenant, NOT v_has_live_grant);

  -- One live invitation per tuple: supersede the previous pending ones.
  UPDATE data.customer_access_invitations
  SET revoked_at = now(),
      revoked_by = auth.uid(),
      revoke_reason = COALESCE(revoke_reason, 'superseded')
  WHERE tenant_id = v_tenant
    AND client_account_contact_id = p_client_account_contact_id
    AND principal_kind = p_principal_kind
    AND principal_contact_id = p_principal_contact_id
    AND accepted_at IS NULL
    AND revoked_at IS NULL;

  p_ttl_hours := GREATEST(1, LEAST(COALESCE(p_ttl_hours, 72), 24 * 30));
  v_expires := now() + make_interval(hours => p_ttl_hours);
  v_secret := encode(gen_random_bytes(32), 'hex');
  v_hash := data.hash_customer_portal_secret(v_secret);

  INSERT INTO data.customer_access_invitations (
    tenant_id, client_account_contact_id, principal_kind, principal_contact_id,
    contact_relationship_id, delivery_channel_id, email_normalized,
    invited_by, token_hash, expires_at
  ) VALUES (
    v_tenant, p_client_account_contact_id, p_principal_kind, p_principal_contact_id,
    v_relationship_id, v_channel.id, lower(btrim(v_channel.value_normalized)),
    auth.uid(), v_hash, v_expires
  )
  RETURNING id INTO v_id;

  PERFORM data.log_audit_event_strict(
    v_tenant, auth.uid(), NULL::uuid,
    'CUSTOMER_ACCESS_INVITATION_CREATED',
    'customer_access_invitation', v_id,
    jsonb_build_object(
      'client_account_contact_id', p_client_account_contact_id,
      'principal_kind', p_principal_kind,
      'principal_contact_id', p_principal_contact_id,
      'contact_relationship_id', v_relationship_id,
      'delivery_channel_id', v_channel.id,
      'ttl_hours', p_ttl_hours,
      'mode_effective', v_cp->>'mode_effective'
    )
  );

  RETURN jsonb_build_object(
    'invitation_id', v_id,
    'secret', v_secret,
    'expires_at', v_expires,
    'email_normalized', lower(btrim(v_channel.value_normalized)),
    'accept_path', '/i/' || v_secret
  );
END;
$$;

REVOKE ALL ON FUNCTION api.create_customer_access_invitation(uuid, text, uuid, uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_customer_access_invitation(uuid, text, uuid, uuid, integer)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.list_customer_access_invitations(
  p_client_account_contact_id uuid DEFAULT NULL,
  p_only_pending boolean DEFAULT false
)
RETURNS SETOF api.customer_access_invitations
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = data, public, api
AS $$
  SELECT i.*
  FROM api.customer_access_invitations i
  WHERE i.tenant_id = data.active_tenant_id()
    AND (p_client_account_contact_id IS NULL
         OR i.client_account_contact_id = p_client_account_contact_id)
    AND (NOT COALESCE(p_only_pending, false) OR i.is_pending)
  ORDER BY i.created_at DESC;
$$;

REVOKE ALL ON FUNCTION api.list_customer_access_invitations(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_customer_access_invitations(uuid, boolean)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.list_customer_access_grants(
  p_client_account_contact_id uuid DEFAULT NULL,
  p_only_active boolean DEFAULT false
)
RETURNS SETOF api.customer_access_grants
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = data, public, api
AS $$
  SELECT g.*
  FROM api.customer_access_grants g
  WHERE g.tenant_id = data.active_tenant_id()
    AND (p_client_account_contact_id IS NULL
         OR g.client_account_contact_id = p_client_account_contact_id)
    AND (NOT COALESCE(p_only_active, false) OR g.is_active)
  ORDER BY g.created_at DESC;
$$;

REVOKE ALL ON FUNCTION api.list_customer_access_grants(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_customer_access_grants(uuid, boolean)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.revoke_customer_access_invitation(
  p_invitation_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_row data.customer_access_invitations%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_row
  FROM data.customer_access_invitations
  WHERE id = p_invitation_id AND tenant_id = v_tenant
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invitation_not_found' USING ERRCODE = 'P0001';
  END IF;

  -- De-escalation: anyone who may invite may also revoke.
  PERFORM data.require_fresh_tenant_permission(
    v_tenant, 'contacts.portal.manage', NULL::uuid
  );

  IF v_row.revoked_at IS NOT NULL THEN
    RETURN v_row.id;
  END IF;

  UPDATE data.customer_access_invitations
  SET revoked_at = now(),
      revoked_by = auth.uid(),
      revoke_reason = NULLIF(btrim(COALESCE(p_reason, '')), '')
  WHERE id = v_row.id;

  PERFORM data.log_audit_event_strict(
    v_tenant, auth.uid(), NULL::uuid,
    'CUSTOMER_ACCESS_INVITATION_REVOKED',
    'customer_access_invitation', v_row.id,
    jsonb_build_object(
      'client_account_contact_id', v_row.client_account_contact_id,
      'principal_kind', v_row.principal_kind,
      'principal_contact_id', v_row.principal_contact_id,
      'reason', p_reason
    )
  );

  RETURN v_row.id;
END;
$$;

REVOKE ALL ON FUNCTION api.revoke_customer_access_invitation(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.revoke_customer_access_invitation(uuid, text)
  TO authenticated, service_role;

-- Revoke grant: bump session_version, kill open sessions and unused login tokens.
CREATE OR REPLACE FUNCTION api.revoke_customer_access_grant(
  p_grant_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_row data.customer_access_grants%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_row
  FROM data.customer_access_grants
  WHERE id = p_grant_id AND tenant_id = v_tenant
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'grant_not_found' USING ERRCODE = 'P0001';
  END IF;

  PERFORM data.require_fresh_tenant_permission(
    v_tenant, 'contacts.portal.manage', NULL::uuid
  );

  IF v_row.revoked_at IS NULL THEN
    UPDATE data.customer_access_grants
    SET revoked_at = now(),
        revoked_by = auth.uid(),
        revoke_reason = NULLIF(btrim(COALESCE(p_reason, '')), ''),
        session_version = session_version + 1
    WHERE id = v_row.id;
  END IF;

  UPDATE data.customer_portal_grant_sessions
  SET revoked_at = COALESCE(revoked_at, now())
  WHERE grant_id = v_row.id AND revoked_at IS NULL;

  UPDATE data.customer_portal_login_tokens
  SET used_at = COALESCE(used_at, now())
  WHERE grant_id = v_row.id AND used_at IS NULL;

  -- Pending invitations for the same tuple must not resurrect the access.
  UPDATE data.customer_access_invitations
  SET revoked_at = now(),
      revoked_by = auth.uid(),
      revoke_reason = COALESCE(revoke_reason, 'grant_revoked')
  WHERE tenant_id = v_row.tenant_id
    AND client_account_contact_id = v_row.client_account_contact_id
    AND principal_kind = v_row.principal_kind
    AND principal_contact_id = v_row.principal_contact_id
    AND accepted_at IS NULL
    AND revoked_at IS NULL;

  PERFORM data.log_audit_event_strict(
    v_tenant, auth.uid(), NULL::uuid,
    'CUSTOMER_ACCESS_GRANT_REVOKED',
    'customer_access_grant', v_row.id,
    jsonb_build_object(
      'client_account_contact_id', v_row.client_account_contact_id,
      'principal_kind', v_row.principal_kind,
      'principal_contact_id', v_row.principal_contact_id,
      'auth_user_id', v_row.auth_user_id,
      'reason', p_reason
    )
  );

  RETURN v_row.id;
END;
$$;

REVOKE ALL ON FUNCTION api.revoke_customer_access_grant(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.revoke_customer_access_grant(uuid, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 9. Privileged RPCs (Edge Functions / service_role only)
-- ---------------------------------------------------------------------------

-- Accept an invitation: activates the grant and opens the first session.
--
-- Relationship re-check at accept time:
--   * named_person with principal <> account: relationship org=client_account,
--     person=principal must still be active
--   * otherwise (shared_mailbox, or named_person self-account): only re-check
--     if a contact_relationship_id was actually stored on the invitation
CREATE OR REPLACE FUNCTION api.accept_customer_access_invitation(
  p_token_hash bytea,
  p_auth_user_id uuid,
  p_ip_address inet DEFAULT NULL,
  p_user_agent text DEFAULT NULL,
  p_session_ttl_minutes integer DEFAULT 60,
  p_client_key text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public, extensions
AS $$
DECLARE
  v_inv data.customer_access_invitations%ROWTYPE;
  v_platform data.customer_portal_platform_state%ROWTYPE;
  v_tstate data.customer_portal_tenant_state%ROWTYPE;
  v_grant data.customer_access_grants%ROWTYPE;
  v_existing_grant_id uuid;
  v_grant_id uuid;
  v_session_id uuid;
  v_session_secret text;
  v_session_hash bytea;
  v_expires timestamptz;
  v_denied text;
  v_email text;
  v_relationship_active boolean;
BEGIN
  BEGIN
    PERFORM data.assert_customer_portal_rate_limit(
      'invitation_accept',
      COALESCE(p_client_key, host(p_ip_address)::text, 'unknown'),
      20, 60, NULL
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%customer_portal_rate_limited%' THEN
      RETURN jsonb_build_object('ok', false, 'code', 'rate_limited');
    END IF;
    RAISE;
  END;

  IF p_token_hash IS NULL OR length(p_token_hash) = 0 OR p_auth_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  SELECT * INTO v_inv
  FROM data.customer_access_invitations
  WHERE token_hash = p_token_hash
  FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO data.customer_portal_unknown_token_ledger (
      token_hash_prefix, ip_address, user_agent
    ) VALUES (
      substring(p_token_hash FROM 1 FOR 8), p_ip_address, left(COALESCE(p_user_agent, ''), 512)
    );
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  SELECT * INTO v_platform FROM data.customer_portal_platform_state WHERE id;
  v_tstate := data.ensure_customer_portal_tenant_state(v_inv.tenant_id);

  v_denied := NULL;
  IF NOT v_platform.enabled OR NOT v_tstate.enabled THEN
    v_denied := 'kill_switch';
  ELSIF v_tstate.new_access_policy <> 'allow' THEN
    v_denied := 'new_access_blocked';
  ELSIF v_tstate.existing_access_policy <> 'allow' THEN
    v_denied := 'existing_access_blocked';
  ELSIF v_inv.revoked_at IS NOT NULL THEN
    v_denied := 'revoked';
  ELSIF v_inv.accepted_at IS NOT NULL THEN
    v_denied := 'already_accepted';
  ELSIF v_inv.expires_at <= now() THEN
    v_denied := 'expired';
  ELSIF NOT EXISTS (SELECT 1 FROM data.profiles pr WHERE pr.id = p_auth_user_id) THEN
    v_denied := 'auth_user_unknown';
  END IF;

  IF v_denied IS NULL
     AND v_inv.principal_kind = 'named_person'
     AND v_inv.principal_contact_id <> v_inv.client_account_contact_id
  THEN
    SELECT EXISTS (
      SELECT 1 FROM data.contact_relationships r
      WHERE r.tenant_id = v_inv.tenant_id
        AND r.organization_contact_id = v_inv.client_account_contact_id
        AND r.person_contact_id = v_inv.principal_contact_id
        AND data.contact_relationship_is_live(r.revoked_at, r.starts_at, r.ends_at, now())
    ) INTO v_relationship_active;

    IF NOT v_relationship_active THEN
      v_denied := 'relationship_revoked';
    END IF;
  ELSIF v_denied IS NULL
        AND v_inv.principal_kind = 'shared_mailbox'
        AND v_inv.principal_contact_id IS DISTINCT FROM v_inv.client_account_contact_id
  THEN
    v_denied := 'shared_mailbox_must_be_account';
  ELSIF v_denied IS NULL AND v_inv.contact_relationship_id IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM data.contact_relationships r
      WHERE r.id = v_inv.contact_relationship_id
        AND data.contact_relationship_is_live(r.revoked_at, r.starts_at, r.ends_at, now())
    ) INTO v_relationship_active;

    IF NOT v_relationship_active THEN
      v_denied := 'relationship_revoked';
    END IF;
  END IF;

  IF v_denied IS NOT NULL THEN
    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, action, http_status, failure_reason, ip_address, user_agent
    ) VALUES (
      v_inv.tenant_id, 'resolve_denied', 410, v_denied,
      p_ip_address, left(COALESCE(p_user_agent, ''), 512)
    );
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  SELECT g.id INTO v_existing_grant_id
  FROM data.customer_access_grants g
  WHERE g.tenant_id = v_inv.tenant_id
    AND g.client_account_contact_id = v_inv.client_account_contact_id
    AND g.principal_kind = v_inv.principal_kind
    AND g.principal_contact_id = v_inv.principal_contact_id
    AND g.auth_user_id = p_auth_user_id
    AND g.revoked_at IS NULL;

  BEGIN
    PERFORM data.assert_can_grant_customer_portal_access(
      v_inv.tenant_id, v_existing_grant_id IS NULL
    );
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, action, http_status, failure_reason, ip_address, user_agent
    ) VALUES (
      v_inv.tenant_id, 'resolve_denied', 403, left(SQLERRM, 200),
      p_ip_address, left(COALESCE(p_user_agent, ''), 512)
    );
    RETURN jsonb_build_object('ok', false, 'code', 'not_allowed');
  END;

  v_email := lower(btrim(v_inv.email_normalized));

  INSERT INTO data.customer_access_grants (
    tenant_id, auth_user_id, client_account_contact_id, principal_kind, principal_contact_id,
    contact_relationship_id, email_normalized, security_version_tenant, security_version_platform,
    invitation_id, last_seen_at
  ) VALUES (
    v_inv.tenant_id, p_auth_user_id, v_inv.client_account_contact_id,
    v_inv.principal_kind, v_inv.principal_contact_id,
    v_inv.contact_relationship_id, v_email, v_tstate.security_version, v_platform.security_version,
    v_inv.id, now()
  )
  ON CONFLICT (tenant_id, client_account_contact_id, principal_kind, principal_contact_id, auth_user_id)
    WHERE revoked_at IS NULL
  DO UPDATE SET
    contact_relationship_id = EXCLUDED.contact_relationship_id,
    email_normalized = EXCLUDED.email_normalized,
    invitation_id = EXCLUDED.invitation_id,
    security_version_tenant = EXCLUDED.security_version_tenant,
    security_version_platform = EXCLUDED.security_version_platform,
    last_seen_at = now(),
    updated_at = now()
  RETURNING id INTO v_grant_id;

  SELECT * INTO v_grant FROM data.customer_access_grants WHERE id = v_grant_id;

  UPDATE data.customer_access_invitations
  SET accepted_at = now(), accepted_auth_user_id = p_auth_user_id
  WHERE id = v_inv.id;

  p_session_ttl_minutes := GREATEST(15, LEAST(COALESCE(p_session_ttl_minutes, 60), 720));
  v_expires := now() + make_interval(mins => p_session_ttl_minutes);
  v_session_secret := encode(gen_random_bytes(32), 'hex');
  v_session_hash := data.hash_customer_portal_secret(v_session_secret);

  INSERT INTO data.customer_portal_grant_sessions (
    tenant_id, grant_id, session_token_hash, session_version,
    security_version_tenant, security_version_platform,
    expires_at, last_seen_at, ip_address, user_agent
  ) VALUES (
    v_grant.tenant_id, v_grant.id, v_session_hash, v_grant.session_version,
    v_tstate.security_version, v_platform.security_version,
    v_expires, now(), p_ip_address, left(COALESCE(p_user_agent, ''), 512)
  )
  RETURNING id INTO v_session_id;

  INSERT INTO data.customer_report_share_access_logs (
    tenant_id, grant_id, session_id, action, http_status, ip_address, user_agent
  ) VALUES (
    v_grant.tenant_id, v_grant.id, v_session_id, 'invitation_accepted', 200,
    p_ip_address, left(COALESCE(p_user_agent, ''), 512)
  );

  PERFORM data.log_audit_event_strict(
    v_grant.tenant_id,
    (SELECT pr.id FROM data.profiles pr WHERE pr.id = p_auth_user_id),
    NULL::uuid,
    'CUSTOMER_ACCESS_GRANT_ACCEPTED',
    'customer_access_grant', v_grant.id,
    jsonb_build_object(
      'invitation_id', v_inv.id,
      'client_account_contact_id', v_grant.client_account_contact_id,
      'principal_kind', v_grant.principal_kind,
      'principal_contact_id', v_grant.principal_contact_id,
      'auth_user_id', p_auth_user_id
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'grant_id', v_grant.id,
    'tenant_id', v_grant.tenant_id,
    'session_id', v_session_id,
    'session_secret', v_session_secret,
    'expires_at', v_expires,
    'client_account_contact_id', v_grant.client_account_contact_id,
    'principal_kind', v_grant.principal_kind,
    'principal_contact_id', v_grant.principal_contact_id,
    'email_normalized', v_grant.email_normalized,
    'actor_type', 'customer'
  );
END;
$$;

-- Return-visit: mint short-TTL login tokens for every live grant of an email.
-- Never leaks existence to the browser: the Edge Function must answer with an
-- identical body whether or not `tokens` is empty.
CREATE OR REPLACE FUNCTION api.request_customer_portal_login_token(
  p_email_normalized text,
  p_ip_address inet DEFAULT NULL,
  p_client_key text DEFAULT NULL,
  p_ttl_minutes integer DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public, extensions
AS $$
DECLARE
  v_email text := lower(btrim(COALESCE(p_email_normalized, '')));
  v_expires timestamptz;
  v_tokens jsonb := '[]'::jsonb;
  v_platform data.customer_portal_platform_state%ROWTYPE;
  v_tstate data.customer_portal_tenant_state%ROWTYPE;
  v_secret text;
  v_rec record;
BEGIN
  BEGIN
    PERFORM data.assert_customer_portal_rate_limit(
      'login_token_ip',
      COALESCE(p_client_key, host(p_ip_address)::text, 'unknown'),
      10, 60, NULL
    );
    PERFORM data.assert_customer_portal_rate_limit(
      'login_token_email', COALESCE(NULLIF(v_email, ''), 'unknown'), 5, 60, NULL
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%customer_portal_rate_limited%' THEN
      RETURN jsonb_build_object('ok', false, 'code', 'rate_limited');
    END IF;
    RAISE;
  END;

  IF v_email = '' OR position('@' IN v_email) = 0 THEN
    RETURN jsonb_build_object('ok', true, 'tokens', '[]'::jsonb);
  END IF;

  SELECT * INTO v_platform FROM data.customer_portal_platform_state WHERE id;
  IF NOT v_platform.enabled OR v_platform.max_mode <> 'portal' THEN
    RETURN jsonb_build_object('ok', true, 'tokens', '[]'::jsonb);
  END IF;

  p_ttl_minutes := GREATEST(15, LEAST(COALESCE(p_ttl_minutes, 20), 30));
  v_expires := now() + make_interval(mins => p_ttl_minutes);

  FOR v_rec IN
    SELECT g.id, g.tenant_id
    FROM data.customer_access_grants g
    WHERE g.email_normalized = v_email
      AND g.revoked_at IS NULL
    ORDER BY g.created_at DESC
    LIMIT 10
  LOOP
    v_tstate := data.ensure_customer_portal_tenant_state(v_rec.tenant_id);
    CONTINUE WHEN NOT v_tstate.enabled OR v_tstate.existing_access_policy <> 'allow';

    v_secret := encode(gen_random_bytes(32), 'hex');

    INSERT INTO data.customer_portal_login_tokens (
      tenant_id, grant_id, email_normalized, token_hash, expires_at, ip_address
    ) VALUES (
      v_rec.tenant_id, v_rec.id, v_email,
      data.hash_customer_portal_secret(v_secret), v_expires, p_ip_address
    );

    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, grant_id, action, http_status, ip_address
    ) VALUES (
      v_rec.tenant_id, v_rec.id, 'login_token_requested', 200, p_ip_address
    );

    v_tokens := v_tokens || jsonb_build_array(jsonb_build_object(
      'tenant_id', v_rec.tenant_id,
      'grant_id', v_rec.id,
      'token_secret', v_secret,
      'expires_at', v_expires
    ));
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'tokens', v_tokens, 'expires_at', v_expires);
END;
$$;

-- Exchange a login token for a grant session.
CREATE OR REPLACE FUNCTION api.exchange_customer_portal_login_token(
  p_token_hash bytea,
  p_ip_address inet DEFAULT NULL,
  p_user_agent text DEFAULT NULL,
  p_session_ttl_minutes integer DEFAULT 60,
  p_client_key text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public, extensions
AS $$
DECLARE
  v_token data.customer_portal_login_tokens%ROWTYPE;
  v_grant data.customer_access_grants%ROWTYPE;
  v_platform data.customer_portal_platform_state%ROWTYPE;
  v_tstate data.customer_portal_tenant_state%ROWTYPE;
  v_session_id uuid;
  v_session_secret text;
  v_session_hash bytea;
  v_expires timestamptz;
  v_denied text;
BEGIN
  BEGIN
    PERFORM data.assert_customer_portal_rate_limit(
      'login_token_exchange',
      COALESCE(p_client_key, host(p_ip_address)::text, 'unknown'),
      20, 60, NULL
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%customer_portal_rate_limited%' THEN
      RETURN jsonb_build_object('ok', false, 'code', 'rate_limited');
    END IF;
    RAISE;
  END;

  IF p_token_hash IS NULL OR length(p_token_hash) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  SELECT * INTO v_token
  FROM data.customer_portal_login_tokens
  WHERE token_hash = p_token_hash
  FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO data.customer_portal_unknown_token_ledger (
      token_hash_prefix, ip_address, user_agent
    ) VALUES (
      substring(p_token_hash FROM 1 FOR 8), p_ip_address, left(COALESCE(p_user_agent, ''), 512)
    );
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  SELECT * INTO v_grant FROM data.customer_access_grants WHERE id = v_token.grant_id;
  SELECT * INTO v_platform FROM data.customer_portal_platform_state WHERE id;
  v_tstate := data.ensure_customer_portal_tenant_state(v_token.tenant_id);

  v_denied := NULL;
  IF NOT v_platform.enabled OR NOT v_tstate.enabled THEN
    v_denied := 'kill_switch';
  ELSIF v_platform.max_mode <> 'portal' THEN
    v_denied := 'mode_not_available';
  ELSIF v_tstate.existing_access_policy <> 'allow' THEN
    v_denied := 'existing_access_blocked';
  ELSIF v_token.used_at IS NOT NULL THEN
    v_denied := 'already_used';
  ELSIF v_token.expires_at <= now() THEN
    v_denied := 'expired';
  ELSIF v_grant.id IS NULL OR v_grant.revoked_at IS NOT NULL THEN
    v_denied := 'grant_revoked';
  END IF;

  IF v_denied IS NOT NULL THEN
    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, grant_id, action, http_status, failure_reason, ip_address, user_agent
    ) VALUES (
      v_token.tenant_id, v_token.grant_id, 'resolve_denied', 410, v_denied,
      p_ip_address, left(COALESCE(p_user_agent, ''), 512)
    );
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  UPDATE data.customer_portal_login_tokens
  SET used_at = now()
  WHERE id = v_token.id;

  p_session_ttl_minutes := GREATEST(15, LEAST(COALESCE(p_session_ttl_minutes, 60), 720));
  v_expires := now() + make_interval(mins => p_session_ttl_minutes);
  v_session_secret := encode(gen_random_bytes(32), 'hex');
  v_session_hash := data.hash_customer_portal_secret(v_session_secret);

  INSERT INTO data.customer_portal_grant_sessions (
    tenant_id, grant_id, session_token_hash, session_version,
    security_version_tenant, security_version_platform,
    expires_at, last_seen_at, ip_address, user_agent
  ) VALUES (
    v_grant.tenant_id, v_grant.id, v_session_hash, v_grant.session_version,
    v_tstate.security_version, v_platform.security_version,
    v_expires, now(), p_ip_address, left(COALESCE(p_user_agent, ''), 512)
  )
  RETURNING id INTO v_session_id;

  UPDATE data.customer_access_grants
  SET last_seen_at = now()
  WHERE id = v_grant.id;

  INSERT INTO data.customer_report_share_access_logs (
    tenant_id, grant_id, session_id, action, http_status, ip_address, user_agent
  ) VALUES (
    v_grant.tenant_id, v_grant.id, v_session_id, 'login_token_exchanged', 200,
    p_ip_address, left(COALESCE(p_user_agent, ''), 512)
  );

  RETURN jsonb_build_object(
    'ok', true,
    'grant_id', v_grant.id,
    'tenant_id', v_grant.tenant_id,
    'session_id', v_session_id,
    'session_secret', v_session_secret,
    'expires_at', v_expires,
    'client_account_contact_id', v_grant.client_account_contact_id,
    'principal_kind', v_grant.principal_kind,
    'principal_contact_id', v_grant.principal_contact_id,
    'actor_type', 'customer'
  );
END;
$$;

-- Per-request resolver for a customer grant session.
-- Heavy entitlement checks happen at session creation; here we enforce the
-- cheap O(1) gates: kill-switch, existing_access_policy, session/security
-- versions, expiry and grant liveness.
CREATE OR REPLACE FUNCTION api.resolve_customer_portal_grant_session(
  p_session_token_hash bytea,
  p_action text DEFAULT 'list_bulletins',
  p_report_version_id uuid DEFAULT NULL,
  p_ip_address inet DEFAULT NULL,
  p_user_agent text DEFAULT NULL,
  p_request_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_sess data.customer_portal_grant_sessions%ROWTYPE;
  v_grant data.customer_access_grants%ROWTYPE;
  v_platform data.customer_portal_platform_state%ROWTYPE;
  v_tstate data.customer_portal_tenant_state%ROWTYPE;
  v_version data.customer_intervention_report_versions%ROWTYPE;
  v_action text := COALESCE(NULLIF(btrim(p_action), ''), 'list_bulletins');
  v_bulletins jsonb;
BEGIN
  IF v_action NOT IN ('list_bulletins', 'report_view', 'media_download') THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid_action');
  END IF;

  IF p_session_token_hash IS NULL OR length(p_session_token_hash) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  SELECT * INTO v_sess
  FROM data.customer_portal_grant_sessions
  WHERE session_token_hash = p_session_token_hash
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  SELECT * INTO v_grant FROM data.customer_access_grants WHERE id = v_sess.grant_id;
  SELECT * INTO v_platform FROM data.customer_portal_platform_state WHERE id;
  v_tstate := data.ensure_customer_portal_tenant_state(v_sess.tenant_id);

  IF v_sess.revoked_at IS NOT NULL
     OR v_sess.expires_at <= now()
     OR v_grant.id IS NULL
     OR v_grant.revoked_at IS NOT NULL
     OR NOT v_platform.enabled
     OR NOT v_tstate.enabled
     OR v_platform.max_mode <> 'portal'
     OR v_tstate.existing_access_policy <> 'allow'
     OR v_sess.session_version IS DISTINCT FROM v_grant.session_version
     OR v_sess.security_version_tenant IS DISTINCT FROM v_tstate.security_version
     OR v_sess.security_version_platform IS DISTINCT FROM v_platform.security_version
  THEN
    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, grant_id, session_id, action, http_status,
      failure_reason, ip_address, user_agent, request_id
    ) VALUES (
      v_sess.tenant_id, v_sess.grant_id, v_sess.id, 'session_denied', 401,
      'session_invalid', p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
    );
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  UPDATE data.customer_portal_grant_sessions
  SET last_seen_at = now()
  WHERE id = v_sess.id;

  UPDATE data.customer_access_grants
  SET last_seen_at = now()
  WHERE id = v_grant.id;

  IF v_action = 'list_bulletins' THEN
    v_bulletins := data.list_customer_portal_bulletins_for_grant(v_grant.id);

    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, grant_id, session_id, action, http_status,
      ip_address, user_agent, request_id
    ) VALUES (
      v_sess.tenant_id, v_grant.id, v_sess.id, 'list_bulletins', 200,
      p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
    );

    RETURN jsonb_build_object(
      'ok', true,
      'action', v_action,
      'tenant_id', v_sess.tenant_id,
      'grant_id', v_grant.id,
      'session_id', v_sess.id,
      'expires_at', v_sess.expires_at,
      'actor_type', 'customer',
      'client_account_contact_id', v_grant.client_account_contact_id,
      'principal_kind', v_grant.principal_kind,
      'principal_contact_id', v_grant.principal_contact_id,
      'bulletins', v_bulletins
    );
  END IF;

  IF p_report_version_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'code', 'report_version_required');
  END IF;

  -- Scope: only versions currently published to this grant's client account.
  -- There is no per-version recipient column, so account is the only key.
  SELECT v.* INTO v_version
  FROM data.customer_intervention_report_versions v
  JOIN data.customer_intervention_reports r ON r.id = v.report_id
  WHERE v.id = p_report_version_id
    AND v.tenant_id = v_grant.tenant_id
    AND r.current_published_version_id = v.id
    AND v.customer_account_contact_id = v_grant.client_account_contact_id;

  IF NOT FOUND THEN
    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, grant_id, session_id, report_version_id, action, http_status,
      failure_reason, ip_address, user_agent, request_id
    ) VALUES (
      v_sess.tenant_id, v_grant.id, v_sess.id, p_report_version_id,
      'resolve_denied', 404, 'out_of_scope',
      p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
    );
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  -- Idempotent per request_id so retries do not inflate the ledger.
  IF p_request_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM data.customer_report_share_access_logs l
    WHERE l.session_id = v_sess.id
      AND l.action = v_action
      AND l.request_id = p_request_id
  ) THEN
    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, grant_id, session_id, report_version_id, action, http_status,
      ip_address, user_agent, request_id
    ) VALUES (
      v_sess.tenant_id, v_grant.id, v_sess.id, v_version.id, v_action, 200,
      p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'action', v_action,
    'tenant_id', v_sess.tenant_id,
    'grant_id', v_grant.id,
    'session_id', v_sess.id,
    'expires_at', v_sess.expires_at,
    'actor_type', 'customer',
    'report_version_id', v_version.id,
    'project_id', v_version.project_id,
    'locale', v_version.locale,
    'content_digest', v_version.content_digest,
    'projection', CASE WHEN v_action = 'report_view' THEN v_version.projection ELSE NULL END,
    'media_manifest', v_version.media_manifest
  );
END;
$$;

-- service_role only: pending-invitation email peek for the Edge accept flow.
-- Reads only email_normalized (account+principal shape doesn't change this).
CREATE OR REPLACE FUNCTION api.peek_customer_access_invitation(
  p_token_hash bytea
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_inv data.customer_access_invitations%ROWTYPE;
BEGIN
  IF p_token_hash IS NULL OR length(p_token_hash) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  SELECT * INTO v_inv
  FROM data.customer_access_invitations
  WHERE token_hash = p_token_hash;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  IF v_inv.revoked_at IS NOT NULL
     OR v_inv.accepted_at IS NOT NULL
     OR v_inv.expires_at <= now()
  THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'invitation_id', v_inv.id,
    'tenant_id', v_inv.tenant_id,
    'email_normalized', v_inv.email_normalized
  );
END;
$$;

REVOKE ALL ON FUNCTION api.peek_customer_access_invitation(bytea) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.peek_customer_access_invitation(bytea) TO service_role;

-- ---------------------------------------------------------------------------
-- 10. Privileged grants (service_role only — never authenticated)
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION api.accept_customer_access_invitation(bytea, uuid, inet, text, integer, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.request_customer_portal_login_token(text, inet, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.exchange_customer_portal_login_token(bytea, inet, text, integer, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.resolve_customer_portal_grant_session(bytea, text, uuid, inet, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.accept_customer_access_invitation(bytea, uuid, inet, text, integer, text)
  TO service_role;
GRANT EXECUTE ON FUNCTION api.request_customer_portal_login_token(text, inet, text, integer)
  TO service_role;
GRANT EXECUTE ON FUNCTION api.exchange_customer_portal_login_token(bytea, inet, text, integer, text)
  TO service_role;
GRANT EXECUTE ON FUNCTION api.resolve_customer_portal_grant_session(bytea, text, uuid, inet, text, text)
  TO service_role;
