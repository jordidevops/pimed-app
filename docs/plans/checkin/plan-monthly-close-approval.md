# Control horari → Nòmina, tancament mensual i fitxatge intel·ligent

> **Data:** 2026-06-30 (v2 — ampliat)  
> **Estat:** pla operatiu actiu — implementació en curs  
> **Mapa global (font de veritat):** [`STATUS.md`](./STATUS.md)  
> **Infra / SLO / automatitzacions:** [`plan.md`](./plan.md) (no duplicar aquí)  
> **Relacionat:** [`18-employee-portal-architecture.md`](../../product-design/18-employee-portal-architecture.md) · [`prompt_refine_pauses.md`](./prompt_refine_pauses.md) · [`plan-period-employee-confirm.md`](./plan-period-employee-confirm.md) (confirmació per període — Fase 0 ✅)

### Progrés per track (2026-06-30)

| Track | Fet | Pendent prioritari |
|-------|-----|-------------------|
| **A** Tancament mensual | A1–A8 ✅ | **A6b** — smoke EP8 portal públic |
| **B** Vista nòmina gestor | B1 ✅; B2 ✅; B3 ✅; B4 barra manager ✅; B5 calendari timesheet ✅ | — |
| **C** Absències / IT | IT manual ✅; taxonomia backend ✅; **C2** fitxa empleat ✅; **C1** export_code ✅ | — |
| **D** Export nòmina | Inspecció ✅; D2 CSV període ampliat ✅; **D3.1 perfils export** ✅ | D3.2 Conectia ⏸️ posposat |
| **E** Fitxatge intel·ligent | E1–E6 ✅ | — |
| **F** Post-tancament | F1 ✅ | F2 refacturació (fora d'abast) |

**Següent recomanat:** **E5** → **D3** (spike). En paral·lel: **A1**.

---

## Resum executiu

Tres problemes entrellaçats:

1. **Tancament mensual** prematur o confús (estats, botons, sense audit).
2. **Dades incompletes per nòmina** — només es veuen dies amb fitxatges; absències, IT, compensacions i hores extra no apareixen al flux de revisió/export.
3. **Fitxatge passiu** — l'empleat no veu prou context (horari, geo en curs) ni pot autocorregir incidències que avui consumeixen temps administratiu.

Aquest document unifica el mini-pla de tancament mensual amb la **vista de nòmina del gestor**, el **mapa de dades d'exportació** i un **track de fitxatge intel·ligent**.

---

## Índex de tracks i fases

| Track | Tema | Fases |
|-------|------|-------|
| **A** | Semàntica, validació i tancament mensual | A1–A8 |
| **B** | Vista nòmina completa i navegació manager | B1–B5 |
| **C** | Absències, IT i taxonomia (referència PayFit) | C1–C4 |
| **D** | Export nòmina (CSV, A3, Sage, integradors) | D1–D4 |
| **E** | Fitxatge intel·ligent (`/attendance`) | E1–E6 |
| **F** | Post-tancament i esmenes | F1–F2 |

Ordre recomanat: **A1 → B1 → A2 → B2 → C1 → E1 → …** (detall al final).

---

# TRACK A — Tancament mensual i estats

## A1. Terminologia (3 capes) — ✅ P0, S

| Capa | Taula | Valors | UI (CA) |
|------|-------|--------|---------|
| **Jornada** | `time_entries` | `open`, `closed`, `adjusted`, `missing` | Jornada oberta / tancada / ajustada |
| **Dia nòmina** | `time_daily_summaries` | `draft`, `approved`, `exported` | Pendent revisió / Aprovat / Exportat nòmina |
| **Mes legal** | `attendance_monthly_reports` | `draft` … `signed` | Esborrany / Confirmat empleat / **Tancat per nòmina** / Signat |

**Fet:** i18n `status_layers.*`, `AttendanceLayerStatusBadge`, `TimesheetDayLayerBadges`, columnes «Jornada» + «Dia nòmina» al registre mensual i timesheet llista, calendari ambdues capes. **Documentació:** doc 15 §15.9 (A8 ✅).

**Fitxers:** `timesheetService.ts`, `MonthlyAttendanceReportPanel.tsx`, `EmployeeTimesheetTab.tsx`, `attendance.json`.

---

## A2. Validació «mes closable» — ✅ P0, M

RPC: `api.validate_attendance_month_close(employee_id, year, month)` → `{ closable, blockers[], warnings[] }`.

### Bloquejos (hard)

- Mes futur o mes corrent amb dies laborables encara no transcorreguts.
- `time_entry.status = 'open'` dins el mes.
- `needs_review = true` sense resoldre.
- (Configurable) dies laborables esperats sense registre tancat ni absència/IT aprovada.

### Avisos (soft → modal)

- Anomalies sense resoldre.
- Dies `draft` no aprovats individualment.
- Diferència treballat vs previst > llindar.

Guards a `approve_attendance_month`, signing link, export payroll.

---

## A3. UX tancament (modals, ordre botons) — ✅ P0, M

**Eliminar:** «Registrar confirmació empleat» i deprecar `manager_confirm_attendance_month` (o només amb motiu + audit explícit).

| Botó | Ordre | Modal |
|------|-------|-------|
| Descarregar JSON / export inspecció | esquerra | — |
| Aprovar registre | mig | Resum + blockers; depèn config empleat |
| Iniciar signatura | mig | Només si tancable + config |
| **Tancar mes per nòmina** | **darrer (dreta)** | Advertència forta: valida hores, pot ser sense confirmació empleat (config), bloqueig posterior |

Badge «Tancat per nòmina» → popover (qui, quan) + enllaç Activitat empleat.

---

## A4. Config flux tenant — ✅ P1, M

| Setting | Default | Efecte |
|---------|---------|--------|
| `attendance_monthly_employee_confirm_required` | `true` | Manager no pot tancar sense confirmació (excepte override) |
| `attendance_monthly_signature_is_employee_approval` | `false` | Signatura empleat = confirmació |
| `attendance_monthly_manager_can_close_without_employee` | `true` | Nòmina sense app empleat (doc 18) |
| `attendance_monthly_require_digital_signature` | `false` | Signatura obligatòria |
| `attendance_monthly_bulk_approve_days_on_close` | `true` | En tancar, marca dies `approved` en bloc |

---

## A5. Audit mensual → Activitat empleat — ✅ P1, M

Esdeveniments: `ATTENDANCE_MONTH_*`, `ATTENDANCE_IT_REGISTERED`, `ATTENDANCE_ABSENCE_APPROVED`, etc.

Feed `get_entity_timeline` per `employee` ha d'incloure payloads amb `employee_id`.

---

## A6. Portal empleat confirmació/signatura — ⚠️ P2, L

### A6a — App tenant-portal (empleats amb compte) — ✅

`/attendance/record` vista **Mes**: banner d’acció, modal de confirmació (validació A2: mes futur, jornades pendents, fitxatges oberts), botó «Signar el meu registre» quan hi ha submissió DMS (A7).

### A6b — Portal públic sense compte (doc 18 / EP8) — ⚠️ implementat, smoke pendent

**Implementat** al `public-portal` ([`plan-employee-portal.md`](./plan-employee-portal.md) §EP8):

- Enllaç `/e/{secret}` → sessió curta → `/portal/monthly`
- `GET /monthly-report`, `POST /monthly-report/confirm` (confirmació **L1** lectura)
- Gestor: «Enviar enllaç confirmació» (WhatsApp) des del registre mensual

**Pendent:** validació manual E2E — checklist [`ep8-smoke-checklist.md`](./ep8-smoke-checklist.md). Fins que no passi en local/staging, A6b es considera **no certificat** en producció.

**L2 (signatura):** no al portal com a clic simple; redirigeix al flux DMS existent (A7).

### A6c — Confirmació per període (mensual / setmanal) — ❌ pla separat

Avui la confirmació empleat és **1 per mes natural** (`attendance_monthly_reports` + `confirm_attendance_month`). El pla [`plan-period-employee-confirm.md`](./plan-period-employee-confirm.md) defineix:

- Validació estricta `PERIOD_NOT_ENDED` (només confirmar després que `period_to` ha passat).
- Nova taula `attendance_period_confirmations` + setting `attendance_employee_confirm_cycle` (`calendar_month` | `iso_week`).
- UI «Registre» al portal (vistes mensual/setmanal) i paritat tenant-portal.
- Audit/Activitat amb `period_from`/`period_to`; tancament gestor segons cobertura de períodes.

**No implementat** — veure fases 0–5 al pla dedicat.

## A7. Signatura DMS + validació A2 — ✅

- **Backend:** `api.validate_attendance_month_employee_confirm` (filtre A2 per confirmació empleat); `confirm_attendance_month` rebutja si `month_not_confirmable`; `link_attendance_monthly_report_signing` exigeix `manager_approved` + `validate_attendance_month_close` abans d'enllaçar.
- **Frontend:** panell validació empleat, modal confirmació amb bloquejos, botó desactivat; `MonthlyReportSigningSection` desactiva «Iniciar signatura» si hi ha bloquejos A2.
- **Migració:** `20260814000001_employee_confirm_validation_and_signing_a7.sql`

## A8 — Docs 3 capes (doc 15) — ✅ P3, S

**Àmbit:** només documentació (no codi). Ampliar [`15-time-attendance-architecture.md`](../../product-design/15-time-attendance-architecture.md) §15.9 amb la terminologia de les **3 capes** (A1):

| Capa | Taula | UI |
|------|-------|-----|
| Jornada | `time_entries` | `AttendanceLayerStatusBadge` — jornada |
| Dia nòmina | `time_daily_summaries` | estat dia (draft / approved / exported) |
| Mes legal | `attendance_monthly_reports` | registre mensual (confirmat / tancat / signat) |

**Fet (2026-07-09):** §15.9 ampliat — taula 3 capes, transicions, mapa UI, confusions habituals, fluxos dia/mes.

**Independent d'A6/EP8** (portal públic).

---

# TRACK B — Vista nòmina del gestor

## Problema

A `/employees/<uid>?tab=timesheet` el manager **només veu dades** (calendari + registre mensual passiu).

A `/attendance-mgmt/records` (**Fitxatges de l'equip**) només apareixen files de `time_daily_summaries` — **dies sense fitxatge desapareixen**, però poden ser laborables amb absència, IT o falta de fitxatge.

## B1. Deep link timesheet → Fitxatges de l'equip — ✅ P0, S

Des del registre mensual / timesheet empleat:

```
/attendance-mgmt/records?employeeId=<uid>&from=YYYY-MM-01&to=YYYY-MM-DD
```

- Botó: **«Revisar i aprovar dies del mes»**
- `AllTimeEntriesPage` llegeix query params (ja té filtres empleat + dates).

---

## B2. Vista «període de nòmina» unificada — ✅ P0, L

RPC: `api.get_payroll_review_days(employee_id, from, to)` — cada dia del període amb horari, fitxatges, absències/IT i `payroll_action`.

**UI:** `AllTimeEntriesPage` mostra `PayrollReviewDaysTable` quan es filtra per un empleat (deep link B1). Vista multi-empleat conserva la taula de summaries.

**Migració:** `20260815000001_payroll_review_days_b2.sql`

| Camp | Font |
|------|------|
| `work_date`, `day_type`, `expected_minutes` | `resolve_work_day` / summary |
| `worked_minutes`, `entry_status` | `time_entries` |
| `summary_status`, `needs_review`, `anomalies` | `time_daily_summaries` |
| `absence_type`, `absence_status`, `is_paid`, `partial_*` | `employee_absences` |
| `is_it`, `it_type` | `tenant_absence_type_configs` |
| `overtime_minutes` | summary |
| `remote_punch_count` | agregat punches |
| `payroll_action` | `approve` \| `absence_ok` \| `missing_punch` \| `blocked` |

**Criteri:** un gestor veu el mes sencer, no només dies amb punches. ✅

---

## B3. Accions des de la fila del dia — ✅ P1, M

Des del detall dia o fila:

- Aprovar dia (`approve_time_day`) — botó per fila a `PayrollReviewDaysTable`
- Obrir ajust (`adjust_time_entry`) — obre detall amb secció d'ajust desplegada
- Enllaç absència / registrar IT (→ C2) — diàlegs des de la fila
- Marcar «falta fitxatge justificada» (futur: vincula a absència o incidència E5)

**UI:** `PayrollReviewDayActions` integrat a Fitxatges equip quan es filtra per empleat.

---

## B4. Timesheet empleat: barra d'accions manager — ✅ P1, S

A `EmployeeTimesheetTab` (variant manager):

- Enllaç B1
- Resum blockers del mes (`validate_attendance_month_close`)
- Accés ràpid «Registrar IT» / «Nova absència» (C2)
- Panel tancament mensual (Track A) al final

**UI:** `TimesheetManagerActionBar` a la fitxa empleat (pestanya Timesheet, manager); `MonthlyAttendanceReportPanel` al final en vista mes.

---

## B5. Calendari timesheet: absències i IT — ✅ P1, M

`fetchEmployeeTimesheetDays` consumeix `get_payroll_review_days` (B2) i fusiona calendari, absències/IT i faltes de registre.

**UI:** `EmployeeTimesheetTab` — colors per tipus (IT, absència, festiu, falta registre), llegenda, subtítols al calendari setmana/mes i columnes extra a la llista.

---

# TRACK C — Absències, IT i taxonomia

## Què tenim avui (`tenant_absence_type_configs` seeds)

| Clau sistema | Cobertura PayFit aproximada |
|--------------|----------------------------|
| `vacation` | Vacaciones |
| `personal_days` | Asunto personal (genèric) |
| `bereavement` | Fallecimiento familiar (sense grau) |
| `marriage` | Permiso por matrimonio |
| `family_hospitalization` | Hospitalización familiar |
| `family_emergency` | Urgencias familiares |
| `partial_medical_personal` | Visita médica |
| `partial_medical_company` | Revisión médica empresa |
| `it_common`, `it_work_accident`, `it_maternity`, `it_parental`, `it_menstrual` | IT / cuidado hijos (parcial) |
| `reduced_hours` | Reducción jornada / lactancia acumulada (parcial) |

## Gaps rellevants (no cal copiar PayFit, cal cobrir nòmina)

| Concepte nòmina | Estat | Notes |
|----------------|-------|-------|
| **Compensación días trabajados** | ❌ | Banc d'hores / dies a favor |
| **Descanso por horas extras** | ⚠️ | `overtime_minutes` al summary; sense tipus absència ni consum |
| **Descanso por festivo trabajado** | ❌ | Festiu treballat → descans compensatori |
| **Teletrabajo** (com a concepte exportable) | ⚠️ | `is_remote` al punch; no al export payroll |
| **Subtipus familiars** (grau consanguinitat) | ❌ | Tenim tipus genèric; falta `subtype` o jerarquia 2 nivells |
| **Huelga no remunerada** | ❌ | Tipus específic `unpaid_strike`? |
| **Permiso por formación / exámenes** | ⚠️ | Dins `personal_days` o tipus nous |
| **Justificant adjunt** | ⚠️ | `requires_document` al config; UI limitada |
| **IT des de fitxa empleat** | ❌ | Només `/attendance-mgmt/absences` global |

## C1. Taxonomia 2 nivells (tenant) — ✅ P2, L

Model proposat (sense copiar PayFit):

```
tenant_absence_type_configs
  + parent_key nullable     -- nivell 1: vacation | personal | family | permission | it | compensation
  + subtype_key nullable  -- nivell 2: opcional per tenant
  + export_code           -- codi per CSV/A3/Sage/PayFit connector
```

Migració suau: tipus actuals = nivell 1; subtipus opcionals per tenant.

**Implementat (`20260912000001`):** columnes `parent_key` / `subtype_key` / `export_code`; RPCs `save_absence_type_export_settings`, `create_absence_type_subtype`; camps a `export_payroll_period` i `get_payroll_review_days`; UI `/settings/attendance-control` → «Tipus d’absència i codis export». **Ajuda usuari:** [`docs/help/horaris/tipus-absencia-export-nomina.md`](../../help/horaris/tipus-absencia-export-nomina.md).

## C2. IT i absències des de fitxa empleat — ✅ P1, M

**UI:** `EmployeeAbsencesPanel` a la pestanya **Timesheet** de la fitxa empleat (només gestor):

- **Registrar IT** — diàleg reutilitzat (`register_it` RPC)
- **Nova absència** — `RequestAbsenceDialog` en mode gestor (`request_absence`, pot auto-aprovar)
- Llista d'absències/IT de l'empleat amb aprovar/rebutjar/tancar IT
- Enllaç a `/attendance-mgmt/absences?employeeId=…`

Components compartits extrets de `AbsencesPage` (`RegisterITDialog`, `CloseITDialog`, `EmployeeAbsenceRow`).

## C3. Compensacions i banc d'hores — P2, L

Taula `time_compensation_ledger` (esborrany):

- `employee_id`, `source_date`, `type` (`overtime`, `holiday_worked`, `manual`)
- `minutes_credit` / `minutes_debit`
- Enllaç a dia que consumeix el descans

Export payroll ha d'incloure saldo del període.

## C4. Hores extra — ✅ P1, M

- `overtime_minutes` al summary i export CSV (D2).
- **UI B2:** barra resum violeta, fila destacada, badge «Extra declarades», columna extra en negreta.
- **UI timesheet empleat:** total extra al període + subtítol per dia.
- **Detall dia:** fila extres ressaltada si hi ha minuts o `OVERTIME_CLAIMED`.
- **Config tenant:** `/settings/attendance-control` → «Hores extra» (`attendance_overtime_policy`: `approval_required` | `auto_if_allowed`).
- **Fitxar (E5):** «He fet hores extra» + sortida en dia sense horari (`no_schedule_work`).

---

# TRACK D — Export nòmina (A3, Sage, integradors)

## Estat actual al codi

| Mecanisme | Què exporta | UI | A3/Sage |
|-----------|-------------|-----|---------|
| `export_payroll_days` | Dies `approved`: worked, overtime, day_type, punch_count | ❌ | ❌ |
| `export_attendance_month` | JSON dies amb `time_entries` | ✅ parcial | ❌ |
| `export_attendance_inspection` | Lectura legal RD 8/2019 | ✅ | ❌ |
| Doc 17 | CSV genèric + **spike A3/Sage** | ❌ | ❌ planificat |

**Resposta honesta:** avui **no tenim** export A3 ni Sage. Tenim la base RPC (`export_payroll_days`) amb camps mínims i informe mensual JSON. Cal D2–D3.

## D1. Matriu de dades que demana un gestor de nòmina

Per empleat i període (normalment mes):

| Bloc | Camps | Font |
|------|-------|------|
| **Presència** | Dies treballats, hores ordinàries, hores nocturnes (futur) | entries + summaries |
| **Absències retribuïdes** | Dies/hores per tipus | absences `is_paid` / `counts_as_worked` |
| **Absències no retribuïdes** | Dies per tipus | absences |
| **IT** | Dies IT per tipus; data inici/fi | absences `is_it` |
| **Hores extra** | Minuts extra; compensades o pendents | summary + ledger C3 |
| **Festius treballats** | Dies; dret a compensació | anomaly + ledger |
| **Teletreball** | Dies (opcional conveni) | punches `is_remote` |
| **Ajustos** | Motiu, qui, quan | `adjust_time_entry` audit |
| **Estat aprovació** | Per dia i mes | summaries + monthly_reports |

## D2. Export CSV nòmina genèric — ✅ P1, M

RPC `api.export_payroll_period(p_site_id, from, to, p_employee_id?, format?)`:

- Una fila per empleat × dia (model B2) amb camps de presència, absències, IT, overtime i estat.
- Opció agregat per empleat (totals mes).
- No marca `exported` fins acció explícita «Traspassar a nòmina» (UI futura sobre `export_payroll_days`).

**UI:** `PayrollExportButton` a Fitxatges de l'equip i al panel de registre mensual.

## D3. Connectors A3 / Sage — ✅ D3.1 (spike ✅ · perfils export ✅)

**Spike:** [`spike-d3-a3-sage-payroll-export.md`](./spike-d3-a3-sage-payroll-export.md)

**Conclusió spike:** no hi ha CSV universal A3/Sage; cal **perfils de mapping** per tenant (plantilles Excel/CSV cap a conceptes variables). Integració API WK (Conectia) = fase D3.2 — **posposada** fins validació E2E.

- Spike format (Wolters Kluwer A3 nómina, Sage 200/Despacho) — ✅
- Esquema `payroll_export_profiles` + tipus `payrollConnectorTypes.ts` — ✅
- **D3.1:** migració + RPC `export_payroll_period_profile` + UI perfils — ✅
- **D3.2:** API a3innuva Nómina Conectia (WK) — ⏸️ **posposat** (veure criteris a sota)
- Fora del core: integració via Holded / gestoria o fitxer pla (D4)

### D3.2 — Conectia WK (posposat)

**Estat:** no s’inicia implementació de producció fins poder **validar el funcionament final** amb un entorn real.

**Bloqueig:** WK exigeix [suscripción Conectia + accés a3innuva Nómina amb WKA + Client OAuth per client](https://a3developers.wolterskluwer.es/doc/a3innuva-n%C3%B3mina/como-empezar/). Sense tenant pilot o demo assignat per WK, només es poden fer mocks/contract tests; no es pot certificar que les incidències arribin a nòmina.

**Camí actual per clients A3:** D3.1 (CSV/perfils) + C1 (`export_code`) → importació manual o via gestoria.

**Condició de desbloqueig (qualsevol):**

1. Client pilot amb Conectia + nómina WK disposat a provar E2E, o
2. Entorn demo / credencials partner que WK assigni al programa Conectia.

**Abans de reprendre D3.2:** prova mínima documentada (OAuth → `GET companies` → enviar 1 incidència/variable → verificar a UI a3innuva).

## D4. PayFit / altres SaaS — P3, opcional

- No replicar taxonomia; exposar `export_code` per tipus absència (C1).
- Webhook o CSV segons partner.

---

# TRACK E — Fitxatge intel·ligent (`/attendance`)

Objectiu: reduir càrrega administrativa; l'empleat aporta context al fitxar.

## E1. Geo: text mentre es localitza — P0, XS

Quan `isLocating === true` a `PunchPage`: text muted «Obtenint ubicació…» (ja hi ha `isLocating` a `useRecordPunch`; verificar que es mostra sempre).

## E2. Horari del dia i propers dies laborables — ✅ P0, S

**Fet** (`PunchDaySchedule`, `useMyPunchSchedule`):

- Horari d'avui **sempre visible** abans del primer fitxatge.
- Propers dies (demà + proper laborable amb intervals) quan sortida registrada **o** fi de torn (30 min abans / després) sense requerir sortida.

## E3. Consentiment geo un cop per dispositiu — ✅ P1, S

- `localStorage` clau `attendance_geo_notice_v1_<tenantId>` després d'acceptar/declinar.
- Modal només primera vegada per dispositiu; text clar: l'empresa ho sap, pot exigir geo, justificació.
- RPC `give_location_consent` conserva consentiment empleat (GDPR).

**UI:** `geoNoticeStorage.ts` + `LocationConsentDialog` + flux a `PunchPage`.

## E4. Cascada «registrar geo» — ✅ P1, M

| Nivell | Camp | Fallback | On configurar (UI) |
|--------|------|----------|-------------------|
| Empleat | `employees.attendance_geo_enabled` | null → següent | Fitxa empleat → Informació |
| Departament | `departments.attendance_geo_enabled` | null → següent | Departaments → editar departament |
| Grup calendari | `calendar_groups.attendance_geo_enabled` | null → següent | Planificació → Grups de calendari |
| Tenant | `attendance_geo_enabled` o `attendance_location_consent_required` | default false | Configuració → Geolocalització al fitxar |

Si `enabled = false` a la cascada: **no es desa** geo al punch (client + `record_time_punch`).

**Backend:** `20260817000001_attendance_geo_cascade_e4.sql` — `resolve_attendance_geo_enabled`, `get_attendance_geo_enabled`.

**UI:** `AttendanceGeoEnabledField` (Heretar / Registrar / No registrar) + `AttendanceGeoSettingsSection` (tenant) + `useAttendanceGeoEnabled` al fitxar.

## E5. Autocorrecció al fitxar (incidències) — ✅ P2, L

Diàleg **post-fitxatge** (in/out online) quan hi ha incidència detectada:

| Opció empleat | Efecte |
|---------------|--------|
| Tot correcte | Registre a `attendance_punch_discrepancies` |
| No guardar ubicació | Anonimitza geo del punch (`employee_anonymize_punch_geo`) |
| He fet hores extra | `OVERTIME_CLAIMED` + `needs_review` al dia |
| He fet l'horari previst | `SCHEDULE_HOURS_CLAIMED` + `needs_review` al dia |

**Detecció:** client (fora d'horari ±marge configurable, sortida tardana, geo imprecisa) + anomalies servidor (`HIGH_UNCERTAINTY`, geofence).

**Config tenant:** `/settings/attendance-control` → «Incidències al fitxar» — marge 15/30/45/60 min (`attendance_punch_discrepancy_tolerance_minutes`).

**UI gestor:** detall de dia mostra «Declaració de l'empleat» + icona d'ajuda a anomalies E5.

**Backend:** `20260819000001_attendance_punch_discrepancy_e5.sql` — taula `attendance_punch_discrepancies`, RPC `submit_punch_discrepancy`.

**UI:** `PunchDiscrepancyDialog` + flux a `PunchPage` via `onPunchRecorded`.

## E6. Auto-assistència aprovació — ✅ P2, M

Si l'empleat declara «horari previst real» (`scheduled_hours_claimed` / `SCHEDULE_HOURS_CLAIMED`) i el tenant té **política de confiança** activa:

- El gestor veu **aprovació ràpida recomanada** al detall del dia i a la vista de revisió nòmina (B2).
- Criteris: només anomalia `SCHEDULE_HOURS_CLAIMED`, jornada tancada, hores treballades ≈ previstes (dins el marge E5), sense altres incidències bloquejants.
- `approve_time_day` neteja `needs_review` en aprovar.

**Config tenant:** `/settings/attendance-control` → «Incidències al fitxar» → «Confiar en horari previst real».

**Backend:** `20260821000001_attendance_trust_schedule_hours_e6.sql` — setting `attendance_trust_schedule_hours_claim`.

**UI:** `DayDetailApprovalSection` (banner verd), `PayrollReviewDayActions` / `PayrollReviewBulkApproveBar`, badge «Confiança» a la taula B2.

---

# TRACK F — Post-tancament

## F1. Esmenes / rectificacions — ✅ P2

`attendance_monthly_report_amendments` + RPCs `list_attendance_month_amendments` / `register_attendance_month_amendment` + Activitat (`ATTENDANCE_MONTH_AMENDMENT_REGISTERED`). Només després de `manager_approved` / `signed` / `archived`. No reobre nòmina a facturació externa.

**UI:** `MonthlyReportAmendmentsSection` al registre mensual (gestor pot registrar; empleat pot llegir).

## F2. Refacturació

Fora d'abast control horari → app facturació.

---

# Mapa de fases (implementació curta)

Cada fase = 1 PR revisable. **No saltar B2 abans de tancar mes en producció.**

| Llegenda | |
|----------|---|
| ✅ | Fet i usable |
| ⚠️ | Parcial |
| — | Pendent |

| ID | Entregable | P | Esforç | Estat |
|----|------------|---|--------|-------|
| **A1** | i18n + columnes estat al registre mensual | P0 | S | ⚠️ i18n + badges; falta 2ª columna al registre mensual |
| **B1** | Query params + botó «Revisar dies del mes» | P0 | S | ✅ |
| **E1** | Text geo localitzant | P0 | XS | ✅ |
| **E2** | Horari visible sempre + propers dies | P0 | S | ✅ |
| **A2** | `validate_attendance_month_close` + guards RPC | P0 | M | ✅ |
| **A3** | Modals + eliminar «Registrar confirmació» | P0 | M | ✅ |
| **A7** | Signatura DMS + validació A2 (+ confirmació empleat) | P0 | M | ✅ |
| **B2** | `get_payroll_review_days` + taula unificada | P0 | L | ✅ |
| **B5** | Calendari timesheet amb absències/IT | P1 | M | ✅ |
| **C2** | IT/absència des de fitxa empleat | P1 | M | ✅ |
| **B4** | Barra accions manager al timesheet | P1 | S | ✅ |
| **A5** | Audit mensual → Activitat | P1 | M | ✅ |
| **A4** | Settings flux tenant | P1 | M | ✅ |
| **C4** | UI hores extra al revisar mes | P1 | M | ✅ |
| **D2** | Export CSV nòmina ampliat | P1 | M | ✅ |
| **E3** | Consentiment geo per dispositiu | P1 | S | ✅ |
| **E4** | Cascada geo enabled (+ UI dept/grup/tenant) | P1 | M | ✅ |
| **B3** | Accions per fila (aprovar, IT, ajust) | P1 | M | ✅ |
| **C1** | Taxonomia 2 nivells + export_code | P2 | L | ✅ `20260912000001` |
| **C3** | Banc compensacions | P2 | L | — |
| **E5** | Incidències autocorrecció al fitxar | P2 | L | ✅ |
| **E6** | Suggeriment auto-aprovació | P2 | M | ✅ |
| **D3** | Spike + mapping A3/Sage (perfils CSV) | P3 | L | ✅ D3.1 perfils export |
| **D3.2** | API a3innuva Conectia (WK) | P3 | L | ⏸️ Posposat — validació E2E |
| **F1** | Esmenes post-tancament | P2 | M | ✅ `20260916000001` |
| **A6a** | Confirmació/signatura app (`MyRecordPage` Mes) | P2 | L | ✅ |
| **A6b** | Portal públic EP8 L1 (`/e/{token}` → `/portal/monthly`) | P2 | M | ⚠️ codi ✅; [smoke EP8](./ep8-smoke-checklist.md) pendent |
| **A8** | Documentar 3 capes (doc 15 §15.9) | P3 | S | ✅ |

### Següent (ordre suggerit)

1. **B5** — Absències/IT al calendari timesheet (fusionar dades a `fetchEmployeeTimesheetDays` o consumir B2).
2. **C2** — Registrar IT/absència des de fitxa empleat (complementa B3). ✅
3. **B3** — Accions per fila (aprovar, IT, ajust). ✅
4. En paral·lel: **A1** (2ª columna), **A6b** ([smoke EP8](./ep8-smoke-checklist.md)).

### Graella de dependències

```
A1 ─┬─ B1 ─ B2 ─ B3
    ├─ A2 ─ A3 ─ A7
    └─ E2

B2 ─ C2, C4, D2
B5 ─ B2
A3 ─ A5
A7 ─ signing (DMS)
```

---

# Criteris d'acceptació globals

- [x] No es tanca mes futur ni amb jornades obertes (A2 + confirmació empleat + signatura A7).
- [x] Gestor veu **tot el mes** (fitxatges, absències, IT, festius, faltes) → **B2** (per empleat a Fitxatges de l'equip).
- [x] Salt timesheet empleat → Fitxatges de l'equip amb filtres (B1).
- [x] IT registrable des de fitxa empleat → **C2**.
- [x] Export CSV inclou absències, IT, overtime (no només punches) → **D2**.
- [x] A3/Sage: spike D3 + **D3.1 perfils export** — [`spike-d3-a3-sage-payroll-export.md`](./spike-d3-a3-sage-payroll-export.md); migració `20260822000001_payroll_export_profiles_d3.sql`.
- [x] Terminologia coherents en català (3 capes) — i18n + doc 15 §15.9 + columnes jornada/dia nòmina ✅ (A1, A8).
- [x] Accions de tancament amb modal i Activitat (A3, A5).
- [x] Fitxar: horari visible, geo amb consentiment per dispositiu, cascada opt-in geo → **E2–E4**.

---

#Referències

- [`STATUS.md`](./STATUS.md)
- [`plan-employee-portal.md`](./plan-employee-portal.md) (EP8 · A6b)
- [`plan-period-employee-confirm.md`](./plan-period-employee-confirm.md) (A6c · confirmació per període)
- [`ep8-smoke-checklist.md`](./ep8-smoke-checklist.md)
- [`15-time-attendance-architecture.md`](../../product-design/15-time-attendance-architecture.md)
- [`17-time-attendance-implementation-plan.md`](../../product-design/17-time-attendance-implementation-plan.md) § export A3/Sage
- [`20260728000005_attendance_v3_absences_refinement.sql`](../../../supabase/migrations/20260728000005_attendance_v3_absences_refinement.sql)
- [`export_payroll_days`](../../../supabase/migrations/20260515000018_attendance_core.sql) — export actual mínim
