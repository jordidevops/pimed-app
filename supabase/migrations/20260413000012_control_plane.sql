-- ============================================================
--  Migration: 20260413000012_control_plane
--
--  Adds the platform Control Plane:
--    • data.storage_egress_logs       – download/share egress events (tenant + optional site)
--    • data.feature_flags             – global platform toggles
--    • data.tenant_feature_overrides  – per-tenant flag overrides
--    • data.tenant_storage_limits     – admin-controlled internal bucket limits
--    • data.plans.features_jsonb      – plan-level feature flag defaults
--    • data.is_feature_enabled()      – hash-based rollout func
--    • api.log_egress()               – SECURITY DEFINER edge-function wrapper
--    • api.get_internal_limits()      – SECURITY DEFINER limits query
--    • api.check_upload_eligibility() – extended to respect internal_quota_gb
--    • api.tenant_entitlements        – single-source-of-truth view for admin
--
--  Notes:
--    • Aquest fitxer forma part del backoffice/control plane i no canvia
--      el model base d'autenticació (JWT claims + RLS) definit a migració 3.
--    • Les Edge Functions poden escriure egress via funcions SECURITY DEFINER.
-- ============================================================

-- ---------------------------------------------------------------------------
-- 1. data.plans — add features_jsonb
-- ---------------------------------------------------------------------------
ALTER TABLE data.plans
  ADD COLUMN IF NOT EXISTS features_jsonb jsonb NOT NULL DEFAULT '{}';

COMMENT ON COLUMN data.plans.features_jsonb
  IS 'JSON map of feature-key → default enabled value for tenants on this plan';

