# Public Portal Leads - V2 Plan

## Context

Actualment, el flux de leads ja crea notificacions i correus via cua (`leads_notification_queue`) i envia correus per `api.enqueue_email`.

Amb V1 minim, quan entra un lead es crea un event a `data.calendar_events` (`entity_type = 'public_lead'`, `entity_id = lead.id`) per donar visibilitat al calendari.

Aquest document defineix la V2 per completar el cicle de vida: recordatoris, sincronitzacio d'estat i millora de la taula de leads.

## Objectius V2

1. Afegir recordatori automatic de 1 dia per cada lead nou.
2. Sincronitzar canvis d'estat del lead amb l'event de calendari.
3. Cancel lar recordatoris pendents quan el lead es tanqui.
4. Millorar UX de la taula de leads al tenant-portal.

## Arquitectura Async Actual (base)

- Cua: `reminders_queue`
- Worker: `supabase/functions/process-reminders-queue/index.ts`
- Dispatcher: `data.invoke_reminders_queue_worker()` + `pg_cron` cada 1 minut
- Handler actiu: `materialize_reminder`
- Contracte payload:
  - `task = 'materialize_reminder'`
  - `tenant_id`, `site_id`, `actor_user_id`
  - `entity_type = 'calendar_event'`
  - `entity_id = <calendar_event.id>`
  - `payload.offset_minutes` (ex: `1440`)

El worker calcula `sendAt = event.start_at - offset_minutes` i encua email via `api.enqueue_email` amb `scheduled_at` si escau.

## Disseny V2

## 1) Model de dades

### 1.1 Enllac explicit lead -> event

Afegir columna a `data.public_leads`:

- `calendar_event_id uuid NULL REFERENCES data.calendar_events(id) ON DELETE SET NULL`

Beneficis:

- lookup directe sense cercar per `(entity_type, entity_id)`
- mantenibilitat quan el lead canvia d'estat

### 1.2 Idempotencia forta d'events

Afegir index unic a `data.calendar_events`:

- `UNIQUE (entity_type, entity_id)`

Per leads:

- un sol event per lead (`entity_type='public_lead'`)

## 2) Creacio + recordatori (alta lead)

### 2.1 Flux transaccional recomanat (nova RPC)

Crear RPC de servei (SECURITY DEFINER) per evitar logica fragmentada al worker:

- `api.create_lead_calendar_event_with_reminder(...)`

Responsabilitats:

1. Crear o reutilitzar l'event de calendari del lead (idempotent).
2. Guardar `calendar_event_id` a `data.public_leads`.
3. Encuar recordatori 1 dia (`offset_minutes = 1440`) a `reminders_queue` amb `pgmq.send`.

Payload recordatori proposat:

```json
{
  "task": "materialize_reminder",
  "tenant_id": "<tenant_uuid>",
  "site_id": null,
  "actor_user_id": "<owner_or_manager_uuid>",
  "entity_type": "calendar_event",
  "entity_id": "<calendar_event_id>",
  "idempotency_key": "rem-<calendar_event_id>-1440",
  "payload": {
    "offset_minutes": 1440,
    "channel": "email"
  },
  "enqueued_at": "now()"
}
```

Nota: `process-reminders-queue` ja sap processar aquest payload sense canvis.

## 3) Canvi d'estat lead -> sync calendar

### 3.1 Nova RPC d'estat

Crear `api.update_public_lead_status(...)` (SECURITY DEFINER) per centralitzar:

- update de `data.public_leads.status`
- update de `data.calendar_events` associat
- auditoria `data.audit_logs`

### 3.2 Regles de sincronitzacio

Quan `status` passa a `converted` o `rejected`:

1. Actualitzar descripcio de l'event amb:
   - `closed_at`
   - `closed_status`
2. Ajustar titol (opcional):
   - `[TANCAT] Nou lead: ...`
3. Eliminar recordatoris pendents del mateix event.

## 4) Cancel lacio de recordatoris pendents

Crear helper SQL intern:

- `data.cancel_reminders_for_calendar_event(p_event_id uuid)`

Estrategia:

- esborrar missatges no processats de `pgmq.q_reminders_queue`
- filtrar per `message->>'entity_type' = 'calendar_event'` i `message->>'entity_id' = p_event_id::text`

Important:

- aplicar-ho en la mateixa transaccio de tancament si es possible
- si falla la cancel lacio, log warning i registrar audit

## 5) Millores taula Leads (tenant-portal)

Objectiu: gestio operativa des de la mateixa taula.

Millores proposades:

1. Dropdown inline de `status` per fila (`new/contacted/converted/rejected`).
2. Filtres per estat (multi-select) i per portal.
3. Columna de data/hora completa (no nomes data).
4. Paginacio quan hi ha mes de 50 registres.
5. Accio "Veure al calendari" quan existeix `calendar_event_id`.
6. Badges de comptador per estat a la capcalera.

## 6) Auditoria i seguretat

Accions d'auditoria noves:

- `LEAD_CALENDAR_EVENT_CREATED`
- `LEAD_REMINDER_ENQUEUED`
- `LEAD_STATUS_CHANGED`
- `LEAD_REMINDERS_CANCELLED`

Regles:

- Cap dada sensible a `payload` d'audit.
- Mantenir model multi-tenant (`tenant_id` sempre explicit).
- Totes les operacions d'estat via RPC, no update directe des de frontend.

## 7) Desplegament incremental recomanat

1. Migracions de schema (FK + index unic + helper cancel reminders).
2. RPC de create/sync status.
3. Integracio al worker de leads per cridar nova RPC.
4. UI de taula leads (status inline + filtres + paginacio).
5. QA end-to-end amb cues locals (`process-leads-queue`, `process-reminders-queue`, `process-email-queue`).

## 8) Acceptacio funcional

1. Quan entra un lead, apareix event al calendari amb data/hora recepcio.
2. Event te recordatori de 1 dia encuat a `reminders_queue`.
3. Quan lead es tanca (`converted/rejected`), event queda marcat i sense recordatoris pendents.
4. La taula de leads permet canviar estat i filtrar operativament.
