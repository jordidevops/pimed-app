# Control Horari v3 - Pla d'enduriment i evolució

> **Estat d'implementació:** [`STATUS.md`](./STATUS.md) (font de veritat)  
> **Nòmina, tancament mensual, export i fitxatge UX:** [`plan-monthly-close-approval.md`](./plan-monthly-close-approval.md) — **no duplicar aquí**  
> **Runbook cua:** [`runbook-attendance-queue.md`](./runbook-attendance-queue.md)  
> **Disseny base:** docs [`14`](../../product-design/14-time-attendance-overview.md)–[`17`](../../product-design/17-time-attendance-implementation-plan.md)  
> **Integració projectes (`work_logs`):** [`prompts/shared/work-logs-time-attendance-integration.md`](../../../prompts/shared/work-logs-time-attendance-integration.md) · [`prompts/projectes/plan.md`](../../../prompts/projectes/plan.md) §7 · Track G [`plan-effective-work-time.md`](./plan-effective-work-time.md) §18.9

## Objectiu

Passar del sistema actual (funcional però amb latència asíncrona i UX fragmentada) a un sistema de control horari **robust legalment, escalable per milers d'usuaris** i clar en operativa diària per a treballadors i managers.

Aquest pla prioritza **integritat + capacitat + compliment legal** abans d'ampliar UI.

## Condició de disseny frontend

Tot el frontend nou o modificat ha d'usar **controls de `shadcn/ui`** (Button, Select, Dialog, Tabs, Sheet, Badge, Table, Calendar wrappers, Form primitives).  
No s'han d'introduir llibreries de components paral·leles per a aquestes pantalles.

---

## Revisió crítica de l'estat actual

1. La pipeline de recompute (`attendance_recompute_queue`) és un cron cada minut amb batch petit (`invoke_attendance_queue_worker(20)`), insuficient per pics massius.
2. `time_punches` (raw) entra ràpid, però `time_entries/time_daily_summaries` poden tardar; l'usuari veu inconsistències temporals.
3. L'àmbit UI (fitxatge, absències, planificació) està partit en rutes disperses i amb semàntica poc clara.
4. Falten funcionalitats clau: pauses tipificades, teletreball, entitlements vacances/permisos.
5. Sense SLO/observabilitat explícita no es pot garantir disponibilitat telemàtica "temps real" de cara a inspecció.
6. Cap disseny de geolocalització (GDPR, consentiment, retenció).
7. La màquina d'estats de pausa no cobreix crash/tancament d'app.
8. Sense flux d'aprovació de registres ni de sol·licitud d'absències lligat als entitlements.
9. `get_today_site_status` RPC on-the-fly no escalarà amb molts sites.

---

## Principis obligatoris

- **Raw immutable primer**: cap càlcul ni ajust no sobreescriu `time_punches`.
- **Idempotència end-to-end**: client op_id + claus deterministes de recompute.
- **Degradació controlada**: si recompute va amb retard, el frontend mostra estat consistent basat en raw.
- **Escalabilitat per pics**: disseny per pics d'entrada/sortida (10-20 min concentrats), no per mitjanes.
- **Traçabilitat legal**: qui/quan/perquè de qualsevol canvi manual; registres 4 anys mínim.

---

## Fase 0 - Capacitat, SLO i observabilitat

**Gate obligatori**: sense complir els SLOs mínims no es passa a noves funcionalitats UI.

### 0.1 SLOs i objectius de rendiment

| Indicador | Objectiu |
|-----------|---------|
| `record_time_punch` p95 | < 400 ms (sense geolocalització bloquejant) |
| Visibilitat al "meu historial" | < 2 s (amb fallback raw) |
| Recomputa diària p95 | < 30 s en condicions normals |
| Frescor tauler managers | < 60 s |
| Export mensual empleat | < 5 s per empleat |

### 0.2 Model de càrrega

Simular 1k, 5k i 10k usuaris amb pics concentrats de 10–20 min (entrada/sortida/pauses). Mesurar: backlog cua, temps mig per missatge, percentils de latència RPC, errors i DLQ.

### 0.3 Hardening pipeline asíncrona

