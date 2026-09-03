# 17. Control Horari — Pla d'implementació V1

Implementació per fases del mòdul de control horari legal (obligatori 2026) + planificació de torns i calendari laboral per al tenant-portal de Supabase.

> **Estat:** Phases 0–2 completades; Phases 3–4 majoritàriament implementades. Evolució v3 en curs — veure [`docs/plans/checkin/STATUS.md`](../plans/checkin/STATUS.md) i [`plan.md`](../plans/checkin/plan.md).  
> **Estimació original:** ~25 dies laborables (Phases 1A–4).

---

## Context i estat actual

**Ja implementat (prerequisits coberts):**
- `data.employees` — migració `20260504000001`, feature frontend `employees/`
- `data.locations` — jerarquia de zones amb `parent_id`, `geo_coordinates`, `site_id`
- `data.departments` — visibilitat i aprovació per responsable
- `data.calendar_events` — base per mostrar torns com events
- PGMQ / async infrastructure — cua per recomputació asíncrona
- RBAC `jwt_has_permission` — base per permisos d'assistència

**Implementat (mòdul assistència — veure [`STATUS.md`](../plans/checkin/STATUS.md)):**
- Backend legal (Phase 1A), calendari laboral (Phase 1B + cascada), torns (Phase 2)
- Control Horari v2/v3: pauses, geo GDPR, entitlements, absències refinades, informes mensuals
- UI treballador (`/attendance/*`) i manager (`/attendance-mgmt/*`)

**Pendent o parcial:**
- Estació fixa (`punch-from-station`), export A3/Sage UI, Fase 0 v3 (SLO/càrrega), automatitzacions

**Patrons existents reutilitzables:**
- `data.validate_geo_payload()` — validació GPS amb anomaly_codes (reusable per time_punches)
- `api.sync_work_log_ops(batch)` — template per batch sync offline idempotent
- `QueueRunner` + `TaskHandler` (`_shared/queue-runtime.ts`) — patró worker PGMQ
- `data.settings_registry` + `api.get_effective_settings()` — configuració cascading
- `data.work_logs` — coexisteix amb time_punches (decisió D1 migració 20260506000005)

---

## Restriccions legals clau (Espanya 2026)

- Registre **immutable i traceable**: no es pot editar un fitxatge raw, només afegir ajustos
- **Accés en temps real** per la Inspecció de Treball (dades server-side, no client-only)
- **Cobertura total**: tots els empleats, inclosos teletreball i mobilitat
- **Retenció**: 4 anys mínim (RDL 8/2019)
- **Sancions**: fins a 10.000 € per treballador afectat

---

## Decisions de disseny confirmades (Phase 0 tancada)

Totes les open questions del doc 16 resoltes:

| # | Pregunta | Decisió ✅ |
|---|---|---|
| 1 | Estacions = llicència TenantMember o identitat tècnica? | **Identitat tècnica**: `device_secret_hash`, no facturable, permís `attendance.punch_station` només |
| 2 | Nivell geofencing V1 | **Configurable per tenant/site** (mode: `off` / `informative` / `warn` / `block`). Per defecte: `informative` |
| 3 | Torns nocturns V1 | **Sí, suport bàsic**: `work_date` = dia d'inici del torn; el càlcul gestiona creuament de mitjanit |
| 4 | Font festius nacionals/locals | **Nager.Date API** (ES + CCAA) + ajust/override manual per tenant |
| 5 | Empleats sense login → QR/barcode | **Selecció manual a l'estació** (V1). QR/barcode via admin en V2 |
| 6 | Arrodoniment payroll | **Configurable per tenant** (`real_minute` / `15_min` / `30_min`). Per defecte: `real_minute` |
| 7 | Hores extra | **Configurable per tenant** (`auto` si `allow_overtime=true` / `approval_required`). Per defecte: `approval_required` |
| 8 | Retenció raw punches | **4 anys** (mínim legal espanyol, RDL 8/2019) |
| 9 | Export V1 | **CSV genèric + PDF resum mensual + format A3/Sage** |

**Decisió UI addicional:** planificador visual de torns construït amb **grid custom (TanStack Table + CSS Grid)** — sense llicències externes, control total del disseny.

---

## Fases d'implementació

### Phase 0 — Design Sprint *(✅ COMPLETADA)*

**Objectiu:** tancar decisions abans de crear cap migració.

- [x] Respondre les 9 open questions → veure taula "Decisions de disseny" més amunt
- [x] Estendre el model de dades (docs 15/16) per incloure **shift planning**:
  - `data.work_shifts` — plantilles de torn reutilitzables (nom, durada, color)
  - `data.shift_slots` — instàncies concretes (data + hora + empleat + torn)
  - `data.shift_swap_requests` — sol·licituds de canvi de torn
