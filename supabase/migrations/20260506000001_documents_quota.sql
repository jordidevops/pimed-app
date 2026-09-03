-- =============================================================================
-- Migration 20260506000001: Documents Storage Quota (Phase 0, Option B)
-- =============================================================================
-- Extends data.storage_usage with Documents-specific columns (additive, 1:1 row
-- stays intact) so that Documents uploads count against the tenant quota.
--
-- Changes:
--   1. ADD COLUMN documents_committed_bytes / documents_reserved_bytes /
--      documents_file_count to data.storage_usage
--   2. Backfill from existing data.document_versions (native only)
--   3. Trigger data.update_document_versions_storage_usage() on document_versions
--   4. Recreate api.storage_usage view (adds new columns + grand_total_bytes)
--   5. Recreate api.check_upload_eligibility() to sum Drive + Documents
--   6. Recreate api.tenant_entitlements with drive_used_bytes / documents_used_bytes
--   7. Recreate data.billing_summary with Documents columns
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Extend data.storage_usage
-- ---------------------------------------------------------------------------
ALTER TABLE data.storage_usage
  ADD COLUMN IF NOT EXISTS documents_committed_bytes bigint  NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS documents_reserved_bytes  bigint  NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS documents_file_count      integer NOT NULL DEFAULT 0;

COMMENT ON COLUMN data.storage_usage.documents_committed_bytes
  IS 'Sum of size_bytes for committed native document_versions (DMS module)';
COMMENT ON COLUMN data.storage_usage.documents_reserved_bytes
  IS 'Reserved bytes for in-flight document uploads (future two-phase support)';
COMMENT ON COLUMN data.storage_usage.documents_file_count
  IS 'Count of native document_versions (DMS module)';

-- ---------------------------------------------------------------------------
-- 2. Backfill existing document_versions → storage_usage
-- ---------------------------------------------------------------------------
-- Only storage_type = 'native' counts against quota. external_link is free.
UPDATE data.storage_usage su
SET
  documents_committed_bytes = COALESCE(sq.total_bytes, 0),
  documents_file_count      = COALESCE(sq.cnt, 0)
FROM (
  SELECT
    d.tenant_id,
    SUM(COALESCE(dv.size_bytes, 0)) AS total_bytes,
    COUNT(*)::integer                AS cnt
  FROM data.document_versions dv
  JOIN data.documents d ON d.id = dv.document_id
  WHERE dv.storage_type = 'native'
  GROUP BY d.tenant_id
) sq
WHERE su.tenant_id = sq.tenant_id;

-- ---------------------------------------------------------------------------
-- 3. Trigger function on data.document_versions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.update_document_versions_storage_usage()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id uuid;
BEGIN
  -- Resolve tenant_id from the parent document
  SELECT d.tenant_id INTO v_tenant_id
  FROM data.documents d
  WHERE d.id = COALESCE(NEW.document_id, OLD.document_id);

  IF v_tenant_id IS NULL THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  IF TG_OP = 'INSERT' AND NEW.storage_type = 'native' THEN
    INSERT INTO data.storage_usage (tenant_id, documents_committed_bytes, documents_file_count)
    VALUES (v_tenant_id, COALESCE(NEW.size_bytes, 0), 1)
    ON CONFLICT (tenant_id) DO UPDATE
      SET documents_committed_bytes = data.storage_usage.documents_committed_bytes
                                    + COALESCE(NEW.size_bytes, 0),
          documents_file_count      = data.storage_usage.documents_file_count + 1,
          updated_at                = now();

  ELSIF TG_OP = 'UPDATE' AND NEW.storage_type = 'native' AND OLD.storage_type = 'native' THEN
    IF OLD.size_bytes IS DISTINCT FROM NEW.size_bytes THEN
      UPDATE data.storage_usage
      SET documents_committed_bytes = GREATEST(
              documents_committed_bytes
              + COALESCE(NEW.size_bytes, 0)
              - COALESCE(OLD.size_bytes, 0),
              0),
          updated_at = now()
      WHERE tenant_id = v_tenant_id;
    END IF;

  ELSIF TG_OP = 'DELETE' AND OLD.storage_type = 'native' THEN
    UPDATE data.storage_usage
    SET documents_committed_bytes = GREATEST(
            documents_committed_bytes - COALESCE(OLD.size_bytes, 0),
            0),
        documents_file_count = GREATEST(documents_file_count - 1, 0),
        updated_at           = now()
    WHERE tenant_id = v_tenant_id;
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_document_versions_storage_usage
  AFTER INSERT OR UPDATE OR DELETE ON data.document_versions
  FOR EACH ROW EXECUTE FUNCTION data.update_document_versions_storage_usage();

