# 05 — Estrategia de Entornos (dev / staging / prod)

---

## Resumen

| Entorno | Backend | proyecto cloud | Frontend URLs |
|---------|---------|----------------|---------------|
| **dev** | Supabase local (Docker) | ✗ ninguno | localhost:5173 / :3000 |
| **staging** | Supabase cloud | ✓ proyecto staging | staging.tenant.example.app / staging.admin.example.app |
| **prod** | Supabase cloud | ✓ proyecto prod | tenant.example.app / admin.example.app |

---

## Archivos de entorno por fronted

### Carga de variables (prioridad de mayor a menor)

```
.env.local              ← secreto personal, nunca en git (máxima prioridad)
.env.<mode>             ← .env.development / .env.staging / .env.production
.env                    ← base compartida (poco recomendado para SaaS)
```

### Archivos en el repo

| Archivo | En git | Quién lo usa |
|---------|--------|-------------|
| `.env.example` | ✓ | Plantilla de referencia |
| `.env.development` | ✓ | `npm run dev` (solo localhost URLs) |
| `.env.staging` | ✗ gitignored | `npm run build:staging` |
| `.env.production` | ✗ gitignored | `npm run build` (si auto-hosting) |
| `.env.local` | ✗ gitignored | Override personal en cualquier entorno |

> **Regla de oro:** solo se commiten archivos que contienen URLs de `localhost` o valores no secretos.

---

## tenant-portal (Vite) — cómo cargar cada entorno

Vite carga el archivo `.env.<mode>` según el flag `--mode`:

```bash
# Desarrollo local → carga .env.development
npm run dev

# Build para staging → carga .env.staging
npm run build:staging

# Build para producción → carga .env.production (default vite build)
npm run build
```

### Crear `.env.staging` (solo local, no en git)

```env
# apps/tenant-portal/.env.staging
VITE_SUPABASE_URL=https://<staging-ref>.supabase.co
VITE_SUPABASE_PUBLISHABLE_DEFAULT_KEY=<staging-publishable-key>
```

---

## admin-portal (Next.js) — cómo cargar cada entorno

Next.js carga automáticamente `.env.development` con `next dev` y `.env.production` con `next build`.
Para staging se usa `dotenv-cli` (ya en devDependencies):

```bash
# Desarrollo local → carga .env.development
npm run dev

# Build para staging → carga .env.staging
npm run build:staging

# Build para producción → carga .env.production
npm run build
```

### Crear `.env.staging` (solo local, no en git)

```env
# apps/admin-portal/.env.staging
NEXT_PUBLIC_SUPABASE_URL=https://<staging-ref>.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY=<staging-publishable-key>
```

---

## Backend Supabase — flujo por entorno

### DEV (local)

No requiere proyecto cloud. Todo corre en Docker.

```bash
# Arrancar
supabase start

# Aplicar schema desde cero
supabase db reset

# Ver keys locales
supabase status
```

### STAGING — primera vez

```bash
# 1. Crear el proyecto en https://supabase.com/dashboard
#    Guarda el project-ref (visible en la URL del dashboard)

# 2. Guardar los refs en un archivo local NO commiteado
#    Ejemplo: .supabase-refs (incluido en .gitignore)
#    STAGING_REF=abcdefghijklmnop
#    PROD_REF=zyxwvutsrqponmlk

# 3. Aplicar las migraciones al proyecto staging
supabase db push --project-ref <staging-ref>
# Te pedirá la DB password (la que pusiste al crear el proyecto)
```

### PROD — primera vez

```bash
supabase db push --project-ref <prod-ref>
```

### Aplicar nuevas migraciones (día a día)

```bash
# 1. Crear nueva migración
supabase migration new nombre_del_cambio
# Edita el archivo generado en supabase/migrations/

# 2. Probar en local
supabase db reset

# 3. Subir a staging
.\scripts\db-push.ps1 staging

# 4. Si el QA pasa, subir a prod
.\scripts\db-push.ps1 prod
```

> ⚠️ `supabase db push --project-ref` es aditivo (aplica solo las migraciones pendientes).
> Nunca ejecutes `supabase db reset` contra staging o prod.

---

## Configurar Google OAuth en staging/prod

Para staging y prod la configuración **no** va en `config.toml` (eso es solo local).
Se configura en el **Supabase Dashboard** de cada proyecto:

1. Dashboard → **Authentication → Providers → Google**
2. Activar Google, introducir Client ID y Client Secret
3. En Google Cloud Console, añadir el redirect URI del proyecto:
   ```
   https://<project-ref>.supabase.co/auth/v1/callback
   ```
4. En Dashboard → **Authentication → URL Configuration**:
   - Site URL: `https://staging.tenant.example.app` (o el dominio real)
   - Redirect URLs: añadir todos los dominios del frontend

---

## Guardar los project-refs de forma segura

Copia `.supabase-refs.example` a `.supabase-refs` (gitignored) y rellena los valores:

```bash
# .supabase-refs  ← NO en git
STAGING_REF=tu-staging-project-ref
PROD_REF=tu-prod-project-ref
```

El script `scripts/db-push.ps1` lee ese archivo automáticamente:

```powershell
# Aplicar migraciones a staging
.\scripts\db-push.ps1 staging

# Aplicar migraciones a prod
.\scripts\db-push.ps1 prod
```

El script valida que `.supabase-refs` exista y que el ref no esté vacío antes de ejecutar nada.

---

## Resumen visual del flujo

```
Desarrollador
    │
    ├─ npm run dev           → Supabase local (:54321)
    │                           .env.development
    │
    ├─ npm run build:staging → Build con .env.staging
    │   + supabase db push   → Supabase cloud staging
    │     --project-ref staging-ref
    │
    └─ npm run build         → Build con .env.production
        + supabase db push   → Supabase cloud prod
          --project-ref prod-ref
```
