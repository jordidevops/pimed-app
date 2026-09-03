# ADR-0003 — Base recurrent setmanal (grup + empleat), reemplaça opció B

| Camp | Valor |
|------|--------|
| **Estat** | Acceptat |
| **Data** | 2026-07-16 |
| **Paquet** | EX-03.2-bis (reobre EX-03.2) |
| **Supersedeix** | [`adr-0002-work-schedules-option-b.md`](./adr-0002-work-schedules-option-b.md) |
| **Relacionats** | [`adr-0001-work-plan-source-of-truth.md`](./adr-0001-work-plan-source-of-truth.md) · [`plan-shift-planner-v2.md`](./plan-shift-planner-v2.md) §4.3 · [`calendaris-laborals.md`](../../help/horaris/calendaris-laborals.md) |

---

## 1. Per què es revisa ADR-0002

ADR-0002 va triar l'opció B: SoT setmanal = `labor_calendar_overrides`, alimentat per `api.apply_weekly_pattern_to_calendar`. Aquesta funció no defineix un patró viu: **explota** el patró en files concretes any per any (`p_year`; vegeu `supabase/migrations/20260804000001_weekly_pattern_skip_assigned_holidays.sql`). Canviar l'horari habitual d'un grup a partir d'una data futura implica un `UPDATE`/`DELETE` massiu sobre milers de files — exactament el que el pla V2 volia evitar.

Amb l'entorn de dev permetent `supabase db reset` lliurement, els arguments originals d'ADR-0002 (seed dual conflictiu, UI òrfena) deixen de pesar per se. Però reactivar `work_schedules` + `employee_schedule_assignments` tal com estaven dissenyades introduiria una dualitat d'assignació real amb `employee.calendar_group_id` (ja consumit per la cascada). Aquesta dualitat és un problema de disseny, no de migració.

**Decisió:** una única font d'assignació (`calendar_group_id`, ja existent), amb una nova capa de **recurrència** consultada en viu pel resolver — sense taules `work_schedules` separades i sense materialització massiva.

---

## 2. Disseny de la nova capa

Base recurrent a nivell de **grup de calendari**, amb possibilitat d'**override recurrent a nivell d'empleat individual**.

Noves taules (`supabase/migrations/20261017000001_weekly_recurring_base_adr0003.sql`):

- `data.calendar_group_weekly_intervals`: `id, tenant_id, group_id (FK calendar_groups), day_of_week (0=diumenge…6=dissabte, EXTRACT(DOW)), day_type ('work'|'non_working'), work_start, work_end, work_intervals (jsonb), valid_from, valid_to, created_at, updated_at`.
- `data.employee_weekly_intervals`: mateixa forma però `employee_id (FK employees)` en lloc de `group_id`. És la capa "override individual recurrent", per sobre del grup i per sota dels overrides puntuals de `labor_calendar_overrides`.
- Índexs per `(group_id, day_of_week)` i `(employee_id, day_of_week)`. `valid_from`/`valid_to` (SCD tipus 2) permeten canvis futurs sense esborrar historial ni tocar files passades.
- RLS: lectura per membres del tenant amb `attendance.view_all`/pertinença; escriptura amb `labor_calendar.manage`.
- Vistes `api.calendar_group_weekly_intervals` / `api.employee_weekly_intervals` (només lectura ampla) i RPCs `api.set_calendar_group_weekly_day`, `api.clear_calendar_group_weekly_day`, `api.set_employee_weekly_day`, `api.clear_employee_weekly_day`, `api.get_calendar_group_weekly_pattern`, `api.get_employee_weekly_pattern` per al CRUD "replace-all per `(entitat, day_of_week)` a partir d'una data".

## 3. Integració al resolver

`data.resolve_schedule_planner_day` (`supabase/migrations/20260729000001_schedule_planner_rpc.sql`, redefinida a `20261017000001_weekly_recurring_base_adr0003.sql`) queda així (primera coincidència guanya):

```
1. employee_override        (labor_calendar_overrides, employee_id)       — puntual
2. group_site_override       (labor_calendar_overrides, group+site)        — puntual
3. site_override              (labor_calendar_overrides, site)              — puntual
4. group_global_override     (labor_calendar_overrides, group)             — puntual
5. tenant_override            (labor_calendar_overrides, tenant)            — puntual
6. assigned_holiday           (holiday_calendars / holidays)
7. NOU: employee_weekly       (employee_weekly_intervals, per day_of_week) — base recurrent
8. NOU: calendar_group_weekly (calendar_group_weekly_intervals, per day_of_week) — base recurrent
9. undefined                  (implícit)
```

Decisions explícites de precedència:

- Les capes puntuals (`labor_calendar_overrides`) sempre guanyen — són el mecanisme d'excepció (dia concret diferent del patró habitual).
- **Un festiu assignat guanya a la base recurrent** (capa 6 abans de 7/8): si un grup té dilluns com a laborable al patró setmanal però aquell dilluns concret és festiu oficial, el dia resol a `holiday`. Només un override puntual (`labor_calendar_overrides` amb `day_type='work'` aquell dia, o `force_work` via `employee_day_overrides` a la capa superior d'`api.resolve_work_day`) pot tornar-lo a laborable.
- `employee_weekly` guanya a `calendar_group_weekly`: l'override individual recurrent és més específic que el del grup, igual que `employee_override` puntual guanya a `group_*_override` puntual.
- `data.resolve_labor_calendar_for_employee` no canvia de contracte — ja delega a `resolve_schedule_planner_day`.

## 4. Retirada de l'opció B (reversió d'EX-03.2)

Migració `supabase/migrations/20261017000002_drop_work_schedules_adr0003.sql`:

- `DROP` de `data.work_schedules`, `data.work_schedule_intervals`, `data.employee_schedule_assignments` i les seves vistes `api.*` (amb `CASCADE` sobre triggers `INSTEAD OF`).
- `DROP FUNCTION api.convert_work_schedule_assignments_to_labor_calendar` (helper one-way d'ADR-0002, ja no té sentit).
- `api.apply_weekly_pattern_to_calendar` **es manté** per a excepcions temporals per rang de dates (vacances d'estiu, horari especial de Nadal) — no per definir l'horari habitual, que ara viu a la base recurrent. Per a rangs curts no pateix el problema d'explosió massiva.

## 5. Seed de dades

`supabase/seeds/attendance_demo.sql` substitueix el seed antic de `work_schedules`/`employee_schedule_assignments` (~6 files + ~50 assignments, ja no existeixen) i simplifica dràsticament el seed massiu d'overrides:

- `data.calendar_group_weekly_intervals` per als grups Acme (Oficina, Taller Gràcia, Obres Sants): Dl–Dv laborable, Ds–Dg no laborable, amb els seus horaris respectius (continu / partit).
- `data.employee_weekly_intervals` per a un subconjunt d'empleats amb horari individual (p. ex. Cap d'obra, Administrativa a Sants).
- Ja no es crida `data.seed_acme_labor_calendar_weekly_base()`: el patró es consulta en viu, no calen ~2600 files de `labor_calendar_overrides` materialitzades per any.

## 6. UI

- `LaborCalendarSetupPage.tsx`: el tab «Horaris de treball» ja es va netejar a EX-03.2; no es reverteix (no es torna a l'UI antiga de `work_schedules`).
- Nou component `apps/tenant-portal/src/features/attendance/components/WeeklyRecurringBaseEditor.tsx`: editor per dia de la setmana (laborable/no laborable + franges via `WorkIntervalsEditor`), reutilitzable per grup i per empleat. CRUD directe sobre les noves taules via els hooks `use{Set,Clear}{CalendarGroupWeeklyDay,EmployeeWeeklyDay}` (`api/useShifts.ts` / `api/shiftsService.ts`) — no materialitza files.
- Muntat a `PlanificacioPage.tsx` (pestanya «Grups» → grup seleccionat → secció collapsable «Patró setmanal recurrent») i a `EmployeeLaborCalendarView.tsx` (pestanya «Calendari laboral» de fitxa d'empleat, amb `canWrite`, → secció collapsable «Patró setmanal individual»).
- `WeeklyPatternPanel` (dins `LaborCalendarGrid.tsx`) es manté per aplicar excepcions puntuals per rang (crida `apply_weekly_pattern_to_calendar` / `upsert_labor_calendar_days`), conceptualment diferent de l'horari habitual.

## 7. Tests i documentació

- `supabase/tests/attendance_weekly_recurring_base_adr0003_tests.sql` (nou): 9 tests dedicats de precedència — base de grup, `non_working` explícit, `employee_weekly` > `calendar_group_weekly`, override puntual > `employee_weekly`, festiu assignat > base recurrent (ambdues capes), sense patró → `undefined`, efecte temporal de `valid_from`, permisos d'escriptura (`labor_calendar.manage`), i reflex al resolver després d'escriure via RPC de manager.
- `supabase/tests/attendance_calendar_tests.sql`: fixtures T0/T11 adaptades a les noves taules (`calendar_group_weekly` alimenta el resolver; `employee_weekly` guanya al grup).
- `supabase/tests/attendance_work_schedules_ex032_tests.sql`: eliminat (assumia taules que ja no existeixen).

## 8. Conseqüències

| Paquet | Impacte |
|--------|---------|
| ADR-0001 §5/§9 | Referències a ADR-0002 actualitzades per apuntar aquí |
| `plan-shift-planner-v2.md` §4.3 | Actualitzat: la base recurrent viva substitueix la reactivació literal de `work_schedules` |
| Help (`calendaris-laborals.md`) | Nova secció "Patró setmanal recurrent" |
| EXECUTION.md | Paquet EX-03.2-bis marcat com a fet |

**Acceptable:** `api.apply_weekly_pattern_to_calendar` roman per excepcions puntuals per rang. **No acceptable:** reintroduir una taula d'assignació setmanal separada de `calendar_group_id` sense ADR nou.
