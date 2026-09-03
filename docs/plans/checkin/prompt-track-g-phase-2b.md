# Prompt d'implementació — Track G Fase 2b (Motor itinerant punch-only)

> **Creat:** 2026-07-05  
> **Track:** G — Temps efectiu de treball  
> **Fase:** **2b** (motor `mobile_peripatetic`: `time_budget`, segments, TRAVEL, buckets)  
> **PRD:** [`plan-effective-work-time.md`](./plan-effective-work-time.md) §2.2, §5.0–5.1, §11.5, §18.4–18.6  
> **Prerequisit:** G1 ✅ · G1b ✅ · **G2a ✅** ([`prompt-track-g-phase-2a.md`](./prompt-track-g-phase-2a.md))  
> **Següent fase:** G2c (`work_logs.field_punch` + gaps D-INT-7 + RPCs composta)

---

## Rol

Ets un **Principal Engineer** al monorepo `pimed-app-supabase`. Implementa la **Fase 2b**: branca **`mobile_peripatetic`** del motor de consolidació — agregació des de **`time_activity_segments`** (classificador G1b, punch-only), buckets `work`/`travel`/`paid`/`effective`, quota diària (`time_budget`), i integració al `recompute_attendance_worker` + E6 per perfil.

**Idioma UI:** català (claus i18n existents).

**Model temporal punch-only** (§18.5 legacy): `day_start` → `in`/`out`/`travel_*` → `day_end`. **No** `work_logs` ni `switch_work_log` — això és **G2c**.

---

## Lectura obligatòria (abans de codificar)

| Document | Per què |
|----------|---------|
| [`plan-effective-work-time.md`](./plan-effective-work-time.md) §2.2, §5.0–5.3, §11.5, §18.4–18.6 | Buckets, pipeline mobile, 3 convenis |
| [`20260902000001_track_g_phase1b_segments.sql`](../../../supabase/migrations/20260902000001_track_g_phase1b_segments.sql) | `classify_activity_segments`, mobile_walk |
| [`20260903000003_track_g_phase2a_per_tram_courtesy.sql`](../../../supabase/migrations/20260903000003_track_g_phase2a_per_tram_courtesy.sql) | `consolidate_day_buckets` (branca `fixed_site` + skip mobile) |
| [`approvalAssistUtils.ts`](../../../apps/tenant-portal/src/features/attendance/utils/approvalAssistUtils.ts) | E6 — migrar bucket mobile → `paid_minutes` |
| [`prompts/shared/work-logs-time-attendance-integration.md`](../../../prompts/shared/work-logs-time-attendance-integration.md) | D-INT-3…8 — **només referència**; no implementar G2c aquí |

---

## Abast IN / OUT

### ✅ Dins d'aquest prompt

1. **`data.consolidate_day_buckets`** — branca **`mobile_peripatetic`** (substitueix `skipped: awaiting_g2b`)
2. Helper **`data.aggregate_segment_buckets`** — Σ minuts per `activity_kind` + flags `policy.activities.*`
3. **`presence_minutes`** mobile = `day_start` → `day_end` si existeixen; sinó envelope segments `counts_presence`
4. **`worked_minutes` legacy (net)** — §2.2 PRD: `presence − breaks_unpaid − travel` (si `TRAVEL.counts_net_work = false`); **no** gross(`day_start`→`day_end`)−pausa; **no** confondre amb `paid_minutes`
5. Patch **`recompute_attendance_worker`**: **`presence_minutes`** (bucket) = `day_start`→`day_end`; **`worked_minutes`** = fórmula net §2.2 (veure §3.1)
6. OT **`time_budget`**: `regular_minutes` / `overtime_minutes` segons `policy.overtime.overtime_base` (`paid_minutes` per defecte mobile)
7. Anomalies: `SEGMENT_GAP` (segment obert a EOD), reutilitzar `DAY_NOT_CLOSED`, `TRAVEL_NOT_CLOSED`, `UNCLASSIFIED_GAP` (buits > llindar entre segments tancats sense classificació — punch-only: gap entre `out` i següent `in`/`travel_start` sense punch)
8. **`consolidation_meta`**: `unclassified_gaps[]`, `per_tram_courtesy: false`, `rules_applied`, desglossament buckets
9. **E6**: comparar **`paid_minutes`** (no `effective_minutes`) quan perfil mobile + flag actiu
10. **`get_payroll_review_days`**: exposar **`paid_minutes`** (addicional a `effective_minutes` G2a)
11. Tests SQL daurats §18.4 (3 convenis) + fixture lampista punch-only
12. STATUS G2b

