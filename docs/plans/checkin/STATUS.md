# Control horari — Estat d'implementació

> **Última actualització:** 2026-07-20 (STATUS: rols/demanda/vacants alineats amb EX-06/07)  
> **Propòsit:** **font de veritat única** de l'estat del mòdul — calendari, horaris, fitxatges, nòmina.  
> **Ordre d'implementació i paquet actiu:** [`EXECUTION.md`](./EXECUTION.md)  
> **Roadmap infra (Fase 0–6):** [`plan.md`](./plan.md)  
> **Roadmap operatiu nòmina/tancament/fitxatge:** [`plan-monthly-close-approval.md`](./plan-monthly-close-approval.md) (Tracks A–F)  
> **Roadmap temps efectiu / consolidació:** [`plan-effective-work-time.md`](./plan-effective-work-time.md) (Track **G**, Fases 0–6)

---

## Com llegir aquest document

| Símbol | Significat |
|--------|------------|
| ✅ | Fet i usable |
| ⚠️ | Parcial / backend sense UI o viceversa |
| ❌ | No implementat o explícitament fora d'abast |
| 📦 | Diferit a una fase posterior |

Els estats es refereixen al **tenant-portal + Supabase** d'aquest repositori, no al sistema legacy JCM.

---

## 1. Mapa de documents (què és vigent)

