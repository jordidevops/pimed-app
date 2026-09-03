-- Dev seed tokens for EP0/EP2 spike (known secrets from constants.ts)
-- Secrets: ep0-dev-acme-montserrat, ep0-dev-beta-alice
--
-- NOTE: `supabase db reset` runs migrations BEFORE seed.sql, so tenants/employees
-- do not exist yet here. Primary seed lives in supabase/seed.sql.
-- This migration only inserts when upgrading an existing DB that already has seed data.

INSERT INTO data.employee_portal_tokens (
  id,
  tenant_id,
  employee_id,
  token_hash,
  label,
  is_active
)
SELECT
  v.id,
  v.tenant_id,
  v.employee_id,
  v.token_hash,
  v.label,
  v.is_active
FROM (
  VALUES
    (
      '50000000-0000-0000-0000-000000000001'::uuid,
      '10000000-0000-0000-0000-000000000001'::uuid,
      '40000000-0000-0000-0000-000000000005'::uuid,
      digest('ep0-dev-acme-montserrat', 'sha256'),
      'Spike dev Acme',
      true
    ),
    (
      '50000000-0000-0000-0000-000000000002'::uuid,
      '10000000-0000-0000-0000-000000000002'::uuid,
      '40000000-0000-0000-0000-000000000004'::uuid,
      digest('ep0-dev-beta-alice', 'sha256'),
      'Spike dev Beta',
      true
    )
) AS v(id, tenant_id, employee_id, token_hash, label, is_active)
WHERE EXISTS (
  SELECT 1
  FROM data.tenants t
  JOIN data.employees e ON e.id = v.employee_id AND e.tenant_id = v.tenant_id
  WHERE t.id = v.tenant_id
)
ON CONFLICT (id) DO NOTHING;
