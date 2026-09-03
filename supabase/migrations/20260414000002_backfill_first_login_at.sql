-- =============================================================================
-- Backfill first_login_at for users who confirmed their email BEFORE we
-- started tracking logins in data.profiles.
--
-- Runs as the migration role (postgres) which has access to auth.users.
-- For each profile where first_login_at IS NULL but email_confirmed_at IS NOT
-- NULL in auth.users, we use email_confirmed_at as a conservative approximation
-- of the first login (invite accepted = first time the user authenticated).
-- =============================================================================

UPDATE data.profiles AS p
SET    first_login_at = u.email_confirmed_at
FROM   auth.users AS u
WHERE  p.id              = u.id
  AND  p.first_login_at  IS NULL
  AND  u.email_confirmed_at IS NOT NULL;