### ❌ Fora d'abast

| Item | Fase |
|------|------|
| `work_logs` / `entry_mode = field_punch` al classificador | **G2c** |
| `gap_kind`, `switch_work_log`, RPCs `field_punch_*` | **G2c** |
| Cortesia / arrodoniment per segment (només WORK `in`/`out` si política ho demana — mínim viable: segments raw, arrodoniment diferit) | Opcional G2b; **obligatori** abans producció legal si tenant exigeix §4.6 en camp |
| UI 4 columnes / timeline segments | G3 |
| `flex_midday` (`fixed_site`) | G2a.2 |
| Perfils `hybrid`, `delivery` al motor | Post-G2c |
| Fixture C (timesheet timer/manual) | Fora motor minuts |

---

## Decisions tancades (NO reobrir)

1. **Un sol flag** `attendance_effective_time_enabled` — perfil resolt selecciona branca (`fixed_site` | `mobile_peripatetic`)
2. **Flag OFF** → recompute idèntic a G1b (zero regressió)
3. **Flag ON + mobile** → consolidate des de **segments existents** (post-`classify_activity_segments`); **no** reclassificar des de `work_logs`
4. **`paid_minutes` ≠ `effective_minutes`** és **normal** en mobile (Conveni C: viatge pagat, no efectiu)
5. **`worked_minutes`** al summary **es manté = `net_minutes`** (no substituir per `paid_minutes` ni per gross jornada)
6. **Presència mobile (bucket `presence_minutes`)** = `day_start` → `day_end` quan ambdós existeixen; sinó Σ segments amb `counts_presence`
7. **Net mobile (`worked_minutes`)** = `presence_minutes − breaks_unpaid − travel_minutes` quan `TRAVEL.counts_net_work = false` (default). Exemple lampista §5.1: **645 − 30 − 135 = 480** — coincideix amb avui (`in`→`out` − pausa, sense comptar viatge)
8. **OT base mobile** = `policy.overtime.overtime_base` (default `paid_minutes`) vs `daily_work_budget_minutes` (default 480)
9. **Classificador G1b** no es reescriu — només es consumeixen segments; gaps declarats explícitament (`travel_start`/`travel_end`) generen TRAVEL
10. **E6 bucket:** `fixed_site` → `effective_minutes`; **`mobile_peripatetic` → `paid_minutes`**
11. **Dia `adjusted`** → no sobreescriure buckets (mateix patró G2a)
12. **Producció mobile amb flag ON** permesa **només** després G2b ✅; G2c millora multi-obra però no bloqueja desplegament punch-only

---

## 1. Backend — Helper agregació segments

### 1.1 `data.sum_segment_minutes_by_kind(...)`

```sql
-- Entrada: employee_id, work_date, tenant_id, policy
-- Llegeix data.time_activity_segments del dia
-- Per cada segment tancat (ended_at NOT NULL):
--   duració = EXTRACT(EPOCH FROM (ended_at - started_at)) / 60
-- Segment obert (ended_at IS NULL) → usar now() AT TIME ZONE tz per provisional
--   + anomaly SEGMENT_GAP si dia passat o day_end absent
```

Retornar jsonb:

```json
{
  "by_kind": { "WORK": 480, "TRAVEL": 135, "BREAK_UNPAID": 30 },
  "presence_minutes": 645,
  "open_segments": 0,
  "gaps": []
}
```

### 1.2 `data.apply_activity_flags_to_buckets(p_by_kind, p_policy)`

Implementar §2.2:

```
work_minutes      = by_kind.WORK
travel_minutes    = by_kind.TRAVEL
paid_minutes      = Σ kind on policy.activities[kind].counts_paid
effective_minutes = Σ kind on policy.activities[kind].counts_effective
```

Respectar `never_reduce_paid_below_net` si aplica (policy rounding).

### 1.3 OT `time_budget`

```sql
v_budget := COALESCE((policy->>'daily_work_budget_minutes')::int, expected_minutes, 480);
v_ot_base := CASE policy.overtime.overtime_base
  WHEN 'paid_minutes' THEN v_paid
  WHEN 'effective_minutes' THEN v_effective
  ELSE v_work
END;
v_regular := LEAST(v_ot_base, v_budget);
v_overtime := GREATEST(0, v_ot_base - v_budget);
```

Si `requires_prior_authorization` → `OVERTIME_UNAUTHORIZED` quan `v_overtime > 0`.

---

## 2. Backend — `data.consolidate_day_buckets` (branca mobile)

