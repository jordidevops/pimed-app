# Prompt d'implementació — Track G Fase 2a (Motor centre fix)

> **Creat:** 2026-07-05  
> **Track:** G — Temps efectiu de treball  
> **Fase:** **2a** (motor `fixed_site`: cortesia, arrodoniment, buckets, feature flag)  
> **PRD:** [`plan-effective-work-time.md`](./plan-effective-work-time.md) §4, §5.1, §11.4  
> **Prerequisit:** G1 ✅ · G1b ✅ ([`prompt-track-g-phase-1b.md`](./prompt-track-g-phase-1b.md))  
> **Següent fase:** G2b (motor `mobile_peripatetic` punch-only)

---

## Rol

Ets un **Principal Engineer** al monorepo `pimed-app-supabase`. Implementa la **Fase 2a**: motor de consolidació diària per perfil **`fixed_site`** — cortesia, arrodoniment assimètric (§4.6), intersecció amb horari previst, buckets nous a `time_daily_summaries`, feature flag tenant, i integració al `recompute_attendance_worker` + E6 per perfil.

**Idioma UI:** català (claus i18n existents).

**No desplegar** el flag a empleats amb `work_profile = mobile_peripatetic` (G2b primer).

---

## Lectura obligatòria (abans de codificar)

| Document | Per què |
|----------|---------|
| [`plan-effective-work-time.md`](./plan-effective-work-time.md) §4, §4.6, §5.1, §9, §11.4 | Algorisme, fixtures, schema |
| [`20260901000001_track_g_phase1_record_policies.sql`](../../../supabase/migrations/20260901000001_track_g_phase1_record_policies.sql) | Política v2, `interval_intersection_minutes` |
| [`20260902000001_track_g_phase1b_segments.sql`](../../../supabase/migrations/20260902000001_track_g_phase1b_segments.sql) | Classificador + recompute actual |
| [`approvalAssistUtils.ts`](../../../apps/tenant-portal/src/features/attendance/utils/approvalAssistUtils.ts) | E6 confiança — migrar bucket |
| [`20260821000001_attendance_trust_schedule_hours_e6.sql`](../../../supabase/migrations/20260821000001_attendance_trust_schedule_hours_e6.sql) | Patró `settings_registry` |

---

## Abast IN / OUT

### ✅ Dins d'aquest prompt

1. Migració columnes `time_daily_summaries` (§9 PRD) + mirall parcial a `time_entries`
2. Setting `attendance_effective_time_enabled` (tenant, default `false`)
3. Helpers SQL: arrodoniment assimètric (§4.6), cortesia als límits WORK
4. `data.consolidate_day_buckets(p_employee_id, p_work_date, p_tenant_id)` — branca **`fixed_site`**
5. Patch `api.recompute_attendance_worker`: després de classify, cridar consolidate **si flag ON i perfil `fixed_site`**
6. Persistir buckets + `consolidation_meta` + `work_profile_snapshot`
7. **`worked_minutes` legacy** = `net_minutes` (comportament actual); buckets nous són addicionals
8. Anomalies noves: `EFFECTIVE_OVERFLOW_EARLY`, `LATE_ARRIVAL`, `OVERTIME_UNAUTHORIZED`, `CONSOLIDATION_POLICY_MISSING`
9. E6: comparar `effective_minutes` (fixed_site) en lloc de `worked_minutes` quan flag actiu
10. Tests SQL daurats §4 + §4.6 obligatoris
11. Actualitzar vista `api.time_daily_summaries` amb columnes noves
12. STATUS G2a

### ❌ Fora d'abast

| Item | Fase |
|------|------|
| Motor `mobile_peripatetic` / `time_budget` | G2b |
| `work_logs.field_punch` al classificador | G2c |
| UI 4 columnes / timeline segments | G3 |
| Rollups anuals / alertes legal | G5 |
| Protocol DMS | G6 |
| Perfils `hybrid`, `delivery` al motor | Post-G2b |

---

## Decisions tancades (NO reobrir)