| Document | Rol | Vigència |
|----------|-----|----------|
| [`14-time-attendance-overview.md`](../../product-design/14-time-attendance-overview.md) | Principis de producte (raw vs processat, employee com a eix, offline) | ✅ Actualitzat (decisions Phase 0 + abast V1) |
| [`15-time-attendance-architecture.md`](../../product-design/15-time-attendance-architecture.md) | Arquitectura (IndexedDB, RPC, recompute, estacions, **§15.9 tres capes**) | ✅ Actualitzat |
| [`16-time-attendance-data-model.md`](../../product-design/16-time-attendance-data-model.md) | Contracte SQL orientatiu JCM → Postgres | ✅ Actualitzat (extensions v2/v3, decisions tancades) |
| [`17-time-attendance-implementation-plan.md`](../../product-design/17-time-attendance-implementation-plan.md) | Pla per fases 0→4 (backend + UI inicial) | ✅ Log d'execució + enllaç a STATUS |
| [`plan.md`](./plan.md) | Control Horari v3 — **enduriment, SLO, cua, automatitzacions** (Fases 0, 0b parcial, 5–6) | ✅ Vigent (àmbit infra) |
| [`prompt_refine_pauses.md`](./prompt_refine_pauses.md) | Pauses, absències parcials, IT, permisos legals | ✅ Spec funcional (incorporada parcialment) |
| [`plan-monthly-close-approval.md`](./plan-monthly-close-approval.md) | **Pla operatiu actiu** — nòmina, tancament mensual, absències/IT, export, fitxatge intel·ligent | ✅ v2 (Tracks A–F; implementació en curs) |
| [`plan-period-employee-confirm.md`](./plan-period-employee-confirm.md) | Confirmació empleat per **període** (mes natural o setmana ISO) — model, RPCs, UI «Registre» | ✅ Fases 0–5 |
| [`plan-effective-work-time.md`](./plan-effective-work-time.md) | **PRD temps efectiu** v4.3 — revisió pre-implementació §21 | ✅ v4.3 doc; implementació ❌ |
| [`prompts/shared/work-logs-time-attendance-integration.md`](../../../prompts/shared/work-logs-time-attendance-integration.md) | Decisions D-INT-1…12 projectes ↔ control horari | ✅ doc compartit |
| [`docs/plans/expenses/`](../expenses/) | Despeses / dietes / tickets / reemborsament (D-INT-12 Opció A) | ✅ pla producte · implementació ❌ |
| [`18-employee-portal-architecture.md`](../../product-design/18-employee-portal-architecture.md) | Portal empleat sense compte (EP8 confirmació L1) | ✅ Disseny · smoke [`ep8-smoke-checklist.md`](./ep8-smoke-checklist.md) |
| [`plan-employee-portal-access-v2.md`](./plan-employee-portal-access-v2.md) | Distribució enllaços, PIN, bulk, **hub portal**, **Identity Gate** | ✅ EP-ACC-1…9 · smoke [`ep-acc8-hub-smoke-checklist.md`](./ep-acc8-hub-smoke-checklist.md) |
| [`plan-employees-portal-access-tab.md`](./plan-employees-portal-access-tab.md) | Hub «Accés al portal» a `/employees` (EP-ACC-8 + 9) | ✅ Implementat |
| [`EXECUTION.md`](./EXECUTION.md) | **Pla mestre executable**: fase activa, dependències, gates, DoR/DoD i evidència | ✅ **EX-00…EX-09 tancats**; cua EI3+ Holded/PayFit |
| [`ex-smoke-checklist.md`](./ex-smoke-checklist.md) | Smoke manual frontend EX-02…EX-05 + fixtures SQL | 📋 Guia · seed [`smoke_ex_attendance_fixtures.sql`](../../../supabase/seeds/smoke_ex_attendance_fixtures.sql) |
| [`adr-0001-work-plan-source-of-truth.md`](./adr-0001-work-plan-source-of-truth.md) | Cascada congelada + contracte `resolve_employee_work_plan` | ✅ SP-0 / EX-03.1 |
| [`adr-0002-work-schedules-option-b.md`](./adr-0002-work-schedules-option-b.md) | Congelar `work_schedules`; SoT = labor calendar | ✅ EX-03.2 (superseded) |
| [`adr-0003-weekly-recurring-base.md`](./adr-0003-weekly-recurring-base.md) | Base recurrent setmanal viva (grup+empleat); elimina `work_schedules` | ✅ EX-03.2-bis |
| [`plan-attendance-stations.md`](./plan-attendance-stations.md) | Estacions fitxatge per ubicació (`attendance_devices`) | ⚠️ MVP+EX; ST-9V2/11/12/13/6c+/14/2a+/15 ✅; **AP-05/10** ✅ |
| [`plan-attendance-legal-access.md`](./plan-attendance-legal-access.md) | **EX-09** — Retenció configurable (0b.1) + enllaç d'inspecció amb caducitat (0b.4) | ✅ EX-09.1–09.3 |
| [`plan-shift-planner-v2.md`](./plan-shift-planner-v2.md) | Integració de calendari, horaris, torns, ubicacions i cobertura | 📦 Pla V2 |
| [`revisio-critica-estacions-fitxatge.md`](./revisio-critica-estacions-fitxatge.md) | Snapshot de riscos i correccions prioritzades | ✅ Persistit |
| [`revisio-exhaustiva-estacions-vs-codi.md`](./revisio-exhaustiva-estacions-vs-codi.md) | Auditoria plans vs codi/migracions | ✅ Persistit |
| [`analisi-producte-control-horari.md`](./analisi-producte-control-horari.md) | Oportunitats i anti-idees de producte | ✅ Persistit · **AP-06** check-in contextual = backlog (deps ✅; falta espec. d'implementació) |
| [`plan-work-status-push.md`](./plan-work-status-push.md) | Work Status Fase B — recordatoris push fitxatge (portal VAPID) | 📦 Pla (WS-B0); Fase A ✅ |
| [`calendaris-laborals.md`](../../help/horaris/calendaris-laborals.md) | Com funciona la cascada de calendari avui | ✅ **Font de veritat operativa** del calendari |
| [`../employee-import/plan.md`](../employee-import/plan.md) | Import/sync empleats (CSV, Holded, PayFit, mapping) | ✅ EI0+EI2+EI1 (CSV); **EI3+ en cua** |
| [`../Holded_Payfit/estudi-integracio-holded-payfit.md`](../Holded_Payfit/estudi-integracio-holded-payfit.md) | Complementaritat Holded/PayFit vs PiMed | ✅ Estudi estratègic |

### Font de veritat recomanada per àmbit

| Àmbit | On mirar |
|-------|----------|
| Principis i arquitectura | Docs 14–15 |
| **Tres capes d'estat** (jornada / dia nòmina / mes legal) | Doc **15 §15.9** · implementació UI: `plan-monthly-close-approval.md` §A1 |
| Calendari laboral (com funciona) | `docs/help/horaris/calendaris-laborals.md` |
| Cascada horari / ADR SP-0 | [`adr-0001-work-plan-source-of-truth.md`](./adr-0001-work-plan-source-of-truth.md) |
| Decisió work_schedules | [`adr-0003-weekly-recurring-base.md`](./adr-0003-weekly-recurring-base.md) (supersedeix [`adr-0002`](./adr-0002-work-schedules-option-b.md)) |
| Tipus absència + codis export nòmina | `docs/help/horaris/tipus-absencia-export-nomina.md` |
| Tancament mensual / nòmina / audit | `plan-monthly-close-approval.md` (Tracks A, D) |
| Confirmació empleat per període (mensual/setmanal) | `plan-period-employee-confirm.md` |
| Vista nòmina gestor (dies sense fitxatge, absències, IT) | `plan-monthly-close-approval.md` (Track B, C) |
| Fitxatge intel·ligent (geo, horari, incidències) | `plan-monthly-close-approval.md` (Track E) |
| Pauses, absències, IT (semàntica) | `prompt_refine_pauses.md` + migració `20260728000005_attendance_v3_absences_refinement.sql` |
| Schema real | `supabase/migrations/202605*` → `202608*` |
| Roadmap infra (SLO, cua, automatitzacions) | `plan.md` |
| Roadmap operatiu (nòmina, tancament, export, fitxatge UX) | `plan-monthly-close-approval.md` |
| Temps efectiu, cortesia, arrodoniment, OT real | `plan-effective-work-time.md` (Track G) |
| Work Status (alertes in-app + push recordatoris) | Fase A ✅ codi · Fase B [`plan-work-status-push.md`](./plan-work-status-push.md) |
| Estat d'implementació | **Aquest fitxer** |
| Ordre d'execució, fase activa i què queda | [`EXECUTION.md`](./EXECUTION.md) |
| Import empleats des de ERP/nòmina | `docs/plans/employee-import/plan.md` |
| Integració Holded/PayFit (estratègia) | `docs/plans/Holded_Payfit/` |

---

## 2. Línia evolutiva

```
Docs 14–17 (disseny V1, migració JCM)
        │
        ├── Phase 0–2 backend (legal + calendari + torns)     ✅
        ├── Phase 3–4 UI inicial (fitxatge + planificador)     ⚠️ ~80%
        │
        └── plan.md (Control Horari v3)
                ├── Refinament pauses/absències/IT             ⚠️ backend fet, UI parcial
                ├── Navegació unificada                        ✅
                ├── Tauler manager                             ✅
                ├── Enduriment / SLO / legal avançat           ❌–⚠️
                └── Automatitzacions                           ❌
```

---

## 3. Estat per fases (doc 17 — implementació V1)

### Phase 0 — Design Sprint ✅

- [x] 9 open questions resoltes (estacions tècniques, geofencing configurable, torns nocturns, Nager.Date, etc.)
- [x] Extensió model torns (`work_shifts`, `shift_slots`, `shift_swap_requests`)
- [x] Actualitzar docs 14–16 amb decisions preses (2026-06-30)

### Phase 1A — Legal Foundation Backend ✅

Migració principal: `20260515000018_attendance_core.sql`

| Component | Estat |
|-----------|-------|
| `attendance_devices`, `attendance_location_assignments` | ✅ |
| `time_punches`, `time_entries`, `time_daily_summaries` | ✅ |
| RPCs: `record_time_punch`, `sync_time_punches`, `my_attendance_today` | ✅ |
| RPCs: `approve_time_day`, `adjust_time_entry`, `export_payroll_days` | ✅ |
| Settings (geofencing, arrodoniment, overtime) | ✅ |
| RBAC + RLS | ✅ |
| PGMQ `attendance_recompute_queue` + `process-attendance-queue` | ✅ |
| Tests `supabase/tests/attendance_tests.sql` | ✅ |

### Phase 1B — Calendari Laboral Backend ✅ (model ampliat)

Migracions: `20260521000001_labor_calendar.sql` i posteriors.

| Component | Estat |
|-----------|-------|
| `work_schedules`, `work_schedule_intervals`, `employee_schedule_assignments` | ❌ eliminades a EX-03.2-bis (ADR-0003) — veure `calendar_group_weekly_intervals`/`employee_weekly_intervals` |
| `holiday_calendars`, `holidays` | ✅ |
| `employee_absences` | ✅ |
| Import festius Nager.Date (`api.import_holidays`) | ✅ |
| `api.resolve_work_day` | ✅ |
| Torns nocturns (`work_date` = dia d'inici) | ✅ |
| **`labor_calendar_overrides`** (overrides per dia) | ✅ — *evolució beyond doc 16* |
| **`calendar_groups`** + assignació a empleats | ✅ — *evolució beyond doc 16* |
| **`work_intervals` JSON** (múltiples trams per dia) | ✅ — *evolució beyond doc 16* |
| Tests `supabase/tests/attendance_calendar_tests.sql` | ✅ |

### Phase 2 — Shift Planning Backend ✅ (EX-03…EX-07 sobre el core inicial)

Migracions: `20260521000002_shift_planning.sql` + hardening EX-03…EX-07.

El core inicial (`work_shifts` / `shift_slots`) està ampliat: slots a la cascada del resolver, cobertura per franja/ubicació/rol, demanda, vacants i swaps. Detall V2 residual (SP-6 forecast, polish UI): [`plan-shift-planner-v2.md`](./plan-shift-planner-v2.md).

| Component | Estat |
|-----------|-------|
| `work_shifts`, `shift_slots`, `shift_swap_requests` | ✅ |
| `shift_coverage_requirements` | ✅ (+ `coverage_demands` EX-06.2) |
| RPCs: assignar, publicar, cobertura, swaps | ✅ |
| Tests `supabase/tests/attendance_shifts_tests.sql` (23 PASS) | ✅ |
| Torn publicat dins la cascada d'horari efectiu | ✅ EX-03.3 (intervals) + EX-03.4 (`scheduled_location_*`) |
| Ubicació als slots (schema + resolver) | ✅ EX-03.4 / ST-19 schema (`location_id`, snapshots, herència) |
| Recompute en publish/cancel de slots | ✅ EX-03.5 (`enqueue_attendance_day_recompute` + trigger) |
| Publicació versionada (lots) | ✅ EX-04.1 (`shift_publications` + `publication_id`) |
| CRUD plantilles `work_shifts` | ✅ EX-04.2 (`create`/`update`/`deactivate_work_shift`) |
| Multi-slot/dia + anomalies assignació | ✅ EX-04.2 (UI + toast `SHIFT_OVERLAP`/`WEEKLY_HOURS_EXCEEDED`) |
| Preflight publicació + warnings_accepted | ✅ EX-04.3 (`preflight_publish_shifts` + gate a `publish_shifts`) |
| Diff entre lots de publicació | ✅ EX-04.3 (`diff_shift_publications`) |
| Bloqueig períodes tancats (planner) | ✅ EX-04.3 (`payroll_locked` + mes `manager_approved|signed|archived`) |
| `shift_slot` al calendari general | ✅ EX-04.4 (`shifts.calendar` + deep-link planificador) |
| Portal «Els meus torns» | ✅ EX-04.4 (`/portal/shifts` + `employee_portal_get_my_shifts`) |
| Rols / quals / demanda | ✅ EX-06.1–06.2 (`work_roles`, quals, `coverage_demands`) |
| Vacants / openings | ✅ EX-07.2–07.4 (veure Phase 4 UI) |

### Phase 3 — UI Fitxatge + Estació ⚠️ ~80%

| Component | Estat |
|-----------|-------|
| Feature `apps/tenant-portal/src/features/attendance/` | ✅ |
| `PunchPage` — IN/OUT, pauses, teletreball, geo, offline | ✅ (requereix `tenant_pause_configs`; seed Acme a `attendance_demo.sql`) |
| IndexedDB outbox + drainer (`useAttendanceSync`, 30s) | ✅ lots via `sync_time_punches` (EX-05.1) |
| `MyRecordPage` — historial + fallback raw provisional | ✅ |
| `AnomalyAlert`, `DailyTimeline`, `PauseButtonGroup` | ✅ |
| Edge Function `punch-from-station` | ❌ |
| `StationPage` (mode estació fixa) | ✅ `/station` + ST-18; **EX-05.2** outbox offline |
| Tokens QR/barcode (`issue_attendance_identity_token`) | 📦 V2 (decisió Phase 0: V1 = selecció manual) |
| Batch offline via `sync_time_punches` al frontend | ✅ EX-05.1 (tenant + portal `/punch/sync`; UUID v7 estable) |
| Outbox kiosk IndexedDB (ST-9 V2) | ✅ EX-05.2 (`attendance_station_outbox` + drain) |
| Offline timestamps + monotònic (ST-9 V2) | ✅ EX-05.3 (`occurred_at` toc / `received_at` pujada) |
| Skew / delay / max_age / quarantena | ✅ EX-05.4 (`CLOCK_SKEW`, `OFFLINE_DELAY`, `station_punch_too_old`) |
| E2E offline (avió / retry / TZ / nocturn) | ✅ EX-05.5 (SQL 6/6 + HTTP 6/6 + CI) |
| FF-04 offline deferred punch | ✅ EX-05.6 (`station_offline_deferred_punch` + runbook) |
| Export CSV inspecció / PDF mensual / A3-Sage | ⚠️ Inspecció + JSON/CSV D2; **D3.1 perfils export** ✅; **D3.2 Conectia WK** ⏸️ posposat |
| Demo seed (`seed_acme_attendance_punches`) | ✅ `20260803000001` |

### Phase 4 — UI Calendari i Planificador ⚠️ ~75%

| Component | Estat |
|-----------|-------|
| Navegació manager unificada `/attendance-mgmt/*` | ✅ |
| Redirects `/control-horari/*` → `/attendance-mgmt/*` | ✅ |
| `PlanificacioPage` — calendari, festius, grups, pauses, rols, demanda, entitlements | ✅ |
| `ShiftsPage` — grid setmanal, publicar torns | ⚠️ MVP+ (EX-04.3: preflight dialog + diff toast; sense historial revisions ni selector ubicació/rol) |
| `SchedulePlannerPage` — grid TanStack Table | ✅ |
| `AbsencesPage` — aprovació, IT manual | ✅ |
| `CalendarPage` — calendari treballador | ✅ |
| Vista cobertura per franja (heatmap) | ✅ EX-06.4 (`get_coverage_buckets` + capes) |
| Dashboard cobertura operatiu / gaps | ✅ EX-06.5 (`get_coverage_operational_snapshot` + widget Tauler) |
| Disponibilitat empleat (regles + excepcions) | ✅ EX-07.1 (`employee_availability_*` + fitxa empleat) |
| Vacants / openings + claims | ✅ EX-07.2–07.4 |
| Swap / give-away / call-off | ✅ EX-07.5 |
| Push vacants/swaps + escalat urgent | ✅ EX-07.6 (`planning_push` + cron) |
| Regles laborals (descans/jornada/dies) | ✅ EX-08.1 (`labor_rules` + preflight/eligibility + UI) |
| Automatitzacions d’anomalies (AP-08) | ✅ EX-08.2 (in-app, dedup, quiet hours, cron) |
| Heurístiques fatiga/equitat (AP-09) | ✅ EX-08.3 (`get_site_planning_heuristics` + UI) |
| Import CSV + mappings externs (AP-12) | ✅ EX-08.4 (`import_employees_bulk` + `external_entity_mappings`) |
| Integració `calendar_events` per torns publicats | ⚠️ Parcial |
| Realtime Supabase per refresc live | ⚠️ No com a garantia de sync |

---

## 4. Estat per fases (plan.md — Control Horari v3)

### Fase 0 — Capacitat, SLO i observabilitat ⚠️ (implementat, validar en staging)

| Item | Estat |
|------|-------|
| SLOs definits | ✅ [`plan.md`](./plan.md) §0.1 |
| Proves de càrrega 1k–10k | ✅ Script `supabase/tests/attendance_load_test.ts` |
| Tuning worker (batch adaptatiu + catch-up) | ✅ Migració `20260806000001` + worker multi-batch |
| `api.get_attendance_queue_health` | ✅ |
| Cron adaptatiu (`invoke_attendance_queue_worker()`) | ✅ |
| Runbook operatiu | ✅ [`runbook-attendance-queue.md`](./runbook-attendance-queue.md) |
| Dashboard operatiu UI (admin) | ❌ — consulta SQL/RPC per ara |
| Alertes automatitzades (Sentry/PagerDuty) | ❌ — usar `alert_*` del health JSON |

### Fase 0b — Compliment legal explícit (RD 8/2019) ✅

| Item | Estat |
|------|-------|
| `export_attendance_month` RPC | ✅ |
| `attendance_monthly_reports` + estats `employee_confirmed` / `manager_approved` | ✅ |
| Edge Function `generate-attendance-report` (hash SHA-256) | ✅ |
| UI informe mensual (`MonthlyAttendanceReportPanel`) | ✅ |
| Signatura digital via mòdul documents/signing | ✅ Plantilla + UI + validació A2 abans d'iniciar |
| Validació tancament mes (`validate_attendance_month_close`) | ✅ A2 |
| Flux configurable (empleat opcional / signatura = aprovació) | ✅ A4 — settings tenant |
| Audit + Activitat empleat (confirmació/aprovació mensual) | ✅ A5 — `ATTENDANCE_MONTH_*`, IT, absències |
| Export inspecció read-only | ✅ `export_attendance_inspection` (20260807000001) |
| Retenció 4 anys (purge batched opt-in) | ✅ EX-09.1 — [`plan-attendance-legal-access.md`](./plan-attendance-legal-access.md) |
| Accés inspecció (enllaç amb caducitat) | ✅ EX-09.2 — enllaç opac + cookie HttpOnly (no ZIP / no rol membre) |

### Fase 1 — Evolució DB ✅ majoritàriament

Migracions: `20260727000001` → `20260728000008` i posteriors.

| Item | Estat |
|------|-------|
| Camps nous `time_punches` (pause, geo GDPR, remote, device_info) | ✅ |
| `tenant_pause_configs` + seed per arquetip | ✅ |
| `vacation_entitlements` (cascada tenant/dept/empleat) | ✅ |
| `tenant_absence_type_configs` + seeds legals de sistema | ✅ |
| `employee_absences` ampliat (parcials, IT, entitlements) | ✅ |
| Detecció `PAUSE_NOT_CLOSED` + resolució manager | ✅ |
| `attendance_absence_requests` (taula separada del pla v3) | ❌ — s'usa `employee_absences` directament |
| Integració `approval_requests` genèric | ❌ |

**Decisions documentades** (`20260728000005_attendance_v3_absences_refinement.sql`):

1. Pauses → `time_punches` (`break_start`/`break_end`); no `pause_sessions`
2. Absència parcial → `employee_absences` amb `partial_start_time`/`partial_end_time`
3. IT → registre manual manager (fins integració INSS)
4. IT + fitxatge → prioritat IT; anomalia `IT_PUNCH_CONFLICT`
5. Seeds de pausa per `archetype_key`

### Fase 2 — Frontend fitxatge personal ✅

| Item | Estat |
|------|-------|
| Màquina d'estats (working / on_pause / outside) | ✅ |
| Cas crash — pausa oberta + timeout + resolució | ✅ |
| Geolocalització amb consentiment GDPR | ✅ |
| Offline amb camps nous a IndexedDB | ✅ |
| Historial amb fallback raw provisional | ✅ |

### Fase 3 — Reestructuració navegació ✅

| Ruta | Estat |
|------|-------|
| `/attendance` — fitxatge treballador | ✅ |
| `/attendance-mgmt/dashboard` — tauler | ✅ |
| `/attendance-mgmt/records` — fitxatges | ✅ |
| `/attendance-mgmt/employees` — empleats | ✅ |
| `/attendance-mgmt/calendar` — calendari laboral | ✅ |
| `/attendance-mgmt/planning/shifts` — torns | ✅ |
| `/attendance-mgmt/planning/schedules` — horaris | ✅ |
| `/attendance-mgmt/absences` — absències | ✅ |
| Redirects `/control-horari/*` | ✅ |

### Fase 4 — Tauler Control Horari ✅

| Item | Estat |
|------|-------|
| `TaulerPage` — stats, llista, mapa, calendaris | ✅ |
| `mv_today_site_status` | ✅ |
| `api.get_today_dashboard_rows` (context horari esperat) | ✅ EX-03.6 — `resolve_employee_work_plan` (absències/slots) |
| `ResolveOpenPauseDialog` | ✅ |
| Refresc MV des del worker a cada recompute | ⚠️ Parcial |

### Fase 5 — Operativa completa ⚠️

| Item | Estat |
|------|-------|
| Fitxatges — vista diària/setmanal/mensual + detall dia | ✅ |
| Ajustos sense alterar raw (`adjust_time_entry`) | ✅ |
| Aprovació diària des de UI (`approve_time_day`) | ✅ Detall dia + aprovació massiva visibles |
| Export inspecció (`export_attendance_inspection`) | ✅ CSV/JSON des de Fitxatges (només lectura) |
| Export payroll (`export_payroll_days`) | ⚠️ RPC mínim (worked, overtime, day_type); marca exported |
| Export nòmina ampliat CSV/JSON (`export_payroll_period`) | ✅ D2 — dies + absències/IT + agregat; només lectura |
| Vista nòmina completa (absències, IT, dies sense fitxatge) | ✅ B2 (Fitxatges) + B5 (timesheet empleat) |
| Accions per fila revisió nòmina (aprovar, ajust, absència, IT) | ✅ B3 — `PayrollReviewDayActions` a Fitxatges equip |
| Barra gestió manager al timesheet (blockers, IT, absència, enllaç revisió) | ✅ B4 — `TimesheetManagerActionBar` |
| Deep link timesheet empleat → Fitxatges equip | ✅ — Track B1 (`?employeeId&from&to`) |
| IT / absència des de fitxa empleat | ✅ C2 — pestanya Timesheet a fitxa empleat |
| Compensacions / banc hores / festiu treballat | ✅ C3 — ledger UI + auto festiu + export D2 saldo (`20260909000003`) |
| Taxonomia absències 2 nivells + codi export | ✅ C1 — `parent_key`/`subtype_key`/`export_code`, settings + export D2 (`20260912000001`) |
| Fitxatge: horari sempre visible + geo localitzant | ✅ E1–E4 |
| Fitxatge: geo per dispositiu + cascada empleat/dept/grup/tenant | ✅ E3–E4 |
| Incidències autocorrecció al fitxar (extra, horari, geo) | ✅ E5 — `PunchDiscrepancyDialog` |
| Work Status Fase A — alertes in-app horari vs fitxatge | ✅ — `WorkScheduleStatusCard` (tenant + portal); `computeWorkScheduleStatus` |
| Work Status Fase B — recordatoris push fitxatge (portal) | ✅ WS-B1–B6 — smoke: [`DEV_RUNBOOK.md`](../../DEV_RUNBOOK.md) § WS-B6; cal VAPID per prova real al navegador — [`plan-work-status-push.md`](./plan-work-status-push.md) |
| Auto-assistència aprovació (confiança horari previst) | ✅ E6 — banner + bulk approve B2 |
| UI hores extra (B2, timesheet, config política) | ✅ C4 |
| Flux aprovació registre mensual (empleat → manager) | ✅ Modal A3 + validació A2 + config A4 |
| Signatura digital registre mensual (DMS/signing) | ✅ A7 — validació A2 abans d'iniciar signatura |
| Confirmació empleat amb validació temporal | ✅ — mes futur / jornades pendents / fitxatges oberts bloquejats |
| Confirmació per període (setmanal / `PERIOD_NOT_ENDED` estricte) | ✅ Fases 0–5 + P0/P1/P2 + P2b signatura com a confirmació — [`plan-period-employee-confirm.md`](./plan-period-employee-confirm.md) |
| Terminologia estats dia vs mes (i18n, `approved` vs `closed`) | ✅ — Track A1 (`status_layers.*`, dues columnes jornada/dia nòmina) |
| Tancament mes sense confirmació empleat (nòmina) | ✅ Configurable (A4): override + checkbox al modal; Fase 5: cobertura períodes quan override desactivat |
| Config flux tancament mensual (tenant settings) | ✅ A4 — `/settings/attendance-control` secció nòmina |
| Audit control horari a Activitat empleat | ✅ A5 — `ATTENDANCE_MONTH_*`, IT, absències |
| Portal empleat (app): confirmació/signatura mensual | ✅ A6a — `MyRecordPage` vista Mes |
| Portal empleat EP3: tab Accés (crear/revocar enllaços) | ✅ — millores v2 a [`plan-employee-portal-access-v2.md`](./plan-employee-portal-access-v2.md) (EP-ACC-1…9) |
| Hub «Accés al portal» a `/employees?tab=portal_hub` | ✅ EP-ACC-8 — overview, bulk, importacions; smoke [`ep-acc8-hub-smoke-checklist.md`](./ep-acc8-hub-smoke-checklist.md) |
| Identity Gate DNI (primer accés token personal) | ✅ EP-ACC-9 — Edge + public-portal; tests I-T* |
| Estació fitxatge (`attendance_devices`, `punch-from-station`) | ❌ — esbòs [`plan-attendance-stations.md`](./plan-attendance-stations.md) |
| Portal públic EP8: confirmació L1 via `/e/{token}` | ⚠️ A6b — codi ✅; smoke [`ep8-smoke-checklist.md`](./ep8-smoke-checklist.md) pendent |
| Docs 3 capes estat (jornada / dia / mes) | ✅ A8 — doc 15 §15.9 |
| Esmenes post-tancament (rectificació sense refacturar) | ✅ F1 — `MonthlyReportAmendmentsSection` |
| Config pauses per tenant (CRUD) | ✅ (Calendari → Tipus de pausa) |
| Config tipus absència per tenant | ✅ C1 — `/settings/attendance-control` codis export + subtipus |
| Entitlements vacances/permisos (CRUD) | ✅ |
| Política geo per tenant / dept / grup / empleat | ✅ E4 — `/settings/attendance-control`, departaments, grups calendari, fitxa empleat |
| Vista anual empleat (previst vs fet) | ⚠️ Parcial (`EmployeeTimesheetTab`) |

### Fase 6 — Integració motor d'automatitzacions ✅

| Trigger proposat | Estat |
|------------------|-------|
| `PUNCH_IN_UNUSUAL_HOUR` | ✅ Fase 6 (trigger insert punch + emit) |
| `PUNCH_OUT_MISSING` | ✅ EX-08.2 (in-app + scan/cron) |
| `OVERTIME_THRESHOLD_EXCEEDED` | ✅ via G5 `ATTENDANCE_OVERTIME_THRESHOLD` |
| `PAUSE_NOT_CLOSED` (com a automation trigger) | ✅ EX-08.2 (wire a `check_unclosed_pauses`) |
| `SHIFT_COVERAGE_GAP` | ✅ EX-08.2 (vacants obertes) |
| `MONTH_CLOSED_REPORT` | ✅ Fase 6 (approve month → emit + `generate-attendance-report`) |
| `ABSENCE_REQUEST_PENDING` | ✅ Fase 6 (insert absència `requested`) |

---

## 5. Divergències rellevants (plans vs codi)

### 5.1 Model de calendari

**Plans 16/17:** horari setmanal + assignació + festius + absències.

**Codi actual:** tot això **més**:

- `labor_calendar_overrides` — override per dia (tenant / site / empleat)
- `calendar_groups` — patró comú + ajust per local
- `work_intervals` JSON — múltiples trams per dia
- Cascada documentada a `docs/help/horaris/calendaris-laborals.md`

### 5.2 Absències

El pla v3 proposava `attendance_absence_requests`. **No s'ha creat.** Flux actual: `employee_absences` amb estats `requested` → `approved` / `rejected`. Compatible amb migració futura a `approval_requests`, però encara ad-hoc.

### 5.3 Tauler manager

Pla v3: només vista materialitzada. Implementació: MV **+** RPC `get_today_dashboard_rows` (més context per horari esperat i ordenació).

### 5.4 Sync offline

Arquitectura (doc 15): lots via `sync_time_punches`. **EX-05 ✅** (05.1–05.6): batch, outbox, timestamps, skew/max_age, E2E, FF-04 `station_offline_deferred_punch` (default OFF; Acme ON local). Runbook: [`docs/runbooks/station-offline-deferred-punch-runbook.md`](../../runbooks/station-offline-deferred-punch-runbook.md).

### 5.5 Seed i càrrega de pauses

- **Seed:** `attendance_demo.sql` aplica l'arquetip `generic` a Acme i Beta (la migració v2 no cobreix tenants creats per `seed.sql`).
- **Hook:** `usePauseConfigs` espera `tenantScopeReady` i inclou `tenantId` a la query key (evita cache buit si el RPC s'executa abans del header `x-tenant-id`).
- **UI gestor:** Control horari → **Calendari → Tipus de pausa** (no a Planificació).

### 5.6 Estats diari vs mensual (terminologia)

Tres capes independents documentades a [`15-time-attendance-architecture.md`](../../product-design/15-time-attendance-architecture.md) **§15.9**:

| Capa | Taula | UI |
|------|-------|-----|
| Jornada | `time_entries` | `AttendanceLayerStatusBadge` — columna «Jornada» |
| Dia nòmina | `time_daily_summaries` | Columna «Dia nòmina» a Fitxatges / revisió nòmina |
| Mes legal | `attendance_monthly_reports` | Registre mensual (confirmat / tancat / signat) |

i18n: `status_layers.*`. Detall implementació: [`plan-monthly-close-approval.md`](./plan-monthly-close-approval.md) §A1 ✅.

---

## 6. Track G — Temps efectiu de treball

> Pla complet: [`plan-effective-work-time.md`](./plan-effective-work-time.md) (PRD **v4.3** — §21 revisió pre-implementació).  
> Integració projectes: [`prompts/shared/work-logs-time-attendance-integration.md`](../../../prompts/shared/work-logs-time-attendance-integration.md) (D-INT-1 … D-INT-12).  
> Depèn de Tracks A–E. **v4:** segments (`WORK`/`TRAVEL`/…), `paid_minutes`, `work_profile` (`fixed_site` | `mobile_peripatetic`).

| Fase G | Entregable | Estat |
|--------|------------|-------|
| **G0** | PRD v4.3 + STATUS + doc 15 §15.8–15.9 + help | ✅ PRD v4.3; doc 15 §15.8–15.9 ✅; help pendents menors |
| **G1** | Policies v2 + `work_profile` + settings legals + UI grups | ✅ — migració `20260901000001`, tests T1–T8, UI tenant/grup/empleat, smoke test ([`prompt-track-g-phase-1.md`](./prompt-track-g-phase-1.md)) |
| **G1b** | `time_activity_segments` + nous `punch_type` + classificador + UI fitxatge mobile | ✅ tancat — migració `20260902000001`, tests T1–T4, UI tenant + portal ([`prompt-track-g-phase-1b.md`](./prompt-track-g-phase-1b.md)) |
| **G2a** | Motor `fixed_site` (cortesia per tram, ∩ expected, buckets, payroll RPC) | ✅ — migracions `20260903000001`–`003`, tests T1–T7 ([`prompt-track-g-phase-2a.md`](./prompt-track-g-phase-2a.md)); **G2a.2** `flex_midday` ✅ `20261058000001` |
| **G2b** | Motor `mobile_peripatetic` punch-only (`time_budget`, TRAVEL, buckets) | ✅ — migracions `20260904000001`–`005`, tests T1/T8a/T8b/T9 ([`prompt-track-g-phase-2b.md`](./prompt-track-g-phase-2b.md)) |
| **G2c** | Integració `work_logs.field_punch` + gaps D-INT-7 + RPCs composta | ✅ — migracions `20260905000001`–`006`, tests TA/TB/TD ([`prompt-track-g-phase-2c.md`](./prompt-track-g-phase-2c.md)) |
| **G3** | UI 4 columnes + timeline segments | ✅ — `EffectiveTimeBucketsPanel`, `ActivitySegmentsTimeline`, anomalies G2 ([`prompt-track-g-phase-3.md`](./prompt-track-g-phase-3.md)) |
| **G4** | Mensual EP8 + D2 desglossament remunerable | ✅ — migració `20260906000001`, UI mensual + export D2 + L1 ([`prompt-track-g-phase-4.md`](./prompt-track-g-phase-4.md)) |
| **G5** | Rollups multi-bucket + alertes + ledger C3 | ✅ — migracions `20260907000001`–`002`, tests T1–T4, UI comptadors + widget tauler ([`prompt-track-g-phase-5.md`](./prompt-track-g-phase-5.md)) |
| **G6** | Protocol DMS + portal Documents | ✅ **Lot 1–4** complet (G6.1–G6.10 excepte backlog buit) |

**G6 backlog (post-MVP):** tots els items G6.1–G6.10 implementats — veure [`prompt-track-g-phase-6.md`](./prompt-track-g-phase-6.md).

**Decisions v4.3 clau:** revisió §21 — G2a ✅ (oficina); G2b ✅ punch-only mobile; **G2c** ✅ field_punch + gaps; G3 UI segments; un sol feature flag; E6 per perfil (`effective` vs `paid`).

---

## 7. Fora d'abast (explícit)

| Item | Motiu / referència |
|------|-------------------|
| Nòmina legal completa | Doc 14 §14.4 |
| Edició offline de calendaris/absències | Doc 14 §14.4 |
| Geofencing bloquejant per defecte | Decisió Phase 0 — mode `informative` per defecte |
| Background sync garantit iOS | Doc 14 §14.4 |
| Biometria, NFC, BLE | Doc 14 §14.4 |
| QR/barcode a estació | Decisió Phase 0 — V2 |
| Integració INSS per baixes | `plan.md` + `prompt_refine_pauses.md` |
| Estació fixa (`punch-from-station`) | Phase 3 doc 17 — **diferida**, no implementada |

---

## 8. Resum executiu

**Construït i operatiu:**

- Pipeline legal: raw immutable → entries → daily summaries → recompute asíncron
- Fitxatge personal amb pauses, teletreball, geo, offline
- Calendari laboral en cascada (festius, overrides, grups, intervals)
- Planificació de torns (backend + UI)
- Absències, IT manual, entitlements, informes mensuals amb confirmació/aprovació parcial
- Navegació manager unificada i tauler del dia

**Gap principal (no és «començar de zero»):**

1. Enduriment i escala (Fase 0 v3) — validar en staging; dashboard/alertes ❌
2. Compliment legal residual — retenció 4 anys, accés inspecció autoritat
3. Estació fixa (diferida)
4. Automatitzacions proactives (Fase 6)
5. Smoke EP8 portal públic (A6b) i confirmació per període setmanal (fases 1–5)
6. **Temps efectiu** — Track G implementat (G1–G6); manteniment i backlog post-MVP

---

## 9. Seqüència recomanada

| Prioritat | Acció | On |
|-----------|-------|-----|
| 1 | Proves de càrrega + tuning worker + observabilitat | `plan.md` Fase 0 |
| 2 | UI aprovació diària + export inspecció | ✅ |
| 3 | Nòmina i tancament mensual (Tracks A–D, F1) | ⚠️ gairebé complet — pendent A6b smoke |
| 4 | Fitxatge intel·ligent (Track E) | ✅ |
| 4b | Temps efectiu — G1–G6 | ✅ [`plan-effective-work-time.md`](./plan-effective-work-time.md) |
| 5 | Signatura informe mensual (DMS) | ✅ A7 — `link_attendance_monthly_report_signing` + UI amb validació A2 |
| 6 | Batch offline al client (`sync_time_punches`) | ✅ EX-05.1 |
| 7 | Triggers automatització (mínim 3) | v3 Fase 6 |
| 8 | Estació fixa quan hi hagi demanda | doc 17 Phase 3 |
| 9 | Consolidar o arxivar docs 14–17 | ✅ docs 14–16 sincronitzats |

---

## 10. Fitxers clau al repositori

### Migracions (ordre aproximat)

```
supabase/migrations/
  20260515000018_attendance_core.sql          # Phase 1A — nucli legal
  20260521000001_labor_calendar.sql           # Phase 1B — calendari base
  20260521000002_shift_planning.sql           # Phase 2 — torns
  20260727000001_attendance_v2_core.sql       # v3 — pauses, geo, entitlements
  20260728000005_attendance_v3_absences_refinement.sql  # absències, IT, seeds
  20260730000001_resolve_work_day_labor_calendar.sql    # cascada calendari
  20260801000001_today_dashboard_rpc.sql      # tauler manager
  20260802000002_manager_resolve_open_pause.sql
  20260803000001_seed_acme_attendance_punches_fn.sql     # demo
  20260806000001_attendance_queue_capacity.sql           # Fase 0: catch-up, health RPC, cron
  20260807000001_attendance_inspection_export.sql   # export inspecció (read-only)
  20260808000001_attendance_monthly_report_signing.sql  # plantilla + signatura mensual
  docs/plans/checkin/plan-monthly-close-approval.md   # pla tancament mensual (actiu)
  docs/plans/checkin/plan-effective-work-time.md      # PRD temps efectiu (Track G)
```

### Frontend

```
apps/tenant-portal/src/features/attendance/
  pages/PunchPage.tsx              # fitxatge treballador
  pages/MyRecordPage.tsx           # historial + informe mensual
  pages/ControlHorariLayout.tsx    # layout manager
  pages/TaulerPage.tsx             # tauler del dia
  pages/PlanificacioPage.tsx       # calendari laboral + config
  pages/ShiftsPage.tsx             # planificador torns
  pages/AbsencesPage.tsx           # absències + IT
  pages/AllTimeEntriesPage.tsx     # fitxatges equip + export inspecció + aprovació massiva
  components/records/AttendanceDayDetailDialog.tsx  # detall dia
  components/records/DayDetailApprovalSection.tsx   # aprovació diària
  components/records/InspectionExportDialog.tsx       # export inspecció CSV/JSON
  components/records/BulkApproveDraftBar.tsx          # aprovació massiva draft
  components/records/MonthlyReportSigningSection.tsx  # signatura DMS
  api/recordsApprovalService.ts    # approve_time_day + export_attendance_inspection
  api/monthlyReportSigningService.ts    # flux sign-document-router
  hooks/useAttendanceSync.ts       # offline outbox
  db/attendanceDb.ts               # IndexedDB
```

### Edge Functions

```
supabase/functions/
  process-attendance-queue/        # worker recompute
  generate-attendance-report/      # export mensual + hash
```

### Tests SQL

```
supabase/tests/
  attendance_tests.sql
  attendance_calendar_tests.sql
  attendance_labor_rules_ex081_tests.sql  # EX-08.1
  attendance_anomaly_automations_ex082_tests.sql  # EX-08.2
  attendance_fase6_triggers_tests.sql             # Fase 6 triggers
  attendance_effective_time_fixed_site_tests.sql  # G2a + G2a.2 T8–T10
  attendance_planning_heuristics_ex083_tests.sql  # EX-08.3
  employee_import_csv_ex084_tests.sql  # EX-08.4
  attendance_load_test.ts          # proves de càrrega Fase 0
  run_attendance_load_test.ps1
```

---

## 11. Manteniment d'aquest document

Actualitzar `STATUS.md` quan:

- Es completi una fase del `plan.md` o del doc 17
- Canviï el model de dades (nova migració rellevant)
- Es tancin decisions obertes de `prompt_refine_pauses.md` §5.2
- S'implementi o es descarti explícitament un item de les seccions 6–7
- Avanci una fase del Track G (`plan-effective-work-time.md`)
