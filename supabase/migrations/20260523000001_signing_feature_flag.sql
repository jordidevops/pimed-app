-- =============================================================================
-- Migració: Feature flag per rollout progressiu de Signing
-- Número:   20260523000001
-- Objectiu: habilitar activació gradual del mòdul signing per tenant
-- =============================================================================

INSERT INTO data.feature_flags (
  key,
  description,
  is_enabled,
  rollout_percentage
)
VALUES (
  'tenant_signing_enabled',
  'Activa els fluxos de signing (generate/sign/monitoring) per tenant amb rollout progressiu.',
  false,
  0
)
ON CONFLICT (key) DO NOTHING;
