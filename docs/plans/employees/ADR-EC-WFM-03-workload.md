# ADR-EC-WFM-03 — Workload contractual

| Camp | Valor |
|------|--------|
| **Estat** | Acceptat |
| **Data** | 2026-07-21 |
| **Paquet** | EC-WFM P1 |
| **Decideix** | Base, prorrateig, arrodoniment i canvis a mig període |
| **Relacionats** | Annex §7 · §16.3 |

## Context

`weekly_hours` al contracte/empleat és insuficient per bases diàries/anuals i complement pactat.

## Decisió

1. **Taula 1:1** `employment_contract_workload_terms` — capacitat contractual, no assistència real.
2. **`commitment_basis`:** `day` | `week` | `year`.
3. **Minuts:** `ordinary_commitment_minutes` + `complementary_commitment_minutes` (complement ≠ overtime real; el saldo segueix a `time_compensation_ledger`).
4. **Base setmana:** `ordinary_commitment_minutes / 60` ha de ser coherent amb `employment_contracts.weekly_hours` (trigger de sync en draft; conflicte → `conflicts` al resolver si divergeix en actiu).
5. **Base dia/any:** el resolver **no** deriva `weekly_hours` sense calendari; exposa minuts + `weekly_hours` només si ve de fallback pla.
6. **Canvi material en actiu:** successor de contracte (immutable in-place); no esmena parcial de workload en fila activa.
7. **Arrodoniment (P1):** truncar a 2 decimals d'hores quan es projecta a `weekly_hours`; minuts enters a la taula.
8. **Prorrateig fi de període / baseline:** diferit a P2 (`resolve_employee_baseline_plan`).

## Conseqüències

- `resolve_employee_work_context.workload` inclou basis, ordinary/complementary minutes, fte_ratio i source.
- P2 afegirà finestres de balanç; P1 no crea segon ledger.
