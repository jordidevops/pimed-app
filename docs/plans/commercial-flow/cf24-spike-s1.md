# CF-24 Spike S1 — filtres prospecte vs cost composer CDL

> **Data:** 2026-10-08  
> **Objectiu (històric):** alimentar la decisió D1. **Tancat 2026-10-08:** D1=**C** implementat (`commercial_stage=prospect`).  
> **Mètode:** lectura de codi / migracions (no prototip runtime en aquesta sessió).

## 1. Superfícies a filtrar si es tria C (`commercial_stage=prospect`)

Cal excloure OS prospecte d’aquestes cues de **camp**. `service_mode=assessment` **no** les exclou avui (només badge a agenda).

| Superfície | Fitxer / RPC | Filtre actual | Acció si C |
|------------|--------------|---------------|------------|
| Avui | `TodayPage` → `useTodayOrders` → `list_projects_paginated` / `getProjectsPage` | Tipus + dates; **sense** `service_mode` | Excloure `commercial_stage=prospect` (param o vista) |
| Agenda | `FieldAgendaPage` → `list_field_visits` | Tipus WO/maint; exposa `service_mode`; badge Avaluació | Excloure prospect; **no** barrejar amb assessment |
| Comptadors | `FieldStatsRow` → `countProjects({ type: 'work_order' })` | Només tipus | Mateix filtre prospect |
| Llista ordres | `ProjectsPage` `/field/orders` | `fsFilter=open` | Opcional: pestanya «Prospectes» vs excloure del open |
| Punch / Fer | `ProjectDetailPage` + workflow | Assessment permet Fer | Prospect: Preparar-only; amagar Fer/Entregar |
| CreateQuoteDialog | `CreateQuoteDialog.tsx` | OS obertes | **Incloure** prospectes (desitjable per cotitzar) amb chip |
| search_jobs_for_pricing | SQL ranking | Prefereix assessment completed | Sense canvi obligatori |

**Estimació cobertura filtres:** M (1–2 dies eng. un cop existeixi la columna `commercial_stage`): RPC list/count + 3–4 callers UI + tests.

**Risc residual:** qualsevol llista nova de `work_order` sense el filtre. Mitigació: helper SQL `data.project_is_field_queue(p)` o default a `list_projects_paginated`.

**No fer:** reutilitzar `assessment` com a prospecte d’oficina.

## 2. Cost Full de preus sobre `commercial_document_lines` (si B)

| Capa | Estat avui | Esforç |
|------|------------|--------|
| UI Full de preus | Només `project_lines` (`ProjectLinesSection`, forms, AI, hàbits) | M–L retarget |
| RPCs escriptura | `upsert_project_line`, `apply_price_sheet`, `apply_pricing_template`, … | L — calen forks `*_document` |
| Draft quote editable | Issue atòmic draft→issued; **no** UI draft | M producte + RPC |
| CDL grants | SELECT authenticated; writes DEFINER | OK si RPC nous |
| Close-out / actuals / CF-19 cost | Lligats a `project_lines` | L si es **substitueix**; M si dual-write o composer magre |
| CF-D10 | Capa viva = `project_lines` | Cal esmena explícita si B amb editor ric |

**Verdict spike:** paritat Full de preus a CDL = **L** (vora XL si es depreca `project_lines`). Composer **mínim** (D): upsert/delete línia + recompute totals + form simple = **M**.

Prototip mínim mesurable (si es continua el spike en runtime):

1. Migració `api.upsert_commercial_document_line` (draft-only) + test SQL.
2. Pantalla 1 línia en draft quote orphan.
3. Comparar checklist: hàbits / AI / cost / notes / offline — què queda fora.

## 3. Ancoratge orphan (B) — recordatori

- `client_id` NOT NULL; `project_id` nullable.
- Bugs NULL: `active_quote_already_exists`, supersedes quote, reissue → cal `IS NOT DISTINCT FROM` + regla unicitat per client.
- Accept no crea OS avui.

## 4. Taula decisió D1

| Criteri | Guanya C | Guanya B/D |
|---------|----------|------------|
| Reutilitzar Full de preus ara | **C** | — |
| Zero fila `projects` fins a acceptar | — | **B/D** |
| Contaminació Avui mitigable amb stage | **C** (M) | B evita el problema |
| Vertical sense contenidor OS | — | **B** |
| Temps fins a 1r Quote-first usable | **C** més curt | B més llarg si paritat editor |

**Decisió (2026-10-08):** **C implementat.** B/D queden diferits; reobrir si cal zero fila `projects` o vertical sense OS.

## 5. Dependències ja entregades (independent de D1)

- Docs 06 + notes 953744b4 + vocabulari SoT.
- Validador unknown paths al portal + alineació `client_reject`.
- Badge potencial/efectiu.
- Guia order-first a detall OS.
- Leads → promote → CTA pressupostos del contacte.
