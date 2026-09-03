-- =============================================================================
-- Seed Google geocoding provider (inactive until proxy supports it — S3)
-- =============================================================================

INSERT INTO data.geocoding_providers (
  provider_key,
  name,
  is_active,
  default_included_total_requests_month,
  default_rate_limit_per_minute,
  default_rate_limit_per_day,
  default_enforce_hard_cap,
  default_allow_overage,
  default_billable,
  default_overage_price_per_1000,
  default_currency,
  metadata
)
VALUES (
  'google',
  'Google Geocoding API',
  false,
  0,
  60,
  2000,
  true,
  false,
  true,
  5.0,
  'EUR',
  jsonb_build_object('kind', 'geocoding', 'requires_byo', true)
)
ON CONFLICT (provider_key) DO UPDATE SET
  name = EXCLUDED.name,
  default_included_total_requests_month = EXCLUDED.default_included_total_requests_month,
  default_rate_limit_per_minute = EXCLUDED.default_rate_limit_per_minute,
  default_rate_limit_per_day = EXCLUDED.default_rate_limit_per_day,
  default_enforce_hard_cap = EXCLUDED.default_enforce_hard_cap,
  default_allow_overage = EXCLUDED.default_allow_overage,
  default_billable = EXCLUDED.default_billable,
  default_overage_price_per_1000 = EXCLUDED.default_overage_price_per_1000,
  default_currency = EXCLUDED.default_currency,
  metadata = EXCLUDED.metadata,
  -- keep existing is_active if already true (idempotent re-runs after activate migration)
  is_active = data.geocoding_providers.is_active OR EXCLUDED.is_active;
