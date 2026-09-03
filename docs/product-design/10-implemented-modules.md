# 10. Mòduls Implementats — Estat Actual del Codebase

> **Última actualització**: 3 de maig de 2026
>
> Aquest document descriu l'**estat real implementat** del projecte: taules, vistes,
> RPCs, Edge Functions i components de frontend que existeixen i funcionen.
> No és un document de disseny futur; és la font de veritat de "el que tenim ara".

---

## Índex ràpid

| Mòdul | Migracions principals | Estat |
|---|---|---|
| [Core multi-tenant + RLS](#1-core-multi-tenant--rls) | `20260401*` | ✅ Complet |
| [Motor Documental (DMS)](#2-motor-documental-dms) | `20260413*`, `20260502210551` | ✅ Complet |
| [Email outbound + BYOS](#3-email-outbound--byos) | `20260415000002`, `20260427*` | ✅ Complet |
| [Rols i Permisos (RBAC)](#4-rols-i-permisos-rbac) | `20260429000002` | ✅ Complet |
| [Departaments, Projectes i Tasques](#5-departaments-projectes-i-tasques) | `20260502000001` | ✅ Complet |
| [Ubicacions i Actius (EAM/CAFM)](#6-ubicacions-i-actius-eamcafm) | `20260502000002` | ✅ Complet |
| [Calendari Genèric](#7-calendari-genèric) | `20260503000001` | ✅ Complet |
| [Infraestructura Asíncrona (PGMQ)](#8-infraestructura-asíncrona-pgmq) | `20260503000002–4` | ✅ Complet |

---

## 1. Core multi-tenant + RLS

### Taules principals (`data.*`)
| Taula | Descripció |
|---|---|
| `data.tenants` | Organitzacions. `slug` únic, `plan_id`, `status`. |
| `data.sites` | Seus/locals dins un tenant. Quota gestionada per trigger. |
| `data.tenant_members` | Membresia usuari-tenant. `site_id NULL` = rol global; `site_id NOT NULL` = rol limitat al site. |
| `data.plans` | Plans de subscripció (free, starter, pro…). `max_sites`, `features jsonb`. |
| `data.user_permissions_cache` | Cache de permisos per fallback quan el JWT és antic. |
| `data.audit_logs` | Log immutable de canvis de cicle de vida. |

### Funcions clau
- `data.jwt_user_tenants()` — llegeix `app_metadata.user_tenants` del JWT o fa fallback al cache.
- `data.active_tenant_id()` — llegeix el header `x-tenant-id` per al filtre UX.
- `data.log_audit_event(action, entity_type, entity_id, payload)` — insereix audit log.
- `data.provision_tenant(name, slug, plan_id)` — crea tenant + site inicial de forma atòmica.
- `data.custom_access_token_hook(event)` — Auth Hook que injecta `user_tenants` al JWT.

### Patró RLS

```sql
-- Lectura per pertinença al tenant
USING (data.jwt_user_tenants() ? tenant_id::text)

-- Escriptura per rol global (owner/manager)
WITH CHECK (
  (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
)
```

---

## 2. Motor Documental (DMS)

### Migracions
- `20260413000010_acl_node_permissions.sql` — ACL per node.
- `20260413000011_multi_drive.sql` — Drives multi-tenant.
- `20260413000012_control_plane.sql` — Control plane de Storage.
- `20260413000014_tenant_lifecycle.sql` — Cicle de vida del tenant.
- `20260502210551_documents_core.sql` — Estructura de carpetes i fitxers.

### Taules (`data.*`)
| Taula | Descripció |
|---|---|
| `data.storage_nodes` | Carpetes i fitxers en un arbre jeràrquic. |
| `data.node_permissions` | ACL per node: `(node_id, grantee_type, grantee_id, permission)`. |
| `data.file_shares` | Share links signats per a fitxers concrets. |
| `data.trash_deletion_queue` | Cua de fitxers a esborrar (s'integra amb PGMQ). |

### Edge Functions
- `request-upload` — genera URL presignada i crea node.
- `confirm-upload` — confirma upload, actualitza mides i estat.
- `get-file-url` — genera URL signada o link de share.
- `process-deletion-queue` — worker que processa `trash_deletion_queue` via `QueueRunner`.
- `resolve-share` — resol tokens de share link.

### Vistes `api.*`
- `api.storage_nodes` — arbre de nodes filtrat per tenant actiu.
- `api.file_shares` — share links actius.

---

## 3. Email outbound + BYOS

### Migracions
- `20260415000002_email_system_core.sql` — Cua d'email, dominis, plantilles.
- `20260427000001_email_analytics_domains_draft.sql` — Analítica de dominis.
- `20260427000005_hub_and_spoke_core.sql` — Hub and spoke multi-site.
- `20260427000006_hub_and_spoke_bridge.sql` — Bridge de relay.
- `20260427000007_email_branding_templates_site.sql` — Branding per site.

### Taules (`data.*`)
| Taula | Descripció |
|---|---|
| `data.email_queue` | Cua d'enviaments pendents. |
| `data.email_domains` | Dominis BYOS (Bring Your Own SMTP). |
| `data.email_templates` | Plantilles i18n per tenant/site. |
| `data.communications` | Registre de comunicacions sortints (email, SMS, WhatsApp). |

### Edge Functions
- `process-email-queue` — worker que processa `email_queue` via Resend/SMTP.
- `configure-byos` — configura i valida un domini BYOS.
- `manage-email-domain` — gestió de dominis.
- `resend-webhook` — processa webhooks de Resend.

---

## 4. Rols i Permisos (RBAC)

### Migració
- `20260429000002_rbac_permissions.sql`

### Model
```
data.roles          → Rol definit per tenant (pot heretar d'un rol global)
data.permissions    → Permís atòmic (action + resource)
data.role_permissions → M2M roles ↔ permissions
data.member_roles   → Assignació de rol a tenant_member (+ scope site)
```

### Filosofia
- **Rols globals de tenant**: `owner`, `manager`, `member`, `viewer` (hardcoded al JWT).
- **RBAC granular**: taules addicionals per permetre rols personalitzats per accions concretes.
- **Precedència**: les polítiques RLS comproven primer el rol global del JWT; el RBAC granular s'aplica a accions de backoffice i lògica de negoci específica.

---

## 5. Departaments, Projectes i Tasques

### Migració
- `20260502000001_departments_projects_tasks.sql`

### Taules (`data.*`)
| Taula | Descripció |
|---|---|
| `data.departments` | Departaments del tenant. `parent_id` per a jerarquia. |
| `data.projects` | Encàrrecs/obres del client. `status`, `priority`, `tenant_id`, `site_id`. |
| `data.project_lines` | Línies de pressupost d'un projecte. |
| `data.tasks` | Tasques associades a projectes o departaments. `assignee_id`, `due_at`. |

### Vistes `api.*`
- `api.departments` — departaments filtrats per tenant actiu.
- `api.projects` — projectes (amb joins a site, assignee).
- `api.tasks` — tasques filtrades per tenant actiu.

> **Nota**: "Project" és l'encàrrec del client. NO confondre amb "tasca tècnica de fons" (`async_tasks`).

---

## 6. Ubicacions i Actius (EAM/CAFM)

### Migració
- `20260502000002_locations_assets.sql`

### Taules (`data.*`)
| Taula | Descripció |
|---|---|
| `data.locations` | Estructura física: edificis, plantes, zones, sales. `parent_id` per jerarquia. `location_type`. |
| `data.asset_categories` | Categories d'actius (HVAC, IT, Vehicles…). Jerarquia per `parent_id`. |
| `data.assets` | Actius físics: número de sèrie, estat, `location_id`, `category_id`. |
| `data.asset_maintenance_plans` | Plans de manteniment preventiu associats a un actiu. |
| `data.asset_work_orders` | Ordres de treball (correctiu/preventiu/predictiu). |

### Vistes `api.*`
- `api.locations` — arbre d'ubicacions per tenant actiu.
- `api.assets` — actius amb informació de categoria i ubicació.
- `api.asset_work_orders` — ordres de treball obertes.

---

## 7. Calendari Genèric

### Migració
- `20260503000001_calendar_events.sql`

### Taules (`data.*`)
| Taula | Descripció |
|---|---|
| `data.calendar_events` | Esdeveniments: `title`, `starts_at`, `ends_at`, `all_day`, `entity_type/id` (polimòrfic). |
| `data.calendar_event_reminders` | Definicions de recordatori d'un event: `offset_minutes`, `channel` (email/push/sms). |
| `data.calendar_event_attendees` | Assistents (usuaris interns o contactes externs). |

### RPC transaccional
```sql
api.create_calendar_event_with_reminders(p_event_data jsonb, p_reminders jsonb[])
  → uuid
```
Insereix l'event + audit + encua missatges a `reminders_queue` en una sola transacció.

### Vistes `api.*`
- `api.calendar_events` — events del tenant actiu amb joins a attendees i reminders.

---

## 8. Infraestructura Asíncrona (PGMQ)

### Migracions
- `20260503000002_async_infra.sql` — Taules base, RPCs genèriques.
- `20260503000003_reminders_queue.sql` — Cua de recordatoris + cron.
- `20260503000004_async_infra_fixes.sql` — Fixes de bugs (COALESCE array_length).

### Taules (`data.*`)
| Taula | Descripció |
|---|---|
| `data.async_tasks` | Rastreig d'estat per a tasques observables per l'usuari (export, import massiu…). |
| `data.notifications` | Inbox in-app per TenantMember. `severity`, `kind`, `title_i18n`, `read_at`. |
| `data.processed_messages` | Dedup idempotent per cua. PK `(queue_name, idempotency_key)`. |
| `data.dlq_messages` | Dead Letter Queue: missatges amb ≥3 intents fallits. |

### RPCs genèriques (`api.*`)
```sql
api.read_queue_batch(queue text, count int, vt int)
  → SETOF (msg_id bigint, read_ct int, message jsonb)

api.archive_queue_message(queue text, msg_id bigint)
  → void

api.mark_notification_read(notification_id uuid)
  → void
```

### Lib compartida: `_shared/queue-runtime.ts`

Classe `QueueRunner` 100% TypeScript estàndard (zero imports Deno). Proveeix:
- **Dedup** via `data.processed_messages`.
- **Dispatch** per `task` key al handler registrat.
- **Retry exponencial**: VT = `60s × 2^(read_ct-1)`, màxim `maxAttempts` (default 3).
- **DLQ automàtic**: al darrer intent, mou a `data.dlq_messages` + audit `TASK_DLQ_MOVED` + notificació `critical` als owners.
- **Audit de batch**: `ASYNC_BATCH_PROCESSED` al final de cada `runBatch()`.

```typescript
import { QueueRunner } from '../_shared/queue-runtime.ts'

const runner = new QueueRunner({
  queueName: 'reminders_queue',
  handlers: {
    materialize_reminder: async (payload, ctx) => { /* ... */ },
  },
  db: createAdminClient(),
})
const summary = await runner.runBatch()
```

### Cues actives

| Cua PGMQ | Worker Edge Function | pg_cron | Tasks previstes |
|---|---|---|---|
| `email_send_queue` | `process-email-queue` | cada 2 min | `send_transactional`, `send_template`, `send_reminder`, `send_invitation` |
| `trash_deletion_queue` | `process-deletion-queue` | cada 5 min | `delete_storage_object` |
| `reminders_queue` | `process-reminders-queue` | cada 1 min | `materialize_reminder`, `send_reminder` |

### Patró d'encuament transaccional

**Sempre des d'una RPC PL/pgSQL** (mai des de triggers de negoci, mai des del codi TypeScript directament):

```sql
-- Dins la mateixa transacció:
INSERT INTO data.calendar_events (...) RETURNING id INTO v_event_id;
PERFORM data.log_audit_event('CALENDAR_EVENT_CREATED', 'calendar_event', v_event_id, ...);
PERFORM pgmq.send('reminders_queue', jsonb_build_object(
  'task', 'materialize_reminder',
  'tenant_id', data.active_tenant_id(),
  'idempotency_key', 'rem-' || v_event_id || '-' || offset,
  'enqueued_at', now(),
  'payload', reminder_data
));
-- COMMIT = tot o res
```

### Anti-patrons (prohibits)

- ❌ `pgmq.send` des de triggers SQL de negoci.
- ❌ Workers amb JWT fictici per simular RLS (usa `service_role` + `tenant_id` explícit al payload).
- ❌ Loops infinits dins l'Edge Function (una invocació = un batch).
- ❌ Re-implementar dedup/retry/DLQ a cada handler (usa `QueueRunner`).
- ❌ Taula `events` paral·lela a `audit_logs`.
- ❌ Taula `jobs` genèrica (els encàrrecs del client són `projects`).
- ❌ Una sola cua compartida per a totes les tasques.

---

## Annex: Convencions creuades

### Audit — naming convention d'`action`
`MAJÚSCULES_AMB_GUIÓ_BAIX`: `CALENDAR_EVENT_CREATED`, `REMINDER_SENT`, `TASK_DLQ_MOVED`, `FILE_DELETED`, `MEMBER_INVITED`, `TENANT_PLAN_CHANGED`…

### Payload PGMQ — estructura mínima obligatòria

```json
{
  "task": "nom_del_handler",
  "tenant_id": "uuid",
  "idempotency_key": "string-determinista",
  "enqueued_at": "ISO-8601",
  "payload": { "...dades específiques..." }
}
```

### Polimorfisme `entity_type` / `entity_id`

Usat a `calendar_events`, `notifications`, `audit_logs`, `dlq_messages`:
- `entity_type`: nom de la taula sense schema (`'project'`, `'asset'`, `'calendar_event'`…).
- `entity_id`: uuid de l'entitat.