1. **Un sol flag** `attendance_effective_time_enabled` — el perfil resolt selecciona branca del motor
2. **Flag OFF** → recompute idèntic a G1b (zero regressió)
3. **Flag ON + `fixed_site`** → consolidate; **`worked_minutes` no canvia** (compat nòmina/export legacy)
4. **Flag ON + mobile** → **skip consolidate** (log `consolidation_meta.skipped = 'awaiting_g2b'`)
5. **Ordre motor (§5.1):** classify → cortesia WORK → pas 1 arrodoniment → pas 2 tall/OT vs `expected_intervals` → agregar buckets
6. **Invariant §4.6:** tardana IN mai ↑ (08:03 → mai 08:15); OUT mai < real
7. **`paid_minutes` = `effective_minutes`** per `fixed_site` default (Conveni A oficina); TRAVEL = 0
8. **`regular_minutes` = min(`effective_minutes`, `expected_minutes`)**; OT sobre residual segons `overtime` policy
9. **Dia `adjusted`** a `time_entries` → no sobreescriure buckets; consolidate només meta/anomalies
10. **E6 bucket:** `fixed_site` → `effective_minutes`; mobile (futur) → `paid_minutes`

---

## 1. Backend — Schema

### 1.1 Columnes `time_daily_summaries`

```sql
ALTER TABLE data.time_daily_summaries
  ADD COLUMN IF NOT EXISTS presence_minutes int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS work_minutes int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS travel_minutes int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS effective_minutes int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS paid_minutes int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS regular_minutes int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS overtime_authorized_minutes int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS consolidation_meta jsonb NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS work_profile_snapshot text;
```

### 1.2 Columnes `time_entries` (mirall per dia tancat)

```sql
ALTER TABLE data.time_entries
  ADD COLUMN IF NOT EXISTS presence_minutes int,
  ADD COLUMN IF NOT EXISTS work_minutes int,
  ADD COLUMN IF NOT EXISTS travel_minutes int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS effective_minutes int,
  ADD COLUMN IF NOT EXISTS paid_minutes int;
```

### 1.3 Feature flag

```sql
INSERT INTO data.settings_registry (setting_key, scope, ...)
VALUES ('attendance_effective_time_enabled', 'tenant', ...);

INSERT INTO data.system_settings (module, settings)
VALUES ('defaults', '{"attendance_effective_time_enabled": false}'::jsonb);
```

Lectura al worker: `data.merge_effective_settings_for_service(tenant_id, site_id)`.

---

## 2. Backend — Helpers arrodoniment i cortesia

### 2.1 `data.floor_to_quarter_local(p_ts, p_tz) RETURNS timestamptz`

Arrodoneix **cap avall** al quart d'hora en timezone local.

### 2.2 `data.ceil_to_quarter_local(p_ts, p_tz) RETURNS timestamptz`

Arrodoneix **cap amunt** al quart d'hora en timezone local.

### 2.3 `data.adjust_punch_for_consolidation(...) RETURNS timestamptz`

Paràmetres: `occurred_at`, `punch_type` (`in`|`out`), `expected_boundary`, `policy`, `tz`.

Implementar matriu §4.5/§4.6:

- IN tardana: mai `> occurred_at`
- OUT: mai `< occurred_at`
- `favor_employee` vs `favor_employer` vs `real_minute`

### 2.4 `data.apply_courtesy_in_out(...) RETURNS jsonb`

Retorna `{ effective_in, effective_out, anomalies[] }` aplicant `policy.courtesy` als límits WORK vs `work_intervals` de `resolve_work_day`.

---

## 3. Backend — `data.consolidate_day_buckets`

```sql
data.consolidate_day_buckets(
  p_employee_id uuid,
  p_work_date   date,
  p_tenant_id   uuid
) RETURNS jsonb
-- { skipped?, presence_minutes, work_minutes, travel_minutes,
--   effective_minutes, paid_minutes, regular_minutes,
--   overtime_minutes, overtime_authorized_minutes,
--   consolidation_meta, anomaly_codes }
```

**Algorisme `fixed_site`:**