-- ---------------------------------------------------------------------------
-- 2. data.storage_egress_logs — egress events (downloads + share-link resolves)
-- ---------------------------------------------------------------------------
CREATE TABLE data.storage_egress_logs (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id             uuid        REFERENCES data.sites(id) ON DELETE SET NULL,  -- granularitat de facturació per site
  node_id             uuid,                   -- nullable: share links may not resolve a node
  storage_provider_id uuid        REFERENCES data.storage_providers(id) ON DELETE SET NULL,
  size_bytes          bigint      NOT NULL DEFAULT 0,
  created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_egress_tenant_created ON data.storage_egress_logs (tenant_id, created_at DESC);
CREATE INDEX idx_egress_created        ON data.storage_egress_logs (created_at DESC);

COMMENT ON TABLE data.storage_egress_logs
  IS 'Platform egress events: downloads via signed URL or share-link resolve';

-- ---------------------------------------------------------------------------
-- 3. data.feature_flags — global platform feature toggles
-- ---------------------------------------------------------------------------
CREATE TABLE data.feature_flags (
  key                text        PRIMARY KEY,
  description        text,
  is_enabled         boolean     NOT NULL DEFAULT true,
  rollout_percentage smallint    NOT NULL DEFAULT 100
    CONSTRAINT feature_flags_rollout_pct CHECK (rollout_percentage BETWEEN 0 AND 100),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE data.feature_flags
  IS 'Global feature flags with hash-based percentage rollout support';

-- ---------------------------------------------------------------------------
-- 4. data.tenant_feature_overrides — per-tenant flag overrides
-- ---------------------------------------------------------------------------
CREATE TABLE data.tenant_feature_overrides (
  tenant_id       uuid        NOT NULL REFERENCES data.tenants(id)       ON DELETE CASCADE,
  feature_key     text        NOT NULL REFERENCES data.feature_flags(key) ON DELETE CASCADE,
  override_status boolean     NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, feature_key)
);

COMMENT ON TABLE data.tenant_feature_overrides
  IS 'Per-tenant overrides that take precedence over the global feature flag setting';

-- ---------------------------------------------------------------------------
-- 5. data.tenant_storage_limits — admin-controlled internal bucket limits
-- ---------------------------------------------------------------------------
CREATE TABLE data.tenant_storage_limits (
  tenant_id               uuid         PRIMARY KEY REFERENCES data.tenants(id) ON DELETE CASCADE,
  internal_quota_gb       numeric(10,2),          -- NULL → fall back to plan.max_storage_mb
  internal_max_file_mb    integer,                -- NULL → no per-file size limit
  internal_allowed_mimes  text[]       NOT NULL DEFAULT '{}',  -- empty → allow all
  created_at              timestamptz  NOT NULL DEFAULT now(),
  updated_at              timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON TABLE data.tenant_storage_limits
  IS 'Admin-controlled limits for the internal (Supabase) storage bucket per tenant';

-- ---------------------------------------------------------------------------
-- 6. data.is_feature_enabled — hash-based rollout with per-tenant override
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.is_feature_enabled(
  p_tenant_id   uuid,
  p_feature_key text
)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = data AS $$
DECLARE
  v_override  boolean;
  v_enabled   boolean;
  v_rollout   smallint;
BEGIN
  -- Per-tenant override takes precedence
  SELECT override_status INTO v_override
    FROM data.tenant_feature_overrides
   WHERE tenant_id = p_tenant_id AND feature_key = p_feature_key;

  IF FOUND THEN
    RETURN v_override;
  END IF;

  -- No override: check global flag
  SELECT is_enabled, rollout_percentage
    INTO v_enabled, v_rollout
    FROM data.feature_flags
   WHERE key = p_feature_key;

  IF NOT FOUND OR NOT v_enabled THEN
    RETURN false;
  END IF;

  -- Full rollout: fast path
  IF v_rollout >= 100 THEN RETURN true;  END IF;
  IF v_rollout <= 0   THEN RETURN false; END IF;

  -- Hash-based deterministic assignment (tenant + feature as entropy)
  RETURN abs(hashtext(p_tenant_id::text || ':' || p_feature_key)) % 100 < v_rollout;
END;
$$;

GRANT EXECUTE ON FUNCTION data.is_feature_enabled(uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION data.is_feature_enabled(uuid, text) TO prisma_admin;

-- ---------------------------------------------------------------------------
-- 7. api.log_egress — SECURITY DEFINER wrapper called by Edge Functions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.log_egress(
  p_tenant_id           uuid,
  p_node_id             uuid,
  p_storage_provider_id uuid,
  p_size_bytes          bigint
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = data AS $$
BEGIN
  INSERT INTO data.storage_egress_logs (tenant_id, node_id, storage_provider_id, size_bytes)
  VALUES (p_tenant_id, p_node_id, p_storage_provider_id, p_size_bytes);
END;
$$;

REVOKE ALL   ON FUNCTION api.log_egress(uuid, uuid, uuid, bigint) FROM PUBLIC;
REVOKE ALL   ON FUNCTION api.log_egress(uuid, uuid, uuid, bigint) FROM authenticated;
REVOKE ALL   ON FUNCTION api.log_egress(uuid, uuid, uuid, bigint) FROM anon;
GRANT EXECUTE ON FUNCTION api.log_egress(uuid, uuid, uuid, bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- 8. api.get_internal_limits — per-tenant internal bucket limits for Edge Functions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_internal_limits(p_tenant_id uuid)
RETURNS TABLE (
  internal_max_file_mb   integer,
  internal_allowed_mimes text[]
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = data AS $$
  SELECT
    tsl.internal_max_file_mb,
    COALESCE(tsl.internal_allowed_mimes, '{}') AS internal_allowed_mimes
  FROM data.tenant_storage_limits tsl
  WHERE tsl.tenant_id = p_tenant_id;
$$;

REVOKE ALL   ON FUNCTION api.get_internal_limits(uuid) FROM PUBLIC;
REVOKE ALL   ON FUNCTION api.get_internal_limits(uuid) FROM authenticated;
REVOKE ALL   ON FUNCTION api.get_internal_limits(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION api.get_internal_limits(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 9. api.check_upload_eligibility — extended to respect tenant_storage_limits
--    Replaces the version created in 20260401000006_file_management.sql.
--    New behaviour: when internal_quota_gb is set it overrides plan.max_storage_mb.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.check_upload_eligibility(
  p_tenant_id  uuid,
  p_size_bytes bigint
)
RETURNS TABLE (
  storage_blocked        boolean,
  storage_blocked_reason text,
  quota_exceeded         boolean,
  current_bytes          bigint,
  max_bytes              bigint
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = data AS $$
  SELECT
    t.storage_blocked,
    t.storage_blocked_reason,
    CASE
      -- Admin-set internal quota takes precedence over plan quota
      WHEN tsl.internal_quota_gb IS NOT NULL THEN
        (COALESCE(su.committed_bytes, 0) + COALESCE(su.reserved_bytes, 0) + p_size_bytes)
        > (tsl.internal_quota_gb * 1024 * 1024 * 1024)::bigint
      WHEN p.max_storage_mb IS NULL THEN false
      ELSE
        (COALESCE(su.committed_bytes, 0) + COALESCE(su.reserved_bytes, 0) + p_size_bytes)
        > (p.max_storage_mb::bigint * 1024 * 1024)
    END AS quota_exceeded,
    COALESCE(su.committed_bytes, 0) + COALESCE(su.reserved_bytes, 0) AS current_bytes,
    CASE
      WHEN tsl.internal_quota_gb IS NOT NULL THEN
        (tsl.internal_quota_gb * 1024 * 1024 * 1024)::bigint
      ELSE
        COALESCE(p.max_storage_mb::bigint * 1024 * 1024, 0)
    END AS max_bytes
  FROM data.tenants t
  LEFT JOIN data.plans               p   ON p.id   = t.plan_id
  LEFT JOIN data.storage_usage       su  ON su.tenant_id = t.id
  LEFT JOIN data.tenant_storage_limits tsl ON tsl.tenant_id = t.id
  WHERE t.id = p_tenant_id;
$$;

REVOKE ALL   ON FUNCTION api.check_upload_eligibility(uuid, bigint) FROM PUBLIC;
REVOKE ALL   ON FUNCTION api.check_upload_eligibility(uuid, bigint) FROM authenticated;
REVOKE ALL   ON FUNCTION api.check_upload_eligibility(uuid, bigint) FROM anon;
GRANT EXECUTE ON FUNCTION api.check_upload_eligibility(uuid, bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- 10. api.tenant_entitlements — single source of truth for admin portal
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.tenant_entitlements AS
SELECT
  t.id                                                                  AS tenant_id,
  t.name                                                                AS tenant_name,
  t.slug,
  t.is_active,
  t.storage_blocked,
  t.storage_blocked_reason,
  -- Plan
  p.id                                                                  AS plan_id,
  p.name                                                                AS plan_name,
  p.display_name                                                        AS plan_display_name,
  p.max_members,
  p.max_storage_mb                                                      AS plan_max_storage_mb,
  p.features_jsonb                                                      AS plan_features,
  -- Admin overrides
  tsl.internal_quota_gb,
  tsl.internal_max_file_mb,
  tsl.internal_allowed_mimes,
  -- Effective quota bytes (admin override wins over plan)
  CASE
    WHEN tsl.internal_quota_gb IS NOT NULL
      THEN (tsl.internal_quota_gb * 1024 * 1024 * 1024)::bigint
    ELSE COALESCE(p.max_storage_mb::bigint * 1024 * 1024, 0)
  END                                                                   AS effective_quota_bytes,
  -- Storage usage
  COALESCE(su.committed_bytes, 0) + COALESCE(su.reserved_bytes, 0)     AS storage_used_bytes,
  COALESCE(su.file_count, 0)                                            AS file_count,
  -- Monthly egress (current calendar month)
  COALESCE((
    SELECT SUM(el.size_bytes)
      FROM data.storage_egress_logs el
     WHERE el.tenant_id = t.id
       AND el.created_at >= date_trunc('month', now())
  ), 0)                                                                 AS monthly_egress_bytes,
  -- Active BYOS drive count
  (
    SELECT COUNT(*)
      FROM data.storage_providers sp
     WHERE sp.tenant_id = t.id
       AND sp.provider_type <> 'supabase'
       AND sp.is_active = true
  )                                                                     AS byos_drive_count
FROM       data.tenants              t
LEFT JOIN  data.plans                p   ON p.id          = t.plan_id
LEFT JOIN  data.storage_usage        su  ON su.tenant_id  = t.id
LEFT JOIN  data.tenant_storage_limits tsl ON tsl.tenant_id = t.id;

GRANT SELECT ON api.tenant_entitlements TO service_role;
GRANT SELECT ON api.tenant_entitlements TO prisma_admin;

-- ---------------------------------------------------------------------------
-- 11. Row-level grants for new tables
-- ---------------------------------------------------------------------------
-- service_role writes egress logs (via api.log_egress SECURITY DEFINER,
-- but also grant direct for future batch jobs)
GRANT SELECT, INSERT ON data.storage_egress_logs       TO service_role;

-- prisma_admin (admin-portal) manages flags, overrides and limits
GRANT SELECT, INSERT, UPDATE, DELETE ON data.feature_flags            TO prisma_admin;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.tenant_feature_overrides TO prisma_admin;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.tenant_storage_limits    TO prisma_admin;
GRANT SELECT                         ON data.feature_flags            TO service_role;
GRANT SELECT                         ON data.tenant_feature_overrides TO service_role;
GRANT SELECT                         ON data.tenant_storage_limits    TO service_role;
GRANT SELECT                         ON data.storage_egress_logs      TO prisma_admin;
