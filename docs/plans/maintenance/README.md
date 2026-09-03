# Motor de checklists i manteniment

Font de veritat del domini versionat de checklists, parts públics i plans de manteniment periòdics.

## Decisions

- `data.projects` continua sent el contenidor d’execució (ordres de servei).
- Subtipus canònics: `internal`, `work_order` (Ordre de treball), `maintenance`.
- Dos tipus de plantilla: **`todo`** (checkbox) i **`review`** (punts reutilitzables + estats).
- **Plataforma mai s’aplica ni s’assigna directament**: només s’inspecciona i es clona al tenant.
- `is_default` només és vàlid en plantilles de tenant (un default `todo` i un `review` per tenant).
- S’ha eliminat `checklist_template_applicability` / “Aplicabilitat”.
- Cada punt/plantilla té un sol idioma (`locale`). Traducció IA només al tenant (crea còpia nova).
- Compliance: les respostes desen snapshot (`answer_label`, `answer_color_token`, `answer_semantic`, `answer_blocks_closeout`); el que es va mostrar al client val per sempre.
- El selector d’ordres ordena plantilles pel `preferred_locale` del contacte/adreça.
- **Part / butlletí — dues capes (no confondre):**
  - `checklist_runs.public_report_payload` (+ escriptura DMS opcional) és un **snapshot d’execució mutable** fins a la publicació formal; útil per close-out i procedència, **no** és l’autoritat pública definitiva.
  - La **versió publicada immutable** del butlletí del client (`customer_intervention_report_versions` i agregat) és la font de veritat per shares i reader; vegeu [`docs/plans/custom-portal/README.md`](../custom-portal/README.md) i [`projection-and-retention.md`](../custom-portal/projection-and-retention.md).
- Destinacions de pla: polimòrfic `entity_type` + `entity_id` (registre `data.entity_types`).
- `data.assets.contact_site_id` permet equips al local del client (XOR amb `location_id`).

## Vocabulari UI

| Terme | Significat |
|-------|------------|
| Punts ToDo | Files checkbox d’una plantilla `todo` |
| Punts de revisió | Catàleg reutilitzable (`checklist_review_points`) usat a plantilles `review` |
| Incloure al part del client | `include_in_report` (sense relació amb IA) |

## Taules clau

| Taula | Rol |
|-------|-----|
| `checklist_review_points` / `_forks` | Catàleg de punts + traça de clonatge/versió |
| `checklist_templates` / `_versions` / `_items` / `_forks` | Autoria versionada (`todo`\|`review`) |
| `checklist_response_sets` / `_options` | Estats (semàfor, pass/fail, severitat) |
| `checklist_runs` / `_run_items` | Execució amb snapshot + respostes idempotents |
| `maintenance_plans` / `_forks` / `_checklists` / `_assignments` / `_occurrences` | Plans i generació |

## RPCs

- `api.publish_checklist_template_version` — congela snapshots dels punts en publicar
- `api.clone_checklist_review_point` / `api.clone_checklist_template` / `api.clone_maintenance_plan`
- `api.create_draft_from_published_checklist` / `api.sync_draft_checklist_items_from_points`
- `api.set_checklist_template_default`
- `api.archive_or_delete_review_point`
- `api.apply_checklist_to_project` (+ `_service`) — rebutja plantilles de plataforma
- `api.answer_checklist_run_item` — idempotent + snapshot d’opció
- `api.checklist_closeout_blockers` / `api.build_checklist_public_report` / `api.persist_…` / `api.build_and_persist_…`
- `api.generate_due_maintenance_orders` (service_role + cron horari)

## Migracions

- `20261143000001_…` — només `work_notes_html` (sense `visit_checklist_templates`)
- `20261159000001_checklist_maintenance_engine.sql` — DDL + RLS
- `20261159000002_checklist_maintenance_engine_rpcs.sql` — vistes, RPCs, seeds plataforma
- `20261159000003_checklist_preferred_locale_api.sql` — `preferred_locale` a API contacts

## UI

### tenant-portal
- `/field/checklist-points` — catàleg de punts (tenant + biblioteca)
- `/field/checklist-templates` — plantilles ToDo/review + biblioteca
- `/field/maintenance-plans` — plans (assignació desactivada sense plans tenant)
- Detall d’ordre — `VisitChecklistSection` (només plantilles tenant)
- Close-out — gates + part públic

### admin-portal
- `/dashboard/settings/checklist-points`
- `/dashboard/settings/checklist-templates`
- `/dashboard/settings/maintenance-plans`
- Sense IA a plataforma (contingut multi-idioma manual)

## Fora d’abast (fase posterior)

- Selector ric client → adreça / seu / ubicació / actiu
- Historial de plans i intervencions dins Contact/ContactSite
- Correcció `byweekday`/`bymonthday` al cron + membres/events canònics
- PDF imprimible i signatura client E2E (butlletí HTML + shares → [custom-portal](../custom-portal/README.md))
- Entitat formal d’albarà / facturació
