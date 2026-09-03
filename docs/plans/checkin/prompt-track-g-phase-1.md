# Prompt d'implementació — Track G Fase 1 (Polítiques i perfils)

> **Creat:** 2026-07-04  
> **Track:** G — Temps efectiu de treball  
> **Fase:** **1** (configuració — **sense** motor de consolidació ni segments)  
> **PRD:** [`plan-effective-work-time.md`](./plan-effective-work-time.md) v4.3 · §11.2 · §21  
> **Següent fase:** Fase 1b (segments) — prompt pendent

---

## Rol

Ets un **Principal Engineer** treballant al monorepo `pimed-app-supabase`. Implementa la **Fase 1** del Track G: emmagatzematge i resolució de **polítiques de registre horari** (conveni), **perfils de jornada** (`work_profile`), i **settings legals** configurables — preparant el terreny per al motor de consolidació (Fase 2a).

**Idioma UI:** català (claus i18n existents a `tenant-portal`).

**Frontend:** només `shadcn/ui` + patrons existents del mòdul attendance.

---

## Lectura obligatòria (abans de codificar)

| Document | Per què |
|----------|---------|
| [`plan-effective-work-time.md`](./plan-effective-work-time.md) §3, §9, §11.2, §21 | Política v2, schema, tasques, bloquejadors |
| [`STATUS.md`](./STATUS.md) §6 Track G | Estat global |
| [`20260817000001_attendance_geo_cascade_e4.sql`](../../../supabase/migrations/20260817000001_attendance_geo_cascade_e4.sql) | **Patró** per `resolve_*` en cascada |
| [`20260821000001_attendance_trust_schedule_hours_e6.sql`](../../../supabase/migrations/20260821000001_attendance_trust_schedule_hours_e6.sql) | Patró `settings_registry` + seed |
| [`AttendanceOvertimeSettingsSection.tsx`](../../../apps/tenant-portal/src/features/attendance/components/settings/AttendanceOvertimeSettingsSection.tsx) | Patró UI settings tenant |
| [`EmployeeDetailPage.tsx`](../../../apps/tenant-portal/src/features/employees/components/EmployeeDetailPage.tsx) | Patró `attendance_geo_enabled` inherit/true/false |
| [`PlanificacioPage.tsx`](../../../apps/tenant-portal/src/features/attendance/pages/PlanificacioPage.tsx) `CalendarGroupsSection` | On afegir editor de política de grup |

---

## Abast IN / OUT

### ✅ Dins d'aquest prompt (Fase 1)

1. Taula `data.attendance_record_policies` + RLS + audit bàsic
2. RPC `data.resolve_attendance_record_policy(employee_id, work_date)` + wrapper `api.*` amb permisos
3. Columna `employees.attendance_work_profile` (nullable, herència)
4. Seeds: política **system** default `fixed_site` + política **tenant** buida opcional
5. RPCs CRUD mínims per polítiques de grup (`upsert` / `list` per `calendar_group_id`)
6. Settings `attendance_statutory_*` al registry + defaults `system_settings`
7. UI: settings legals a `/settings/attendance-control`
8. UI: editor política v2 al formulari de **grup de calendari** (Planificació)
9. UI: selector `work_profile` a fitxa empleat (inherit + 4 valors)
10. UI preview: «política resolta» per empleat + data (read-only)
11. Spike SQL `data.interval_intersection_minutes()` + test a `supabase/tests/`
12. Reserva `work_day_type` a `api.resolve_work_day` (camp `'normal'` per defecte — sense lògica guàrdies)
13. Tests SQL: resolució cascada + RLS

### ❌ Fora d'abast (NO implementar en aquest PR)

| Item | Fase |
|------|------|
| `time_activity_segments`, nous `punch_type` | 1b |
| `consolidate_day_buckets`, canvis a `recompute_attendance_worker` | 2a |
| Columnes `paid_minutes` / `effective_minutes` a summaries | 2a |
| Feature flag `attendance_effective_time_enabled` | 2a |
| Canvis E6 `approvalAssistUtils` | 2a |
| Integració `work_logs` | 2c |
| UI 4 columnes / timeline segments | 3 |
| Perfils `hybrid`, `delivery` — enum sí, **sense** algorisme ni UX especial |

