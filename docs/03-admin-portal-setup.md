# 03 — Admin Portal (Next.js App Router)

Panel de administración para el equipo interno de la startup (superadmins). Desde aquí se gestionan los tenants, se crean cuentas de empresa, se supervisan los contratos y se administra la plataforma.

**Stack:** Next.js 15 · App Router · TypeScript · Tailwind CSS · @supabase/ssr · @supabase/supabase-js · Prisma ORM (introspección)

**Puerto por defecto:** http://localhost:3000

---

## Estructura del proyecto

```
apps/admin-portal/
├── app/
│   ├── layout.tsx                 ← Root layout (fuente, metadata, globals.css)
│   ├── page.tsx                   ← Redirige a /dashboard o /login según sesión
│   ├── globals.css                ← Tailwind directives
│   ├── (auth)/
│   │   └── login/
│   │       └── page.tsx           ← Página de login (Server Component con LoginForm)
│   ├── dashboard/
│   │   └── page.tsx               ← Dashboard protegido (Server Component)
│   └── auth/
│       ├── callback/
│       │   └── route.ts           ← Route Handler: intercambia code por sesión (OAuth)
│       └── signout/
│           └── route.ts           ← Route Handler: cierra sesión
├── components/
│   ├── auth/
│   │   └── LoginForm.tsx          ← Client Component: form email/pass + Google
│   └── dashboard/
│       └── UserCard.tsx           ← Server Component: muestra datos del usuario
├── app/
│   └── admin/
│       └── actions/
│           └── tenants.ts         ← Ejemplo de Server Action con Prisma + guard de rol
├── lib/
│   ├── prisma.ts                  ← Singleton PrismaClient con @prisma/adapter-pg (Prisma v7)
│   └── supabase/
│       ├── client.ts              ← createBrowserClient (Client Components)
│       └── server.ts              ← createServerClient (Server Components)
├── prisma/
│   └── schema.prisma              ← Solo introspección. NO usar prisma migrate.
├── middleware.ts                  ← Refresca sesión, protege rutas y valida rol admin
├── prisma.config.ts               ← Configuración de conexión para el CLI de Prisma v7
├── next.config.ts
├── tailwind.config.ts
├── tsconfig.json
├── package.json
├── .env.development               ← Variables de localhost (commitable, sin credenciales reales)
└── .env.staging / .env.production ← Credenciales reales (gitignored)
```

---

## 1. Instalación

```bash
cd apps/admin-portal
npm install
```

---

## 2. Variables de entorno

El archivo `.env.development` ya está configurado para desarrollo local y **puede commitearse** siempre que solo contenga URLs de localhost.

```env
# .env.development
NEXT_PUBLIC_SUPABASE_URL=http://localhost:54321
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY=<publishable key de `supabase status`>

# Prisma — conexión directa al PostgreSQL local (puerto 54322)
DATABASE_URL="postgresql://postgres:postgres@localhost:54322/postgres"
```

> Para staging/prod, copia `.env.example` a `.env.staging` o `.env.production` (ambos gitignored) y rellena con las URLs reales de Supabase Cloud.

> **NUNCA** añadir credenciales reales (passwords, tokens) a `.env.development`.

---

## 3. Arrancar en modo desarrollo

```bash
npm run dev
```

Abre http://localhost:3000 → redirige automáticamente a `/login` o `/dashboard`.

---

## 4. Arquitectura de autenticación (SSR)

Next.js App Router requiere un enfoque diferente al SPA para la autenticación con Supabase:

### Capas de autenticación

```
Request
  │
  ▼
middleware.ts          ← Refresca el token JWT en cada request
  │                       Redirige a /login si no hay sesión
  ▼
Server Component       ← Usa createSupabaseServerClient() (cookies de Next.js)
  │                       NO usar getSession() → usar getUser() (verificación segura)
  ▼
Client Component       ← Usa createSupabaseClient() (browser client)
                          Para interacciones del usuario (form submit, signOut)
```

### Clientes Supabase

| Archivo | Usar en | Función |
|---------|---------|---------|
| `lib/supabase/server.ts` | Server Components, Route Handlers | Lee cookies del servidor |
| `lib/supabase/client.ts` | Client Components (`'use client'`) | Browser cookies |

### Por qué usar `getUser()` en lugar de `getSession()`

`getSession()` retorna la sesión desde las cookies sin validarla con el servidor. `getUser()` hace una llamada al servidor de Supabase para verificar el JWT, lo que es más seguro para rutas protegidas.

---

## 5. Flujo de autenticación

### Email / Contraseña
1. `LoginForm` (Client Component) llama a `supabase.auth.signInWithPassword()`
2. Supabase establece cookies de sesión
3. `router.push('/dashboard')` + `router.refresh()` para actualizar los Server Components

### Google OAuth
1. `LoginForm` llama a `supabase.auth.signInWithOAuth({ redirectTo: '/auth/callback' })`
2. Redireccionamiento a Google → usuario da permisos → Google redirige a `/auth/callback?code=...`
3. Route Handler en `app/auth/callback/route.ts` intercambia el código por sesión con `exchangeCodeForSession()`
4. Redirige a `/dashboard`

