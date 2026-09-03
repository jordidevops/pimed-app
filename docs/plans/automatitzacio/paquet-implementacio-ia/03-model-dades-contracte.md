# Contracte de Model de Dades

Aquest document defineix el contracte que una migració SQL futura haurà de materialitzar. No és una migració final, però sí el llistat de camps i invariants que l'agent implementador no ha d'improvisar.

## 1. Entitats principals

### `data.automation_workflows`

Guarda definicions editables i blueprints clonables.

Camps obligatoris:

| Camp | Notes |
|------|-------|
| `id` | UUID PK |
| `tenant_id` | UUID nullable només si `is_blueprint=true` |
| `site_id` | UUID nullable. Restringeix workflow a site concret. |
| `name` | Text visible UI |
| `description` | Text nullable |
| `schema_version` | Integer, començar a 1 |
| `version` | Integer incrementat a cada canvi |
| `trigger_event` | Text canònic dot notation |
| `trigger_filters` | JSONB, default `{}` |
| `steps` | JSONB array validat per Zod |
| `is_active` | Boolean |
| `is_blueprint` | Boolean |
| `source_blueprint_id` | UUID nullable |
| `created_by` | UUID nullable per blueprints plataforma |
| `created_at`, `updated_at` | Timestamps |

Invariants:

- Si `is_blueprint = true`, `tenant_id` ha de ser NULL.
- Si `is_blueprint = false`, `tenant_id` ha de ser NOT NULL.
- `steps` ha de ser array no buit quan `is_active = true`.
- `trigger_event` no pot ser null.

### `data.automation_runs`

Guarda cada execució de workflow.

Camps obligatoris:

| Camp | Notes |
|------|-------|
| `id` | UUID PK |
| `workflow_id` | FK a `automation_workflows` |
| `workflow_version` | Versió usada en aquesta execució |
| `workflow_snapshot` | JSONB immutable amb steps i trigger usats |
| `tenant_id` | UUID obligatori |
| `site_id` | UUID nullable |
| `status` | Enum textual |
| `event_id` | Idempotency key de l'event que dispara la run |
| `trigger_event` | Event canònic |
| `trigger_entity_type` | Text |
| `trigger_entity_id` | UUID nullable |
| `source_kind` | `user`, `automation`, `system`, `external_api` |
| `actor_user_id` | UUID nullable |
| `correlation_id` | Text/UUID |
| `causation_run_id` | UUID nullable |
| `depth` | Integer default 0 |
| `context` | JSONB snapshot construït amb context-builder |
| `started_at`, `completed_at` | Timestamps |
| `cancelled_by`, `cancelled_at`, `cancel_reason` | Per cancel·lació manual |

Statuses V1:

- `PENDING`
- `RUNNING`
- `WAITING_HUMAN`
- `WAITING_EXTERNAL`
- `WAITING_TIMER`
- `COMPLETED`
- `FAILED`
- `CANCELLED`

Invariants:

- Unique: `(workflow_id, event_id)`.
- `workflow_snapshot` no es modifica després de crear la run.
- `status` només pot avançar per la state machine definida a `04-state-machine-i-concurrencia.md`.

### `data.automation_step_runs`

Guarda l'estat de cada step d'una run.

Camps obligatoris:

| Camp | Notes |
|------|-------|
| `id` | UUID PK |
| `workflow_run_id` | FK a `automation_runs` |
| `tenant_id` | UUID denormalitzat per RLS i queries ràpides |
| `site_id` | UUID nullable |
| `step_id` | ID del step dins `workflow_snapshot.steps` |
| `step_name` | Snapshot visible |
| `step_type` | Text |
| `status` | Enum textual |
| `attempt_number` | Integer default 0 |
| `max_attempts` | Snapshot del retry policy |
| `input` | JSONB |
| `output` | JSONB nullable |
| `error` | JSONB nullable |
| `correlation_key` | Text nullable per callbacks/waits |
| `locked_at` | Timestamp nullable |
| `locked_by` | Text nullable (worker invocation id) |
| `started_at`, `completed_at` | Timestamps |
| `approved_by`, `approved_at` | UUID/timestamp nullable |

Statuses V1:

- `PENDING`
- `RUNNING`
- `WAITING_HUMAN`
- `WAITING_EXTERNAL`
- `WAITING_TIMER`
- `COMPLETED`
- `FAILED`
- `SKIPPED`
- `CANCELLED`

Invariants:

- Unique: `(workflow_run_id, step_id)`.
- Un worker només pot passar de `PENDING` a `RUNNING` amb update atòmic.
- Steps en `WAITING_*` no poden ser reexecutats per retry de cua normal.

### `data.automation_pending_approvals`

