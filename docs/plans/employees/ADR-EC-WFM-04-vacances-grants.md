# ADR-EC-WFM-04 — Vacances i grants

| Camp | Valor |
|------|--------|
| **Estat** | Acceptat |
| **Data** | 2026-07-21 |
| **Paquet** | EC-WFM P1 |
| **Decideix** | Grants, ajustos, consum, cancel·lació i períodes tancats |
| **Relacionats** | Annex §8 · §4.1 · §16.4 |

## Context

P0 va corregir el consum sobre un sol `vacation_entitlements` efectiu. P1 afegeix política al contracte i grants append-only.

## Decisió

1. **Política 1:1:** `employment_contract_leave_terms` (allowance, unitat, counting, proration).
2. **Moviments:** `leave_entitlement_grants` append-only amb `idempotency_key` per tenant.
3. **Activació / substitució / finalització:** generen grants (P1: activació amb prorrateig `calendar_ratio` o `none`; substitució/finalització mínimes amb clau idempotent).
4. **Ajustos manuals:** files grant amb `reason` / `source_event = 'manual_adjustment'` — mai UPDATE d'un grant existent.
5. **Consum:** continua via absències + trigger P0 sobre `vacation_entitlements` (projecció dual-read).
6. **Saldo lògic:** `sum(grants) − consum_efectiu`; UI pot mostrar grants + projecció.
7. **Períodes tancats:** no es regeneren grants silenciosament per dies amb `payroll_locked_at`; esmenes amb GUC/audit (alineat §4.6).
8. **Festius:** no entren a leave terms; romanen al calendari laboral.

## Conseqüències

- `vacation_entitlements` no desapareix a P1.
- Consum no escriu grants; només decrementa la projecció.
