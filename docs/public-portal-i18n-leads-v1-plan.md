# Public Portal Multi-idioma + Leads V1 — Pla de treball

> Data: 13 maig 2026  
> Estat: pla final revisat, pendent d'implementació

V1 combina email obligatori al formulari, correu de confirmació al lead, correus configurables per portal, i multi-idioma SEO-friendly. Estratègia: URL amb prefix de locale (`/{slug}/{locale}/...`), negociació Accept-Language → `default_locale` del portal, fallback de pàgina al base `ca`. Model de traducció: base `ca` + `translations` JSON per locale (idèntic a email templates).

---

## Scope tancat (Phase 0)

- **URL sistema**: `/{slug}/{locale}` (home) i `/{slug}/{locale}/{pageSlug}` (inner)
- **URL custom domain**: `/{locale}` i `/{locale}/{pageSlug}`
- **Locale negotiation** (sense prefix): al middleware (`proxy.ts`), no a la pàgina — evita latència extra
- **Catàleg fix V1**: `ca`, `es`, `en`
- **`event_type` confirmació lead**: `portal.lead_submitted_confirmation` — contracte únic, no modificar
- **Restricció `slug NOT IN ('ca','es','en')`** a `data.public_pages` — decisió de **producte i tècnica** alhora: evita col·lisió de routing i ambigüitat UX/SEO

---

## Phase 1 — Contracte SQL

**Fitxer**: `supabase/migrations/20260515000010_public_portal_i18n_locales_and_contact_emails.sql`

### `data.public_sites` — nous camps

```sql
supported_locales  text[]  NOT NULL DEFAULT '{ca}'
default_locale     text    NOT NULL DEFAULT 'ca'
contact_email_public  text NULL
lead_ack_copy_email   text NULL
```

**Constraints**:
- `CHECK (supported_locales <@ ARRAY['ca','es','en']::text[] AND cardinality(supported_locales) > 0)`
- `CHECK (default_locale = ANY(supported_locales))`
- `CHECK (contact_email_public ~* '^[^@]+@[^@]+$' OR contact_email_public IS NULL)`
- `CHECK (lead_ack_copy_email ~* '^[^@]+@[^@]+$' OR lead_ack_copy_email IS NULL)`

### `data.public_pages` — nous camps

```sql
translations  jsonb  NOT NULL DEFAULT '{}'

CONSTRAINT chk_public_pages_slug_not_reserved
  CHECK (slug NOT IN ('ca','es','en'))
```

### Vistes `api.*` a actualitzar
`api.public_sites`, `api.public_sites_full`, `api.public_pages`, `api.public_pages_full` — exposar nous camps.

### RPCs a actualitzar
- `api.create_public_site` — inicialitza locales/correus amb defaults
- `api.update_public_site` — nous params: `p_supported_locales`, `p_default_locale`, `p_contact_email_public`, `p_lead_ack_copy_email`
- `api.upsert_public_page` — nou param `p_translations jsonb`
- `api.portal_site_row` (composite type) + `resolve_site_for_portal` + `resolve_domain_for_portal` — afegir `supported_locales`, `default_locale`, `contact_email_public`; **MAI `lead_ack_copy_email` en RPC anon**

---

## Phase 2 — Tipus TypeScript

Regeneració estàndard + **pas addicional obligatori**:

```powershell
supabase gen types typescript --local 2>$null | Set-Content "apps/tenant-portal/src/types/database.types.ts" -Encoding utf8
Copy-Item "apps/tenant-portal/src/types/database.types.ts" "supabase/functions/_shared/database.types.ts"
# Pas addicional: public-portal té fitxer propi, NO cobert per la comanda estàndard
Copy-Item "apps/tenant-portal/src/types/database.types.ts" "apps/public-portal/types/database.types.ts"
```

Ajustar tipus locals (`PublicSite`, `PublicPage`) als hooks/components de `public-portal`.

---

## Phase 3 — Tenant Portal UI *(dep Phase 2, parallel Phase 4)*

### `SiteConfigForm.tsx`
- Checkboxes `ca/es/en` per `supported_locales`
- `<select>` de `default_locale` restringit als locales habilitats
- Camps `contact_email_public` i `lead_ack_copy_email`
- Validació client coherent amb constraints SQL

### `PageEditor.tsx` (model: `EmailTemplateEditor.tsx`)
- Selector de locale: `ca` (base) + addicionals de `supported_locales`
- Locale `ca` → edita camps base (`title`, `content`, `seoTitle`, ...)
- Locale no-base → edita `translations[locale]` com a overlay
- Hint fallback visible per camp buit: "Si buit, usa base ca"
- Actualitzar `usePublicSiteMutations` per enviar `p_translations`

