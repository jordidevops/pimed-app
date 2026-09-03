# Public Portal — Content, Header/Footer, Logo i Límits: Pla V1 + V2

## Context

Actualment el tenant pot crear pàgines i configurar dominis però no pot editar contingut, ni hi ha header ni footer, ni logo, ni límits de quota per pla. Un portal sense contingut ni branding no té valor.

## Decisions d'arquitectura (aprovades)

| Decisió | Opció triada | Motiu |
|---|---|---|
| Editor de contingut V1 | TipTap (StarterKit) | Rich-text minimalista; output HTML `{html:"..."}` compatible amb `PortalPageContent` existent, zero canvis al render |
| Emmagatzematge del contingut V1 | DB JSONB | Simple, transaccional, RLS nativa. Migrar a Storage en V2 si el consum per tenant > 10 MB |
| Header/Footer V1 | Extendre `theme_config` JSONB existent | `data.public_sites.theme_config` ja existeix; no cal ALTER TABLE |
| Logo V1 | Bucket `public-assets` existent | Ja creat, `public=true`, 2 MB límit, path `{tenant_id}/portal/logo.{ext}` |
| Límits V1 | Per **camp editable** (chars), no per pàgina global | Permet granularitat màxima sense inflacionar columnes. Es guarda a `plans.portal_field_limits jsonb` |
| Enforcement de límits | Trigger BD + guard UI | BD garanteix integritat; UI mostra feedback en temps real |
| Merge de `theme_config` | Deep-merge via RPC de patch | Evita esborrar claus existents en guardats parcials |
| Auditoria de contingut | Actions mínimes amb metadades (mida, clau) | No guardem HTML complet al log; sí `old_chars`, `new_chars`, locale, field_key |

---

## Estructura de `theme_config` (contracte V1)

```jsonc
{
  "logo_url": "https://...",        // URL pública de public-assets
  "colors": {
    "primary": "#4F46E5"            // color accent del portal
  },
  "header": {
    "show": true,
    "show_contact_button": true,
    "contact_button_label": "Contacta'ns"
  },
  "footer": {
    "show": true,
    "copyright_text": "© 2025 Empresa SL",
    "social": {
      "linkedin": "https://linkedin.com/...",
      "instagram": "https://instagram.com/...",
      "twitter":   "https://x.com/...",
      "facebook":  "https://facebook.com/..."
    }
  }
}
```

**Nav automàtica**: es genera des de pàgines publicades amb `show_in_nav = true` i `sort_order` ascendent. Cap configuració manual a V1.

---

## Estructura de `portal_field_limits` a `data.plans` (contracte V1)

```jsonc
{
  "page_title_max_chars":       120,   // title de la pàgina base + traduccions
  "page_seo_title_max_chars":   70,
  "page_seo_description_max_chars": 160,
  "page_html_max_chars":        50000, // content.html + translations[].content.html per locale
  "nav_label_max_chars":        40,    // future: nav label personalitzat (V2)
  "footer_text_max_chars":      300,   // footer.copyright_text
  "header_cta_label_max_chars": 50     // header.contact_button_label
}
```

Valors per pla:

| Camp | Free | Pro | Enterprise |
|---|---|---|---|
| `max_portal_pages` | 3 | 20 | 0 (∞) |
| `page_title_max_chars` | 120 | 120 | 120 |
| `page_seo_title_max_chars` | 70 | 70 | 70 |
| `page_seo_description_max_chars` | 160 | 160 | 160 |
| `page_html_max_chars` | 10 000 | 50 000 | 0 (∞) |
| `footer_text_max_chars` | 150 | 300 | 0 (∞) |
| `header_cta_label_max_chars` | 50 | 50 | 50 |

`0` = il·limitat (convenant consistent amb `max_sites`).

---

## V1 — Implementació

### Fase 1 — Migració SQL `20260520000001_public_portal_content_v1.sql`

Tots els canvis de BD en una sola migració atòmica.

**1a. `data.plans` — nous camps de quota portal:**