- Batch adaptatiu 10–50 segons `pgmq.metrics` (`data.attendance_recompute_batch_size`).
- Catch-up: fins a 10 batches per invocació (`data.attendance_recompute_max_batches`).
- Cron: `invoke_attendance_queue_worker()` cada minut (sense batch fixe).
- Migració: `20260806000001_attendance_queue_capacity.sql`.

### 0.4 Observabilitat

- RPC `api.get_attendance_queue_health()` — profunditat cua, DLQ, cron, lots recents.
- Dashboard operatiu: consultar health RPC o `pgmq.metrics` (UI admin pendent).
- Alertes: camps `alert_backlog`, `alert_stale_sec`, `alert_dlq` al health JSON.
- Runbook operatiu: [`runbook-attendance-queue.md`](./runbook-attendance-queue.md).

### 0.5 Proves de càrrega

Script: `supabase/tests/attendance_load_test.ts` (wrapper PowerShell `run_attendance_load_test.ps1`).

```powershell
.\supabase\tests\run_attendance_load_test.ps1 -Users 100 -Concurrency 25
npx tsx supabase/tests/attendance_load_test.ts --users 1000 --concurrency 50
```

---

## Fase 0b - Compliment legal explícit (RD 8/2019)

### Requisits normatius concrets

El RD 8/2019 (España) exigeix:
- Registre d'hora d'inici i fi de jornada per a cada empleat, cada dia.
- Accés telemàtic en temps real per a la Inspecció de Treball.
- Conservació mínima de **4 anys**.
- Lliurament en format llegible (PDF/Excel) per a cada empleat sota petició.

### 0b.1 Política de retenció ✅ EX-09.1

- Retenció mínima legal **4 anys** (RD 8/2019); per defecte **no s'esborra res**.
- Opt-in tenant: `attendance_retention_purge_enabled` + `attendance_retention_years` (≥4).
- Purge batched via `data.purge_attendance_older_than_batch` + cron `attendance-retention-purge` (sense botó manual).
- Bypass immutability només amb GUC `app.allow_attendance_purge=on` dins SECURITY DEFINER.
- Detall: [`plan-attendance-legal-access.md`](./plan-attendance-legal-access.md).

### 0b.2 Exportació legal mensual per empleat

Nova RPC: `api.export_attendance_month(employee_id, year, month)` que retorna:
- Cada dia: data, hora entrada, hora sortida, pauses detallades, minuts nets.
- Resum mensual: dies treballats, hores previstes, hores fetes, diferència.
- Format de sortida: JSON estructurat per generar PDF/Excel al frontend o via Edge Function.

### 0b.3 Signatura digital del registre mensual ✅

Integrat amb el mòdul de documents/signing:

1. Plantilla de plataforma **«Registre mensual de jornada»** (`attendance`, HTML) — migració `20260808000001`.
2. Després d'aprovar el mes (`manager_approved`), el manager inicia signatura seqüencial (empleat → responsable) via `sign-document-router`.
3. `api.link_attendance_monthly_report_signing` enllaça `document_id` + `signing_submission_id`.
4. Trigger a `signing_submissions`: quan `status = completed` → `attendance_monthly_reports.status = signed`.
5. UI: `MonthlyReportSigningSection` dins `MonthlyAttendanceReportPanel` (manager + empleat veuen seguiment).

Pendent opcional: PDF/Excel directe sense signatura; automatització `MONTH_CLOSED_REPORT` (Fase 6).

**Següent pas:** [`plan-monthly-close-approval.md`](./plan-monthly-close-approval.md) v2 — Tracks A (tancament), B (vista nòmina gestor), C (absències/IT), D (export A3/Sage), E (fitxatge).

### 0b.4 Accés telemàtic per a inspecció ✅ EX-09.2

- Enllaç opac amb caducitat (empleat + període ≤400 dies); TTL default 7d / max 30d.
- Secret SHA-256; URL pública `/inspect/[id]` + cookie HttpOnly després del primer hit.
- Edge `inspect-api` (service_role); email plantilla `attendance.inspection_access`.
- Audit `ATTENDANCE_INSPECTION_LINK_*` amb actor simbòlic `inspection_authority`.
- Detall: [`plan-attendance-legal-access.md`](./plan-attendance-legal-access.md).