- [x] Definir contracte API cobertura → `api.get_coverage_for_period`
- [x] Decidir UI framework planificador → **TanStack Table + CSS Grid (custom)**
- [x] Actualitzar docs 14, 15, 16 amb decisions preses (2026-06-30)

---

### Phase 1A — Legal Foundation Backend *(~5 dies)*

**Objectiu:** compliment legal mínim operatiu.

**Migracions noves:**
- `data.attendance_devices` — dispositius i estacions fixes
- `data.attendance_location_assignments` — qui pot fitxar on
- `data.time_punches` — fitxatges raw immutables (amb `client_op_id` únic)
- `data.time_entries` — intervals processats (IN→OUT)
- `data.time_daily_summaries` — resum diari per revisió i payroll

**Settings Engine (claus noves a `data.settings_registry`):**
- `attendance_geofencing_mode` (site) — `'off'|'informative'|'warn'|'block'`, default `'informative'`
- `attendance_rounding_mode` (tenant) — `'real_minute'|'15_min'|'30_min'`, default `'real_minute'`
- `attendance_overtime_policy` (tenant) — `'auto_if_allowed'|'approval_required'`, default `'approval_required'`
- `attendance_clock_offset_threshold_ms` (site) — default `300000` (5 min)
- Defaults afegits a `data.system_settings` module `'defaults'`

**RBAC (`CREATE OR REPLACE data.get_role_permissions`):**
- viewer += `attendance.view_own`
- member += `attendance.punch_own`, `absences.request`
- manager += `attendance.view_all`, `attendance.adjust`, `attendance.approve`, `attendance.export`, `attendance.devices.manage`, `labor_calendar.manage`, `absences.approve`

**Seguretat:**
- RLS: lectura pròpia (`employee.user_id = auth.uid()`), managers per `jwt_has_permission`
- Cap `INSERT` directe des del frontend; tot via RPC

**RPCs:**
- `api.record_time_punch(...)` — registre individual idempotent; reutilitza `data.validate_geo_payload()`
- `api.sync_time_punches(p_batch jsonb)` — lot offline, resposta per item (patró `sync_work_log_ops`)
- `api.my_attendance_today(p_employee_id)` — estat actual per UI
- `api.approve_time_day(p_employee_id, p_work_date)` — manager aprova resum diari (`draft`→`approved`)
- `api.adjust_time_punch(p_time_punch_id, p_adjustment jsonb)` — crea ajust sense editar raw
- `api.export_payroll_days(p_site_id, p_from, p_to)` — retorna dies aprovats; marca `exported` + `payroll_locked_at`

**Vistes API (security_invoker=true, seg. doc 16.7):**
- `api.time_punches`, `api.time_entries`, `api.time_daily_summaries`
- `api.attendance_devices`, `api.attendance_locations` (filtre de `api.locations` per attend.)
- `api.work_schedules`, `api.employee_absences`

**Async:**
- PGMQ queue `attendance_recompute_queue` (`pgmq.create`)
- Edge Function `process-attendance-queue` (patró `QueueRunner`/`TaskHandler` existent)
  - Handler `recompute_attendance_day`: calcula time_entries + time_daily_summaries
  - Genera `data.notifications` si anomalia o needs_review
- SQL wrapper `data.invoke_attendance_queue_worker(batch_size)` + `cron.schedule` (patró existent)

**Audit events:** `TIME_PUNCH_RECORDED`, `TIME_PUNCH_REJECTED`, `TIME_ENTRY_ADJUSTED`, `TIME_DAY_RECOMPUTED`, `TIME_DAY_APPROVED`, `TIME_DAY_EXPORTED`

**Tests SQL (`supabase/tests/attendance_tests.sql`):**
- Idempotència: enviar mateix `client_op_id` dues vegades → `duplicate`
- RLS: empleat no pot veure fitxatges d'altre empleat
- Permisos: member no pot aprovar dies; manager sí

**Verificació:** fitxatge idempotent en staging; recomputació diària passa per cua asíncrona

---

### Phase 1B — Calendari Laboral Backend *(~4 dies)*

**Objectiu:** base per a càlcul legal d'hores esperades per dia. Inclou suport de torns nocturns (creuament de mitjanit): `work_date` = dia d'inici del torn.

**Migracions noves:**
- `data.work_schedules` + `data.work_schedule_intervals` — plantilles horàries setmanals
- `data.employee_schedule_assignments` — assignació d'horari a empleat (amb dates vigència)
- `data.holiday_calendars` + `data.holidays` — festius nacionals/regionals/locals/tenant
- `data.employee_absences` — vacances, baixes, permisos, incidències (amb workflow)

**Permisos RBAC nous:** `labor_calendar.view`, `labor_calendar.manage`, `absences.request`, `absences.approve`