---

## Decisions tancades (NO reobrir)

1. **Cascada política** (§3.1 PRD): empleat → group_site → site → group global → tenant → system
2. **`work_profile`**: empleat override → política guanyadora → `fixed_site` per defecte
3. **`attendance_rounding_mode`** (registry legacy): injectar com a default a `policy.rounding` si el JSON no en té — **no** eliminar columna encara
4. **Un sol flag** `attendance_effective_time_enabled` — **Fase 2a**, no aquí
5. **Taula `work_locations`** — descartada; no crear
6. **Política històrica**: `work_date ∈ [effective_from, effective_to]` — mai «política d'avui» sobre mes tancat

---

## 1. Backend — Schema

### 1.1 `data.attendance_record_policies`

Implementar segons PRD §9 amb ajustos:

```sql
CREATE TABLE data.attendance_record_policies (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  scope             text NOT NULL CHECK (scope IN (
    'system', 'tenant', 'group', 'group_site', 'site', 'employee'
  )),
  calendar_group_id uuid REFERENCES data.calendar_groups(id) ON DELETE CASCADE,
  site_id           uuid REFERENCES data.sites(id) ON DELETE CASCADE,
  employee_id       uuid REFERENCES data.employees(id) ON DELETE CASCADE,
  effective_from    date NOT NULL DEFAULT CURRENT_DATE,
  effective_to      date,
  policy            jsonb NOT NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  created_by        uuid REFERENCES auth.users(id),
  CONSTRAINT arp_scope_fks CHECK (
    (scope = 'system'     AND tenant_id IS NOT NULL AND calendar_group_id IS NULL AND site_id IS NULL AND employee_id IS NULL)
    OR (scope = 'tenant'  AND calendar_group_id IS NULL AND site_id IS NULL AND employee_id IS NULL)
    OR (scope = 'group'    AND calendar_group_id IS NOT NULL AND site_id IS NULL AND employee_id IS NULL)
    OR (scope = 'group_site' AND calendar_group_id IS NOT NULL AND site_id IS NOT NULL AND employee_id IS NULL)
    OR (scope = 'site'     AND site_id IS NOT NULL AND calendar_group_id IS NULL AND employee_id IS NULL)
    OR (scope = 'employee' AND employee_id IS NOT NULL AND calendar_group_id IS NULL AND site_id IS NULL)
  ),
  CONSTRAINT arp_effective_range CHECK (effective_to IS NULL OR effective_to >= effective_from)
);
```

**Índexs obligatoris** (§14 PRD):

```sql
CREATE INDEX idx_arp_tenant_scope ON data.attendance_record_policies (tenant_id, scope, effective_from DESC);
CREATE INDEX idx_arp_group ON data.attendance_record_policies (calendar_group_id, effective_from DESC)
  WHERE calendar_group_id IS NOT NULL;
CREATE INDEX idx_arp_employee ON data.attendance_record_policies (employee_id, effective_from DESC)
  WHERE employee_id IS NOT NULL;
CREATE UNIQUE INDEX uq_arp_one_active_system ON data.attendance_record_policies (tenant_id)
  WHERE scope = 'system';  -- o un sol system global per tenant; documentar tria
```

**Nota implementació:** per `scope = 'system'`, usar **un registre global** per plataforma (`tenant_id` del seed demo o fila amb `tenant_id` NULL si adapteu constraint — preferir **seed per tenant** copiat en onboarding). Documentar al COMMENT.

### 1.2 `employees.attendance_work_profile`

```sql
ALTER TABLE data.employees
  ADD COLUMN IF NOT EXISTS attendance_work_profile text
  CHECK (attendance_work_profile IS NULL OR attendance_work_profile IN (
    'fixed_site', 'mobile_peripatetic', 'hybrid', 'delivery'
  ));
```

