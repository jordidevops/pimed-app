# 16. Control horari - Model de dades Postgres orientatiu

Aquest document proposa l'estructura SQL del modul. No es una migracio final:
serveix com a contracte funcional i tecnic. **El schema real** viu a
`supabase/migrations/`; consultar [`STATUS.md`](../plans/checkin/STATUS.md) per
divergències respecte a aquest contracte inicial.

> **Actualitzat:** 2026-06-30 — extensions v2/v3, open questions resoltes.  
> **Calendari laboral (cascada):** [`docs/help/horaris/calendaris-laborals.md`](../help/horaris/calendaris-laborals.md)

---

## 16.1 Mapping JCM -> Postgres

| JCM | Postgres proposat |
|---|---|
| `punches/{uid}/logs/{timestamp}` | `data.time_punches` |
| IndexedDB `punchDB` | IndexedDB `attendance_ops` + `attendance_cache` |
| `Schedules` NORMAL/ESPECIAL | `data.work_schedules` + `data.work_schedule_intervals` |
| `Schedules` FIESTAS | `data.holiday_calendars` + `data.holidays` |
| `Schedules` VACACIONES | `data.employee_absences` |
| `Users.appData.horariosAsignados` | `data.employee_schedule_assignments` |
| Overrides puntuals de calendari | `data.labor_calendar_overrides` + `data.calendar_groups` |
| `WorkZones` | `data.locations` |
| `Devices` | `data.attendance_devices` |
| `UserZoneAssignments` | `data.attendance_location_assignments` |
| calcul local `calculateWorkedTime` | `data.time_entries` + `data.time_daily_summaries` |
| Planificació de torns | `data.work_shifts` + `data.shift_slots` + `data.shift_swap_requests` |
| Config pauses per conveni | `data.tenant_pause_configs` |
| Tipus d'absència per tenant | `data.tenant_absence_type_configs` |
| Saldo vacances/permisos | `data.vacation_entitlements` |
| Registre mensual legal | `data.attendance_monthly_reports` |

---

## 16.2 Entitats principals

### `data.employees`

Prerequisit per control horari i payroll.

```sql
CREATE TABLE data.employees (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id         uuid REFERENCES data.sites(id) ON DELETE SET NULL,
  user_id         uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  department_id   uuid REFERENCES data.departments(id) ON DELETE SET NULL,
  full_name       text NOT NULL,
  email           text,
  phone           text,
  document_id     text,
  job_title       text,
  status          text NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active','inactive','terminated')),
  starts_on       date,
  ends_on         date,
  weekly_hours    numeric(5,2),
  metadata        jsonb NOT NULL DEFAULT '{}',
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
```

Notes:

- `user_id` es opcional.
- Si un TenantMember pot fitxar, ha d'estar vinculat a un Employee.
- Payroll mai ha de dependre nomes de `auth.users`.

### `data.attendance_devices`

```sql
CREATE TABLE data.attendance_devices (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id               uuid NOT NULL REFERENCES data.sites(id) ON DELETE CASCADE,
  location_id           uuid REFERENCES data.locations(id) ON DELETE SET NULL,
  public_device_id      text NOT NULL,
  name                  text,
  kind                  text NOT NULL DEFAULT 'mobile'
                        CHECK (kind IN ('mobile','fixed_station','tablet','import')),
  status                text NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active','suspended','retired')),
  device_secret_hash    text,
  last_seen_at          timestamptz,
  last_user_id          uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  user_agent            text,
  metadata              jsonb NOT NULL DEFAULT '{}',
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, public_device_id)
);
```

`public_device_id` pot venir del navegador, pero no es una prova forta
d'identitat. Les estacions fixes han de tenir `device_secret_hash` o un mecanisme
equivalent.

### `data.attendance_location_assignments`

```sql
CREATE TABLE data.attendance_location_assignments (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id   uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  location_id   uuid NOT NULL REFERENCES data.locations(id) ON DELETE CASCADE,
  assigned_by   uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  starts_on     date NOT NULL DEFAULT current_date,
  ends_on       date,
  is_active     boolean NOT NULL DEFAULT true,
  notes         text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (employee_id, location_id, starts_on)
);
```

La herencia de zones es resol amb `data.locations.parent_id` i una funcio
recursiva tipus `data.employee_can_punch_at_location(employee_id, location_id)`.

---

## 16.3 Raw punches

### Enums

