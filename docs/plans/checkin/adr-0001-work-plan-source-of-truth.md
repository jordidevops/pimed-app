# ADR-0001 — Font de veritat de l'horari operatiu

| Camp | Valor |
|------|--------|
| **Estat** | Acceptat (caracterització congelada) |
| **Data** | 2026-07-16 |
| **Paquet** | EX-03.1 / SP-0 |
| **Decideix** | Cascada vigent, matriu de precedència i contracte objectiu de `resolve_employee_work_plan` |
| **Relacionats** | [`plan-shift-planner-v2.md`](./plan-shift-planner-v2.md) §4 · [`calendaris-laborals.md`](../../help/horaris/calendaris-laborals.md) · [`EXECUTION.md`](./EXECUTION.md) · [`adr-0003-weekly-recurring-base.md`](./adr-0003-weekly-recurring-base.md) (base recurrent viva, substitueix ADR-0002) |

---

## 1. Context

Abans de reactivar `work_schedules` o integrar `shift_slots` publicats al resolver, cal congelar el comportament **real** desplegat avui. Els tests `attendance_calendar_tests.sql` encara assumien el model Phase 1B (plantilla setmanal → `resolve_work_day`), desconnectat des de `20260730000001_resolve_work_day_labor_calendar.sql`.

Aquest ADR documenta:

1. quina RPC és la font de veritat d'assistència;
2. la cascada efectiva i el mapatge de tipus;
3. què queda legacy / desconnectat;
4. quins consumidors salten la capa d'absències;
5. el contracte JSON objectiu del resolver canònic V2.

---

## 2. Decisió

**Font de veritat d'assistència avui:** `api.resolve_work_day(employee_id, work_date)`.

Cadena interna efectiva (migració canònica `20260914000006`):

```
api.resolve_work_day
  → (absència aprovada | employee_day_overrides)
  → data.resolve_labor_calendar_for_employee
    → data.resolve_schedule_planner_day
```

**No consulta** `work_schedules`, `employee_schedule_assignments` ni `shift_slots`.

La UI d'horaris setmanals i el planificador de torns poden editar dades, però **no** canvien minuts esperats / `day_type` fins a EX-03.2–03.3.

---

## 3. Matriu de precedència (congelada)

### 3.1 Capes d'`api.resolve_work_day` (més prioritària → menys)

| Ordre | Font | Efecte |
|------:|------|--------|
| 0a | `employee_absences` (`status = approved`) | `day_type = absence`; minuts de referència des del calendari si el dia base és `work` |
| 0b | `employee_day_overrides` | `force_holiday` → `holiday` immediat; `force_work` → salta festius assignats i continua |
| 1…6 | Cascada laboral (§3.2) | Via `resolve_labor_calendar_for_employee` |

### 3.2 Cascada laboral (`resolve_schedule_planner_day`)

Ordre de resolució (primera coincidència guanya):

| Ordre | Capa | Taula / origen |
|------:|------|----------------|
| 1 | Override empleat | `labor_calendar_overrides` (`employee_id`) |
| 2 | Grup al local | `labor_calendar_overrides` (`group_id` + `site_id`) |
| 3 | Override local | `labor_calendar_overrides` (`site_id`, sense grup/empleat) |
| 4 | Patró grup global | `labor_calendar_overrides` (`group_id`, `site_id` NULL) |
| 5 | Override empresa | `labor_calendar_overrides` (només `tenant_id`) |
| 6 | Festiu assignat | `holiday_calendars` / `holidays` via `planner_site_holidays` |
| 7 | Base recurrent empleat (ADR-0003) | `employee_weekly_intervals`, per `day_of_week` |
| 8 | Base recurrent grup (ADR-0003) | `calendar_group_weekly_intervals`, per `day_of_week` |
| 9 | Implicit | `labor_day_type = undefined` → API `day_type = unknown`, 0 minuts |

> Des d'[ADR-0003](./adr-0003-weekly-recurring-base.md), les capes 7–8 substitueixen la cascada "sense capa `weekly_schedule` viva" descrita a §5/§9 (ADR-0002): ara sí hi ha una base recurrent viva, però consultada en directe (sense materialitzar overrides) i sempre per sota del festiu assignat.

