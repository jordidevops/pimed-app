-- =============================================================================
-- Migració 15: Vista data.billing_summary
-- =============================================================================
-- Vista d'ús intern del Admin Portal per al mòdul de Monetització.
-- Agrega per tenant: pla, ús d'emmagatzematge, membres actius, egress mensual
-- i salut d'ownership.
--
-- Accessible per prisma_admin (BYPASSRLS) i service_role.
-- NO exposada a l'esquema api → usuaris finals no hi poden accedir.
-- =============================================================================

CREATE OR REPLACE VIEW data.billing_summary AS
SELECT
  t.id                           AS tenant_id,
  t.name                         AS tenant_name,
  t.slug,
  t.is_active,
  t.created_at                   AS tenant_created_at,

  -- Pla contractat
  p.id                           AS plan_id,
  p.name                         AS plan_name,
  p.display_name                 AS plan_display_name,
  p.price_monthly,
  p.max_members,
  p.max_storage_mb,

  -- Ús d'emmagatzematge intern (data.storage_usage)
  COALESCE(su.committed_bytes, 0)                                    AS storage_committed_bytes,
  COALESCE(su.reserved_bytes, 0)                                     AS storage_reserved_bytes,
  (COALESCE(su.committed_bytes, 0) + COALESCE(su.reserved_bytes, 0)) AS storage_used_bytes,
  COALESCE(su.file_count, 0)                                         AS file_count,

  -- Membres actius (places ocupades)
  (
    SELECT COUNT(*)::integer
      FROM data.tenant_members tm
     WHERE tm.tenant_id = t.id
       AND tm.is_active  = true
  ) AS active_members,

  -- Salut d'ownership: té almenys un owner actiu
  EXISTS (
    SELECT 1
      FROM data.tenant_members tm
     WHERE tm.tenant_id = t.id
       AND tm.role       = 'owner'
       AND tm.is_active  = true
  ) AS has_active_owner,

  -- Egress del mes natural en curs
  COALESCE(
    (
      SELECT SUM(el.size_bytes)
        FROM data.storage_egress_logs el
       WHERE el.tenant_id  = t.id
         AND el.created_at >= date_trunc('month', now())
    ),
    0
  ) AS egress_bytes_current_month

FROM data.tenants t
LEFT JOIN data.plans         p  ON p.id          = t.plan_id
LEFT JOIN data.storage_usage su ON su.tenant_id  = t.id;

-- L'admin portal usa prisma_admin (BYPASSRLS); service_role per a Edge Functions
GRANT SELECT ON data.billing_summary TO prisma_admin, service_role;
