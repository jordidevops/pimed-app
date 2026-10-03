# Fase 1A — Nucli de factura i migració

> **Ordre:** 1A · **Depèn de:** Fase 0 · **Bloqueja:** 1B, 3, 4, 6  
> **Índex:** [`README.md`](./README.md)

## Objectiu

Substituir `external_invoices` per factures `commercial_documents` (`doc_type = 'invoice'`) amb línies traçables, links reversibles i migració forward segura.

## Decisions aplicables

S-D1, S-D2, S-D3, S-D4, S-D5, S-D8 (veure [`README.md`](./README.md)).

## Esquema (migració forward)

Nom suggerit: `supabase/migrations/20261217000001_sales_invoice_core.sql` (o timestamp posterior a `000008`).

### Taules / columnes

- [ ] Ampliar CHECK `commercial_documents.doc_type` amb `'invoice'`.
- [ ] `commercial_document_lines.source_commercial_document_line_id uuid NULL REFERENCES …`
- [ ] `data.invoice_delivery_notes`:
  - `tenant_id`, `invoice_id`, `delivery_note_id`, `created_at`, `released_at`
  - PK `(invoice_id, delivery_note_id)` o id propi + unique
  - **Índex únic parcial:** `(delivery_note_id) WHERE released_at IS NULL`
- [ ] `data.commercial_document_external_refs`:
  - `tenant_id`, `document_id`, `provider`, `external_id`, `external_number`, `synced_at`, `payload_hash`, timestamps
  - Unique `(tenant_id, provider, external_id)` WHERE external_id NOT NULL
  - Unique `(tenant_id, document_id, provider)`
- [ ] Triggers: mateix `tenant_id` entre invoice, DN, lines, refs.
- [ ] RLS + vistes `api.*` amb `active_tenant_id()`.
- [ ] Opcional: `number_origin` / metadades per migrats (`external_migrated`).

### RPCs

- [ ] `api.create_invoice_draft_from_delivery_notes(p_delivery_note_ids, p_client_op_id, p_issued_on?, p_notes?)`
  - Requereix `active_tenant_id()` no nul.
  - Un sol `client_id`; DN `issued|signed|accepted`; sense link actiu; mateix tenant.
  - `FOR UPDATE` dels DN ordenats per UUID.
  - Insert invoice `status='draft'` (sense `doc_number`).
  - Links `released_at IS NULL`.
  - Copia línies 1:1 amb `source_commercial_document_line_id`.
  - Recomputa `subtotal`, `tax_breakdown`, `total` (mateixa lògica que emissió comercial).
  - `project_id = NULL` si >1 OS.
  - Idempotent per `client_op_id`.
- [ ] `api.issue_invoice(p_invoice_id, p_client_op_id, p_issued_on?, p_series_id?)`
  - Només draft del tenant actiu.
  - Valida totals vs DN; `content_hash`; assigna número (Fase 3 pot completar sèries; fins llavors prefix provisional o counter existent).
  - `draft → issued` en la mateixa TX després de línies (immutabilitat).
- [ ] `api.cancel_invoice(p_invoice_id, p_client_op_id)`
  - Només `issued`; sense pagaments amb `document_id = invoice`; sense `external_refs.synced_at` (si aplica).
  - `status='cancelled'`; `released_at = now()` als links; **no** esborrar links/línies/pagaments DN.
  - Event `invoice_cancelled`.
- [ ] Actualitzar `record_payment`: gate per **link actiu** (no només `external_invoice_ref`).
- [ ] Actualitzar `rectify_delivery_note`: bloqueig per link actiu.
- [ ] Actualitzar llistes / `get_delivery_note_collection_detail` per exposar `invoice_id`, `invoice_doc_number`, facturació derivada.

### Migració de dades

- [ ] Preflight: llista `external_invoices` on `total_cents ≠ SUM(DN lines/totals)`.
- [ ] Si hi ha inconsistències: `RAISE` amb informe (ids); **no** crear línies d’ajust.
- [ ] Per cada fila coherent:
  - Crear `commercial_documents` invoice `issued`, `doc_number = invoice_number`, `number_origin = 'external_migrated'`.
  - Copiar línies des dels DN enllaçats.
  - Crear `invoice_delivery_notes`.
  - Moure/notes/`file_node_id` a payload o external_ref `provider='manual'`.
  - Repointar `payments.external_invoice_id` → `payments.document_id` (invoice) **o** columna `invoice_id` unificada (decidir a 1B; aquí preparar FK).
- [ ] Després de verificació: deixar d’escriure `external_invoice_ref`; planificar drop de taules/RPC antigues en migració posterior (no al mateix dia sense proves).

### Client TS / UI mínim

- [ ] Substituir `registerExternalInvoice` pel draft+issue (o un sol wrapper temporal).
- [ ] Actualitzar `deriveOrderWorkflow`, `pendingCommercialAction`, panell OS, badges de facturació.
- [ ] Helper `deliveryNoteActiveInvoice(dn)` basat en link, no ref text.
- [ ] Regenerar o actualitzar stubs de `database.types.ts` quan toqui (obligatori Fase 7).

## Fitxers esperats

| Àmbit | Fitxers |
|-------|---------|
| SQL | nova migració + tests `supabase/tests/sales_invoice_core_tests.sql` |
| TS | `commercialFlowService.ts`, workflow, `DeliveryNotesList`, `ProjectCommercialPanel`, `CommercialDocumentView` |
| Docs | actualitzar [`07`](../07-collections-and-ar-hub.md) quan aquesta fase tanqui |

## Proves SQL mínimes (abans de DoD)

- [ ] Draft + issue 1 DN.
- [ ] Issue 2 DN / 2 OS mateix client.
- [ ] Rebutja DN de clients diferents.
- [ ] Rebutja DN ja en factura activa.
- [ ] Cancel allibera DN; historial de link queda.
- [ ] `record_payment` sobre DN facturat → error.
- [ ] Rectify amb link actiu → error.
- [ ] Preflight bloqueja total incoherent (fixture).

## DoD

- [ ] Cap UI nova depèn de `external_invoice_ref` com a font de veritat.
- [ ] Migració forward aplicada en reset local; tests SQL verds.
- [ ] Modal/oficina crea factures natives (encara que la UI de taula/rutes arribi després).
- [ ] Checklist [`CHECKLIST.md`](./CHECKLIST.md) actualitzat.
