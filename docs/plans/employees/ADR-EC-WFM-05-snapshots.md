# ADR-EC-WFM-05 — Snapshots de context

| Camp | Valor |
|------|--------|
| **Estat** | Acceptat |
| **Data** | 2026-07-21 |
| **Paquet** | EC-WFM P0 §4.6 / P1 |
| **Decideix** | Camps congelats, versió del resolver i esmenes |
| **Relacionats** | Annex §4.6 · §16.5 |

## Context

Els resums diaris no poden recalcular-se amb polítiques posteriors un cop tancats/bloquejats.

## Decisió

1. **Suport:** `time_daily_summaries.work_context_snapshot`, `employment_contract_id`, `resolver_version`, `work_context_frozen_at`.
2. **Contingut mínim del snapshot:** contract_id, workload, placement, calendar, convenio_categoria, policies stub, resolver_version, captured_at.
3. **Ciclo de vida:** refresca mentre no està frozen; en `payroll_locked_at` (o freeze explícit) queda immutable.
4. **Esmena:** només amb GUC `data.work_context_amendment=1` (+ auditoria futura); mai recompute silenciós.
5. **Versió:** el camp `resolver_version` del snapshot és el del resolver en el moment de captura (`ec_wfm_p1_v1`+).

## Conseqüències

- Correccions de període tancat = esmena / moviment compensatori, no rewrite opac.
- P2 podrà ampliar snapshots de balanç; no es crea magatzem paral·lel.
