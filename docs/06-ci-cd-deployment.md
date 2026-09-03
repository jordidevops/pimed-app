# 06 — CI/CD Deployment: Lliçons apreses

Documentació de les dificultats trobades durant la posada en marxa del pipeline CI/CD
amb GitHub Actions + Vercel CLI, per evitar repetir-les en futurs entorns o projectes.

---

## Visió general del pipeline

```
push → staging  →  GitHub Actions  →  vercel build + vercel deploy --prebuilt  →  admin-staging.cavalle.dev
push → main     →  GitHub Actions  →  vercel build + vercel deploy --prebuilt --prod  →  admin.cavalle.dev
```

Cada app (admin-portal, tenant-portal) és un projecte Vercel independent.
El build el fa GitHub Actions; Vercel rep el resultat pre-compilat (`--prebuilt`).
Vercel té configurada l'opció **Ignored Build Step → Custom → `exit 0`** per evitar
que Vercel faci el seu propi build en paral·lel.

---

## Problema 1: `vercel pull` NO descarrega les variables personalitzades

### Símptoma
Quan `vercel build` s'executava, les variables `NEXT_PUBLIC_*` eren buides al bundle.
L'error al navegador era:

```
Uncaught Error: @supabase/ssr: Your project's URL and API key are required
```

### Causa arrel
`vercel pull --environment=preview` descarrega únicament les variables de sistema de Vercel
(`VERCEL_ENV`, `VERCEL_URL`, etc.). Les variables personalitzades definides a
_Vercel → Project Settings → Environment Variables_ **no s'inclouen** al fitxer
`.vercel/.env.preview.local` generat.

Confirmació via `cat .vercel/.env.preview.local` al workflow: només hi havia vars `VERCEL_*`.

### Per què `NEXT_PUBLIC_*` és diferent
Les variables `NEXT_PUBLIC_*` es repliquen dins el bundle de JavaScript en temps de build
(Next.js les inlineja al codi). Si no estan presents quan s'executa `next build`, queden
com a `undefined` per sempre, ni que s'afegeixin després com a variables d'entorn del servidor.

### Solució
Injectar les variables explícitament des de **GitHub Variables** (`vars.*`) al fitxer
`.env.production` **abans** de `vercel build`:

```yaml
- name: Inject public env vars (NEXT_PUBLIC_* must be present at build time)
  run: |
    echo "NEXT_PUBLIC_SUPABASE_URL=${{ vars.NEXT_PUBLIC_SUPABASE_URL_STAGING }}" >> .env.production
    echo "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY=${{ vars.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY_STAGING }}" >> .env.production
  working-directory: apps/admin-portal
```

GitHub Variables necessàries (Settings → Secrets and variables → Actions → Variables):

| Variable GitHub | Valor |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL_STAGING` | `https://<ref>.supabase.co` |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY_STAGING` | `sb-<ref>-...` |
| `NEXT_PUBLIC_SUPABASE_URL_PROD` | `https://<ref-prod>.supabase.co` |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY_PROD` | `sb-<ref-prod>-...` |

> **Nota:** Les variables de servidor com `DATABASE_URL` (usades per Prisma en runtime,
> no al bundle) sí que s'han de configurar a _Vercel → Environment Variables_.
> Vercel les injecta al runtime del servidor sense necessitat d'aquest workaround.

---

## Problema 2: `force-dynamic` al root layout

### Símptoma
El build fallava amb errors de connexió a Prisma/Supabase durant la fase de pre-rendering:

```
Error: Can't reach database server at `...`
```

### Causa arrel
Next.js intenta pre-renderitzar estàticament totes les pàgines durant el build.
Qualsevol pàgina que faci consultes a la BD o llegeixi cookies (sessió) falla,
perquè en temps de build no hi ha BD accessible ni sessió activa.

### Solució
Afegir `export const dynamic = 'force-dynamic'` al **root layout**
(`app/layout.tsx`). Això propagua la directiva a totes les pàgines i rutes fill:

```ts
// app/layout.tsx
export const dynamic = 'force-dynamic'
```

No cal repetir-ho a cada pàgina. No afegir-ho directament a pàgines individuals
si ja el root layout el té.

---

## Problema 3: Bucle infinit de redireccions al middleware

### Símptoma
`ERR_TOO_MANY_REDIRECTS` al navegador. El middleware redirigia `/login` → `/login` → ...

### Causa arrel
S'havia afegit una guarda al middleware per gestionar variables d'entorn absents:

```ts
// MAL: la guarda s'aplica a /login també
if (!process.env.NEXT_PUBLIC_SUPABASE_URL) {
  return NextResponse.redirect('/login')  // redirigeix /login → /login
}
```

El middleware s'executa per **totes** les rutes que coincideixen amb el `matcher`,
incloses les rutes públiques com `/login`.

### Solució
Extreure `pathname` i la comprovació de ruta pública **abans** de la guarda,
i saltar la redirecció si ja estem a una ruta pública:

```ts
export async function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl
  const isPublicPath = PUBLIC_PATHS.some((p) => pathname.startsWith(p))

  if (!process.env.NEXT_PUBLIC_SUPABASE_URL || !process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY) {
    if (isPublicPath) return NextResponse.next()
    const url = request.nextUrl.clone()
    url.pathname = '/login'
    return NextResponse.redirect(url)
  }
  // ... resta del middleware (sense redeclarar pathname ni isPublicPath)
}
```

---

## Problema 4: Els canvis al workflow no disparaven el deploy

### Símptoma
Quan es modificava el fitxer `deploy-staging.yml` i es feia push, els jobs de deploy
quedaven en `skipped` (no feien res).

### Causa arrel
El filtre de paths del job `changes` no incloïa el propi fitxer del workflow:

```yaml
filters: |
  admin:
    - 'apps/admin-portal/**'
    - 'supabase/migrations/**'
  # ← el workflow en si no estava inclòs
