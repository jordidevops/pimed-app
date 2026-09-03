# Estudi: UX fitxatge estació v2 + portal QR

> **Data:** 2026-07-15  
> **Estat:** Proposta d'estudi — **sense implementació** (excepte bugfix proxy QR)  
> **Relacionat:** [`plan-attendance-stations.md`](./plan-attendance-stations.md), ST-10, ST-16, ST-18 (nou)
> **Execució:** [`EXECUTION.md`](./EXECUTION.md) — paquets EX-01, EX-02, EX-04 i EX-05  
> **Auditoria:** [`revisio-exhaustiva-estacions-vs-codi.md`](./revisio-exhaustiva-estacions-vs-codi.md)

---

## Resum executiu

L'MVP d'estacions (ST-1…ST-8) cobreix el vestuari funcional, però la **selecció manual amb botons flotants** és fràgil: qualsevol pot fitxar per un altre i el context de «de qui» és poc visible. Demanar el DNI **després** de triar un nom a la llista és igualment contraintuïtiu — el flux natural és **DNI → confirmar identitat → fitxar**. Al portal empleat, el **QR d'identitat conviu amb el botó de fitxar mòbil**, cosa incoherent si el tenant obliga a fitxar només a estació.

Aquest document recull el redisseny proposat, el mapatge a fases futures i les decisions de configuració. **Pauses** al kiosk: **ST-16**. **Horari, avisos, sessió empleat i modes d'entrada**: **ST-18**. **On i quan treballar cada dia**: **ST-19**, primera entrega del [Planificador de torns V2](./plan-shift-planner-v2.md), que complementa les assignacions fixes de `/locations` i integra el torn publicat amb l'horari efectiu.

---

## Problemes actuals

### Estació (`/station`)

