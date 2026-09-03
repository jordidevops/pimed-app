-- =============================================================================
-- CP-A2 — Customer report shares control plane
-- Shares hashades, sessions opaques, kill-switch, logs particionats,
-- delivery intents (email sense secret), rate limit, entitlements customer_portal
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. Helpers: digest share secrets
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.hash_customer_portal_secret(p_secret text)
RETURNS bytea
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_secret IS NULL OR btrim(p_secret) = '' THEN NULL
    ELSE extensions.digest(convert_to(btrim(p_secret), 'UTF8'), 'sha256')
  END;
$$;

REVOKE ALL ON FUNCTION data.hash_customer_portal_secret(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.hash_customer_portal_secret(text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 1. Platform + tenant operational state (kill-switch O(1))
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.customer_portal_platform_state (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  enabled boolean NOT NULL DEFAULT true,
  security_version integer NOT NULL DEFAULT 1 CHECK (security_version >= 1),
  -- Product rollout cap: CP-A => share_only; CP-B bumps to portal additively
  max_mode text NOT NULL DEFAULT 'share_only'
    CHECK (max_mode IN ('share_only', 'portal')),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  note text
);

INSERT INTO data.customer_portal_platform_state (id)
VALUES (true)
ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS data.customer_portal_tenant_state (
  tenant_id uuid PRIMARY KEY REFERENCES data.tenants(id) ON DELETE CASCADE,
  enabled boolean NOT NULL DEFAULT true,
  new_access_policy text NOT NULL DEFAULT 'allow'
    CHECK (new_access_policy IN ('allow', 'review', 'blocked')),
  new_share_policy text NOT NULL DEFAULT 'allow'
    CHECK (new_share_policy IN ('allow', 'blocked')),
  existing_access_policy text NOT NULL DEFAULT 'allow'
    CHECK (existing_access_policy IN ('allow', 'blocked')),
  restriction_reason text
    CHECK (restriction_reason IS NULL OR restriction_reason IN (
      'abuse', 'non_payment', 'incident', 'manual'
    )),
  restriction_note text,
  restricted_at timestamptz,
  restricted_by uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  review_at timestamptz,
  security_version integer NOT NULL DEFAULT 1 CHECK (security_version >= 1),
  bulletin_bcc_emails text[] DEFAULT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION data.ensure_customer_portal_tenant_state(p_tenant_id uuid)
RETURNS data.customer_portal_tenant_state
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_row data.customer_portal_tenant_state%ROWTYPE;
BEGIN
  INSERT INTO data.customer_portal_tenant_state (tenant_id)
  VALUES (p_tenant_id)
  ON CONFLICT (tenant_id) DO NOTHING;

  SELECT * INTO v_row
  FROM data.customer_portal_tenant_state
  WHERE tenant_id = p_tenant_id;
  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION data.ensure_customer_portal_tenant_state(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.ensure_customer_portal_tenant_state(uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Entitlements: customer_portal channel
-- ---------------------------------------------------------------------------
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
      'mode', 'share_only',
      'customer_users_limit', NULL,
      'active_share_guardrail', 500,
      'customer_mau_alert_threshold', 1000,
      'included_email_deliveries_month', 2000
    )
  );
$$;

CREATE OR REPLACE FUNCTION data.customer_portal_entitlement_defaults()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT (data.portal_entitlements_default()->'customer_portal');
$$;

-- Merge plan JSON with defaults for missing keys (preserve unknown keys)
CREATE OR REPLACE FUNCTION data.merge_customer_portal_entitlements(p_plan jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT data.customer_portal_entitlement_defaults() || COALESCE(p_plan, '{}'::jsonb);
$$;

CREATE OR REPLACE FUNCTION data.resolve_portal_entitlements(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant           data.tenants%ROWTYPE;
  v_plan_ent         jsonb;
  v_overrides        jsonb;
  v_emp_included     boolean;
  v_pub_included     boolean;
  v_emp_tier_plan    text;
  v_pub_tier_plan    text;
  v_emp_tier         text;
  v_pub_tier         text;
  v_max_pages        integer;
  v_pages_by_site    jsonb;
  v_cp               jsonb;
  v_cp_plan          jsonb;
  v_cp_included      boolean;
  v_cp_mode_plan     text;
  v_cp_mode_granted  text;
  v_platform         data.customer_portal_platform_state%ROWTYPE;
  v_tstate           data.customer_portal_tenant_state%ROWTYPE;
  v_mode_effective   text;
  v_enabled_tenant   boolean;
  v_effective        boolean;
  v_can_shares       boolean;
  v_can_grants       boolean;
BEGIN
  SELECT * INTO v_tenant FROM data.tenants t WHERE t.id = p_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'tenant_not_found:%', p_tenant_id USING ERRCODE = 'P0001';
  END IF;

  v_plan_ent := data.plan_portal_entitlements(v_tenant.plan_id);
  v_overrides := COALESCE(v_tenant.tenant_portal_overrides, '{}'::jsonb);

  v_emp_included  := COALESCE((v_plan_ent->'employee_portal'->>'included')::boolean, false);
  v_pub_included  := COALESCE((v_plan_ent->'public_portal'->>'included')::boolean, false);
  v_emp_tier_plan := COALESCE(v_plan_ent->'employee_portal'->>'cms_tier', 'none');
  v_pub_tier_plan := COALESCE(v_plan_ent->'public_portal'->>'cms_tier', 'none');

  v_emp_tier := data.merge_portal_cms_tier(
    v_emp_tier_plan,
    v_overrides->'employee_portal'->>'cms_tier'
  );
  v_pub_tier := data.merge_portal_cms_tier(
    v_pub_tier_plan,
    v_overrides->'public_portal'->>'cms_tier'
  );

  SELECT COALESCE(p.max_portal_pages, 0)
    INTO v_max_pages
    FROM data.plans p
   WHERE p.id = v_tenant.plan_id;

  IF COALESCE((v_plan_ent->'public_portal'->>'max_pages')::integer, 0) > 0 THEN
    v_max_pages := (v_plan_ent->'public_portal'->>'max_pages')::integer;
  END IF;

  SELECT COALESCE(
    jsonb_object_agg(ps.id::text, COALESCE(cnt.c, 0)),
    '{}'::jsonb
  )
  INTO v_pages_by_site
  FROM data.public_sites ps
  LEFT JOIN (
    SELECT pp.public_site_id, COUNT(*)::integer AS c
      FROM data.public_pages pp
     WHERE pp.tenant_id = p_tenant_id
     GROUP BY pp.public_site_id
  ) cnt ON cnt.public_site_id = ps.id
  WHERE ps.tenant_id = p_tenant_id;

  -- customer_portal
  SELECT * INTO v_platform FROM data.customer_portal_platform_state WHERE id;
  v_tstate := data.ensure_customer_portal_tenant_state(p_tenant_id);

  v_cp_plan := data.merge_customer_portal_entitlements(v_plan_ent->'customer_portal');
  -- Snapshot/override may raise guardrails / emails additively (CP-ADM refinements later)
  v_cp := v_cp_plan || COALESCE(v_overrides->'customer_portal', '{}'::jsonb);

  v_cp_included := COALESCE((v_cp->>'included')::boolean, false);
  v_cp_mode_plan := COALESCE(v_cp->>'mode', 'share_only');
  IF v_cp_mode_plan NOT IN ('share_only', 'portal') THEN
    v_cp_mode_plan := 'share_only';
  END IF;
  v_cp_mode_granted := v_cp_mode_plan;

  -- Platform rollout caps mode (CP-A: share_only)
  IF v_platform.max_mode = 'share_only' AND v_cp_mode_granted = 'portal' THEN
    v_mode_effective := 'share_only';
  ELSE
    v_mode_effective := v_cp_mode_granted;
  END IF;

  v_enabled_tenant := v_tstate.enabled AND v_platform.enabled;
  v_effective := v_cp_included AND v_enabled_tenant;
  v_can_shares := v_effective
    AND v_tstate.new_share_policy = 'allow'
    AND v_mode_effective IN ('share_only', 'portal');
  v_can_grants := v_effective
    AND v_tstate.new_access_policy = 'allow'
    AND v_mode_effective = 'portal'
    AND v_platform.max_mode = 'portal';

  RETURN jsonb_build_object(
    'tenant_id', p_tenant_id,
    'employee_portal', jsonb_build_object(
      'included_by_plan', v_emp_included,
      'enabled_by_tenant', v_tenant.employee_portal_enabled,
      'effective', v_emp_included AND v_tenant.employee_portal_enabled,
      'cms_tier', CASE WHEN v_emp_included THEN v_emp_tier ELSE 'none' END
    ),
    'public_portal', jsonb_build_object(
      'included_by_plan', v_pub_included,
      'enabled_by_tenant', v_tenant.public_portal_enabled,
      'effective', v_pub_included AND v_tenant.public_portal_enabled,
      'cms_tier', CASE WHEN v_pub_included THEN v_pub_tier ELSE 'none' END,
      'max_pages', v_max_pages,
      'pages_used_by_site', COALESCE(v_pages_by_site, '{}'::jsonb)
    ),
    'customer_portal', jsonb_build_object(
      'included_granted', v_cp_included,
      'included_plan', COALESCE((v_cp_plan->>'included')::boolean, false),
      'enabled_by_tenant', v_tstate.enabled,
      'enabled_by_platform', v_platform.enabled,
      'effective', v_effective,
      'mode_granted', v_cp_mode_granted,
      'mode_plan', COALESCE(v_cp_plan->>'mode', 'share_only'),
      'mode_effective', v_mode_effective,
      'can_create_shares', v_can_shares,
      'can_grant_portal_access', v_can_grants,
      'customer_users_limit', v_cp->'customer_users_limit',
      'active_share_guardrail', COALESCE((v_cp->>'active_share_guardrail')::int, 500),
      'customer_mau_alert_threshold', COALESCE((v_cp->>'customer_mau_alert_threshold')::int, 1000),
      'included_email_deliveries_month', COALESCE((v_cp->>'included_email_deliveries_month')::int, 2000),
      'security_version_tenant', v_tstate.security_version,
      'security_version_platform', v_platform.security_version,
      'new_share_policy', v_tstate.new_share_policy,
      'new_access_policy', v_tstate.new_access_policy
    )
  );
END;
$$;

-- Seed customer_portal into existing plans (additive; preserve other keys)
UPDATE data.plans p
SET portal_entitlements = COALESCE(p.portal_entitlements, '{}'::jsonb)
  || jsonb_build_object(
    'customer_portal',
    data.merge_customer_portal_entitlements(p.portal_entitlements->'customer_portal')
  )
WHERE p.portal_entitlements IS NULL
   OR NOT (p.portal_entitlements ? 'customer_portal');

-- ---------------------------------------------------------------------------
-- 3. Shares
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.customer_report_shares (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  project_id uuid NOT NULL REFERENCES data.projects(id) ON DELETE RESTRICT,
  report_id uuid NOT NULL REFERENCES data.customer_intervention_reports(id) ON DELETE RESTRICT,
  report_version_id uuid NOT NULL
    REFERENCES data.customer_intervention_report_versions(id) ON DELETE RESTRICT,
  customer_account_contact_id uuid NOT NULL REFERENCES data.contacts(id) ON DELETE RESTRICT,
  recipient_contact_id uuid REFERENCES data.contacts(id) ON DELETE SET NULL,
  contact_relationship_id uuid REFERENCES data.contact_relationships(id) ON DELETE SET NULL,
  delivery_channel_id uuid REFERENCES data.contact_delivery_channels(id) ON DELETE SET NULL,

  token_hash bytea NOT NULL,
  channel text NOT NULL DEFAULT 'manual_link'
    CHECK (channel IN ('manual_link', 'email')),
  expires_at timestamptz NOT NULL,
  max_sessions integer,
  max_views integer,
  session_count integer NOT NULL DEFAULT 0,
  view_count integer NOT NULL DEFAULT 0,
  session_version integer NOT NULL DEFAULT 1 CHECK (session_version >= 1),

  second_channel_confirmed_at timestamptz,
  creation_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,

  created_by uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  revoke_reason text,
  revoked_by uuid REFERENCES data.profiles(id) ON DELETE SET NULL,

  CONSTRAINT customer_report_shares_expires_after_create
    CHECK (expires_at > created_at)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_customer_report_shares_token_hash
  ON data.customer_report_shares (token_hash);

CREATE INDEX IF NOT EXISTS idx_crs_tenant_created
  ON data.customer_report_shares (tenant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_crs_tenant_active
  ON data.customer_report_shares (tenant_id, expires_at)
  WHERE revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_crs_version
  ON data.customer_report_shares (report_version_id);

CREATE INDEX IF NOT EXISTS idx_crs_project
  ON data.customer_report_shares (project_id, created_at DESC);

COMMENT ON TABLE data.customer_report_shares IS
  'CP-C: bearer shares for a published version. recipient_contact_id is optional '
  'delivery metadata (any contact). Only token_hash stored; plaintext secret once.';

-- ---------------------------------------------------------------------------
-- 4. Share sessions
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.customer_portal_share_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  share_id uuid NOT NULL REFERENCES data.customer_report_shares(id) ON DELETE RESTRICT,
  report_version_id uuid NOT NULL
    REFERENCES data.customer_intervention_report_versions(id) ON DELETE RESTRICT,
  session_token_hash bytea NOT NULL,
  share_session_version integer NOT NULL,
  security_version_tenant integer NOT NULL,
  security_version_platform integer NOT NULL,
  expires_at timestamptz NOT NULL,
  last_seen_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  ip_address inet,
  user_agent text
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_cpss_session_hash
  ON data.customer_portal_share_sessions (session_token_hash);

CREATE INDEX IF NOT EXISTS idx_cpss_share
  ON data.customer_portal_share_sessions (share_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_cpss_tenant_expires
  ON data.customer_portal_share_sessions (tenant_id, expires_at)
  WHERE revoked_at IS NULL;

-- ---------------------------------------------------------------------------
-- 5. Access logs (monthly partitions) — no destructive FK cascade
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.customer_report_share_access_logs (
  id bigint GENERATED BY DEFAULT AS IDENTITY,
  tenant_id uuid NOT NULL,
  share_id uuid,
  session_id uuid,
  report_version_id uuid,
  accessed_at timestamptz NOT NULL DEFAULT now(),
  action text NOT NULL CHECK (action IN (
    'session_create',
    'report_view',
    'media_download',
    'resolve_denied',
    'session_denied',
    'rate_limited'
  )),
  http_status smallint,
  failure_reason text,
  ip_address inet,
  user_agent text,
  request_id text,
  PRIMARY KEY (id, accessed_at)
) PARTITION BY RANGE (accessed_at);

CREATE TABLE IF NOT EXISTS data.customer_report_share_access_logs_default
  PARTITION OF data.customer_report_share_access_logs DEFAULT;

CREATE OR REPLACE FUNCTION data.create_customer_report_share_access_logs_partition(p_month_start date)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_month_end date := (p_month_start + interval '1 month')::date;
  v_table_name text := 'customer_report_share_access_logs_'
    || to_char(p_month_start, 'YYYY_MM');
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'data' AND c.relname = v_table_name
  ) THEN
    EXECUTE format(
      'CREATE TABLE data.%I PARTITION OF data.customer_report_share_access_logs FOR VALUES FROM (%L) TO (%L)',
      v_table_name,
      p_month_start,
      v_month_end
    );
  END IF;
END;
$$;

SELECT data.create_customer_report_share_access_logs_partition(date_trunc('month', now())::date);
SELECT data.create_customer_report_share_access_logs_partition(
  (date_trunc('month', now()) + interval '1 month')::date
);

CREATE INDEX IF NOT EXISTS idx_crsal_tenant_accessed
  ON data.customer_report_share_access_logs (tenant_id, accessed_at DESC);
CREATE INDEX IF NOT EXISTS idx_crsal_share_accessed
  ON data.customer_report_share_access_logs (share_id, accessed_at DESC);
CREATE INDEX IF NOT EXISTS idx_crsal_session_accessed
  ON data.customer_report_share_access_logs (session_id, accessed_at DESC);

-- ---------------------------------------------------------------------------
-- 6. Unknown-token abuse ledger (no tenant)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.customer_portal_unknown_token_ledger (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  token_hash_prefix bytea NOT NULL,
  ip_address inet,
  user_agent text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_cputl_created
  ON data.customer_portal_unknown_token_ledger (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_cputl_ip_created
  ON data.customer_portal_unknown_token_ledger (ip_address, created_at DESC);

-- ---------------------------------------------------------------------------
-- 7. Rate limit buckets (distributed, fail-closed)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.customer_portal_rate_limits (
  bucket_key text NOT NULL,
  window_start timestamptz NOT NULL,
  attempt_count integer NOT NULL DEFAULT 0,
  PRIMARY KEY (bucket_key, window_start)
);

CREATE TABLE IF NOT EXISTS data.customer_portal_rate_limit_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_type text NOT NULL,
  client_key text NOT NULL,
  tenant_id uuid,
  attempt_count integer NOT NULL,
  max_attempts integer NOT NULL,
  window_minutes integer NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION data.assert_customer_portal_rate_limit(
  p_bucket_type text,
  p_client_key text,
  p_max_attempts int DEFAULT 20,
  p_window_minutes int DEFAULT 60,
  p_tenant_id uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_key text;
  v_window_start timestamptz;
  v_count int;
BEGIN
  v_key := left(COALESCE(NULLIF(btrim(p_client_key), ''), 'unknown'), 128);
  p_max_attempts := GREATEST(1, LEAST(COALESCE(p_max_attempts, 20), 200));
  p_window_minutes := GREATEST(1, LEAST(COALESCE(p_window_minutes, 60), 1440));
  v_window_start := to_timestamp(
    floor(extract(epoch FROM now()) / (p_window_minutes * 60.0))
    * (p_window_minutes * 60.0)
  );

  INSERT INTO data.customer_portal_rate_limits (bucket_key, window_start, attempt_count)
  VALUES (p_bucket_type || ':' || v_key, v_window_start, 1)
  ON CONFLICT (bucket_key, window_start) DO UPDATE
    SET attempt_count = data.customer_portal_rate_limits.attempt_count + 1
  RETURNING attempt_count INTO v_count;

  IF v_count > p_max_attempts THEN
    INSERT INTO data.customer_portal_rate_limit_events (
      bucket_type, client_key, tenant_id, attempt_count, max_attempts, window_minutes
    ) VALUES (
      p_bucket_type, v_key, p_tenant_id, v_count, p_max_attempts, p_window_minutes
    );
    RAISE EXCEPTION 'customer_portal_rate_limited'
      USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object(
              'bucket_type', p_bucket_type,
              'attempt_count', v_count,
              'max_attempts', p_max_attempts
            )::text;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION data.assert_customer_portal_rate_limit(text, text, int, int, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.assert_customer_portal_rate_limit(text, text, int, int, uuid)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 8. Email delivery intents (no secret in queue)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.customer_report_share_delivery_intents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  project_id uuid NOT NULL REFERENCES data.projects(id) ON DELETE RESTRICT,
  report_id uuid NOT NULL REFERENCES data.customer_intervention_reports(id) ON DELETE RESTRICT,
  report_version_id uuid NOT NULL
    REFERENCES data.customer_intervention_report_versions(id) ON DELETE RESTRICT,
  customer_account_contact_id uuid NOT NULL REFERENCES data.contacts(id) ON DELETE RESTRICT,
  recipient_contact_id uuid REFERENCES data.contacts(id) ON DELETE SET NULL,
  delivery_channel_id uuid NOT NULL REFERENCES data.contact_delivery_channels(id) ON DELETE RESTRICT,
  contact_relationship_id uuid REFERENCES data.contact_relationships(id) ON DELETE SET NULL,
  channel text NOT NULL DEFAULT 'email' CHECK (channel = 'email'),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'processing', 'sent', 'failed', 'cancelled')),
  idempotency_key text NOT NULL,
  expires_at timestamptz NOT NULL,
  share_id uuid REFERENCES data.customer_report_shares(id) ON DELETE SET NULL,
  failure_reason text,
  created_by uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_crsdi_status
  ON data.customer_report_share_delivery_intents (status, created_at)
  WHERE status IN ('pending', 'processing');

-- ---------------------------------------------------------------------------
-- 9. RLS
-- ---------------------------------------------------------------------------
ALTER TABLE data.customer_portal_platform_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.customer_portal_tenant_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.customer_report_shares ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.customer_portal_share_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.customer_report_share_access_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.customer_portal_unknown_token_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.customer_portal_rate_limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.customer_portal_rate_limit_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.customer_report_share_delivery_intents ENABLE ROW LEVEL SECURITY;

CREATE POLICY cpts_select ON data.customer_portal_tenant_state FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id()));

CREATE POLICY cpts_update ON data.customer_portal_tenant_state FOR UPDATE TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner','manager')
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id()))
  WITH CHECK (data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner','manager'));

CREATE POLICY cpts_insert ON data.customer_portal_tenant_state FOR INSERT TO authenticated
  WITH CHECK (data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner','manager'));

CREATE POLICY crs_select ON data.customer_report_shares FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id()));

-- Writes only via SECURITY DEFINER RPCs (create/enqueue/revoke) — no direct INSERT/UPDATE.
DROP POLICY IF EXISTS crs_insert ON data.customer_report_shares;
DROP POLICY IF EXISTS crs_update ON data.customer_report_shares;

CREATE POLICY crsal_select ON data.customer_report_share_access_logs FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id()));

CREATE POLICY crsdi_select ON data.customer_report_share_delivery_intents FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id()));

DROP POLICY IF EXISTS crsdi_insert ON data.customer_report_share_delivery_intents;
DROP POLICY IF EXISTS crsdi_update ON data.customer_report_share_delivery_intents;

-- Sessions / platform / rate / unknown: no authenticated policies (service_role only)

GRANT SELECT ON data.customer_portal_tenant_state TO authenticated;
GRANT INSERT, UPDATE ON data.customer_portal_tenant_state TO authenticated;
GRANT SELECT ON data.customer_report_shares TO authenticated;
GRANT SELECT ON data.customer_report_share_access_logs TO authenticated;
GRANT SELECT ON data.customer_report_share_delivery_intents TO authenticated;

GRANT ALL ON data.customer_portal_platform_state TO service_role;
GRANT ALL ON data.customer_portal_tenant_state TO service_role;
GRANT ALL ON data.customer_report_shares TO service_role;
GRANT ALL ON data.customer_portal_share_sessions TO service_role;
GRANT ALL ON data.customer_report_share_access_logs TO service_role;
GRANT ALL ON data.customer_portal_unknown_token_ledger TO service_role;
GRANT ALL ON data.customer_portal_rate_limits TO service_role;
GRANT ALL ON data.customer_portal_rate_limit_events TO service_role;
GRANT ALL ON data.customer_report_share_delivery_intents TO service_role;

-- ---------------------------------------------------------------------------
-- 10. API views (never expose token_hash)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.customer_report_shares
WITH (security_invoker = true) AS
SELECT
  s.id, s.tenant_id, s.project_id, s.report_id, s.report_version_id,
  s.customer_account_contact_id, s.recipient_contact_id,
  s.contact_relationship_id, s.delivery_channel_id,
  s.channel, s.expires_at, s.max_sessions, s.max_views,
  s.session_count, s.view_count, s.session_version,
  s.second_channel_confirmed_at, s.creation_snapshot,
  s.created_by, s.created_at, s.revoked_at, s.revoke_reason, s.revoked_by,
  (s.revoked_at IS NULL AND s.expires_at > now()) AS is_active
FROM data.customer_report_shares s;

CREATE OR REPLACE VIEW api.customer_report_share_delivery_intents
WITH (security_invoker = true) AS
SELECT *
FROM data.customer_report_share_delivery_intents;

CREATE OR REPLACE VIEW api.customer_portal_tenant_state
WITH (security_invoker = true) AS
SELECT *
FROM data.customer_portal_tenant_state;

GRANT SELECT ON api.customer_report_shares TO authenticated;
GRANT SELECT ON api.customer_report_share_delivery_intents TO authenticated;
GRANT SELECT ON api.customer_portal_tenant_state TO authenticated;

-- ---------------------------------------------------------------------------
-- 11. Internal: count active shares + assert can create
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.count_active_customer_report_shares(p_tenant_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT COUNT(*)::integer
  FROM data.customer_report_shares s
  WHERE s.tenant_id = p_tenant_id
    AND s.revoked_at IS NULL
    AND s.expires_at > now();
$$;

CREATE OR REPLACE FUNCTION data.assert_can_create_customer_report_share(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_ent jsonb;
  v_cp jsonb;
  v_guardrail int;
  v_active int;
BEGIN
  v_ent := data.resolve_portal_entitlements(p_tenant_id);
  v_cp := v_ent->'customer_portal';

  IF NOT COALESCE((v_cp->>'can_create_shares')::boolean, false) THEN
    RAISE EXCEPTION 'customer_portal_shares_not_allowed'
      USING ERRCODE = 'P0001', DETAIL = v_cp::text;
  END IF;

  v_guardrail := COALESCE((v_cp->>'active_share_guardrail')::int, 500);
  v_active := data.count_active_customer_report_shares(p_tenant_id);
  IF v_active >= v_guardrail THEN
    RAISE EXCEPTION 'active_share_guardrail_reached'
      USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('active', v_active, 'guardrail', v_guardrail)::text;
  END IF;

  RETURN v_cp;
END;
$$;

REVOKE ALL ON FUNCTION data.assert_can_create_customer_report_share(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.assert_can_create_customer_report_share(uuid)
  TO authenticated, service_role;

-- CP-C: channel owned by account OR related person; no hard relationship for person-self / company mailbox
CREATE OR REPLACE FUNCTION data.resolve_delivery_for_customer_account(
  p_tenant_id uuid,
  p_account_contact_id uuid,
  p_delivery_channel_id uuid,
  p_recipient_contact_id uuid DEFAULT NULL,
  p_require_email boolean DEFAULT false
)
RETURNS TABLE (
  recipient_contact_id uuid,
  contact_relationship_id uuid,
  delivery_channel_id uuid
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_account data.contacts%ROWTYPE;
  v_channel data.contact_delivery_channels%ROWTYPE;
  v_recipient uuid;
  v_rel_id uuid;
BEGIN
  SELECT * INTO v_account
  FROM data.contacts
  WHERE id = p_account_contact_id AND tenant_id = p_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'customer_account_required' USING ERRCODE = 'P0001';
  END IF;

  IF p_delivery_channel_id IS NULL THEN
    v_recipient := p_recipient_contact_id;
    IF v_recipient IS NOT NULL AND v_recipient IS DISTINCT FROM p_account_contact_id THEN
      SELECT r.id INTO v_rel_id
      FROM data.contact_relationships r
      WHERE r.tenant_id = p_tenant_id
        AND r.organization_contact_id = p_account_contact_id
        AND r.person_contact_id = v_recipient
        AND data.contact_relationship_is_live(r.revoked_at, r.starts_at, r.ends_at, now())
      ORDER BY r.created_at DESC
      LIMIT 1;
      IF v_rel_id IS NULL THEN
        RAISE EXCEPTION 'recipient_relationship_required' USING ERRCODE = 'P0001';
      END IF;
    END IF;
    RETURN QUERY SELECT v_recipient, v_rel_id, NULL::uuid;
    RETURN;
  END IF;

  SELECT * INTO v_channel
  FROM data.contact_delivery_channels c
  WHERE c.id = p_delivery_channel_id
    AND c.tenant_id = p_tenant_id
    AND c.disabled_at IS NULL
    AND c.verified_at IS NOT NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'delivery_channel_invalid' USING ERRCODE = 'P0001';
  END IF;

  IF p_require_email AND v_channel.channel_type IS DISTINCT FROM 'email' THEN
    RAISE EXCEPTION 'delivery_channel_invalid' USING ERRCODE = 'P0001';
  END IF;

  v_recipient := COALESCE(p_recipient_contact_id, v_channel.contact_id);

  IF v_channel.contact_id = p_account_contact_id THEN
    RETURN QUERY SELECT v_recipient, NULL::uuid, v_channel.id;
    RETURN;
  END IF;

  IF v_account.kind = 'company' THEN
    SELECT r.id INTO v_rel_id
    FROM data.contact_relationships r
    WHERE r.tenant_id = p_tenant_id
      AND r.organization_contact_id = p_account_contact_id
      AND r.person_contact_id = v_channel.contact_id
      AND data.contact_relationship_is_live(r.revoked_at, r.starts_at, r.ends_at, now())
    ORDER BY r.created_at DESC
    LIMIT 1;
    IF v_rel_id IS NOT NULL THEN
      RETURN QUERY SELECT v_recipient, v_rel_id, v_channel.id;
      RETURN;
    END IF;
  END IF;

  RAISE EXCEPTION 'delivery_channel_invalid' USING ERRCODE = 'P0001';
END;
$$;

REVOKE ALL ON FUNCTION data.resolve_delivery_for_customer_account(uuid, uuid, uuid, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.resolve_delivery_for_customer_account(uuid, uuid, uuid, uuid, boolean)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 12. Tenant RPC: create manual share (secret returned once)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.create_customer_report_share(
  p_project_id uuid,
  p_recipient_contact_id uuid DEFAULT NULL,
  p_ttl_hours integer DEFAULT 72,
  p_report_version_id uuid DEFAULT NULL,
  p_max_sessions integer DEFAULT NULL,
  p_max_views integer DEFAULT NULL,
  p_delivery_channel_id uuid DEFAULT NULL,
  p_second_channel_confirmed boolean DEFAULT FALSE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public, extensions
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_project data.projects%ROWTYPE;
  v_report data.customer_intervention_reports%ROWTYPE;
  v_version data.customer_intervention_report_versions%ROWTYPE;
  v_delivery RECORD;
  v_cp jsonb;
  v_secret text;
  v_hash bytea;
  v_share_id uuid;
  v_expires timestamptz;
  v_org uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_project FROM data.projects WHERE id = p_project_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'project_not_found' USING ERRCODE = 'P0001';
  END IF;

  PERFORM data.require_fresh_tenant_permission(
    v_tenant, 'field_service.reports.share', v_project.site_id
  );

  IF NOT data.can_access_project(p_project_id) THEN
    RAISE EXCEPTION 'project_access_denied' USING ERRCODE = 'P0001';
  END IF;

  v_cp := data.assert_can_create_customer_report_share(v_tenant);

  SELECT * INTO v_report
  FROM data.customer_intervention_reports
  WHERE project_id = p_project_id AND tenant_id = v_tenant
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'report_not_found' USING ERRCODE = 'P0001';
  END IF;
  IF v_report.legacy_unresolved THEN
    RAISE EXCEPTION 'legacy_unresolved' USING ERRCODE = 'P0001';
  END IF;

  IF p_report_version_id IS NULL THEN
    IF v_report.current_published_version_id IS NULL THEN
      RAISE EXCEPTION 'no_published_version' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_version
    FROM data.customer_intervention_report_versions
    WHERE id = v_report.current_published_version_id;
  ELSE
    SELECT * INTO v_version
    FROM data.customer_intervention_report_versions
    WHERE id = p_report_version_id
      AND report_id = v_report.id
      AND tenant_id = v_tenant;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'version_not_found' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  v_org := COALESCE(v_version.customer_account_contact_id, v_project.client_id);
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'customer_account_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_delivery
  FROM data.resolve_delivery_for_customer_account(
    v_tenant, v_org, p_delivery_channel_id, p_recipient_contact_id, false
  );

  -- Default 72h. Extended TTL (>72h, max 90d) requires verified channel + second-channel flag.
  IF COALESCE(p_ttl_hours, 72) > 72 THEN
    IF p_second_channel_confirmed IS DISTINCT FROM TRUE THEN
      RAISE EXCEPTION 'second_channel_required' USING ERRCODE = 'P0001';
    END IF;
    IF v_delivery.delivery_channel_id IS NULL THEN
      RAISE EXCEPTION 'verified_recipient_required_for_extended_ttl' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  p_ttl_hours := GREATEST(
    1,
    LEAST(
      COALESCE(p_ttl_hours, 72),
      CASE WHEN p_second_channel_confirmed IS TRUE THEN 24 * 90 ELSE 72 END
    )
  );
  v_expires := now() + make_interval(hours => p_ttl_hours);
  v_secret := encode(gen_random_bytes(32), 'hex');
  v_hash := data.hash_customer_portal_secret(v_secret);

  INSERT INTO data.customer_report_shares (
    tenant_id, project_id, report_id, report_version_id,
    customer_account_contact_id, recipient_contact_id,
    contact_relationship_id, delivery_channel_id,
    token_hash, channel, expires_at, max_sessions, max_views,
    second_channel_confirmed_at, creation_snapshot, created_by
  ) VALUES (
    v_tenant, p_project_id, v_report.id, v_version.id,
    v_org, v_delivery.recipient_contact_id,
    v_delivery.contact_relationship_id, v_delivery.delivery_channel_id,
    v_hash, 'manual_link', v_expires, p_max_sessions, p_max_views,
    CASE WHEN p_second_channel_confirmed IS TRUE THEN now() ELSE NULL END,
    jsonb_build_object(
      'recipient_contact_id', v_delivery.recipient_contact_id,
      'customer_account_contact_id', v_org,
      'delivery_channel_id', v_delivery.delivery_channel_id,
      'report_version_id', v_version.id,
      'version_number', v_version.version_number,
      'content_digest', v_version.content_digest,
      'ttl_hours', p_ttl_hours,
      'second_channel_confirmed', COALESCE(p_second_channel_confirmed, false),
      'guardrail', v_cp->'active_share_guardrail'
    ),
    auth.uid()
  )
  RETURNING id INTO v_share_id;

  INSERT INTO data.customer_intervention_report_events (
    tenant_id, report_id, project_id, event_type, version_id, actor_id, payload
  ) VALUES (
    v_tenant, v_report.id, p_project_id, 'SHARE_CREATED', v_version.id, auth.uid(),
    jsonb_build_object('share_id', v_share_id, 'channel', 'manual_link')
  );

  PERFORM data.log_audit_event_strict(
    v_tenant, auth.uid(), v_project.site_id,
    'CLIENT_REPORT_SHARE_CREATED',
    'customer_report_share', v_share_id,
    jsonb_build_object(
      'project_id', p_project_id,
      'report_version_id', v_version.id,
      'channel', 'manual_link'
    )
  );

  RETURN jsonb_build_object(
    'share_id', v_share_id,
    'secret', v_secret,
    'expires_at', v_expires,
    'report_version_id', v_version.id,
    'channel', 'manual_link'
  );
END;
$$;

REVOKE ALL ON FUNCTION api.create_customer_report_share(uuid, uuid, integer, uuid, integer, integer, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_customer_report_share(uuid, uuid, integer, uuid, integer, integer, uuid, boolean)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 13. List + revoke
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.list_customer_report_shares(p_project_id uuid DEFAULT NULL)
RETURNS SETOF api.customer_report_shares
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = data, public, api
AS $$
  SELECT s.*
  FROM api.customer_report_shares s
  WHERE s.tenant_id = data.active_tenant_id()
    AND (p_project_id IS NULL OR s.project_id = p_project_id)
  ORDER BY s.created_at DESC;
$$;

REVOKE ALL ON FUNCTION api.list_customer_report_shares(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_customer_report_shares(uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.revoke_customer_report_share(
  p_share_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_share data.customer_report_shares%ROWTYPE;
  v_site uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_share
  FROM data.customer_report_shares
  WHERE id = p_share_id AND tenant_id = v_tenant
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'share_not_found' USING ERRCODE = 'P0001';
  END IF;

  SELECT site_id INTO v_site FROM data.projects WHERE id = v_share.project_id;
  PERFORM data.require_fresh_tenant_permission(
    v_tenant, 'field_service.reports.revoke', v_site
  );

  IF v_share.revoked_at IS NOT NULL THEN
    RETURN v_share.id;
  END IF;

  UPDATE data.customer_report_shares
  SET
    revoked_at = now(),
    revoke_reason = NULLIF(btrim(COALESCE(p_reason, '')), ''),
    revoked_by = auth.uid(),
    session_version = session_version + 1
  WHERE id = v_share.id;

  UPDATE data.customer_portal_share_sessions
  SET revoked_at = COALESCE(revoked_at, now())
  WHERE share_id = v_share.id AND revoked_at IS NULL;

  INSERT INTO data.customer_intervention_report_events (
    tenant_id, report_id, project_id, event_type, version_id, actor_id, payload
  ) VALUES (
    v_tenant, v_share.report_id, v_share.project_id, 'SHARE_REVOKED',
    v_share.report_version_id, auth.uid(),
    jsonb_build_object('share_id', v_share.id, 'reason', p_reason)
  );

  PERFORM data.log_audit_event_strict(
    v_tenant, auth.uid(), v_site,
    'CLIENT_REPORT_SHARE_REVOKED',
    'customer_report_share', v_share.id,
    jsonb_build_object('project_id', v_share.project_id, 'reason', p_reason)
  );

  RETURN v_share.id;
END;
$$;

REVOKE ALL ON FUNCTION api.revoke_customer_report_share(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.revoke_customer_report_share(uuid, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 14. Email intent (no secret) + worker fulfill
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.enqueue_customer_report_share_email(
  p_project_id uuid,
  p_delivery_channel_id uuid,
  p_idempotency_key text,
  p_ttl_hours integer DEFAULT 72,
  p_report_version_id uuid DEFAULT NULL,
  p_recipient_contact_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_project data.projects%ROWTYPE;
  v_report data.customer_intervention_reports%ROWTYPE;
  v_version data.customer_intervention_report_versions%ROWTYPE;
  v_delivery RECORD;
  v_org uuid;
  v_intent uuid;
  v_key text := NULLIF(btrim(COALESCE(p_idempotency_key, '')), '');
  v_emails int;
  v_included int;
  v_cp jsonb;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_key IS NULL THEN
    RAISE EXCEPTION 'idempotency_key_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_delivery_channel_id IS NULL THEN
    RAISE EXCEPTION 'delivery_channel_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_project FROM data.projects WHERE id = p_project_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'project_not_found' USING ERRCODE = 'P0001';
  END IF;

  PERFORM data.require_fresh_tenant_permission(
    v_tenant, 'field_service.reports.share', v_project.site_id
  );
  v_cp := data.assert_can_create_customer_report_share(v_tenant);

  -- Soft email budget: block new email intents when over included (policy = block)
  v_included := COALESCE((v_cp->>'included_email_deliveries_month')::int, 2000);
  SELECT COUNT(*)::int INTO v_emails
  FROM data.customer_report_share_delivery_intents i
  WHERE i.tenant_id = v_tenant
    AND i.channel = 'email'
    AND i.created_at >= date_trunc('month', now())
    AND i.status IN ('pending', 'processing', 'sent');
  IF v_emails >= v_included THEN
    RAISE EXCEPTION 'included_email_deliveries_exceeded'
      USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_report
  FROM data.customer_intervention_reports
  WHERE project_id = p_project_id AND tenant_id = v_tenant;
  IF NOT FOUND OR v_report.legacy_unresolved THEN
    RAISE EXCEPTION 'report_not_shareable' USING ERRCODE = 'P0001';
  END IF;

  IF p_report_version_id IS NULL THEN
    SELECT * INTO v_version FROM data.customer_intervention_report_versions
    WHERE id = v_report.current_published_version_id;
  ELSE
    SELECT * INTO v_version FROM data.customer_intervention_report_versions
    WHERE id = p_report_version_id AND report_id = v_report.id;
  END IF;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'version_not_found' USING ERRCODE = 'P0001';
  END IF;

  v_org := COALESCE(v_version.customer_account_contact_id, v_project.client_id);
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'customer_account_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_delivery
  FROM data.resolve_delivery_for_customer_account(
    v_tenant, v_org, p_delivery_channel_id, p_recipient_contact_id, true
  );

  INSERT INTO data.customer_report_share_delivery_intents (
    tenant_id, project_id, report_id, report_version_id,
    customer_account_contact_id, recipient_contact_id,
    delivery_channel_id, contact_relationship_id,
    idempotency_key, expires_at, created_by
  ) VALUES (
    v_tenant, p_project_id, v_report.id, v_version.id,
    v_org, v_delivery.recipient_contact_id,
    v_delivery.delivery_channel_id, v_delivery.contact_relationship_id,
    v_key,
    now() + make_interval(hours => GREATEST(1, LEAST(COALESCE(p_ttl_hours, 72), 72))),
    auth.uid()
  )
  ON CONFLICT (tenant_id, idempotency_key) DO UPDATE
    SET updated_at = now()
  RETURNING id INTO v_intent;

  PERFORM data.log_audit_event_strict(
    v_tenant, auth.uid(), v_project.site_id,
    'CLIENT_REPORT_SHARE_EMAIL_ENQUEUED',
    'customer_report_share_delivery_intent', v_intent,
    jsonb_build_object(
      'project_id', p_project_id,
      'idempotency_key', v_key,
      'delivery_channel_id', p_delivery_channel_id
    )
  );

  RETURN v_intent;
END;
$$;

REVOKE ALL ON FUNCTION api.enqueue_customer_report_share_email(uuid, uuid, text, integer, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.enqueue_customer_report_share_email(uuid, uuid, text, integer, uuid, uuid)
  TO authenticated, service_role;

-- Worker: create share just before send; returns secret once. On uncertainty caller must revoke.
CREATE OR REPLACE FUNCTION api.fulfill_customer_report_share_delivery_intent(p_intent_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public, extensions
AS $$
DECLARE
  v_intent data.customer_report_share_delivery_intents%ROWTYPE;
  v_secret text;
  v_hash bytea;
  v_share_id uuid;
  v_cp jsonb;
  v_to_email text;
  v_bcc text[];
  v_site_id uuid;
BEGIN
  SELECT * INTO v_intent
  FROM data.customer_report_share_delivery_intents
  WHERE id = p_intent_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'intent_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF v_intent.status = 'sent' AND v_intent.share_id IS NOT NULL THEN
    RAISE EXCEPTION 'intent_already_sent' USING ERRCODE = 'P0001';
  END IF;

  IF v_intent.status NOT IN ('pending', 'processing', 'failed') THEN
    RAISE EXCEPTION 'intent_not_fulfillable:%', v_intent.status USING ERRCODE = 'P0001';
  END IF;

  v_cp := data.assert_can_create_customer_report_share(v_intent.tenant_id);

  UPDATE data.customer_report_share_delivery_intents
  SET status = 'processing', updated_at = now()
  WHERE id = v_intent.id;

  -- If a previous share exists from a failed send, revoke it before creating a new one
  IF v_intent.share_id IS NOT NULL THEN
    UPDATE data.customer_report_shares
    SET revoked_at = COALESCE(revoked_at, now()),
        revoke_reason = COALESCE(revoke_reason, 'delivery_retry'),
        session_version = session_version + 1
    WHERE id = v_intent.share_id AND revoked_at IS NULL;
  END IF;

  v_secret := encode(gen_random_bytes(32), 'hex');
  v_hash := data.hash_customer_portal_secret(v_secret);

  INSERT INTO data.customer_report_shares (
    tenant_id, project_id, report_id, report_version_id,
    customer_account_contact_id, recipient_contact_id,
    contact_relationship_id, delivery_channel_id,
    token_hash, channel, expires_at, creation_snapshot, created_by
  ) VALUES (
    v_intent.tenant_id, v_intent.project_id, v_intent.report_id, v_intent.report_version_id,
    v_intent.customer_account_contact_id, v_intent.recipient_contact_id,
    v_intent.contact_relationship_id, v_intent.delivery_channel_id,
    v_hash, 'email', v_intent.expires_at,
    jsonb_build_object(
      'intent_id', v_intent.id,
      'idempotency_key', v_intent.idempotency_key,
      'guardrail', v_cp->'active_share_guardrail'
    ),
    v_intent.created_by
  )
  RETURNING id INTO v_share_id;

  UPDATE data.customer_report_share_delivery_intents
  SET share_id = v_share_id, updated_at = now()
  WHERE id = v_intent.id;

  INSERT INTO data.customer_intervention_report_events (
    tenant_id, report_id, project_id, event_type, version_id, actor_id, payload
  ) VALUES (
    v_intent.tenant_id, v_intent.report_id, v_intent.project_id,
    'SHARE_CREATED', v_intent.report_version_id, v_intent.created_by,
    jsonb_build_object('share_id', v_share_id, 'channel', 'email', 'intent_id', v_intent.id)
  );

  SELECT c.value_normalized INTO v_to_email
  FROM data.contact_delivery_channels c
  WHERE c.id = v_intent.delivery_channel_id;

  SELECT t.bulletin_bcc_emails INTO v_bcc
  FROM data.customer_portal_tenant_state t
  WHERE t.tenant_id = v_intent.tenant_id;

  SELECT p.site_id INTO v_site_id
  FROM data.projects p
  WHERE p.id = v_intent.project_id;

  RETURN jsonb_build_object(
    'intent_id', v_intent.id,
    'share_id', v_share_id,
    'secret', v_secret,
    'expires_at', v_intent.expires_at,
    'delivery_channel_id', v_intent.delivery_channel_id,
    'to_email', v_to_email,
    'tenant_id', v_intent.tenant_id,
    'site_id', v_site_id,
    'project_id', v_intent.project_id,
    'report_version_id', v_intent.report_version_id,
    'idempotency_key', v_intent.idempotency_key,
    'bulletin_bcc_emails', to_jsonb(COALESCE(v_bcc, ARRAY[]::text[]))
  );
END;
$$;

-- Claim pending delivery intents for the fulfill worker (SKIP LOCKED).
-- Also reclaims stale `processing` rows (worker crash / mark-success lost) after
-- a visibility window so emails are not stuck forever without a new INSERT.
DROP FUNCTION IF EXISTS api.claim_customer_report_share_delivery_intents(integer);
DROP FUNCTION IF EXISTS api.claim_customer_report_share_delivery_intents(integer, integer);

CREATE OR REPLACE FUNCTION api.claim_customer_report_share_delivery_intents(
  p_limit integer DEFAULT 20,
  p_stale_after_seconds integer DEFAULT 300
)
RETURNS TABLE (id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_stale interval := make_interval(
    secs => GREATEST(60, LEAST(COALESCE(p_stale_after_seconds, 300), 3600))
  );
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  WITH claimable AS (
    SELECT x.id
    FROM data.customer_report_share_delivery_intents x
    WHERE x.status = 'pending'
       OR (
         x.status = 'processing'
         AND x.updated_at < now() - v_stale
       )
    ORDER BY x.created_at ASC
    LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 20), 100))
    FOR UPDATE OF x SKIP LOCKED
  )
  UPDATE data.customer_report_share_delivery_intents i
  SET status = 'processing',
      updated_at = now(),
      failure_reason = CASE
        WHEN i.status = 'processing' THEN COALESCE(i.failure_reason, 'reclaimed_stale_processing')
        ELSE i.failure_reason
      END
  FROM claimable c
  WHERE i.id = c.id
  RETURNING i.id;
END;
$$;

CREATE OR REPLACE FUNCTION api.mark_customer_report_share_delivery_result(
  p_intent_id uuid,
  p_success boolean,
  p_failure_reason text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_intent data.customer_report_share_delivery_intents%ROWTYPE;
BEGIN
  SELECT * INTO v_intent
  FROM data.customer_report_share_delivery_intents
  WHERE id = p_intent_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'intent_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF p_success THEN
    UPDATE data.customer_report_share_delivery_intents
    SET status = 'sent', failure_reason = NULL, updated_at = now()
    WHERE id = p_intent_id;
  ELSE
    UPDATE data.customer_report_share_delivery_intents
    SET status = 'failed',
        failure_reason = NULLIF(btrim(COALESCE(p_failure_reason, '')), ''),
        updated_at = now()
    WHERE id = p_intent_id;

    IF v_intent.share_id IS NOT NULL THEN
      UPDATE data.customer_report_shares
      SET revoked_at = COALESCE(revoked_at, now()),
          revoke_reason = COALESCE(revoke_reason, 'delivery_failed'),
          session_version = session_version + 1
      WHERE id = v_intent.share_id AND revoked_at IS NULL;

      UPDATE data.customer_portal_share_sessions
      SET revoked_at = COALESCE(revoked_at, now())
      WHERE share_id = v_intent.share_id AND revoked_at IS NULL;
    END IF;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION api.fulfill_customer_report_share_delivery_intent(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.mark_customer_report_share_delivery_result(uuid, boolean, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.claim_customer_report_share_delivery_intents(integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.fulfill_customer_report_share_delivery_intent(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION api.mark_customer_report_share_delivery_result(uuid, boolean, text) TO service_role;
GRANT EXECUTE ON FUNCTION api.claim_customer_report_share_delivery_intents(integer, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 15. Privileged resolver (service_role only) — Edge Function
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.exchange_customer_report_share_token(
  p_token_hash bytea,
  p_session_ttl_minutes integer DEFAULT 30,
  p_ip_address inet DEFAULT NULL,
  p_user_agent text DEFAULT NULL,
  p_client_key text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public, extensions
AS $$
DECLARE
  v_share data.customer_report_shares%ROWTYPE;
  v_platform data.customer_portal_platform_state%ROWTYPE;
  v_tstate data.customer_portal_tenant_state%ROWTYPE;
  v_version data.customer_intervention_report_versions%ROWTYPE;
  v_session_secret text;
  v_session_hash bytea;
  v_session_id uuid;
  v_denied text;
BEGIN
  BEGIN
    PERFORM data.assert_customer_portal_rate_limit(
      'share_resolve',
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

  SELECT * INTO v_share
  FROM data.customer_report_shares
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
  v_tstate := data.ensure_customer_portal_tenant_state(v_share.tenant_id);

  v_denied := NULL;
  IF NOT v_platform.enabled OR NOT v_tstate.enabled THEN
    v_denied := 'kill_switch';
  ELSIF v_share.revoked_at IS NOT NULL THEN
    v_denied := 'revoked';
  ELSIF v_share.expires_at <= now() THEN
    v_denied := 'expired';
  ELSIF v_share.max_sessions IS NOT NULL AND v_share.session_count >= v_share.max_sessions THEN
    v_denied := 'session_limit';
  END IF;

  IF v_denied IS NOT NULL THEN
    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, share_id, report_version_id, action, http_status, failure_reason, ip_address, user_agent
    ) VALUES (
      v_share.tenant_id, v_share.id, v_share.report_version_id,
      'resolve_denied', 410, v_denied, p_ip_address, left(COALESCE(p_user_agent, ''), 512)
    );
    -- Identical external shape for invalid/revoked/expired
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  SELECT * INTO v_version
  FROM data.customer_intervention_report_versions
  WHERE id = v_share.report_version_id;

  v_session_secret := encode(gen_random_bytes(32), 'hex');
  v_session_hash := data.hash_customer_portal_secret(v_session_secret);

  INSERT INTO data.customer_portal_share_sessions (
    tenant_id, share_id, report_version_id, session_token_hash,
    share_session_version, security_version_tenant, security_version_platform,
    expires_at, ip_address, user_agent, last_seen_at
  ) VALUES (
    v_share.tenant_id, v_share.id, v_share.report_version_id, v_session_hash,
    v_share.session_version, v_tstate.security_version, v_platform.security_version,
    now() + make_interval(mins => GREATEST(5, LEAST(COALESCE(p_session_ttl_minutes, 30), 120))),
    p_ip_address, left(COALESCE(p_user_agent, ''), 512), now()
  )
  RETURNING id INTO v_session_id;

  UPDATE data.customer_report_shares
  SET session_count = session_count + 1
  WHERE id = v_share.id;

  INSERT INTO data.customer_report_share_access_logs (
    tenant_id, share_id, session_id, report_version_id, action, http_status, ip_address, user_agent
  ) VALUES (
    v_share.tenant_id, v_share.id, v_session_id, v_share.report_version_id,
    'session_create', 200, p_ip_address, left(COALESCE(p_user_agent, ''), 512)
  );

  RETURN jsonb_build_object(
    'ok', true,
    'session_id', v_session_id,
    'session_secret', v_session_secret,
    'expires_at', now() + make_interval(mins => GREATEST(5, LEAST(COALESCE(p_session_ttl_minutes, 30), 120))),
    'tenant_id', v_share.tenant_id,
    'share_id', v_share.id,
    'report_version_id', v_share.report_version_id,
    'projection', v_version.projection,
    'media_manifest', v_version.media_manifest,
    'locale', v_version.locale,
    'content_digest', v_version.content_digest
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.resolve_customer_portal_share_session(
  p_session_token_hash bytea,
  p_action text DEFAULT 'report_view',
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
  v_sess data.customer_portal_share_sessions%ROWTYPE;
  v_share data.customer_report_shares%ROWTYPE;
  v_platform data.customer_portal_platform_state%ROWTYPE;
  v_tstate data.customer_portal_tenant_state%ROWTYPE;
  v_version data.customer_intervention_report_versions%ROWTYPE;
BEGIN
  IF p_session_token_hash IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  SELECT * INTO v_sess
  FROM data.customer_portal_share_sessions
  WHERE session_token_hash = p_session_token_hash
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  SELECT * INTO v_share FROM data.customer_report_shares WHERE id = v_sess.share_id;
  SELECT * INTO v_platform FROM data.customer_portal_platform_state WHERE id;
  v_tstate := data.ensure_customer_portal_tenant_state(v_sess.tenant_id);

  IF v_sess.revoked_at IS NOT NULL
     OR v_sess.expires_at <= now()
     OR v_share.revoked_at IS NOT NULL
     OR v_share.expires_at <= now()
     OR NOT v_platform.enabled
     OR NOT v_tstate.enabled
     OR v_sess.share_session_version IS DISTINCT FROM v_share.session_version
     OR v_sess.security_version_tenant IS DISTINCT FROM v_tstate.security_version
     OR v_sess.security_version_platform IS DISTINCT FROM v_platform.security_version
  THEN
    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, share_id, session_id, report_version_id, action, http_status,
      failure_reason, ip_address, user_agent, request_id
    ) VALUES (
      v_sess.tenant_id, v_sess.share_id, v_sess.id, v_sess.report_version_id,
      'session_denied', 401, 'session_invalid', p_ip_address,
      left(COALESCE(p_user_agent, ''), 512), p_request_id
    );
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  IF v_share.max_views IS NOT NULL AND v_share.view_count >= v_share.max_views
     AND COALESCE(p_action, 'report_view') = 'report_view' THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  SELECT * INTO v_version
  FROM data.customer_intervention_report_versions
  WHERE id = v_sess.report_version_id;

  UPDATE data.customer_portal_share_sessions
  SET last_seen_at = now()
  WHERE id = v_sess.id;

  IF COALESCE(p_action, 'report_view') = 'report_view' THEN
    -- Idempotent view log by request_id when provided
    IF p_request_id IS NULL OR NOT EXISTS (
      SELECT 1 FROM data.customer_report_share_access_logs l
      WHERE l.session_id = v_sess.id
        AND l.action = 'report_view'
        AND l.request_id = p_request_id
    ) THEN
      INSERT INTO data.customer_report_share_access_logs (
        tenant_id, share_id, session_id, report_version_id, action, http_status,
        ip_address, user_agent, request_id
      ) VALUES (
        v_sess.tenant_id, v_sess.share_id, v_sess.id, v_sess.report_version_id,
        'report_view', 200, p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
      );
      UPDATE data.customer_report_shares
      SET view_count = view_count + 1
      WHERE id = v_share.id;
    END IF;
  ELSIF p_action = 'media_download' THEN
    IF p_request_id IS NULL OR NOT EXISTS (
      SELECT 1 FROM data.customer_report_share_access_logs l
      WHERE l.session_id = v_sess.id
        AND l.action = 'media_download'
        AND l.request_id = p_request_id
    ) THEN
      INSERT INTO data.customer_report_share_access_logs (
        tenant_id, share_id, session_id, report_version_id, action, http_status,
        ip_address, user_agent, request_id
      ) VALUES (
        v_sess.tenant_id, v_sess.share_id, v_sess.id, v_sess.report_version_id,
        'media_download', 200, p_ip_address, left(COALESCE(p_user_agent, ''), 512), p_request_id
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'tenant_id', v_sess.tenant_id,
    'share_id', v_share.id,
    'session_id', v_sess.id,
    'report_version_id', v_version.id,
    'projection', v_version.projection,
    'media_manifest', v_version.media_manifest,
    'locale', v_version.locale,
    'content_digest', v_version.content_digest
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.set_customer_portal_kill_switch(
  p_scope text, -- 'platform' | 'tenant'
  p_tenant_id uuid DEFAULT NULL,
  p_enabled boolean DEFAULT false,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  -- Platform admin path; tenant managers can disable their own portal surface.
  IF p_scope = 'platform' THEN
    UPDATE data.customer_portal_platform_state
    SET
      enabled = COALESCE(p_enabled, false),
      security_version = security_version + 1,
      updated_at = now(),
      updated_by = auth.uid(),
      note = NULLIF(btrim(COALESCE(p_note, '')), '')
    WHERE id;
    RETURN (SELECT to_jsonb(s) FROM data.customer_portal_platform_state s WHERE id);
  ELSIF p_scope = 'tenant' THEN
    IF p_tenant_id IS NULL THEN
      RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'P0001';
    END IF;
    PERFORM data.ensure_customer_portal_tenant_state(p_tenant_id);
    UPDATE data.customer_portal_tenant_state
    SET
      enabled = COALESCE(p_enabled, false),
      security_version = security_version + 1,
      updated_at = now(),
      restriction_reason = CASE WHEN COALESCE(p_enabled, false) THEN NULL ELSE 'manual' END,
      restriction_note = NULLIF(btrim(COALESCE(p_note, '')), ''),
      restricted_at = CASE WHEN COALESCE(p_enabled, false) THEN NULL ELSE now() END,
      restricted_by = CASE WHEN COALESCE(p_enabled, false) THEN NULL ELSE auth.uid() END
    WHERE tenant_id = p_tenant_id;
    RETURN (SELECT to_jsonb(s) FROM data.customer_portal_tenant_state s WHERE tenant_id = p_tenant_id);
  ELSE
    RAISE EXCEPTION 'invalid_scope' USING ERRCODE = 'P0001';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION api.exchange_customer_report_share_token(bytea, integer, inet, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.resolve_customer_portal_share_session(bytea, text, inet, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.set_customer_portal_kill_switch(text, uuid, boolean, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.exchange_customer_report_share_token(bytea, integer, inet, text, text)
  TO service_role;
GRANT EXECUTE ON FUNCTION api.resolve_customer_portal_share_session(bytea, text, inet, text, text)
  TO service_role;
-- Kill-switch: service_role for platform; authenticated for own tenant via wrapper below
GRANT EXECUTE ON FUNCTION api.set_customer_portal_kill_switch(text, uuid, boolean, text)
  TO service_role;

CREATE OR REPLACE FUNCTION api.set_my_customer_portal_enabled(
  p_enabled boolean,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF (data.jwt_user_tenants() -> v_tenant::text ->> 'global_role') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  PERFORM data.ensure_customer_portal_tenant_state(v_tenant);

  UPDATE data.customer_portal_tenant_state
  SET
    enabled = COALESCE(p_enabled, false),
    security_version = security_version + 1,
    updated_at = now(),
    restriction_reason = CASE WHEN COALESCE(p_enabled, false) THEN NULL ELSE 'manual' END,
    restriction_note = NULLIF(btrim(COALESCE(p_note, '')), ''),
    restricted_at = CASE WHEN COALESCE(p_enabled, false) THEN NULL ELSE now() END,
    restricted_by = CASE WHEN COALESCE(p_enabled, false) THEN NULL ELSE auth.uid() END
  WHERE tenant_id = v_tenant;

  RETURN (SELECT to_jsonb(s) FROM data.customer_portal_tenant_state s WHERE tenant_id = v_tenant);
END;
$$;

REVOKE ALL ON FUNCTION api.set_my_customer_portal_enabled(boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_my_customer_portal_enabled(boolean, text)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.set_my_customer_portal_bulletin_bcc(
  p_bcc_emails text[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_normalized text[];
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF (data.jwt_user_tenants() -> v_tenant::text ->> 'global_role') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  PERFORM data.ensure_customer_portal_tenant_state(v_tenant);

  SELECT COALESCE(
    (
      SELECT array_agg(e ORDER BY e)
      FROM (
        SELECT DISTINCT lower(btrim(x)) AS e
        FROM unnest(COALESCE(p_bcc_emails, ARRAY[]::text[])) AS x
        WHERE NULLIF(btrim(x), '') IS NOT NULL
      ) s
    ),
    ARRAY[]::text[]
  )
  INTO v_normalized;

  IF cardinality(v_normalized) = 0 THEN
    v_normalized := NULL;
  END IF;

  UPDATE data.customer_portal_tenant_state
  SET
    bulletin_bcc_emails = v_normalized,
    updated_at = now()
  WHERE tenant_id = v_tenant;

  PERFORM data.log_audit_event_strict(
    v_tenant, auth.uid(), NULL,
    'CUSTOMER_PORTAL_BULLETIN_BCC_UPDATED',
    'customer_portal_tenant_state', v_tenant,
    jsonb_build_object(
      'bcc_count', COALESCE(cardinality(v_normalized), 0)
    )
  );

  RETURN (SELECT to_jsonb(s) FROM data.customer_portal_tenant_state s WHERE tenant_id = v_tenant);
END;
$$;

REVOKE ALL ON FUNCTION api.set_my_customer_portal_bulletin_bcc(text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_my_customer_portal_bulletin_bcc(text[])
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 16. Worker dispatcher: claim → Edge fulfill-customer-report-share-emails
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.invoke_customer_report_share_email_worker()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_supabase_url text;
  v_service_key text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RAISE WARNING
      'invoke_customer_report_share_email_worker: pg_net not installed. Skipping.';
    RETURN;
  END IF;

  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'app_supabase_url'
  LIMIT 1;

  SELECT decrypted_secret INTO v_service_key
  FROM vault.decrypted_secrets
  WHERE name = 'app_service_role_key'
  LIMIT 1;

  IF v_supabase_url IS NULL OR v_service_key IS NULL THEN
    RAISE WARNING
      'invoke_customer_report_share_email_worker: vault secrets missing. Skipping.';
    RETURN;
  END IF;

  BEGIN
    PERFORM extensions.http_post(
      url     := v_supabase_url || '/functions/v1/fulfill-customer-report-share-emails',
      headers := jsonb_build_object(
        'Content-Type',  'application/json',
        'Authorization', 'Bearer ' || v_service_key
      ),
      body    := jsonb_build_object('limit', 20),
      timeout_milliseconds := 5000
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING
      'invoke_customer_report_share_email_worker: http_post failed: %', SQLERRM;
  END;
END;
$$;

REVOKE ALL ON FUNCTION data.invoke_customer_report_share_email_worker() FROM PUBLIC;
REVOKE ALL ON FUNCTION data.invoke_customer_report_share_email_worker() FROM authenticated;
REVOKE ALL ON FUNCTION data.invoke_customer_report_share_email_worker() FROM anon;

CREATE OR REPLACE FUNCTION data.trg_notify_customer_report_share_email_worker()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  PERFORM data.invoke_customer_report_share_email_worker();
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_customer_report_share_email_notify
  ON data.customer_report_share_delivery_intents;
CREATE TRIGGER trg_customer_report_share_email_notify
  AFTER INSERT ON data.customer_report_share_delivery_intents
  FOR EACH STATEMENT
  EXECUTE FUNCTION data.trg_notify_customer_report_share_email_worker();

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('fulfill-customer-report-share-emails')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'fulfill-customer-report-share-emails'
    );

    PERFORM cron.schedule(
      'fulfill-customer-report-share-emails',
      '*/2 * * * *',
      'SELECT data.invoke_customer_report_share_email_worker()'
    );
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 17. Auto-enqueue on_publish delivery rules after CIR publish
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.enqueue_bulletin_on_publish_intents(
  p_tenant_id uuid,
  p_project_id uuid,
  p_report_id uuid,
  p_version_id uuid,
  p_account_contact_id uuid,
  p_actor uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_rule record;
  v_count int := 0;
  v_key text;
  v_delivery record;
BEGIN
  IF p_account_contact_id IS NULL THEN
    RETURN 0;
  END IF;

  -- Skip quietly when shares are disabled / guardrail hit — do not dirty the queue.
  BEGIN
    PERFORM data.assert_can_create_customer_report_share(p_tenant_id);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%customer_portal_shares_not_allowed%'
       OR SQLERRM LIKE '%active_share_guardrail_reached%' THEN
      RETURN 0;
    END IF;
    RAISE;
  END;

  FOR v_rule IN
    SELECT r.id, r.contact_point_id, c.contact_id AS recipient_contact_id
    FROM data.contact_delivery_rules r
    JOIN data.contact_delivery_channels c
      ON c.id = r.contact_point_id
     AND c.tenant_id = r.tenant_id
     AND c.disabled_at IS NULL
     AND c.verified_at IS NOT NULL
     AND c.channel_type = 'email'
    WHERE r.tenant_id = p_tenant_id
      AND r.client_account_contact_id = p_account_contact_id
      AND r.purpose = 'bulletin'
      AND r.policy = 'on_publish'
      AND r.disabled_at IS NULL
  LOOP
    -- Re-validate account↔channel (incl. ends_at) so expired affiliations skip enqueue.
    BEGIN
      SELECT * INTO v_delivery
      FROM data.resolve_delivery_for_customer_account(
        p_tenant_id,
        p_account_contact_id,
        v_rule.contact_point_id,
        v_rule.recipient_contact_id,
        true
      );
    EXCEPTION WHEN OTHERS THEN
      CONTINUE;
    END;

    v_key := format(
      'on_publish:%s:%s:%s',
      p_version_id, v_rule.contact_point_id, v_rule.id
    );
    INSERT INTO data.customer_report_share_delivery_intents (
      tenant_id, project_id, report_id, report_version_id,
      customer_account_contact_id, recipient_contact_id,
      delivery_channel_id, idempotency_key, expires_at, created_by
    ) VALUES (
      p_tenant_id, p_project_id, p_report_id, p_version_id,
      p_account_contact_id, v_delivery.recipient_contact_id,
      v_delivery.delivery_channel_id, v_key,
      now() + interval '72 hours', p_actor
    )
    ON CONFLICT (tenant_id, idempotency_key) DO NOTHING;
    IF FOUND THEN
      v_count := v_count + 1;
    END IF;
  END LOOP;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION data.enqueue_bulletin_on_publish_intents(uuid, uuid, uuid, uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.enqueue_bulletin_on_publish_intents(uuid, uuid, uuid, uuid, uuid, uuid) FROM authenticated;
REVOKE ALL ON FUNCTION data.enqueue_bulletin_on_publish_intents(uuid, uuid, uuid, uuid, uuid, uuid) FROM anon;
-- Internal only: version AFTER INSERT trigger (DEFINER) + service_role ops.
GRANT EXECUTE ON FUNCTION data.enqueue_bulletin_on_publish_intents(uuid, uuid, uuid, uuid, uuid, uuid)
  TO service_role;

CREATE OR REPLACE FUNCTION data.trg_cir_version_enqueue_on_publish()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  -- Historical reconciliation must never behave like a new publication.
  IF COALESCE(NEW.template_version, '') LIKE 'legacy-%'
     OR COALESCE(NEW.snapshots, '{}'::jsonb) ? 'legacy_source' THEN
    RETURN NEW;
  END IF;

  PERFORM data.enqueue_bulletin_on_publish_intents(
    NEW.tenant_id,
    NEW.project_id,
    NEW.report_id,
    NEW.id,
    NEW.customer_account_contact_id,
    COALESCE(NEW.published_by, auth.uid())
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cir_version_enqueue_on_publish
  ON data.customer_intervention_report_versions;
CREATE TRIGGER trg_cir_version_enqueue_on_publish
  AFTER INSERT ON data.customer_intervention_report_versions
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_cir_version_enqueue_on_publish();
