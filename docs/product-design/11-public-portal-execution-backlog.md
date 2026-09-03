# 11. Backlog Executable — Public Portal

> **Objectiu**: convertir el pla de `public-portal` en un backlog accionable per fases i tracks (migració SQL, backend, frontend), amb estimació d'esforç i dependències clares.

## 11.1 Scope V1

Inclòs:
- Landing pública multi-tenant per host (subdomini o domini propi)
- Publicació/despublicació de web
- SEO bàsic (metadata, canonical, sitemap, robots)
- Formularis públics de captació (`lead/contact`)
- Ingesta segura cap al tenant

Fora de V1:
- Builder visual avançat (drag-and-drop complex)
- Motor de reserves avançat i integracions OTA

## 11.2 Decisions Tècniques (fixades)

- **Framework**: Next.js (app pública amb SSR/ISR i resolució per host)
- **Hosting**: Vercel
- **DNS**: Cloudflare
- **Patró de seguretat**: entrada pública només via endpoint server-side + antiabús + cues asíncrones
- **Permisos**: model existent `data.*` + `api.*` + RLS amb `jwt_user_tenants()`

## 11.3 Fases i Backlog Executable

## Fase 0 — Preparació i Contracte

**Objectiu**: tancar arquitectura i criteris de seguretat abans de codificar.

Tasques:
1. Escriure ADR curt amb decisions finals (`framework`, `hosting`, `dominis`, `ingesta`).
2. Definir contracte funcional V1 (què és publicable i què no).
3. Definir criteris de dades públiques permeses/prohibides.

Estimació:
- Migració SQL: **0.5-1 dia**
- Backend: **1-1.5 dies**
- Frontend: **0.5-1 dia**

Dependència:
- Bloquejant per totes les fases següents.

## Fase 1 — Model SQL + Auditoria

**Objectiu**: crear la base de dades del mòdul públic.

Tasques:
1. Crear taules:
- `data.public_sites`
- `data.public_pages`
- `data.public_domains`
- `data.public_leads`
- `data.public_domain_events`
2. Definir constraints i índexs:
- host únic actiu
- ruta única per `public_site`
- `primary_domain` únic
3. Afegir triggers d'auditoria amb `data.log_audit_event()`.
4. Regenerar tipus `Database`.

Estimació:
- Migració SQL: **2-3 dies**
- Backend: **0.5-1 dia**
- Frontend: **0.5 dia**

Dependència:
- Requereix Fase 0 completada.

## Fase 2 — RLS + API + RPC Lifecycle

**Objectiu**: exposar gestió segura per tenants i bloquejar escriptura anon directa.

Tasques:
1. Activar RLS a taules noves amb patró existent.
2. Crear vistes `api.*` amb `security_invoker = true`.
3. Crear RPCs de cicle de vida:
- `api.create_public_site`
- `api.publish_public_site`
- `api.attach_public_domain`
- `api.verify_public_domain`
- `api.promote_lead_to_contact`
4. Definir grants mínims (`authenticated`, `service_role`) i denegar accés indegut.

Estimació:
- Migració SQL: **2-3 dies**
- Backend: **1-1.5 dies**
- Frontend: **1 dia**

Dependència:
- Requereix Fase 1.

## Fase 3 — App public-portal + SEO Runtime

**Objectiu**: servir webs públiques multi-tenant de forma indexable.

Tasques:
1. Crear `apps/public-portal`.
2. Implementar resolució tenant per `Host` header.
3. Render SSR/ISR de pàgines públiques.
4. SEO tècnic:
- metadata dinàmica
- `canonical`
- `sitemap.xml`
- `robots.txt`
5. `404` i fallback de tenant no resolt.

Estimació:
- Migració SQL: **0 dies**
- Backend: **1-1.5 dies**
- Frontend: **3-4 dies**

Dependència:
- Requereix contractes de Fase 2 estables.

## Fase 4 — Subdominis i Dominis Propis

**Objectiu**: automatitzar publicació en subdomini i domini custom.

