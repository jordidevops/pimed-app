# EX-02…EX-05 — Smoke checklist: fitxatges, horaris, calendaris i estacions

> **Àmbit:** verificació manual sistemàtica del frontend + dades noves dels paquets tancats a [`EXECUTION.md`](./EXECUTION.md) (EX-02, EX-03, EX-04, EX-05.1–05.3).  
> **No cobreix:** EP8 registre mensual ([`ep8-smoke-checklist.md`](./ep8-smoke-checklist.md)), hub portal ([`ep-acc8-hub-smoke-checklist.md`](./ep-acc8-hub-smoke-checklist.md)), EX-05.4+ (quarantena / CLOCK_SKEW encara actiu).  
> **Estat:** pendent execució — marca `[x]` quan passi.

### On provar cada secció?

| Secció | App | Rol |
|--------|-----|-----|
| **0** | SQL Editor Supabase | — |
| **A–F, H** | **tenant-portal** | Owner / manager Acme |
| **G, I, J** | **public-portal** | Empleat (token) + kiosk `/station` |
| **K** | Creuat (tenant + portal + SQL) | Validació resolver / anomalies |

---

## Prerequisits

| # | Requisit |
|---|----------|
| P1 | Supabase local en marxa + migracions fins a `20261031000001` (EX-05.3) aplicades. |
| P2 | Seed: `seed.sql` + `supabase/seeds/attendance_demo.sql` (automàtic amb `db reset`). |
| P3 | Fixtures smoke: executar [`supabase/seeds/smoke_ex_attendance_fixtures.sql`](../../../supabase/seeds/smoke_ex_attendance_fixtures.sql) a l’**Editor SQL**. |
| P4 | Edge Functions: `station-api`, `employee-portal-api` (i cua assistència si vols veure recompute). |
| P5 | **tenant-portal** (`apps/tenant-portal`, Vite) — usuari manager/owner Acme. |
| P6 | **public-portal** (`apps/public-portal`, port **3002**) — portal empleat + kiosk. |
| P7 | Navigador: una finestra gestió + una (o tablet) per `/station` + una per `/e/…`. |

**URLs locals (ajustar port Vite si cal):**

| Superfície | URL |
|------------|-----|
| Fitxatge personal | `/attendance` |
| Control horari | `/attendance-mgmt/dashboard` |
| Planificació calendari | `/attendance-mgmt/calendar` |
| Horaris (grid) | `/attendance-mgmt/planning/schedules` |
| Torns | `/attendance-mgmt/planning/shifts` |
| Config control horari | `/settings/attendance-control` |
| Estacions | `/settings/attendance-stations` |
| Kiosk | `http://localhost:3002/station` |
| Portal Montserrat | `http://localhost:3002/e/ep0-dev-acme-montserrat` |
| Portal Laia | `http://localhost:3002/e/ep0-dev-acme-laia` |
| Portal Marta | `http://localhost:3002/e/ep0-dev-acme-marta` |

### Persones i polítiques després dels fixtures

| Empleat | Document | PIN | `punch_only` resolt | Ús al smoke |
|---------|----------|-----|---------------------|-------------|
| Montserrat `…005` | `SMOKE005A` | `1234` | `false` (herència) | Fitxatge portal + kiosk + torns |
| Laia `…008` | `SMOKE008B` | `1234` | `false` (override) | Portal amb botons |
| Marta `…012` | `SMOKE012C` | `1234` | `true` (override) | Portal sense punch → QR estació |

### Ordre recomanat

```
0 SQL fixtures → A config → B calendaris → C horaris → D torns (publicar)
→ E fitxatges → F tauler → G estacions admin → H kiosk → I portal → J offline → K creuat
```

---

## 0. SQL — fixtures i sanity

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| 0.1 | Obrir Editor SQL → enganxar `smoke_ex_attendance_fixtures.sql` → Run | `COMMIT` sense error; NOTICE seed OK | [ ] |
| 0.2 | Resultat `today` del resolver | `day_type` laborable (`working`) o coherent amb festiu/absència; `base_source` / `labor_source` omplerts (no `none` en dia laborable Taller) | [ ] |
| 0.3 | Resultat `tomorrow_override` | `day_type = non_working`, `labor_day_type` vacation (o equivalent) | [ ] |
| 0.4 | Taula documents/PIN | Montserrat/Laia/Marta amb `document_id` SMOKE*; `tokens_with_pin ≥ 1`; Marta `resolved_punch_only = true` | [ ] |
| 0.5 | (Opcional) Regenerar punches demo | `SELECT data.seed_acme_attendance_punches();` si el tauler està buit | [ ] |