```sql
ALTER TABLE data.plans
  ADD COLUMN IF NOT EXISTS max_portal_pages integer NOT NULL DEFAULT 5,
  ADD COLUMN IF NOT EXISTS portal_field_limits jsonb NOT NULL DEFAULT '{}';

COMMENT ON COLUMN data.plans.max_portal_pages
  IS 'Màxim de pàgines al portal públic. 0 = il·limitat.';

COMMENT ON COLUMN data.plans.portal_field_limits
  IS 'Límits per camp editable del portal. Claus: page_html_max_chars, page_title_max_chars, etc. 0 = il·limitat.';
```

Valors inicials a `seed.sql`:
```sql
UPDATE data.plans SET
  max_portal_pages = 3,
  portal_field_limits = '{"page_html_max_chars":10000,"page_title_max_chars":120,...}'
WHERE name = 'free';
-- pro: max_portal_pages=20, page_html_max_chars=50000
-- enterprise: max_portal_pages=0, page_html_max_chars=0
```

**1b. `data.public_pages` — camp `show_in_nav`:**

```sql
ALTER TABLE data.public_pages
  ADD COLUMN IF NOT EXISTS show_in_nav boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN data.public_pages.show_in_nav
  IS 'Si true, la pàgina apareix a la nav automàtica del header i footer.';
```

Exposat a `api.public_pages` i `api.public_pages_full`.

**1c. Trigger `enforce_portal_page_quota` (model: `enforce_site_quota`):**

```sql
CREATE OR REPLACE FUNCTION data.enforce_portal_page_quota()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_limit   integer;
  v_current integer;
BEGIN
  -- Bypass per a rols privilegiats
  IF current_role IN ('postgres', 'service_role', 'supabase_admin') THEN
    RETURN NEW;
  END IF;

  SELECT p.max_portal_pages
    INTO v_limit
    FROM data.tenants t
    JOIN data.plans   p ON p.id = t.plan_id
   WHERE t.id = NEW.tenant_id;

  IF v_limit IS NULL OR v_limit = 0 THEN RETURN NEW; END IF;

  SELECT COUNT(*)::integer INTO v_current
    FROM data.public_pages
   WHERE public_site_id = NEW.public_site_id
     AND (TG_OP = 'INSERT' OR id != NEW.id);

  IF v_current >= v_limit THEN
    RAISE EXCEPTION 'quota_exceeded: El pla permet un màxim de % pàgines al portal.',
      v_limit USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_enforce_portal_page_quota
  BEFORE INSERT ON data.public_pages
  FOR EACH ROW EXECUTE FUNCTION data.enforce_portal_page_quota();
```

**1d. Trigger `enforce_portal_field_limits` (límit per camp editable, BD-side):**

Valida: `title`, `seo_title`, `seo_description`, `content->>'html'` i cada locale a `translations`.

