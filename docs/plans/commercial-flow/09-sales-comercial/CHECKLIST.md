# Checklist mestre — Comercial /sales (pla 09)

> Marcar `[x]` només quan el **DoD** de la fase estigui complert.  
> Detall: arxius `00`…`07` d’aquest directori · índex [`README.md`](./README.md)  
> **Actualització implementació:** 2026-10-03

| Fase | Fitxer | Estat | Data tancament | Notes |
|------|--------|-------|----------------|-------|
| 0 Bugs modal | [`00-fase0-bugs-modal.md`](./00-fase0-bugs-modal.md) | [x] | 2026-10-02 | `commercialErrorMessage`, modal reset/etiquetes/total RO |
| 1A Invoice core | [`01a-fase-invoice-core.md`](./01a-fase-invoice-core.md) | [x] | 2026-10-03 | Migracions local; emetre amb sèrie + Ref. ERP opcional |
| 1B Payment ledger | [`01b-fase-payment-ledger.md`](./01b-fase-payment-ledger.md) | [x] | 2026-10-03 | Tests SQL PASS |
| 2 Security + routes | [`02-fase-security-routes.md`](./02-fase-security-routes.md) | [x] | 2026-10-02 | `/sales/*`, nav Comercial, preset Gestoria |
| 3 Numbering + FY | [`03-fase-numbering-fiscal.md`](./03-fase-numbering-fiscal.md) | [x] | 2026-10-03 | Preview al modal; Settings FY |
| 4 Sales tables | [`04-fase-sales-tables.md`](./04-fase-sales-tables.md) | [x] | 2026-10-03 | Keyset + KPI dashboard |
| 5 Gestoria + export | [`05-fase-accountant-exports.md`](./05-fase-accountant-exports.md) | [x] | 2026-10-03 | ZIP client (PizZip) |
| 6 Detail + render | [`06-fase-detail-render.md`](./06-fase-detail-render.md) | [x] | 2026-10-03 | Fitxes + PDF invoice |
| 7 Tests + docs | [`07-fase-tests-scale-docs.md`](./07-fase-tests-scale-docs.md) | [x] | 2026-10-03 | Types regenerats; SQL/TS verds; UAT oficina/gestoria/camp |

## Gates ràpids

1. **Després de 0:** toasts llegibles; modal net. ✅
2. **Després de 1A:** factures natives; link = font de veritat. ✅
3. **Després de 1B:** retry de cobrament no duplica. ✅
4. **Després de 2:** RPC sense permís fallida; `/sales` viu. ✅
5. **Després de 3:** números atòmics; exercici tanca mutacions. ✅
6. **Després de 4:** llistes sense `delivery_balances(NULL)`. ✅
7. **Després de 5:** gestoria exporta paquet canònic. ✅
8. **Després de 6:** URLs de fitxa + badges etiquetats. ✅
9. **Després de 7:** docs + types + tests SQL. ✅ — UAT navegador OK

## Pendent operatiu

- (Opcional) edició write de patrons de sèrie; adaptadors ERP
- (Opcional) selecció radio a Comptabilitat (Marcar revisat) si cal millorar UX
- (**Diferit**) EXPLAIN escala; UAT anul·lar factura / tancar exercici
- (**Ops**) després de `000011`: re-login members perquè el JWT perdi `invoices.edit` base

## Epic

**CF-27** — Comercial `/sales`. Log: [`IMPLEMENTATION-LOG.md`](./IMPLEMENTATION-LOG.md)
