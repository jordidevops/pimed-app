-- =============================================================================
-- Migration: Add is_default flag to data.plans
-- =============================================================================
-- Allows the self-signup Edge Function (public-onboarding) to resolve the
-- correct starter plan without hard-coding a UUID.
-- Only one plan can have is_default = true at any time (enforced by partial
-- unique index below).
-- =============================================================================

ALTER TABLE data.plans
  ADD COLUMN IF NOT EXISTS is_default BOOLEAN NOT NULL DEFAULT false;

-- Ensures at most one row has is_default = true.
CREATE UNIQUE INDEX IF NOT EXISTS plans_one_default_idx
  ON data.plans (is_default)
  WHERE is_default = true;

-- The 'free' plan is the default starter plan for self-signed tenants.
UPDATE data.plans SET is_default = true WHERE name = 'free';