### Cierre de sesión
- El botón de logout hace POST a `/auth/signout`
- Route Handler llama a `supabase.auth.signOut()` y redirige a `/login`

---

## 6. Middleware de protección

El middleware en `middleware.ts` se ejecuta en **cada request** (excepto archivos estáticos):

- Si no hay sesión → redirige a `/login`
- Si hay sesión pero el usuario **no tiene** `app_metadata.role === 'admin'` → redirige a `/login?error=unauthorized`
- Si hay sesión válida de admin y el usuario va a `/login` → redirige a `/dashboard`
- **Siempre** refresca el token de sesión en las cookies de la respuesta

> `app_metadata` es gestionado exclusivamente por el servidor (Supabase Admin API). El usuario no puede modificarlo, lo que lo hace adecuado para controles de acceso de alto nivel.

---

## 7. Scripts disponibles

```bash
# Desarrollo
npm run dev              # Servidor de desarrollo (puerto 3000)
npm run build            # Build de producción
npm run build:staging    # Build con variables de .env.staging
npm run start            # Inicia el servidor de producción
npm run lint             # ESLint con configuración de Next.js

# Prisma
npm run prisma:pull      # Introspecta la BD y actualiza prisma/schema.prisma
npm run prisma:generate  # Regenera @prisma/client desde schema.prisma
```

> `postinstall` ejecuta `prisma generate` automáticamente después de cada `npm install`.

---

## 8. Crear usuario admin de prueba

```bash
# Desde Supabase Studio (local): http://localhost:54323
# Authentication → Users → Add user

# Desde SQL Editor, asignar rol 'admin' en app_metadata:
UPDATE auth.users
SET raw_app_meta_data = raw_app_meta_data || '{"role": "admin"}'::jsonb
WHERE email = 'admin@example.com';
```

> El middleware valida `app_metadata.role === 'admin'`. Cualquier otro valor (incluido `superadmin`) denegará el acceso.

---

## 9. Prisma ORM — Workflow con Supabase CLI

Prisma actúa como **capa de acceso a datos** para el backoffice, ejecutándose exclusivamente en el servidor (Server Actions, Route Handlers) y **bypasando el RLS** al conectarse directamente a la base de datos.

### Responsabilidades

| Herramienta | Responsabilidad |
|---|---|
| **Supabase CLI** | Source of truth del esquema. Crea y aplica migraciones (`/supabase/migrations/`). |
| **Prisma** | Introspección del esquema existente y generación de tipos TypeScript. |

### Archivos clave

| Archivo | Propósito |
|---|---|
| `prisma.config.ts` | Configura la URL de conexión para el CLI (Prisma v7). Carga `.env` via `dotenv`. |
| `prisma/schema.prisma` | Generado por `db pull`. Solo contiene `provider`. No editar manualmente. |
| `lib/prisma.ts` | Singleton `PrismaClient` con `@prisma/adapter-pg` (driver adapter requerido en Prisma v7). |

### Comandos del día a día

```bash
# 1. Después de cambiar el esquema con Supabase CLI:
npm run prisma:pull      # Introspecta la BD y actualiza prisma/schema.prisma
npm run prisma:generate  # Regenera el cliente TypeScript (@prisma/client)

# Nunca ejecutar:
# npx prisma migrate dev
# npx prisma migrate deploy
```

### Prisma v7 — cambios importantes respecto a v6

- La URL de conexión ya **no** va en `schema.prisma` (ni `url` ni `directUrl`). Va en `prisma.config.ts`.
- El cliente requiere un **driver adapter** (`@prisma/adapter-pg`). Se instancia en `lib/prisma.ts`.
- `directUrl` ha sido **eliminado** en v7. Se usa una sola URL de conexión directa (puerto 5432 en Supabase Cloud, `54322` en local).

### Seguridad: Prisma bypassa el RLS

Prisma se conecta con la contraseña directa de PostgreSQL, saltando las políticas Row-Level Security. Por ello, **todas las Server Actions que usen Prisma deben incluir el guard `assertAdmin()`** al inicio, que valida el JWT de Supabase y comprueba `app_metadata.role === 'admin'`.

Ver ejemplo completo en [app/admin/actions/tenants.ts](../apps/admin-portal/app/admin/actions/tenants.ts).

---

## 10. Consideraciones de seguridad

- Las variables `NEXT_PUBLIC_*` son visibles en el cliente — solo usar la `publishable key`, nunca `service_role key`
- El middleware usa `getUser()` (verificación con servidor) para validar sesiones, nunca `getSession()`
- Prisma bypassa el RLS al conectarse directamente a PostgreSQL — **toda Server Action con Prisma debe empezar con `assertAdmin()`**
- `DATABASE_URL` es un secreto de servidor — nunca exponerla en variables `NEXT_PUBLIC_*`
- `app_metadata` solo puede modificarse desde el servidor (Supabase Admin API) — es seguro usarlo como control de acceso