```sql
CREATE OR REPLACE FUNCTION data.enforce_portal_field_limits()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_limits   jsonb;
  v_locale   text;
  v_html_lim integer;
  v_ttl_lim  integer;
  v_seo_t    integer;
  v_seo_d    integer;
BEGIN
  IF current_role IN ('postgres', 'service_role', 'supabase_admin') THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(p.portal_field_limits, '{}')
    INTO v_limits
    FROM data.tenants t
    JOIN data.plans   p ON p.id = t.plan_id
   WHERE t.id = NEW.tenant_id;

  v_html_lim := COALESCE((v_limits->>'page_html_max_chars')::integer, 0);
  v_ttl_lim  := COALESCE((v_limits->>'page_title_max_chars')::integer, 0);
  v_seo_t    := COALESCE((v_limits->>'page_seo_title_max_chars')::integer, 0);
  v_seo_d    := COALESCE((v_limits->>'page_seo_description_max_chars')::integer, 0);

  -- title base
  IF v_ttl_lim > 0 AND char_length(NEW.title) > v_ttl_lim THEN
    RAISE EXCEPTION 'field_limit_exceeded:title: % caràcters (màxim %)',
      char_length(NEW.title), v_ttl_lim USING ERRCODE = 'P0001';
  END IF;

  -- seo_title base
  IF v_seo_t > 0 AND NEW.seo_title IS NOT NULL AND char_length(NEW.seo_title) > v_seo_t THEN
    RAISE EXCEPTION 'field_limit_exceeded:seo_title: % caràcters (màxim %)',
      char_length(NEW.seo_title), v_seo_t USING ERRCODE = 'P0001';
  END IF;

  -- seo_description base
  IF v_seo_d > 0 AND NEW.seo_description IS NOT NULL AND char_length(NEW.seo_description) > v_seo_d THEN
    RAISE EXCEPTION 'field_limit_exceeded:seo_description: % caràcters (màxim %)',
      char_length(NEW.seo_description), v_seo_d USING ERRCODE = 'P0001';
  END IF;

  -- content.html base
  IF v_html_lim > 0 AND NEW.content IS NOT NULL AND (NEW.content->>'html') IS NOT NULL THEN
    IF char_length(NEW.content->>'html') > v_html_lim THEN
      RAISE EXCEPTION 'field_limit_exceeded:content.html: % caràcters (màxim %)',
        char_length(NEW.content->>'html'), v_html_lim USING ERRCODE = 'P0001';
    END IF;
  END IF;

  -- Iteració per locale a translations
  FOR v_locale IN SELECT jsonb_object_keys(NEW.translations) LOOP
    IF v_ttl_lim > 0
       AND (NEW.translations->v_locale->>'title') IS NOT NULL
       AND char_length(NEW.translations->v_locale->>'title') > v_ttl_lim THEN
      RAISE EXCEPTION 'field_limit_exceeded:translations.%.title: % caràcters (màxim %)',
        v_locale, char_length(NEW.translations->v_locale->>'title'), v_ttl_lim USING ERRCODE = 'P0001';
    END IF;

    IF v_html_lim > 0
       AND (NEW.translations->v_locale->'content'->>'html') IS NOT NULL
       AND char_length(NEW.translations->v_locale->'content'->>'html') > v_html_lim THEN
      RAISE EXCEPTION 'field_limit_exceeded:translations.%.content.html: % caràcters (màxim %)',
        v_locale, char_length(NEW.translations->v_locale->'content'->>'html'), v_html_lim USING ERRCODE = 'P0001';
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_enforce_portal_field_limits
  BEFORE INSERT OR UPDATE ON data.public_pages
  FOR EACH ROW EXECUTE FUNCTION data.enforce_portal_field_limits();
```

**1e. RPC `api.patch_public_site_theme` — deep-merge de `theme_config`:**

Evita l'overwrite complet; fa merge per secció (`header`, `footer`, `colors`, `branding`).

```sql
CREATE FUNCTION api.patch_public_site_theme(
  p_id          uuid,
  p_section     text,    -- 'header' | 'footer' | 'colors' | 'branding'
  p_patch       jsonb
)
RETURNS void
LANGUAGE plpgsql SECURITY INVOKER ...
  -- UPDATE data.public_sites SET
  --   theme_config = jsonb_set(theme_config, ARRAY[p_section], ...)
  -- amb merge de claus del nivell superior
```

Audit: `PUBLIC_SITE_THEME_UPDATED` amb payload `{section, changed_keys: [...], public_site_id}`.

**1f. Vista `api.portal_usage`:**

```sql
CREATE VIEW api.portal_usage WITH (security_invoker = true) AS
SELECT
  pp.public_site_id,
  pp.tenant_id,
  COUNT(*)                                                  AS page_count,
  -- bytes DB: contingut + traduccions
  SUM(octet_length(pp.content::text)
    + octet_length(pp.translations::text))                  AS db_content_bytes,
  -- bytes total site (afegeix theme_config)
  SUM(octet_length(pp.content::text)
    + octet_length(pp.translations::text))
  + MAX(octet_length(ps.theme_config::text))                AS db_total_bytes
FROM data.public_pages pp
JOIN data.public_sites ps ON ps.id = pp.public_site_id
WHERE (data.active_tenant_id() IS NULL OR pp.tenant_id = data.active_tenant_id())
GROUP BY pp.public_site_id, pp.tenant_id;

GRANT SELECT ON api.portal_usage TO authenticated;
```

> **Nota**: el consum de logo/imatges a `public-assets` es consulta via `api.storage_usage` (ja existent). Per V1, el tenant veurà dos indicadors separats: DB bytes (portal_usage) i Storage bytes (storage_usage).