### 3.3 Mapatge de tipus

| `labor_day_type` | `day_type` API | `expected_minutes` |
|------------------|----------------|-------------------|
| `work` | `working` | `planned_minutes` |
| `holiday` | `holiday` / `half_holiday` | 0 |
| `vacation`, `leave` | `non_working` | 0 |
| `undefined` | `unknown` | 0 |

Valors API observats: `working` \| `non_working` \| `holiday` \| `half_holiday` \| `absence` \| `unknown`.

### 3.4 Timezone

`site_timezone` surt de `data.get_site_timezone(site_id, tenant_id)` amb fallback `Europe/Madrid`. La data `p_work_date` és una **data de calendari**, no un instant UTC: el resolver no reinterpreta el dia amb TZ; la TZ s'exposa als consumidors (punches, recordatoris).

### 3.5 Torn nocturn

Intervals amb `end <= start` (p. ex. `22:00`–`06:00`) marquen `spans_midnight = true` via `labor_intervals_shift_bounds`. Els minuts es calculen sumant 24 h al final.

---

## 4. Inventari RPC / helpers efectius

| Funció | Rol | Usa `work_schedules`? | Usa `shift_slots`? |
|--------|-----|----------------------|--------------------|
| `api.resolve_work_day` | Contracte assistència (recompute, export, portal, recordatoris) | No | No |
| `data.resolve_labor_calendar_for_employee` | Pont empleat → planner day | No | No |
| `data.resolve_schedule_planner_day` | Cascada overrides + festius | No | No |
| `data.planner_site_holidays` | Festius efectius del site | — | — |
| `api.request_absence` / `approve_absence` | Escriptura absències | — | — |
| `api.import_holidays` | Import Nager.Date | — | — |
| Vistes `work_schedules` / intervals | CRUD plantilles setmanals | Sí (emmagatzematge) | — |

Suite de caracterització: `supabase/tests/attendance_calendar_tests.sql` (SP-0).

---

## 5. Legacy: `work_schedules` i `employee_schedule_assignments`

| Observació (BD local demo, 2026-07-16) | Valor |
|----------------------------------------|-------|
| Files `work_schedules` | 6 |
| Files `employee_schedule_assignments` | 50 |
| Files `labor_calendar_overrides` | ~2600 (seed Acme) |
| Files `employee_day_overrides` | 0 |

**Conclusió SP-0:** hi ha dades reals d'assignació setmanal al seed/demo, però el resolver les **ignora**. La UI d'horaris era editable i engañosa respecte a minuts esperats.

**Decisió EX-03.2 (superseded):** opció B — veure [`adr-0002-work-schedules-option-b.md`](./adr-0002-work-schedules-option-b.md).

- SoT setmanal = `labor_calendar_overrides` + `apply_weekly_pattern_to_calendar`
- Escriptura API revocada; helper one-way `convert_work_schedule_assignments_to_labor_calendar`

**Decisió EX-03.3 (vigent):** [`adr-0003-weekly-recurring-base.md`](./adr-0003-weekly-recurring-base.md) reemplaça l'opció B.

- SoT setmanal = base recurrent viva (`calendar_group_weekly_intervals` + `employee_weekly_intervals`), consultada per `day_of_week` directament al resolver — sense materialitzar overrides.
- `work_schedules`, `work_schedule_intervals`, `employee_schedule_assignments` i el helper de conversió: **eliminats** (no només congelats).
- `api.apply_weekly_pattern_to_calendar` es manté només per excepcions puntuals per rang de dates.

---

## 6. `employee_day_overrides`

Encara llegits per `resolve_work_day` (`force_holiday` / `force_work`). Paral·lels als overrides d'empleat a `labor_calendar_overrides`.

