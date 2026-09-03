# 14. Control horari - Overview funcional i migracio des de JCM

> Objectiu: portar el sistema de fitxatge de `/my-app-jcm` a
> `/app-supabase` sense copiar el model Firestore tal qual. La versio nova
> ha de funcionar be amb Supabase/Postgres, suportar offline real al mobil i
> deixar una base fiable per a calendari laboral i payroll.

> **Actualitzat:** 2026-06-30 — decisions Phase 0 incorporades.  
> **Estat d'implementació:** [`docs/plans/checkin/STATUS.md`](../plans/checkin/STATUS.md)  
> **Roadmap actiu:** [`docs/plans/checkin/plan.md`](../plans/checkin/plan.md) (Control Horari v3)

---

## 14.1 Que fa avui `/my-app-jcm`

El sistema actual cobreix tres blocs de producte:

1. **Fitxatge d'entrada/sortida**
   - L'usuari registra `IN` / `OUT`.
   - Cada fitxatge porta tipus (`NORMAL`, `LUNCH`, `BREAK`, `EXTRA`,
     `VACATION`, `SICK_LEAVE`, etc.), comentari, mode remot, dispositiu,
     ubicacio GPS opcional i zona de treball si el dispositiu en te assignada.
   - El document remot viu a Firestore com `punches/{uid}/logs/{timestamp}`.
   - El document local viu a IndexedDB en `punchDB`, object store
     `punches_{uid}`, amb `timestamp` com a clau.

2. **Offline-first pragmatic**
   - El fitxatge es desa sempre localment primer.
   - Si hi ha connexio real, s'intenta escriure a Firestore i verificar la
     lectura posterior.
   - Si falla, queda `synced=false` i es reintenta cada 20 segons, en tornar
     online o amb sincronitzacio manual.
   - Un listener Firestore descarrega els ultims fitxatges del servidor i els
     copia a IndexedDB per mantenir estat local.

3. **Zones i estacions de fitxatge**
   - `WorkZones`: arbre de zones de treball (`fatherZoneId`).
   - `Devices`: dispositius amb `deviceId`, nom amigable, `zoneId`, mode
     estacio fixa i ultims usos.
   - `UserZoneAssignments`: usuaris assignats a zones, amb herencia des de
     zones pare.
   - La pantalla `/station` permet seleccionar usuari, escanejar QR o codi de
     barres i fitxar com aquell usuari des d'una estacio assignada a una zona.

---

## 14.2 Model Firestore actual

| Firestore / local | Us real | Notes de migracio |
|---|---|---|
| `punches/{uid}/logs/{timestamp}` | Fitxatges raw per usuari | En Postgres ha de ser una taula append-only amb idempotencia per `client_op_id`, no una subcolleccio per usuari. |
| IndexedDB `punchDB.punches_{uid}` | Cua local + cache de consultes | Es mante, pero amb una cua tipada d'operacions i resposta per item des de RPC Supabase. |
| `Schedules` | Horaris normals, especials, vacances i festius | Cal normalitzar: horaris setmanals, assignacions, festius i absencies han de ser entitats separades. |
| `Users.appData.horariosAsignados` | Assignacio d'horaris a usuari | En Supabase ha de penjar d'`employee`, no nomes d'`auth.users`. |
| `WorkZones` | Zones internes del tenant | Es poden mapar a `data.locations`; no cal una taula nova de zones. |
| `Devices` | Mobils i estacions fixes | Nova taula `data.attendance_devices`, vinculada a `site_id` i opcionalment `location_id`. |
| `UserZoneAssignments` | Qui pot fitxar en una zona | Nova taula `data.attendance_location_assignments`, amb herencia via `data.locations.parent_id`. |
| `DevicesPWD` | Contrasenya admin d'estacio | En Supabase s'ha de substituir per secret hash / PIN hash i audit, mai password pla. |

---

## 14.3 Principis per a la versio Supabase

### Separar el fet del calcul

