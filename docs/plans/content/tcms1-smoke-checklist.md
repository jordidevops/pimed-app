# TCMS-1 — Smoke checklist: CMS unificat (portal empleat + web pública)

> **Codi del pla:** TCMS-1  
> **Pla:** [`plan-tenant-content.md`](./plan-tenant-content.md)  
> **Runbook local:** [`DEV_RUNBOOK.md`](../../../DEV_RUNBOOK.md) § TCMS-1 smoke

**Estat checklist (2026-07-13):** SQL automatitzat F1+F2 ✅ · E2E manual pendent (marca `[x]` quan passi al navegador).

### Quin portal en cada secció?

| Secció | On | Rol |
|--------|-----|-----|
| **1** | SQL (Docker) | CI / dev local |
| **2** | **admin-portal** | Super-admin (entitlements) |
| **3–4, 6–8, 10–11** | **tenant-portal** | Owner / manager |
| **5, 9** | **public-portal** | Empleat sense compte + visitant anònim |

---

## Prerequisits

| # | Requisit |
|---|----------|
| P1 | Supabase local (`supabase start`) + migracions TCMS (`20260930200001` F1, `20260931000001` F2, fix seed `20260931000002`). |
| P2 | Edge Functions: `supabase functions serve --env-file supabase/functions/.env.local` (reiniciar després d'afegir `content-service.ts`). |
| P3 | **tenant-portal** dev (`apps/tenant-portal`, Vite). |
| P4 | **public-portal** dev (`apps/public-portal`, port **3002**). |
| P5 | **admin-portal** dev (opcional per F1). |
| P6 | Tenant seed **Acme** (`10000000-0000-0000-0000-000000000001`): `employee_portal_enabled = true`, pla **pro** amb `cms_tier` basic+. |
| P7 | Token dev Montserrat: `ep0-dev-acme-montserrat` → `/e/…` → sessió portal. |
| P8 | ISR revalidate (F3): mateix secret a `VITE_PORTAL_REVALIDATE_SECRET` (tenant-portal) i `REVALIDATE_PORTAL_SECRET` (public-portal). Veure `.env.example` de cada app. |

**Tests SQL (automatitzats — executar abans del smoke manual):**

```powershell
.\supabase\tests\run_portal_entitlements_tests.ps1
.\supabase\tests\run_tenant_content_tests.ps1
```

| Suite | Resultat 2026-07-13 |
|-------|---------------------|
| TCMS F1 (entitlements) | ✅ 6/6 |
| TCMS F2 (content + sync + employee RPC) | ✅ 6/6 |

**Regenerar tipus TypeScript** (després de migracions):

```powershell
cd C:\JordiDevops\pimed-app
supabase gen types typescript --local 2>$null | Set-Content "apps\tenant-portal\src\types\database.types.ts" -Encoding utf8
Copy-Item "apps\tenant-portal\src\types\database.types.ts" "supabase\functions\_shared\database.types.ts"
Copy-Item "apps\tenant-portal\src\types\database.types.ts" "apps\public-portal\types\database.types.ts"
```

---

## 1. SQL automatitzat (F1 + F2)

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| 1.1 | `run_portal_entitlements_tests.ps1` | `TCMS F1: all tests passed` | [x] |
| 1.2 | `run_tenant_content_tests.ps1` | `TCMS F2: all tests passed` | [x] |

---

## 2. Entitlements — admin-portal (F1)

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| 2.1 | Tenant **free** → intent activar web pública | Toggle deshabilitat o sense efecte (`included_by_plan = false`) | [ ] |
| 2.2 | Tenant **pro** → activar employee + public | `employee_portal.effective` i `public_portal.effective` true al tab Portals | [ ] |
| 2.3 | Editar pla → `cms_tier` employee `none` | Portal empleat sense CMS; nav «Notícies» ocult al public-portal | [ ] |

---

## 3. Admin tenant — portal empleat (F3)

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| 3.1 | `/employee-portal/content` | Llista de contingut (o buida); tab visible si `employee_portal.effective` | [ ] |
| 3.2 | Nou anunci → audiència **departament** Producció (tier advanced) | Desat com draft; tier basic → selectors dept/site deshabilitats + error RPC `cms_tier_insufficient` | [ ] |
| 3.3 | Publicar anunci dept | Reach preview mostra count abans de confirmar | [ ] |
| 3.4 | Intent desactivar únic canal actiu | Switch disabled (no error SQL `last_channel_required`) | [ ] |
| 3.5 | Anunci + activar canal web | Modal confirmació addicional (`AnnouncementPublicConfirmDialog`) | [ ] |

---

## 4. Runtime portal empleat (F4)

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| 4.1 | Login `http://localhost:3002/e/ep0-dev-acme-montserrat` | Sessió OK; menú lateral | [ ] |
| 4.2 | Nav «Notícies» visible | Només si `cms_tier ≠ none` | [ ] |
| 4.3 | `/portal/news` | Llista anuncis visibles per audiència | [ ] |
| 4.4 | Empleat dept A vs dept B | Anunci dept A visible només per A (T2 SQL ✅; manual opcional) | [ ] |
| 4.5 | Item **sticky** | Apareix primer a la llista | [ ] |
| 4.6 | Item amb `publish_end_at` passat | No apareix a la llista | [ ] |
| 4.7 | Clic anunci → `/portal/news/{slug}` | Detall amb HTML sanititzat | [ ] |
| 4.8 | `GET /portal/api/content` (DevTools, cookie sessió) | 200 + `{ items: [...] }` | [ ] |

---

## 5. Web pública — tenant-portal + SSR (F3 + F4)

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| 5.1 | `/public-portal?tab=pages` → nova pàgina | Canal web ON per defecte; editor unificat (`ContentEditor`) | [ ] |
| 5.2 | Publicar pàgina | Visible immediatament a `http://localhost:3002/acme-corp/ca/{pageSlug}` (revalidate ISR, no esperar 1h) | [ ] |
| 5.3 | Browser anònim → URL pública | Pàgina renderitzada; HTML sanititzat | [ ] |
| 5.4 | Item **dual** (empleat + web) | Visible a `/portal/news` i web pública | [ ] |
| 5.5 | Desactivar canal web → draft/sync | Pàgina SSR desapareix o passa a draft | [ ] |
| 5.6 | 2 `public_sites` mateix slug «contacte» | Dos items diferents (quota per site, no UNIQUE global tenant) | [ ] |

---

## 6. API ràpida (opcional, PowerShell)

Amb sessió activa al navegador, copiar cookie `employee_portal_session` o provar des del browser DevTools.

Health + content (requereix cookie):

```
GET http://localhost:3002/portal/api/health
GET http://localhost:3002/portal/api/content
```

Esperat content: 200 amb `items`, o 403 `content_module_disabled` si CMS desactivat.

---

## Referències

| Recurs | Path |
|--------|------|
| Pla complet | `docs/plans/content/plan-tenant-content.md` |
| Migració F2 | `supabase/migrations/20260931000001_tenant_content_items_f2.sql` |
| Feature tenant | `apps/tenant-portal/src/features/tenant-content/` |
| UI notícies | `apps/public-portal/features/employee-portal/components/PortalNews*.tsx` |
| Revalidate | `apps/public-portal/app/api/revalidate-portal/route.ts` |
