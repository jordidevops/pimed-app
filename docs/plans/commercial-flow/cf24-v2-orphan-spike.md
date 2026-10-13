# CF-24 V2 — Spike orphan (Fase 1b)

> **Data:** 2026-10-08 (actualitzat 2026-10-13)  
> **Decisió accept↔OS:** **1A (defer)** — accept consolida sempre; **no** crea OS automàticament. L’oficina crea l’ordre a mà (tipus + intent) o marca «No cal ordre».

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
- `data.finalize_commercial_agreement_version`: accepta quote `issued` + `separate_agreement`; `recompute` / link només si hi ha projecte.
- **Hooks:** després d’accept/reject/signed → notificar gestors (`QUOTE_ACCEPTED` / `QUOTE_REJECTED`). **No** cridar `ensure_project_from_orphan_quote`.

## 4. Decisió accept↔OS — **1A (defer)**

Abans era option B (auto-OS). Producte: la data dels treballs s’acorda amb el client; alguns pressupostos (p.ex. manteniment comercial) poden no voler OS, o voler `type=maintenance`.

| Pas | Comportament |
|-----|----------------|
| Accept / finalize quote | Sempre consolida status; notifica gestors |
| OS | Manual: `ensure_project_from_orphan_quote(doc, site, type, intent)` → `work_order`\|`maintenance` + `visit_intent`; event `project_linked` + `ORPHAN_OS_CREATED` |
| Sense OS de camp | `mark_orphan_quote_project_not_needed` → event `project_not_needed` |
| Prospect promote (C) | Continua al trigger de status |

Migració: `20261245000001_orphan_accept_defer_os.sql`.

## 5. OS sense `planned_start`

Neix `commercial_stage=execute`, `planned_start` NULL → Agenda **Sense planificar** + filtre **Sense data** a `/field/orders` (`list_projects_paginated` `p_unscheduled=true`).

## 6. RPCs work_gate (`source_quote_id` sense enllaç)

Gate via `trg_work_logs_agreement_gate` → `project_requires_active_agreement` (projectes enllaçats + acord amb `source_quote_id`).

## 7. Següent

UAT manual: [`cf24-v2-orphan-uat.md`](./cf24-v2-orphan-uat.md).