1. Resoldre política + perfil; si flag OFF o perfil mobile → `{ skipped: true }`
2. Carregar segments WORK/BREAK del dia (post-classify)
3. `presence_minutes` = gross (primera IN → última OUT) − breaks unpaid (mateix que net base)
4. Obtenir `work_intervals`, `expected_minutes`, `shift_*` de `api.resolve_work_day`
5. Cortesia IN/OUT als límits del primer/últim interval WORK
6. Pas 1 — arrodoniment als timestamps ajustats
7. Pas 2 — `effective_minutes` = `interval_intersection_minutes(adj_in, adj_out, work_intervals, tz)` − breaks unpaid dins finestra
8. `work_minutes` = `effective_minutes` (fixed_site)
9. `paid_minutes` = `effective_minutes` si `activities.WORK.counts_paid`
10. `regular_minutes` = LEAST(`effective_minutes`, `expected_minutes`)
11. `overtime_minutes` = GREATEST(0, `paid_minutes` − `expected_minutes`) — ajustar amb autoritzacions E5 si existeixen
12. `consolidation_meta` compacte (policy_version, work_profile, buckets, rules_applied)

---

## 4. Backend — Patch `recompute_attendance_worker`

Després de `classify_activity_segments`:

```sql
IF v_effective_time_enabled AND v_profile = 'fixed_site' THEN
  v_consolidated := data.consolidate_day_buckets(...);
  -- UPDATE time_daily_summaries SET presence_minutes=..., effective_minutes=..., ...
  -- UPDATE time_entries mirall buckets
  -- Merge anomaly_codes
ELSIF v_effective_time_enabled AND data.is_mobile_work_profile(v_profile) THEN
  -- consolidation_meta := {"skipped":"awaiting_g2b"}
END IF;
```

**No modificar** el càlcul existent de `worked_minutes` / `net_minutes`.

---

## 5. Frontend — E6 `approvalAssistUtils`

Quan el tenant té `attendance_effective_time_enabled` (exposar via settings existents o day detail):

- `isTrustScheduleHoursApprovalEligible`: comparar `effective_minutes` (o `paid_minutes` si perfil mobile) vs `expected_minutes`
- Fallback a `worked_minutes` si flag OFF o buckets = 0

Fitxers:

- `approvalAssistUtils.ts`
- `dayDetailService.ts` / RPC si cal exposar columnes noves
- `PayrollReviewDay` tipus si cal

---

## 6. Tests SQL obligatoris

Fitxer: `supabase/tests/attendance_effective_time_fixed_site_tests.sql`

| Cas | Fixture | Assert |
|-----|---------|--------|
| T1 | IN 07:55, OUT 18:05, horari 08–18, cortesia 15 | `effective_in` efectiu 08:00 |
| T2 | **IN 08:03** tardana | `IN_ajustat` **≠ 08:15** |
| T3 | **OUT 18:18**, favor_employee | OT = **30** min (pas 2 vs 18:00) |
| T4 | Jornada partida §4.3 | `presence`=520, `effective`=480, OT=45 |
| T5 | Flag OFF | buckets = 0, `worked_minutes` inalterat |
| T6 | Flag ON + mobile | consolidate skipped |

Policy JSON tancada per test (INSERT política grup + empleat fixture).

---

## 7. Criteris de done

- [ ] Migració aplica en local
- [ ] Tests `attendance_effective_time_fixed_site_tests.sql` passen
- [ ] Flag OFF: zero canvi `worked_minutes` vs G1b
- [ ] Flag ON + fixed_site: buckets persistits; IN 08:03 mai → 08:15
- [ ] Flag ON + mobile: no consolidate (meta skipped)
- [ ] Vista `api.time_daily_summaries` exposa columnes noves
- [ ] E6 usa `effective_minutes` quan flag ON
- [ ] STATUS G2a ✅

---

## 8. Ordre d'execució

```text
1. Schema columnes + settings flag
2. Helpers rounding/courtesy
3. consolidate_day_buckets (fixed_site)
4. Patch recompute_attendance_worker
5. api.time_daily_summaries view
6. Tests SQL §4/§4.6
7. approvalAssistUtils E6
8. STATUS.md
```

---

## 9. Notes PR

**Títol:** `feat(attendance): Track G phase 2a — fixed_site effective time motor`

**Test plan manual:**

1. Tenant flag OFF → fitxatge in/out → `worked_minutes` com abans
2. Activar flag + empleat `fixed_site` + política cortesia 15 min
3. IN 08:03 → `effective_minutes` correcte; timeline raw intacte
4. E6 confiança compara efectiu vs previst

---

*Fi del prompt — Track G Fase 2a*