Inbox BAM.

Camps obligatoris:

| Camp | Notes |
|------|-------|
| `id` | UUID PK |
| `workflow_run_id` | FK |
| `step_run_id` | FK unique per step d'aprovació |
| `tenant_id`, `site_id` | Scope |
| `assigned_to_user_id` | Nullable |
| `assigned_to_role` | Nullable |
| `assigned_to_site_id` | Nullable |
| `status` | `PENDING`, `APPROVED`, `REJECTED`, `EXPIRED`, `CANCELLED` |
| `title` | Text renderitzat |
| `summary` | Text renderitzat |
| `context_preview` | JSONB per UI |
| `due_at` | Timestamp nullable |
| `resolved_by`, `resolved_at`, `resolution_comment` | Resolució |

Invariants:

- Ha d'existir `assigned_to_user_id` o `assigned_to_role`.
- Una approval només es pot resoldre una vegada.
- Resoldre approval ha d'emetre audit log.

### `data.automation_scheduled_triggers`

Recomanada per evitar escanejar documents sencers cada dia.

| Camp | Notes |
|------|-------|
| `id` | UUID PK |
| `tenant_id`, `site_id` | Scope |
| `event_type` | Ex: `date_field.reached` |
| `entity_type`, `entity_id` | Entitat relacionada |
| `field_key` | Ex: `data_fi_contracte` |
| `scheduled_for` | Timestamp/date en UTC |
| `payload` | JSONB |
| `status` | `PENDING`, `ENQUEUED`, `FIRED`, `CANCELLED` |
| `idempotency_key` | Text unique |
| `created_at`, `fired_at` | Timestamps |

Invariants:

- Unique: `idempotency_key`.
- `process-date-triggers` processa per keyset pagination: `scheduled_for`, `id`.

## 2. Camps comuns d'auditoria

Totes les taules han de seguir el patró d'auditoria del repo:

- Canvis de cicle de vida han d'escriure a `data.audit_logs`.
- `action` en MAJÚSCULES_AMB_GUIÓ_BAIX.
- `entity_type` sense schema: `automation_workflow`, `automation_run`, `automation_step_run`, `automation_approval`.
- `payload` sense secrets.

Actions mínimes:

- `AUTOMATION_WORKFLOW_CREATED`
- `AUTOMATION_WORKFLOW_UPDATED`
- `AUTOMATION_WORKFLOW_ACTIVATED`
- `AUTOMATION_WORKFLOW_DEACTIVATED`
- `AUTOMATION_RUN_STARTED`
- `AUTOMATION_RUN_COMPLETED`
- `AUTOMATION_RUN_FAILED`
- `AUTOMATION_RUN_CANCELLED`
- `AUTOMATION_APPROVAL_CREATED`
- `AUTOMATION_APPROVAL_APPROVED`
- `AUTOMATION_APPROVAL_REJECTED`
- `AUTOMATION_STEP_RETRIED`

## 3. RLS i permisos esperats

Regles conceptuals:

- Tenant members només veuen workflows/runs del seu `tenant_id` actiu.
- Site-only users només veuen runs del seu `site_id`, excepte si el workflow és tenant-global i les dades són visibles per policy.
- Approvals assignades a rol de site només són visibles als membres amb aquest rol al site.
- Gestió de workflows requereix permís de configuració/automatització, no qualsevol member.
- Retry/cancel/skip requereixen rol `owner`/`manager` o permís explícit.

## 4. Vistes API recomanades

Per al tenant-portal, exposar via `api.*`:

- `api.automation_workflows`
- `api.automation_runs`
- `api.automation_step_runs`
- `api.automation_pending_approvals`

No exposar secrets, config interna sensible ni payloads complets si poden contenir dades no visibles per l'usuari.

## 5. Indexos conceptuals

- `automation_workflows(tenant_id, trigger_event) WHERE is_active`
- `automation_workflows(site_id, trigger_event) WHERE is_active`
- `automation_runs(tenant_id, status, started_at DESC)`
- `automation_runs(workflow_id, event_id)` unique
- `automation_step_runs(workflow_run_id, status)`
- `automation_step_runs(correlation_key) WHERE correlation_key IS NOT NULL`
- `automation_pending_approvals(tenant_id, status, due_at)`
- `automation_scheduled_triggers(status, scheduled_for, id)`

## 6. Notes per a migracions futures

Quan s'implementi aquest model en SQL:

1. Cal regenerar `database.types.ts` seguint les instruccions del repo.
2. Cal copiar els tipus a `supabase/functions/_shared/database.types.ts`.
3. Cal afegir RLS i vistes `api.*`.
4. Cal afegir audit triggers o inserts explícits segons el patró del projecte.
