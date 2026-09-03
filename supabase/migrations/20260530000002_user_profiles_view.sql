-- ============================================================
-- api.user_profiles
-- Vista que exposa els perfils dels usuaris membres del tenant actiu.
-- No cal security_invoker=true perquè data.profiles ja té RLS
-- que permet veure els membres dels teus tenants.
-- ============================================================

CREATE OR REPLACE VIEW api.user_profiles WITH (security_invoker = true) AS
  SELECT id, email, full_name, avatar_url
  FROM data.profiles;

GRANT SELECT ON api.user_profiles TO authenticated;

COMMENT ON VIEW api.user_profiles
  IS 'Perfils d''usuaris visibles per l''usuari autenticat (filtra per RLS de data.profiles)';
