# ADR-0002 — Decisió `work_schedules`: opció B (congelar + calendari laboral)

| Camp | Valor |
|------|--------|
| **Estat** | **Superseded** per [`adr-0003-weekly-recurring-base.md`](./adr-0003-weekly-recurring-base.md) |
| **Data** | 2026-07-16 |
| **Paquet** | EX-03.2 |
| **Supersedeix / completa** | [`adr-0001`](./adr-0001-work-plan-source-of-truth.md) §5 (decisió diferida) |
| **Decisió** | **Opció B** — no reactivar `work_schedules` al resolver (ARA ELIMINAT, no només congelat — veure ADR-0003) |

---

## 1. Pregunta

Després de SP-0 (EX-03.1), calia triar:

| Opció | Acció |
|-------|--------|
| **A** | Reactivar `work_schedules` + `employee_schedule_assignments` com a capa base sota festius/overrides |
| **B** | Retirar/congelar la UI i API d'escriptura; SoT setmanal = `labor_calendar_overrides` (+ `apply_weekly_pattern_to_calendar`); conversió one-way opcional |

El pla V2 preferia A; l'escape hatch de §4.3 permetia B si les dades de plantilla no són fiables com a SoT.

---

## 2. Evidència

| Fet | Detall |
|-----|--------|
| Resolver des de `20260730` | `resolve_work_day` **no** llegeix `work_schedules` (ADR-0001 T0) |
| UI d'edició | Tab «Horaris de treball» a `LaborCalendarSetupPage` **no està muntada** (`PlanificacioPage` només `onlyTab="holidays"`) |
| Assignació empleat↔schedule | Hook `useEmployeeScheduleAssignments` sense callers de UI |
| UX setmanal real | `WeeklyPatternPanel` → `api.apply_weekly_pattern_to_calendar` → overrides diaris |
| Seed Acme | ~50 assignments + ~2600 labor overrides (doble via); labor cobreix grups |
| Reactivar A sobre Acme | Overrides guanyen → patró setmanal seria **no-op** fins a podar milers de files |

Conclusió: `work_schedules` és legacy dual i engañós; el producte ja opera amb calendari laboral materialitzat.

---

## 3. Decisió

**Opció B.**

1. **SoT setmanal / per data:** `labor_calendar_overrides` + festius (+ absències a `resolve_work_day`).
2. **Congelar** escriptura API: `REVOKE INSERT/UPDATE/DELETE` sobre `api.work_schedules`, `api.work_schedule_intervals`, `api.employee_schedule_assignments` (SELECT roman).
3. **Helper** `api.convert_work_schedule_assignments_to_labor_calendar` — expansió one-way només on el dia encara és `undefined`; `dry_run=true` per defecte; no pisa overrides ni festius.
4. **Seed punches** Acme llegeix intervals via `resolve_labor_calendar_for_employee`.
5. **UI:** eliminar pestanya/CRUD orphaned de plantilles setmanals; documentar patró setmanal al calendari.
6. **EX-03.3:** cascada canònica **sense** capa `weekly_schedule` viva. El camp `labor_source` / contracte pot ometre `weekly_schedule` o marcar-lo `deferred_legacy`. Reintroduir plantilles compactes requeriria ADR nou (un sol model d'assignació).

---

## 4. Per què no A ara

- Cost de reconciliació seed/overrides sense guany producte (UI setmanal ja existeix via labor).
- Dos models d'assignació (`employee_schedule_assignments` vs `calendar_group_id`) quedarien vius.
- Mantindria taules editables «amb efecte» només després d'un purge arriscat.

---

## 5. Migració

`supabase/migrations/20261016000001_work_schedules_ex032_option_b.sql`

**Rollback:** re-GRANT escriptura + restaurar seed punches anterior; no canvia el resolver (ja ignorava schedules).

---

## 6. Conseqüències

| Paquet | Impacte |
|--------|---------|
| EX-03.3 | `resolve_employee_work_plan` sense base `work_schedules` |
| EX-03.6 | Dashboards → `resolve_work_day` (sense canvi per aquesta decisió) |
| Help | `calendaris-laborals.md` — plantilles setmanals marcades legacy |

**Acceptable:** taules físiques romanen (lectura, tests T0/T11, conversió). **No acceptable:** UI o API d'escriptura reconnectades sense ADR.