**1g. Audit per canvis de contingut de pàgina:**

Afegir al trigger `trg_audit_public_pages` existent la detecció de canvis de contingut:

```sql
-- Al bloc ELSIF TG_OP = 'UPDATE' del trigger existent, afegir:
IF OLD.content IS DISTINCT FROM NEW.content
   OR OLD.translations IS DISTINCT FROM NEW.translations THEN
  PERFORM data.log_audit_event(
    NEW.tenant_id, auth.uid(), NULL,
    'PUBLIC_PAGE_CONTENT_UPDATED', 'public_page', NEW.id,
    jsonb_build_object(
      'slug',            NEW.slug,
      'old_html_chars',  char_length(OLD.content->>'html'),
      'new_html_chars',  char_length(NEW.content->>'html'),
      'locales_changed', (
        SELECT jsonb_agg(k) FROM jsonb_object_keys(NEW.translations) k
        WHERE NEW.translations->k IS DISTINCT FROM OLD.translations->k
      )
    )
  );
END IF;
```

**1h. Actualitzar `api.upsert_public_page`:**

Afegir param `p_show_in_nav boolean DEFAULT true` i actualitzar `api.public_pages/public_pages_full`.

**1i. Regenerar tipus TypeScript (3 fitxers):**

```powershell
supabase gen types typescript --local 2>$null | Set-Content "apps/tenant-portal/src/types/database.types.ts" -Encoding utf8
Copy-Item "apps/tenant-portal/src/types/database.types.ts" "supabase/functions/_shared/database.types.ts"
Copy-Item "apps/tenant-portal/src/types/database.types.ts" "apps/public-portal/types/database.types.ts"
```

---

### Fase 2 — Public Portal: Header + Footer + Logo

Fitxers nous a `apps/public-portal/components/`:

**2a. `PortalHeader.tsx` (Server Component):**
- Logo `<img src={theme_config.logo_url}>` linkejant a home
- Nav auto-generada: `pages.filter(p => p.show_in_nav && p.status === 'published').sort(sort_order)`
- Botó CTA si `header.show_contact_button` → link a pàgina amb `slug = 'contact'` o anchor `#contact`
- Color primari via CSS variable injectada des de `theme_config.colors.primary`
- Props: `site: PublicSite, pages: PublicPage[], currentLocale: string, currentPageSlug: string`

**2b. `PortalFooter.tsx` (Server Component):**
- Copyright text de `footer.copyright_text`
- Links de pàgines `show_in_nav=true` (columna de links)
- Icones social (LinkedIn, Instagram, Twitter/X, Facebook) si el camp no és buit

**2c. `PortalShell.tsx`:**
- Embolcalla `<PortalHeader>`, `{children}`, `<PortalFooter>`
- Injecta `<style>` amb CSS variable `--color-primary: {theme_config.colors.primary}` per a tot el portal
- S'aplica als layouts de rutes: `[slug]/[locale]/layout.tsx` i `sites/[domain]/layout.tsx`

---

### Fase 3 — Tenant Portal: TipTap + Apariència

**3a. Dependències (package.json):**
```json
"@tiptap/react": "^2.x",
"@tiptap/starter-kit": "^2.x",
"@tiptap/extension-placeholder": "^2.x",
"@tiptap/extension-link": "^2.x"
```

**3b. `src/components/ui/RichTextEditor.tsx`:**
- Toolbar: Bold, Italic, H2, H3, UL, OL, Link, separadors visuals
- Guarda com `{html: editor.getHTML()}`
- `CharCounter` inline: "X / Y caràcters" amb color amber si >80%, red si >100%
- Prop `maxChars?: number` — si 0 o undefined, no hi ha límit UI
- `onLimitExceeded(field: string)` callback per bloquejar el submit

**3c. Integrar a `PageEditor.tsx`:**
- `InlinePageForm` afegeix `<RichTextEditor>` per sota dels camps de SEO
- En locale base: edita `form.content.html`
- En locale no-base: edita `form.translations[locale].content.html`
- `pageToForm()` extreu `content?.html ?? ''`
- Afegir checkbox `show_in_nav` al formulari (visible, labeled)
- Actualitzar `useSavePublicPage` per passar `p_show_in_nav`