-- ---------------------------------------------------------------------------
-- 4. Recreate api.storage_usage view (adds documents columns + grand_total)
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api.storage_usage CASCADE;
CREATE VIEW api.storage_usage
  WITH (security_invoker = true) AS
  SELECT
    tenant_id,
    -- Drive (file_nodes)
    file_count,
    committed_bytes,
    reserved_bytes,
    committed_bytes + reserved_bytes                                     AS total_bytes,
    round((committed_bytes + reserved_bytes)::numeric / 1048576, 2)     AS total_mb,
    -- Documents (DMS)
    documents_committed_bytes,
    documents_reserved_bytes,
    documents_file_count,
    -- Grand total: Drive + Documents
    (committed_bytes + reserved_bytes
     + documents_committed_bytes + documents_reserved_bytes)             AS grand_total_bytes,
    updated_at
  FROM data.storage_usage;

GRANT SELECT ON api.storage_usage TO authenticated;
GRANT SELECT ON api.storage_usage TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Recreate api.check_upload_eligibility (Drive + Documents in quota check)
-- ---------------------------------------------------------------------------
-- Replaces the version from 20260413000012_control_plane.sql.
-- Now sums committed_bytes + reserved_bytes + documents_committed_bytes
-- + documents_reserved_bytes for the quota comparison.
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
      WHEN tsl.internal_quota_gb IS NOT NULL THEN
        (  COALESCE(su.committed_bytes, 0)           + COALESCE(su.reserved_bytes, 0)
         + COALESCE(su.documents_committed_bytes, 0) + COALESCE(su.documents_reserved_bytes, 0)
         + p_size_bytes
        ) > (tsl.internal_quota_gb * 1024 * 1024 * 1024)::bigint
      WHEN p.max_storage_mb IS NULL THEN false
      ELSE
        (  COALESCE(su.committed_bytes, 0)           + COALESCE(su.reserved_bytes, 0)
         + COALESCE(su.documents_committed_bytes, 0) + COALESCE(su.documents_reserved_bytes, 0)
         + p_size_bytes
        ) > (p.max_storage_mb::bigint * 1024 * 1024)
    END AS quota_exceeded,
    -- current usage across both modules
    COALESCE(su.committed_bytes, 0)           + COALESCE(su.reserved_bytes, 0)
    + COALESCE(su.documents_committed_bytes, 0) + COALESCE(su.documents_reserved_bytes, 0)
      AS current_bytes,
    CASE
      WHEN tsl.internal_quota_gb IS NOT NULL
        THEN (tsl.internal_quota_gb * 1024 * 1024 * 1024)::bigint
      ELSE COALESCE(p.max_storage_mb::bigint * 1024 * 1024, 0)
    END AS max_bytes
  FROM data.tenants t
  LEFT JOIN data.plans               p   ON p.id          = t.plan_id
  LEFT JOIN data.storage_usage       su  ON su.tenant_id  = t.id
  LEFT JOIN data.tenant_storage_limits tsl ON tsl.tenant_id = t.id
  WHERE t.id = p_tenant_id;
$$;

