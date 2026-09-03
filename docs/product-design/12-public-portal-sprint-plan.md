# 12. Sprint Plan — Public Portal V1

> **Objectiu**: convertir el backlog executable en una planificació setmanal amb entregables verificables, responsables per track i criteris d'acceptació.

## 12.1 Supòsits de planificació

- Durada sprint: **1 setmana**
- Equip base:
  - **SQL/Platform** (migracions, RLS, API/RPC)
  - **Backend** (runtime públic, domini, ingestes segures, workers)
  - **Frontend** (UI tenant/admin, UX de publicació, leads)
- Entorns: local + staging + producció
- Release strategy: pilot intern abans de beta

## 12.2 Timeline proposat (6 sprints)

## Sprint 1 — Contracte i Fonaments de Dades

Objectiu:
- Tancar decisions V1 i crear model SQL mínim amb auditoria.

Backlog sprint:
1. ADR final public-portal (arquitectura, seguretat, hosting, DNS).
2. Migració SQL:
- `data.public_sites`
- `data.public_pages`
- `data.public_domains`
- `data.public_leads`
- `data.public_domain_events`
3. Constraints/índexs de consistència.
4. Triggers d'auditoria amb `data.log_audit_event()`.
5. Regeneració de `database.types.ts` (apps + edge shared).

Responsable principal:
- SQL/Platform

Dependències:
- Cap (sprint inicial)

Acceptance criteria:
1. Migració aplicada en local sense drift.
2. Taules i índexs validats amb casos de prova mínims.
3. Esdeveniments d'auditoria escrits a `data.audit_logs`.
4. Tipus regenerats en ambdós fitxers obligatoris.

## Sprint 2 — RLS, Vistes API i RPCs de Lifecycle

Objectiu:
- Exposar el mòdul públic amb permisos segurs multi-tenant.

Backlog sprint:
1. RLS complet a totes les taules noves.
2. Vistes `api.*` amb `security_invoker = true`.
3. RPCs:
- `api.create_public_site`
- `api.publish_public_site`
- `api.attach_public_domain`
- `api.verify_public_domain`
- `api.promote_lead_to_contact`
4. Grants mínims (`authenticated`/`service_role`) i revokes necessaris.
5. Test matrix de polítiques (`anon`, `authenticated`, `service_role`).

Responsable principal:
- SQL/Platform

Dependències:
- Sprint 1 complet

Acceptance criteria:
1. No existeix escriptura anon directa a `data.*`.
2. Només membres del tenant poden operar sobre el seu `public_site`.
3. Les RPCs retornen errors controlats en accessos il·lícits.
4. Tests de seguretat bàsics en staging en verd.

## Sprint 3 — Runtime Next.js Públic i SEO Tècnic

Objectiu:
- Posar en marxa `apps/public-portal` amb render per host i SEO base.

Backlog sprint:
1. Scaffold de `apps/public-portal` (Next.js).
2. Resolució tenant per `Host` header.
3. Render SSR/ISR de pàgines publicades.
4. SEO:
- metadata dinàmica
- canonical
- `sitemap.xml`
- `robots.txt`
5. Gestió d'errors (`404` tenant no resolt / pàgina no publicada).

Responsable principal:
- Backend + Frontend

Dependències:
- Sprint 2 per contractes de lectura estables

Acceptance criteria:
1. Un subdomini vàlid resol contingut correcte del tenant.
2. Un host desconegut retorna error controlat.
3. Sitemap i robots són funcionals per host canònic.
4. Lighthouse SEO baseline acceptable per landing principal.

## Sprint 4 — Subdominis, Dominis Propis i Canonicalització

Objectiu:
- Fer operatiu el flux de domini propi de cap a cap.

