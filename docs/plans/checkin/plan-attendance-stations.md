# Estacions de fitxatge per ubicació

> **Data:** 2026-07-10 (actualitzat 2026-07-14 — ubicació organitzativa vs GPS, ST-6b visibilitat per ubicació, UX gestió/estació; revisat 2026-07-13 — estudi `my-app-jcm`, tenant scoping, cicle de vida `device_secret_hash`, decisions #2–#8, UI estació)  
> **Estat:** **MVP complet (ST-1…ST-8, ST-2a, ST-6b/c) validat local** — veure §"Estat d'implementació" i §"Post-MVP"  
> **Relacionat:** doc 15 §15.6 · doc 16 `attendance_devices` · [`plan-employee-portal-access-v2.md`](./plan-employee-portal-access-v2.md) §7  
> **Mapa global:** [`STATUS.md`](./STATUS.md)
> **Ordre executable:** [`EXECUTION.md`](./EXECUTION.md) — aquest pla especifica estacions, però no decideix per si sol la següent fase  
> **Revisions:** [`revisio-critica-estacions-fitxatge.md`](./revisio-critica-estacions-fitxatge.md) · [`revisio-exhaustiva-estacions-vs-codi.md`](./revisio-exhaustiva-estacions-vs-codi.md)

---

---

## Estat d'implementació (viu)

> Actualitzar aquesta secció a cada entrega. Última revisió: **2026-07-15**.

| Fase | Estat | Notes |
|------|-------|-------|
| **ST-1** | 🟢 MVP local | Pàgina `/settings/attendance-stations`: llista, codi d'aparellament, edició, revocar secret |
| **ST-1b** | 🟢 MVP local | Migració `20261014000001_attendance_stations_st1.sql` aplicada localment |
| **ST-2** | 🟢 MVP local | UI `/station` (public-portal), sense GPS |
| **ST-2b** | 🟢 MVP local | PIN només accions sensibles (desaparellar, sortir pantalla completa, bloqueig manual); fitxatge obert |
| **ST-3** | 🟢 MVP local | Edge `station-api` + `record_station_time_punch` + snapshots ubicació |
| **ST-4** | 🟢 MVP local | QR identitat signat: issue/resolve RPCs, escàner estació, QR al portal empleat |
| **ST-5** | 🟢 MVP local | `allowed_methods` per estació + geo anti-frau opcional (validació tablet vs `locations.geo_coordinates`, sense guardar geo al punch) |
| **ST-6** | 🟢 MVP local | Drawer historial per estació (device_id), filtre data/empleat, export CSV |
| **ST-6b** | 🟢 MVP local | Vista fitxatges raw, filtre ubicació/estació, export CSV, columna ubicació a detall/seqüència |
| **ST-6c** | 🟢 MVP local | Resum hores per ubicació (vista + export CSV) |
| **ST-7** | 🟢 MVP local | Branding estació (títol + logo al kiosk) |
| **ST-8** | 🟢 MVP local | Auditoria accions admin (drawer + RPC audit logs) |
| **ST-9** | ✅ V2 | EX-05.2–05.6 ✅ (outbox → FF-04); V1 online-only = flag OFF |
| **ST-2a** | 🟢 MVP local | CRUD assignacions empleat↔zona des de `/locations` + filtre estació |
| **ST-10** | ✅ V1 tenant | Flag tenant + enforcement + UX portal (EX-02.1). |
| **ST-10b** | ✅ Cascada | Empleat → grup calendari → site → tenant (EX-02.1b). UI Grups + fitxa empleat. |
| **ST-18** | ✅ Core+18a–e+presets | EX-02.2–02.7: FSM, DNI, PIN, QR portal, historial, presets/auto-blank/masking. |
| **Eliminar `shared_device`** | 🟢 MVP local | Substituït per estacions `/station` |

### Fitxers clau (2026-07-14)

| Àrea | Fitxer |
|------|--------|
| Migració | `supabase/migrations/20261014000001_attendance_stations_st1.sql` … `20261051000001_station_st6c_st2a_plus.sql` |
| Edge | `supabase/functions/station-api/index.ts` |
| Tenant UI estacions | `apps/tenant-portal/src/features/attendance-stations/` |
| Tenant UI (assignacions) | `apps/tenant-portal/src/features/locations/components/LocationAttendanceEmployeesPanel.tsx` |
| Tenant UI (estacions↔ubicació) | `LocationLinkedStationsPanel.tsx`; enllaços a `AttendanceStationsPage` / `?locationId=` |
| Fitxatges ST-6b / ST-6c / ST-6c+ | `LocationWorkSummaryTable.tsx`, `api/locationWorkSummaryService.ts`, `api/useLocationWorkSummary.ts`, `utils/locationWorkSummary.ts` |
| Historial ST-6 | `apps/tenant-portal/src/features/attendance-stations/components/StationHistoryDrawer.tsx` |
| Auditoria ST-8 | `apps/tenant-portal/src/features/attendance-stations/components/StationAdminAuditDrawer.tsx` |
| Estació UI | `apps/public-portal/app/station/page.tsx`, `lib/attendance-station/deviceGeo.ts`, `components/station/StationPinPad.tsx`, `components/station/StationQrScanner.tsx` |
| Portal QR | `apps/public-portal/features/employee-portal/components/PortalIdentityQrCard.tsx` |
| Proxy | `apps/public-portal/app/api/station/[...path]/route.ts` |
| Tests SQL | `supabase/tests/attendance_station_tests.sql`, `attendance_station_st6c_st2a_plus_tests.sql`, `e2e_attendance_stations_joint.ps1` |

### Flux operatiu MVP

1. Admin → **Configuració → Estacions de fitxatge** → generar codi.
2. Tablet → `/station` → codi + PIN → estació `pending`.
3. Admin → assignar centre + ubicació → `active`.
4. Tablet → seleccionar empleat → Entrada/Sortida (ubicació snapshot, sense GPS).

### Validació E2E local (2026-07-15)

| Prova | Resultat |
|-------|----------|
| SQL `attendance_station_tests.sql` (13 tests, ROLLBACK) | ✅ PASS — 13/13 (ST-T5 corregit 2026-07-15) |
| Script `e2e_attendance_stations_joint.ps1` (14 passos) | ✅ PASS — aparellament → bootstrap → employees → punch → ST-2a/6b/6c/7 |
| `GET /functions/v1/station-api/health` | ✅ |
| `GET …/bootstrap` + proxy `:3002/api/station/bootstrap` | ✅ branding ST-7 |
| `GET …/employees` site_fallback (29) + zone (1/29) | ✅ ST-2a |
| `POST …/punch` in/out → `time_punches` snapshot, sense geo | ✅ ST-3/6b |
| `POST …/verify-pin` | ✅ ST-2b |
| vitest `locationWorkSummary.test.ts` | ✅ ST-6c (5 tests) |
| `http://localhost:5173` (tenant-portal) | ✅ UI gestió + fitxatges |
| `http://127.0.0.1:3002/station` (public-portal) | ✅ kiosk estació |

**Nota dev:** Vite (tenant-portal) escolta `localhost:5173`, no `127.0.0.1:5173`.

### Properes passes (tancament MVP → producció)

1. Validació UI manual al tenant-portal (`http://localhost:5173`): estacions + **Hores per ubicació**.
2. Desplegament staging: migracions `20261014000001`…`014`, Edge `station-api`, proxy `/api/station`, bucket `public-assets`.
3. Guia operativa admin (aparellar → assignar → activar → provar fitxatge).

---

## Post-MVP i backlog

> MVP funcional complet (2026-07-15). Tot el següent és **opcional** o **per demanda de client**, no bloqueja desplegar el vestuari/tablet.

### Prioritat alta — abans o just després de producció

| ID | Entregable | Notes |
|----|------------|-------|
| **ST-10** | Política `punch_only_at_stations` (V1) | ✅ Tenant-only (EX-02.1). Decisió #2 intacta (consulta sí). |
| **ST-10b** | Cascada canal de fitxatge | ✅ Empleat → grup → site → tenant (EX-02.1b / decisió #22). |
| **ST-11** | Hardening QR (#12) | ✅ Entropia 32 bytes / min 43 chars + rate limit dins `resolve_attendance_identity_token` (migració `20261050000001`; Edge passa `p_client_key`). |
| **ST-12** | Monitoratge operatiu | ✅ Via **EX-01.6** + ampliació **AP-05/10** (fleet health UI, outbox telemetry, lockdown/bulk). |
| **ST-13** | CI | ✅ Via **EX-01.5** (`.github/workflows/attendance-station-tests.yml` + E2E gate). |

### Prioritat mitjana — entorns exigents

| ID | Entregable | Notes |
|----|------------|-------|
| **ST-9 V2** | Offline + reintent | ✅ Via **EX-05** (outbox, timestamps, skew, E2E, FF-04 `station_offline_deferred_punch`). Opt-in; default OFF. |
| **ST-6c+** | Resum ubicació servidor | ✅ RPC `api.summarize_location_work` (`20261051000001`); UI Fitxatges via server; tests **7/7**. |
| **ST-14** | Enllaços creuats UI | ✅ Estació → `/locations?locationId=`; ubicació → panell estacions vinculades. |
| **ST-2a+** | Assignacions amb dates | ✅ UI `starts_on`/`ends_on` + massiu; RPCs update/bulk/list inactive. |
| **ST-15** | QR codi aparellament | ✅ QR al diàleg tenant + escàner a `/station` registre. |

### Prioritat baixa — només si un client ho demana

| ID | Entregable | Notes |
|----|------------|-------|
| **ST-4b** | Codi de barres | Mateix token signat que QR; lectors físics USB/BT (decisió #6). Veure §"Backlog: codi de barres". |
| **ST-5b** | Mètodes per empleat | `allowManual` / `allowQR` per empleat (`my-app-jcm` PunchPermissionsConfig). |
| **ST-7+** | Tema kiosk | Clar/fosc/colors, a més de títol+logo (ST-7 fet). |
| **ST-16** | Pauses a estació | `break_start` / `break_end` al kiosk (avui només in/out). |
| **ST-17** | Canvi PIN local | Des del tenant-portal (avui només a l'aparellament). |
| **ST-18** | UX fitxatge estació v2 + portal QR | Modes entrada configurables (DNI-first / llista / QR); sessió empleat amb countdown, historial per període i «Tancar sessió». Veure [`estudi-station-punch-ux-v2.md`](./estudi-station-punch-ux-v2.md). Subfases: **ST-18a** (DNI + PIN), **ST-18b** (portal tab QR + ST-10), **ST-18c** (avis ubicació — requereix ST-19), **ST-18d** (fitxar sense assignació), **ST-18e** (historial sessió). |
| **ST-19** | Ubicació al planificador de torns | Primera entrega del [Planificador de torns V2](./plan-shift-planner-v2.md): schema `location_id`/snapshots ✅ (EX-03.4); ST-18c ✅ (EX-04.5); UI `/attendance-mgmt/planning/shifts` ja operativa (EX-04.2+). El torn publicat forma part de l'horari efectiu (EX-03.3+). |

### Millores incrementals (sense fase formal)

- Rotació programada de `device_secret`.
- Validar resum ST-6c vs `time_daily_summaries` / export nòmina.
- Resum per ubicació **+ estació** (dimensió dual).
- Test E2E Playwright UI tenant + kiosk (complement al script PowerShell).

### Mapa post-MVP

```
MVP (fet) → ST-10 V1 + ST-10b / 11/12/13 (prod) → ST-19 (ubicació als torns)
                                      → ST-18/18a/18b/18e (UX estació + portal)
                                      → ST-18c/18d/16 (avisos + pauses)
                                      → ST-9 V2 / ST-6c+ / ST-14 (fet via EX / backlog mitjà)
                                      → ST-4b / ST-5b / ST-7+ (demanda client)
```

---

## Motivació

El portal empleat (`/e/{secret}`) cobreix el **mòbil personal** i consulta d'horari. El cas **tablet/QR al vestuari** compartit per molts empleats encaixa millor com a **estació de fitxatge** vinculada a `site_id` + `location_id`, no com a enllaç personal amb flag `shared_device`.

**MVP complet (2026-07-15):** ST-1…ST-8, ST-2a, ST-6b/c validats local (SQL + E2E). Veure §"Post-MVP" per continuar.

---

## Objectiu (quan s'implementi)

1. Registrar dispositius/estacions per local i zona.
2. **Pàgina de gestió d'estacions al tenant-portal** (llista + alta + edició), no només un formulari puntual — veure §"Gestió d'estacions" més avall.
3. **UI estació** (tercera superfície, veure §"Tres superfícies d'app"): tablet/PC fix amb:
   - selecció manual d'empleat (V1 estació), o
   - escaneig QR d'identitat emesa pel servidor (V2; codi de barres fora d'abast inicial).
4. Fitxatges amb `source IN ('station','qr')` i `device_id` + **`location_id` snapshot** obligatoris (`barcode` reservat per backlog futur). **Sense coordenades GPS de l'empleat** des d'estació fixa — veure §"Ubicació de treball".
5. Política opcional «només fitxar des d'estacions» (`punch_only_at_stations`); **consulta d'horari sempre permesa** des del portal personal (decisió #2). **V1 = tenant**; **objectiu producte = cascada ST-10b** (grup calendari + override empleat), no un interruptor global únic.
6. L'empresa pot **veure i exportar** on ha treballat cada empleat (ubicació organitzativa de `/locations`, no només per estació/dispositiu) — veure **ST-6b**.

---

## Referència: sistema d'estacions de `my-app-jcm` (Firebase)

`my-app-jcm` és una altra app del mateix grup amb un sistema de fitxatge (Firebase/Firestore) que ja té estacions fixes en producció. Val la pena revisar-lo perquè cobreix casos reals que el nostre esbòs encara no detallava. Resum de com ho fa (fonts: `docs/QR_SYSTEM.md`, `docs/DEVICE_ID_SYSTEM.md`, `docs/BARCODE/*`, `src/components/station/*`, `src/components/admin/PunchPermissionsConfig.tsx`):

### 1. Auto-registre del dispositiu (bootstrap sense provisioning previ)
- La UI d'estació (`FixedStationInterface.tsx`) genera un `deviceId` estable al primer accés (hash de `userAgent` + `platform` + resolució + timezone, persistit a `localStorage`+`sessionStorage` com a doble backup) i **crea el document del dispositiu ell mateix** a Firestore si no existeix (`isFixedStation: true`, `isActive: true`, nom amic auto-generat tipus `Desktop Chrome (Windows)`).
- Si el dispositiu no té zona assignada, l'estació mostra una pantalla de bloqueig «Dispositiu sense zona — contacta amb l'administrador» en lloc de deixar fitxar.
- **Comparació amb el nostre pla:** doc 15 ja preveu `api.register_attendance_device(p_public_device_id, p_kind, p_metadata)`, és a dir, la mateixa idea d'auto-registre ja hi és contemplada a nivell d'API. Cal assegurar que ST-1/ST-2 facin explícit aquest flux "pairing": l'estació truca `register_attendance_device` sola en el primer arrencada i queda en estat `pending` (sense `site_id`/`location_id`) fins que un admin l'assigna des de la pàgina de gestió.
- ⚠️ **Punt no resolt a `my-app-jcm` (Firestore és single-tenant per projecte, no cal resoldre `tenant_id`) però crític per a nosaltres (multi-tenant amb RLS):** `my-app-jcm` no necessita saber a quin "tenant" pertany el dispositiu perquè cada client té el seu propi projecte Firebase. Nosaltres SÍ ho necessitem, i el document original no ho deixava explícit — veure "Registre de tenant a `register_attendance_device`" més avall, resolt abans d'aprovar l'abast.

### 2. Gestió d'estacions: **no hi ha una pàgina central d'administració**
- Aquest és el punt més rellevant per a la teva pregunta. `my-app-jcm` **no té** una pàgina d'admin amb la llista de totes les estacions. La gestió és **descentralitzada, dispositiu per dispositiu**: cada estació té el seu propi mode admin local (`StationAdminMode.tsx`), protegit per una contrasenya pròpia del dispositiu (`device_passwords` a Firestore, hash bcrypt, contrasenya per defecte `admin123` fins que es canvia), accessible tocant un badge discret a la UI de l'estació.
- Dins d'aquest mode admin local hi ha 3 pestanyes:
  - **Dispositiu**: nom, zona assignada (select), actiu/inactiu, canvi/reset de contrasenya de l'estació.
  - **Aparença**: títol personalitzat, logo (base64 a IndexedDB), tema (light/dark/blue) — branding per a un totem/tablet compartit.
  - **Historial**: fitxatges filtrats per aquest dispositiu concret, cerca per text, rang de dates, exportació CSV.
- **Conclusió per al nostre pla:** el nostre esbòs (ST-1 "CRUD `attendance_devices` tenant-portal") ja proposa una solució **millor** que la de `my-app-jcm` — una pàgina central al tenant-portal en lloc de gestió dispositiu-a-dispositiu (que escala malament i obliga a tocar físicament cada tablet per reassignar-la). **Mantenim ST-1 com a pàgina central**, però n'hi afegim funcionalitats que `my-app-jcm` sí que té i que ens faltaven detallar (veure "Gestió d'estacions" més avall): historial/auditoria per dispositiu amb export, i un mecanisme de "bloqueig local" per evitar que qualsevol usuari toqui la configuració física de la tablet.

### 3. Identificació d'empleats a l'estació: 3 mètodes en pestanyes
- **Selecció manual**: llista d'empleats assignats a la zona de l'estació, **amb herència de zones pare** (si zona té `fatherZoneId`, s'inclouen també els empleats assignats a la zona pare). Mostra l'últim fitxatge de cadascú (IN/OUT + hora) abans de confirmar. → Coincideix exactament amb doc 15 §15.6 punt 1 ("selecció manual... incloent herència de locations pare"); validat.
- **QR**: cada empleat genera, des del seu perfil personal (`UserQRCode.tsx`), un QR amb un JSON `{uid, email, displayName, timestamp, version}` que **caduca als 5 minuts** (comprovació només de timestamp, sense signatura de servidor). L'estació l'escaneja amb `@zxing/library` via càmera.
- **Codi de barres**: mateix concepte que el QR (mateixa caducitat de 5 min), però format 1D generat amb `jsbarcode`, pensat per lectors de codi de barres físics o per pantalles petites on un QR no es llegeix bé.
- ⚠️ **Advertència de seguretat a NO replicar**: el payload QR/barcode de `my-app-jcm` no porta signatura del servidor, només caducitat per timestamp — és replicable durant els 5 minuts per qualsevol que hagi vist el codi (foto, captura). El nostre pla ja tria l'opció correcta a la decisió #1 (token curt **signat pel servidor**, `issue_attendance_identity_token` / `resolve_attendance_identity_token` de doc 15). Mantenim aquesta decisió i la marquem com a **tancada**, no oberta.

### 4. Permisos de fitxatge configurables per empleat (no només per estació)
- `PunchPermissionsConfig.tsx` (admin) permet activar/desactivar, **per empleat**, quins mètodes pot usar (`allowManual`, `allowQR`, `allowBarcode`) i quin és el mètode per defecte.
- Això és un eix ortogonal al nostre "estació" (que és per dispositiu/ubicació). **Decisió tancada (#5):** fase 1 només restricció per estació (ST-5); fase 2 per empleat (ST-5b) només si un client ho demana — no construir-ho especulativament ara.

### 5. Altres detalls útils observats
- Reassignar la zona d'un dispositiu no reescriu els fitxatges antics: el `zoneId`/`zoneName` queda "congelat" al fitxatge en el moment de crear-se. Confirma que el nostre `device_id`/`location_id` a `time_punches` ha de guardar-se per còpia al moment del punch, no només per referència viva.
- Nom amic auto-generat + possibilitat de renombrar-lo manualment, per distingir dispositius quan el `deviceId` canvia (ex. usuari neteja dades del navegador i apareix com a "dispositiu nou").

---

## Ubicació de treball: model i UX (revisió 2026-07-14)

### Què vol dir «on ha treballat» l'empleat

Per a **estacions fixes**, la resposta és la **ubicació organitzativa** de l'empresa (`data.locations`, gestionada a `/locations`), no les coordenades GPS del moment del fitxatge.

| Concepte | Taula / camp | Exemple |
|----------|--------------|---------|
| **Ubicació d'empresa** | `data.locations` | «Cuina», «Sala», «Bancada 2 — Nau A» |
| **Estació** | `attendance_devices` → `location_id` | Tablet al vestuari de la cuina |
| **On ha treballat** (al punch) | `time_punches.location_id` + `location_name_snapshot` | Congelat al moment del fitxatge |
| **Coordenades GPS** (canal mòbil) | `time_punches.geo_*` | Només portal personal / mòbil amb geo activada |

**Casos reals on les coordenades no aporten res (i no cal demanar-les):**

- Una nau amb dues bancades de treball al costat: importa **quina bancada** (`location`), no lat/lng.
- Un restaurant amb cuina i sala: zones diferents, sovint **sense polígon GPS** precís.
- Un vestuari compartit: l'estació ja identifica el lloc; demanar GPS al tablet és redundant i confús.

### Decisió: estació fixa **no** guarda geo de l'empleat

| Canal | Geo al punch (`geo_lat`, `geo_lng`, …) | Ubicació organitzativa |
|-------|----------------------------------------|-------------------------|
| **Estació** (`source IN ('station','qr')`) | **No** — camps NULL, `location_permission = 'notrequired'` | **Sí** — snapshot de la `location_id` de l'estació |
| **Portal personal / mòbil** (`source = 'portal'/'mobile'`) | Opcional segons política tenant (cascada geo E4) | **No** per defecte (canal separat; veure nota més avall) |
| **Itinerant** (`mobile_peripatetic`) | Via `work_logs` + projecte | **No** via `/locations` — veure [`plan-effective-work-time.md`](./plan-effective-work-time.md) |

**Regles ST-3 (`punch-from-station`):**

1. Omplir `device_id`, `location_id`, `location_name_snapshot`, `device_name_snapshot` des de l'estació activa (valors **copiats**, no JOIN viu).
2. **No** cridar geolocalització del navegador a la UI estació.
3. **No** omplir `geo`, `geo_lat`, `geo_lng`, `geo_consent` ni demanar permís d'ubicació al tablet.
4. Si en el futur un client vol validar que la tablet no s'ha mogut físicament, es pot comparar (opcional, ST-5) les coordenades **de la location** (`locations.geo_coordinates`) o **de l'estació** (`metadata`) amb un test puntual del dispositiu — **no** com a dada per punch d'empleat.

### Relació estació ↔ `/locations`

- **Model mental:** 1 estació → 1 ubicació d'empresa (cas habitual). Múltiples estacions poden compartir la mateixa ubicació (p. ex. dues tablets al mateix vestuari).
- **Obligatori per activar:** una estació en estat `active` ha de tenir `site_id` + `location_id` assignats (ST-1). Sense ubicació → pantalla de bloqueig a la UI estació (com `my-app-jcm`).
- **Selector d'ubicació (ST-1):** arbre de locations del mateix `site_id` (reutilitzar patró de [`LocationsPage`](../../../apps/tenant-portal/src/features/locations/components/LocationsPage.tsx)); enllaç «Gestionar ubicacions» → `/locations`.
- **`locations.geo_coordinates`:** opcional. Una location és vàlida **amb o sense** coordenades. No bloquejar l'alta d'estació si la ubicació no té GPS.

### Snapshot al punch (auditoria i informes)

Camps nous a `time_punches` (migració ST-3):

```sql
-- Afegir a data.time_punches (ST-3)
location_id            uuid REFERENCES data.locations(id) ON DELETE SET NULL,
location_name_snapshot text,   -- ex. «Cuina» o «Nau A › Bancada 2»
device_name_snapshot   text,   -- ex. «Tablet vestuari nord»
```

**Per què snapshot de nom:** si l'admin reanomena o esborra una location, l'historial legal segueix llegible sense dependre de JOINs que poden trencar-se.

### Visibilitat per a l'empresa (ST-6b)

L'empresa ha de poder respondre: *«On ha treballat l'empleat X el dia D?»* i extreure dades per ubicació.

| Funcionalitat | On | Fase |
|---------------|-----|------|
| Columna «Ubicació» al detall de punch | tenant-portal — registres / historial | ST-6b |
| Filtre per `location_id` (i per estació) | tenant-portal — llista de fitxatges | ST-6b |
| Export CSV de punches amb ubicació + estació + font | tenant-portal — registres + drawer estació (ST-6) | ST-6b |
| Historial per estació (`device_id`) | tenant-portal — gestió estacions | ST-6 |
| Resum «hores per ubicació» (agregat) | tenant-portal — fitxatges equip | ST-6c 🟢 |

**Export mínim ST-6b (columnes):** `employee_name`, `occurred_at`, `punch_type`, `source`, `location_name`, `device_name`, `site_name`.

**Nota:** l'export d'inspecció existent (`export_attendance_inspection`) és per **resums diaris** (legal RD 8/2019), no per ubicació. ST-6b afegeix dimensió d'ubicació als **punches raw** i a la UI de registres — no substitueix l'export legal.

### Assignació empleat ↔ zona (per llista a l'estació)

ST-2 necessita saber quins empleats poden fitxar a cada estació. Taula existent: `attendance_location_assignments`.

**V1 (MVP, recomanat):** si no hi ha assignacions per a la `location_id` de l'estació (ni zones pare), mostrar **tots els empleats actius del `site_id`** — simple, usable des del primer dia. Badge informatiu a la UI estació: «Sense assignacions de zona — es mostren tots els empleats del centre».

**V1.1 (mateix sprint o immediatament després):** pestanya «Empleats de la zona» a l'edició de location (`/locations`) o enllaç des de ST-1 — CRUD d'`attendance_location_assignments`. Sense això, clients amb zones estrictes hauran de confiar en la llista per site.

**Herència de zones pare:** RPC `data.employee_can_punch_at_location(employee_id, location_id)` — recursiva per `locations.parent_id` (doc 15 §15.6, doc 16).

**No confondre amb el planificador de torns (ST-19):** les assignacions a `/locations` són **estructurals** («pot fitxar en aquesta zona») i no canvien sovint. El planificador (`/attendance-mgmt/planning/shifts`) ha de dir **on i quan treballar cada dia** via el torn publicat — veure [`estudi-station-punch-ux-v2.md`](./estudi-station-punch-ux-v2.md) §«Zones fixes vs planificador de torns» i el [pla específic del Planificador V2](./plan-shift-planner-v2.md).

### UX: màxim útil, mínim fricció

**Tenant-portal (admin / RRHH):**

1. **Un sol lloc per estacions:** `/settings/attendance-stations` (o secció dins control horari) — no dispersar la gestió.
2. **Flux d'aparellament en 3 passos:** generar codi → tablet introdueix codi + PIN → admin assigna ubicació i activa.
3. **Badge «Pendent d'assignar»** visible a la llista; filtre ràpid «Pendents».
4. **Ubicació en llenguatge humà:** mostrar camí complet (`Site › Nau A › Cuina`), no només UUID.
5. **Enllaços creuats:** des d'una estació → ubicació; des d'una ubicació → estacions vinculades (read-only).

**UI estació (tablet / kiosk):**

1. **Pantalla principal = mode espera** (`waiting`): DNI, llista d'empleats o QR segons `entry_mode` (ST-18) — no configuració.
2. **Mode DNI recomanat (vestuari):** teclat numèric → resoldre empleat → confirmar nom → sessió empleat — no demanar DNI *després* de triar un nom a la llista (decisió #20).
3. **Mode llista (alternatiu):** targetes (`cards`) o llista compacta (`compact_list`); cerca per nom; confirmació `tap_name` o PIN.
4. **Sessió empleat (`employee_session`):** pantalla punch com portal (ST-18); botó **«Tancar sessió»** sempre visible; countdown de retorn a `waiting` amb reinici per inactivitat.
5. **Historial dins sessió** (ST-18e, configurable): selector de període via `station-api` — **mai** portal personal; màx. **90 dies**.
6. **Cap sol·licitud de permís GPS** ni diàlegs de geolocalització.
7. **Feedback immediat** post-punch: nom, hora servidor, ubicació.
8. **Estat bloquejat clar** si `pending` / sense `location_id` / suspesa.
9. **PIN kiosk (ST-2b)** només per sortir de pantalla completa o accions sensibles admin — no per cada fitxatge (salvo `identity_confirm = portal_pin`).
10. **Avis ubicació planificada** (ST-18c + ST-19): «Avui et tocava a Cuina» si el torn planificat difereix de l'estació actual.

**Portal personal (mòbil):** sense canvis de UX per estacions; generació de QR d'identitat (ST-4) des del perfil. El canal mòbil i l'estació romanen separats (§"No confondre").

---

## Registre de tenant a `register_attendance_device` (buit crític, tancat)

Ni aquest pla ni doc 15/16 deixaven explícit com sap `api.register_attendance_device` a quin `tenant_id` pertany un dispositiu nou. Amb RLS multi-tenant, un endpoint d'auto-registre sense credencial de tenant permetria crear dispositius `pending` fantasma a qualsevol tenant (o obligaria a enumerar `tenant_id`). Cal resoldre-ho explícitament abans d'implementar ST-1b:

- **Opció triada: codi/QR d'aparellament d'un sol ús generat des del tenant-portal.** Un admin, des de la pàgina de gestió d'estacions (ST-1), genera un codi curt (o QR) d'un sol ús i temps de vida curt (ex. 15 min), lligat al `tenant_id` (i opcionalment `site_id`). L'estació nova mostra una pantalla "Introdueix el codi d'aparellament" (o l'escaneja); en fer-ho, crida `register_attendance_device` **amb el codi**, que resol el `tenant_id` i crea el registre `pending` ja lligat al tenant correcte, retornant el `device_secret_hash` inicial (veure punt següent). Sense codi vàlid, no hi ha registre possible — elimina l'endpoint anònim sense credencial.
- **Opcions descartades:** A) subdomini/URL per tenant baked-in al desplegament de l'app estació (funciona però trenca la idea de "mateixa app, qualsevol tablet" i complica el desplegament multi-site); B) `tenant_id` manual a la config de la tablet (provisioning manual, és el que volíem evitar amb l'auto-registre).
- Aquest flux de codi d'aparellament passa a ser part explícita de **ST-1b**.

### Cicle de vida de `device_secret_hash`

També quedava implícit i cal fixar-ho per escrit abans de codi:

1. **Emissió**: es genera al moment de l'aparellament (codi d'un sol ús, punt anterior) o en el primer `register_attendance_device` reeixit. El secret en clar es retorna **una única vegada** a l'estació (mai es torna a mostrar sencer); a BD només es guarda `device_secret_hash`.
2. **Ús**: l'estació l'envia (header/bearer) a `punch-from-station` i a qualsevol crida autenticada com a dispositiu; és la prova que "aquest client és aquesta estació", no substitueix l'autenticació de l'empleat que fitxa.
3. **Regeneració/revocació**: des de la pàgina de gestió (ST-1), un admin pot revocar el secret d'una estació (ex. tablet perduda/robada) — la revocació és immediata i l'estació deixa de poder fitxar fins que es torni a aparellar amb un nou codi. La UI d'"Edició" ha de deixar clar que revocar el secret **no esborra l'historial de fitxatges** passats.
4. Aquest cicle de vida passa a ser part explícita de **ST-1b/ST-3**, no només una menció a "Edició".

---

## Tres superfícies d'app (arquitectura tancada)

El document original no deixava clar **on** viu la "UI estació". Això no és un detall de redacció: cada opció té implicacions d'autenticació diferents. Decisió tancada:

| Superfície | App / ruta | Autenticació | Per a qui |
|------------|------------|--------------|-----------|
| **tenant-portal** | `apps/tenant-portal` | Login d'usuari tenant amb RBAC | Admins/managers: gestió d'estacions (ST-1), configuració, auditoria |
| **public-portal** (portal empleat) | `apps/public-portal` — `/e/{secret}`, `/portal/*` | Token personal permanent per empleat | Empleat individual: consultar horari, fitxar des del mòbil, generar QR d'identitat |
| **UI estació** | `apps/public-portal` — ruta dedicada `/station/*` (o app separada si cal escalar) | **`device_secret`** del dispositiu aparellat — no login d'usuari, no token d'empleat | Tablet/PC compartit al vestuari: molts empleats fitxen sense sessió personal |

**Per què no dins tenant-portal:** la tablet del vestuari no pot tenir una sessió d'admin oberta permanentment — qualsevol persona davant la pantalla tindria accés físic a permisos d'administració.

**Per què no dins `/portal/*`:** el portal empleat està dissenyat per **un sol empleat** amb token personal permanent. L'estació serveix **molts empleats** sense sessió personal; barrejar els dos contextos d'auth al mateix espai de rutes complica el model i amplia la superfície d'atac del token d'identitat.

**Per què l'escàner va aquí (decisió #4):** si l'escàner d'identitat estigués al portal públic (`/portal/*`), qualsevol navegador podria resoldre tokens d'identitat, no només dispositius d'estació controlats. Mantenir-lo aïllat a la UI estació (autenticada per `device_secret`) és coherent amb la decisió #1 (token curt signat).

L'escàner integrat (`@zxing/library` o equivalent) viu exclusivament a la UI estació. L'empleat genera el QR des del portal personal; l'estació només el resol via `resolve_attendance_identity_token`.

---

## Gestió d'estacions: pàgina d'administració (resposta directa)

Sí, ho havíem considerat (ST-1), però calia concretar-ho més. Proposta després de l'estudi de `my-app-jcm`:

- **Llista d'estacions** (tenant-portal, secció Attendance/Settings): taula amb nom, site, **ubicació** (camí complet des de `/locations`), `kind`, estat (`pending`/`active`/`suspended`/`retired`), últim `last_seen`, últim empleat fitxat.
- **Estat `pending`**: quan una estació nova s'auto-registra (§1) sense `site_id`/`location_id`, apareix a la llista amb badge "Pendent d'assignar" perquè l'admin no hagi de tocar físicament el dispositiu — es resol des del tenant-portal, no des de l'estació (millora respecte `my-app-jcm`).
- **Edició**: assignar/canviar `site_id`+`location_id` (selector d'arbre de locations), activar/suspendre, renombrar, regenerar/revocar el `device_secret_hash` — cada acció d'edició queda registrada a l'auditoria d'admin (ST-8). **No es pot activar sense `location_id`.**
- **Historial per estació** (ST-6): pestanya o drawer amb fitxatges d'aquest `device_id`, filtrable per data/empleat, amb export CSV (inclou columna ubicació).
- **Vista per ubicació** (ST-6b): des de `/locations` o des de registres — fitxatges agregats per `location_id` (totes les estacions de la zona).
- **Bloqueig local (ST-2b)**: PIN curt propi de l'estació per UX de kiosk — **obligatori establir-lo a l'aparellament** (sense valor per defecte), emmagatzemat com a hash a `attendance_devices.local_pin_hash`. No substitueix RBAC del tenant-portal.
- **Aparença/branding (ST-7, opcional/baixa prioritat)**: títol i logo personalitzats per estació — nice-to-have vist a `my-app-jcm`, útil si diverses seus/clients comparteixen la mateixa app d'estació però volen marca pròpia al totem.

---

## Decisions (estudiar abans de codi)

| # | Pregunta | Decisió | Estat |
|---|----------|---------|-------|
| 1 | QR empleat a estació porta URL del portal? | **Token curt signat pel servidor** (`issue/resolve_attendance_identity_token`). No replicar el JSON pla amb caducitat de `my-app-jcm`. | **Tancada** |
| 2 | Portal sense estació pot consultar horari? | **Sí per defecte.** `punch_only_at_stations` afecta només el **fitxatge**, no la consulta. Si algun dia cal bloquejar també la consulta, serà un flag explícit separat — no barrejar els dos comportaments sota un sol booleà. | **Tancada** |
| 22 | Granularitat de `punch_only_at_stations`? | **Cascada com la geo (E4), no només tenant.** Ordre: empleat → grup calendari → `sites.settings` → `tenants.settings` → `false`. `null` = heretar. **Knob massiu principal = grup de calendari** (`/attendance-mgmt/calendar` → Grups); site i tenant són defaults; empleat cobreix excepcions (teletreball dins d'un grup «kiosk»). **Rebutjat:** (a) només tenant/site — insuficient dins un mateix centre; (b) només `work_profile` — coupla malament canal amb semàntica de punch/consolidació; (c) cascada sense override empleat. Departament opcional més endavant si cal simetria amb geo. Veure §«ST-10b». | **Tancada** (2026-07-15) |
| 3 | Relació amb `shared_device` del portal | **Eliminar directament** quan ST-1 a ST-3 estiguin fets. Cap tenant real l'usa en producció; no cal capa de compatibilitat ni migració gradual. Si `shared_device` no bloqueja cap flux actiu, es pot treure abans o alhora que ST-3 per simplificar el disseny. Veure §"Eliminació de `shared_device`". | **Tancada** |
| 4 | Escàner integrat: on viu? | **Dins la UI estació** (`/station/*`, auth per `device_secret`), no dins `/portal/*` ni tenant-portal. Veure §"Tres superfícies d'app". | **Tancada** |
| 5 | Restricció de mètodes de fitxatge (manual/QR): a quin nivell? | **D per fases, no tot a ST-5:** Fase 1 → **B (per estació)** via `attendance_devices.allowed_methods` (ST-5). Fase 2 → **C (per empleat)** només si un client ho demana (backlog ST-5b, inspirat en `PunchPermissionsConfig` de `my-app-jcm`). | **Tancada** (fase 1); fase 2 oberta fins demanda |
| 6 | Codi de barres a més de QR? | **Fora d'abast inicial.** El token signat és el mateix payload; renderitzar-lo com a codi de barres seria només UI. Activar si un client demana lectors físics o targetes impreses. Veure §"Backlog: codi de barres". | **Tancada → ajornat** |
| 7 | PIN/bloqueig local d'estació | **Sí (ST-2b).** Obligatori a l'aparellament, sense default (`admin123` de `my-app-jcm` prohibit). Hash a `attendance_devices.local_pin_hash`. No substitueix RBAC. | **Tancada** |
| 8 | Historial/auditoria de fitxatges per estació + export CSV | ST-6 (per `device_id`) + **ST-6b** (per `location_id` i columna ubicació a registres). | **Tancada** |
| 9 | Tenant del dispositiu a `register_attendance_device` | Codi/QR d'aparellament d'un sol ús des del tenant-portal. Veure §"Registre de tenant...". | **Tancada** |
| 10 | Timestamp del fitxatge: qui mana? | **Online (estació/portal):** servidor `now()` com a `occurred_at`. **Offline (ST-9 V2):** `occurred_at` = instant del toc (cua); servidor valida i `received_at` = pujada. | **Tancada** (ampliada #34) |
| 11 | Resiliència de xarxa a l'estació | V1: **sense xarxa no es pot fitxar** (ST-9). Revisar cua local + reintent (V2) si ubicacions reals ho demanen. | **Tancada** (V1 = A) |
| 12 | Entropia i rate limiting del token curt | Longitud/entropia mínima (32 bytes CSPRNG → ≥43 base64url) + rate limiting a `resolve_attendance_identity_token` per IP/dispositiu. **Aparellament:** `assert_station_register_rate_limit` (20/15min/IP). **QR:** ST-11 ✅ (`20261050000001`). | **Tancada** |
| 13 | On es guarda el PIN de bloqueig local | **`attendance_devices.local_pin_hash`** (columna nova). Obligatori a l'aparellament, sense default. | **Tancada** |
| 14 | Auditoria d'accions admin sobre estacions | Registre (qui, què, quan) separat de l'historial de fitxatges. ST-8. | **Tancada → ST-8** |
| 15 | Geo GPS al punch des d'estació fixa? | **No.** Ubicació = `location_id` snapshot (+ noms). `geo_*` NULL; sense permís de geolocalització a la UI estació. Comparació opcional coords dispositiu vs location només com a validació anti-frau (ST-5 backlog), no com a dada per empleat. | **Tancada** |
| 16 | `location_id` obligatori al punch d'estació? | **Sí.** ST-3 omple `location_id` + `location_name_snapshot` + `device_name_snapshot` des de l'estació activa. Estació `active` requereix `location_id` assignada. | **Tancada** |
| 17 | Location sense `geo_coordinates` és vàlida? | **Sí.** Ubicacions organitzatives (cuina/sala/bancada) no requereixen GPS. `locations.geo_coordinates` és opcional. | **Tancada** |
| 18 | Empresa veu/exporta «on ha treballat» per ubicació? | **Sí (ST-6b + ST-6c):** columna ubicació, filtre, export CSV punches i resum hores per ubicació. | **Tancada** |
| 19 | Llista d'empleats a l'estació sense assignacions prèvies | **V1:** tots els actius del `site_id`. **ST-2a:** CRUD assignacions des de `/locations` + herència zones pare. | **Tancada** |
| 20 | Ordre identitat estació: DNI abans o després de triar nom? | **DNI abans** (mode `document_entry`). La llista és mode alternatiu; no demanar DNI després de seleccionar empleat. | **Tancada** (ST-18) |
| 21 | `entry_mode` per estació | Configurable: `employee_list` / `document_entry` / `qr_only` / `employee_list_and_document` + layout llista. | **Tancada** (ST-18) |
| 22 | Post-punch: countdown vs sessió | Interacció **pausa** countdown i manté sessió; inactivitat reinicia; «Tancar sessió» sempre visible. | **Tancada** (ST-18) |
| 23 | Historial a estació | Període configurable via `station-api` (mai portal); màx. 90 dies; `session_allow_history` per estació. | **Tancada** (ST-18e) |
| 24 | Zones fixes vs torns planificats | `/locations` = eligibility; **planificador de torns** = on cada dia (**ST-19**, `shift_slots.location_id`). | **Tancada** (ST-19) |
| 26 | Historial kiosk: via API estació | Read-only `station-api`; **prohibit** accés portal en dispositiu compartit. | **Tancada** (ST-18e) |
| 27 | Format document estació | `document_match` (`full`/`suffix`) per estació; entrada alfanumèrica (DNI/NIE amb lletra). | **Tancada** (ST-18a) |
| 28 | QR + PIN a estació | `qr_identity_confirm` per estació; per defecte sense PIN addicional. | **Tancada** (ST-18) |
| 29 | Lloc del dia | Torns planificats (ST-19), no només assignacions `/locations`. | **Tancada** (ST-19) |
| 30 | `entry_mode` default | **`document_entry`** en estació nova. | **Tancada** (ST-18) |
| 31 | Ubicació planificada ≠ estació | `block_wrong_scheduled_location` per estació; **default només avís**. | **Tancada** (ST-18c) |
| 32 | Rang historial kiosk | Màx. **90 dies** (`session_history_max_days`). | **Tancada** (ST-18e) |
| 33 | Col·lisió document (DNI) | `full` → document complet; `suffix` → mínim N, entrada pot ser completa o més llarga; **>1 coincidència → llista per triar**. | **Tancada** (ST-18a) |
| 34 | Timestamp offline | Online: `occurred_at` servidor. Offline sync: `occurred_at` toc local + validació skew; `received_at` pujada. | **Tancada** (ST-9 V2) |
| 35 | ST-9 V2 i producció | Offline a prod només amb ST-9 V2 fiable; prod online-only (V1) vàlid sense V2. | **Tancada** (ST-9 V2) |

---

## Eliminació de `shared_device` (decisió #3)

`shared_device` al portal empleat era un pont temporal per tablets compartides (outbox a `sessionStorage`, sense refresh automàtic, timeout idle). Amb estacions reals (`attendance_devices` + `device_secret`), aquest camí queda obsolet.

Com que **cap tenant real usa `shared_device` en producció** (encara en desenvolupament local):

- **No cal migració gradual** ni període de transició.
- **Eliminar directament** el flag i tot el codi associat quan ST-1 a ST-3 estiguin fets (o abans, si no bloqueja cap flux actiu).
- No mantenir dos camins de codi per un flag que ningú ha fet servir mai.
- Actualitzar [`plan-employee-portal-access-v2.md`](./plan-employee-portal-access-v2.md) §7 per reflectir l'eliminació (no només "deprecar quan estació cobreixi vestuari").

---

## Backlog: codi de barres (decisió #6, ajornat)

Fora d'abast inicial (no ST-4). El token signat (`issue_attendance_identity_token`) ha de ser **agnòstic del format de renderització** (QR avui, codi de barres demà) perquè afegir-lo sigui només UI, no canvi d'arquitectura.

**Quan interessa a un client:**
- Lectors físics USB/Bluetooth ("keyboard wedge") — més barats i robustos que càmera en vestuaris industrials, poca llum, codis bruts.
- Alta rotació en canvis de torn (fàbrica, hostaleria) — lector làser més ràpid que obrir càmera + enfocar QR.
- Targetes d'identificació físiques impreses (magatzems, hospitals) — l'empleat no necessita mòbil per generar el codi.
- Entorns amb guants/mans brutes (cuina, taller) — passar targeta rígida per lector vs. manipular mòbil.

**Quan NO val la pena:** oficines o negocis petits amb una tablet i pocs empleats — QR via càmera cobreix el cas sense cost de hardware.

Activar com a fase futura (p. ex. ST-4b) només si un client ho demana.

---

## Esquelet de fases (provisional)

| Fase | Entregable |
|------|------------|
| ST-1 | Pàgina de gestió d'estacions al tenant-portal: llista + alta/edició `attendance_devices`, estat `pending`, generació de codis d'aparellament d'un sol ús, selector d'ubicació (`/locations`) |
| ST-1b | `api.register_attendance_device` amb codi d'aparellament (decisió #9) + cicle de vida complet de `device_secret_hash` + `local_pin_hash` obligatori a l'aparellament (decisió #7, #13) |
| ST-2 | UI estació (`/station/*` a public-portal, auth per `device_secret`): selecció manual d'empleat, **sense GPS**, feedback «Has fitxat a: {ubicació}» |
| ST-2b | Bloqueig local (PIN kiosk): validació de `local_pin_hash` per accions sensibles a la UI estació; sense default |
| ST-3 | `punch-from-station` Edge + `record_time_punch`: timestamp servidor (#10), **`location_id` + snapshots** (#16), **geo NULL** (#15), `source IN ('station','qr')`, ampliar CHECK `source` amb `qr` + **eliminació de `shared_device`** (#3) |
| ST-4 | QR: `issue_attendance_identity_token` / `resolve_attendance_identity_token` (token signat; entropia mínima + rate limiting, decisió #12); escàner integrat només a UI estació (decisió #4) |
| ST-5 | Restricció de mètodes **per estació** (`allowed_methods`, decisió #5 fase 1) + geo anti-frau opcional (comparar coords tablet vs location; validació només, geo NULL al punch). |
| ST-5b | *(backlog)* Restricció de mètodes **per empleat** — només si un client ho demana (decisió #5 fase 2) |
| ST-6 | Historial de fitxatges filtrat per `device_id` + export CSV amb ubicació (decisió #8) |
| ST-6b | **Visibilitat per ubicació:** columna/filtre per `location_id` a registres, export punches per empleat/ubicació, enllaços des de `/locations` |
| ST-6c | 🟢 MVP local | Resum agregat «hores per ubicació» per empleat/període + export CSV |
| ST-7 | 🟢 MVP local | Aparença/branding per estació (títol, logo) — opcional, baixa prioritat |
| ST-8 | Auditoria d'accions admin sobre estacions (decisió #14) |
| ST-9 | Resiliència de xarxa: V1 online-only (flag OFF); V2 EX-05.2–05.6 ✅ |
| ST-4b | *(post-MVP ST-4b)* Codi de barres: mateix token signat, renderització 1D + suport lectors físics (decisió #6) |
| ST-2a | 🟢 MVP local | CRUD `attendance_location_assignments` des de `/locations` + RPC `employee_can_punch_at_location` |
| ST-10 | ✅ Cascada | EX-02.1 + EX-02.1b (decisió #22) |
| ST-18 | 🟡 Core+18a+PIN | EX-02.2–02.4. Pendents 18b/c/d/e |
| ST-10b…ST-19 | ⚠️ parcial | ST-10b ✅; ST-19 schema ✅ EX-03.4; ST-18c ✅ EX-04.5; ST-18d ✅ EX-04.6; ST-16 ✅ EX-04.7. Veure [`estudi-station-punch-ux-v2.md`](./estudi-station-punch-ux-v2.md) |

### Ordre d'implementació recomanat

```
ST-1 → ST-1b → ST-2 + ST-2b → ST-3 → ST-6b (mínim: columna ubicació + export)
  → ST-6 (historial per estació) → ST-4 (QR) → ST-5 → ST-8 → ST-7
```

**MVP usable (vestuari real):** ST-1 + ST-1b + ST-2 + ST-2b + ST-3 + **ST-6b** (columna ubicació als registres).

---

## ST-10b — Cascada «només fitxar a estacions» (decisió #22)

### Problema de producte (V1 insuficient)

Amb el flag **només a nivell tenant** (EX-02.1 / ST-10 V1):

- Un sol teletreballador o comercial itinerant obliga a deixar el punch mòbil obert **per a tothom**, o bé a tancar-lo i deixar sense canal els qui no poden anar a la tablet.
- L'estació fixa **no és accessible per Internet**: no és un substitut del portal personal per a feina remota.
- Multi-site ajuda (magatzem A kiosk-only vs seu B mòbil), però **dins el mateix site** solen conviure cohorts diferents (oficina vs camp vs teletreball).

### Alternatives descartades

| Opció | Per què no |
|-------|------------|
| Només tenant (V1) | Massa groller; trenca plantilles mixtes |
| Només site | No separa cohorts dins d'un centre |
| Només `work_profile` (`fixed_site` ⇒ kiosk) | Coupla malament: oficinistes amb `fixed_site` poden necessitar mòbil temporalment; itinerants poden usar estació; `hybrid`/`delivery` queden ambigus. El perfil governa **tipus de punch i consolidació**, no el **canal** |
| Només empleat, sense grup | Operativament car; els cohorts ja es gestionen com a grups de calendari |
| Només grup, sense override empleat | Un teletreball puntuals dins d'un grup «fàbrica» no té escapatòria |

### Solució adoptada — mateixa família que la geo (E4)

Cascada **més específic → default** (`null` = heretar):

| Prioritat | Nivell | Emmagatzematge | On configurar (UI) |
|-----------|--------|----------------|-------------------|
| 1 | Empleat | `employees.punch_only_at_stations boolean NULL` | Fitxa empleat (Informació / Control horari) |
| 2 | Grup calendari | `calendar_groups.punch_only_at_stations boolean NULL` | `/attendance-mgmt/calendar` → **Grups** (mateix patró UX que geo: Heretar / Només estacions / Portal+estacions) |
| 3 | Site | `sites.settings.punch_only_at_stations` | Settings site (ja llegit pel resolver V1; UI opcional a ST-10b) |
| 4 | Tenant | `tenants.settings.punch_only_at_stations` | Configuració → Control horari (ja existeix) |
| 5 | Default | `false` | Sistema — punch mòbil/portal permès |

**Resolver canònic:** `data.resolve_punch_only_at_stations(p_employee_id)` (substituir / enriquir `is_punch_only_at_stations` actual).

**Enforcement:** sense canvi de contracte — `assert_portal_mobile_punch_allowed` i el portal `/punch` consumeixen el valor **resolt per empleat**. Estació / `source IN ('station','qr')` sempre permisos.

**Departament:** no al MVP de ST-10b (la geo sí el té). Afegir-lo només si cal simetria operativa; els cohorts de fitxatge s'alineen millor amb grups de calendari que amb organigrama.

### Per què el grup de calendari és el knob massiu correcte

- Ja és l'eix on l'operació agrupa gent amb el mateix conveni/patró laboral (`calendar_group_id` a l'empleat).
- La UI de Grups ja exposa overrides booleans heretables (`attendance_geo_enabled`) i polítiques de registre.
- Un grup «Fàbrica / vestuari» pot forçar kiosk; un grup «Comercials / teletreball» pot deixar portal obert, sense tocar cada fitxa.
- Multi-site: grups **globals** (`site_id` null) vs grups **per site** ja existents — cobreix el cas «mateixa empresa, centres amb regles diferents» sense un sol booleà tenant.

No redefineix el grup com a «estació»: continua sent calendari + política; el canal de fitxatge és **un booleà heretable més**, igual que la geo.

### Relació amb altres pieces

| Piece | Relació |
|-------|---------|
| Decisió #2 | Intacta: la política resolta només bloqueja **fitxatge** portal/mòbil; consulta i QR d'identitat queden |
| ST-5 / ST-5b | Ortogonal: mètodes manuals/QR **a l'estació**, no «portal vs estació» |
| `attendance_work_profile` | Ortogonal: tipus de punch / motor consolidació |
| ST-18b | El portal amb política resolta `true` continua amagant botons i prioritzant QR |

### Abast d'implementació (EX-02.1b)

1. Migració: columnes nullable a `calendar_groups` i `employees`; upsert grup + update empleat; `resolve_punch_only_at_stations`.
2. Patch `record_time_punch` / assert i `employee_portal_get_today` per usar el resolver per empleat.
3. UI Grups: camp Heretar / Només estacions / Permetre portal (reutilitzar patró `AttendanceGeoEnabledField`).
4. UI fitxa empleat: mateix control amb herència visible (valor efectiu + origen).
5. Mantindre secció tenant com a **default d'empresa**.
6. Tests: ST-T18 ampliat o ST-T18b (tenant true + grup false → portal OK; grup true + empleat false → portal OK; empleat true → 403).

**Rollback:** desactivar columnes (null a tot arreu) torna a comportament tenant/site V1.

**No-objectius ST-10b:** mètodes per empleat (ST-5b); bloquejar consulta d'horari; lligar automàticament a `work_profile`.

---

## No confondre

| | Portal personal (`/e/{secret}`, `/portal/*`) | UI estació (`/station/*`) | tenant-portal |
|---|---------------------------------------------|---------------------------|---------------|
| Auth | Token per empleat, permanent | `device_secret` del dispositiu | Login usuari + RBAC |
| Per a qui | Un empleat | Molts empleats, sense sessió personal | Admins/managers |
| Dades visibles | Horari, historial, absències | Només fitxar (+ feedback ubicació) | Gestió, auditoria, informes per ubicació |
| Ubicació al punch | GPS opcional (política tenant) | **Ubicació organitzativa** (`/locations`) — **sense GPS** | Consulta/export per ubicació (ST-6b) |
| Escaneig | Genera QR d'identitat (mòbil) | Resol QR escanejat (càmera integrada) | — |
| Fitxar amb política resolta `punch_only_at_stations=true` | Bloquejat (consulta sí; QR d'identitat sí) | Sempre permès | Config cascada ST-10b |
| Gestió | Autoservei empleat | — | Centralitzada (ST-1) + `/locations` |

Detall operatiu del portal: [`plan-employee-portal-access-v2.md`](./plan-employee-portal-access-v2.md).
