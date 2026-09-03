# 02 — Gap matrix i col·lisió de noms

> Part del pla [Field Service / Work Orders](./README.md).  
> Actualitzar la taula de gaps a mesura que es tanquen epics (també reflectit a [`STATUS.md`](./STATUS.md)).

## Substrat existent (no reinventar)

| Peça | On | Notes |
|------|-----|--------|
| Projects `type=work_order` | `apps/tenant-portal/src/features/projects/` | Estats, tasques, línies de catàleg |
| Work logs GPS + offline | `WorkLogCard`, `useFieldSync`, `field-ops-db` | Start/stop amb geo |
| Catalog + seed FS | `features/catalog/`, migració `20260503000008_sector_profiles.sql` | Label seed: `"project": "Ordre de servei"` |
| Calendar sync | `process-project-events`, lifecycle projectes | Events des de dates de projecte |
| Locations / assets schema | `features/locations/`, migració locations_assets | Assets UI dedicada pendent |
| Contact sites | Contacts — UI parcial | CRUD “aviat” = blocker Epic 1 |
| Dispatch eligibility HR | gate opcional `start_work_log` | **No** és tauler d’assignació |

## Gap matrix (adopció)

| ID | Necessitat FSM | Estat avui | Epic | Impacte |
|----|----------------|------------|------|---------|
| G1 | Home **Avui** + FAB “Iniciar visita” | Dashboard genèric; worklog al detall | FS-2 | Sense això no és app de camp |
| G2 | Client + **adreça d’obra** a l’ordre | `client_id` a RPC; no al `ProjectForm`; sites parcial | FS-1 | No saben on van |
| G3 | Vocabulari / estats “de servei” | UI diu Projectes; estats genèrics | FS-0 | Sonoritat d’oficina |
| G4 | Checklist visita / tancament | ✅ Motor versionat (`checklist_runs`); veure [maintenance/README](../maintenance/README.md) | FS-3+ | — |
| G5 | Materials consumits | `project_materials` sense UI | FS-3 | No tanquen amb peces |
| G6 | Labels sector a tota la UI | Seed OK; UI no aplica | FS-0 | No sona al vertical |
| G7 | PWA + Today offline | Offline només worklogs; sense `vite-plugin-pwa` | FS-4 | Cotxe sense cobertura |
| G8 | Close-out (fotos + resum) | DMS OK; flux inexistent | FS-3 | Sense prova de feina |
| G9 | Superfície `tecnic` vs oficina | Bundles dissenyats; RBAC gruixut | V1.5 | Micro-equip |
| G10 | Tauler dispatch / rutes | Absent | V1.5 / V2 | Correcte absència a V1 solo |

## Col·lisió de noms (obligatori llegir)

| Terme | Significat correcte | No confondre amb |
|-------|---------------------|------------------|
| **Field Service / WO** | Ordre al client (`projects.type = work_order`) | — |
| **EAM `asset_work_orders`** | Ordre sobre actiu **intern** del tenant | Documentat a [10-implemented-modules](../../product-design/10-implemented-modules.md) §6 però **no existeix a migrations**; el manteniment de camp usa `projects.type=maintenance` + `maintenance_plans` |
| **RRULE a calendar_events** | Recurrència RFC5545 | **No implementat**; la periodicitat viu a `maintenance_plan_assignments` |
| **Checkin “FSM”** | **Finite State Machine** del kiosk de fitxatge | Field Service Management |
| **Expenses “FSM vs comercial”** | Mode de presentació del tècnic de camp (`line_first`) | State machine ni mòdul WO |


