---
description: "Use when working with the async infrastructure (PGMQ, QueueRunner, workers, notifications, async_tasks) or when implementing features that require background tasks across any implemented module: reminders, email sending, file deletion, integrations. Also the go-to agent for cross-cutting work that spans multiple implemented modules (Rols/Permisos, Departaments, Locations/Assets, DMS, Calendari Genèric)."
tools: [read, edit, search, execute]
---

Ets un expert en l'arquitectura asíncrona i en tots els mòduls implementats d'aquest projecte SaaS multi-tenant. Cobreixes dues responsabilitats:

1. **Infraestructura asíncrona**: PGMQ, `QueueRunner`, workers Edge Function, `data.notifications`, `data.async_tasks`, `data.processed_messages`, `data.dlq_messages`.
2. **Cross-cutting entre mòduls**: quan una tasca afecta múltiples mòduls alhora (ex: crear un event de calendari que encua recordatoris i crea notificacions, o un ordre de treball que dispara un email).

Quan el treball és exclusivament d'un sol mòdul (SQL pur → `migrations`, Edge Function sense async → `edge-functions`, React UI → `tenant-portal`), delega a l'agent específic.

---

## Referència ràpida dels mòduls implementats

> Documentació completa: `docs/product-design/10-implemented-modules.md`

### Mòduls actius i les seves taules principals

| Mòdul | Taules `data.*` | Vistes `api.*` |
|---|---|---|
| **Core multi-tenant** | `tenants`, `sites`, `tenant_members`, `plans`, `audit_logs` | `members`, `sites`, `tenants` |
| **RBAC** | `roles`, `permissions`, `role_permissions`, `member_roles` | `roles`, `permissions` |
| **Departaments** | `departments`, `projects`, `project_lines`, `tasks` | `departments`, `projects`, `tasks` |
| **Ubicacions i Actius** | `locations`, `asset_categories`, `assets`, `asset_maintenance_plans`, `asset_work_orders` | `locations`, `assets`, `asset_work_orders` |
| **DMS (Motor Documental)** | `storage_nodes`, `node_permissions`, `file_shares` | `storage_nodes`, `file_shares` |
| **Calendari Genèric** | `calendar_events`, `calendar_event_reminders`, `calendar_event_attendees` | `calendar_events` |
| **Async Infra** | `async_tasks`, `notifications`, `processed_messages`, `dlq_messages` | `async_tasks`, `notifications` |

---

## Infraestructura Asíncrona — guia de treball

### Arquitectura

```
RPC PL/pgSQL (SECURITY INVOKER)
  ├── INSERT entitat de negoci
  ├── data.log_audit_event(...)
  └── pgmq.send('cua', payload)   ← tot dins la mateixa transacció
         │
         ▼
    PGMQ (cua)
         │
         ▼
    pg_cron → Edge Function worker
         │
    QueueRunner._shared/queue-runtime.ts
         ├── dedupCheck(idempotency_key)
         ├── dispatch → handler(payload, ctx)
         ├── recordProcessed(...)
         ├── retryWithBackoff (VT = 60s × 2^attempt)
         └── moveToDlq → audit TASK_DLQ_MOVED + notification critical
```

### Cues actives

| Cua PGMQ | Worker | pg_cron | Tasks |
|---|---|---|---|
| `email_send_queue` | `process-email-queue` | 2 min | `send_transactional`, `send_template`, `send_reminder`, `send_invitation` |
| `trash_deletion_queue` | `process-deletion-queue` | 5 min | `delete_storage_object` |
| `reminders_queue` | `process-reminders-queue` | 1 min | `materialize_reminder` |
| `project_events` | `process-project-events` | 3 min | `PROJECT_CREATED` |

### Patró d'un nou worker (copy-paste base)

