# Portal empleat — Millores d'accés, distribució i PIN (v2)

> **Data:** 2026-07-10 · **Actualitzat:** 2026-07-13  
> **Estat:** **implementat** — EP-ACC-1…9 + 3b; smoke hub [`ep-acc8-hub-smoke-checklist.md`](./ep-acc8-hub-smoke-checklist.md); pendent docs arquitectura §8 i ST-0 (estacions)  
> **Continuació de:** [`plan-employee-portal.md`](./plan-employee-portal.md) (EP3 gestió tokens)  
> **Arquitectura:** [`18-employee-portal-architecture.md`](../../product-design/18-employee-portal-architecture.md)  
> **Estacions (futur):** [`15-time-attendance-architecture.md`](../../product-design/15-time-attendance-architecture.md) §15.6 · doc 16 §`attendance_devices` · [`plan-attendance-stations.md`](./plan-attendance-stations.md)  
> **Mapa global:** [`STATUS.md`](./STATUS.md)  
> **Batch (detall):** [`plan-employee-portal-token-batch.md`](./plan-employee-portal-token-batch.md)  
> **Hub UX /employees:** [`plan-employees-portal-access-tab.md`](./plan-employees-portal-access-tab.md) — **✅ implementat (EP-ACC-8 + 9)**

### Resum executiu

EP0–EP9 han lliurat el portal funcional (fitxar, horari, absències, etc.). **Aquest pla v2 (EP-ACC-1…9 + 3b) està implementat al codi** (tenant-portal, public-portal, Edge i migracions SQL). La gestió administrativa de l'accés inclou: modal contextual, correu amb QR CID, impressió/export, PIN empleat + lockout, reset PIN, sessió compartida endurida, límit 1 enllaç per tipus, resolució multi-site, **generació massiva** des del hub «Accés al portal», **Identity Gate DNI** al primer accés i **hub de resum** per empleat.

**Pendent de tancar (no bloqueja ús):** smoke E2E manual §3 hub (generar lot des del navegador), actualització `18-employee-portal-architecture.md` §8, i el camí cap a **estacions** (ST-0 → implementació).

Aquest pla defineix millores **per fases** al tenant-portal i al public-portal, i deixa explícita la **separació de producte** entre:

| Canal | Propòsit | Identitat |
|-------|----------|-----------|
| **Portal personal** (`/e/{secret}`) | Consulta + fitxar des del **mòbil personal** (o enllaç reobert) | Token per empleat, sessió curta |
| **Estació de fitxatge** (`attendance_devices`) | Fitxar **només** des d'una **ubicació** de l'empresa | Dispositiu + token d'identitat curt (QR/barcode servidor) |

**Decisió estratègica:** no invertir en un «mode quiosc escàner» dins el portal. Els QR de vestuari/taulell compartit evolucionaran cap al pla d'**estacions** (fitxatge per ubicació). EP-ACC-1…7 i 3b milloren l'experiència actual sense bloquejar estacions.

---

## 0. Estat d'implementació (2026-07-13)

| Fase | Estat | Notes |
|------|-------|-------|
| **EP-ACC-1** | ✅ | Modal contextual Personal vs taulell; secret eliminat de la UI |
| **EP-ACC-7** | ✅ | `20260925000001` — 1 actiu per tipus, supersede automàtic |
| **EP-ACC-2a** | ✅ | `resolve_public_site_for_employee` + hook client; fix admin sense exigir web corporativa publicada |
| **EP-ACC-5** | ✅ | `20260925000003` — shared: sense refresh, idle, caducitat absoluta |
| **EP-ACC-4** | ✅ | `20260925000004` — `pin_must_set`, setup/change al portal |
| **EP-ACC-4a** | ✅ | Mateixa migració — lockout atòmic |
| **EP-ACC-2** | ✅ | `20260925000005` — plantilla correu, CID QR, regenerar i enviar |
| **EP-ACC-3** | ✅ | `portalQrPrint.ts`, `portalLabelExport.ts` — imprimir i CSV (1 empleat) |
| **EP-ACC-4b** | ✅ | `20260926000001` — reset PIN `/e/pin-reset/{secret}` |
| **EP-ACC-6** | ✅ | UI «Taulell compartit (temp.)» + enllaç pla estacions |
| **EP-ACC-3b-prep** | ✅ | `20260927000001` — batch jobs/items, RPCs, tests B-T1…B-T9 |
| **EP-ACC-3b** | ✅ | UI bulk al hub `/employees?tab=portal_hub`, export CSV/QR, banner recuperació 1h |
| **EP-ACC-8** | ✅ | Hub «Accés al portal» — [`plan-employees-portal-access-tab.md`](./plan-employees-portal-access-tab.md) · RPC `list_employee_portal_access_overview` · smoke [`ep-acc8-hub-smoke-checklist.md`](./ep-acc8-hub-smoke-checklist.md) |
| **EP-ACC-9** | ✅ | Identity Gate DNI obligatori — mateix pla §13 · tests I-T* |
| **ST-0** | 📋 | [`plan-attendance-stations.md`](./plan-attendance-stations.md) — esbòs, sense codi |
| **Bulk email** | ⏳ | Fora d'abast 3b; requereix anàlisi throughput (§10) |
| **Docs §8** | ⏳ | Actualitzar `18-employee-portal-architecture.md`, `STATUS.md` |

**Correccions post-lliurament 3b (2026-07-13):**

- URL batch: mateix fallback que el flux individual (`VITE_PUBLIC_PORTAL_BASE_URL` o `http://localhost:3002`); el portal d'empleat **no** depèn de tenir web corporativa publicada.
- Textos UI: «Accés al portal (massiu)», equivalència amb pestanya «Accés Portal».
- Modal resultats: estats traduïts, export visible, recuperació del lot no s'esborra en tancar el modal.

**Com validar (smoke ràpid):**

1. Tenant-portal: empleat → pestanya «Accés Portal» → crear enllaç, correu, imprimir.
2. `/employees?tab=portal_hub` → seleccionar empleats → generar → CSV / copiar / imprimir.
3. Tancar modal resultats → banner «Recuperar lot» durant 1h (només al hub).
4. Public-portal: primer accés DNI → confirmació → PIN setup; lockout; taulell compartit sense Identity Gate.

Checklist complet: [`ep-acc8-hub-smoke-checklist.md`](./ep-acc8-hub-smoke-checklist.md).

---

## 1. Problemes i buits actuals (baseline pre-v2)

> Taula històrica: descriu l'estat **abans** d'EP-ACC. La majoria de files estan resoltes; veure §0.

