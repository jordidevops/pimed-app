-- =============================================================================
-- data.system_settings
-- Platform-wide configuration grouped by module.
--
-- Design rationale:
--   • data.feature_flags  → tenant-facing feature toggles with rollout % and
--                           per-tenant overrides. Tenants may experience them
--                           differently.
--   • data.system_settings → global platform infrastructure config that applies
--                            equally to every tenant (auth providers, billing
--                            behaviour, onboarding flags, etc.).
--
-- Adding a new setting to an existing module never requires a migration; just
-- update the JSONB value. Adding a new module is a single INSERT.
-- =============================================================================

CREATE TABLE data.system_settings (
  module      text        PRIMARY KEY,
  settings    jsonb       NOT NULL DEFAULT '{}',
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid        REFERENCES auth.users(id) ON DELETE SET NULL
);

-- Auto-bump updated_at
CREATE OR REPLACE FUNCTION data.touch_system_settings_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_system_settings_updated_at
  BEFORE UPDATE ON data.system_settings
  FOR EACH ROW EXECUTE FUNCTION data.touch_system_settings_updated_at();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
ALTER TABLE data.system_settings ENABLE ROW LEVEL SECURITY;

-- Platform admins (prisma_admin has BYPASSRLS) and service_role have full access
CREATE POLICY "service_role full access on system_settings"
  ON data.system_settings FOR ALL TO service_role
  USING (true) WITH CHECK (true);

-- Authenticated and anonymous users can READ (tenant-portal needs auth settings
-- before the user is logged in, e.g. to show/hide the Google button on the
-- login page)
CREATE POLICY "public read system_settings"
  ON data.system_settings FOR SELECT TO anon, authenticated
  USING (true);

-- Grant table-level permissions (RLS is a second layer; GRANT is required too)
GRANT SELECT ON data.system_settings TO anon, authenticated;
GRANT ALL    ON data.system_settings TO prisma_admin, service_role;

-- ---------------------------------------------------------------------------
-- Seed: initial modules
-- ---------------------------------------------------------------------------
INSERT INTO data.system_settings (module, settings) VALUES
  ('auth', '{
    "google_oauth_enabled":    true,
    "password_login_enabled":  true,
    "magic_link_enabled":      false
  }'::jsonb),
  ('onboarding', '{
    "self_signup_enabled":     false
  }'::jsonb);

-- ---------------------------------------------------------------------------
-- api.get_auth_settings()
-- Safe, anon-accessible function that returns the auth module's settings.
-- Tenant-portal calls this before the user is authenticated so it can decide
-- whether to render the Google button.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_auth_settings()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT COALESCE(
    (SELECT settings FROM data.system_settings WHERE module = 'auth'),
    '{"google_oauth_enabled": true, "password_login_enabled": true, "magic_link_enabled": false}'::jsonb
  )
$$;

GRANT EXECUTE ON FUNCTION api.get_auth_settings() TO anon, authenticated;