---

## Fase 1 - Evolució DB

### 1.1 `time_punches` — camps nous

```sql
ALTER TABLE data.time_punches
  ADD COLUMN pause_type           text    NULL,  -- només en break_start/break_end
  ADD COLUMN pause_counts_as_work boolean NULL,  -- snapshot del moment; crític per canvis de política
  ADD COLUMN is_remote            boolean NOT NULL DEFAULT false,
  ADD COLUMN geo_lat              numeric(10,7) NULL,
  ADD COLUMN geo_lng              numeric(10,7) NULL,
  ADD COLUMN geo_accuracy_m       real    NULL,
  ADD COLUMN geo_altitude_m       real    NULL,
  ADD COLUMN geo_speed_ms         real    NULL,
  ADD COLUMN geo_consent          boolean NOT NULL DEFAULT false,  -- GDPR: va consentir en aquell moment
  ADD COLUMN device_info          jsonb   NULL;  -- user_agent, ip, plataforma
```

**Per a anonimització GDPR**: funció `api.anonymize_punch_geo(punch_id)` que posa lat/lng a NULL i registra data d'anonimització. Política configurable per tenant: anonimitzar geo passats X mesos.

### 1.2 Geolocalització — disseny GDPR

**Disseny obligatori abans d'implementar**:
- Camp `location_consent_required boolean` a `tenant_settings` (default false).
- Camp `location_consent_given boolean` a `employees`, amb data de consentiment i versió del text.
- El consentiment s'ha de donar de forma explícita i registrada; no n'hi ha prou amb acceptar TOS.
- La recollida de geo és **puntual** (moment del punch), mai contínua.
- La geolocalització **no bloqueja** el fitxatge: timeout de 3s, si falla s'enregistra l'error però el punch continua.
- Camp `geo_error text NULL` per registrar errors de geolocalització sense trencar el flux.
- Anonimització programada via `pg_cron`: `SELECT api.anonymize_old_punch_geo(months := 24)`.

### 1.3 Configuració pauses tenant

Nova taula `tenant_pause_configs`:
- `key text` (`lunch`, `rest`, `medical`, o custom),
- `label_i18n jsonb`,
- `counts_as_work boolean NOT NULL`,
- `max_duration_minutes int NULL` (timeout automàtic; vegeu Fase 2.1),
- `is_active boolean`, `sort_order int`.

RPC: `api.list_pause_configs`, `api.upsert_pause_config` (manager/owner).

### 1.4 Entitlements vacances/permisos

Nova taula `vacation_entitlements`:
- `scope` + claus de cascada: tenant → departament → empleat.
- `leave_type` (vacation, parental, medical, custom).
- `days_allocated`, `days_used` (calculat via trigger/RPC).

**Nota SQL crítica**: usar `CREATE UNIQUE INDEX` sobre expressions, mai `UNIQUE (col1, COALESCE(col2, uuid))` inline.

RPC:
- `api.get_vacation_entitlement(employee_id, year)` — resol cascada,
- `api.upsert_vacation_entitlement(...)`.

### 1.5 `attendance_absence_requests` — flux complet sol·licituds

Nova taula per al flux de sol·licitud d'absències:
```sql
CREATE TABLE data.attendance_absence_requests (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id     uuid NOT NULL REFERENCES data.employees,
  tenant_id       uuid NOT NULL,
  leave_type      text NOT NULL,               -- vacation, medical, parental...
  starts_on       date NOT NULL,
  ends_on         date NOT NULL,
  days_requested  int  NOT NULL,               -- precalculat (dies laborables)
  comment         text,
  status          text NOT NULL DEFAULT 'pending',  -- pending/approved/rejected
  reviewed_by     uuid REFERENCES auth.users,
  reviewed_at     timestamptz,
  review_comment  text,
  entitlement_id  uuid REFERENCES data.vacation_entitlements,
  created_at      timestamptz NOT NULL DEFAULT now()
);
```

**Integrar amb `approval_requests`** quan el mòdul genèric estigui disponible, en lloc de construir un flux ad-hoc. El disseny d'aquesta taula ha de ser compatible per migrar a approval_requests.

