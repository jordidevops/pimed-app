# Fase 1B — Cobrament idempotent i ledger d’imputacions

> **Ordre:** 1B · **Depèn de:** 1A · **Bloqueja:** 4 (saldos llista), 5 (export payments), 6 (fitxa cobraments)  
> **Índex:** [`README.md`](./README.md)

## Objectiu

Un pagament de factura és una sola operació lògica auditable. El FIFO als albarans es desa a `payment_allocations`. Retries no dupliquen diners.

## Decisions

S-D6, S-D7. Això **obre** el ledger d’imputacions que CF-26 havia deixat fora ([`07b`](../07b-albara-out-of-scope.md) §3 actualitzat).

## Problema actual

`record_invoice_payment` (migració `000005`) crea diverses files `payments` sobre DN amb `client_op_id` només a la primera; la resta usa `gen_random_uuid()` → retry parcial = sobrecobrament possible.

## Esquema

- [ ] Taula `data.payment_allocations`:
  - `id`, `tenant_id`, `payment_id` → `payments`, `delivery_note_id` → `commercial_documents`, `amount_cents > 0`, `position int`, `created_at`
  - Unique `(tenant_id, payment_id, delivery_note_id)` o `(payment_id, position)`
  - Índex `(tenant_id, delivery_note_id)`
- [ ] Regla: pagament de factura té `payments.document_id = invoice_id` (`doc_type=invoice`).
- [ ] Les allocations **no** creen pagaments addicionals sobre el DN.
- [ ] Migrar slices antics (si n’hi ha): consolidar o mapar a payment+allocations (script + tests).

## RPCs

- [ ] Reescriure `api.record_invoice_payment(p_invoice_id, p_amount_cents, p_method, p_occurred_at, p_client_op_id, …)`:
  - `active_tenant_id` + permís (Fase 2 pot completar; mentrestant membership + tenant).
  - Lock invoice + DN enllaçats (UUID ordenats).
  - Idempotència: si `client_op_id` existeix → retornar mateix JSON.
  - Insert **un** `payments` sobre la factura.
  - FIFO: omplir `payment_allocations` fins esgotar import o remaining.
  - Rebutjar `payment_exceeds_remaining`.
- [ ] `api.record_payment` (DN/quote):
  - No accepta `doc_type=invoice`.
  - Rebutja DN amb link factura actiu.
- [ ] Actualitzar `data.delivery_balances`:
  - Incloure sumes d’allocations cap al DN.
  - **No** comptar alhora el pagament de factura i les seves allocations (evitar doble resta).

## Saldos derivats (factura)

Documentar i implementar a RPC de detall/llista:

| Camp | Fórmula |
|------|---------|
| `invoice_total_cents` | total document |
| `remaining_cents` | `SUM(remaining)` DN amb link actiu |
| `collected_cents` | `invoice_total − remaining` |
| `collected_via_dn_cents` | cobraments DN + bestretes aplicades (derivats) |
| `collected_via_invoice_cents` | `SUM(payments.amount)` on `document_id=invoice` |

Estats cobrament: `pending` \| `partial` \| `paid` (derivats).

## Proves SQL

- [ ] Pagament parcial factura → allocations correctes; remaining DN baixa.
- [ ] Retry mateix `client_op_id` → 1 sola fila payment.
- [ ] Fallada simulada mid-loop no deixa slices orfes (tot o res).
- [ ] Pagament > remaining → error.
- [ ] DN facturat + `record_payment` → error.
- [ ] Bestreta de pressupost continua reduint remaining via balances.
- [ ] Cancel factura amb pagament de factura → bloquejat; amb només cobraments DN previs → permès (segons 1A).

## Fitxers

| Àmbit | Fitxers |
|-------|---------|
| SQL | migració `…payment_allocations…`, update `delivery_balances`, `record_invoice_payment` |
| Tests | `supabase/tests/sales_payment_allocations_tests.sql` |
| TS | `commercialFlowService.ts`, `paymentAllocation.ts` (+ tests si cal), UI modal cobrament factura |

## DoD

- [ ] Cap slice amb UUID aleatori en cobrament de factura.
- [ ] `delivery_balances` coherent amb allocations.
- [ ] Tests SQL verds + checklist actualitzat.