Backlog sprint:
1. Wildcard DNS configurat (`*.public.<domini>`).
2. Mapeig `slug -> host` amb fallback a subdomini.
3. Flux d'estat domini:
- `pending`
- `dns_verified`
- `ssl_active`
4. Verificació DNS periòdica via worker/cron.
5. Registre d'events a `public_domain_events`.
6. Redireccions 301 cap a host canònic.

Responsable principal:
- Backend

Dependències:
- Sprint 3 complet

Acceptance criteria:
1. Subdomini funciona automàticament sense pas manual.
2. Domini propi transiciona d'estat correctament.
3. SSL actiu i navegació segura en domini propi.
4. No hi ha contingut duplicat entre hosts (301 + canonical).

## Sprint 5 — Ingesta Segura de Leads + Asíncron

Objectiu:
- Permetre entrada de visitants amb controls antiabús i pipeline asíncron.

Backlog sprint:
1. Endpoint server-side únic de formulari públic.
2. Antiabús obligatori:
- `zod`
- Turnstile
- honeypot
- rate-limit per IP/host
- idempotency key
3. Persistència a `data.public_leads`.
4. Encolat PGMQ per notificacions/processat.
5. Observabilitat d'errors i mètriques bàsiques.

Responsable principal:
- Backend

Dependències:
- Sprint 3 i Sprint 4

Acceptance criteria:
1. Formulari vàlid crea lead una sola vegada (idempotència).
2. Tràfic sospitós queda bloquejat o limitat.
3. Missatges de cua es processen i deixen traça observable.
4. No s'exposa informació sensible al payload d'auditoria.

## Sprint 6 — Integració Portals + QA Final + Rollout

Objectiu:
- Governar el mòdul des de tenant/admin portal i sortir a pilot.

Backlog sprint:
1. `tenant-portal`:
- configuració web pública
- SEO
- dominis
- publicació
- leads
2. `admin-portal`:
- observabilitat global
- alertes de verificació/abús
3. Activació via addon (`hub-and-spoke`).
4. QA final E2E + regressió permisos.
5. Pilot intern i runbook operatiu.

Responsable principal:
- Frontend + Backend

Dependències:
- Sprints 1-5

Acceptance criteria:
1. Tenant pot publicar/despublicar sense intervenció manual.
2. Admin pot monitoritzar incidències de domini i leads.
3. Test crítics en verd (RLS, host routing, antiabús, SEO).
4. Pilot intern amb 1-2 tenants completat.

## 12.3 Capacitat i estimació per sprint

Estimació orientativa per sprint (dies efectius):
1. Sprint 1: **4-6 dies**
2. Sprint 2: **4-6 dies**
3. Sprint 3: **5-7 dies**
4. Sprint 4: **4-6 dies**
5. Sprint 5: **4-6 dies**
6. Sprint 6: **5-7 dies**

Total orientatiu:
- **26-38 dies efectius**
- Equivalent a **6 setmanes** en ritme setmanal amb marge curt de risc

## 12.4 Riscos de calendari

1. **Dependència externa DNS/SSL**
- Impacte: pot bloquejar tancament d'Sprint 4
- Contenció: proveir fallback estable en subdomini

2. **Complexitat real de RLS en casos límit**
- Impacte: pot estendre Sprint 2
- Contenció: test matrix des del primer dia de l'sprint

3. **Falsos positius antiabús**
- Impacte: pot penalitzar conversió en Sprint 5
- Contenció: tuning gradual i feature flag per host

## 12.5 Definition of Ready (DoR) per sprint

1. Històries amb owner i criteris d'acceptació clars.
2. Dependències del sprint anterior tancades.
3. Entorn staging disponible amb secrets configurats.
4. Pla de proves mínim definit abans de començar implementació.

## 12.6 Definition of Done (DoD) transversal

1. Codi/migracions en branch amb revisió completada.
2. Validació local + staging satisfactòria.
3. Auditoria i permisos revisats.
4. Documentació operativa actualitzada (runbook/changelog).
5. Monitoratge mínim actiu per la funcionalitat nova.
