-- =============================================================================
-- Login tracking in data.profiles
-- Guardem les dates de primer i últim login a la nostra taula (no confiem en
-- auth.last_sign_in_at que Supabase actualitza al acceptar la invitació).
-- La funció api.record_login() és cridada pel tenant-portal en cada SIGNED_IN.
-- =============================================================================

ALTER TABLE data.profiles
  ADD COLUMN IF NOT EXISTS first_login_at  timestamptz,
  ADD COLUMN IF NOT EXISTS last_login_at   timestamptz;

-- ---------------------------------------------------------------------------
-- api.record_login()
-- Cridat pel tenant-portal (anon/authenticated) via supabase.rpc('record_login').
-- SECURITY DEFINER perquè pugui escriure a data.profiles.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.record_login()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = data, public
AS $$
  UPDATE data.profiles
  SET    last_login_at  = now(),
         first_login_at = COALESCE(first_login_at, now())
  WHERE  id = auth.uid();
$$;

-- Només els usuaris autenticats poden cridar-la (no anon)
REVOKE EXECUTE ON FUNCTION api.record_login() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION api.record_login() TO authenticated;
