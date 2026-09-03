-- Executa aquest snippet al SQL Editor del projecte CLOUD de Supabase.
-- El rol ja existeix (creat per la migració 20260401000001 via db push).
-- Només cal canviar la password (la migració usa 'prisma_local_dev', insegura per al cloud).

-- 1. Canvia la password del rol existent (NO recrear, ja té BYPASSRLS i permisos)
ALTER ROLE prisma_admin WITH PASSWORD 'CANVIA-AQUESTA-PASSWORD';

-- Verifica
SELECT rolname, rolcanlogin, rolbypassrls FROM pg_roles WHERE rolname = 'prisma_admin';

-- =============================================================================
-- Els permisos ja els té de la migració. Si per algun motiu cal reaplicar-los:
-- =============================================================================

-- 2. Accés a l'schema data
GRANT USAGE ON SCHEMA data TO prisma_admin;

-- 3. CRUD sobre totes les taules existents
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA data TO prisma_admin;

-- 4. CRUD automàtic sobre taules futures
ALTER DEFAULT PRIVILEGES IN SCHEMA data
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO prisma_admin;

-- 5. Seqüències (per a camps SERIAL si n'hi ha)
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA data TO prisma_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA data
  GRANT USAGE, SELECT ON SEQUENCES TO prisma_admin;

-- 6. Lectura de auth.users (per consultar usuaris des del backoffice)
GRANT USAGE ON SCHEMA auth TO prisma_admin;
GRANT SELECT ON auth.users TO prisma_admin;

-- Verifica que s'ha creat correctament
SELECT rolname, rolcanlogin FROM pg_roles WHERE rolname = 'prisma_admin';