Flux complet:
1. Empleat sol·licita (dies laborables fins als que li queden pendents).
2. Manager aprova o rebutja (notificació via sistema de notificacions).
3. Si s'aprova: decrement de `days_used` a `vacation_entitlements`.
4. Event al calendari del tenant.
5. Notificació a les dues parts.

### 1.6 `attendance_monthly_reports` (Fase 0b.3)

Ja descrita a Fase 0b.3.

### 1.7 Recompute worker

A `api.recompute_attendance_worker`:
- Excloure de `break_minutes` les pauses amb `pause_counts_as_work = true`.
- Mantenir compatibilitat amb registres antics sense camps nous.
- Detectar pauses obertes (sense `break_end`) i generar anomalia `PAUSE_NOT_CLOSED`.
- En finalitzar recompute, refrescar la vista materialitzada `data.mv_today_site_status` (vegeu Fase 4).

---

## Fase 2 - Frontend fitxatge personal (`/attendance`)

**Implementació amb controls `shadcn/ui`**: `Switch`, `Button`, `ButtonGroup`, `Badge`, `Alert`.

### 2.1 Màquina d'estats (completa, inclou crash)

```
outside → [PUNCH_IN] → working
working → [BREAK_START:<type>] → on_pause:<type>
working → [PUNCH_OUT] → outside
working → [SWITCH_WORK_LOG] → working   ← canvi de projecte; estat horari NO canvia (D-INT-6)
on_pause:<type> → [BREAK_END] → working
```

**Canvi de projecte (`mobile_peripatetic`):** la UI crida `api.switch_work_log` (stop work_log + gap + start nou). El `time_punch` legal **no** canvia d'estat (`working` es manté); només el `work_log` actiu canvia de `project_id`. Veure doc compartit D-INT-6.

**Pausa legal i `work_log` actiu (D-INT-8):** en processar `break_start` dins `api.record_time_punch`, **mateixa transacció**:

```sql
UPDATE data.work_logs
SET status = 'paused', updated_at = now()
WHERE worker_id = (SELECT user_id FROM data.employees WHERE id = p_employee_id)  -- mapping employee→profile
  AND tenant_id = p_tenant_id
  AND status = 'open'
  AND entry_mode = 'field_punch';
```

En `break_end`, operació inversa (`status = 'open'`). Si no hi ha `work_log` obert → cap error; comportament attendance normal. La durada de pausa **no** compta al `work_log` (interval `paused` exclòt del càlcul de durada).

**Cas crash/tancament d'app en pausa** (obligatori dissenyar ara):
- Si `break_start` sense `break_end` passat `max_duration_minutes` (de `tenant_pause_configs`): el worker de recompute detecta l'anomalia `PAUSE_NOT_CLOSED` i genera un registre d'anomalia.
- L'empleat veu: "Pausa sense tancar des de les 14:32" amb opció de tancar manualment.
- El manager veu l'anomalia al tauler.
- La resolució manual crea un ajust amb traçabilitat (qui, quan, motiu), sense alterar el raw punch.
- Si el tenant no defineix `max_duration_minutes`, s'aplica un default de 4h.

Regles addicionals:
- En pausa no es pot "Sortir" sense tancar pausa (o configuració explícita per permetre-ho).
- Cada acció genera op idempotent amb `op_id` de client.

### 2.2 Geolocalització al punch

- Demanar permís browser si `location_consent_required` per al tenant i `location_consent_given` per a l'empleat.
- Si l'empleat no ha donat consentiment, mostrar diàleg explicatiu (GDPR) i registrar resposta.
- Timeout de 3s, error registrat a `geo_error`, punch continua sempre.
- No demanar geo si l'empleat treballa des d'un context marcat com "oficina" (configuració futura).

### 2.3 Offline

Extendre `attendanceDb` (IndexedDB) amb:
- `pause_type`, `pause_counts_as_work`, `is_remote`, `geo_lat/lng/accuracy`, `geo_consent`, `device_info`.

Sincronització conserva ordre local i idempotència.

### 2.4 Historial personal robust

