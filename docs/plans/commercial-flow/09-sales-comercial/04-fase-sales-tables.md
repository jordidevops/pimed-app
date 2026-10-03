# Fase 4 — Taules de gestió escalables

> **Ordre:** 4 · **Depèn de:** 1A, 1B, 2 · **Recomanat:** 3 (filtre exercici)  
> **Índex:** [`README.md`](./README.md)

## Objectiu

Llistes tipiques de programa de gestió: checkbox, ordenació, filtres, paginació keyset, accions massives. Cap escaneig global de balances del tenant.

## Anti-patrons (prohibiats)

- [ ] ❌ `delivery_balances(tenant_id, NULL)` a llistes.
- [ ] ❌ OFFSET profund com a única estratègia (pàgina 50+).
- [ ] ❌ `ILIKE '%q%'` sense trigram / mínim de caràcters.
- [ ] ❌ Ordenar per camps derivats no indexables sense whitelist.

## Component UI

- [x] `SalesDataTable` (shared): checkbox 1a columna, capçaleres ordenables, comptador, menú fila (`dropdown-menu`), barra massiva, paginació cursor.
- [x] Modes: full hub / compact (OS, client) — embedded manté llista legacy.

## RPCs de llista

### Albarans — `api.list_sales_delivery_notes_page`

Paràmetres (orientatius):

- filtres: `p_client_id`, `p_project_id`, `p_q`, `p_billing_status[]`, `p_collection_status[]`, `p_year`, `p_date_from/to`
- cursor: `p_sort`, `p_dir`, `p_cursor_value`, `p_cursor_id`, `p_limit`
- [ ] Primer CTE candidats amb `tenant_id` + filtres indexats.
- [ ] Balances només amb `project_ids` / ids de la pàgina (patró `000008`).
- [ ] Columnes: Número, Data, Client, OS, Facturació, Cobrament, Import, Factura (id+número).

**Facturació (derivat):** `to_invoice` \| `draft_invoice` \| `invoiced` \| `rectified`  
(`rectified` = DN `cancelled` / substitut; **no** confondre amb factura cancel·lada)

**Cobrament (derivat):** `pending` \| `partial` \| `paid`

### Factures — `api.list_sales_invoices_page`

- [ ] Mateix patró keyset; balances scoped als DN de les factures candidates.
- [ ] Columnes: Número, Data, Client, #DN, Document, Cobrament, Total, Pendent, Ref. externa, Revisió, Export.
- [ ] Document: `draft` \| `issued` \| `cancelled` (persistit).
- [ ] Cobrament derivat; Revisió des de `accounting_reviews` (Fase 5 pot stub `pending`); Export derivat de batches.

### Índexs (mínim)

- [ ] `(tenant_id, doc_type, issued_at DESC, id DESC)` partial invoice / DN
- [ ] `(tenant_id, client_id, issued_at DESC)`
- [ ] GIN/trgm sobre `doc_number`, display name client (o columna materialitzada)
- [ ] Links actius: `(tenant_id, delivery_note_id) WHERE released_at IS NULL`

### Deprecar

- [ ] Eliminar ús de `list_delivery_collection_page` mort.
- [ ] Substituir `list_external_invoices_page` / `list_delivery_notes_page` o adaptar-los sense trencar OS embedded fins migrar UI.

## Accions massives

- [ ] «Facturar seleccionats»: mateix client; crida `create_invoice_draft` (+ issue opcional); locks UUID ordenats; tot-o-res.
- [ ] Errors parcials: preferir fallar tot el lot amb missatge clar.

## Dashboard `/sales`

- [x] KPI exercici actiu: # per facturar, € pendent cobrament, # pressupostos pendents resposta.
- [x] Queries indexades / agregats scoped; no full històric (`api.get_sales_dashboard_kpis`).

## Proves

- [ ] SQL: filtres billing/collection; cursor estable; cap seq scan òbvi en fixture mitjà.
- [ ] TS: mapping estats → labels i18n.
- [ ] Manual: aspecte «programa de gestió» (taula, no cards).

## DoD

- [x] Hub albarans/factures usa `SalesDataTable` + RPCs noves (`list_sales_*`).
- [x] Cap crida full-tenant balances a llistes (SQL scoped).
- [x] Checklist actualitzat (KPI dashboard fet; deprecar legacy encara obert).
