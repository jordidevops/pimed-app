# Pla: TCMS-2 - Website Builder de blocs (Puck) per al portal public del tenant

## TL;DR
Substituir l'editor TipTap/HTML actual de `data.tenant_content_items`/`data.public_pages` per un editor visual de blocs basat en Puck (`@measured/puck`, MIT), sense mantenir compatibilitat enrere (entorn dev local, sense produccio). S'inclou en el mateix pla: media library (imatges inline + gestor d'actius), formularis configurables (a mes del lead form simple actual), draft preview + historial de versions, un sistema de temes basat en tokens amb presets per vertical, i el paquet FSR amb reserves online, carta/menu i horaris com a casos de primera classe. S'aprofita al maxim l'arquitectura TCMS-1 existent (`tenant_content_items`, entitlements, quotes, dual-channel, sync a `public_pages`) en lloc de substituir-la.

## Decisions
- Sense migracio/retrocompatibilitat: entorn dev sense dades de produccio, es pot canviar directament l'esquema de `content` (de `{html}` a blocs Puck) amb `ALTER`/`UPDATE` net, sense taula paralela ni backfill complex.
- Puck com a llibreria de builder (confirmat, MIT, React-native, JSON-based, encaixa amb el model de seguretat multi-tenant existent).
- Tots els tiers tenen l'editor de blocs: en substituir TipTap per complet, la diferenciacio de tier (`none`/`basic`/`advanced`) es desplaca cap a quins tipus de bloc i funcionalitats estan disponibles (formularis personalitzats, historial de versions amb restore, nombre de presets de tema, quota de media), no cap a l'existencia de l'editor.
- `public_leads` es mante intacte per al bloc de formulari de contacte simple ja existent (`LeadForm.tsx` + `api.submit_public_lead`). El nou model de formularis configurables (`public_forms`/`public_form_fields`/`public_form_submissions`) es additiu, per a formularis avancats amb camps custom.
- Reaprofitar el bucket `public-assets` (public, actualment 2MB, tipus imatge) amb un nou segment de path `{tenant_id}/media/{asset_id}.{ext}` en lloc de crear un bucket nou; evita duplicar plumbing RLS. (a confirmar; alternativa: bucket dedicat `public-media` amb limit mes alt, p. ex. 5-10MB).
- Versionat: snapshot a `data.content_item_versions` en cada publish + accio manual desar versio, no en cada autosave (evita creixement excessiu de taula).
- Gap detectat: `sitemap.xml`/`robots.ts` no existeixen actualment a `apps/public-portal`; s'inclou com a fix dins l'abast SEO d'aquest pla.
- Comparticio de codi entre apps: `apps/tenant-portal` (Vite) i `apps/public-portal` (Next.js) no tenen workspaces npm/pnpm configurats ni precedent de codi compartit real (`packages/ai-schemas` no es consumit per cap app). Cal decidir entre crear paquet compartit `packages/portal-blocks` o duplicar components presentacionals lleugers en cada app i compartir nomes tipus/schemas Zod. Recomanacio: duplicar per ara.
- Fora d'abast explicit d'aquest pla (es mante al roadmap V2 existent): categories/taxonomia, notificacions push, digest per email, hard-delete + purga GDPR. Multi-departament per empleat tambe fora.

## Steps

### Fase A - Fonaments d'esquema de blocs (bloqueig de tot la resta)
1. Definir el contracte de dades Puck: `content` jsonb passa de `{"html": "..."}` a `{"puck": {"root": {}, "content": {}, "zones": {}}}` a `data.tenant_content_items` i `data.public_pages` (mateix camp, nova forma; `translations[locale].content` segueix el mateix patro).
2. Nova migracio (`supabase/migrations/<timestamp>_content_blocks_f6.sql`): actualitzar defaults, generalitzar el trigger de limits de camp (`20260931000001_tenant_content_items_f2.sql`) per mesurar `octet_length(content::text)` en lloc de longitud d'`html`; verificar que `data.sync_content_item_to_public_page` no depengui d'`html` explicitament.
3. Regenerar `database.types.ts` (comanda oficial del repo) i copiar a `supabase/functions/_shared/`.

### Fase B - Paquet de blocs compartit i editor (tenant-portal) - depen de Fase A
4. Crear `packages/portal-blocks/` (o duplicar segons decisio): definicions de blocs Fase 1 (15-20 blocs): Hero, RichText (TipTap nomes per text dins del bloc), Image, ImageGallery, CTAButton, FeatureGrid, Testimonials, FAQAccordion, ContactForm (embed lead form simple o `public_forms`), TeamMembers, JobOpenings, PricingTable, LogoCloud, Stats/Counters, Spacer/Container/Columns, VideoEmbed, MapEmbed. Cada bloc amb schema Zod de props.
5. Afegir `@measured/puck` a `apps/tenant-portal`. Substituir el camp `contentHtml`/TipTap de `ContentEditor.tsx` per `PortalBlocksEditor`.
6. Actualitzar `TenantContentFormState`, `tenantContentService.ts`, `useTenantContentMutations.ts` per enviar `content: {puck: Data}` en lloc de `contentHtml`.
7. Media picker com a custom field de Puck per al bloc Image/Gallery (llista/cerca/puja contra `data.public_media_assets`, Fase D).
8. Panell de tema basat en tokens (colors, tipografia, radius, spacing) substituint edicio JSON manual, cridant una versio estesa d'`api.patch_public_site_theme`.

### Fase C - Renderitzacio al portal public - depen de Fase A, en paral lel amb Fase B
9. Substituir `ContentBlock`/`renderBlock`/`renderContent` ad-hoc de `PortalPageContent.tsx` pel `<Render config={...} data={...}>` de Puck amb el mateix config compartit de la Fase B.4.
10. Draft preview: RPC `api.create_content_preview_token(item_id)` (token signat, TTL curt tipus 1h); nova ruta `apps/public-portal/app/preview/[token]/...` que verifica signatura/expiracio/tenant i renderitza el contingut en esborrany amb `noindex`.
11. Crear `apps/public-portal/app/sitemap.ts` i `apps/public-portal/app/robots.ts` (actualment inexistents) amb totes les `public_pages` publicades per site/domini.

### Fase D - Media library, versionat i formularis - depen de Fase A; independent entre si
12. Taula `data.content_item_versions` (patro reaprofitat de `document_versions`): `content_item_id, version_number, title, excerpt, content, translations, created_by, created_at, change_note`. RPCs: `api.list_content_item_versions`, `api.get_content_item_version`, `api.restore_content_item_version`.
13. Taula `data.public_media_assets` (`tenant_id, public_site_id NULL=tenant-wide, storage_path, file_name, mime_type, size_bytes, width, height, alt_text, created_by, created_at`). RPCs `api.list_public_media_assets`, `api.register_public_media_asset`, `api.delete_public_media_asset`. Extensio del bucket `public-assets` amb path `media/`.
14. Formularis configurables: taules `data.public_forms`, `data.public_form_fields`, `data.public_form_submissions`. RPCs: `api.upsert_public_form`, `api.submit_public_form` (SECURITY DEFINER, anon, amb idempotency_key), `api.list_public_form_submissions`. Bloc Puck Form amb fallback al lead form simple existent.

### Fase E - FSR web pack: reserves, carta i horaris - depen de C i D
15. Crear un bloc de reserva online per al portal public que consulti disponibilitat real i generi sollicituds/reserves amb `party_size`, franja horaria, notes, contacte i estat (`requested`, `confirmed`, `cancelled`, `no_show`). Prioritat: flux de reserva com a CTA principal de la web FSR.
16. Afegir el model minim de sala per donar resposta real al widget: taules amb capacitat, possibles combinacions i RPC de disponibilitat per `site_id + start_at + party_size`, reaprofitant `assets`/`locations` si es possible.
17. Exposar horaris i dies tancats al portal public amb forma definida i consumida pel widget de reserves i per capcalera/peu de pagina.
18. Afegir un bloc de carta/menu per FSR que llegeixi del cataleg o d'una font de menu i mostri seccions, plats i especials del dia. Floor plan visual queda com a ampliacio posterior dins del vertical.

### Fase F - Temes, entitlements i gating - depen de B, C, D, E
19. Ampliar `theme_config` amb estructura de tokens (`colors`, `typography`, `radius`, `spacing`) + 4-6 presets per vertical (restaurant, salut/clinica, retail, serveis professionals, per defecte) com a constants al frontend (`lib/theme-presets.ts`).
20. Actualitzar `data.plans.portal_entitlements`/`portal_field_limits` amb nous flags per tier: allowlist de blocs per tier (basic vs advanced), acces a formularis custom, restore de versions, nombre de presets de tema, quota d'actius de media. Actualitzar `api.can_publish_content` i el trigger de tier-enforcement.

### Fase G - IA assistida (opcional)
21. Endpoint opcional que genera JSON de blocs Puck restringit als schemas Zod/blocs permesos (mai HTML/JS lliure), amb revisio humana obligatoria abans de publicar.

## Relevant files
- `supabase/migrations/20260931000001_tenant_content_items_f2.sql`
- `supabase/migrations/20260513000001_public_portal_core.sql`
- `supabase/migrations/20260513000002_public_portal_rls.sql`
- `supabase/migrations/20260520000001_public_portal_content_v1.sql`
- `supabase/migrations/20260930200001_portal_entitlements_f1.sql`
- `supabase/migrations/20260427000007_email_branding_templates_site.sql`
- `supabase/migrations/20260502210551_documents_core.sql`
- `apps/tenant-portal/src/features/tenant-content/components/ContentEditor.tsx`
- `apps/tenant-portal/src/features/tenant-content/api/tenantContentTypes.ts`
- `apps/tenant-portal/src/features/tenant-content/api/tenantContentService.ts`
- `apps/tenant-portal/src/features/tenant-content/api/useTenantContentMutations.ts`
- `apps/tenant-portal/src/features/tenant-content/api/useTenantContentItems.ts`
- `apps/public-portal/components/PortalPageContent.tsx`
- `apps/public-portal/components/PortalShell.tsx`
- `apps/public-portal/lib/theme.ts`
- `apps/public-portal/lib/portal.ts`
- `apps/public-portal/components/LeadForm.tsx`
- `apps/public-portal/app/sitemap.ts` (nou)
- `apps/public-portal/app/robots.ts` (nou)
- `apps/public-portal/app/preview/[token]/...` (nou)
- `packages/portal-blocks/` (nou, si s'opta per paquet compartit)
- `docs/plans/content/plan-tenant-content.md`
- `docs/V2/public-portal-content-v1-v2.md`
- `docs/product-design/veriticals/FSR - Full Service Restaurant.md`

## Verification
1. Ampliar `docs/plans/content/tcms1-smoke-checklist.md` (o crear `tcms2-blocks-smoke-checklist.md`) amb validacions de publicacio, sync, versionat, preview, RLS media i gating per tier.
2. Executar `get_errors` despres de cada fase (migracions SQL i codi TS/TSX).
3. Verificar flux FSR: crear reserva des de web publica amb disponibilitat real, validar CTA de reserves a home/hero, i comprovar que `business_hours`/dies tancats condicionen disponibilitat i presentacio.
4. Manual general: crear pagina amb Hero+FeatureGrid+Testimonials+Form+Image, publicar, validar `sitemap.xml`, validar preview, restaurar versio anterior i canviar preset de tema.

## Further Considerations
1. Comparticio de codi entre apps: paquet compartit `packages/portal-blocks` vs duplicacio de components presentacionals.
2. Bucket media: reaprofitar `public-assets` amb path `media/` vs bucket dedicat `public-media`.
3. Estrategia de versionat: snapshot nomes a publish + manual vs snapshot a cada autosave.