**Sense fixtures:** el seed ja dóna grups, base setmanal ADR-0003, pauses i punches. Els fixtures afegeixen documents, PIN, política ST-10b, plantilla de torn draft i override de demà.

---

## A. Configuració tenant — `/settings/attendance-control`

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| A.1 | Obrir pàgina com a manager | Carrega seccions (nòmina, geo, pauses/absències, estació, etc.) sense error | [ ] |
| A.2 | Secció **Fitxatge només a estacions** (ST-10) | Toggle tenant visible; valor inicial `false` després fixtures | [ ] |
| A.3 | Activar temporalment tenant `punch_only_at_stations` → desar | Persistit; preview/efecte coherent a fitxa empleat | [ ] |
| A.4 | Revertir a `false` | Torna a l’estat smoke | [ ] |
| A.5 | Tipus de pausa / absència | Llista no buida (seed Acme); edició bàsica no trenca la pàgina | [ ] |

---

## B. Calendaris laborals — `/attendance-mgmt/calendar`

Referència operativa: [`calendaris-laborals.md`](../../help/horaris/calendaris-laborals.md) · ADR-0003.

### B1. Pestanya Calendari

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| B1.1 | Obrir graella (empresa / local Gràcia) | Dies pintats; dl–dv laborables via base recurrent (no cal override per cada dia) | [ ] |
| B1.2 | Seleccionar un dia futur → override `vacation` o `non_working` | Desat; color/etiqueta canvien | [ ] |
| B1.3 | Revertir override | Torna al patró base | [ ] |
| B1.4 | Panell cascada / llegenda | Mostra capa guanyadora (grup / empleat / festiu / base) | [ ] |

### B2. Pestanya Grups

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| B2.1 | Llista grups | Oficina, Taller Gràcia, Obres Sants | [ ] |
| B2.2 | Obrir **Taller Gràcia** → editor base setmanal | Dl–Dv 07:00–15:00; Ds/Dg no laborable | [ ] |
| B2.3 | Canviar un dia del grup (ex. divendres fi 14:00) → desar | Persistit; empleats del grup sense override individual reflecteixen el canvi a calendari/horari | [ ] |
| B2.4 | Restaurar 15:00 | Estat seed recuperat | [ ] |
| B2.5 | Camp `punch_only_at_stations` del grup | Herència / força sí / força no; desar sense error | [ ] |
| B2.6 | Assignació empleats al grup | Montserrat al Taller (seed); canvi temporal i revert opcional | [ ] |

### B3. Festius / pauses / vacances

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| B3.1 | Pestanya **Festius** | Calendari Catalunya assignat; dies festius visibles | [ ] |
| B3.2 | Import Nager (si API disponible) o alta manual d’un festiu | Apareix a graella | [ ] |
| B3.3 | **Tipus de pausa** | CRUD / llista activa (necessari per botons kiosk ST-16) | [ ] |
| B3.4 | **Configuració** entitlements vacances | Any actual editable | [ ] |

### B4. Fitxa empleat — calendari + base individual

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| B4.1 | `/employees/…005?tab=work_calendar` | Calendari Montserrat; demà mostra override smoke (vacances) | [ ] |
| B4.2 | Editor base setmanal **empleat** (Marta té override seed) | Intervals propis visibles; netejar un dia hereta del grup | [ ] |
| B4.3 | Info empleat: `punch_only` + grup | Preview política coherents amb fixtures | [ ] |

---

## C. Horaris (vista planificador) — `/attendance-mgmt/planning/schedules`

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| C.1 | Vista setmana / mes | Graella amb empleats; dies laborables amb franges | [ ] |
| C.2 | Filtre per grup Taller | Només empleats del grup | [ ] |
| C.3 | Mode previst vs real / discrepàncies | Badges sense crash; dades coherents amb seed punches | [ ] |
| C.4 | Demà Montserrat | Dia no laborable (override smoke) | [ ] |

*Nota:* la graella és sobretot lectura/comparació; l’edició d’horari viu a Calendari / Grups / fitxa.

---