```sql
CREATE TYPE data.time_punch_direction AS ENUM ('in', 'out');
CREATE TYPE data.time_punch_source AS ENUM ('manual', 'station', 'qr', 'barcode', 'import', 'admin_adjustment');
CREATE TYPE data.time_punch_validation_status AS ENUM ('pending', 'valid', 'needs_review', 'rejected', 'voided');
```

### `data.time_punches`

```sql
CREATE TABLE data.time_punches (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id               uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id                 uuid NOT NULL REFERENCES data.sites(id) ON DELETE CASCADE,
  employee_id             uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  actor_user_id           uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  device_id               uuid REFERENCES data.attendance_devices(id) ON DELETE SET NULL,
  location_id             uuid REFERENCES data.locations(id) ON DELETE SET NULL,

  client_op_id            uuid NOT NULL,
  direction               data.time_punch_direction NOT NULL,
  -- v2: punch_type inclou 'in'|'out'|'break_start'|'break_end'
  source                  data.time_punch_source NOT NULL DEFAULT 'manual',
  punch_type              text NOT NULL DEFAULT 'normal',

  -- v2: pauses tipificades
  pause_type              text,              -- clau de tenant_pause_configs
  pause_counts_as_work    boolean,           -- snapshot al moment del punch

  -- v2: teletreball i geo GDPR
  is_remote               boolean NOT NULL DEFAULT false,
  geo_lat                 numeric(10,7),
  geo_lng                 numeric(10,7),
  geo_accuracy_m          real,
  geo_consent             boolean NOT NULL DEFAULT false,
  geo_error               text,
  geo_anonymized_at       timestamptz,
  device_info             jsonb,

  occurred_at             timestamptz NOT NULL,
  received_at             timestamptz NOT NULL DEFAULT now(),
  client_timezone         text,
  client_clock_offset_ms  integer,

  is_remote               boolean NOT NULL DEFAULT false,
  comment                 text,

  geo                     jsonb,
  location_permission     text NOT NULL DEFAULT 'notrequired'
                          CHECK (location_permission IN ('granted','denied','timeout','error','notrequired')),
  location_error          text,

  location_name_snapshot  text,
  device_name_snapshot    text,
  raw_payload             jsonb NOT NULL DEFAULT '{}',
  validation_status       data.time_punch_validation_status NOT NULL DEFAULT 'pending',
  validation_errors       jsonb NOT NULL DEFAULT '[]',

  created_at              timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, client_op_id)
);
```

Indexos recomanats:

```sql
CREATE INDEX idx_time_punches_employee_time
  ON data.time_punches (employee_id, occurred_at DESC);

CREATE INDEX idx_time_punches_tenant_site_time
  ON data.time_punches (tenant_id, site_id, occurred_at DESC);

CREATE INDEX idx_time_punches_validation
  ON data.time_punches (tenant_id, validation_status, occurred_at DESC);
```

Regles:

- No `UPDATE` funcional sobre raw punches, excepte `validation_status` i camps
  de revisio controlats per RPC.
- Un error o correccio crea ajustos, no sobreescriu el raw original.
- `occurred_at` ve del client; `received_at` ve del servidor.

---

## 16.4 Processed entries i resums

### `data.time_entries`

```sql
CREATE TABLE data.time_entries (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id         uuid NOT NULL REFERENCES data.sites(id) ON DELETE CASCADE,
  employee_id     uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  work_date       date NOT NULL,

  start_punch_id  uuid REFERENCES data.time_punches(id) ON DELETE SET NULL,
  end_punch_id    uuid REFERENCES data.time_punches(id) ON DELETE SET NULL,
  starts_at       timestamptz NOT NULL,
  ends_at         timestamptz,
  duration_minutes integer,

  location_id     uuid REFERENCES data.locations(id) ON DELETE SET NULL,
  source          text NOT NULL DEFAULT 'computed'
                  CHECK (source IN ('computed','manual_adjustment')),
  status          text NOT NULL DEFAULT 'open'
                  CHECK (status IN ('open','closed','needs_review','voided')),
  anomaly_codes   text[] NOT NULL DEFAULT '{}',
  metadata        jsonb NOT NULL DEFAULT '{}',
  processed_at    timestamptz NOT NULL DEFAULT now()
);
```

### `data.time_daily_summaries`

