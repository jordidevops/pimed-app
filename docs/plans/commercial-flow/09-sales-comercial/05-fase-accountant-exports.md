# Fase 5 — Gestoria, revisió comptable i exportació

> **Ordre:** 5 · **Depèn de:** 1A, 1B, 2, 4 · **Índex:** [`README.md`](./README.md)

## Objectiu

La gestoria del tenant revisa factures/albarans i genera lots d’exportació **immutables i reproduïbles** per alimentar el seu programa (Sage, A3, DelSol, …) sense connector API encara.

## Persona i accés

- [ ] Membres amb preset Gestoria (`invoices.view` + `review` + `export`).
- [ ] Vista `/sales/accounting` visible amb `review` o `export` o `manage`.
- [ ] Sense editar documents, cobrar, anul·lar ni Settings sèries.

## Esquema

### Revisió

- [ ] `data.commercial_accounting_reviews`:
  - `tenant_id`, `document_id`, `status` (`pending` \| `reviewed` \| `needs_changes`), `comment`, `reviewed_by`, `reviewed_at`, `revision int`
  - Unique lògica: última revisió per document (o historial append-only + vista latest)
- [ ] Events: `accounting_reviewed`, `accounting_changes_requested` a `commercial_document_events` (ampliar CHECK).

### Export

- [ ] `data.commercial_export_profiles`:
  - `tenant_id`, `name`, `adapter` (`canonical_v1` \| futur `sage_*`…), `schema_version`, `config jsonb`, `active`
- [ ] `data.commercial_export_batches`:
  - `tenant_id`, `profile_id`, `period_from`, `period_to`, `status` (`preparing` \| `ready` \| `failed`), `schema_version`, `row_count`, `checksum`, `file_node_id` / storage path, `created_by`, `created_at`, `finalized_at`, `error_text`
- [ ] `data.commercial_export_batch_documents`:
  - `batch_id`, `document_id`, `content_hash`, `exported_at`
  - Unique `(batch_id, document_id)`
- [ ] Event `included_in_export` amb `batch_id` al payload.

## Validació pre-export

Bloquejar inclusió silenciosa si falla (marcar document / lot `failed` amb llista):

- [ ] NIF / id fiscal client i emissor (snapshot)
- [ ] Raó social, adreça
- [ ] Sèrie + número + data
- [ ] Bases per tipus impost, quotes, total, moneda EUR
- [ ] Coherència línies ↔ capçalera
- [ ] Document `issued` (no draft); política per `cancelled` (excloure o exportar amb flag)

## Flux d’export (patró recruitment)

Referència: `api.export_job_posting_applications_csv` + packages + claim worker.

1. [ ] RPC `api.prepare_commercial_export_batch(...)` → crea batch `preparing`, selecciona documents, valida; **no** retorna CSV enorme al client.
2. [ ] Worker / edge (service_role) genera ZIP, puja storage path `tenant_id/exports/…`, calcula checksum, marca `ready`.
3. [ ] RPC `api.claim_commercial_export_batch` / signed URL TTL curt (p. ex. 15 min).
4. [ ] Auditoria de cada descàrrega.
5. [ ] Regenerar = **nou** batch; mai overwrite.

## Contingut ZIP `canonical_v1`

- [ ] `manifest.json` — profile, schema_version, period, checksums, generated_at, tenant_id
- [ ] `invoices.csv`
- [ ] `invoice_lines.csv`
- [ ] `taxes.csv`
- [ ] `payments.csv`
- [ ] `delivery_notes.csv`
- [ ] `pdfs/` opcional (per invoice id)
- [ ] Encoding UTF-8, dates ISO, decimals fixos, `csv_escape_cell` (formula injection)

## UI

- [x] `/sales/accounting`: filtres període; cua «Pendent de revisar»; historial lots; botó Generar export (prepare→finalize→claim → JSON package).
- [ ] Fitxa document: estat revisió + lots (Fase 6 completa el detall).
- [x] Llistes Fase 4: columnes Revisió / Export (hub factures).
- [x] Copy honest: «Export canònic PiMed»; **no** «Compatible Sage» sense adaptador validat.

## Adaptadors futurs (fora V1)

- [ ] Documentar carpeta / convenció `adapter + schema_version + golden fixtures`.
- [ ] No UI «Sage/A3/DelSol» fins fixture d’importació real acceptada.

## Proves

- [ ] Gestoria exporta només tenant actiu.
- [ ] Document amb NIF buit no entra al lot ready.
- [ ] Golden ZIP / CSV snapshots.
- [ ] Reexport → nou batch_id; primer batch immutable.
- [ ] URL caducada no serveix.
- [ ] Formula injection neutralitzada.

## DoD

- [x] Flux revisió + export canònic operable per gestoria (V1: ZIP client via PizZip quan `package.files` té CSV; JSON fallback; ZIP storage worker diferit).
- [x] Lots auditables i reproduïbles (nou batch per regenerar).
- [ ] Checklist actualitzat (fase oberta per worker/ZIP + validació NIF completa).