Estendre funció existent (no duplicar):

```text
IF NOT v_enabled → skip flag_off
IF v_profile = 'fixed_site' → branca G2a (existent)
IF is_mobile_work_profile(v_profile) → branca G2b (NOVA)
ELSE → unsupported_profile
```

**Algorisme G2b:**

1. Resoldre política + `daily_work_budget_minutes`
2. Assegurar segments classificats (`classify_activity_segments` ja cridat des del worker abans)
3. `aggregate_segment_buckets` → minuts per kind
4. Detectar **gaps** entre segments consecutius > `policy.unclassified_gap_threshold_minutes` (default 30) sense TRAVEL/BREAK → `UNCLASSIFIED_GAP` + `consolidation_meta.unclassified_gaps[]`
5. `apply_activity_flags_to_buckets`
6. Pas OT `time_budget` (§1.3)
7. Retornar mateix schema jsonb que G2a

**`depot_rule.jornada_starts_at_depot`:** si `true`, el TRAVEL previ al primer `in` pot ser `OFF_DUTY` — implementar si política té flag; sinó documentar com a TODO G2c amb geo.

---

## 3. Backend — Patch `recompute_attendance_worker`

### 3.1 Presència i net mobile (abans de consolidate)

Quan `is_mobile_work_profile(v_profile)`:

**Presència (bucket `presence_minutes`, i base del net):**

```sql
-- Preferit: jornada legal explícita
IF v_day_start IS NOT NULL AND v_day_end IS NOT NULL THEN
  v_presence_min := ROUND(EXTRACT(EPOCH FROM (v_day_end - v_day_start)) / 60)::int;
ELSIF v_day_start IS NOT NULL THEN
  -- jornada oberta: provisional day_start → now() o últim punch
  ...
ELSE
  -- legacy sense day_start: envelope first/last activity amb counts_presence
  ...
END IF;
```

**Net legacy (`worked_minutes` = `net_minutes`) — §2.2, NO reobrir:**

```sql
v_travel_for_net := CASE
  WHEN COALESCE((policy->'activities'->'TRAVEL'->>'counts_net_work')::boolean, false)
  THEN 0
  ELSE v_travel_min  -- des de segments o consolidate
END;
v_net_min := GREATEST(0, v_presence_min - v_break_min - v_travel_for_net);
```

**Fixture lampista:** presència **645**, travel **135**, break **30** → **`worked_minutes` = 480** (no 615 ni 450).

| Error a evitar | Per què |
|----------------|---------|
| `worked = gross − pausa` → 615 | Inclou viatge al net; infla dashboard vs avui |
| `615 − 135 − 30` → 450 | Resta la pausa dues vegades |

Si només `day_start` (jornada oberta) → mantenir lògica G1b `in`/`out` provisional fins tancament.

Si **no** hi ha `day_start` (legacy in/out) → presència envelope `first_in` → `last_out`; net = presència − pausa − travel (si aplica).

### 3.2 Consolidació

Substituir bloc `awaiting_g2b`:

```sql
v_consolidated := data.consolidate_day_buckets(...);
-- mateix UPDATE buckets que fixed_site quan skipped = false
```

Eliminar escriptura `consolidation_meta.skipped = 'awaiting_g2b'` com a estat final quan G2b està actiu.

---

## 4. Frontend — E6 `approvalAssistUtils`

Ampliar `trustComparisonMinutes`:

```typescript
// Pseudocodi — implementar amb work_profile del dia o settings
if (effectiveTimeEnabled && workProfile === 'mobile_peripatetic') {
  return paidMinutes ?? workedMinutes
}
if (effectiveTimeEnabled && effectiveMinutes > 0) {
  return effectiveMinutes
}
return workedMinutes
```

**Requisits:**

- Exposar `paid_minutes` + `work_profile_snapshot` al day detail / payroll review RPC
- `useApprovalAssistSettings` — sense canvis de flag (mateix `attendance_effective_time_enabled`)
- Actualitzar `PayrollReviewDay` + `mapDay` si cal `paid_minutes`

Fitxers probables:

- `approvalAssistUtils.ts`
- `payrollReviewService.ts`
- `dayDetailService.ts` / query summary
- `DayDetailApprovalSection.tsx` (opcional: tooltip «Comparació sobre remunerable» per mobile)

---

## 5. Tests SQL obligatoris

Fitxer nou: `supabase/tests/attendance_effective_time_mobile_tests.sql`

### 5.1 Fixture base — Lampista punch-only (Conveni C default)