```sql
CREATE TABLE data.time_daily_summaries (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id              uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id                uuid NOT NULL REFERENCES data.sites(id) ON DELETE CASCADE,
  employee_id            uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  work_date              date NOT NULL,

  expected_minutes       integer NOT NULL DEFAULT 0,
  worked_minutes         integer NOT NULL DEFAULT 0,
  regular_minutes        integer NOT NULL DEFAULT 0,
  break_minutes          integer NOT NULL DEFAULT 0,
  overtime_minutes       integer NOT NULL DEFAULT 0,
  absence_paid_minutes   integer NOT NULL DEFAULT 0,
  absence_unpaid_minutes integer NOT NULL DEFAULT 0,
  payroll_minutes        integer NOT NULL DEFAULT 0,

  day_type               text NOT NULL DEFAULT 'workday'
                         CHECK (day_type IN ('workday','holiday','vacation','absence','no_schedule')),
  status                 text NOT NULL DEFAULT 'draft'
                         CHECK (status IN ('draft','needs_review','approved','exported','locked')),
  anomaly_codes          text[] NOT NULL DEFAULT '{}',
  calculation_payload    jsonb NOT NULL DEFAULT '{}',

  approved_by            uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  approved_at            timestamptz,
  payroll_locked_at      timestamptz,
  updated_at             timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, employee_id, work_date)
);
```

---

## 16.5 Calendari laboral

### `data.work_schedules`

```sql
CREATE TABLE data.work_schedules (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id           uuid REFERENCES data.sites(id) ON DELETE SET NULL,
  name              text NOT NULL,
  description       text,
  effective_from    date NOT NULL,
  effective_to      date,
  flexibility_min   integer NOT NULL DEFAULT 0,
  summer_from_mmdd  text,
  summer_to_mmdd    text,
  is_active         boolean NOT NULL DEFAULT true,
  metadata          jsonb NOT NULL DEFAULT '{}',
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
```

### `data.work_schedule_intervals`

```sql
CREATE TABLE data.work_schedule_intervals (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  schedule_id   uuid NOT NULL REFERENCES data.work_schedules(id) ON DELETE CASCADE,
  weekday       smallint NOT NULL CHECK (weekday BETWEEN 1 AND 7),
  variant       text NOT NULL DEFAULT 'standard'
                CHECK (variant IN ('standard','summer')),
  segment       text NOT NULL DEFAULT 'main'
                CHECK (segment IN ('morning','afternoon','main','night')),
  starts_at     time NOT NULL,
  ends_at       time NOT NULL,
  position      integer NOT NULL DEFAULT 0
);
```

### `data.employee_schedule_assignments`

```sql
CREATE TABLE data.employee_schedule_assignments (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id         uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  schedule_id         uuid NOT NULL REFERENCES data.work_schedules(id) ON DELETE RESTRICT,
  starts_on           date NOT NULL,
  ends_on             date,
  allow_overtime      boolean NOT NULL DEFAULT false,
  assigned_by         uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at          timestamptz NOT NULL DEFAULT now()
);
```

### Feriats i calendaris locals

```sql
CREATE TABLE data.holiday_calendars (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id           uuid REFERENCES data.sites(id) ON DELETE CASCADE,
  name              text NOT NULL,
  country_code      char(2) NOT NULL DEFAULT 'ES',
  region_code       text,
  municipality_code text,
  is_active         boolean NOT NULL DEFAULT true
);

CREATE TABLE data.holidays (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  calendar_id   uuid NOT NULL REFERENCES data.holiday_calendars(id) ON DELETE CASCADE,
  holiday_date  date NOT NULL,
  name          text NOT NULL,
  scope         text NOT NULL DEFAULT 'local'
                CHECK (scope IN ('national','regional','local','tenant')),
  is_paid       boolean NOT NULL DEFAULT true,
  UNIQUE (calendar_id, holiday_date)
);
```

### Vacances, baixes i incidencies

```sql
CREATE TABLE data.employee_absences (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id    uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  type           text NOT NULL
                 CHECK (type IN ('vacation','sick_leave','personal_leave','incident','unpaid_leave','other')),
  status         text NOT NULL DEFAULT 'requested'
                 CHECK (status IN ('requested','approved','rejected','cancelled')),
  starts_at      timestamptz NOT NULL,
  ends_at        timestamptz NOT NULL,
  all_day        boolean NOT NULL DEFAULT true,
  is_paid        boolean NOT NULL DEFAULT true,
  requested_by   uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  approved_by    uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  approved_at    timestamptz,
  reason         text,
  metadata       jsonb NOT NULL DEFAULT '{}',
  created_at     timestamptz NOT NULL DEFAULT now()
);
```

---

## 16.6 RPCs recomanades