Tasques:
1. Configurar wildcard DNS (`*.public.<domini>`) a Cloudflare cap a Vercel.
2. Resoldre `slug -> host` per subdomini.
3. Flux domini propi:
- `pending -> dns_verified -> ssl_active`
4. Verificació DNS periòdica (Edge Function/cron).
5. Registrar events a `public_domain_events`.
6. Forçar redirecció `301` canònica.

Estimació:
- Migració SQL: **0.5-1 dia**
- Backend: **2-3 dies**
- Frontend: **1-1.5 dies**

Dependència:
- Requereix Fase 3 base en funcionament.

## Fase 5 — Ingesta Segura de Visitants

**Objectiu**: captació pública robusta i segura, integrada al tenant.

Tasques:
1. Endpoint server-side únic per formularis.
2. Controls antiabús obligatoris:
- validació `zod`
- CAPTCHA (Turnstile)
- honeypot
- rate limit per IP/host
- idempotency key
3. Sanitització i política RGPD de metadades tècniques.
4. Persistir a `data.public_leads`.
5. Encua processament asíncron (PGMQ) per notificacions.

Estimació:
- Migració SQL: **0.5-1 dia**
- Backend: **3-4 dies**
- Frontend: **1-1.5 dies**

Dependència:
- Requereix Fase 3 i Fase 4 mínimament operatives.

## Fase 6 — Integració amb tenant-portal i admin-portal

**Objectiu**: operar el mòdul públic des de portals existents.

Tasques:
1. `tenant-portal`:
- configuració web pública
- SEO
- dominis
- publicació
- gestió de leads
2. `admin-portal`:
- observabilitat global dominis/leads
- alertes verificació/abús
- suport d'operació
3. Activació per addon via `hub-and-spoke`.

Estimació:
- Migració SQL: **0.5 dia**
- Backend: **2-3 dies**
- Frontend: **3-4 dies**

Dependència:
- Requereix Fases 2-5 estables.

## Fase 7 — QA, Rollout i Operació

**Objectiu**: sortir a producció amb control de risc.

Tasques:
1. Test matrix:
- RLS (`anon/authenticated/service_role`)
- resolució host/subdomini/custom domain
- SEO indexació
- antiabús i idempotència
- pipeline deploy tercera app
2. Rollout:
- pilot intern (1-2 tenants)
- beta controlada (5-10 tenants)
- GA progressiu
3. Runbook incidències i monitoratge.

Estimació:
- Migració SQL: **0 dies**
- Backend: **1-2 dies**
- Frontend: **1-2 dies**

Dependència:
- Requereix totes les fases anteriors.

## 11.4 Estimació Agregada V1

Per track:
- Migració SQL: **6-9 dies**
- Backend: **11-17 dies**
- Frontend: **11-16 dies**

Calendari orientatiu:
- Equip petit (2 perfils fullstack): **5-8 setmanes**
- Treball en paral·lel per tracks (3 fronts): **4-6 setmanes**

## 11.5 Dependències i Paral·lelisme

Bloquejants:
1. `Fase 0 -> Fase 1 -> Fase 2`

Paral·lelitzables:
1. Frontend shell de Fase 3 en paral·lel quan Fase 2 fixa contractes de lectura.
2. Fase 4 i Fase 5 poden avançar parcialment en paral·lel després de Fase 3.

## 11.6 Definition of Done (DoD)

Per fase:
1. Migració: aplicada localment, constraints i triggers validats, tipus regenerats.
2. Backend: endpoints/RPC validats amb casos límit i autorització.
3. Frontend: flux d'usuari complet, i18n i tests mínims.
4. Operació: mètriques visibles i runbook publicat.

## 11.7 Riscos Principals i Mitigació

1. **Risc DNS/SSL lent en dominis propis**
- Mitigació: estat visual clar, retries i fallback temporal a subdomini.

2. **Risc d'abús en formularis públics**
- Mitigació: CAPTCHA + rate-limit + honeypot + idempotència + cues.

3. **Risc de regressions en RLS**
- Mitigació: tests de polítiques i checklist de permisos abans de cada release.

4. **Risc SEO per contingut duplicat**
- Mitigació: canonical + redireccions 301 + sitemap per host canònic.