```

### Solució
Afegir el fitxer del workflow als filtres de cada app:

```yaml
filters: |
  admin:
    - 'apps/admin-portal/**'
    - 'supabase/migrations/**'
    - '.github/workflows/deploy-staging.yml'
  tenant:
    - 'apps/tenant-portal/**'
    - '.github/workflows/deploy-staging.yml'
```

---

## Problema 5: Domini personalitzat per a previews de staging

### Símptoma
`vercel deploy --prebuilt` generava una URL aleatòria (`https://admin-portal-xyz.vercel.app`)
en lloc d'assignar `admin-staging.cavalle.dev`.

### Causa arrel
Vercel assigna dominis de branca automàticament quan detecta el commit via integració Git.
En deploying manual amb CLI sense integració Git activa, Vercel no sap a quina branca
pertany el deploy i no assigna dominis de branca.

### Solució
Pas explícit de `vercel alias set` après del deploy:

```yaml
- name: Deploy to Vercel
  id: deploy-admin
  run: echo "url=$(vercel deploy --prebuilt --token=${{ secrets.VERCEL_TOKEN }})" >> $GITHUB_OUTPUT

- name: Assign staging domain
  run: vercel alias set ${{ steps.deploy-admin.outputs.url }} ${{ secrets.ADMIN_STAGING_DOMAIN }} --token=${{ secrets.VERCEL_TOKEN }}
```

Secrets necessaris: `ADMIN_STAGING_DOMAIN` = `admin-staging.cavalle.dev`,
`TENANT_STAGING_DOMAIN` = `app-staging.cavalle.dev`.

> **Producció:** Per a producció (`--prod`), Vercel assigna automàticament al domini
> de producció configurat al projecte. No cal `vercel alias set`.

---

## Resum: Secrets i Variables necessaris

### GitHub Secrets (Settings → Secrets → Actions)
| Secret | Descripció |
|---|---|
| `VERCEL_TOKEN` | Token personal de Vercel |
| `VERCEL_ORG_ID` | ID de l'organització/compte Vercel |
| `VERCEL_ADMIN_PROJECT_ID` | ID del projecte admin-portal a Vercel |
| `VERCEL_TENANT_PROJECT_ID` | ID del projecte tenant-portal a Vercel |
| `ADMIN_STAGING_DOMAIN` | `admin-staging.cavalle.dev` |
| `TENANT_STAGING_DOMAIN` | `app-staging.cavalle.dev` |

### GitHub Variables (Settings → Secrets → Actions → Variables)
| Variable | Descripció |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL_STAGING` | URL del projecte Supabase staging |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY_STAGING` | Clau pública (anon key) Supabase staging |
| `NEXT_PUBLIC_SUPABASE_URL_PROD` | URL del projecte Supabase producció |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY_PROD` | Clau pública (anon key) Supabase producció |

### Vercel Environment Variables (per a runtime del servidor)
| Variable | Scope | Descripció |
|---|---|---|
| `DATABASE_URL` | Preview + Production | Connection string Prisma (via PgBouncer) |
| `VITE_SUPABASE_URL` | Preview + Production | Per tenant-portal |
| `VITE_SUPABASE_PUBLISHABLE_DEFAULT_KEY` | Preview + Production | Per tenant-portal |

> `DATABASE_URL` pertany a Vercel (no a GitHub) perquè és un secret de servidor
> que Prisma llegeix en runtime, no en build time.

---

## Checklist per al deploy de producció

- [ ] Crear GitHub Variables per a producció: `NEXT_PUBLIC_SUPABASE_URL_PROD`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY_PROD`
- [ ] Configurar `DATABASE_URL` a Vercel → Environment Variables → scope **Production** per a admin-portal
- [ ] Configurar `VITE_SUPABASE_URL` i `VITE_SUPABASE_PUBLISHABLE_DEFAULT_KEY` a Vercel → scope **Production** per a tenant-portal
- [ ] Verificar que el domini de producció (`admin.cavalle.dev`) apunta a `cname.vercel-dns.com` a Cloudflare (proxy desactivat)
- [ ] Verificar que el domini és el domini de producció del projecte Vercel (Settings → Domains)
- [ ] Crear un usuari backoffice al Supabase de producció amb `app_metadata.role = "admin"`