### Captura

```sql
api.record_time_punch(
  p_client_op_id uuid,
  p_employee_id uuid,
  p_direction text,
  p_occurred_at timestamptz,
  p_source text,
  p_device_public_id text,
  p_location_id uuid,
  p_payload jsonb
) RETURNS jsonb
```

Per lots offline:

```sql
api.sync_time_punches(p_batch jsonb) RETURNS jsonb
```

Resposta per item, mai tot-o-res per defecte. Si un item falla, els altres
poden entrar.

### Consulta UI

```sql
api.my_attendance_today(p_employee_id uuid DEFAULT NULL) RETURNS jsonb
api.resolve_work_day(p_employee_id uuid, p_work_date date) RETURNS jsonb
api.recompute_attendance_day(p_employee_id uuid, p_work_date date) RETURNS jsonb
```

`api.recompute_attendance_day` pot ser interna/service_role per worker; si es
permet a authenticated, ha de limitar-se a managers o a l'empleat propi i sense
aprovar res.

### Estacions

```sql
api.register_attendance_device(p_public_device_id text, p_kind text, p_metadata jsonb)
api.issue_attendance_identity_token(p_method text)
api.resolve_attendance_identity_token(p_token text, p_device_public_id text)
```

---

## 16.7 Vistes `api.*`

| Vista | Proposit |
|---|---|
| `api.employees` | Llista d'empleats segons permisos. Ocultar camps sensibles si no toca. |
| `api.attendance_devices` | Gestio de dispositius/estacions. |
| `api.attendance_locations` | Locations habilitades per fitxatge, basada en `data.locations`. |
| `api.time_punches` | Raw punches visibles per usuari/manager. |
| `api.time_entries` | Intervals processats. |
| `api.time_daily_summaries` | Resums diaris per revisio i payroll. |
| `api.work_schedules` | Plantilles horaries. |
| `api.employee_absences` | Vacances/incidencies. |

---

## 16.8 RLS orientativa

### Lectura propia

Un empleat pot veure els seus propis fitxatges si:

```sql
EXISTS (
  SELECT 1 FROM data.employees e
  WHERE e.id = employee_id
    AND e.user_id = auth.uid()
    AND e.tenant_id = time_punches.tenant_id
)
```

### Managers

Managers/owners poden veure per tenant/site:

```sql
data.jwt_has_permission(tenant_id, 'attendance.view_all', site_id)
```

### Insert

No recomanat fer `INSERT` directe des del frontend. L'entrada ha de passar per
RPC per validar:

- employee pertany al tenant actiu;
- actor pot fitxar aquell employee;
- device actiu;
- location valida i del mateix tenant/site;
- `client_op_id` no duplicat.

---

## 16.9 Audit events

Accions minimes:

| Action | entity_type | Quan |
|---|---|---|
| `TIME_PUNCH_RECORDED` | `time_punch` | Insert raw acceptat. |
| `TIME_PUNCH_REJECTED` | `time_punch` | Operacio rebutjada o quarantena server-side. |
| `TIME_ENTRY_ADJUSTED` | `time_entry` | Manager crea ajust manual. |
| `TIME_DAY_RECOMPUTED` | `time_daily_summary` | Worker recalcula un dia. |
| `TIME_DAY_APPROVED` | `time_daily_summary` | Manager aprova dia. |
| `TIME_DAY_EXPORTED` | `time_daily_summary` | Incluit en export payroll. |
| `ATTENDANCE_DEVICE_REGISTERED` | `attendance_device` | Alta dispositiu. |
| `ATTENDANCE_DEVICE_ASSIGNED` | `attendance_device` | Assignacio a site/location. |
| `EMPLOYEE_ABSENCE_APPROVED` | `employee_absence` | Vacances/baixa aprovada. |

Els ajustos, aprovacions i exports payroll han de considerar-se d'alta
sensibilitat.

---

## 16.10 Riscos

| Risc | Mitigacio |
|---|---|
| Hora client manipulada | Guardar `received_at`, clock offset, anomalies i revisio. |
| Duplicats offline | `UNIQUE (tenant_id, client_op_id)` i resposta `duplicate`. |
| Fitxatges fora d'ordre | Recomputacio server-side per dia amb ordenacio estable. |
| Estacio fixa usada fora de lloc | Device secret + location assignada + audit + suspensio. |
| GPS indoor poc fiable | No bloquejar V1; marcar anomaly si cal. |
| Canvi de calendari retroactiu | Reprocessar dies afectats i bloquejar dies exportats. |
| Payroll legal complex | Exportar resums aprovats, no implementar nomina completa V1. |
| Dades laborals sensibles | Separar permisos `employees.payroll.*`, `attendance.*`, `payroll.*`. |

