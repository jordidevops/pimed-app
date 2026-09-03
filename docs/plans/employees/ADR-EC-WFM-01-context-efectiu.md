# ADR-EC-WFM-01 — Context efectiu i precedència

| Camp | Valor |
|------|--------|
| **Estat** | Acceptat |
| **Data** | 2026-07-21 |
| **Paquet** | EC-WFM P1 |
| **Decideix** | Dimensions del context efectiu, fallback legacy i errors |
| **Relacionats** | [`plan-employment-contracts-inspiracio-orquest.md`](./plan-employment-contracts-inspiracio-orquest.md) §4.2 · §16 |

## Context

P0 va introduir `resolve_employee_work_context`. P1 afegeix workload terms, leave terms/grants i placement periods. Cal congelar la precedència perquè els consumidors no tornin a llegir camps plans.

## Decisió

**Resolver canònic:** `data.resolve_employee_work_context(employee_id, work_date, requested_site_id?)`.

**Precedència per dimensió (efectiu):**

| Dimensió | 1r | 2n | 3r (fallback) |
|---|---|---|---|
| Contracte | Contracte efectiu a la data | — | Sense contracte → `employee_fallback` |
| Workload | `employment_contract_workload_terms` | `employment_contracts.weekly_hours` / `fte` | `employees.weekly_hours` |
| Placement | `employee_placement_periods` vigent `[inici,fi)` | Site/dept/job del contracte | Camps plans d'`employees` |
| Conveni/categoria | FKs del contracte | — | null |
| Leave policy | `employment_contract_leave_terms` | — | `vacation_entitlements` (projecció) |

**Errors:**

- Empleat inexistent → `NULL` (callers tracten com a unavailable).
- Site sol·licitat ≠ placement efectiu → `requested_site.eligible = false` (no excepció).
- Divergències contracte vs pla → `conflicts[]` informatiu, no bloqueig.

**Versió:** `resolver_version = ec_wfm_p1_v1` a partir de P1.

## Conseqüències

- Helpers `employee_effective_*` continuen delegant al resolver.
- Snapshots (§4.6) congelen el payload del resolver, no camps plans.
- No es llegeix Orquest ni es creen endpoints amb noms externs.
