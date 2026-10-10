# CF-24 V2 — Spike orphan (Fase 1b)

> **Data:** 2026-10-08  
> **Decisió accept↔OS:** **B** — accept consolida sempre; creació d’OS idempotent i reintentable.

## 1. Mapeig CDL → `project_lines`

| `commercial_document_lines` | `project_lines` |
|-----------------------------|-----------------|
| `catalog_item_id`, `kind`, `name`, `description`, `unit`, `quantity`, `unit_price`, `discount_pct`, `tax_rate`, `position` | mateixos |
| `id` | `source_quote_line_id` (FK ja a `20261160000001`) |
| — | `notes` NULL; sense cost/actuals |

Composer mínim ha d’exposar tots els camps NOT NULL de CDL (defaults: `service`, `u`, `0`, `21`).

## 2. NULL-safe (inventari)

Canviar `project_id =` → `IS NOT DISTINCT FROM` a:

- `trg_commercial_document_apply_supersedes` / active quote — `20261160000004_commercial_flow_quote_reissue.sql`
- Active quote check a `issue` / reissue — `20261186000001_commercial_formalization_mode.sql`
- Delivery supersedes — `20261216000004_rectify_delivery_note.sql` (mateix patró; tocar si es toca el trigger compartit)

**No** unique index global `(tenant, client)` per orphans actius (N per client).

## 3. prepare / finalize orphan

- `api.prepare_agreement_from_quote`: OK sense `project_id`; salta `commercial_agreement_projects`.
- `data.finalize_commercial_agreement_version`: accepta quote `issued` + `separate_agreement`; `recompute` només si hi ha projecte.
- **Hooks V2:** després d’accept (status→accepted/signed), cridar `api.ensure_project_from_orphan_quote(doc_id)`; després `api.link_agreement_project_from_quote(doc_id)` (reintentable).

## 4. Decisió A vs B — **B**

**Evidència:** `stamp-pdf-signatures` fa Storage + `add_document_version_internal` + audit en txns **anteriors** a `finalize_signing_session`. Si l’apply dins del trigger falla i es fa rollback de l’accept, la **firma/PDF pot quedar**. CS-D21 i el patró d’acords (`retry_commercial_agreement_signing`) afavoreixen B.

| Pas | Comportament |
|-----|----------------|
| Accept / finalize quote | Sempre consolida status |
| OS | `ensure_project_from_orphan_quote` idempotent; si falla → chip «OS pendent» + retry oficina |
| Prospect promote (C) | Continua al trigger de status (OK in-txn; no és stamp) |

## 5. OS sense `planned_start`

Neix `commercial_stage=execute`, `planned_start` NULL → safata Agenda **Sense planificar** (`list_field_visits` `unscheduled=true`). No ha d’aparèixer a Avui. Verificar que el filtre prospecte **no** l’exclou (és execute).

## 6. RPCs work_gate (`source_quote_id` sense enllaç)

Avui el gate és `trg_work_logs_agreement_gate` → `project_requires_active_agreement` (només projectes enllaçats).

**Estendre** perquè també denegui si existeix acord `require_signed_agreement` amb `source_quote_id` = quote de l’OS (via `commercial_documents.project_id`) i **no** hi ha fila a `commercial_agreement_projects`.

Camins que inserten `work_logs` (coberts pel trigger si s’estén):

- `api.start_work_log`
- `api.field_punch_start`
- Altres INSERT a `work_logs`

UI primary action també ha de respectar el mateix senyal (lectura de gate).

## 7. Següent

Implementació V2 + hotfix feta. **UAT manual:** [`cf24-v2-orphan-uat.md`](./cf24-v2-orphan-uat.md).