---

## Phase 4 — Routing i render multi-idioma *(dep Phase 2, parallel Phase 3)*

### Nova estructura de rutes (sistema)

| Fitxer | Funció |
|--------|--------|
| `app/[slug]/page.tsx` | **Redirect 308 únic**: negocia locale → redirigeix a `/{slug}/{locale}` |
| `app/[slug]/[locale]/page.tsx` | Home localitzada *(nou)* |
| `app/[slug]/[locale]/[page-slug]/page.tsx` | Inner page localitzada *(nou, elimina `[page-slug]` actual)* |

### Custom domain `[...path]` — actualitzar parsing de segments

```typescript
// Abans:
const pageSlug = path[0] ?? 'home'

// Després:
const VALID_LOCALES = ['ca', 'es', 'en']
const locale = VALID_LOCALES.includes(path[0]) ? path[0] : null
const pageSlug = locale ? (path[1] ?? 'home') : (path[0] ?? 'home')
// Si no hi ha locale → 308 a `/{locale}/{path[0]}`
```

### `proxy.ts` — locale negotiation per custom domains sense prefix
Llegir `Accept-Language` header → `default_locale` del portal → reescriure a `/_sites/{host}/{locale}/{pathname}`.

### `<html lang>` dinàmic
El middleware injecta `x-locale` als headers. `app/layout.tsx` llegeix:
```typescript
import { headers } from 'next/headers'
const locale = (await headers()).get('x-locale') ?? 'ca'
// <html lang={locale}>
```
**No** sobreescriure via layout fill (tècnica poc fiable amb App Router).

### Frontera RSC ↔ Client Components

| Component | Tipus | Motiu |
|-----------|-------|-------|
| `page.tsx` | RSC | fetch + `resolveLocalizedPage()` + metadata; passa `locale` + `localizedContent` per prop |
| `PortalPageContent` | Client | `useTranslation` de l'app shell |
| `LeadForm` | Client | hooks de formulari, Turnstile |
| `LanguageSwitcher` | Client | navegació entre locales |

**Cap `useTranslation` en RSC** — strings estàtics llegits del JSON de locale o passats per prop.

### `resolveLocalizedPage(page, locale)`
Base `ca` + overlay `page.translations[locale]` camp per camp. Si camp absent → usa base `ca`.

### SEO
- `hreflang` emet **sempre tots els `supported_locales`** (fins i tot sense traducció: URL existeix, contingut fa fallback ca — ometre seria error SEO)
- `x-default` apunta a `default_locale`
- `canonical` amb prefix locale

### `lib/i18n.ts`
Afegir resources `es` i `en`. `I18nProvider` rep `locale` inicial per prop i fa `i18n.changeLanguage(locale)` a l'init.

---

## Phase 5 — Formulari leads localitzat *(dep Phase 4)*

### `LeadForm.tsx`
- Email obligatori + validació Zod
- Estat d'èxit: missatge + `<Link href="/{slug}/{locale}">` retorn a home (URL per prop)
- Bloc de contacte públic: mostra `contact_email_public` si no null (prop des del RSC)
- **`LanguageSwitcher`**: `<Link href="/{slug}/{newLocale}/{pageSlug}">` per cada locale de `supported_locales`
  - ⚠️ **NO és `i18n.changeLanguage()`** — és navegació d'URL (SSR, compartible, indexable)

### `API /api/leads/route.ts`
- Acceptar i validar camp `locale` al body (`'ca' | 'es' | 'en'`)
- Persistir a `metadata` del lead: `{ ...existingMetadata, locale }`
- Mantenir antiabuse: honeypot, Turnstile, rate limit, idempotency

### `process-leads-queue/index.ts` — handler `lead_submitted`
```typescript
// Confirmació al submitter
await enqueueEmail({
  event_type: 'portal.lead_submitted_confirmation',
  to: lead.email,
  locale: payload.locale,
  variables: { lead_name, site_name, site_url }
})

// BCC intern (best-effort)
if (site.lead_ack_copy_email && site.lead_ack_copy_email !== lead.email) {
  try {
    await enqueueEmail({ ..., to: site.lead_ack_copy_email })
  } catch (e) {
    console.warn('[leads-worker] BCC intern fallat:', e)
    // NO llança excepció
  }
}
```

---

## Phase 6 — Plantilla email confirmació lead *(dep Phase 1, parallel Phase 5)*

**Fitxer**: `supabase/migrations/20260515000011_lead_confirmation_email_template.sql`

