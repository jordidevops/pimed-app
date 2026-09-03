# 02 — Tenant Portal (Vite + React)

Portal genèric multitenant. Els usuaris de cada organització (tenant) accedeixen aquí per gestionar les dades del seu compte.

**Stack:** Vite 5 · React 19 · TypeScript · Tailwind CSS · @supabase/supabase-js · React Router v6 · TanStack Query v5 · React Hook Form · Zod

**Port per defecte:** http://localhost:5173

---

## Estructura del projecte

```
apps/tenant-portal/
├── src/
│   ├── lib/
│   │   ├── supabase.ts          ← Client Supabase (schema: 'api', instància única)
│   │   └── react-query.ts       ← QueryClient amb staleTime i polítiques de retry
│   │
│   ├── types/
│   │   └── database.types.ts    ← Tipus generats per `supabase gen types` (NO editar a mà)
│   │
│   ├── hooks/                   ← Hooks de dades reutilitzables (TanStack Query + Supabase)
│   │   ├── useTenants.ts        ← Query: tenants als quals pertany l'usuari (via vista api.my_tenant)
│   │   └── useNotes.ts          ← Query: notes del tenant seleccionat
│   │
│   ├── features/
│   │   └── auth/
│   │       ├── api/
│   │       │   ├── useSignIn.ts       ← Mutation: signInWithPassword
│   │       │   └── useSignOut.ts      ← Mutation: signOut
│   │       ├── schemas/
│   │       │   └── auth.schema.ts     ← Zod: regles de validació del login
│   │       └── components/
│   │           └── LoginForm.tsx      ← Hook Form + zodResolver
│   │
│   ├── contexts/
│   │   └── AuthContext.tsx      ← Provider de sessió (session, user, loading, signOut)
│   │
│   ├── components/
│   │   ├── ProtectedRoute.tsx   ← Redirigeix a /login si no hi ha sessió
│   │   ├── UserAvatarMenu.tsx   ← Avatar dropdown (perfil + tancar sessió)
│   │   └── ui/
│   │       └── Spinner.tsx
│   │
│   └── pages/
│       ├── LoginPage.tsx
│       ├── DashboardPage.tsx    ← Selector de tenant + notes
│       ├── ProfilePage.tsx      ← Informació de l'usuari
│       └── AuthCallbackPage.tsx ← Gestiona el redirect OAuth (PKCE)
├── index.html
├── vite.config.ts
├── tailwind.config.js
├── tsconfig.json
├── package.json
├── .env.development             ← Local (commiteable, només localhost)
└── .env.staging                 ← Staging (gitignored, claus reals)
```

### Responsabilitats per capa

| Capa | Eina | Què fa |
|---|---|---|
| `hooks/` | TanStack Query + Supabase | Consultes de dades via vistes de l'schema `api` |
| `features/auth/` | React Hook Form + Zod | Formulari de login i mutacions d'auth |
| `contexts/` | React Context | Sessió global accessible des de qualsevol component |
| `types/` | TypeScript | Tipat end-to-end sincronitzat amb la BD real |

---

## 1. Instal·lació

```bash
cd apps/tenant-portal
npm install
```

---

## 2. Variables d'entorn

El fitxer `.env.development` ja està configurat per a l'entorn local:

```env
VITE_SUPABASE_URL=http://localhost:54321
VITE_SUPABASE_PUBLISHABLE_DEFAULT_KEY=<publishable key de `supabase status`>
```

Per a staging, edita `.env.staging` (gitignored):

```env
VITE_SUPABASE_URL=https://<staging-ref>.supabase.co
VITE_SUPABASE_PUBLISHABLE_DEFAULT_KEY=<publishable key del dashboard de Supabase>
```

> La publishable key de staging es troba a: **Supabase Dashboard → Settings → API → Project API keys**.

---

## 3. Arrancar en mode desenvolupament

```bash
# Contra Supabase local (Docker)
npm run dev

# Contra Supabase staging (cloud)
npm run dev:staging
```

Obre http://localhost:5173

---

## 4. Flux d'autenticació

### Email / Contrasenya
1. `LoginForm` usa **React Hook Form** amb **zodResolver** per validar abans d'enviar
2. Si el formulari és vàlid, crida el hook `useSignIn()` (mutation de React Query)
3. `useSignIn` crida internament `supabase.auth.signInWithPassword()`
4. Si és correcte, `onAuthStateChange` a `AuthContext` detecta `SIGNED_IN` → React Router redirigeix a `/dashboard`

### Google OAuth (PKCE flow)
1. L'usuari prem "Continuar amb Google"
2. Es crida `supabase.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: '/auth/callback' } })`
3. L'usuari és redirigit a Google → dóna permisos → Google redirigeix a `http://localhost:5173/auth/callback?code=...`
4. `AuthCallbackPage` detecta el codi i Supabase intercanvia per sessió automàticament
5. `onAuthStateChange` dispara `SIGNED_IN` → redirigeix a `/dashboard`

### Rutes protegides
`ProtectedRoute` embolcalla qualsevol ruta que requereixi autenticació. Si no hi ha sessió activa, redirigeix automàticament a `/login`.

---

## 5. Schema `api` i vistes

El client Supabase usa `db: { schema: 'api' }` — totes les crides `.from()` apunten a l'schema `api` (vistes controlades) en lloc de `public`. Les taules reals viuen a l'schema `data` i no s'exposen directament.

Vistes disponibles a `api`:
- `my_tenant` — tenants als quals pertany l'usuari autenticat (amb pla i rol)
- `my_notes` — notes del tenant (filtrades per RLS)

---

## 6. Tipus de base de dades

Els tipus a `src/types/database.types.ts` s'han de regenerar cada vegada que canviï l'esquema de la BD. **No editar aquest fitxer a mà.**

```powershell
# Des de la raíz del monorepo (amb `supabase start` corrent)
supabase gen types typescript --local | Out-File -Encoding utf8 apps/tenant-portal/src/types/database.types.ts
```

> A PowerShell, usar `Out-File -Encoding utf8` en lloc de `>` per evitar que generi UTF-16.

---

## 7. Scripts disponibles

```bash
npm run dev            # Servidor de desenvolupament contra Supabase local
npm run dev:staging    # Servidor de desenvolupament contra Supabase staging
npm run build          # Build de producció (dist/)
npm run build:staging  # Build per a staging
npm run preview        # Preview del build de producció
npm run lint           # ESLint
```

---

## 8. Crear un usuari de prova

### Seed local (recomanat)
El fitxer `supabase/seed.sql` crea automàticament usuaris de prova en fer `supabase db reset`:

| Email | Password | Rol |
|---|---|---|
| `superadmin@example.com` | `Test1234!` | admin (admin-portal) |
| `owner@acme-corp.com` | `Test1234!` | owner (2 tenants) |
| `member@acme-corp.com` | `Test1234!` | member (1 tenant) |
| `owner@beta-startup.com` | `Test1234!` | owner (1 tenant) |

### Des de Supabase Studio (local)
1. Obre http://localhost:54323
2. Ve a **Authentication → Users → Add user**

---

## 9. Consideracions de producció

- Editar `.env.staging` / `.env.production` amb les URLs i claus correctes
- Afegir el domini de producció als redirect URLs al Supabase Dashboard
- Regenerar `src/types/database.types.ts` contra el projecte de producció abans del deploy:
  ```powershell
  supabase gen types typescript --project-id <ref> | Out-File -Encoding utf8 apps/tenant-portal/src/types/database.types.ts
  ```