Exposar a `api.employees` / RPC update existent (mateix patró que `attendance_geo_enabled`).

### 1.3 Validació JSON `policy` (mínim)

Funció `data.validate_attendance_record_policy(p_policy jsonb) RETURNS void`:

- `version` = 2
- `work_profile` ∈ enum
- `jornada_model` ∈ `schedule_intersection`, `time_budget`
- `activities` objecte amb claus conegudes (WORK, TRAVEL, BREAK_*)
- Cridar des de triggers BEFORE INSERT/UPDATE o des de RPC upsert

**Default factory:** `data.default_attendance_record_policy(p_work_profile text DEFAULT 'fixed_site') RETURNS jsonb` — retorna JSON §3.3 PRD per `fixed_site`; variant simplificada per `mobile_peripatetic` (TRAVEL `counts_paid: true`, `counts_effective: false`).

---

## 2. Backend — Resolució cascada

### 2.1 `data.resolve_attendance_record_policy`

```sql
data.resolve_attendance_record_policy(
  p_employee_id uuid,
  p_work_date     date
) RETURNS jsonb
-- { policy, policy_id, resolved_from, work_profile, policy_version }
```

**Algorisme** (mateixa TX, STABLE):

1. Carregar empleat: `tenant_id`, `site_id`, `calendar_group_id`, `attendance_work_profile`
2. Cercar fila guanyadora per prioritat (§3.1), filtrant:
   - `tenant_id` = empleat.tenant_id (excepte system seed)
   - `p_work_date >= effective_from AND (effective_to IS NULL OR p_work_date <= effective_to)`
   - En empate de prioritat: `effective_from` més recent
3. Si cap fila → `default_attendance_record_policy('fixed_site')`, `resolved_from = 'system_default'`
4. **`work_profile` resolt:**
   - `employees.attendance_work_profile` si NOT NULL
   - sinó `policy->>'work_profile'`
   - sinó `'fixed_site'`
5. **Merge arrodoniment legacy:** si `policy.rounding` absent, injectar des de `api.get_effective_settings()` clau `attendance_rounding_mode` mapat a `policy.rounding.mode`

**No** cridar des del recompute encara — només exposar RPC.

### 2.2 Wrapper API

```sql
api.get_attendance_record_policy(p_employee_id uuid, p_work_date date DEFAULT CURRENT_DATE)
```

Permisos (mateix patró que `api.get_attendance_geo_enabled`):

- Pròpi empleat (`employees.user_id = auth.uid()`)
- O `attendance.view_all` / `attendance.approve` al site

### 2.3 RPC upsert política de grup

```sql
api.upsert_calendar_group_record_policy(
  p_group_id       uuid,
  p_policy         jsonb,
  p_effective_from date DEFAULT CURRENT_DATE,
  p_site_id        uuid DEFAULT NULL  -- NULL = scope 'group'; NOT NULL = 'group_site'
) RETURNS jsonb
```

Permís: `attendance.calendar.manage` o nou `attendance.policy.manage` (registrar a permisos si cal — reutilitzar `attendance.calendar.manage` per MVP).

Inserir amb `scope = 'group'` o `'group_site'`, `validate_attendance_record_policy`, audit log.

---

## 3. Backend — Settings legals

Registrar a `data.settings_registry` (scope `tenant`, permís `settings.manage`):

| `setting_key` | Tipus | Default |
|---------------|-------|---------|
| `attendance_statutory_max_overtime_minutes_year` | integer | `4800` |
| `attendance_statutory_overtime_period` | string | `calendar_year` |
| `attendance_statutory_fiscal_year_start_month` | integer | `1` |
| `attendance_statutory_jurisdiction_code` | string | `ES` |
| `attendance_statutory_max_work_minutes_year` | integer/null | `null` |
| `attendance_statutory_alert_thresholds_pct` | json array | `[80,90,100]` |
| `attendance_statutory_block_punch_on_limit` | boolean | `false` |