**RPCs:**
- `api.resolve_work_day(p_employee_id, p_work_date)` — retorna: dia tipus, horari esperat, festiu, absència
- `api.recompute_attendance_day(p_employee_id, p_work_date)` — recalcula amb regla de resolució (prioritat: absència > festiu > override > horari)
- `api.request_absence(...)` / `api.approve_absence(...)` — flux sol·licitud/aprovació

**Utilitat festius:** script/RPC per importar festius via Nager.Date API (ES + regions)

**Lògica nocturna al recompute worker:**
- Si horari inclou interval que creua mitjanit (e.g., 22:00→06:00), `work_date` = dia d'inici
- El worker carrega punches de day-1 → day+1 per emparellar correctament
- `time_entries.ends_at` pot ser del dia següent a `time_entries.starts_at`
- **Timezone del site**: `resolve_work_day` usa `site_timezone` (settings) per determinar límits del dia; crític per sites en Canaries (UTC+0) vs península (UTC+1)

**Tests SQL (`supabase/tests/attendance_calendar_tests.sql`):**
- Torn nocturn 22:00→06:00 genera `work_date` correcte
- Dia festiu → `expected_minutes = 0`
- Absència aprovada → `day_type = 'absence'`, `absence_paid_minutes` correctes

**Verificació:** `resolve_work_day` retorna valors correctes per dia festiu, dia d'absència aprovada, dia laborable normal i torn nocturn

---

### Phase 2 — Shift Planning Backend *(~4 dies)*

**Estat:** ✅ core inicial + hardening; ⚠️ integració operativa V2 pendent

El core existent no és encara la font de veritat de l'horari: els `shift_slots` publicats no participen en `api.resolve_work_day()` i la cobertura és agregada per dia. La continuació autoritativa és el [Pla específic — Planificador de torns V2 integrat](../plans/checkin/plan-shift-planner-v2.md).

**Objectiu:** planificació de torns + detecció d'hores extra/mancants per contracte.

**Migracions noves (extensió del model):**
- `data.work_shifts` — plantilles de torn (nom, starts_at, ends_at, color, site_id)
- `data.shift_slots` — instàncies concretes (date, employee_id, shift_id, status: `draft/published/cancelled`)
- `data.shift_swap_requests` — sol·licituds de canvi (requester, target_employee, status)

**RPCs:**
- `api.assign_shift_slot(...)` — assignar torn a empleat per dia
- `api.publish_shifts(p_site_id, p_week_start)` — publicar borrador de torns
- `api.get_coverage_for_period(p_site_id, p_from, p_to)` — cobertura agregada per dia en el core actual; cobertura real per franja/ubicació/rol passa a SP-3
- `api.request_shift_swap(...)` / `api.approve_shift_swap(...)` — flux canvi torn
- Integració: si shift_slot publicat → crear/actualitzar `calendar_events` corresponent

**Detecció d'anomalies de planificació:**
- Empleat supera hores setmanals contractuals (`weekly_hours`)
- Empleat assignat per sota del mínim contractual
- Solapes de torns

**Hardening aplicat (post-implementació):**
- Solapament real per intervals (inclou nocturns creuant mitjanit)
- Integritat DB amb triggers per `work_shifts`, `shift_slots`, `shift_swap_requests`, `shift_coverage_requirements`
- Flux formal per swaps oberts amb `api.accept_shift_swap(...)`
- Cobertura requerida amb `data.shift_coverage_requirements`
- Auditoria trigger-based per taules de planificació
- Validació de `p_week_start` (obligatori dilluns) a `api.publish_shifts`

**Verificació (SQL):** `supabase/tests/attendance_shifts_tests.sql` amb **23 PASS, 0 FAIL, 0 ERROR**

**Pendent V2:** resolver únic calendari/horari/torn/absència, ubicació i rol per slot, publicacions versionades, múltiples torns diaris a la UI, cobertura per franja, vacants, disponibilitat i autoservei.

---

### Phase 3 — UI Fitxatge + Estació (Tenant Portal) *(~6 dies)*

**Objectiu:** interfície de fitxatge per a empleats, estacions fixes i managers.

**Nova feature `attendance/` al tenant-portal:**

```
features/attendance/
  db/          # IndexedDB schema (Dexie): attendance_ops, attendance_cache, reference_cache, sync_state
  hooks/       # useAttendanceSync, useMyAttendanceToday, useAttendanceDashboard
  components/  # PunchButton, AttendanceStatusBadge, AnomalyAlert, DailyTimeline
  pages/
    PunchPage          # Fitxar IN/OUT (online + offline)
    MyRecordPage       # Historial propi (dia, setmana, mes)
    StationPage        # Mode estació fixa (selecció empleat)
    ManagerDashboard   # Anomalies, aprovació dies, export
```