| Problema | Detall |
|----------|--------|
| Suplantació | Llista d'empleats → selecció → punch **sense verificar** que qui toca la pantalla sigui l'empleat. |
| Botons flotants | Barra fixa inferior (`fixed bottom-4`) amb in/out; el nom apareix a sobre però és fàcil confondre's en un kiosk compartit. |
| Només in/out | Sense horari, avisos, pauses ni timeline — diferent del portal empleat. |
| QR estació | Escaneja token → punch **directe** (mateix risc si algú mostra el QR d'un altre sense supervisió). |

### Portal empleat (`/portal/punch`)

| Problema | Detall |
|----------|--------|
| QR sobre el botó | `PortalIdentityQrCard` es renderitza **abans** de `PortalPunchActionPanel` — incoherent si ha de fitxar només a estació. |
| Fitxatge mòbil + QR | Amb QR visible, l'empleat pot fitxar des del mòbil **i** generar QR per estació a la mateixa pantalla. |
| Bug proxy | `POST /portal/api/identity/qr-token` retornava **404** perquè el proxy Next.js no tenia la ruta (l'Edge Function sí). **Corregit** afegint el handler al proxy. |

---

## Flux proposat — estació (modes d'entrada configurables)

### Principi: el DNI (o identificador) ha d'anar **abans**, no després

Demostrar identitat **després** d'haver triat un nom a la llista és contraintuïtiu: sembla que qualsevol pot triar un altre i després «verificar-se». El flux natural per a un kiosk compartit és:

1. **Qui sóc?** (DNI, PIN, QR…)
2. **Confirmació** («Ets *Anna García*?»)
3. **Què vols fer?** (pantalla de fitxatge)

La llista d'empleats segueix sent vàlida per a entorns de confiança o quan no hi ha DNI disponible, però com a **mode alternatiu**, no com a únic camí amb verificació posterior.

### Modes d'entrada configurables per estació

```typescript
// attendance_devices (ST-18)
entry_mode: 'employee_list' | 'document_entry' | 'qr_only' | 'employee_list_and_document'  // default: document_entry
employee_list_layout: 'cards' | 'compact_list'
document_match: 'full' | 'suffix'           // full = document complet; suffix = mínim N, entrada pot ser més llarga o completa
document_suffix_length: number              // default 4; només rellevant si document_match = 'suffix'
identity_confirm: 'none' | 'tap_name' | 'portal_pin'  // mode DNI / llista
qr_identity_confirm: 'none' | 'tap_name' | 'portal_pin'  // mode QR — independent, configurable
```

| `entry_mode` | Pantalla d'espera | Flux |
|--------------|-------------------|------|
| **`document_entry`** (default estació nova) | Teclat alfanumèric / lector DNI | DNI → resoldre empleat → confirmar nom → pantalla punch |
| **`employee_list`** | Graella o llista d'empleats | Selecció → (opcional `identity_confirm`) → pantalla punch |
| **`employee_list_and_document`** | Tabs o selector superior | DNI **o** llista — mateix destí (pantalla punch) |
| **`qr_only`** | Escàner actiu | QR portal → confirmar (si cal) → pantalla punch |

**Layout llista:** `cards` (targetes grans amb avatar, estat IN/OUT) vs `compact_list` (filtrable, densitat alta per >30 empleats).

### Diagrama — mode DNI (recomanat)

```
┌────────────────────┐     ┌─────────────────────┐     ┌─────────────────────────┐
│ Estació en espera  │ ──► │ Entrada DNI / doc.  │ ──► │ Confirmació identitat   │
│ (cap empleat actiu)│     │ (teclat o lector)   │     │ «Ets Anna García?» Sí/No│
└────────────────────┘     └─────────────────────┘     └───────────┬─────────────┘
                                                                    │
                                                                    ▼
                                                         ┌─────────────────────────┐
                                                         │ Pantalla fitxatge       │
                                                         │ (com /portal/punch)     │
                                                         └───────────┬─────────────┘
                                                                     │
                    ┌────────────────────────────────────────────────┘
                    ▼
         ┌──────────────────────┐     ┌─────────────────────────────┐
         │ Sessió empleat activa │ ──► │ Estació en espera (auto/botó)│
         │ countdown + historial │     │ (cap sessió personal oberta) │
         └──────────────────────┘     └─────────────────────────────┘
```

### Diagrama — mode llista (alternatiu)

```
┌────────────────────┐     ┌──────────────────────┐     ┌─────────────────────────┐
│ Llista empleats    │ ──► │ Confirmació identitat │ ──► │ Pantalla fitxatge       │
│ (cerca, avatar)    │     │ (tap nom / PIN, cfg.) │     │ (com /portal/punch)     │
└────────────────────┘     └──────────────────────┘     └───────────┬─────────────┘
                                                                     │
                    (mateix post-punch / sessió que mode DNI) ──────┘
```

### Pantalla de fitxatge personalitzada

Després de verificar identitat, **pantalla dedicada** (ruta interna p.ex. `/station/punch/[employeeId]` o estat «mode punch» a la mateixa pàgina) equivalent al portal:

- Capçalera clara: **nom + foto/avatar + ubicació estació** («Fitxes com a *Anna* a *Vestuari B*»).
- `PortalWorkScheduleStatusCard` (horari avui, avisos tardança/absència).
- Botó circular (`PortalPunchActionPanel`) — no barra flotant genèrica.
- Pauses (`PortalPauseButtonGroup` / `PortalPauseActiveButton`) quan ST-16 estigui actiu.
- Timeline del dia (opcional, configurable).

**Reutilització:** extreure components compartits de `PortalPunchPage` a `features/time-attendance/` o `features/employee-portal/components/punch/` per evitar duplicar lògica de `dayState`, pauses i horari.

### Resolució d'identitat per DNI

Nou endpoint `station-api`:

| Mètode | Ruta | Body | Resposta |
|--------|------|------|----------|
| POST | `resolve-employee-document` | `{ document_id }` | `{ employee_id, full_name, avatar_url?, pin_required }` o `not_found` |

- Cerca dins empleats actius del `site_id` de l'estació (no cal haver seleccionat abans).
- **Entrada alfanumèrica** — el DNI/NIE espanyol inclou lletra final; no assumir format fix ni només dígits (altres països: longitud i caràcters variables).
- **`document_match`** configurable per estació:
  - **`full`:** l'empleat introdueix el document **complet** (alfanumèric). Si hi ha **varis coincidències** (dades duplicades o error de càrrega), es mostra **llista d'empleats coincidents** per triar.
  - **`suffix`:** mínim `document_suffix_length` caràcters (default 4), però l'entrada pot ser el **document complet** o **més caràcters que el mínim** — es fa match per sufix normalitzat; si encara hi ha col·lisió, **llista per triar** (mateix comportament que `full`).
- Rate limit per IP/dispositiu (anti-enumeració).
- Flux després de resoldre (1 o N coincidències → tria si cal): pantalla **«Ets {nom}?»** (`identity_confirm: tap_name`) o PIN si configurat.

### Verificació addicional (després de resoldre identitat)

| `identity_confirm` | Quan | Detall |
|--------------------|------|--------|
| **`tap_name`** | Default mode DNI | Botons «Sí, sóc jo» / «No, tornar» — sense secret extra |
| **`portal_pin`** | Empleat amb PIN portal | `PinGate` + `POST verify-employee-pin` |
| **`none`** | Entorns de confiança | Només resolució DNI/QR + confirmació visual del nom a la capçalera punch |

El **PIN portal** complementa el DNI o QR (no els substitueix) quan cal seguretat extra — **configurable per estació** (`identity_confirm` per DNI/llista; `qr_identity_confirm` per QR, independent). Per defecte QR **sense** PIN addicional (`qr_identity_confirm: none` o `tap_name`). No té sentit demanar DNI *després* d'haver triat un nom a la llista — en mode llista, la verificació és `tap_name` o `portal_pin`, no DNI.

**Configuració** (per estació, amb override tenant):

```typescript
entry_mode: 'employee_list' | 'document_entry' | 'qr_only' | 'employee_list_and_document'  // default document_entry
employee_list_layout: 'cards' | 'compact_list'
document_match: 'full' | 'suffix'
document_suffix_length: number              // default 4
identity_confirm: 'none' | 'tap_name' | 'portal_pin'
qr_identity_confirm: 'none' | 'tap_name' | 'portal_pin'  // default none
session_idle_seconds: number                // default 60
session_return_countdown_seconds: number    // default 15
session_allow_history: boolean              // default **false** (PG-08; opt-in)
session_history_max_days: number            // default 90 — límit rang consulta
allow_unassigned_punch: boolean
warn_unassigned_punch: boolean
warn_wrong_scheduled_location: boolean      // default true
block_wrong_scheduled_location: boolean     // default false — només avís
```

Només oferir **PIN portal** si el tenant/empleat té PIN activat (mateixa regla que `/portal`).

### Sessió empleat i post-fitxatge

Després d'un fitxatge (o en entrar a la pantalla punch), l'estació entra en **sessió empleat**: un empleat identificat té la tablet «seva» temporalment. Això substitueix el model actual de «seleccionat + barra flotant».

**Estats de la UI estació:**

| Estat | Descripció |
|-------|------------|
| **`waiting`** | Mode espera — cap empleat actiu; mostra DNI / llista / QR segons config |
| **`employee_session`** | Empleat identificat — punch, pauses, historial, tancar sessió |
| **`success_flash`** | Feedback breu post-punch dins `employee_session` (banner verd + reinici countdown) |

**Countdown de retorn:**

1. Després de cada punch: banner d'èxit + **barra de progrés decreixent** (p.ex. 15 s).
2. Si l'usuari **interactua** (tocar pantalla, obrir historial, un altre punch): el countdown **es pausa** — l'usuari **roman a la sessió**, no es redirigeix enlloc.
3. Si passa **`session_idle_seconds`** sense interacció després de pausar: el countdown **es reinicia**.
4. Quan el countdown arriba a zero: **`endEmployeeSession()`** → torna a `waiting`.

**Historial dins la sessió** (si `session_allow_history: true`):

- Enllaç **«Consultar els meus fitxatges»** obre una subvista dins la mateixa sessió (no surt de l'estació).
- **Només via `station-api`** (`GET employee-history`) — **mai** enllaç ni redirecció al portal personal (`/portal/*`) en dispositiu compartit (decisió #26).
- Selector de període com `PortalHistoryPage`: setmana / mes / rang personalitzat.
- **Límit màxim 90 dies** (`session_history_max_days`, default 90) — el servidor rebutja rangs més amplis.
- Només lectura; sense export ni edició des del kiosk.

**Tancar sessió — sempre visible:**

- Botó fix **«Tancar sessió»** / **«Tornar a l'estació»** a la capçalera de `employee_session`.
- Acció immediata: esborra identitat en memòria, torna a `waiting` sense esperar countdown.
- És l'equivalent kiosk de «logout» — imprescindible en pantalla compartida.

**No fer:** redirigir a «consultar fitxatges d'avui» com a única opció en cancel·lar el countdown. Cancel·lar = quedar-se a la sessió amb totes les opcions disponibles.

### Flux QR a l'estació

Avui: escanejar QR → resoldre token → punch directe.

Proposta ST-18:

```
Escanejar QR ──► Resoldre token ──► Confirmació segons qr_identity_confirm (config. estació)
                                      ──► Pantalla fitxatge (employee_session)
```

Per defecte QR **sense PIN addicional**; si l'estació té `qr_identity_confirm: portal_pin`, llavors sí. Així el QR identifica l'empleat (com el DNI); el punch passa per la mateixa sessió i UI que la resta de modes.

---

## Zones fixes vs planificador de torns — on treballar

### Dos conceptes diferents (no barrejar)

| Concepte | Taula / UI | Canvia sovint? | Propòsit |
|--------|------------|----------------|----------|
| **Assignació de zona (eligibility)** | `attendance_location_assignments` — `/locations` → «Empleats de la zona» | **No** — configuració estructural | «Aquest empleat *pot* fitxar en aquesta zona» (permís màxim / lloc habitual) |
| **Torn planificat (operatiu)** | `shift_slots` — `/attendance-mgmt/planning/shifts` | **Sí** — setmanal/diari | «*Avui* treballes de 08:00 a 16:00 **a la Cuina**» |

Avui el planificador de torns només respon **QUAN** (`work_shifts` + `shift_slots`: empleat, data, horari). **No té `location_id`** — no pot dir **ON** treballar. Això deixa un buit per a empleats que canvien de lloc cada dia.

### Proposta d'integració (ST-19)

> Aquesta secció defineix el contracte mínim que necessita l'estació. La cascada autoritativa, publicació versionada, cobertura, vacants i autoservei es desenvolupen al [pla específic del Planificador de torns V2](./plan-shift-planner-v2.md).

**1. Schema — ubicació al torn**

```sql
-- ST-19 migration (esborrany)
ALTER TABLE data.work_shifts
  ADD COLUMN default_location_id uuid REFERENCES data.locations(id) ON DELETE SET NULL;

ALTER TABLE data.shift_slots
  ADD COLUMN location_id uuid REFERENCES data.locations(id) ON DELETE SET NULL;
-- location_id al slot override el default del work_shift; NULL = «sense ubicació concreta»
```

**2. UI planificador (`ShiftsPage`)**

- Columna o badge d'ubicació per slot (selector de `/locations` del site).
- Opcional: filtrar graella per zona.
- Herència: en assignar un `work_shift` amb `default_location_id`, omplir automàticament al slot.

**3. RPC «on ha d'anar avui»**

```text
api.get_employee_scheduled_locations(p_employee_id, p_date)
  → [{ location_id, location_path, shift_name, start_time, end_time, source: 'shift_slot' }]
```

Prioritat de resolució per avisos estació/portal:

```
1. shift_slots publicats avui amb location_id  →  font operativa (canvia cada dia)
2. attendance_location_assignments actives     →  fallback si no hi ha slot amb ubicació
3. Cap resultat                                →  sense avís específic (o avís genèric del site)
```

**4. Validació al punch (estació)**

| Capa | Pregunta | Acció |
|------|----------|-------|
| **Eligibility** (assignació fixa) | «Pot fitxar mai aquí?» | `employee_can_punch_at_location` — strict o warn (`ST-18d`) |
| **Planificació** (slot avui) | «Li toca aquí avui?» | Avis si `shift_slot.location_id` ≠ ubicació estació; **per defecte només avís** — bloqueig opcional per estació (decisió #31: errors admin, imprevistos, flexibilitat) |

Config estació (decisions tancades):

```typescript
warn_wrong_scheduled_location: boolean   // default true
block_wrong_scheduled_location: boolean  // default false — només avís; true = rebutja punch
```

El «lloc del dia» operatiu ve dels **torns planificats** (ST-19), no de les assignacions estàtiques de `/locations` (decisió #29).

**5. Relació amb ST-18c**

ST-18c («avis ubicació esperada») **depèn de ST-19** per tenir dades diàries fiables. Sense `location_id` als `shift_slots`, només podem avisar amb assignacions fixes (poc útil si canvien cada dia).

### Model mental per al client

```
/locations (assignacions)     = «Anna pot treballar a Cuina i a Sala»  (rarament canvia)
/planning/shifts              = «Dilluns Anna a Cuina, dimarts a Sala»  (canvia cada setmana)
/estació                      = «Estàs a Vestuari Cuina — avui et tocava Cuina ✓»
```

---

## Portal empleat — separació mòbil vs QR estació

### Principi

| Política tenant | Pantalla «Fitxar» (`/portal/punch`) | Tab / secció QR |
|-----------------|--------------------------------------|-----------------|
| Fitxatge mòbil permès (default) | Botó circular + pauses + horari | Tab «QR estació» (opcional, no per defecte al damunt del botó) |
| `punch_only_at_stations` (ST-10) | **Sense botó de fitxar** — horari, avisos, enllaços | **Només QR** (o pantalla principal = QR) |
| Mix (perfil peripatètic vs fix) | Segons `employee.punch_profile` | QR visible només si perfil «estació» |

### Navegació proposada

- `/portal/punch` — fitxatge mòbil (si permès).
- `/portal/station-qr` — QR d'identitat (nou tab o item de navegació).
- Si `punch_only_at_stations`: redirigir `/portal/punch` → horari + enllaç prominent a `/portal/station-qr`.

### Avis «on has d'anar avui»

Cas: empleat amb **torns planificats en ubicacions diferents** cada dia (hostaleria, retail, sanitat).

**Font de dades (ST-19):** `shift_slots` publicats amb `location_id` per `(employee_id, avui)`.

**Proposta (ST-18c + ST-19):**

- Al portal i a la pantalla `employee_session` de l'estació: targeta «Avui et correspon treballar a: *Cuina* (08:00–16:00)».
- Si fitxa en estació d'una altra zona: banner segons `warn_wrong_scheduled_location`.
- Si té slot avui **sense** `location_id`: fallback a assignacions fixes o missatge neutre.
- Múltiples slots el mateix dia (partit): llista de franges + ubicacions.

---

## Assignació estació / zona

### Comportament actual (MVP)

- Llista d'empleats: filtre per assignacions de zona; fallback a tots els actius del site.
- Punch RPC: **`employee_not_allowed_at_location`** → error dur, no es pot fitxar.

### Comportament proposat (configurable)

| `allow_unassigned_punch` | `warn_unassigned_punch` | Resultat |
|--------------------------|-------------------------|----------|
| `false` (default strict) | — | Error (com avui) |
| `true` | `true` | Banner groc «No estàs assignat a aquesta ubicació» + botó continuar |
| `true` | `false` | Permet sense avís (auditoria: flag `punched_outside_assignment`) |

Implementació: relaxar o parametritzar el `RAISE EXCEPTION` a `record_station_time_punch` / wrapper, o validar a `station-api` abans del RPC amb mode «warn».

---

## Mapatge a fases del pla

| ID | Àmbit | Prioritat | Notes |
|----|-------|-----------|-------|
| **Bugfix** | Proxy `identity/qr-token` | ✅ Fet | 404 Next.js → Edge |
| **ST-10** | `punch_only_at_stations` | Alta (prod) | V1 tenant fet (EX-02.1). **ST-10b:** cascada empleat → grup calendari → site → tenant (decisió #22 a `plan-attendance-stations.md`). Consulta horari sempre sí. |
| **ST-18** | UX estació v2: modes entrada + sessió empleat | Alta (UX) | DNI-first o llista configurable; pantalla punch; countdown + tancar sessió. Veure §Flux. |
| **ST-18a** | Resolució DNI + confirmació + PIN | Alta (seguretat) | `resolve-employee-document`, `verify-employee-pin`, UI `PinGate` / teclat DNI. |
| **ST-18b** | Portal: tab QR + layout segons ST-10 | ✅ EX-02.5 | `/portal/station-qr` + nav; QR fora de punch; CTA si `punch_only_at_stations`. |
| **ST-18c** | Avis «on toca avui» | Mitjana | Targeta portal + estació; **requereix ST-19** per dades diàries. |
| **ST-18d** | `allow_unassigned_punch` + warn | Mitjana | Config estació + relaxació RPC o capa API. |
| **ST-18e** | Historial dins sessió estació | ✅ EX-02.6 | `POST employee-history` + PIN; màx. 90 dies; default desactivat (PG-08). |
| **ST-19** | Ubicació al planificador de torns | Alta (integració) | `location_id` a `shift_slots` + UI ShiftsPage + RPC scheduled locations. |
| **ST-16** | Pauses al kiosk | Mitjana (demanda) | `break_start`/`break_end` via `station-api`; dins `employee_session`. |
| **ST-11** | Rate limit QR / DNI | Alta (prod) | Anti-enumeració a resolució identitat. |

**Ordre recomanat:**

```
Bugfix qr-token → ST-10 → ST-19 (location als torns — desbloqueja ST-18c)
  → ST-18 + ST-18a (modes entrada DNI/llista + sessió empleat)
  → ST-18b (portal QR tab) → ST-18e (historial sessió)
  → ST-18d → ST-16 (pauses) → ST-18c (avis ubicació amb dades ST-19)
```

---

## Canvis tècnics previstos (ST-18)

### `station-api` — nous endpoints

| Mètode | Ruta | Propòsit |
|--------|------|----------|
| POST | `resolve-employee-document` | `{ document_id }` → empleat (mode DNI-first) |
| POST | `verify-employee-pin` | `{ employee_id, pin }` → ok / invalid / locked |
| GET | `employee-today` | Horari, punches avui, dayState, pause configs |
| POST | `employee-history` | `{ employee_id, from, to, pin }` — read-only kiosk; PIN obligatori; màx. `session_history_max_days` (90); **mai** proxy al portal |
| POST | `punch` | *(existent)* ampliar tipus: `break_start`, `break_end` (ST-16) |

### Schema (`attendance_devices`)

> **EX-02.2 (2026-07-15):** columnes ST-18 core + FSM kiosk.  
> **EX-02.3 (2026-07-15):** `POST resolve-employee-document`, normalització, anti-enumeració, teclat DNI, default `document_entry`.  
> **EX-02.4 (2026-07-15):** `POST verify-employee-pin` — hash PIN portal, lockout per `device_id+employee_id` (sense `token_id` portal). Config `identity_confirm`/`qr_identity_confirm = portal_pin`. Historial → EX-02.6.

```sql
-- ST-18 migration (esborrany original; defaults efectius a EX-02.2 diferits)
entry_mode text NOT NULL DEFAULT 'document_entry'
  CHECK (entry_mode IN ('employee_list', 'document_entry', 'qr_only', 'employee_list_and_document')),
employee_list_layout text NOT NULL DEFAULT 'cards'
  CHECK (employee_list_layout IN ('cards', 'compact_list')),
document_match text NOT NULL DEFAULT 'full'
  CHECK (document_match IN ('full', 'suffix')),
document_suffix_length int NOT NULL DEFAULT 4,
identity_confirm text NOT NULL DEFAULT 'tap_name'
  CHECK (identity_confirm IN ('none', 'tap_name', 'portal_pin')),
qr_identity_confirm text NOT NULL DEFAULT 'none'
  CHECK (qr_identity_confirm IN ('none', 'tap_name', 'portal_pin')),
session_idle_seconds int NOT NULL DEFAULT 60,
session_return_countdown_seconds int NOT NULL DEFAULT 15,
session_allow_history boolean NOT NULL DEFAULT true,
session_history_max_days int NOT NULL DEFAULT 90,
allow_unassigned_punch boolean NOT NULL DEFAULT false,
warn_unassigned_punch boolean NOT NULL DEFAULT true,
warn_wrong_scheduled_location boolean NOT NULL DEFAULT true,
block_wrong_scheduled_location boolean NOT NULL DEFAULT false
```

### Frontend estació

- Estats: `waiting` | `employee_session` (sub: `punch` | `history` | `success_flash`).
- Eliminar barra flotant inferior (`page.tsx` línies ~604–645).
- **`waiting`:** teclat DNI i/o llista segons `entry_mode`.
- **`employee_session`:** capçalera amb nom + botó **«Tancar sessió»** sempre visible.
- Nova vista `StationEmployeePunchView` + `StationEmployeeHistoryView` compartint lògica amb portal.

### Frontend portal

- ✅ EX-02.5: `PortalIdentityQrCard` a `/portal/station-qr` + nav «QR estació».
- ✅ `PortalPunchActionPanel` només si `!punch_only_at_stations`; CTA a QR quan station-only.

---

---

## ST-9 V2 — Offline a l'estació (què és i proposta)

### Què tenim avui (ST-9 V1)

L'estació **necessita xarxa** per a tot: aparellament, llista d'empleats, resoldre DNI/QR, validar PIN, fitxar, historial. Si la WiFi cau → **error** i l'empleat no pot registrar el fitxatge.

Això és intencional al MVP: simple, sense risc de cua local desincronitzada ni rellotges del tablet incorrectes sense supervisió.

### Què seria ST-9 V2

**Resiliència de xarxa:** poder **registrar el fitxatge al tablet** quan la connexió falla (o és intermitent) i **pujar-lo al servidor** quan torni la xarxa — sense perdre l'acció de l'empleat.

Analogia: el portal mòbil (`PortalPunchPage`) ja té una **cua offline** (`portalSessionOutbox`): desa punches a `IndexedDB` i els sincronitza en tornar online. ST-9 V2 portaria un patró similar a la **UI estació**, adaptat a dispositiu compartit.

### Abast proposat (limitat, no «estació 100% offline»)

| Acció | Offline V2? | Motiu |
|-------|-------------|-------|
| Resoldre DNI / QR | **No** | Cal servidor per identificar i anti-frau |
| Validar PIN portal (primera vegada) | **No** | Cal servidor (mateix que portal) |
| **Registrar punch** (in/out/pausa) | **Sí** | Cas principal: WiFi cau just en fitxar |
| Consultar historial | **No** | Només online; dades sensibles |
| Llista d'empleats / bootstrap | **No** (V2.0) | Opcional V2.1: cache només lectura, stale |

**Flux proposat:**

```
Empleat ja identificat (sessió ST-18) → toca «Fitxar»
  → xarxa OK     → POST station-api/punch (com avui)
  → xarxa falla  → desar a cua local (IndexedDB) + missatge «Fitxatge desat — es pujarà en tornar la connexió»
  → xarxa torna  → worker en segon pla envia la cua (FIFO, `client_op_id` per idempotència)
  → servidor rebutja → quarantena visible (PIN admin kiosk) — no esborrar silenciosament
```

**Timestamp — model online vs offline (decisió #10 + #34):**

| Mode | `occurred_at` (hora legal del fitxatge) | `received_at` (auditoria) |
|------|----------------------------------------|---------------------------|
| **Online** (com avui) | **`now()` del servidor** en rebre la petició | `now()` — coincideixen |
| **Offline → sync** | **`occurred_at` capturat al tablet en el moment del toc** (desat a la cua) | `now()` del servidor en pujar — **pot ser minuts/hores després** |

**Per què no usar `now()` del servidor en sync tardà?** Tens raó: si l'Anna fitxa **sortida** a les 18:00 sense xarxa i la cua puja a les 20:00, posar `occurred_at = 20:00` li sumaria **2 hores extra** de treball — dada falsa.

**Per què no confiar cegament en el rellotge del tablet?** Qualsevol pot desconfigurar l'hora (menys habitual en tablet kiosk, però possible). Per això el **servidor continua sent l'autoritat**: valida, accepta o rebutja el `occurred_at` del client; marca `received_at`; afegeix anomalia si cal.

**Regles proposades ST-9 V2 (alinear amb portal offline):**

1. En desar a cua: `occurred_at = new Date().toISOString()` **al moment del toc** (congelat).
2. En sync: enviar aquest `occurred_at` + `client_op_id` idempotent.
3. Servidor: `received_at = now()`; comparar `|occurred_at − received_at|` amb llindar tenant (`attendance_clock_offset_threshold_ms`, default 5 min).
4. Si desviació **dins llindar** → acceptar `occurred_at` del client.
5. Si desviació **fora llindar** (rellotge tablet desconfigurat o cua molt antiga) → acceptar amb anomalia **`CLOCK_SKEW`** + **`OFFLINE_DELAY`** (si `received_at − occurred_at` > llindar de sync); revisió RRHH — **no** sobreescriure silenciosament amb `now()`.
6. Avui `record_time_punch` força `v_occurred_at := now()` per `source IN ('station','qr')` — cal **relaxar-ho** només quan el client envia `occurred_at` explícit (sync offline).

**Resum:** confiar en el **servidor com a jutge**, no com a «hora del toc retardat». Online = servidor marca l'instant; offline = tablet marca l'instant, servidor valida en pujar.

**Sessió empleat (ST-18):** la cua és **del dispositiu**, no de l'empleat. Si l'empleat tanca sessió amb punches pendents, la cua **segueix sincronitzant** en segon pla. Banner global a l'estació: «N fitxatges pendents de pujar».

### Producció — quan cal ST-9 V2 (decisió #35)

| Escenari producció | ST-9 V2 |
|--------------------|---------|
| Estació **només online** (V1) | **No obligatori** — acceptable si la WiFi del centre és estable |
| Estació **amb cua offline** activada | **Obligatori abans de producció** — ha de ser **fiable** (no un experiment) |

**Criteris mínims de fiabilitat** abans d'activar offline en prod:

- Tests E2E: punch offline → sync → `occurred_at` correcte + `received_at` posterior
- Idempotència (`client_op_id`) — sense duplicats en reintent
- Quarantena visible (no perdre punches rebutjats)
- Anomalies `CLOCK_SKEW` / `OFFLINE_DELAY` quan cal revisió
- Banner «N pendents» + resolució admin (PIN kiosk)

Fins llavors: desplegar ST-18 amb **V1 online-only** és vàlid; ST-9 V2 es desenvolupa i valida abans d'obrir la funcionalitat offline als tenants.

### Què NO incloure a V2 (evitar complexitat)

- Fitxar sense haver identificat abans l'empleat (no «mode offline llista»).
- Editar o esborrar punches de la cua des del kiosk (només admin amb PIN).
- Historial offline ni cache de 90 dies.
- ST-9 V2 es desenvolupa com a capa additiva sobre `station-api` + `postStationPunch`.

### Ordre recomanat

```
ST-18 (UX + sessió, online-only)  →  ST-9 V2 (cua + timestamps + tests)  →  activar offline en prod
```

ST-9 V2 **no bloqueja** el desenvolupament de ST-18, però **sí bloqueja** desplegar offline a producció.

### Esforç tècnic (ordre de magnitud)

| Peça | On |
|------|-----|
| `stationOutbox` (IndexedDB) | `apps/public-portal/lib/attendance-station/` |
| Hook `useStationSync` (online/offline, pending count) | mateix patró que portal |
| `client_op_id` al POST punch | ja existeix al contracte portal; reutilitzar |
| Idempotència servidor | `record_station_time_punch` / edge — verificar o afegir |
| UI banner + quarantena | `StationPage` / `employee_session` |

---

## Decisions obertes

*(cap — totes les decisions d'estació UX/ST-9 estan tancades fins nova revisió.)*

## Decisions tancades (revisió 2026-07-15)

| # | Decisió |
|---|---------|
| 20 | El DNI va **abans** de mostrar l'empleat, no després de seleccionar-lo a la llista |
| 21 | `entry_mode` configurable per estació: llista **o** DNI **o** ambdós |
| 22 | Cancel·lar countdown = **quedar-se a la sessió**; reinici countdown per inactivitat |
| 23 | **«Tancar sessió»** sempre visible durant `employee_session` |
| 24 | Historial kiosk amb **selector de període** (no només avui), configurable |
| 25 | Assignacions `/locations` = eligibility; **planificador de torns** = on treballar cada dia (ST-19) |
| 26 | Historial kiosk **només via `station-api`** — mai portal personal en dispositiu compartit |
| 27 | `document_match` (`full` / `suffix`) configurable per estació; entrada **alfanumèrica** (DNI/NIE ES amb lletra; sense assumir format país) |
| 28 | PIN addicional després de QR: configurable per estació (`qr_identity_confirm`); per defecte **sense** PIN |
| 29 | «Lloc del dia» operatiu = **torns planificats** (ST-19), no assignacions estàtiques |
| 30 | `entry_mode` per defecte en estació nova: **`document_entry`** |
| 31 | `block_wrong_scheduled_location` configurable; **per defecte només avís** (`false`) — imprevistos, errors admin, flexibilitat |
| 32 | Historial kiosk: límit **90 dies** (`session_history_max_days`) |
| 33 | Col·lisió document | `full`: document complet → llista coincidents si >1. `suffix`: mínim N però entrada pot ser completa o més llarga → mateixa llista si col·lisió. |
| 34 | Timestamp offline (ST-9 V2) | **Online:** `occurred_at = now()` servidor. **Offline sync:** `occurred_at` = instant del toc (cua local); servidor valida skew + `received_at` = instant de pujada; anomalies si desviació. |
| 35 | ST-9 V2 abans producció | Offline a prod **només** amb ST-9 V2 fiable (tests E2E, idempotència, quarantena). Prod **online-only** (V1) vàlid sense ST-9 V2. |

---

## Annex: bug `identity/qr-token` 404

**Causa:** `employee-portal-api` exposa `POST identity/qr-token`, però `apps/public-portal/app/api/employee-portal/[...path]/route.ts` no tenia handler → `{ code: "not_found" }` 404.

**Fix:** handler que llegeix cookie de sessió portal i fa proxy a l'Edge Function (mateix patró que `POST punch`).

**Verificació manual:** iniciar sessió a `/portal`, obrir `/portal/punch` o `/portal/station-qr` — el QR ha de generar-se sense error de xarxa.

---

## Referències de codi

| Àmbit | Fitxer |
|-------|--------|
| Estació — botons flotants | `apps/public-portal/app/station/page.tsx` |
| Portal punch layout | `apps/public-portal/features/employee-portal/components/PortalPunchPage.tsx` |
| QR portal | `apps/public-portal/features/employee-portal/components/PortalIdentityQrCard.tsx` |
| Proxy (fix qr-token) | `apps/public-portal/app/api/employee-portal/[...path]/route.ts` |
| Edge qr-token | `supabase/functions/employee-portal-api/index.ts` |
| RPC assignacions fixes | `supabase/migrations/20261014000013_station_location_assignments_st2a.sql` |
| Planificador torns (sense ubicació avui) | `apps/tenant-portal/src/features/attendance/pages/ShiftsPage.tsx` |
| Schema torns | `supabase/migrations/20260521000002_shift_planning.sql` |
| Historial portal (referència kiosk) | `apps/public-portal/features/employee-portal/components/PortalHistoryPage.tsx` |