Seed a `data.system_settings` module `defaults`.

**Site override:** si el settings engine ja suporta override per site, documentar; sinó **només tenant** en Fase 1 (deixar TODO §14.7).

---

## 4. Backend — Spike `interval_intersection_minutes`

Funció pura per Fase 2a (jornada partida §4.3):

```sql
data.interval_intersection_minutes(
  p_range_start timestamptz,
  p_range_end   timestamptz,
  p_intervals   jsonb  -- [{ "start": "08:00", "end": "14:00" }, ...] en time local del site
  p_tz          text DEFAULT 'Europe/Madrid'
) RETURNS int
```

Test SQL a `supabase/tests/attendance_interval_intersection_tests.sql`:

- Jornada partida 08–14, 16–18; rang 07:55–18:40 → minuts d'intersecció esperats documentats
- Rang buit → 0
- Torn nocturn — cas simple (opcional, pot fallar amb TODO)

---

## 5. Backend — Reserva `work_day_type`

Ampliar retorn de `api.resolve_work_day` amb camp addicional:

```json
"work_day_type": "normal"
```

Sempre `"normal"` en Fase 1. No UI. Prepara §19 guàrdies.

---

## 6. Backend — Tests SQL

Fitxer `supabase/tests/attendance_record_policy_tests.sql`:

| Test | Assert |
|------|--------|
| T1 | Sense cap política → default `fixed_site`, version 2 |
| T2 | Política tenant override system |
| T3 | Política group override tenant |
| T4 | Política group_site override group global |
| T5 | Política employee override tot |
| T6 | `effective_from` / `effective_to` — data fora rang no aplica |
| T7 | `attendance_work_profile` empleat override `policy.work_profile` |
| T8 | RLS: member no edita polítiques; manager amb permís sí |

Patró: `BEGIN` … fixtures … `ROLLBACK`.

---

## 7. Frontend — Settings tenant

**Fitxer:** ampliar [`AttendanceControlPage.tsx`](../../../apps/tenant-portal/src/pages/settings/AttendanceControlPage.tsx)

Nova secció `AttendanceStatutoryLimitsSection.tsx`:

- Camps §3.2 PRD
- Hint: «Límits legals configurables — no substitueixen assessorament laboral»
- Mostrar procedència «Llei {jurisdiction_code}»
- Reutilitzar `useTenantSettingsMutation` + parse/serialize helpers (nou `statutoryLimitsSettings.ts`)

**No** eliminar encara la UI de `attendance_rounding_mode` si existeix — afegir nota «Es migrarà a la política de conveni del grup (Track G)».

---

## 8. Frontend — Grup de calendari

**Fitxer:** [`PlanificacioPage.tsx`](../../../apps/tenant-portal/src/features/attendance/pages/PlanificacioPage.tsx) — `CalendarGroupsSection`

Afegir pestanya o secció col·lapsable **«Política de registre (conveni)»** quan un grup està seleccionat:

- Carregar política via `api.get_calendar_group_record_policy` (nou hook) o incloure a `list_calendar_groups` com a camp opcional
- Editor JSON **guiat** (no raw JSON lliure per MVP):
  - Selector `work_profile`
  - Selector `jornada_model`
  - Matriu `activities` — checkboxes per WORK/TRAVEL/BREAK (usar defaults factory)
  - Secció cortesia (4 camps numèrics)
  - Secció arrodoniment (mode + direction)
  - Secció overtime (allowed, requires_prior_authorization, overtime_base)
- Botó «Restaurar defaults» crida factory backend o constant client sincronitzada
- `effective_from` = avui per defecte; avís si canvi afecta mes obert

**Component nou suggerit:** `AttendanceRecordPolicyEditor.tsx` (reutilitzable després a inspector calendari).

---

## 9. Frontend — Fitxa empleat

**Fitxer:** [`EmployeeDetailPage.tsx`](../../../apps/tenant-portal/src/features/employees/components/EmployeeDetailPage.tsx)

