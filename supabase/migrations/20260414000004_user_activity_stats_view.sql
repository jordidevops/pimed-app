-- =============================================================================
-- Migration: data.user_activity_stats view
-- =============================================================================
-- Per-user activity snapshot used by the admin analytics dashboard.
-- Joins data.profiles with their primary tenant (owner role first, then oldest
-- active membership) and billing_summary for plan info.
-- Pre-computes boolean activity flags so the dashboard queries are simple
-- aggregations on top of this view.
--
-- "At-risk" definition: user accepted the invite (first_login_at IS NOT NULL)
-- but hasn't logged in for more than 14 days. Pending users (first_login_at
-- IS NULL) are excluded — they haven't accepted the invite yet.
--
-- Accessible by prisma_admin (BYPASSRLS) and service_role.
-- NOT exposed on the api schema — no end-user access.
-- =============================================================================

CREATE OR REPLACE VIEW data.user_activity_stats AS
SELECT
  p.id                    AS user_id,
  p.email,
  p.full_name,
  p.first_login_at,
  p.last_login_at,
  p.created_at            AS registered_at,

  -- Primary tenant: owner role first, otherwise oldest active membership.
  -- Users with no active membership have NULLs for all tenant columns.
  t.id                    AS tenant_id,
  t.name                  AS tenant_name,
  tm_lateral.role,
  bs.plan_display_name    AS plan_name,

  -- Activity flags (all NULL-safe: NULL comparisons evaluate to false)
  (p.first_login_at IS NOT NULL)                                         AS has_logged_in,
  (p.last_login_at >= CURRENT_DATE)                                      AS active_today,
  (p.last_login_at >= date_trunc('week',  CURRENT_DATE::timestamptz))    AS active_this_week,
  (p.last_login_at >= date_trunc('month', CURRENT_DATE::timestamptz))    AS active_this_month,

  -- At-risk: accepted invite, but inactive for >14 days
  (
    p.first_login_at IS NOT NULL
    AND (
      p.last_login_at IS NULL
      OR p.last_login_at < NOW() - INTERVAL '14 days'
    )
  )                                                                       AS is_at_risk

FROM data.profiles p

-- Resolve the user's primary tenant with a lateral join
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

-- Allow admin portal and edge functions to read
GRANT SELECT ON data.user_activity_stats TO prisma_admin, service_role;