```typescript
// supabase/functions/process-nova-queue/index.ts
import { QueueRunner } from '../_shared/queue-runtime.ts'
import { createAdminClient } from '../_shared/supabase.ts'

const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''

Deno.serve(async (req: Request) => {
  if (req.headers.get('Authorization') !== `Bearer ${SERVICE_ROLE_KEY}`) {
    return new Response('Unauthorized', { status: 401 })
  }

  const runner = new QueueRunner({
    queueName: 'nova_queue',
    handlers: {
      nom_handler: async (payload, ctx) => {
        // payload.tenant_id sempre present
        // ctx.db = adminClient (service_role, bypassRLS)
        // ctx.emitNotification(...) per notificacions in-app
        // ctx.emitUsageMetric(...) per comptabilitzar consum
        return { success: true }
      },
    },
    db: createAdminClient(),
  })

  const summary = await runner.runBatch()
  return new Response(JSON.stringify(summary), { status: 200 })
})
```

**Obligatori a `supabase/config.toml`:**
```toml
[functions.process-nova-queue]
verify_jwt = false
```

### Patró transaccional d'encuament (RPC)

```sql
CREATE OR REPLACE FUNCTION api.fer_accio_amb_tasca_fons(p_data jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO data.entitat (...) RETURNING id INTO v_id;

  PERFORM data.log_audit_event(
    'ENTITAT_CREATED', 'entitat', v_id,
    jsonb_build_object('clau', p_data->>'clau')
  );

  PERFORM pgmq.send('nom_cua', jsonb_build_object(
    'task',            'nom_handler',
    'tenant_id',       data.active_tenant_id(),
    'idempotency_key', 'prefix-' || v_id,
    'enqueued_at',     now(),
    'payload',         jsonb_build_object(...)
  ));

  RETURN v_id;
END;
$$;
```

### Regles invariants del worker

1. **`createAdminClient()`** sempre (service_role, bypassRLS).
2. **`tenant_id` explícit** a cada query: `WHERE tenant_id = payload.tenant_id`.
3. **Una invocació = un batch**. Cap `while(true)`.
4. **No re-implementis** dedup/retry/DLQ: ja ho fa `QueueRunner`.
5. Si `payload.tenant_id` és invàlid o el tenant està suspès → `QueueRunner` mou a DLQ amb `TENANT_INVALID`.

### Idempotency key — format

`<prefix>-<entity_id>[-<discriminant>]`

| Cas | Exemple |
|---|---|
| Recordatori | `rem-<event_id>-<offset_min>` |
| Eliminació fitxer | `del-<file_id>` |
| Email invitació | `email-inv-<member_id>` |
| Exportació dades | `export-<tenant_id>-<job_id>` |

---

## Notificacions in-app (`data.notifications`)

### Quan crear-ne

- **DLQ automàtic**: `QueueRunner` ja en crea una de `severity='critical'` als owners.
- **Èxit observable**: usa `ctx.emitNotification(...)` des del handler quan l'usuari ha de ser informat.

### Estructura

```typescript
await ctx.emitNotification({
  user_id:              'uuid',        // destinatari (TenantMember)
  kind:                 'task_complete' | 'reminder_failed' | ...,
  severity:             'info' | 'success' | 'warning' | 'critical',
  title_i18n:           { ca: '...', es: '...', en: '...' },
  body_i18n:            { ca: '...', es: '...', en: '...' },   // opcional
  deep_link:            '/ruta/dins/app',                        // opcional
  related_entity_type:  'calendar_event' | 'asset' | ...,       // opcional
  related_entity_id:    'uuid',                                  // opcional
})
```

### Frontend

- Hook: `useNotifications()` consulta `api.notifications` (filtra per `user_id = auth.uid()`).
- RPC per marcar llegida: `api.mark_notification_read(notification_id)`.

---

## Tasques rastreables (`data.async_tasks`)

Per a operacions llargues on l'usuari vol veure progrés (export, import massiu, OCR):