`/attendance/record`:
- Primer intenta `time_entries` (processades).
- Fallback temporal a raw punches resumits si no hi ha recompute.
- Marcar visualment "dada provisional" fins a consolidació.

---

## Fase 3 - Reestructuració navegació "Control Horari"

Rutes noves:
- `/control-horari` (layout)
- `/control-horari/tauler`
- `/control-horari/fitxatges`
- `/control-horari/empleats`
- `/control-horari/calendari`
- `/control-horari/planificacio`

Rutes antigues amb redirects client-side per compatibilitat.

**UI**: `shadcn/ui Tabs`, `Badge` (absències pendents), `Table`, `Dialog`, `Sheet`.

---

## Fase 4 - Tauler Control Horari (managers)

### Blocs

1. Estat avui (qui havia de fitxar, qui no, retard, pauses obertes).
2. Mapa de geolocalitzacions recents (Leaflet, ampliat en modal).
3. Mini calendari i accessos ràpids.
4. Incidències i pendents (absències, dies oberts, pauses no tancades).

### `get_today_site_status` com a vista materialitzada

**Decisió de disseny crítica**: NO implementar com a RPC on-the-fly. Amb 20 sites i polling cada 60s = 20 crides/minut per manager. No escala.

**Solució**: Vista materialitzada `data.mv_today_site_status`:
```sql
CREATE MATERIALIZED VIEW data.mv_today_site_status AS
  -- Agregació: per site, per empleat, estat actual, darrer punch, geo
  ...
WITH NO DATA;

CREATE UNIQUE INDEX ON data.mv_today_site_status (site_id, employee_id);
```

- Refrescada pel worker de recompute (`REFRESH MATERIALIZED VIEW CONCURRENTLY ...`) cada cop que processa punches nous.
- RPC `api.get_today_site_status(site_id)` fa `SELECT` sobre la vista, no càlcul.
- Si el worker tarda, la vista serveix dades lleugerament obsoletes (acceptable dins SLO de 60s).

---

## Fase 5 - Fitxatges, Empleats, Calendari, Planificació

### 5.1 Fitxatges — Consolidació i flux d'aprovació

- Vista operativa diària/setmanal/mensual.
- Detall raw vs processat (costat a costat).
- **Flux d'aprovació de registres** (obligatori per a compliment legal):
  1. Empleat revisa el registre del mes i el confirma (`status: employee_confirmed`).
  2. Manager l'aprova (`status: manager_approved`).
  3. Un cop aprovat, queda tancat; qualsevol ajust posterior requereix reobrir amb motiu.
  4. Integrar amb `approval_requests` genèric quan estigui disponible.
- Consolidació manual: crea un "ajust" sense alterar raw; traçabilitat completa.
- Exportació mensual per empleat (PDF/Excel) via `api.export_attendance_month`.

### 5.2 Empleats

- Resum anual/mensual, detall diari amb mapa i trail d'events.
- Vista any: total hores previstes vs fetes, dies vacances assignats/pendents.
- Exportació i impressió per mes.

### 5.3 Calendari

- Vista anual + mensual + setmanal.
- Selecció d'intervals per sol·licitar absències/permisos.
- Restriccions: només dies laborables configurables.
- Badge amb entitlements restants visibles.

### 5.4 Planificació

- Calendari cascada: tenant/site/departament/empleat.
- Entitlements vacances/permisos: CRUD amb cascada.
- Configuració pauses tipificades (inclou `max_duration_minutes`).
- Política de geolocalització per tenant (activar/desactivar, termini anonimització).

Tots els formularis i taules de la fase amb primitives `shadcn/ui`.

---

## Fase 6 - Integració motor d'automatitzacions

### Nous `trigger_event` a `automation_workflows`

| Trigger | Condició | Ús típic |
|---------|----------|----------|
| `PUNCH_IN_UNUSUAL_HOUR` | Punch fora de franja esperada | Notificació manager |
| `PUNCH_OUT_MISSING` | Fi del dia sense PUNCH_OUT | Recordatori a l'empleat |
| `OVERTIME_THRESHOLD_EXCEEDED` | Hores extras sobre llindar | Alerta a RRHH |
| `PAUSE_NOT_CLOSED` | Pausa >max_duration | Anomalia + notificació |
| `MONTH_CLOSED_REPORT` | Mes finalitzat | Generar registre mensual signat |
| `ABSENCE_REQUEST_PENDING` | Sol·licitud d'absència nova | Notificació manager |
| `PROJECT_SWITCH` | `api.switch_work_log` acceptat | Notificar manager (obra acabada, següent client) |
| `WORK_LOG_CLOSED` | `field_punch_stop` amb `day_end` o últim treball del dia | Workflows CRM / facturació |