**3d. `src/features/public-portal/components/AppearanceEditor.tsx`:**
- Secció **Branding**: upload logo (input file → Storage `public-assets/{tenant_id}/portal/logo.{ext}` → `api.patch_public_site_theme('branding', {logo_url})`)
- Preview logo inline
- Secció **Colors**: `<input type="color">` per `colors.primary`
- Secció **Header**: toggle "Mostrar nav", toggle "Botó de contacte", camp text etiqueta botó (counter max_chars)
- Secció **Footer**: textarea copyright (counter max_chars), 4 camps URL de xarxes socials
- Cada secció guarda independentment via `api.patch_public_site_theme`

**3e. Tab "Apariència" a `PublicPortalPage.tsx`:**
- Nou `TabsTrigger value="appearance"` + `TabsContent` amb `<AppearanceEditor>`
- Habilitat si `site?.id` existeix

**3f. Indicador de quota a `PageEditor.tsx`:**
- Badge `"X / Y pàgines"` al header de la llista de pàgines
- Botó "Nova pàgina" `disabled` amb tooltip si `page_count >= max_portal_pages` (i límit != 0)
- Hook `usePortalUsage(siteId: string)` → `supabase.from('portal_usage').select('*').eq('public_site_id', siteId).single()`

**3g. i18n:**
- Totes les strings noves via `t('public_portal.appearance.*', 'fallback')` i `t('public_portal.pages.nav_*', 'fallback')`
- Actualitzar `src/locales/ca/public-portal.json`

---

### Fase 4 — Verificació V1

| Test | Acció | Resultat esperat |
|---|---|---|
| Quota pàgines BD | INSERT que excedeix `max_portal_pages` | Error P0001 de trigger |
| Pla enterprise (0) | INSERT il·limitat | Permet |
| Límit HTML | Enviar >10 000 chars (free) | Error `field_limit_exceeded:content.html` |
| Límit per locale | Traducció `es` amb title >120 | Error `field_limit_exceeded:translations.es.title` |
| Deep-merge tema | Guardar solo header; consultar theme_config | Claus footer i colors conservades |
| Logo Storage | Pujar logo → URL → render | Accessible sense JWT (bucket public) |
| Header/Footer | Obrir pàgina publicada | Header visible amb logo + nav; Footer amb copyright |
| show_in_nav=false | Deseleccionar la pàgina | No apareix al menú header ni footer |
| TipTap → render | Escriure contingut → publicar | HTML correctament sanititzat a PortalPageContent |
| Quota visual | Obrir PageEditor | Badge "X / Y pàgines" reflecteix count real |
| Audit | Canviar contingut d'una pàgina | Registre `PUBLIC_PAGE_CONTENT_UPDATED` a audit_logs |

---

## V2 — Scope Futur

### 2.1 Navigation Builder

Arrossegar i ordenar pàgines al menú, etiquetes personalitzades per locale, links externs (sense pàgina del portal), items de submenú de primer nivell.

Model de dades: nou array `theme_config.nav_items` com a override de la nav automàtica:
```jsonc
"nav_items": [
  { "type": "page", "page_slug": "serveis", "label": { "ca": "Serveis", "es": "Servicios" } },
  { "type": "external", "href": "https://...", "label": { "ca": "Blog" } }
]
```

### 2.2 Image Blocks dins de l'Editor

Extensió `@tiptap/extension-image` + upload inline a `public-assets/{tenant_id}/portal/images/{uuid}.{ext}`.

Model de consum: el consum de les imatges s'acumula a `api.storage_usage`. Afegir indicador a l'editor de "X MB usats en imatges del portal".

### 2.3 Theme Presets

Paletes de colors predefinides (clar/fosc, 5 paletes base), selector de font des de Google Fonts (llista curada de 10 opcions, no cdn dinàmic). El `theme_config.font` s'afegeix al contracte.

### 2.4 Storage per Contingut Pesat (migració selectiva)

Quan `db_content_bytes > 5 MB` (mesurat per `api.portal_usage`), l'admin-portal pot migrar els HTMLs de pàgines individuals a fitxers JSON privats a `public-assets`:

- Path privat (cal canviar bucket a privat o usar tenant-files): `{tenant_id}/portal/pages/{page_id}-{locale}.json`
- El camp `content` a DB passa de `{html: "..."}` a `{storage_path: "..."}` 
- `PortalPageContent` detecta `storage_path` i fa fetch al render (SSR)
- Avantatge: cost DB quasi zero per tenant de contingut pesat

### 2.5 Prévia de Pàgines Esborrany

JWT de curta durada (1 hora) signat amb `SUPABASE_JWT_SECRET` que inclou `draft_preview=true` i `public_site_id`. La ruta de public-portal valida el token i permet renderitzar pàgines `status=draft`.

### 2.6 Analytics Bàsic

Integrar Vercel Analytics (si allotjat a Vercel) o PostHog (self-hosted possible). Esdeveniments mínims:
- `page_view` amb `{locale, page_slug, referrer}`
- `lead_form_view`, `lead_submitted`

### 2.7 Seccions Reutilitzables (Global Blocks)

Biblioteca de blocs globals gestionada al tenant-portal (CTA, testimonis, bloc de contacte avançat). Cada bloc té un `id`, es referencia des de `content.blocks[].block_id`. Quan s'actualitza el bloc global, totes les pàgines que el referenciaven es re-renderitzen.

### 2.8 Multi-locale Header/Footer

Traduccions de labels del `theme_config`:
```jsonc
"header": {
  "contact_button_label_i18n": { "ca": "Contacta'ns", "es": "Contáctanos", "en": "Contact Us" }
}
```

### 2.9 Mesura Consolidada a Admin Portal

Vista d'admin que mostra per tenant:
- `db_content_bytes` (portal_usage)
- `storage_bytes` (assets de portal a public-assets sota prefix `{tenant_id}/portal/`)
- Cost estimat en euros (preu Supabase Storage per GB/mes)
- % del pla consumit

Útil per detectar tenants de grans consumidors i proposar upgrade de pla.

---

## Fitxers afectats V1

| Fitxer | Operació |
|---|---|
| `supabase/migrations/20260520000001_public_portal_content_v1.sql` | CREAR — totes les DDL/DML de la Fase 1 |
| `supabase/seed.sql` | Editar — valors `max_portal_pages` i `portal_field_limits` per pla |
| `apps/tenant-portal/src/types/database.types.ts` | Regenerar |
| `supabase/functions/_shared/database.types.ts` | Còpia post-regen |
| `apps/public-portal/types/database.types.ts` | Còpia post-regen |
| `apps/public-portal/components/PortalHeader.tsx` | CREAR |
| `apps/public-portal/components/PortalFooter.tsx` | CREAR |
| `apps/public-portal/components/PortalShell.tsx` | CREAR |
| `apps/public-portal/app/[slug]/[locale]/layout.tsx` | CREAR (o editar si existeix) |
| `apps/public-portal/app/sites/[domain]/layout.tsx` | CREAR (o editar si existeix) |
| `apps/tenant-portal/package.json` | Editar — afegir deps TipTap |
| `apps/tenant-portal/src/components/ui/RichTextEditor.tsx` | CREAR |
| `apps/tenant-portal/src/features/public-portal/components/PageEditor.tsx` | Editar |
| `apps/tenant-portal/src/features/public-portal/components/AppearanceEditor.tsx` | CREAR |
| `apps/tenant-portal/src/features/public-portal/components/PublicPortalPage.tsx` | Editar — nova tab |
| `apps/tenant-portal/src/features/public-portal/api/usePublicSiteMutations.ts` | Editar — patch_public_site_theme |
| `apps/tenant-portal/src/features/public-portal/api/usePortalUsage.ts` | CREAR |
| `apps/tenant-portal/src/locales/ca/public-portal.json` | Editar — noves claus |

---

## Dependències entre fases

```
Fase 1 (SQL + tipus) ──┬──► Fase 2 (public-portal render)
                       └──► Fase 3 (tenant-portal UI)
Fase 2 + Fase 3 ──────────► Fase 4 (verificació integral)
```

Fase 2 i Fase 3 són paral·lelitzables un cop la Fase 1 és aplicada i els tipus regenerats.