Un fitxatge raw no es modifica. Es poden afegir ajustos o invalidacions, pero
el registre original queda com a evidencia.

```text
time_punches         = esdeveniments raw: IN/OUT capturats pel dispositiu
time_entries         = intervals processats: parelles IN->OUT
time_daily_summaries = resum calculat per dia: hores regulars, extres, absencies
```

Aixo evita que un error de calcul destrueixi l'evidencia original i permet
reprocessar dies quan canvia una regla laboral, un festiu o una absencia.

### Employee es l'eix laboral

El document de domini ja separa `TenantMember` i `Employee`. El control horari
ha de penjar d'`Employee`, no directament de l'usuari d'auth.

- Un usuari amb login pot tenir `employee.user_id = auth.uid()`.
- Una estacio fixa pot fitxar un empleat sense que aquest tingui login propi.
- Payroll sempre treballa sobre `employee_id`.

Regla recomanada V1: qualsevol persona que pugui fitxar ha de tenir una fila a
`data.employees`. Si tambe te login, es vincula amb `user_id`.

### `data.locations` substitueix `WorkZones`

El projecte Supabase ja te `data.locations` amb jerarquia, `site_id` i
`geo_coordinates`. Les zones de fitxatge han de ser locations amb
`type='zone'`, `type='room'`, `type='floor'` o `type='outdoor'` segons el cas.

La informacio historica del fitxatge ha de conservar:

- `location_id` si encara existeix.
- `location_name_snapshot` per informes encara que la location canviï de nom.
- `device_id` i `device_name_snapshot`.

### Offline compatible amb Supabase, pero no automatic

Supabase no dona una cache offline equivalent a Firestore. La estrategia bona
es mantenir IndexedDB, pero fer-la explicita:

- IndexedDB com a **outbox local**.
- RPC Supabase idempotents per pujar lots.
- Taula de deduplicacio al servidor per `client_op_id`.
- Realtime nomes com a millora d'experiencia, no com a mecanisme de garantia.

---

## 14.4 Abast funcional V1

### Inclou

- Fitxatge manual `IN` / `OUT` i **pauses tipificades** (`break_start` / `break_end`).
- **Teletreball** (`is_remote`) i geolocalització puntual amb consentiment GDPR.
- Geolocalització opcional amb estat de permisos (timeout 3s; no bloqueja el fitxatge).
- Zones internes basades en `data.locations`.
- Assignació d'empleats a locations/zones.
- Registre offline en mòbil i sincronització posterior (IndexedDB outbox).
- Càlcul de parelles IN/OUT i resums diaris (`time_entries`, `time_daily_summaries`).
- Calendari laboral en **cascada** (festius, overrides tenant/site/grup/empleat, grups de calendari).
- Absències, permisos retribuïts, IT (baixa manual) i entitlements de vacances.
- Planificació de torns (`work_shifts`, `shift_slots`).
- Resums diaris per aprovació i export payroll; **informe mensual** per empleat (JSON/PDF base).
- Fitxatge via estació fixa — **diferit**: identitat tècnica per `device_secret_hash` dissenyada; UI i Edge Function pendents.

### V1 estació fixa (quan s'implementi)

- Identificació per **selecció manual** d'empleat assignat a la location.
- QR / codi de barres signat pel servidor → **V2** (no V1).

### No inclou en V1

- Nòmina legal completa (només export de resums aprovats / CSV / informe mensual).
- Integració INSS per baixes automàtiques (entrada manual IT per manager).
- Edició offline complexa de calendaris/absències.
- Geofencing dur bloquejant per defecte (mode configurable; per defecte `informative`).
- Background sync garantit a iOS.
- Biometria, NFC o BLE.
- Accés telemàtic per Inspecció de Treball com a API dedicada (pendent pla v3 F0b).

---

## 14.5 Permisos necessaris

Afegir al cataleg RBAC existent:

```text
attendance.punch_own
attendance.punch_station
attendance.view_own
attendance.view_all
attendance.adjust
attendance.approve
attendance.export
attendance.devices.manage
attendance.locations.manage
labor_calendar.view
labor_calendar.manage
absences.request
absences.approve
payroll.view
payroll.export
```

Regles d'us:

- `attendance.punch_own`: usuari amb login pot fitxar-se ell mateix.
- `attendance.punch_station`: estacio fixa pot registrar fitxatges d'empleats
  assignats a la seva location.
- `attendance.adjust`: crea ajustos o marca fitxatges com revisats; no edita
  raw directament.
- `attendance.approve`: aprova resums diaris abans d'export payroll.

---

## 14.6 Relacio amb altres moduls

| Modul existent | Integracio |
|---|---|
| `data.sites` | Defineix calendari local, timezone i ambit de locations. |
| `data.locations` | Substitueix `WorkZones`; assignacio de dispositius i empleats. |
| `data.tenant_members` | Permisos i login; no substitueix `Employee`. |
| `data.departments` | Visibilitat i aprovacio per responsable. |
| `data.calendar_events` | Pot mostrar torns, vacances i incidencies com events. |
| `data.notifications` | Avisos in-app de fitxatges pendents, anomalies i resums per aprovar. |
| `data.communications` | Futur: recordatoris outbound, si el tenant ho vol. |
| DMS | Contractes i justificants d'absencia amb `entity_type='employee'` o `absence`. |

---

## 14.7 Decisions inicials

1. **Raw i processed separats**: obligatori per payroll i auditories.
2. **IndexedDB es mante**: pero com a outbox local controlada, no com a reflex
   informal de Firestore.
3. **`employee_id` es obligatori als fitxatges**: `user_id` es nomes l'actor o
   el vincle amb login.
4. **`data.locations` es la font de zones**: no duplicar `WorkZones`.
5. **Codi QR/barres signat pel servidor**: no secrets client-side (V2 estació).
6. **El calcul oficial viu al servidor**: el frontend pot mostrar estat
   provisional, pero payroll surt de Postgres.
7. **Estacions fixes = identitat tècnica**: `device_secret_hash`, no consumeixen
   llicència TenantMember; permís `attendance.punch_station` només.
8. **Torns nocturns**: suport bàsic V1; `work_date` = dia d'inici del torn.
9. **Festius**: import Nager.Date (ES + CCAA) + override manual per tenant.
10. **Retenció legal**: mínim 4 anys (RDL 8/2019) per raw punches i resums.
11. **Pauses dins jornada**: `time_punches` amb `pause_type` i snapshot
    `pause_counts_as_work`; configuració per tenant (`tenant_pause_configs`).
12. **Absències fora de jornada**: `employee_absences` separades dels punches;
    tipus configurables (`tenant_absence_type_configs`); absències parcials amb
    `partial_start_time` / `partial_end_time` (no són pauses).

Veure taula completa de decisions Phase 0 al [doc 17 §Decisions](./17-time-attendance-implementation-plan.md#decisions-de-disseny-confirmades-phase-0-tancada).

---

## 14.8 Documentació relacionada

| Document | Contingut |
|----------|-----------|
| [15 — Arquitectura](./15-time-attendance-architecture.md) | Fluxos offline, recompute, pauses, cascada calendari |
| [16 — Model de dades](./16-time-attendance-data-model.md) | Taules Postgres i RPCs |
| [17 — Pla d'implementació](./17-time-attendance-implementation-plan.md) | Fases 0–4 i decisions tancades |
| [STATUS.md](../plans/checkin/STATUS.md) | Estat real vs plans |
| [plan.md](../plans/checkin/plan.md) | Roadmap v3 (enduriment, legal, automatitzacions) |
| [prompt_refine_pauses.md](../plans/checkin/prompt_refine_pauses.md) | Semàntica legal pauses/absències/IT |
| [calendaris-laborals.md](../help/horaris/calendaris-laborals.md) | Cascada de calendari (font operativa) |
