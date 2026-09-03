


SQL para crear un rol para Prisma en el backoffice. Hay que cambiar public por data o el nombre del esquema correcto si se ha hecho hardening con un custom schema. No es el esquema api porque el backoffice conecta directamente sin pasar por las views de la api.

```sql
-- 1. Crea el rol amb password (canvia el password!)
CREATE ROLE prisma_admin WITH LOGIN PASSWORD 'canvia-aquest-password';

-- 2. Accés a l'schema public
GRANT USAGE ON SCHEMA public TO prisma_admin;

-- 3. CRUD sobre totes les taules existents
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO prisma_admin;

-- 4. CRUD automàtic sobre taules futures
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO prisma_admin;

-- 5. Seqüències (per a camps SERIAL si n'hi ha)
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO prisma_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO prisma_admin;

-- 6. Lectura de auth.users (per consultar usuaris des del backoffice)
GRANT USAGE ON SCHEMA auth TO prisma_admin;
GRANT SELECT ON auth.users TO prisma_admin;

-- Verifica que s'ha creat correctament
SELECT rolname, rolcanlogin FROM pg_roles WHERE rolname = 'prisma_admin';
```

L'última línia ha de retornar:

| rolname | rolcanlogin |
|---|---|
| prisma_admin | true |


```sql
-- 1. Crea el rol amb password (canvia el password!)
CREATE ROLE prisma_admin WITH LOGIN PASSWORD 'canvia-aquest-password';

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
```