REVOKE ALL   ON FUNCTION api.check_upload_eligibility(uuid, bigint) FROM PUBLIC;
REVOKE ALL   ON FUNCTION api.check_upload_eligibility(uuid, bigint) FROM authenticated;
REVOKE ALL   ON FUNCTION api.check_upload_eligibility(uuid, bigint) FROM anon;
GRANT EXECUTE ON FUNCTION api.check_upload_eligibility(uuid, bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- 6. Recreate api.tenant_entitlements (adds drive_used_bytes / documents_used_bytes)
-- ---------------------------------------------------------------------------
-- storage_used_bytes is now the GRAND TOTAL (Drive + Documents).
-- Consumers that need the breakdown use drive_used_bytes / documents_used_bytes.
DROP VIEW IF EXISTS api.tenant_entitlements CASCADE;
CREATE VIEW api.tenant_entitlements AS
SELECT
  t.id                                                                    AS tenant_id,
  t.name                                                                  AS tenant_name,
  t.slug,
  t.is_active,
  t.storage_blocked,
  t.storage_blocked_reason,
  -- Plan
  p.id                                                                    AS plan_id,
  p.name                                                                  AS plan_name,
  p.display_name                                                          AS plan_display_name,
  p.max_members,
  p.max_storage_mb                                                        AS plan_max_storage_mb,
  p.features_jsonb                                                        AS plan_features,
  -- Admin overrides
  tsl.internal_quota_gb,
  tsl.internal_max_file_mb,
  tsl.internal_allowed_mimes,
  -- Effective quota
  CASE
    WHEN tsl.internal_quota_gb IS NOT NULL
      THEN (tsl.internal_quota_gb * 1024 * 1024 * 1024)::bigint
    ELSE COALESCE(p.max_storage_mb::bigint * 1024 * 1024, 0)
  END                                                                     AS effective_quota_bytes,
  -- Drive (file_nodes) usage
  COALESCE(su.committed_bytes, 0) + COALESCE(su.reserved_bytes, 0)       AS drive_used_bytes,
  COALESCE(su.file_count, 0)                                              AS file_count,
  -- Documents (DMS) usage
  COALESCE(su.documents_committed_bytes, 0)
    + COALESCE(su.documents_reserved_bytes, 0)                            AS documents_used_bytes,
  COALESCE(su.documents_file_count, 0)                                    AS documents_file_count,
  -- Grand total (Drive + Documents) — backward-compatible column name
  COALESCE(su.committed_bytes, 0)           + COALESCE(su.reserved_bytes, 0)
  + COALESCE(su.documents_committed_bytes, 0) + COALESCE(su.documents_reserved_bytes, 0)
                                                                          AS storage_used_bytes,
  -- Monthly egress
  COALESCE((
    SELECT SUM(el.size_bytes)
      FROM data.storage_egress_logs el
     WHERE el.tenant_id = t.id
       AND el.created_at >= date_trunc('month', now())
  ), 0)                                                                   AS monthly_egress_bytes,
  -- Active BYOS drive count
  (
    SELECT COUNT(*)
      FROM data.storage_providers sp
     WHERE sp.tenant_id = t.id
       AND sp.provider_type <> 'supabase'
       AND sp.is_active = true
  )                                                                       AS byos_drive_count
FROM       data.tenants               t
LEFT JOIN  data.plans                 p   ON p.id          = t.plan_id
LEFT JOIN  data.storage_usage         su  ON su.tenant_id  = t.id
LEFT JOIN  data.tenant_storage_limits tsl ON tsl.tenant_id = t.id;

GRANT SELECT ON api.tenant_entitlements TO service_role;
GRANT SELECT ON api.tenant_entitlements TO prisma_admin;

-- ---------------------------------------------------------------------------
-- 7. Recreate data.billing_summary (adds documents columns)
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS data.billing_summary CASCADE;
CREATE VIEW data.billing_summary AS
SELECT
  t.id                                                                    AS tenant_id,
  t.name                                                                  AS tenant_name,
  t.slug,
  t.is_active,
  t.created_at                                                            AS tenant_created_at,
  -- Plan
  p.id                                                                    AS plan_id,
  p.name                                                                  AS plan_name,
  p.display_name                                                          AS plan_display_name,
  p.price_monthly,
  p.max_members,
  p.max_storage_mb,
  -- Drive (file_nodes) usage
  COALESCE(su.committed_bytes, 0)                                         AS storage_committed_bytes,
  COALESCE(su.reserved_bytes, 0)                                          AS storage_reserved_bytes,
  COALESCE(su.file_count, 0)                                              AS file_count,
  -- Documents (DMS) usage
  COALESCE(su.documents_committed_bytes, 0)                               AS documents_committed_bytes,
  COALESCE(su.documents_file_count, 0)                                    AS documents_file_count,
  -- Grand total across all modules
  COALESCE(su.committed_bytes, 0)           + COALESCE(su.reserved_bytes, 0)
  + COALESCE(su.documents_committed_bytes, 0) + COALESCE(su.documents_reserved_bytes, 0)
                                                                          AS storage_used_bytes,
  -- Members
  (
    SELECT COUNT(*)::integer
      FROM data.tenant_members tm
     WHERE tm.tenant_id = t.id
       AND tm.is_active  = true
  ) AS active_members,
  EXISTS (
    SELECT 1
      FROM data.tenant_members tm
     WHERE tm.tenant_id = t.id
       AND tm.role       = 'owner'
       AND tm.is_active  = true
  ) AS has_active_owner,
  -- Egress
  COALESCE((
    SELECT SUM(el.size_bytes)
      FROM data.storage_egress_logs el
     WHERE el.tenant_id  = t.id
       AND el.created_at >= date_trunc('month', now())
  ), 0) AS egress_bytes_current_month
FROM data.tenants t
LEFT JOIN data.plans         p  ON p.id         = t.plan_id
LEFT JOIN data.storage_usage su ON su.tenant_id = t.id;

GRANT SELECT ON data.billing_summary TO prisma_admin, service_role;

-- ---------------------------------------------------------------------------
-- 8. Recreate data.user_activity_stats (dropped by billing_summary CASCADE)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW data.user_activity_stats AS
SELECT
  p.id                    AS user_id,
  p.email,
  p.full_name,
  p.first_login_at,
  p.last_login_at,
  p.created_at            AS registered_at,
  t.id                    AS tenant_id,
  t.name                  AS tenant_name,
  tm_lateral.role,
  bs.plan_display_name    AS plan_name,
  (p.first_login_at IS NOT NULL)                                         AS has_logged_in,
  (p.last_login_at >= CURRENT_DATE)                                      AS active_today,
  (p.last_login_at >= date_trunc('week',  CURRENT_DATE::timestamptz))    AS active_this_week,
  (p.last_login_at >= date_trunc('month', CURRENT_DATE::timestamptz))    AS active_this_month,
  (
    p.first_login_at IS NOT NULL
    AND (
      p.last_login_at IS NULL
      OR p.last_login_at < NOW() - INTERVAL '14 days'
    )
  )                                                                       AS is_at_risk
FROM data.profiles p
LEFT JOIN LATERAL (
  SELECT tm2.tenant_id, tm2.role
  FROM   data.tenant_members tm2
  WHERE  tm2.user_id  = p.id
    AND  tm2.is_active = true
  ORDER BY (tm2.role = 'owner') DESC, tm2.joined_at ASC
  LIMIT 1
) tm_lateral ON true
LEFT JOIN data.tenants        t  ON t.id  = tm_lateral.tenant_id
LEFT JOIN data.billing_summary bs ON bs.tenant_id = tm_lateral.tenant_id;

GRANT SELECT ON data.user_activity_stats TO prisma_admin, service_role;