Seed a `data.email_templates`:
- `event_type = 'portal.lead_submitted_confirmation'`
- `is_platform_default = true`
- Variables mínimes: `{{lead_name}}`, `{{site_name}}`, `{{site_url}}`
- Base en `ca` + `translations: { es: {...}, en: {...} }` (model JSON existent)

---

## Phase 7 — Verificació integral *(dep Phases 3–6)*

1. **SQL**: `slug = 'ca'` a `public_pages` falla; locales invàlids fallen; RPC anon no exposa `lead_ack_copy_email`
2. **Tipus**: els **tres** fitxers de types reflecteixen nous camps
3. **Tenant UI**: desar/recuperar locales, correus i traduccions per locale; fallback visible
4. **Routing sistema**: 308 sense prefix → locale resolt; pàgina correcta amb prefix (home + inner)
5. **Routing custom domain**: 308 sense prefix; parsing `path[0]=locale`, `path[1]=pageSlug` correcte
6. **`<html lang>`**: reflectit al View Source per cada locale
7. **SEO**: hreflang per tots els `supported_locales`, `x-default` correcte
8. **Lead form**: no envia sense email; link retorn funcional; LanguageSwitcher canvia URL
9. **Worker async**: confirmació en locale correcte; BCC rebut si configurat; idempotency en retry
10. **No regressions**: Turnstile, rate limit, notificacions owners/managers

---

## Fitxers afectats

| Fitxer | Acció |
|--------|-------|
| `supabase/migrations/20260515000010_*.sql` | Crear (migració principal) |
| `supabase/migrations/20260515000011_*.sql` | Crear (seed plantilla email) |
| `apps/tenant-portal/src/types/database.types.ts` | Regenerar |
| `supabase/functions/_shared/database.types.ts` | Còpia post-regen |
| `apps/public-portal/types/database.types.ts` | Còpia post-regen *(pas addicional)* |
| `apps/tenant-portal/src/features/public-portal/components/SiteConfigForm.tsx` | Afegir locales + correus |
| `apps/tenant-portal/src/features/public-portal/components/PageEditor.tsx` | Editor multi-locale |
| `apps/tenant-portal/src/features/public-portal/api/usePublicSiteMutations.ts` | Nous params |
| `apps/public-portal/proxy.ts` | Locale negotiation + rewrite custom domain |
| `apps/public-portal/app/layout.tsx` | `<html lang>` dinàmic via `x-locale` header |
| `apps/public-portal/app/[slug]/page.tsx` | Convertir en redirect 308 pur |
| `apps/public-portal/app/[slug]/[page-slug]/page.tsx` | Eliminar (substituït per `[locale]/`) |
| `apps/public-portal/app/[slug]/[locale]/page.tsx` | Crear (home localitzada) |
| `apps/public-portal/app/[slug]/[locale]/[page-slug]/page.tsx` | Crear (inner page localitzada) |
| `apps/public-portal/app/_sites/[domain]/[...path]/page.tsx` | Actualitzar parsing segments |
| `apps/public-portal/components/PortalPageContent.tsx` | `resolveLocalizedPage` |
| `apps/public-portal/components/LeadForm.tsx` | Email obligatori, link retorn, LanguageSwitcher |
| `apps/public-portal/app/api/leads/route.ts` | Validar + persistir `locale` |
| `apps/public-portal/lib/i18n.ts` | Resources `es` i `en` |
| `supabase/functions/process-leads-queue/index.ts` | Confirmació lead + BCC intern |

---

## Decisions de scope

### Inclou V1
- Multi-idioma URL prefix, catàleg fix `ca/es/en`
- Governance per portal: `supported_locales` + `default_locale`
- Traduccions de pàgina: model base `ca` + `translations` JSON overlay
- Formulari/lead localitzats, email obligatori, return link post-submit
- Correu de contacte públic i còpia interna BCC per portal
- Confirmació al lead via plantilla `portal.lead_submitted_confirmation`

### Exclou V1 (backlog)
- Idiomes fora de `ca/es/en`
- Slugs traduïbles per locale
- **Invalidació ISR on-demand**: limitació coneguda — `revalidate=3600`, traduccions noves no apareixen fins al TTL; solució futura: webhook Supabase → `revalidatePath`
- Multi-destinatari de còpia interna (llista) o regles condicionals
- Editor WYSIWYG avançat per blocs multilingües

---

## Notes addicionals

1. En RPC anon (`resolve_site_for_portal`, `resolve_domain_for_portal`) exposar **NOMÉS** `contact_email_public`. Mai `lead_ack_copy_email`.
2. Al worker: evitar auto-còpia si `lead_ack_copy_email === lead.email`.
3. Considerar audit action `PORTAL_LOCALES_CHANGED` quan es modifiquen idiomes o correus del portal.
