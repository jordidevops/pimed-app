-- =============================================================================
-- tenant_members view: exposar site_id per resoldre UX i filtratge site-scoped
-- =============================================================================

CREATE OR REPLACE VIEW api.tenant_members
  WITH (security_invoker = true) AS
  SELECT
    tm.id,
    tm.tenant_id,
    tm.user_id,
    tm.role,
    tm.is_active,
    tm.joined_at,
    p.email,
    p.full_name,
    p.avatar_url,
    tm.site_id
  FROM data.tenant_members tm
  JOIN data.profiles p ON p.id = tm.user_id;

GRANT SELECT ON api.tenant_members TO authenticated;
GRANT SELECT ON api.tenant_members TO service_role;