**Decisió:** migrar i retirar a EX-03.3+ (sense dos editors d'excepcions individuals). Fins aleshores, la caracterització els manté a la matriu §3.1.

---

## 7. Consumidors que eviten `resolve_work_day`

**EX-03.6 ✅:** `api.get_today_dashboard_rows` ja usa `data.resolve_employee_work_plan` (absències i slots published respectats).

`api.get_schedule_planner_days` continua amb `data.resolve_schedule_planner_day` a propòsit (vista laboral del planificador de calendaris; sense capa d'absència).

Portal, export, recordatoris i recompute ja usaven `api.resolve_work_day`.

`shift_slots` **published** entren a `data.resolve_employee_work_plan` (EX-03.3 ✅): substitueixen intervals quan el dia base és `work` o `undefined`; **no** converteixen `holiday`/`vacation`/`leave` en work. Ubicació per interval: `location_id` / name / path snapshots als slots (EX-03.4 ✅ / ST-19 schema).

---

## 8. Contracte JSON objectiu — `data.resolve_employee_work_plan`

Funció de domini canònica (EX-03.3). `api.resolve_work_day` ha d'esdevenir un adaptador estable sobre aquest contracte.

```json
{
  "employee_id": "uuid",
  "work_date": "YYYY-MM-DD",
  "site_timezone": "Europe/Madrid",
  "day_type": "working|non_working|holiday|half_holiday|absence|unknown",
  "labor_day_type": "work|holiday|vacation|leave|undefined",
  "labor_source": "employee_override|group_site|site|group_global|tenant|assigned_holiday|weekly_schedule|published_shift|absence|employee_day_override|undefined",
  "expected_minutes": 0,
  "spans_midnight": false,
  "work_intervals": [{ "start": "HH:MM", "end": "HH:MM", "location_id": null, "role_id": null }],
  "shift_start_time": "HH:MM:SS|null",
  "shift_end_time": "HH:MM:SS|null",
  "schedule_id": "uuid|null",
  "schedule_name": "string|null",
  "published_slot_ids": [],
  "is_holiday": false,
  "holiday_name": null,
  "is_absence": false,
  "absence_id": null,
  "absence_type": null,
  "absence_counts_as_worked": false,
  "location_id": null,
  "employee_override": false
}
```

Regles V2 (ajustades per [ADR-0003](./adr-0003-weekly-recurring-base.md), que reemplaça ADR-0002 / EX-03.2 opció B):

1. Base: `labor_calendar_overrides` (puntual) → festiu assignat → base recurrent viva (`employee_weekly_intervals` / `calendar_group_weekly_intervals`). *Sense* `work_schedules`, que s'ha eliminat.
2. Festius assignats guanyen a la base recurrent (mateixa jerarquia §3.2).
3. `shift_slots` **published** substitueixen intervals del dia (draft mai).
4. Absència aprovada anul·la/retalla obligació (prioritat màxima d'incidència).
5. Un slot publicat no converteix sol un `holiday`/`vacation`/`leave` en `work`.

---

## 9. Cascada objectiu V2 (referència)

```
0. Absència aprovada (total/parcial)
1–5. Overrides puntuals (tenant → … → empleat)
6. Festiu assignat
7–8. Base recurrent setmanal (grup → empleat, ADR-0003)
9. shift_slots published
```

*(ADR-0002 va rebutjar `work_schedules` com a base viva; ADR-0003 la substitueix per una nova base recurrent — grup + empleat — consultada en directe, sense materialitzar overrides.)*

---

## 10. Conseqüències

| Acció | Paquet |
|-------|--------|
| Tests `attendance_calendar_tests.sql` alineats amb labor calendar | EX-03.1 ✅ |
| Decisió executable A/B sobre `work_schedules` | EX-03.2 ✅ opció B ([ADR-0002](./adr-0002-work-schedules-option-b.md), superseded) |
| Base recurrent setmanal (grup + empleat), retirada d'opció B | EX-03.2-bis ✅ ([ADR-0003](./adr-0003-weekly-recurring-base.md)) |
| Implementar `resolve_employee_work_plan` + adaptar `resolve_work_day` | EX-03.3 ✅ |
| Schema ST-19 (ubicació, snapshots) | EX-03.4 ✅ |
| Recompute idempotent en canvis de slots published | EX-03.5 ✅ |
| Migrar dashboards que salten absències | EX-03.6 ✅ |
| Dual-run / feature flag i backfill | EX-03.7 ✅ |

**Rollback d'aquest ADR:** cap canvi de schema; només documentació + tests. Revertir els fixtures de test restaura el desalineament conegut (BL-03/BL-04).