Afegir camp **«Perfil de jornada»** (`attendance_work_profile`):

- Opcions: Hereta del grup / Centre fix / Itinerant / Híbrid / Repartiment
- Hint: «Determina botons de fitxatge i càlcul d'hores — el configura RRHH»
- Preview read-only: crida `api.get_attendance_record_policy(employee_id, today)` i mostra `resolved_from` + `work_profile` resolt

Mateix patró inherit que `attendance_geo_enabled`.

---

## 10. Frontend — Preview inspector (mínim)

Si [`LaborCalendarGrid`](../../../apps/tenant-portal/src/features/attendance/components/LaborCalendarGrid.tsx) té `DayInspector`, afegir línia read-only:

- «Política registre: {resolved_from} · Perfil: {work_profile}»

Si no hi ha hook fàcil, **diferir** a Fase 3 — opcional Fase 1.

---

## 11. Tipus i regeneració

- Actualitzar `apps/tenant-portal/src/types/database.types.ts` (o script regenerate si existeix)
- Hooks nous a `apps/tenant-portal/src/features/attendance/api/`:
  - `recordPolicyService.ts`
  - `useAttendanceRecordPolicy.ts`
  - `statutoryLimitsSettings.ts`

---

## 12. Criteris de done (PR mergeable)

- [ ] Migració SQL aplica sense errors en local (`supabase db reset` o equivalent)
- [ ] `supabase/tests/attendance_record_policy_tests.sql` passa
- [ ] `supabase/tests/attendance_interval_intersection_tests.sql` passa (spike)
- [ ] Manager pot guardar política v2 per grup de calendari i veure preview
- [ ] Manager pot configurar límits legals tenant
- [ ] RRHH pot assignar `work_profile` per empleat (inherit + override)
- [ ] `api.get_attendance_record_policy` retorna JSON vàlid per qualsevol empleat actiu
- [ ] **Cap** canvi de comportament de `recompute_attendance_worker` (worked_minutes igual que abans)
- [ ] RLS revisat: polítiques no filtrables cross-tenant
- [ ] [`STATUS.md`](./STATUS.md) G1 marcat ⚠️ parcial o ✅ segons checklist

---

## 13. Ordre d'execució recomanat

```text
1. Migració schema + validate + default factory + seeds
2. resolve_attendance_record_policy + api wrapper
3. Tests SQL polítiques
4. Spike interval_intersection + test
5. resolve_work_day work_day_type
6. Settings registry statutory + UI tenant
7. upsert_calendar_group_record_policy + UI grup
8. Employee work_profile + preview
9. STATUS + lints
```

---

## 14. Notes per la PR

**Títol suggerit:** `feat(attendance): Track G phase 1 — record policies and work profiles`

**Descripció:**

- Afegeix emmagatzematge versionat de polítiques de conveni (`attendance_record_policies`) i resolució en cascada per empleat/data.
- UI per configurar política per grup de calendari, límits legals tenant, i perfil de jornada per empleat.
- Sense canvis al motor de fitxatge/recompute (Fase 2a).

**Test plan manual:**

1. Crear grup «Oficina» amb política `fixed_site` i cortesia 15 min
2. Assignar empleat al grup — preview mostra política del grup
3. Override empleat a `mobile_peripatetic` — preview reflecteix override
4. Canviar `attendance_statutory_max_overtime_minutes_year` — persisteix

---

## 15. Decisions producte pendents (documentar a PR si no resolt)

| Pregunta | Opció recomanada Fase 1 |
|----------|---------------------------|
| E6 bucket per perfil (`effective` vs `paid`) | Documentar a PR: `fixed_site` → `effective_minutes`; `mobile_peripatetic` → `paid_minutes` (**implementació Fase 2a**) |
| Permís nou `attendance.policy.manage` | Reutilitzar `attendance.calendar.manage` |
| System policy per tenant vs global | Un seed `scope=tenant` copiat en onboarding + factory hardcoded fallback |

---

*Fi del prompt — Track G Fase 1*
