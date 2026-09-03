# 05 — Backlog epics V1

> Part del pla [Field Service / Work Orders](./README.md).  
> Estat per epic: [`STATUS.md`](./STATUS.md).  
> Principi: **cada epic ha de ser usable sola al mòbil**; no acumular backend sense gest.

## Ordre d’implementació

```text
FS-0 labels → FS-1 bind client/site → FS-2 Avui/FAB → FS-3 close-out → FS-4 PWA → FS-5 acceptació
```

## FS-0 — Contracte i vocabular (1–2d)

- Aplicar `sector_profiles.labels` a nav, títols i empty states (`Ordre de servei`, `Visita`, `Client`)
- Documentar mapeig estat UI FSM ↔ `projects.status` (preferir labels + filtres; ampliar CHECK només si cal)
- **DoD:** un tenant `field_service` no veu “Projecte” on hauria de veure “Ordre de servei”
- Tanca gaps: G3, G6

## FS-1 — Ordre de servei completa (oficina mínima) (3–4d)

- Form: `client_id`, `contact_site_id` (prioritari), `asset_id` opcional
- CRUD mínim de contact sites si encara és “aviat” (**blocker**)
- Deep-link Maps des del detall
- Llista filtrable: les meves / obertes / avui (`planned_start`)
- Crear ordre des de Contact/Site en ≤3 taps
- **DoD:** crear “canvi d’endolls a Carrer X” amb client + adreça + data + línies seed
- Tanca gap: G2

## FS-2 — Shell de camp “Avui” (4–6d)

- Home `field_service`: visites/ordres d’avui + estat + adreça
- FAB **Iniciar visita** → start `work_log` + geo
- Bottom nav: Avui | Ordres | Agenda | Més
- Responsive-first; targets ≥48dp
- **DoD:** tècnic fa el dia sense obrir el menú Projectes d’oficina
- Tanca gap: G1

## FS-3 — Execució i tancament (4–5d)

- Checklist versionada: plantilles → `checklist_runs` (no `tasks` amb tag); veure [maintenance/README](../maintenance/README.md)
- UI `project_materials` (+ opcional `catalog_item_id`)
- Expenses: stub o enllaç al pla [expenses](../expenses/) — no bloqueja
- Close-out: fotos DMS + gates de checklist + payload públic + completar + stop work_log
- **DoD:** tancar visita amb temps, 1 foto i 1 material en &lt;2 min (offline→online)
- Tanca gaps: G4, G5, G8

## FS-CP — Butlletí d’intervenció i portal client (després de FS-3)

> Milestone de producte detallat a [`docs/plans/custom-portal/`](../custom-portal/README.md).  
> Execució: [`STATUS.md`](../custom-portal/STATUS.md) · [`EXECUTION.md`](../custom-portal/EXECUTION.md).

- **Després de FS-3** (close-out usable): artefacte de butlletí **immutable**, shares segurs, reader a `apps/customer-portal` (Fase A / CP-A*).
- Close-out **no** és publicació al client; publicar és una operació explícita amb projecció allowlist.
- El payload `checklist_runs.public_report_payload` és procedència/snapshot d’execució; la versió publicada és l’autoritat (vegeu maintenance README).
- **Portal client light (Fase B / CP-B)** es conserva a **V2** (grants persistents); no forma part del gate V1 de Field Service.
- **DoD Fase A (orientatiu):** publicar → crear/enviar share → reader → revocar; veure validació al pla custom-portal.

## FS-3b — Plans de manteniment

- `maintenance_plans` (plataforma + tenant), assignacions polimòrfiques, cron idempotent
- **DoD:** assignar un pla a un `contact_site` i generar una ordre `maintenance` sense duplicats

## FS-4 — PWA + offline Today (3–4d)

- `vite-plugin-pwa` + manifest installable al tenant-portal
- Cache lectura Avui; estendre cua (foto/note) si cal
- **DoD:** sense xarxa es veu Avui i es pot start/stop + foto en cua
- Tanca gap: G7

## FS-5 — Acceptació Tier A solo (2–3d)

- Empty states + onboarding 3 passos
- Smoke E2E (seed + Playwright)
- Widgets recepta: visites avui + ordres obertes
- UAT: [`uat-tier-a-checklist.md`](./uat-tier-a-checklist.md)
- **DoD:** checklist **acceptada** → gate obert a V1.5 ([06](./06-acceptance-and-gates.md))

## Dependències

| Dep | Nota |
|-----|------|
| Contact sites CRUD | **Bloqueja** FS-1 |
| EHR / dispatch eligibility | No bloqueja V1 solo |
| Expenses | Desitjable després FS-3; no bloqueja close-out mínim |
| Assets UI | Opcional V1 |
| Attendance itinerant | No redissenyar HR ara; `field_punch` és el pont |
| Custom portal CP-A* | Després FS-3; no bloqueja el gate UAT V1 de FS-5 |
| Custom portal CP-B | V2 |

**Risc principal:** construir més CRUD d’oficina en lloc del shell Avui.

## Fora de V1

- Rutes multi-parada (Maps V2)
- Cobrament al lloc / Stripe
- Signatura client → **V1.5**
- Dispatch multi-tècnic → **V1.5**
- Stock decrement / purchase
- App nativa / `tech-portal` separat
- Helpdesk / flota
- Portal client persistent (CP-B) → **V2**

## V1.5 / V2 (després del gate)

| Versió | Abast |
|--------|--------|
| **V1.5** | Signatura; bundle `tecnic`; assignació simple; WhatsApp “vaig de camí” |
| **Post FS-3 (paral·lel / després UAT)** | Butlletí + shares (CP-A*) — pla [custom-portal](../custom-portal/README.md) |
| **V2** | Rutes; pagament; consum estoc; PM assets; **portal client light (CP-B)** |