### Implementació

- `record_time_punch` envia event a `automation_trigger_queue` al finalitzar (no bloquejant).
- `api.switch_work_log` i `api.field_punch_stop` envien `PROJECT_SWITCH` / `WORK_LOG_CLOSED` a `audit_log` (consumible pel motor d'automatitzacions).
- `process-attendance-queue` worker detecta condicions OVERTIME/PAUSE_NOT_CLOSED i envia events.
- `pg_cron` diari comprova PUNCH_OUT_MISSING al final de jornada esperada.
- `MONTH_CLOSED_REPORT` integra amb `generate-attendance-report` Edge Function → document signable.

Això converteix el control horari d'un sistema de registre passiu en un sistema proactiu, integrat naturalment amb el motor d'automatitzacions i notificacions existents.

---

## Riscos principals i mitigacions

| Risc | Mitigació |
|------|-----------|
| Backlog de recompute en pics | Fase 0 obligatòria + tuning + alertes |
| Divergència raw vs processat | Fallback visual i estats "provisional" |
| Canvi regles pausa en mig d'any | Snapshot `pause_counts_as_work` en cada punch |
| Complexitat calendari cascada | RPC única `resolve_work_day` + tests regressió |
| Geolocalització GDPR | `geo_consent` per punch + política tenant + anonimització programada |
| Crash en pausa | Timeout automàtic + anomalia `PAUSE_NOT_CLOSED` + resolució manual traçable |
| Compliment legal incomplet | Export mensual + signatura digital + retenció 4 anys |
| `get_today_site_status` lent | Vista materialitzada refrescada pel worker |
| Flux aprovació ad-hoc | Dissenyat compatible amb `approval_requests` genèric |

---

## Criteris d'acceptació per fase

| Fase | Criteri |
|------|---------|
| F0 | SLOs definits i complerts en proves de càrrega |
| F0b | Export mensual funcional, hash del document generat, política retenció documentada |
| F1 | Migracions aplicables, tests de compatibilitat en dades existents, flux absències end-to-end |
| F2 | Flux complet offline/online entrada/sortida/pausa/remote; cas crash cobert |
| F3 | Navegació unificada sense regressions de rutes antigues |
| F4 | Tauler amb dades fresques dins SLO via vista materialitzada |
| F5 | Operativa completa, flux aprovació registres, exportació legal |
| F6 | Mínim 3 triggers d'automatització operatius (PUNCH_OUT_MISSING, OVERTIME, MONTH_CLOSED) |

---

## Fitxers clau previstos

```
supabase/migrations/
  20260727000001_attendance_v2_core.sql           # time_punches camps, pause_configs, entitlements
  20260727000002_attendance_v2_absence_requests.sql
  20260727000003_attendance_v2_monthly_reports.sql
  20260727000004_attendance_v2_materialized_view.sql

supabase/functions/
  process-attendance-queue/index.ts               # worker + refresc vista materialitzada
  generate-attendance-report/index.ts             # PDF/Excel + hash signatura

apps/tenant-portal/src/features/attendance/
  pages/PunchPage.tsx                             # màquina d'estats completa + geo
  components/PunchButton.tsx
  components/PauseButtonGroup.tsx
  db/attendanceDb.ts                              # IndexedDB + camps nous
  pages/MyRecordPage.tsx                          # fallback raw
  pages/ControlHorariLayout.tsx                   # nou layout unificat
  pages/TaulerPage.tsx
  pages/FitxatgesPage.tsx
  pages/EmpleatsFitxatgesPage.tsx
  pages/CalendariPage.tsx
  pages/PlanificacioPage.tsx
  api/recordRows.ts                               # fallback punches → entries
```
