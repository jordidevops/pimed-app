# Legal Center — Guia de prova i revisió a l’app

> **Creat:** 2026-08-15 (post LC-4 + QA hardening)  
> **Propòsit:** checklist manual per validar el mòdul Legal & Compliance a tenant-portal, customer-portal i public-portal.  
> **Referència:** [`STATUS.md`](./STATUS.md) · [`EXECUTION.md`](./EXECUTION.md) · [`README.md`](./README.md)

---

## Abans de provar

1. Aplicar migracions locals fins a `20261159000047_legal_compliance_qa_hardening` (inclou filtre de retenció en handoff staff report-scoped).
2. Tenir un tenant amb Legal Center accessible (`Settings → Legal` / `/settings/legal`).
3. Idealment: un share de butlletí, un grant dashboard, un site públic (slug i/o custom domain), i un empleat amb portal.

---

## Com funciona (mapa ràpid)

| Peça | On | Què fa |
|------|-----|--------|
| **Legal Center** | Tenant Settings → Legal | Perfil (responsable/DPO), mode per document (`template` / `external_url`), preview, DPA soft-ack, retenció (lectura), DSAR revoke |
| **Resolució pública** | RPC `resolve_public_legal_document` | Retorna HTML de plantilla/edició o `external_url` (només s’hauria de redirigir si és `https://`) |
| **Customer-portal** | Footer + CookieNotice + `/legal/[code]?t=&locale=` | Art. 13 + cookies essencials (dismiss); sense acceptació obligatòria |
| **Public-portal** | Footer/cookies + `/[slug]/[locale]/legal/...` i custom domain `/{locale}/legal/...` | Web, leads, careers (`privacy_candidates`) |
| **Portal empleat** | `/portal/legal/[code]` + footer | Política empleat / termes / cookies |
| **Retenció** | Jobs + guards als resolve | Versions no `active` no s’haurien de servir a share/grant/staff |

**Modes de document**

- `template` — plantilla de plataforma (el més habitual a provar).
- `external_url` — redirecció a URL **https** (http/`javascript:` es rebutgen).
- `edited` — **sense editor/publicació a la UI** (opció oculta; si ja estava editat, avís per tornar a plantilla o URL).

**DPA:** el tenant reconeix la DPA de plataforma (soft-duty). El client final **no** l’accepta; no ha d’aparèixer a allowlists públiques.

---

## Checklist per superfície

### A. Tenant portal — Settings → Legal

| # | Prova | Esperat |
|---|--------|---------|
| A1 | Obrir Legal Center | Llista de documents + perfil |
| A2 | Desar perfil (nom responsable, email DPO, …) | Toast OK; persisteix en refresh |
| A3 | Preview d’un document en `template` | Modal/secció amb HTML net (sense scripts) |
| A4 | Mode → URL externa amb `https://…` | Mode guardat; preview obre pestanya |
| A5 | Mode → URL amb `http://` o `javascript:…` | Error; no es desa |
| A6 | Intentar mode «Editat» | Toast: no disponible; no canvia |
| A7 | Banner DPA → Reconèixer | `dpa_acknowledged_at` / banner desapareix o queda confirmat |
| A8 | Secció retenció | Comptes / dies visibles (read-only) |
| A9 | DSAR revoke (UUID contacte conegut) | Acció registrada a la llista |
| A10 | Recruitment settings | Enllaç a Legal (no camp URL legacy editable) |

### B. Customer-portal

| # | Prova | Esperat |
|---|--------|---------|
| B1 | Share `/r` + butlletí | Footer: Privacitat, Condicions, Cookies; CookieNotice dismissible |
| B2 | Canviar locale UI | Enllaços `/legal/...?locale=` i CookieNotice usen el mateix locale |
| B3 | Dashboard grant (llista butlletins) | Mateix footer/cookies amb locale (no sempre `es`) |
| B4 | Obrir `/legal/privacy_customers?t=<tenantId>&locale=ca` | HTML plantilla o redirect https |
| B5 | Document en mode URL no-https | Missatge «no disponible» / sense redirect |
| B6 | `/legal/dpa_platform?...` | 404 (no públic) |
| B7 | Versió amb `retention_status` ≠ `active` via share | Accés denegat |
| B8 | Staff handoff **report-scoped** a versió bloquejada | `version_retention_blocked` / sense contingut |
| B9 | Pàgina Accessos | Footer + cookies amb locale |

### C. Public-portal (slug)

| # | Prova | Esperat |
|---|--------|---------|
| C1 | `/{slug}/{locale}` footer | Enllaços legal / cookies |
| C2 | `/{slug}/{locale}/legal/privacy_website` | Document o redirect https |
| C3 | Lead form | Checkbox + enllaç política |
| C4 | Careers apply + rights | Política `privacy_candidates` (Legal Center) |
| C5 | Cookie notice | Informatiu; dismiss |

### D. Public-portal (custom domain)

| # | Prova | Esperat |
|---|--------|---------|
| D1 | `/{locale}/legal/cookie_notice` | Resol amb `tenant_id` del site |
| D2 | Lead form sense slug (o slug buit) | Enllaç privacitat present (`linkBase: locale` + tenant) |
| D3 | URL externa maliciosa al document | No redirect |

### E. Portal empleat

| # | Prova | Esperat |
|---|--------|---------|
| E1 | Footer legal | Privacitat empleat / termes / cookies |
| E2 | `/portal/legal/privacy_employees` | Contingut o redirect https segur |
| E3 | `/portal/personal-data` | Stub (EHR-3.4 diferit) |
| E4 | `dpa_platform` | No a l’allowlist |

---

## Verificacions tècniques ràpides (opcional)

```sql
-- Filtres de retenció presents al cos de les funcions
select proname, position('retention_status' in pg_get_functiondef(oid)) > 0 as has_retention
from pg_proc
where pronamespace = 'api'::regnamespace
  and proname in (
    'resolve_customer_portal_share_session',
    'exchange_customer_portal_staff_session'
  );
```

Staff report-scoped: després de `00047`, la branca `report_version_id IS NOT NULL` ha de filtrar `COALESCE(retention_status,'active')='active'`.

---

## Gaps coneguts (no fallar la prova com a “bug nou”)

| Gap | Estat |
|-----|--------|
| Editor/publish de mode `edited` | Diferit; UI bloqueja noves seleccions |
| DSAR UI demana UUID cru | Mínim viable; millorable amb cercador de contactes |
| Retenció UI read-only | Settings/purge via jobs; no edició des de Legal |
| Self-service PII empleat complet | Stub; pla EHR-3.4 |
| CMP / cookies no essencials | LC-5 📦 |
| Preview Legal Settings | Sanititzat amb DOMPurify (post-QA) |

---

## Ordre de smoke suggerit (30–45 min)

1. Migració `00047` aplicada.  
2. **A1–A7** (Legal + DPA + URL segura).  
3. **B1–B4** (CP share/dashboard).  
4. **C1–C4** (web + careers).  
5. **D2** si hi ha custom domain.  
6. **E1–E3** si hi ha empleat.  
7. **B7–B8** només si pots marcar una versió de prova com a no-`active`.

Marca cada fila ✅ / ❌ / N/A i anota tenantId, slug i locale usats.