---

## 16.11 Decisions de disseny (resoltes — Phase 0)

Les open questions originals estan tancades. Resum:

| # | Pregunta | Decisió |
|---|---|---|
| 1 | Estacions = llicència TenantMember o identitat tècnica? | **Identitat tècnica** (`device_secret_hash`, no facturable) |
| 2 | Nivell geofencing V1 | **Configurable** per tenant/site: `off` / `informative` / `warn` / `block`. Per defecte: `informative` |
| 3 | Torns nocturns V1 | **Sí, suport bàsic**; `work_date` = dia d'inici del torn |
| 4 | Font festius | **Nager.Date** (ES + CCAA) + override manual |
| 5 | QR/barcode estació | **V2**. V1 = selecció manual |
| 6 | Arrodoniment payroll | **Configurable**: `real_minute` / `15_min` / `30_min`. Per defecte: `real_minute` |
| 7 | Hores extra | **Configurable**: `auto_if_allowed` / `approval_required`. Per defecte: `approval_required` |
| 8 | Retenció raw punches | **4 anys** (RDL 8/2019) |
| 9 | Export V1 | **CSV genèric + PDF resum mensual + A3/Sage** |

Decisions addicionals (v3 / `prompt_refine_pauses.md`):

| Tema | Decisió |
|------|---------|
| Pauses vs `pause_sessions` | **`time_punches`** (`break_start`/`break_end`); no taula separada |
| Absència parcial | **`employee_absences`** amb `partial_start_time`/`partial_end_time` |
| `attendance_absence_requests` | **No implementada**; flux directe sobre `employee_absences` |
| IT / baixes | Registre **manual** manager fins integració INSS |
| IT + fitxatge simultani | Prioritat IT; anomalia `IT_PUNCH_CONFLICT` |
| Seeds pauses | Per **`archetype_key`** del tenant (`tenant_pause_configs`) |
| Seeds absències | **`tenant_absence_type_configs`** amb `is_system = true` |

---

## 16.12 Extensions implementades (beyond contracte inicial)

Taules i camps afegits durant la implementació (migracions `202605*` → `202608*`):

### Calendari laboral en cascada

- **`data.labor_calendar_overrides`** — override per `(tenant, site?, group?, employee?, date)` amb `day_type`, `work_intervals` JSON, `work_start`/`work_end` legacy.
- **`data.calendar_groups`** — grups globals o de local; `employees.calendar_group_id`.
- Resolució: `data.resolve_schedule_planner_day`, `data.resolve_labor_calendar_for_employee`, `api.resolve_work_day`.

### Pauses i configuració tenant

- **`data.tenant_pause_configs`** — `key`, `label_i18n`, `counts_as_work`, `max_duration_minutes`, seed per arquetip.
- **`data.archetype_pause_config_seeds`** — plantilles de sistema per arquetip.

### Absències i permisos

- **`data.tenant_absence_type_configs`** — catàleg per tenant + seeds legals de sistema (`vacation`, `bereavement`, `it_common`, `partial_medical_*`, etc.).
- **`data.employee_absences`** ampliat — parcials, IT (`it_reference`, `it_start_confirmed`), `counts_as_worked`, `affects_entitlement`.
- **`data.vacation_entitlements`** — cascada tenant / departament / empleat.

### Planificació de torns

- **`data.work_shifts`**, **`data.shift_slots`**, **`data.shift_swap_requests`**, **`data.shift_coverage_requirements`**.

### Informes i tauler

- **`data.attendance_monthly_reports`** — estats `draft` → `employee_confirmed` → `manager_approved` → `signed` → `archived`.
- **`data.mv_today_site_status`** — vista materialitzada per estat del dia.
- **`api.get_today_dashboard_rows`** — RPC enriquida per tauler manager.

### RPCs addicionals (selecció)

```text
api.request_absence / api.approve_absence / api.reject_absence
api.register_it / api.close_it
api.export_attendance_month
api.upsert_pause_config / api.list_pause_configs
api.get_today_dashboard_rows
api.manager_resolve_open_pause
data.seed_acme_attendance_punches  -- demo
```

Veure llista completa i estat UI a [`STATUS.md`](../plans/checkin/STATUS.md).