| Àrea | Avui | Problema |
|------|------|----------|
| Modal «Enllaç generat» | URL + secret + QR igual per tots els casos | Secret redundant; no adaptat a Personal vs QR taulell |
| Distribució | Copiar manualment | Sense correu, sense plantilla, sense impressió massiva |
| PIN | Manager el defineix en crear el token | L'empresa coneix el PIN; si l'oblida l'empleat → revocar i nou enllaç |
| Sessió compartida | JWT 15 min + refresh automàtic cada 11 min | Si ningú tanca la pestanya, la sessió es **renova sola** |
| `shared_device` | Canvia outbox (sessionStorage vs IndexedDB) | No tanca sessió; confús vs estacions; mal configurat amb tipus «Personal» a tablet |
| **Multi-site** | `usePublicSite` agafa el **primer** `public_site` del tenant | URL/QR/domini **incorrectes** si l'empleat pertany a un altre local |
| **PIN — força bruta** | `pin_attempts`/`pin_locked_until` existeixen a l'esquema però **no s'usen enlloc** | `POST /session` accepta intents de PIN il·limitats contra el mateix secret sense fricció |
| **Enllaços actius sense límit** | Cap restricció més enllà de `(employee_id, label)` | Un empleat pot acumular N tokens Personal/QR taulell actius sense revocació; s'agreujaria amb bulk (EP-ACC-3b) |
| Estacions | `attendance_devices` a BD, UI/Edge **no implementats** | STATUS: `punch-from-station` ❌, `StationPage` ❌ |

---

## 2. Decisions de producte (tancades abans d'implementar)

### D1 — Eliminar el camp «Secret» de la UI

El secret **és** el fragment `/e/{secret}` de la URL. No cal mostrar-lo mai al manager de producció. Eliminar de `PortalTokenRevealDialog` (ja ocult en prod; **eliminar definitivament** inclòs dev, excepte seeds documentats).

### D2 — Modal contextual segons tipus d'enllaç

| Tipus en crear | Modal prioritza | URL |
|----------------|-----------------|-----|
| **Personal** | URL + botó «Copiar» + QR secundari (WhatsApp / imprimir) | Destacada |
| **QR taulell** | QR gran + nom empleat + instruccions breus | Informativa (peu o desplegable) |

El tipus es decideix **en crear** (`shared_device`); el modal rep `sharedDevice: boolean` del flux de creació.

### D3 — PIN propietat de l'empleat (model objectiu)

| Mode | Qui defineix el PIN | Tenant el coneix? | Recuperació |
|------|---------------------|-------------------|-------------|
| **A — Manager** (legacy, deprecar) | RRHH en crear enllaç | Sí (ho introdueix) | Nou enllaç o reset manual manager |
| **B — Empleat primer accés** (per defecte nou) | Empleat al primer `POST /session` | **No** | Canvi des del portal; reset per correu |
| **C — Sense PIN** | — | — | Només amb avís explícit (ja existeix) |

**Per defecte nou:** mode B si la política tenant `employee_portal.default_pin_required` és activa. En el contracte de sessió, `pin_required` passa a significar «aquest token requereix PIN» i es calcula com `(pin_hash IS NOT NULL OR pin_must_set)`, no només a partir de `pin_hash`.

Flux mode B:

1. Manager crea enllaç **sense** camp PIN (o checkbox «L'empleat definirà el PIN al primer accés»).
2. BD: `pin_hash IS NULL` + `pin_must_set = true` (columna nova).
3. Primer accés: `POST /session` retorna `403 pin_setup_required`; la pantalla «Defineix el teu PIN» envia `secret + pin nou + confirmació` a `POST /pin/setup` **sense sessió prèvia**.
4. `pin_hash` es desa; tenant **mai** rep el valor en clar.
5. Portal: secció «Seguretat» → «Canviar PIN» (PIN actual + nou).
6. Sense correu: canvi només des del portal mentre la sessió és vàlida; si oblida PIN **i** no té sessió → manager envia **enllaç de restabliment PIN** (no revocar token) o revoca i genera enllaç nou (últim recurs).

**Contracte primer setup (obligatori):**

- Ordre de routing obligatori: si `pin_must_set = true`, retornar sempre `pin_setup_required`; no entrar al flux de validació de PIN existent encara que `pin_required = true`.
- `POST /pin/setup` s'autoritza amb el secret d'alta entropia del portal, no amb una sessió que encara no existeix.
- L'RPC fa un únic `UPDATE ... WHERE token_hash = ? AND pin_must_set AND pin_hash IS NULL AND is_active AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > now()) RETURNING ...`; només el primer intent concurrent pot establir el PIN.
- En èxit: desa `pin_hash`, posa `pin_must_set = false`, `pin_set_at = now()`, `pin_set_by = 'employee'`, reinicia lockout i emet la primera sessió.
- `POST /pin/change` és un flux diferent: exigeix sessió activa, PIN actual i PIN nou.
- Els lookup/session RPC han de retornar separadament `pin_required`, `pin_must_set`, `pin_attempts` i `pin_locked_until`.

**Nota sobre el model de seguretat del PIN:** el PIN **no és** l'únic factor — cal conèixer també el secret de l'URL (`/e/{secret}`), que actua com a primer factor de possessió. El PIN és una barrera addicional pensada per al cas «algú intercepta o reobre l'enllaç», no un sistema d'autenticació autònom. Amb aquesta premissa, el hash SHA-256 actual (`hashPortalPin`, sense sal, format `sha256:{hex}`) és **acceptable** per V1: no cal migrar a bcrypt/argon2 — seria sobreenginyeria per protegir un PIN de 4–6 dígits que ja depèn d'un secret d'alta entropia com a primer factor. **El que sí cal corregir és el control d'intents (lockout)**, ja que avui no hi ha cap fricció davant d'intents il·limitats de PIN contra un secret conegut (veure D3b).

### D3b — Lockout de PIN (nou, obligatori amb mode B)

**Problema concret:** les columnes `pin_attempts` i `pin_locked_until` ja existeixen a `data.employee_portal_tokens` i a la vista administrativa, però els lookup RPC de sessió no les retornen i `session-service.ts` no les incrementa ni les comprova. Avui `POST /session` accepta intents de PIN il·limitats contra el mateix secret sense cap penalització. Amb el mode B (empleat defineix el seu propi PIN, sense que el manager el conegui), aquest control esdevé més necessari, no menys: és l'única xarxa de seguretat si el secret es filtra.

**Disseny mínim (V1, sense infraestructura nova):**

1. A cada intent fallit de PIN (`pin_invalid`): `pin_attempts := pin_attempts + 1`. A cada intent correcte: reset a `0`.
2. Llindar: **5 intents fallits consecutius** → `pin_locked_until := now() + interval '15 minutes'`.
3. `createPortalSession`, el refresh d'una sessió JWT ja expirada i `POST /pin/change` comproven `pin_locked_until` **abans** de validar el PIN actual; si és futur → `423 pin_locked`, cos amb `retry_after_seconds` i capçalera `Retry-After`.
4. El comptador i el bloqueig van lligats al **token** (secret), no a IP — coherent amb el fet que qui té el secret ja ha superat el primer factor; no cal infraestructura de rate-limit per IP per aquesta V1 (evitem sobreenginyeria simètrica a l'anterior). Es pot revisar en una fase posterior si es detecta abús distribuït.
5. Validació, increment/reset i bloqueig es fan dins una única RPC service-role (`employee_portal_attempt_pin` o equivalent), amb lock de la fila del token. L'Edge envia el hash candidat i rep un resultat (`ok`, `invalid`, `locked`); no fa un `SELECT` i un `UPDATE` separats.
6. Si `pin_locked_until` ja ha passat, la mateixa RPC reinicia `pin_attempts` abans de comptar el nou intent.
7. Access log: registrar `pin_locked` com a nova `action` a més de `pin_failed` (ja existent), ampliant també el `CHECK` SQL d'accions permeses.

**Acceptació:**

- [ ] 5 PIN incorrectes consecutius → sessió bloquejada 15 min encara que el PIN correcte s'introdueixi durant el bloqueig.
- [ ] PIN correcte abans d'arribar al llindar → comptador es reinicia a 0.
- [ ] `pin_locked_until` passat → intents es tornen a comptar des de 0.
- [ ] Intents de PIN actual a `/pin/change` i reautenticació d'un JWT expirat comparteixen comptador/lockout amb `/session`.
- [ ] Missatge UI clar («Massa intents. Torna-ho a provar d'aquí X minuts») al public-portal.

### D4 — Sessió en dispositiu compartit

| Mesura | Personal | QR taulell (interí) | Estació (futur) |
|--------|----------|---------------------|-----------------|
| Auto-refresh sessió | Sí (11 min) | **No** | N/A (sessió dispositiu) |
| Botó «Sortir» visible | Opcional menú | **Obligatori** post-fitxatge | Flux estació |
| Idle timeout UI | No | **10 min** configurable sense interacció → logout | Config estació |
| Cookie al tancar pestanya | Persisteix fins `maxAge` | **Persisteix fins `maxAge`**; tancar pestanya no és logout | — |

**Problema actual:** `PortalSessionRefresh` renova la cookie indefinidament mentre la pestanya és oberta → en tablet compartida, l'empleat B podria veure la sessió de A si A no ha fet logout.

**EP-ACC-5:** si `shared_device` al token de sessió → desactivar interval de refresh; mostrar banner «Torna a escanejar el teu QR quan acabis»; botó «He acabat» que crida `POST /portal/api/session/logout` i neteja només les claus/outbox del portal a `sessionStorage`.

La protecció **no pot dependre només del client** (`isPortalSharedDevice()` és una dada de `sessionStorage` manipulable). L'Edge/proxy ha d'aplicar una caducitat absoluta de 15 min als tokens `shared_device` i rebutjar-ne la renovació; `GET /session/me` no pot renovar la cookie en aquest mode. El timeout UI desa `last_activity_at` i, quan una pestanya suspesa torna a primer pla, comprova el temps transcorregut abans de renderitzar dades.

La caducitat absoluta s'ancora a l'`iat` del JWT emès a `session_create`; en mode shared aquest JWT no es reemet. En obrir una pestanya sense el marcador `shared_session_active` de `sessionStorage`, el layout queda bloquejat mentre consulta `/session/me`: si el servidor identifica una sessió shared residual, executa logout abans de renderitzar dades i exigeix tornar a escanejar. Així, tancar/reobrir pestanya no reutilitza la sessió d'un altre empleat encara que la cookie persisteixi.

Els settings públics del portal no es llegeixen directament amb els hooks autenticats del tenant-portal. EP-ACC-5 afegeix un endpoint/RPC de política mínim, llegit amb service role durant el bootstrap, que només exposa valors segurs (`default_pin_required`, `shared_device_idle_timeout_minutes`) i els inclou en el payload de sessió.

### D5 — Tablet amb enllaços «Personal» (anti-patró)

Si el manager deixa bookmarks o enllaços tipus Personal en una tablet compartida:

- IndexedDB conserva outbox d'empleats anteriors.
- La cookie de sessió pot persistir (mateix origen).
- **Risc:** fitxatge o dades visibles creuades.

**Accions:**

1. Avís al crear enllaç Personal si el label conté «taulell», «tablet», «quiosc» (heurística opcional).
2. Documentació i help text (ja parcialment fet).
3. No suportar oficialment aquesta configuració; estació futura és el camí correcte.

### D6 — «QR taulell» vs estacions de fitxatge

| Aspecte | Portal `shared_device` (interí) | Estació `attendance_devices` (objectiu) |
|---------|--------------------------------|----------------------------------------|
| URL | `/e/{secret}` per empleat | App estació a `/station` o similar |
| QR empleat | URL personal → portal complet | Token curt signat `issue_attendance_identity_token` |
| Ubicació | No vinculada | `site_id` + `location_id` obligatoris |
| Consultar horari | Sí | Opcional / política tenant |
| Fitxar | Sí (`source=portal`) | Sí (`source=station` o `qr`) |
| Escàner integrat | **No** (app QR del SO) | **Sí** (UI estació) |

**Decisió:** EP-ACC no implementa escàner dins el portal. El pla d'estacions (`plan-attendance-stations.md`, esbòs §8) cobrirà quiosc per ubicació. El flag `shared_device` es manté com a pont EP5 (outbox sessionStorage) fins que estacions absorbeixi el cas «tablet vestuari».

### D7 — Un enllaç actiu per tipus (Personal / QR taulell)

**Problema actual:** no hi ha cap límit d'enllaços actius per empleat; l'única restricció és unicitat per `(employee_id, label)` en tokens permanents etiquetats. Un empleat pot acumular N tokens `Personal` actius (p. ex. per reenviaments successius sense revocar l'anterior) sense que ningú se n'adoni, i EP-ACC-3b (generació massiva) agreujaria això si no es tanca abans.

**Decisió:** com a màxim **un token actiu de cada tipus** per empleat:

| `shared_device` | Significat | Màxim actius |
|------------------|------------|---------------|
| `false` (Personal) | Enllaç mòbil personal de l'empleat | **1** |
| `true` (QR taulell) | Enllaç interí de dispositiu compartit | **1** |

Un empleat pot tenir, alhora, **com a màxim 2 tokens actius en total**: 1 Personal + 1 QR taulell. Crear-ne un nou del mateix tipus **revoca automàticament** l'anterior actiu d'aquell tipus (no cal pas manual de «revocar abans de crear»); això també simplifica la UX (no calen dues accions) i evita enllaços «fantasma» oblidats.

**Implementació:** l'índex únic parcial definit canònicament a §4 complementa l'índex legacy per label; no cal eliminar aquest últim en V1.

Abans de crear l'índex, la migració ha de normalitzar duplicats existents: conservar el token més recent de cada `(employee_id, shared_device)` i revocar la resta amb `revoke_reason = 'superseded'` i increment de `session_version`.

`create_employee_portal_token` ha de fer, dins la mateixa transacció curta:

1. Adquirir un lock estable per `(employee_id, shared_device)` (`SELECT ... FOR UPDATE` sobre l'empleat o `pg_advisory_xact_lock`) per serialitzar creacions concurrents.
2. `UPDATE ... SET is_active = false, revoked_at = now(), revoke_reason = 'superseded', session_version = session_version + 1` sobre qualsevol token encara marcat actiu del mateix tipus, inclosos els caducats pendents del cron.
3. `INSERT` del nou token.

L'índex manté la invariant final, però no substitueix el lock. No s'ha d'afegir `expires_at > now()` al predicat de l'índex: `now()` no és immutable i Postgres no l'admet en expressions d'índex. La RPC allibera l'índex desactivant també les files caducades abans de l'insert.

**Acceptació:**

- [ ] Crear un 2n enllaç Personal per al mateix empleat revoca el 1r automàticament (UI ho indica: «S'ha revocat l'enllaç anterior»).
- [ ] Crear un enllaç QR taulell no afecta l'enllaç Personal actiu (i viceversa).
- [ ] Bulk (EP-ACC-3b) respecta el mateix límit per cada empleat del lot.
- [ ] Test de concurrència: dues creacions simultànies del mateix tipus pel mateix empleat no deixen dos tokens actius.

**Preparació per estacions (sense implementar ara):**

- `time_punch.source` ja inclou `portal`, `station`, `qr`.
- Doc 15 defineix `api.issue_attendance_identity_token` / `resolve_attendance_identity_token`.
- Portal token i station token **no han de compartir** el mateix secret.
- Setting futur: `employee_portal.allow_punch_only_from_stations` → portal en mode lectura fora estació (opcional, estudiar a pla estacions).

### D8 — Multi-site: plantilles tenant, branding i URL per site

El tenant pot tenir **múltiples locals** (`data.sites`) i **múltiples portals públics** (`data.public_sites`: un global `site_id NULL` i/o un per site físic). L'empleat té `employees.site_id`.

**Tres capes diferents:**

| Capa | Abast avui | Comportament objectiu EP-ACC |
|------|------------|------------------------------|
| **Text plantilla correu** | **Tenant** (1 override per `event_type`) | Mateix text per a tot el tenant; el tenant clona la plantilla de plataforma una vegada |
| **Branding correu** (remitent, logo, layout) | **Site** via `enqueue_email(site_id)` | Passar `employee.site_id` → cascada `sites.email_*` → tenant → plataforma (ja implementada) |
| **URL del portal** (`/e/{secret}`) | **Bug:** primer `public_site` del tenant | Resoldre per `employee.site_id` → veure EP-ACC-2a |

**No cal** (V1): plantilles de correu per site (`email_templates` no té `site_id`). Si un local necessita instruccions molt diferents, el tenant pot usar variables Liquid (`{{site_name}}`) o una plantilla standalone sense `event_type` seleccionable manualment al modal.

> **Advertència de nomenclatura:** `data.sites` conté el local físic i el branding (`sites.email_*`); `data.public_sites` conté URL/domini/slug del portal. Són registres i configuracions diferents, però **sí** estan vinculats per FK (`public_sites.site_id → sites.id`). Un canvi de branding del local no canvia automàticament slug/domini del portal, i viceversa.

**Resolució URL** (`resolvePublicSiteForEmployee`):

```
1. SELECT public_sites WHERE tenant_id = ? AND site_id = employee.site_id
2. Si no trobat → public_site global (site_id IS NULL) del mateix tenant
3. Només portals `status = 'published'`; un portal de site draft/suspended cau al global publicat
4. Domini: `primary_domain_id` si apunta a un domini `ssl_active`; si no, domini SSL actiu determinista; si no, subdomini sistema
5. Slug: public_site.slug per subdomini sistema ({slug}.public.{domain})
```

**Escenaris:**

| Configuració | URL | Correu (branding) | Plantilla text |
|--------------|-----|-------------------|----------------|
| 1 portal global, N sites | Global per a tothom | Per site de l'empleat | 1 text tenant |
| Portal per site (Barcelona, Madrid) | Domini/slug del site de l'empleat | Per site | 1 text tenant + `{{site_name}}` |
| Empleat sense `site_id` | Portal global | Branding tenant | `tenant_name` |
| Site sense `public_site` propi | Fallback global + **avís UI** al manager | Branding del site físic (sites) | `site_name` del local |

**Tokens:** no cal `site_id` a `employee_portal_tokens`; l'empleat ja està vinculat i la URL és independent del token (mateix secret, mateix host resolt en generar/distribuir).

---

## 3. Eines administratives (tenant-portal)

### 3.1 Enviament per correu

**Event type:** `employee_portal.access_link`

**Plantilla de sistema** (seed migració, `tenant_id NULL`, `is_platform_default`):

Variables Liquid:

| Variable | Descripció |
|----------|------------|
| `employee_name` | Nom complet |
| `employee_first_name` | Primer nom (opcional) |
| `portal_url` | URL bootstrap (**resolta per site de l'empleat**, EP-ACC-2a) |
| `link_type` | `personal` \| `kiosk` |
| `pin_instructions` | Text segons mode PIN (manager / empleat / sense) |
| `tenant_name` | Nom del tenant |
| `site_name` | Nom del local (`sites.name`); buit si empleat sense site |
| `support_email` | `sites.email_reply_to` o reply-to del tenant |
| `expires_at` | Data caducitat o buit |

Contingut: instruccions curtes + botó URL + **imatge QR inline** com a attachment CID de Resend. El QR PNG es genera amb una llibreria TypeScript compatible amb Deno, es desa temporalment en un bucket privat i s'encua com `attachments: [{ filename, storage_path, content_type, content_id }]`. El worker recupera l'arxiu, el converteix a Base64 i l'envia a Resend amb `content_id`; la plantilla usa `src="cid:employee-portal-qr"`. No dependre de QuickChart ni d'URLs públiques temporals.

**Suport general d'attachments al worker Resend (inclòs a EP-ACC-2):**

1. `process-email-queue` valida que cada `storage_path` pertany al bucket privat autoritzat i descarrega l'arxiu amb service role.
2. Construeix `payload.attachments` de Resend amb `filename`, `content` Base64, `content_type` i `content_id` opcional.
3. Límits d'aplicació: màxim 10 attachments i 25 MiB totals abans de Base64 (per sota del límit Resend de 40 MB després de Base64); per al QR del portal, màxim 256 KiB.
4. Si falta o falla un attachment obligatori, el correu **no** s'envia degradat: queda en retry amb error explícit.
5. Els fitxers es mantenen mentre hi pugui haver retries i es purguen amb job de retenció després de 7 dies en estat terminal (`sent`/`failed`).
6. Tests del worker: attachment normal, CID inline, path no autoritzat, límit excedit, fitxer absent i retry idempotent.

**UI:**

- Al modal «Enllaç generat» → «Enviar per correu» mentre el secret encara és en memòria.
- A la fila d'un token actiu **no es pot reenviar el mateix URL**, perquè només se'n conserva el hash. L'acció s'anomena «Regenerar i enviar»: avisa que revocarà l'enllaç anterior del mateix tipus, crea el nou token i envia el correu en el mateix flux.
- Destinatari: email de l'empleat. Si és buit es demana; si el manager el modifica, cal confirmació explícita i registrar el destinatari real als logs/metadades d'auditoria.
- Plantilla: selector amb default `employee_portal.access_link` (resolució `event_type`: tenant publicat → fallback plataforma).
- Enviament via `api.enqueue_email` amb **`site_id: employee.site_id`** (branding i layout per local).
- Locale: `employee.preferred_locale` o default tenant (`ca`).

**Criteri:** tenant pot clonar i personalitzar plantilla **una vegada** a nivell tenant; el branding del correu es diferencia automàticament per site via `site_id` al payload.

### 3.2 Impressió QR amb nom

**Accions:**

- «Imprimir» → finestra `window.print()` amb layout A4: grid 2×4 o 3×5 de targetes (nom + QR + text «Escaneja per fitxar»).
- Un sol empleat des del modal; **bulk** des de llista d'empleats (fase posterior EP-ACC-3b).

Generació QR: **client-side** (`qrcode` npm) o Edge petita per PDF — evitar dependència externa QuickChart en producció.

### 3.3 Export etiquetes (Brother Q-800 i similars)

**Format CSV** (mínim viable):

```csv
employee_name,employee_code,portal_url,qr_payload,label
"Anna Garcia",EMP001,https://...,https://...,"WhatsApp"
```

- `qr_payload` = mateixa URL (impresores accepten camp URL o contingut QR).
- Opció **Excel** (.xlsx) mateixes columnes per usuaris no tècnics.
- Documentar a help: import a P-touch Editor / Brother iPrint&Label; **no** garantir compatibilitat binària `.lbx` en V1.

**Bulk:** tab empleats o informe «Exportar enllaços actius» filtrat per site/departament (només tokens actius no revocats — **problema:** URL no es pot regenerar; export només vàlid **just després de crear** o si es regenera enllaç). Per això el bulk export ha d'anar lligat a **generació massiva** o «rotar enllaços» amb avís.

**Decisió V1:** export CSV des del modal post-creació (1 empleat) i des del modal resultats batch (EP-ACC-3b). Cada fila bulk usa URL resolta per `employee.site_id` (EP-ACC-2a) amb fallback dev (`VITE_PUBLIC_PORTAL_BASE_URL`).

---

## 4. Canvis de model de dades (PIN)

```sql
-- data.employee_portal_tokens
ALTER TABLE data.employee_portal_tokens
  ADD COLUMN pin_must_set boolean NOT NULL DEFAULT false,
  ADD COLUMN pin_set_at timestamptz,
  ADD COLUMN pin_set_by text CHECK (pin_set_by IN ('manager', 'employee', 'reset'));

COMMENT ON COLUMN data.employee_portal_tokens.pin_must_set IS
  'True: primer accés obliga l''empleat a triar PIN abans de sessió.';

-- Lockout (D3b) — pin_attempts/pin_locked_until JA EXISTEIXEN (migració core) però sense ús.
-- No calen columnes noves; només lògica a l'RPC/Edge (veure D3b).

-- Límit d'enllaços actius per tipus (D7): normalitzar abans de crear l'índex.
WITH ranked AS (
  SELECT id,
         row_number() OVER (
           PARTITION BY employee_id, shared_device
           ORDER BY created_at DESC, id DESC
         ) AS rn
  FROM data.employee_portal_tokens
  WHERE is_active AND revoked_at IS NULL
)
UPDATE data.employee_portal_tokens t
SET is_active = false,
    revoked_at = now(),
    revoke_reason = 'superseded',
    session_version = t.session_version + 1
FROM ranked r
WHERE t.id = r.id
  AND r.rn > 1;

CREATE UNIQUE INDEX uq_employee_portal_tokens_active_per_type
  ON data.employee_portal_tokens (employee_id, shared_device)
  WHERE is_active AND revoked_at IS NULL;
```

**Settings a registrar (migració/seed):**

- `employee_portal.default_pin_required` — boolean, default `true`.
- `employee_portal.shared_device_idle_timeout_minutes` — integer, default `10`, rang admès `1..60`.

El public-portal no consulta el catàleg complet de settings: l'Edge resol només aquestes claus i les retorna en un payload de política allowlist.

**RPCs nous / canvis:**

| RPC | Canvi |
|-----|-------|
| `create_employee_portal_token` | `p_pin_hash` opcional; `p_pin_must_set` si sense hash i PIN requerit per política; **revoca l'actiu del mateix `shared_device` abans d'inserir (D7)** |
| `employee_portal_setup_pin` | Primer accés sense sessió: valida secret i estableix PIN una sola vegada amb `UPDATE ... WHERE pin_must_set AND pin_hash IS NULL` |
| `employee_portal_change_pin` | Amb sessió: valida PIN actual mitjançant la mateixa RPC de lockout i estableix el nou |
| `employee_portal_reset_pin_request` / `consume` | Propietat de la migració EP-ACC-4b: genera i consumeix token separat, curt, expirable i d'un sol ús |
| `employee_portal_attempt_pin` | Amb lock de fila: comprova `pin_locked_until`, compara hash candidat i incrementa/reseteja `pin_attempts` de forma atòmica (D3b) |
| `resolve_public_site_for_employee` | Font de veritat URL: només portals publicats i domini canònic |

**Edge `employee-portal-api`:**

- `POST /session`: comprova caducitat; si `pin_must_set` → `403 pin_setup_required`; si `pin_locked_until` futur → `423 pin_locked` (D3b).
- `POST /pin/setup` — primer accés, autoritzat pel secret, consum atòmic.
- `POST /pin/change` — requereix PIN actual i aplica el mateix lockout D3b.

---

## 5. Roadmap per fases

Ordenat per seqüència d'execució, no pel número de fase:

| Fase | Abast | Prioritat | Esforç | Estat |
|------|-------|-----------|--------|-------|
| **EP-ACC-1** | Modal contextual + eliminar secret + passar `sharedDevice` al reveal | P0 | S | ✅ |
| **EP-ACC-7** | Límit 1 enllaç actiu per tipus (Personal/QR taulell), revocació automàtica (D7) | P0 | S | ✅ |
| **EP-ACC-2a** | Resolució `public_site` + URL per `employee.site_id` (multi-site) | P0 | S | ✅ |
| **EP-ACC-5** | Sessió compartida: no auto-refresh, logout, idle timeout | P0 | S | ✅ |
| **EP-ACC-4** | PIN empleat (primer accés + canvi al portal) | P0 | M | ✅ |
| **EP-ACC-4a** | Lockout PIN (`pin_attempts`/`pin_locked_until`, D3b) | **P0** | S | ✅ |
| **EP-ACC-2** | Plantilla email + attachments/CID a Resend + enviar/regenerar | P0 | M | ✅ |
| **EP-ACC-3** | Imprimir targetes QR + export CSV/Excel (1 empleat) | P1 | M | ✅ (CSV; XLSX opcional) |
| **EP-ACC-4b** | Reset PIN per correu (magic link curt) | P1 | M | ✅ |
| **EP-ACC-6** | Renombrar UI «QR taulell» → «Taulell compartit (temp.)» + enllaç doc estacions | P1 | S | ✅ |
| **ST-0** | Pla estacions (`plan-attendance-stations.md`) — esbòs §8 | P1 | S (doc) | 📋 esbòs |
| **EP-ACC-3b-prep** | Batch tokens: taules + RPC idempotent + TTL + tests SQL | P2 | M | ✅ |
| **EP-ACC-3b** | UI bulk: selecció empleats + export CSV/QR (depèn 3b-prep) | P2 | M | ✅ |

### EP-ACC-1 — Modal contextual (detall)

**Fitxers:**

- `PortalTokenRevealDialog.tsx` — layout bifurcat; eliminar `secret` prop i CopyField.
- `CreatePortalTokenDialog.tsx` — passar `sharedDevice` a `onCreated`.
- `EmployeePortalAccessTab.tsx` — `onCreated({ tokenId, secret, sharedDevice })`.

**Acceptació:**

- [ ] Personal: URL prominent, QR sota.
- [ ] QR taulell: QR gran centrat, URL en text petit copiable.
- [ ] Cap camp «Secret» en cap entorn.

### EP-ACC-2a — Multi-site: resolució URL (detall)

**Prerequisit** de EP-ACC-2 (correu), EP-ACC-3 (impressió) i EP-ACC-3b (bulk).

**Fitxers:**

- `apps/tenant-portal/src/features/employee-portal/utils/resolvePublicSiteForEmployee.ts` (nou) — wrapper prim de l'RPC, sense duplicar l'algorisme.
- `apps/tenant-portal/src/features/employee-portal/utils/portalUrl.ts` — acceptar `publicSite` ja resolt (sense canvi de contracte extern).
- `apps/tenant-portal/src/features/public-portal/api/usePublicSiteForEmployee.ts` (nou) — query per `employeeId` via RPC; el tab avui no rep `employee.site_id`.
- `EmployeePortalAccessTab.tsx` — substituir `usePublicSite(tenantId)` pel hook basat en `employeeId`; eliminar la resolució independent de `usePublicDomains`, ja inclosa al resultat canònic de l'RPC.
- RPC `api.resolve_public_site_for_employee(p_employee_id)` — **no és opcional**: és la font de veritat única, ja que l'Edge d'enviament de correu (EP-ACC-2) necessita resoldre la mateixa URL/site sense poder cridar hooks de React. Implementar-la primer i fer que el hook de client hi apunti (via RPC o vista), no duplicar la lògica en TypeScript client i en SQL per separat.

**Contracte RPC:**

```text
input: employee_id
output: {
  public_site_id, site_id, site_name, slug, canonical_domain,
  portal_base_url, fallback_used
}

elegibilitat:
  site-specific published → global published → error no_published_public_site
domini:
  primary_domain_id ssl_active → primer ssl_active ordenat → subdomini sistema
```

**Acceptació:**

- [ ] Empleat site Barcelona + `public_site` Barcelona → URL amb domini/slug de Barcelona.
- [ ] Empleat site sense portal propi → URL portal global + toast/avís «No hi ha portal públic per aquest local; s'ha usat el global».
- [ ] Empleat sense `site_id` → portal global.
- [ ] Portal de site `draft`/`suspended` → no s'usa; fallback global publicat.
- [ ] `primary_domain_id` SSL actiu → és el domini escollit encara que no sigui el primer retornat.
- [ ] Cap portal publicat → bloquejar creació/distribució amb error clar.
- [ ] Tests SQL/integració de resolució (6 casos mínims); tests TS només del wrapper/URL.

### EP-ACC-2 — Correu (detall)

**Dependència:** EP-ACC-2a (URL i `site_name` correctes).

**Fitxers:**

- Migració seed `email_templates` event `employee_portal.access_link` (variables inclouen `site_name`, `support_email`).
- `employeePortalService.ts` — crida un endpoint tenant-authenticated `sendEmployeePortalAccessEmail({ employeeId, tokenId, secret, linkType, recipient, templateId? })`; el servidor valida que el hash del secret correspon al token abans d'usar-lo.
- Edge/helper d'enviament — resol URL/site amb l'RPC canònica, genera el QR PNG amb llibreria TS compatible amb Deno, el puja al bucket privat i encua el correu.
- `enqueue_email` payload: `site_id`, `event_type`, `template_variables`, attachment QR PNG.
- `process-email-queue/index.ts` — descarregar attachments privats, validar límits/MIME, convertir a Base64 i afegir `attachments` al payload Resend, inclòs `content_id`.
- Bucket privat/retenció — paths autoritzats per tenant, cleanup als 7 dies d'estat terminal.
- `PortalTokenRevealDialog.tsx` — botó «Enviar per correu» + diàleg confirmació.
- `EmployeePortalAccessTab.tsx` — «Regenerar i enviar» (mai «reenviar») per a tokens ja creats.

**Acceptació:**

- [ ] Correu arriba amb URL, instruccions i QR del **site correcte**.
- [ ] QR es mostra inline via CID i també arriba com attachment PNG.
- [ ] Worker rebutja path no autoritzat/fitxer massa gran i reintenta si Storage falla.
- [ ] Remitent/logo del correu segueix branding del site (`sites.email_*`).
- [ ] Tenant pot override plantilla text des de Configuració → Correu (1 per tenant).
- [ ] `email_logs.site_id` = `employee.site_id` per traçabilitat.
- [ ] Destinatari diferent de `employee.email` requereix confirmació i queda auditat.
- [ ] Des d'una fila existent, «Regenerar i enviar» revoca l'anterior i informa l'usuari.

### EP-ACC-3 — Impressió i etiquetes (detall)

**Dependència:** EP-ACC-2a (la URL impresa/exportada ha de ser la canònica del site).

**Fitxers:**

- `portalQrPrint.ts` — util HTML print + generació QR local.
- `portalLabelExport.ts` — CSV/XLSX download.
- Tests unitaris format CSV.

**Acceptació:**

- [ ] Imprimir 1 targeta amb nom + QR llegible.
- [ ] CSV obre correctament a Excel ca/ES.

### EP-ACC-3b — Bulk ✅ (2026-07-13)

**Prerequisit:** [`plan-employee-portal-token-batch.md`](./plan-employee-portal-token-batch.md) (fase **EP-ACC-3b-prep**). Resol el risc §10 «Bulk create/resultat no recuperable».

**Prep (fet):**

- Taules `employee_portal_token_batch_jobs` + `_items` amb TTL 1h.
- RPC `start_employee_portal_token_batch` (idempotent) + `fetch_employee_portal_token_batch_results`.
- Secrets generats **al servidor**; plaintext només a `batch_items` fins a purge.
- Refactor `api._employee_portal_token_create_locked` compartit amb create 1-a-1.
- Tests SQL B-T1…B-T9.

**UI (fet):**

- `/employees` → «Accés al portal (massiu)» → mode selecció → diàleg opcions (mateix contracte que «Accés Portal» per empleat).
- Modal resultats: taula per empleat, **Imprimir QR / Exportar CSV / Copiar enllaços**.
- Banner «Obrir resultats» (sessionStorage, 1h) si es tanca el modal abans d'exportar.
- Locales CA; copy que explica equivalència amb la pestanya «Accés Portal».

**Decisions operatives (dev):**

- `VITE_PUBLIC_PORTAL_BASE_URL=http://localhost:3002` a `.env.development` del tenant-portal.
- Sense domini SSL al tenant, l'URL es construeix amb fallback local (com al flux 1-a-1); **no** cal web corporativa publicada.

**Fora d'abast (explicit):** enviar correu a tot el lot (veure §10 throughput); export XLSX (opcional P2+).

### EP-ACC-4 — PIN empleat (detall)

**Fitxers:**

- Migració `pin_must_set`; actualitzar API view/lookup RPC perquè `pin_required = (pin_hash IS NOT NULL OR pin_must_set)` i exposi els camps de setup/lockout necessaris.
- RPC atòmica `employee_portal_setup_pin` i Edge routes separades `/pin/setup` i `/pin/change`.
- `PinSetupGate.tsx` (public-portal) — primer accés.
- `PortalSecurityPage.tsx` o secció a punch — canvi PIN.
- `CreatePortalTokenDialog` — treure camp PIN manager per defecte; opció avançada «Definir PIN jo (legacy)».

**Acceptació:**

- [ ] Flux nou: manager no introdueix PIN; empleat el defineix.
- [ ] Token `pin_must_set=true` mai rep sessió abans de completar `/pin/setup`.
- [ ] Dos setups concurrents → només un guanya; l'altre rep `pin_already_set`.
- [ ] Tenant no pot veure PIN a cap pantalla.
- [ ] Canvi PIN des del portal amb sessió activa.
- [ ] Tokens legacy amb `pin_hash` continuen funcionant sense migració destructiva.

### EP-ACC-4a — Lockout PIN (detall)

Veure disseny complet a D3b. Resum d'implementació:

**Fitxers:**

- Migració: RPC `employee_portal_attempt_pin` amb lock de fila; ampliar lookup/session records; afegir `pin_locked` al `CHECK` d'access logs.
- `session-service.ts` — delegar validació/lockout a l'RPC tant a creació com al refresh amb JWT expirat.
- `employee-portal-api/index.ts` — mapar nou error a `423 pin_locked`, `retry_after_seconds` i `Retry-After`.
- Public-portal: pantalla PIN — missatge de bloqueig temporal.
- `access-logs-service.ts` — nova `action: pin_locked`.

**Acceptació:** veure D3b.

### EP-ACC-4b — Reset PIN per enllaç d'un sol ús (detall)

No reutilitzar el secret `/e/{secret}` ni crear una sessió de portal. Afegir `data.employee_portal_pin_reset_tokens` amb:

- `id`, `tenant_id`, `employee_portal_token_id`
- `reset_token_hash` únic (secret en clar només al moment de generar)
- `expires_at` curt (default 30 min), `used_at`, `revoked_at`
- `created_by`, `created_at`

Taula no exposada a `anon`/`authenticated`; accés només via funcions/Edge autoritzats. Índex únic parcial per garantir un sol reset pendent per `employee_portal_token_id`.

**Flux:**

1. Manager amb permís genera reset; qualsevol reset anterior pendent del mateix token queda revocat.
2. Correu o QR usa una ruta separada `/e/pin-reset/{secret}`.
3. `POST /pin/reset/consume` bloqueja la fila i fa consum atòmic (`used_at IS NULL`, no caducat/revocat), estableix el PIN nou, reinicia lockout i incrementa `session_version`.
4. El reset no desbloqueja ni revela l'enllaç principal; després redirigeix al bootstrap normal.

**Acceptació:**

- [ ] El reset només es pot consumir una vegada i no funciona després de caducar.
- [ ] Dos consums concurrents → només un guanya.
- [ ] Generar un reset nou invalida l'anterior.
- [ ] Consum correcte reinicia `pin_attempts`/`pin_locked_until` i invalida sessions anteriors.
- [ ] Secret de reset i secret de portal mai comparteixen valor, hash ni ruta.

### EP-ACC-7 — Límit d'enllaços actius per tipus (detall)

Veure disseny complet a D7. Resum d'implementació:

**Fitxers:**

- Migració: normalitzar duplicats i crear índex únic parcial `(employee_id, shared_device) WHERE is_active AND revoked_at IS NULL`.
- `create_employee_portal_token` (RPC) — lock per empleat/tipus, revocar l'actiu existent (inclòs caducat), incrementar `session_version` i inserir, dins la mateixa transacció.
- `EmployeePortalAccessTab.tsx` / `CreatePortalTokenDialog.tsx` — avís UI «Es revocarà l'enllaç [tipus] actual» abans de confirmar creació si ja n'hi ha un actiu del mateix tipus.
- EP-ACC-3b (bulk): aplicar la mateixa regla per cada fila del lot, no només al flux d'1 empleat.

**Acceptació:** veure D7.

### EP-ACC-5 — Sessió compartida (detall)

**Fitxers:**

- `PortalSessionRefresh.tsx` — no interval si `isPortalSharedDevice()`.
- `PortalShell.tsx` — botó «He acabat» + `session/logout`.
- `usePortalIdleLogout.ts` — timeout del payload de política, `last_activity_at` persistent a la pestanya i comprovació en `visibilitychange`.
- Edge/proxy `session/refresh` i `session/me` — per `shared_device`, no reemetre sessió/cookie; expiració absoluta de 15 min aplicada al servidor.
- Endpoint/RPC de política pública mínima — resol settings amb service role i retorna només claus allowlist.
- `session-service.ts` — comprovar `expires_at` en crear sessió (no dependre del cron); assegurar que logout esborra cookie via proxy.
- `portalApi.ts` / `sessionFlags.ts` — afegir logout client i esborrar només snapshot, flags i outbox del portal.

**Acceptació:**

- [ ] Tablet `shared_device`: sense refresh automàtic.
- [ ] Crida manual/directa a `session/refresh` o `session/me` no allarga una sessió shared.
- [ ] Tancar i reobrir la pestanya elimina el marcador de tab; si queda cookie shared residual, es fa logout abans de renderitzar i cal tornar a escanejar.
- [ ] Logout esborra sessió; següent usuari ha d'escanejar QR + PIN.
- [ ] Idle i retorn d'una pestanya suspesa → logout abans de mostrar dades + missatge clar.
- [ ] Token amb `expires_at` passat no pot crear una sessió encara que el cron no hagi corregut.

---

## 6. Preguntes resoltes (FAQ operativa)

### Si l'empleat no tanca la sessió a la tablet?

Avui: la sessió pot durar **indefinidament** (refresh cada 11 min). **EP-ACC-5** corregeix això per `shared_device`. Fins llavors: recomanar PIN + política de tancar pestanya.

### Si el gestor posa enllaços «Personal» a una tablet fixa?

Comportament incorrecte: IndexedDB i cookie persisteixen entre empleats. **No suportat.** Usar tipus taulell compartit (interí) o esperar estacions.

### Cal escàner dins el portal?

**No.** L'escaneig el fa la càmera/app del dispositiu; el portal només rep la URL. L'escàner integrat serà de la **UI estació** (pla futur).

### L'empleat sense correu pot canviar PIN?

Sí, **des del portal** amb sessió. Sense sessió i sense correu: manager ha de **revocar i generar enllaç nou** o (EP-ACC-4b) imprimir QR de reset PIN d'un sol ús.

### Multi-site: cal una plantilla de correu per local?

**No.** El text és **tenant-level** (un override per `event_type`). El que canvia per local és el **branding** (`site_id` a `enqueue_email`) i la **URL** (`portal_url` resolta per EP-ACC-2a). La plantilla pot dir «Accés al portal de **{{site_name}}**» amb una sola còpia editada per RRHH.

### Multi-site: l'empleat de Madrid pot obrir l'enllaç de Barcelona?

El **token** és el mateix independentment del host; el servidor valida el secret, no el domini. Però és millor enviar la URL del **seu** `public_site` (domini de marca correcte, cookies al host esperat). EP-ACC-2a assegura que manager/correu/QR generen la URL adequada per empleat.

---

## 7. Esbòs pla estacions (ST-0 — document separat) ✅ esbòs

Document creat: [`plan-attendance-stations.md`](./plan-attendance-stations.md) (ST-0, 2026-07-13). Conté:

1. **UI** `StationPage` + registre `attendance_devices`.
2. **Edge** `punch-from-station` + `issue_attendance_identity_token`.
3. **Modes:** selecció manual | QR empleat | barcode.
4. **Política:** només fitxar a estació vs portal complet.
5. **Migració** usuaris de `shared_device` → dispositiu estació quan existeixi.

No bloqueja EP-ACC; es referencia des de STATUS quan s'aprovi.

---

## 8. Impacte a documentació existent

| Document | Actualització |
|----------|---------------|
| `18-employee-portal-architecture.md` | §18.5 PIN mode B/setup/reset/lockout; sessió shared server-side; settings allowlist; **corregir bcrypt → SHA-256 sense sal (D3)**; **corregir `EXCLUDE` únic → índex parcial per tipus + lock (D7)** |
| `plan-employee-portal.md` | Enllaç a aquest pla; EP3 ampliat; deprecar/ajustar `max_tokens_per_employee` davant la invariant 1 Personal + 1 shared |
| Arquitectura correu | Documentar contracte `attachments` de cua → Storage privat → Base64/CID Resend, límits i retenció |
| `STATUS.md` | Fila EP-ACC-1…7 |
| Help center (futur) | Article RRHH «Distribuir accés portal» |

---

## 9. Ordre d'implementació recomanat

```
✅ EP-ACC-1 → EP-ACC-7 → EP-ACC-2a → EP-ACC-5 → EP-ACC-4 + EP-ACC-4a →
   EP-ACC-2 → EP-ACC-3 → EP-ACC-4b → EP-ACC-6 → EP-ACC-3b-prep → EP-ACC-3b
```

### Com seguim (post-v2)

| Pas | Què | Prioritat | Notes |
|-----|-----|-----------|-------|
| **1. Smoke + commit** | Validar fluxos §0; commit/PR del lot EP-ACC | P0 | Abans de producció |
| **2. Docs §8** | Actualitzar `18-employee-portal-architecture.md`, `STATUS.md`, enllaç des de `plan-employee-portal.md` | P1 | Tancar deute documental |
| **3. i18n** | Traduccions EN/ES de claus `portal_access.batch_*` (avui només CA complet) | P2 | Si cal multi-idioma tenant |
| **4. ST-1** | Aprovar abast i implementar **estacions** ([`plan-attendance-stations.md`](./plan-attendance-stations.md)) | P1 producte | Substituir «taulell compartit (temp.)» a llarg termini |
| **5. Bulk email** | «Generar i enviar a tots» al lot | P3 | Requereix estudi quota Resend / throughput (§10) |
| **6. Help center** | Article RRHH «Distribuir accés portal» | P3 | §8 |

**No cal repetir l'ordre d'implementació original** — les dependències EP-ACC ja estan resoltes. El següent bloc de valor és **estacions de fitxatge** (canal separat del portal personal), no més feina al tab `portal_access` excepte polish.

Referències de dependències (històric):

- EP-ACC-2a abans de 2/3/3b: URL correcta per local — **fet**.
- EP-ACC-7 abans de bulk: 1 actiu per tipus — **fet**.
- EP-ACC-3b-prep abans de UI bulk — **fet**.

---

## 10. Riscos coneguts i pendents (documentats, no resolts en aquest pla)

Detectats durant la revisió crítica d'aquest pla. No bloquegen el camí P0/P1, excepte quan s'indica explícitament; s'han de resoldre abans d'activar funcionalitats massives o d'escalar a volums grans.

| Risc | Estat | Notes |
|------|-------|-------|
| **Sense rate-limit per IP a `/session`** | Acceptat V1 | Lockout per token (EP-ACC-4a). Revisar si abús distribuït real. |
| **Bulk create/resultat no recuperable** | ✅ Resolt | EP-ACC-3b-prep + 3b: TTL 1h, fetch idempotent, banner recuperació. |
| **Enviament massiu de correus sense anàlisi de throughput** | ⏳ Pendent | Fora d'EP-ACC-3b. Abans de «enviar a tots» cal estudi Resend/quota. |

---

## 11. Fora d'abast (explícit)

- Mode quiosc amb escàner integrat al portal.
- Format `.lbx` natiu Brother sense passar per CSV.
- Recuperació de URL d'un token ja creat (secret no recuperable per disseny).
- Un sol QR per a tota l'empresa (això és estació, no portal personal).
- **Plantilles de correu per site** (`site_id` a `email_templates`) — V1 usa text tenant + branding/URL per site.