Empleat `mobile_peripatetic`, flag ON, tz `Europe/Madrid`, dia fixture `2026-07-20`.

| Hora | Punch |
|------|-------|
| 06:45 | `day_start` |
| 08:00 | `in` |
| 12:00 | `break_start` (unpaid) |
| 12:30 | `break_end` |
| 16:30 | `out` |
| 17:30 | `day_end` |

**Esperat (policy default mobile = Conveni C):**

| Camp | Valor | Notes |
|------|-------|-------|
| `presence_minutes` | **645** | 06:45→17:30 (`day_start`→`day_end`) |
| `work_minutes` | **480** | Σ segments WORK |
| `travel_minutes` | **135** | 75 (casa→obra) + 60 (obra→casa) |
| `paid_minutes` | **615** | 480 work + 135 travel remunerat |
| `effective_minutes` | **480** | TRAVEL no efectiu (Conveni C) |
| `overtime_minutes` | **0** | |
| **`worked_minutes`** | **480** | **Net legacy** = 645 − 30 − 135 (§2.2); **mateix** que avui amb només `in`/`out` (510−30) |

Test **T1** ha d’assertar explícitament `worked_minutes = 480` i `presence_minutes = 645`.

### 5.2 Tres convenis (§18.4) — mateix timeline, polítiques diferents

| Test | Policy override | `paid` | `effective` | `overtime` |
|------|-----------------|--------|-------------|------------|
| T8a Conveni A | `TRAVEL.counts_paid=false`, `counts_effective=false` | 480 | 480 | 0 |
| T8b Conveni B | `TRAVEL.counts_paid=true`, `counts_effective=true` | 615 | 615 | 135\* |
| T8c Conveni C | default mobile | 615 | 480 | 0 |

\* T8b: fixar OT exacte al test segons `overtime_base=paid_minutes` i budget 480 → OT = 135.

### 5.3 Altres casos

| Cas | Assert |
|-----|--------|
| T1 | Fixture lampista §5.1 — `worked_minutes=480`, `presence_minutes=645`, `paid_minutes=615` |
| T9 | Flag OFF + mobile → buckets 0, `worked_minutes` inalterat |
| T10 | `day_start` sense `day_end` → `DAY_NOT_CLOSED`, consolidate skipped o provisional |
| T11 | Gap > 30 min entre `out` 16:30 i `day_end` 17:30 cobert per TRAVEL segment → **no** `UNCLASSIFIED_GAP` |
| T12 | `fixed_site` empleat → branca G2a no regressió (smoke: un assert) |

Policy JSON per test via `INSERT data.attendance_record_policies` scope `employee`.

---

## 6. Criteris de done

- [ ] Migració aplica en local
- [ ] Tests `attendance_effective_time_mobile_tests.sql` passen
- [ ] Flag OFF: zero canvi vs G1b
- [ ] Flag ON + mobile: buckets persistits; `paid ≠ effective` amb default policy
- [ ] Flag ON + mobile: **no** `awaiting_g2b` al meta
- [ ] `presence_minutes` = `day_start`→`day_end` (645 fixture); **`worked_minutes` = 480** (net §2.2, zero regressió vs in/out)
- [ ] E6 usa `paid_minutes` per mobile
- [ ] `get_payroll_review_days` inclou `paid_minutes`
- [ ] STATUS G2b ✅

---

## 7. Ordre d'execució

```text
1. data.sum_segment_minutes_by_kind + apply_activity_flags_to_buckets
2. consolidate_day_buckets branca mobile
3. Patch recompute (gross day_start/end + eliminar awaiting_g2b)
4. get_payroll_review_days paid_minutes
5. Tests SQL §18.4 + lampista
6. approvalAssistUtils E6 per perfil
7. database.types.ts (supabase gen types)
8. STATUS.md
```

---

## 8. Notes PR

**Títol:** `feat(attendance): Track G phase 2b — mobile_peripatetic punch-only consolidation`

**Test plan manual:**

1. Empleat `mobile_peripatetic`, flag OFF → mateix comportament que avui
2. Activar flag → jornada `day_start` … `day_end` amb `in`/`out`/pausa
3. Revisió nòmina: veure `effective_minutes` i `paid_minutes` diferents (Conveni C)
4. E6 confiança compara **remunerable** vs quota/budget
5. Empleat `fixed_site` → sense regressió G2a

**Després de G2b:** obrir [`prompt-track-g-phase-2c.md`](./prompt-track-g-phase-2c.md) (pendent crear) per `work_logs` + gaps.

---

*Fi del prompt — Track G Fase 2b*
