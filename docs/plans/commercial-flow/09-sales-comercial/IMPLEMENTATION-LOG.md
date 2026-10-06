# CF-27 — Log d’implementació

> Data: 2026-10-03 · Pla: [`README.md`](./README.md)

## Migracions (aplicades en local)

| Fitxer | Contingut |
|--------|-----------|
| `20261217000001_sales_invoice_core.sql` | `doc_type=invoice`, links, external_refs, draft/issue/cancel, migració `external_invoices` |
| `20261217000002_sales_payment_allocations.sql` | `payment_allocations`, pagament factura idempotent |
| `20261217000003_sales_invoice_permissions.sql` | `invoices.review/export`, `assert_invoice_permission` |
| `20261217000004_sales_numbering_fiscal.sql` | sèries, comptadors, exercicis, preview/close/reopen |
| `20261217000005_sales_list_pages.sql` | `list_sales_*_page` (keyset) |
| `20261217000006_sales_accountant_exports.sql` | reviews, export batches, prepare/finalize/claim |
| `20261217000007_sales_dashboard_kpis.sql` | KPI dashboard exercici |
| `20261217000008_set_document_external_ref.sql` | Ref. ERP manual a document |
| `20261217000009_fix_preview_next_document_number.sql` | Preview sense fila de comptador (evita NULL) |
| `20261217000010_fix_invoice_draft_empty_lines.sql` | Rebutja DN sense línies; `cancel_invoice` també en draft |
| `20261217000011_fix_cf27_bugs.sql` | Issue atòmic + resume orphan; export `client_op_id`; member sense `invoices.edit` |
| `20261217000012_commercial_activity_payments.sql` | `payment_recorded`; Activity `INVOICE_CANCELLED` / `PAYMENT_RECORDED` (fan-out multi-OS) |

## Proves

SQL (docker psql, PASS):
- `sales_invoice_core_tests.sql`
- `sales_payment_allocations_tests.sql`
- `sales_list_pages_tests.sql`
- `sales_accountant_exports_tests.sql`
- `sales_dashboard_kpis_tests.sql`
- `sales_preview_number_tests.sql`
- `sales_cf27_bugfix_tests.sql` (atomic issue, orphan resume, empty lines, export op id, member RBAC)
- `commercial_activity_payments_tests.sql` (payment_recorded, cancel Activity fan-out, repair idempotent)

TS: `commercialErrorMessage`, `resolveNav`, `navigationReturn`, `buildCommercialDocumentHtml`, `sessionAppMetadata` — verds.

## Frontend

- `/sales/*` + redirects legacy + sidebar Comercial
- Modal emetre: preview número sèrie + Ref. ERP opcional + total RO
- KPIs dashboard reals
- Export ZIP client (PizZip) des del paquet CSV
- Fitxes DN/factura + PDF invoice via render existent
- Fitxa factura: import de cobrament = pendent (no total brut)
- Settings Comercial + preset Gestoria
- RBAC: `getSessionAppMetadata` llegeix claims del access token (hook)
- `database.types.ts` regenerat (local) i copiat a edge `_shared`

## UAT local (2026-10-03)

### Oficina (Alice / Volt owner)
- Hub `/sales` + albarans + emetre `F-2026-0018` + PDF + cobrament OK

### Gestoria (Eve viewer + preset)
- Comptabilitat + export/revisió visibles
- Fitxa: sense Cobrar/Anul·lar

### Camp (Hèctor member / Riera)
- Home `/field/today`; sense Comercial `/sales` per defecte després de `000011` (member base sense `invoices.*`)
- Cobrament DN a l’OS intacte (no usa `invoices.*`)
- **Ops:** cal re-login / refresh de sessió perquè el JWT reflecteixi el base nou

## Bugfix CF-27 (`000011`, 2026-10-03)

- Issue atòmic `issue_invoice_from_delivery_notes` + resume d’orphan draft
- `clientOpId` per intent (cobrar / emetre / export); export no reutilitza lots `failed`
- Badge `billing_status` (En esborrany vs Facturat); selecció només `to_invoice`
- Data local (`localDateIso`); `registerExternalInvoice` fallback només `PGRST202`
- Member base sense `invoices.edit` (TS + `get_role_permissions`)

## Activity + cobraments (`000012`, 2026-10-03)

- Event narratiu `payment_recorded` (DN/factura); `payments` segueix sent la font de saldos
- Projecció Activity: `PROJECT_COMMERCIAL_INVOICE_CANCELLED` / `PAYMENT_RECORDED` (fan-out multi-OS; cancel ignora `released_at`)
- Nota: noves actions a `audit_logs` poden disparar automatització PGMQ si hi ha playbooks per prefix


## UAT CF-26 (2026-10-03, mateix cicle)

- Camp: cobrar `A-2026-0002` + comprovant
- Oficina: emetre `F-2026-0019` des d’`A-2026-0001`; Rectificar visible al menú hub; preview bloqueja si heretat > total
- Fix: DN seed sense línies → orphan draft; ara `invoice_delivery_notes_empty_lines` + discard draft
- LOG: dades UAT `A-CF25-*` locals sense backfill cega de línies
- Seeds durables (2026-10-06): Volt `A-2026-9101` (2 línies), Riera `A-2026-9102` + existent `A-2026-9001` — `supabase/seeds/commercial_hub_delivery_notes.sql` a `[db.seed] sql_paths`

## Pendent curt (opcional)

- Edició write de patrons de sèrie
- Adaptadors Sage/A3/DelSol
- Worker storage signat (V1: ZIP al navegador)
- EXPLAIN escala + UAT anul·lar / tancar exercici (diferits; veure fase 7)