**Edge Function `punch-from-station` (autenticació d'estacions):**
- Input: `device_public_id`, `device_secret`, `employee_id`, punch payload
- Valida `bcrypt(device_secret)` contra `attendance_devices.device_secret_hash`
- Valida que empleat està assignat a la location de l'estació
- Crida internament `api.record_time_punch` amb service_role
- Zero dependència d'`auth.uid()` → identitat tècnica pura

**Offline-first:**
- IndexedDB outbox `attendance_ops` amb `LocalAttendanceOp`
- Drainer: escolta `online`, foreground, interval 30s
- Retry fins a `quarantined` si 5 intents fallits
- Indicador visual d'estat de sincronització per a cada fitxatge

**Export:**
- **CSV genèric** — Inspecció de Treball (empleat, data, entrada, sortida, hores, estat)
- **PDF resum mensual** — per empleat o per equip
- **Format A3/Sage** — mapping de camps segons documentació del proveïdor (spike de recerca format inclòs)

**Verificació:** fitxatge en mode avió → torna xarxa → es sincronitza automàticament

---

### Phase 4 — UI Calendari i Planificador Visual *(~6 dies)*

**Objectiu:** gestió de calendari laboral + planificador de torns visual.

**Pàgines noves:**

- `/attendance/calendar` — Calendari laboral mensual per empleat (festius, vacances, horari esperat, torns assignats)
- `/attendance/absences` — Llistat sol·licituds d'absència + formulari de nova sol·licitud + flux aprovació
- `/attendance/shifts` — **Planificador visual de torns** (TanStack Table + CSS Grid):
  - Vista setmanal/mensual amb empleats en files i dies en columnes
  - Arrossegar plantilles de torn sobre cel·les d'empleat/dia (drag & drop)
  - Alertes en temps real: sobrepàs d'hores, franja no coberta, solapament
  - Publicar/despublicar setmana (draft → published)
  - Vista de cobertura per franja horària (objectiu V2 SP-3; l'MVP actual només agrega per dia)
  - Gestió de torns nocturns: visualització clara del creuament de mitjanit

**Integració calendar_events:** torns publicats apareixen al calendari general del tenant

**Verificació:** planificador detecta i avisa quan un empleat supera les hores contractuals setmanals

---

## Dependències entre fases

```
Phase 0 (Design) ──► Phase 1A (Legal Backend)
                        │
                        ├──► Phase 1B (Calendari Backend)
                        │         │
                        │         └──► Phase 2 (Shifts Backend)
                        │                    │
                        └──► Phase 3 (UI Fitxatge) ◄──┘
                                   │
                                   └──► Phase 4 (UI Planificador)
```

Phase 1A i 1B es poden solapar parcialment. Phase 3 requereix 1A complet. Phase 4 requereix 1B + 2 + 3.

---

## Arxius afectats per fase

| Fase | Migracions | Edge Functions | Frontend | Tests |
|---|---|---|---|---|
| 0 | — | — | — | — |
| 1A | `20260515000018_attendance_core.sql` | `process-attendance-queue/` | — | `attendance_tests.sql` |
| 1B | `20260521000001_labor_calendar.sql` + extensions cascada | — | — | `attendance_calendar_tests.sql` |
| 2 | `20260521000002_shift_planning.sql` + hardening | — | — | `attendance_shifts_tests.sql` |
| 3 | v2/v3 migrations | `generate-attendance-report/` | `features/attendance/` | — |
| 4 | labor_calendar v1, schedule planner RPCs | — | `features/attendance/` (ampliació) | — |
| v3 | `20260727*` → `202608*` | `generate-attendance-report/` | `features/attendance/` | — |

**Estat detallat per component:** [`docs/plans/checkin/STATUS.md`](../plans/checkin/STATUS.md)

---

## Riscos principals

| Risc | Mitigació |
|---|---|
| Hora client manipulada | `received_at` + `validate_geo_payload()` + anomaly si offset > threshold configurable |
| Duplicats offline | `UNIQUE(tenant_id, client_op_id)` + resposta `duplicate` (patró provat a work_logs) |
| Canvi retroactiu de calendari | Reprocessar dies afectats; bloquejar dies exportats (`payroll_locked_at`) |
| Planificador visual complex | Grid custom (TanStack + CSS Grid); zero llicències; componentització iterativa |
| Geofencing indoor poc fiable | Mode configurable per site; per defecte informatiu, mai bloquejant si no explícit |
| Festius locals incorrectes | Nager.Date + override manual per tenant |
| Torns nocturns (creuament mitjanit) | `work_date` = dia inici; recompute carrega day±1; test específic |
| Estació compromesa | `device_secret_hash` + `status='suspended'` immediat; audit d'alta severitat |
| Format A3/Sage canvia | Mapping extern configurable; CSV genèric com a fallback sempre disponible |
