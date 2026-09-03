# 01 — Supabase Local Setup

Guía oficial basada en las recomendaciones de Supabase para trabajar en local con Supabase CLI y Docker.

---

## Prerrequisitos

| Herramienta | Versión mínima | Enlace |
|-------------|---------------|--------|
| Docker Desktop | Latest | https://www.docker.com/products/docker-desktop/ |
| Node.js | 18+ | https://nodejs.org |
| Supabase CLI | Latest | Ver instalación abajo |

Docker Desktop debe estar **corriendo** antes de ejecutar cualquier comando de Supabase.

---

## 1. Instalar Supabase CLI

### Windows (recomendado: Scoop)
```powershell
# Instalar Scoop si no lo tienes
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
Invoke-RestMethod -Uri https://get.scoop.sh | Invoke-Expression

# Instalar Supabase CLI
scoop bucket add supabase https://github.com/supabase/scoop-bucket.git
scoop install supabase
```

### Windows / macOS / Linux (via npm)
```bash
npm install supabase --save-dev
# Usar siempre como: npx supabase <command>
```

### Verificar instalación
```bash
supabase --version
```

---

## 2. Inicializar el proyecto

Desde la raíz del workspace:

```bash
supabase init
```

Esto crea la carpeta `supabase/` con la estructura:
```
supabase/
├── config.toml      ← Configuración del proyecto local
├── seed.sql         ← Datos iniciales (opcional)
└── .gitignore
```

---

## 3. Copiar la migración inicial

El schema ya está preparado en este repo. Copia el archivo de migración:

```powershell
# Crear carpeta de migraciones si no existe
New-Item -ItemType Directory -Force -Path supabase\migrations

# Copiar el schema inicial
Copy-Item "supabase\migrations\20260324000000_initial_schema.sql" -Destination "supabase\migrations\"
```

> Si ya ejecutaste `supabase init`, la carpeta `supabase/migrations/` ya existe. Solo verifica que el archivo `.sql` esté dentro.

---

## 4. Arrancar el stack local

```bash
supabase start
```

La primera vez descarga las imágenes Docker (~1-2 GB). Al terminar verás:

```
API URL:         http://localhost:54321
GraphQL URL:     http://localhost:54321/graphql/v1
DB URL:          postgresql://postgres:postgres@localhost:54322/postgres
Studio URL:      http://localhost:54323
Inbucket URL:    http://localhost:54324
JWT secret:      super-secret-jwt-token-with-at-least-32-characters-long
anon key:        eyJ...  ← COPIA ESTE VALOR (publishable key) para .env.development
service_role key: eyJ... ← Solo para backend / server-side
```

> **Guarda el `publishable key` (antes llamado `anon key`)** — lo necesitarás en los `.env.development` de los frontends.

---

## 5. Aplicar el schema (migraciones)

```bash
# Aplica todas las migraciones desde cero (reset + migrations)
supabase db reset
```

Esto ejecuta los archivos en `supabase/migrations/` en orden cronológico.

### Verificar en Supabase Studio
Abre http://localhost:54323 → Table Editor → deberías ver todas las tablas.

---

## 6. Comandos esenciales del día a día

```bash
# Ver estado del stack local
supabase status

# Parar el stack
supabase stop

# Parar y borrar datos (reset completo)
supabase stop --no-backup

# Crear nueva migración
supabase migration new nombre_de_la_migracion

# Resetear la DB (aplica todas las migraciones)
supabase db reset

# Ver logs
supabase logs

# Abrir Studio en el navegador
supabase studio
```

---

## 7. Configurar Google OAuth (local)

### 7.1 Crear credenciales en Google Cloud Console

1. Ve a https://console.cloud.google.com
2. Crea o selecciona un proyecto
3. **APIs & Services → Credentials → Create Credentials → OAuth 2.0 Client ID**
4. Application type: **Web application**
5. Authorized redirect URIs:
   ```
   http://localhost:54321/auth/v1/callback
   ```
6. Copia el **Client ID** y **Client Secret**

### 7.2 Editar `supabase/config.toml`

Añade o descomenta esta sección:

```toml
[auth]
site_url = "http://localhost:3000"
additional_redirect_urls = [
  "http://localhost:5173",
  "http://localhost:5173/auth/callback",
  "http://localhost:3000",
  "http://localhost:3000/auth/callback"
]

[auth.external.google]
enabled = true
client_id = "env(GOOGLE_CLIENT_ID)"
secret = "env(GOOGLE_CLIENT_SECRET)"
```

### 7.3 Crear archivo `.env` en la carpeta `supabase/`

```bash
# supabase/.env  (NO subas esto a git)
GOOGLE_CLIENT_ID=tu-client-id.apps.googleusercontent.com
GOOGLE_CLIENT_SECRET=tu-client-secret
```

### 7.4 Reiniciar el stack

```bash
supabase stop
supabase start
```

---

## 8. Generar tipos TypeScript (opcional pero recomendado)

```bash
supabase gen types typescript --local > apps/tenant-portal/src/types/database.types.ts
supabase gen types typescript --local > apps/admin-portal/types/database.types.ts
```

---

## 9. Conectar a la DB remota (producción)

```bash
# Autenticarse en Supabase
supabase login

# Vincular al proyecto remoto
supabase link --project-ref <tu-project-ref>

# Subir migraciones al proyecto vinculado
supabase db push --linked
```

> **Nota**: el flag `--project-ref` fue eliminado de `supabase db push` en versiones recientes del CLI. Ahora es necesario vincular el proyecto con `supabase link` y luego usar `--linked`.

### Alternativa recomendada: script `db-push.ps1`

El repo incluye `scripts/db-push.ps1` que lee los project-refs desde `.supabase-refs`, vincula el proyecto automáticamente con `supabase link` y ejecuta `supabase db push --linked`. Evita tener que escribir el ref a mano cada vez.

**1. Crear el archivo de refs** (solo la primera vez, no se sube a git):

```powershell
# Copia el ejemplo y rellena los valores
Copy-Item scripts\.supabase-refs.example .supabase-refs
```

```ini
# .supabase-refs
STAGING_REF=tu-staging-project-ref
PROD_REF=tu-prod-project-ref
```

**2. Ejecutar el script:**

```powershell
# Aplicar migraciones a staging
.\scripts\db-push.ps1 staging

# Aplicar migraciones a producción
.\scripts\db-push.ps1 prod
```

> Asegúrate de haber ejecutado `supabase login` previamente.


Si el proyecto está linkado el siguiente comando aplicaría las migraciones pendientes en el cloud:

```powershell
supabase db push --linked
```

Si quieres ver exactamente qué aplicaría sin ejecutarlo:

```powershell
supabase db push --linked --dry-run
```

No es posible un reset con el CLI en el proyecto del cloud como se puede hacer en el local por motivos de seguridad.  Si se puede desde el Dashboard de Supabase (Settings → Database → Reset database y después supabase db push --linked).

---

## URLs de los servicios locales

| Servicio | URL |
|----------|-----|
| API REST / Auth | http://localhost:54321 |
| GraphQL | http://localhost:54321/graphql/v1 |
| Supabase Studio | http://localhost:54323 |
| Inbucket (emails test) | http://localhost:54324 |
| PostgreSQL directo | postgresql://postgres:postgres@localhost:54322/postgres |
