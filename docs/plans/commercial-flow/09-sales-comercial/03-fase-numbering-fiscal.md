# Fase 3 — Sèries, numeració atòmica i exercicis

> **Ordre:** 3 · **Depèn de:** 1A, 2 · **Bloqueja:** emissió «seria» i Settings Comercial  
> **Índex:** [`README.md`](./README.md)

## Objectiu

Numeració concurrent per tenant+sèrie+període, preview no vinculant, i tancament d’exercici natural que bloqueja mutacions.

## Esquema

### Sèries

- [ ] `data.commercial_document_series`:
  - `id`, `tenant_id`, `doc_type`, `code` (ex. `F`, `A`), `name`, `pattern` (ex. `F-{YYYY}-{####}`), `reset_policy` (`yearly` \| `never`), `active`, timestamps
  - Unique `(tenant_id, doc_type, code)`
- [ ] Seed per tenant nou / backfill: sèries per defecte quote `P`, amendment `AMP`, delivery_note `A`, invoice `F`.
- [ ] `data.commercial_document_number_counters` (o evolució de `document_number_counters`):
  - PK `(tenant_id, series_id, period_key)`
  - `last_value bigint`
- [ ] Validació server-side del pattern (tokens: `{YYYY}`, `{YY}`, `{####}`, `{code}`, …). Rebutjar desconeguts.

### Exercicis

- [ ] `data.commercial_fiscal_years`:
  - `(tenant_id, year)` PK, `closed_at`, `closed_by`, `reopened_at`, `reopened_by` (opcional)
- [ ] V1: any natural 1 gen – 31 des. No barrejar amb `attendance_statutory_fiscal_year_start_month` (documentar a UI).

## RPCs

- [ ] `data.allocate_commercial_document_number(tenant, series_id, issued_on)`:
  - `period_key` des de `issued_on` + `reset_policy`
  - `INSERT … ON CONFLICT DO UPDATE … RETURNING` amb lock de fila
  - Retorna número renderitzat
- [ ] `api.preview_next_document_number(p_doc_type | p_series_id, p_issued_on)`:
  - Lectura `last_value+1` **sense** reservar; documentar a UI «orientatiu»
- [ ] Integrar a `issue_invoice` (i idealment issue DN/quote després): usar `issued_on`, no només `now()`.
- [ ] `api.close_commercial_fiscal_year(p_year)` / `api.reopen_…` → `invoices.manage`
- [ ] Gates `fiscal_year_closed` a:
  - `issue_invoice` (any de `issued_on`)
  - `cancel_invoice`
  - `record_invoice_payment` / `record_payment` (`occurred_at`)

## Settings UI

- [x] Settings → Comercial (nova secció o sota plantilles comercials):
  - Llista sèries per tipus; editar pattern; activar/desactivar — **read-only** list + pattern (sense write RPC)
  - Vista prèvia (preview RPC)
  - Exercicis: tancar / reobrir amb confirmació
- [x] La UI **no** escriu `last_value` a mà.

## Proves

- [ ] Dues emissions concurrents mateixa sèrie → números consecutius sense duplicat.
- [ ] Preview no consumeix número.
- [ ] `issued_on` any passat usa `period_key` correcte.
- [ ] Any tancat bloqueja issue/cancel/pay; lectura OK.
- [ ] Reobrir restaura mutacions.

## DoD

- [x] Factures noves usen sèrie configurable. (SQL `issue_invoice` + series)
- [x] Settings operable amb `invoices.manage` (close/reopen + preview).
- [ ] Tests concurrència + checklist.
