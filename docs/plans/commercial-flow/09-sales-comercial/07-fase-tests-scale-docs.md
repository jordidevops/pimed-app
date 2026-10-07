# Fase 7 — Proves, escala, UAT i documentació

> **Ordre:** 7 · **Depèn de:** fases 0–6 (com a mínim el que s’hagi mergejat)  
> **Índex:** [`README.md`](./README.md)  
> **Tancada:** 2026-10-03

## Objectiu

Tancar el pla amb proves de regressió, concurrència, multi-tenant, escala, UAT i docs alineades amb el producte real.

## Regeneració types

- [x] Regenerar `apps/tenant-portal/src/types/database.types.ts` des del schema final.
- [x] Compilar tenant-portal sense errors de RPC.

## Suite SQL

- [x] `sales_invoice_core_tests.sql`
- [x] `sales_payment_allocations_tests.sql`
- [x] `sales_preview_number_tests.sql` (numeració / preview)
- [x] `sales_list_pages_tests.sql` (keyset)
- [x] `sales_accountant_exports_tests.sql` (export canònic + gestoria)
- [x] `sales_dashboard_kpis_tests.sql`

Casos coberts a les suites anteriors (PASS local):

- [x] Draft → issue; DN/OS mateix client
- [x] Total/impostos coherents
- [x] Cancel / link `released_at`
- [x] Retry payment idempotent
- [x] Gestoria: review/export OK; edit/pay/cancel forbidden (RPC asserts)
- [x] Export paquet + finalize

## Suite TS

- [x] `commercialErrorMessage`
- [x] Nav aliases + `navigationReturn` / `resolveNav`
- [x] `sessionAppMetadata` (claims JWT)
- [x] `buildCommercialDocumentHtml` (invoice)

## Escala (diferit / opcional)

- [ ] Fixture gran + `EXPLAIN` → `perf-notes.md` (**diferit**; no bloqueja V1 ni bugfix `000011`)

## UAT humana

### Oficina

- [x] Facturar selecció DN → fitxa factura → PDF → cobrar → saldos
- [x] Anul·lar factura sense pagaments → DN tornen a per facturar (2026-10-06 Gina: `A-2026-9001` → `F-2026-0001` cancelled; hub **Per facturar**)
- [x] Tancar exercici → bloqueig mutacions (2026-10-06: tancar 2026 → Settings **Tancat**; emetre no va crear `F-2026-0002`; **Reobrir** → **Obert**, `reopened_at` set; no deixar l’any tancat)

### Camp

- [x] Home camp; sense `/sales` per defecte després de `000011` (member base sense `invoices.*`; cal re-login JWT)
- [x] Sense Comptabilitat
- [x] Cobrament DN a l’OS (no depèn de `invoices.*`)

### Gestoria

- [x] Login membre gestoria (Eve viewer + preset)
- [x] Comptabilitat visible; sense Cobrar/Anul·lar
- [x] Claims JWT via `getSessionAppMetadata`

## Documentació a actualitzar

- [x] [`07-collections-and-ar-hub.md`](../07-collections-and-ar-hub.md): apuntar a pla 09 com a font Comercial `/sales`
- [x] [`07b-albara-out-of-scope.md`](../07b-albara-out-of-scope.md): què ha entrat a CF-27
- [x] [`STATUS.md`](../STATUS.md): CF-27 ✅
- [x] [`EXECUTION.md`](../EXECUTION.md): fase activa → CF-26 UAT
- [x] [`README.md`](../README.md): taula docs
- [x] [`04-phases-and-backlog.md`](../04-phases-and-backlog.md): enllaç CF-27 ✅
- [x] [`CHECKLIST.md`](./CHECKLIST.md) + [`IMPLEMENTATION-LOG.md`](./IMPLEMENTATION-LOG.md)

## DoD global del pla 09

- [x] Totes les fases 0–7 [x] al [`CHECKLIST.md`](./CHECKLIST.md)
- [x] Suites SQL/TS verdes
- [x] UAT 3 perfils OK
- [x] Docs alineades
- [x] Cap promesa «compatible Sage» sense adaptador