## D. Torns i publicació — `/attendance-mgmt/planning/shifts` (EX-04)

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| D.1 | Obrir planificador setmana actual | Plantilla **Smoke Matí Taller** visible (o crear-ne una) | [ ] |
| D.2 | CRUD plantilla: color / hores / ubicació per defecte Magatzem | Desa; `default_location_id` ST-19 | [ ] |
| D.3 | Slots draft dilluns (Magatzem) + dimarts (Muntatge) per Montserrat | Visibles al grid (fixtures) o assignats manualment | [ ] |
| D.4 | Multi-slot mateix dia (opcional): 2n tram overlapping | Toast/anomalia `SHIFT_OVERLAP` o bloqueig | [ ] |
| D.5 | **Publicar setmana** → diàleg **preflight** | Llista warnings; cal acceptar si n’hi ha (`warnings_accepted`) | [ ] |
| D.6 | Confirmar publicació | Slots `published` + `publication_id`; toast OK | [ ] |
| D.7 | SQL: `SELECT status, publication_id, slot_date FROM data.shift_slots WHERE id IN ('4900…f001','4900…f002')` | `published` + UUID lot | [ ] |
| D.8 | Republish / diff (si UI mostra) | Diff o nou lot sense corrompre historial | [ ] |
| D.9 | Intent editar/publicar període tancat (si tens mes bloquejat) | Error `MONTH_CLOSED` / `payroll_locked` | [ ] |
| D.10 | Calendari general: esdeveniment `shift_slot` | Deep-link o entrada visible post-publicació | [ ] |

---

## E. Fitxatges — personal i equip

### E1. Personal tenant — `/attendance`

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| E1.1 | Login com a usuari amb `hasMyEmployee` | Entrada/sortida, pauses, card horari | [ ] |
| E1.2 | IN → pausa → fi pausa → OUT | Estats UI correctes; timeline del dia | [ ] |
| E1.3 | Card «estat horari» | Coherent amb resolver (EX-03) | [ ] |
| E1.4 | Historial `/attendance/record` | Dies amb punches seed | [ ] |

### E2. Equip — `/attendance-mgmt/records`

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| E2.1 | Filtres data / empleat / ubicació | Resultats filtrats | [ ] |
| E2.2 | Detall dia + aprovació draft | Flux sense error | [ ] |
| E2.3 | Export inspecció / punches (smoke ràpid) | Fitxer o JSON sense 500 | [ ] |

---

## F. Tauler — `/attendance-mgmt/dashboard` (EX-03.6)

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| F.1 | Obrir tauler «avui» | Llista empleats programats | [ ] |
| F.2 | Empleat amb absència/festiu avui | **No** surt com a «programat treball» (resolver canònic) | [ ] |
| F.3 | Després de publicar slot Montserrat (si avui = dilluns slot) | Horari/ubicació planificada reflectits | [ ] |
| F.4 | Incidències / pauses obertes | Montserrat pot tenir pausa oberta seed «ahir» — resolució UI | [ ] |

---

## G. Estacions — admin — `/settings/attendance-stations` (EX-01/02/04)

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| G.1 | Generar codi d’emparellament (site Gràcia, ubicació **Magatzem electric**) | Codi temporal visible | [ ] |
| G.2 | Després d’emparellar al kiosk (§H): estació a la llista | Nom, site, location, estat `active` | [ ] |
| G.3 | Preset **estricte** / **ràpid** / **QR** | Camps UX s’omplen; desar | [ ] |
| G.4 | `entry_mode = document_entry` + confirm `portal_pin` | Desa | [ ] |
| G.5 | ST-18c: warn ubicació ON, block OFF | Desa | [ ] |
| G.6 | ST-18d: allow unassigned ON, warn ON | Desa | [ ] |
| G.7 | `session_allow_history` OFF (default) | Desa | [ ] |
| G.8 | Mètodes: manual + QR | Desa | [ ] |
| G.9 | Revocar secret (prova controlada) | Kiosk demana re-emparellar; no queda secret a `localStorage` | [ ] |
| G.10 | Audit / historial canvis | Entrades de config visibles | [ ] |

**Valors recomanats per la resta del smoke (després G.9 si has revocat, re-emparella):**

- Ubicació estació = Magatzem `…0002`
- entry_mode = `document_entry` (i una passada amb `employee_list`)
- identity_confirm = `portal_pin`
- warn_wrong_scheduled_location = true, block = false (després provar block)
- allow_unassigned_punch = true, warn = true
- session_allow_history = true només per §H historial

---

## H. Kiosk — `http://localhost:3002/station` (EX-02, EX-04.5–04.7, EX-05)

### H1. Emparellament i sessió

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| H1.1 | Obrir `/station` sense cookie | Pantalla emparellament | [ ] |
| H1.2 | Introduir codi + PIN local | Registre OK; cookie HttpOnly `Path=/api/station` (DevTools → Application) | [ ] |
| H1.3 | Recarregar | Sessió restaura **sense** secret a `localStorage` | [ ] |
| H1.4 | Heartbeat / badge connexió | Estació viva al tenant (si UI mostra) | [ ] |