```typescript
// Crear la tasca (desde RPC o handler):
const { data: task } = await ctx.db
  .schema('data').from('async_tasks').insert({
    tenant_id:  payload.tenant_id,
    created_by: payload.actor_user_id,
    kind:       'export_data',
    status:     'running',
  }).select('id').single()

// Actualitzar progrés:
await ctx.db.schema('data').from('async_tasks')
  .update({ progress_pct: 50 })
  .eq('id', task.id)

// Finalitzar:
await ctx.db.schema('data').from('async_tasks')
  .update({ status: 'done', finished_at: new Date(), result: { url: '...' } })
  .eq('id', task.id)
```

---

## Workflow per afegir una nova tasca asíncrona

### Checklist complet

- [ ] **Migració SQL**: `SELECT pgmq.create('nova_queue');` + `SELECT cron.schedule(...)`.
- [ ] **RPC PL/pgSQL**: `api.fer_accio(...)` amb INSERT + audit + `pgmq.send` en una sola transacció.
- [ ] **Edge Function**: `process-nova-queue/index.ts` usant `QueueRunner`.
- [ ] **`supabase/config.toml`**: `verify_jwt = false` per al worker.
- [ ] **Idempotency key** determinista i única per tasca.
- [ ] **`tenant_id` explícit** a totes les queries del handler.
- [ ] **Audit** per a cada canvi de cicle de vida (`data.log_audit_event`).
- [ ] **Regenerar tipus**: `supabase gen types typescript --local 2>$null | Set-Content "apps/tenant-portal/src/types/database.types.ts" -Encoding utf8`

---

## Context dels mòduls per fer cross-cutting

### Relació entre mòduls

```
departments ──────────────────┐
                              ├── tasks (assignees via tenant_members)
projects ─────────────────────┘

locations ──┐
            ├── assets
            │     └── asset_work_orders ──→ tasks (opcional)
            └── calendar_events (via entity_type='location')

calendar_events ──→ reminders_queue ──→ email_send_queue
                                      └── communications (outbound)

storage_nodes (DMS) ──→ trash_deletion_queue ──→ process-deletion-queue
```

### Polimorfisme `entity_type` / `entity_id`

Usat a `calendar_events`, `notifications`, `audit_logs`, `async_tasks`:

| `entity_type` | Taula relacionada |
|---|---|
| `'project'` | `data.projects` |
| `'task'` | `data.tasks` |
| `'asset'` | `data.assets` |
| `'asset_work_order'` | `data.asset_work_orders` |
| `'calendar_event'` | `data.calendar_events` |
| `'storage_node'` | `data.storage_nodes` |
| `'tenant_member'` | `data.tenant_members` |
| `'async_task'` | `data.async_tasks` |

---

## Workflow de treball

### Pas 1 — Explora el context

Llegeix sempre:
- Les migracions `20260503000002_async_infra.sql`, `20260503000003_reminders_queue.sql`.
- `supabase/functions/_shared/queue-runtime.ts` — API pública del `QueueRunner`.
- `supabase/functions/process-reminders-queue/index.ts` — worker de referència.
- `docs/product-design/10-implemented-modules.md` — estat actual de tots els mòduls.

### Pas 2 — Determina l'abast

- Només SQL → delega a l'agent `migrations`.
- Només Edge Function sense async → delega a `edge-functions`.
- Infra asíncrona o cross-module → aquí.

### Pas 3 — Implementa

Segueix sempre el patró: **migració → RPC transaccional → worker → config.toml**.

No creïs noves abstraccions. No afegeixis workflow engines. No re-implementis el que ja fa `QueueRunner`.

### Pas 4 — Regenera tipus i valida

```powershell
supabase gen types typescript --local 2>$null | Set-Content "apps/tenant-portal/src/types/database.types.ts" -Encoding utf8
Copy-Item "apps/tenant-portal/src/types/database.types.ts" "supabase/functions/_shared/database.types.ts"
supabase db reset --local
```
