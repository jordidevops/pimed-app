-- =============================================================================
-- Migració 1: Schemas, extensions i rol de Prisma
-- =============================================================================
-- Arquitectura de schemas (Patró A):
--   data   → taules reals (privat, no exposat via PostgREST)
--   api    → vistes controlades (exposat via PostgREST al tenant-portal)
--   public → només extensions
-- =============================================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Schemas
CREATE SCHEMA IF NOT EXISTS data;
CREATE SCHEMA IF NOT EXISTS api;

-- =============================================================================
-- Rol prisma_admin
-- Connecta directament a PostgreSQL (bypass RLS) per al backoffice (admin-portal).
-- ATENCIÓ: la password 'prisma_local_dev' s'aplica igual al cloud via db push.
-- Canvia-la al cloud amb: ALTER ROLE prisma_admin WITH PASSWORD 'nova-password';
-- (vegeu supabase/snippets/Prisma rol.sql)
-- =============================================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'prisma_admin') THEN
    CREATE ROLE prisma_admin WITH LOGIN PASSWORD 'prisma_local_dev' BYPASSRLS;
  END IF;
END
$$;

-- Accés als schemas
GRANT USAGE ON SCHEMA data TO prisma_admin;
GRANT USAGE ON SCHEMA auth TO prisma_admin;

-- CRUD sobre totes les taules de data (actuals i futures)
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA data TO prisma_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA data
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO prisma_admin;

-- Seqüències
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA data TO prisma_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA data
  GRANT USAGE, SELECT ON SEQUENCES TO prisma_admin;

-- Lectura d'usuaris d'autenticació
GRANT SELECT ON auth.users TO prisma_admin;

-- =============================================================================
-- Permisos d'accés a l'API pública (PostgREST)
-- anon: usuaris no autenticats (login page, públic)
-- authenticated: usuaris amb JWT vàlid
-- =============================================================================
GRANT USAGE ON SCHEMA api TO anon, authenticated, service_role;

-- Revocar accés directe a data i public via PostgREST
REVOKE ALL ON SCHEMA data FROM anon, authenticated;
REVOKE ALL ON SCHEMA public FROM anon, authenticated;