### H2. Identitat ST-18a / PIN ST-18

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| H2.1 | Mode document: introduir `SMOKE005A` | Sessió Montserrat (anti-enumeració: doc inventat → missatge genèric) | [ ] |
| H2.2 | PIN `1234` | Challenge OK | [ ] |
| H2.3 | PIN incorrecte ×N | Lockout temporal; missatge clar | [ ] |
| H2.4 | Mode llista + tap_name / portal_pin | Flux alternatiu OK | [ ] |

### H3. Punch, pauses ST-16, ubicació ST-18c/d

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| H3.1 | IN (amb assignació publicada avui si aplica) | Punch OK; flash confirmació | [ ] |
| H3.2 | Botons pausa (configs tenant) | `break_start` / `break_end` segons estat dia | [ ] |
| H3.3 | OUT | Estat outside; sessió es buida / waiting | [ ] |
| H3.4 | **ST-18c warn:** dia amb slot a Muntatge + estació Magatzem | Banner/avís `WRONG_SCHEDULED_LOCATION`; punch permès si block OFF | [ ] |
| H3.5 | Activar **block** ubicació → reintent | Punch bloquejat | [ ] |
| H3.6 | **ST-18d:** empleat sense slot publicat avui | Warn / allow segons toggles; anomalia `OUTSIDE_ASSIGNMENT` si warn | [ ] |
| H3.7 | Desactivar allow unassigned | Punch bloquejat | [ ] |

### H4. QR estació ST-18b + historial ST-18e

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| H4.1 | Portal Montserrat → `/portal/station-qr` mostra QR | QR visible | [ ] |
| H4.2 | Kiosk mode QR escaneja / resol | Identitat OK; token **no** consumit fins al punch | [ ] |
| H4.3 | Punch amb QR | Èxit; reutilitzar mateix token → error | [ ] |
| H4.4 | Historial amb `session_allow_history=false` | No accessible o demana reauth | [ ] |
| H4.5 | Historial ON + PIN | Màx. 90 dies; read-only | [ ] |

### H5. Privacitat / presets EX-02.7

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| H5.1 | Idle waiting → auto-blank | Pantalla buida / mask noms | [ ] |
| H5.2 | Canvi d’empleat consecutiu | Cap dada de l’anterior visible | [ ] |

---

## I. Portal empleat — public-portal (EX-02.1, EX-04.4)

| # | Pas | On | Resultat esperat | OK |
|---|-----|-----|------------------|-----|
| I.1 | Bootstrap `/e/ep0-dev-acme-montserrat` | portal | Redirect `/portal/punch`; secret no queda a la URL | [ ] |
| I.2 | Fitxatge Montserrat | `/portal/punch` | Botons IN/OUT visibles (`punch_only=false`) | [ ] |
| I.3 | Horari | `/portal/schedule` | Intervals Taller; demà no laborable (override) | [ ] |
| I.4 | **Els meus torns** | `/portal/shifts` | Només slots **published**; draft no surt | [ ] |
| I.5 | Laia | `/portal/punch` | Botons OK | [ ] |
| I.6 | Marta (`punch_only=true`) | `/portal/punch` | **Sense** botons punch; CTA / enllaç a QR estació | [ ] |
| I.7 | Marta QR | `/portal/station-qr` | QR usable al kiosk | [ ] |
| I.8 | Nav «QR estació» | sidebar | Visible i separat de Fitxatge | [ ] |

---

## J. Offline — portal + kiosk (EX-05.1–05.3)

> EX-05.4 (CLOCK_SKEW / quarantena) **no** està tancat: no fallis el smoke per absència de quarantena.

| # | Pas | On | Resultat esperat | OK |
|---|-----|-----|------------------|-----|
| J.1 | DevTools → Offline → IN al portal | tenant o portal | Encua a IndexedDB; banner pendents | [ ] |
| J.2 | Online de nou | | Drain via `sync_time_punches` / `/punch/sync`; punch a BD | [ ] |
| J.3 | Reintent mateix `client_op_id` | | Idempotent (sense duplicat) | [ ] |
| J.4 | Kiosk Offline → punch identificat | `/station` | Outbox Dexie `attendance_station_outbox`; banner | [ ] |
| J.5 | Drain kiosk | | `occurred_at` = hora toc; `received_at` ≈ pujada (SQL) | [ ] |
| J.6 | SQL opcional | Editor | `SELECT occurred_at, received_at, client_op_id FROM data.time_punches ORDER BY received_at DESC LIMIT 5;` | [ ] |

---

## K. Validacions creuades (resolver + anomalies)

| # | Pas | Resultat esperat | OK |
|---|-----|------------------|-----|
| K.1 | Després de publicar: portal «Els meus torns» = grid manager | Mateixes hores/ubicació | [ ] |
| K.2 | SQL `data.resolve_employee_work_plan(Montserrat, dilluns)` | `labor_source` inclou published_shift; intervals del slot | [ ] |
| K.3 | Override vacation demà + slot published demà (si es crea) | Slot **no** converteix el dia a working (ADR-0001) | [ ] |
| K.4 | Anomalies ST-18c/d a BD / UI fitxatges | Files `WRONG_SCHEDULED_LOCATION` / `OUTSIDE_ASSIGNMENT` | [ ] |
| K.5 | Cascada ST-10b: grup força true + empleat NULL | Empleat del grup sense override → portal sense punch | [ ] |
| K.6 | Redirect legacy `/control-horari/…` | Va a `/attendance-mgmt/…` | [ ] |

---

## Matriu ràpida paquet → proves

| Paquet | Seccions smoke |
|--------|----------------|
| EX-02.1 / 02.1b ST-10 | A.2–A.4, B2.5, B4.3, I.6–I.7, K.5 |
| EX-02.2–02.7 ST-18 UX | G, H1–H2, H4–H5 |
| EX-03.2-bis / 03.3 resolver | 0.2–0.3, B, C, F, I.3, K.2–K.3 |
| EX-03.4–03.5 ST-19 + recompute | D.2, D.6, F.3 |
| EX-03.6 dashboard | F |
| EX-04.1–04.3 publicació | D.5–D.9 |
| EX-04.4 portal torns | D.10, I.4, K.1 |
| EX-04.5–04.6 ubicació / unassigned | G.5–G.6, H3.4–H3.7, K.4 |
| EX-04.7 pauses estació | B3.3, H3.2 |
| EX-05.1–05.3 offline | J |

---

## Incidències / notes d’execució

| Data | Tester | Resultat global | Notes |
|------|--------|-----------------|-------|
| | | | |

**Neteja fixtures:** bloc comentat al final de `smoke_ex_attendance_fixtures.sql`.

**Suites SQL automatitzades (opcional abans del smoke UI):**

```powershell
# Exemples (des de l'arrel del repo; requerixen Docker DB)
Get-Content supabase/tests/attendance_station_tests.sql | docker exec -i supabase_db_cavalle-app psql -U postgres -d postgres
# Altres: attendance_calendar_tests, attendance_shifts_tests, attendance_*_ex0*.sql
# EX-09: attendance_retention_purge_ex091_tests.sql, attendance_inspection_access_ex092_tests.sql
```

---

## EX-09 — Retenció legal + enllaç inspecció

Smoke manual (Control horari + public-portal):

1. **Retenció OFF per defecte** — a `/settings/attendance-control`, secció Retenció: toggle OFF; desar; confirmar que no hi ha botó «Executar ara».
2. **Activar retenció** — activar toggle → cal checkbox «entenc que és irreversible»; anys ≥4; desar. (No cal esperar el cron en smoke.)
3. **Crear enllaç** — secció Accés inspecció: triar empleat, període ≤400 dies, TTL 7d → Generar → copiar URL (`/inspect/{id}?t=…`).
4. **Obrir públic** — obrir URL al public-portal → secret desapareix de la barra → veure punches raw + consolidat → descarregar JSON/CSV.
5. **Revocar** — a la llista, Revocar → refrescar la pàgina pública → 404 / enllaç no vàlid.
6. **Email opcional** — després de crear, enviar a una adreça de prova; comprovar Inbucket / cua `attendance.inspection_access`.

SQL:

```powershell
Get-Content supabase/tests/attendance_retention_purge_ex091_tests.sql | docker exec -i supabase_db_cavalle-app psql -U postgres -d postgres
Get-Content supabase/tests/attendance_inspection_access_ex092_tests.sql | docker exec -i supabase_db_cavalle-app psql -U postgres -d postgres
```

---

## Relacionats

- [`EXECUTION.md`](./EXECUTION.md) — ordre i estat paquets  
- [`STATUS.md`](./STATUS.md) — inventari funcional  
- [`plan-attendance-stations.md`](./plan-attendance-stations.md) — estacions  
- [`plan-attendance-legal-access.md`](./plan-attendance-legal-access.md) — EX-09 retenció + inspecció  
- [`adr-0003-weekly-recurring-base.md`](./adr-0003-weekly-recurring-base.md) — base setmanal  
- [`calendaris-laborals.md`](../../help/horaris/calendaris-laborals.md) — cascada calendari  
