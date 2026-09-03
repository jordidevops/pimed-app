> ⚠️ **DOCUMENT ARXIVAT** — Aquest document era el disseny i el prompt de partida.
> La implementació real ja existeix al codebase. Consulta en canvi:
> - **`docs/product-design/10-implemented-modules.md`** — Estat actual dels mòduls implementats.
> - **`.github/copilot-instructions.md`** (secció "Infraestructura Asíncrona") — Regles de treball.
> - **`.github/agents/async-infra.agent.md`** — Agent especialitzat per treballar-hi.
>
> Conservat per referència històrica (decisions de disseny, anti-patrons, ordre d'implementació).

---

# 9. Infraestructura asíncrona — Replantejament `jobs/events/notifications`

> Aquest document **substitueix** els prompts a
> `prompts/jobs-events-notifications/` (els quals quedaven obsolets respecte
> la base ja construïda i el disseny de `/docs/product-design/`).
>
> Objectiu: definir clarament què hi ha, què falta, i quin **prompt** s'ha
> de fer servir per implementar la peça que ens manca, sense duplicar el
> que ja existeix.

---

## 9.1 Per què cal replantejar els prompts originals

Els fitxers `prompt_de_prompt.md` i `jobs_events_notifications.md` van ser
escrits abans de tancar el disseny actual. Repassats avui, **xoquen amb
quatre decisions ja preses**:

### a) `events` (audit log) — ja resolt amb `data.audit_logs`

El prompt demanava una taula `events` "estrictament audit log". Nosaltres
**ja tenim `data.audit_logs`** amb el seu protocol descrit a
`copilot-instructions.md`:

- Trigger SQL `data.log_audit_event()` per canvis a BD.
- Insert directe (fire-and-forget) per accions de codi (Edge Functions,
  Server Actions sense trigger).
- Convenció `action` MAJÚSCULES_AMB_GUIÓ_BAIX (`MEMBER_INVITED`,
  `FILE_DELETED`, `TENANT_PLAN_CHANGED`…).
- RLS pròpia + accés admin via `prisma.$queryRaw` (BYPASSRLS).

A més, doc 06 va afegir taules complementàries amb un propòsit clar:
- `data.integration_events` — log de webhooks/sync per debug d'integracions.
- `data.ai_invocations` — log de crides a `ai-gateway`.
- `data.usage_metrics` — comptabilització de consum (no audit).

**Conclusió**: NO crear cap taula `events` nova. Tot l'audit ja viu.

### b) `jobs` — nom ambigu i col·lisió semàntica

"Job" en el nostre domini té **dos significats incompatibles**:

| Sentit | A què correspon al disseny | Taula |
|---|---|---|
| "Feina del client" (encàrrec, obra, ordre de treball) | Vegeu doc 02 §2.1 i doc 05 Fase D | `data.projects` (+ `tasks`, `project_lines`) |
| "Tasca tècnica asíncrona del sistema" (enviar email, esborrar fitxer, comprimir foto…) | Aquesta capa | NOVA: `data.async_tasks` |

El prompt original barrejava els dos. Cal separar: **mai** una taula
`jobs` genèrica. Els encàrrecs de client són `Project`. Les feines
tècniques de fons són `async_tasks`.

### c) Worker — `set_config('request.jwt.claims', …)` no encaixa

El prompt deia que el worker injectés un JWT fictici amb `tenant_id` per
fer servir RLS. **Això trenca la nostra arquitectura**:

- Les nostres polítiques RLS s'avaluen contra `data.jwt_user_tenants()`,
  que llegeix el claim `app_metadata.user_tenants` (estructura completa
  amb roles + sites). Un JWT amb només `tenant_id` no la satisfà i les
  polítiques denegarien.
- A més, ja seguim el patró d'usar `service_role` als workers (vegeu
  `process-deletion-queue` i `process-email-queue` actuals) **amb
  responsabilitat al codi TypeScript** d'aplicar el `tenant_id` del
  payload a totes les operacions.

**Conclusió**: el worker és `service_role` (bypass_rls). El TypeScript
del worker és el responsable d'aïllar per `tenant_id`. Cap simulació de
JWT.

### d) `notifications` — abast confús (in-app vs comunicacions sortints)

El prompt deia "almacena resultados asíncronos para el usuario" en una
sola taula. Al disseny tenim **dos canals diferents**:

| Canal | Audiència | Taula | Contingut |
|---|---|---|---|
| In-app inbox / toast / badge | TenantMember (usuari intern) | NOVA: `data.notifications` | "S'han comprimit 12 fotos del projecte X", "Recordatori: 3 cites demà" |
| Outbound al Contact (email/SMS/WhatsApp) | Contact (client final) | `data.communications` (ja prevista doc 02) | El missatge real enviat |

Els dos s'han de tractar separadament. El worker pot generar **una
notificació in-app** (resum de què ha fet) i alhora una **comunicació
sortint** (missatge al client) — entitats diferents.

---

## 9.2 Mapa final de la capa asíncrona

```
┌─────────────────────────────────────────────────────────────────────┐
│  Triggers de negoci (codi de l'app)                                 │
│   - RPC d'app crea entitat + audit_logs + pgmq.send (transaccional) │
│   - pg_cron periòdic encua manteniments                             │
└────────────────────────────┬────────────────────────────────────────┘
                             ▼
                     ┌──────────────┐
                     │   PGMQ       │   cues per família de tasca
                     │   queues     │   (email, deletion, reminders,
                     └──────┬───────┘    integrations, ai, ...)
                            ▼
              ┌─────────────────────────────┐
              │  Edge Function workers      │   1 worker per cua
              │  (cron cada 1-5 min)        │
              │                             │
              │  comparteixen _shared/lib:  │
              │   - read batch RPC          │
              │   - dedup check             │
              │   - retry/backoff           │
              │   - DLQ on final failure    │
              │   - audit + usage_metrics   │
              └─────────────┬───────────────┘
                            ▼
        ┌───────────────────┴───────────────────┐
        ▼                                       ▼
┌────────────────────┐                 ┌──────────────────────┐
│ data.async_tasks   │                 │ data.communications  │  ← outbound
│ data.notifications │ ← in-app inbox  │ data.audit_logs      │  ← qui ha fet què
│ data.dlq_messages  │ ← DLQ           │ data.usage_metrics   │  ← cost
│ data.processed_msgs│ ← idempotència  │                      │
└────────────────────┘                 └──────────────────────┘
```

### Catàleg de taules noves d'aquesta capa

#### `data.async_tasks` (**rastreig opcional** d'una tasca de fons)

Només per a tasques on l'usuari vol veure **estat i resultat** (ex: "exporta
totes les meves dades"). La majoria de tasques ràpides (enviar email) no
necessiten registre aquí; viuen exclusivament a la cua.

```
id                  uuid PK
tenant_id           uuid NOT NULL
site_id             uuid NULL
created_by          uuid NULL                 -- auth.uid() o NULL si pg_cron
kind                text NOT NULL             -- 'export_data', 'bulk_import', ...
status              text NOT NULL             -- 'queued'|'running'|'done'|'failed'
progress_pct        smallint                  -- 0..100 opcional
started_at          timestamptz
finished_at         timestamptz
result              jsonb                     -- URL, comptadors, etc.
error_text          text
created_at, updated_at
```

#### `data.notifications` (in-app inbox per TenantMember)

```
id                  uuid PK
tenant_id           uuid NOT NULL
user_id             uuid NOT NULL             -- destinatari (TenantMember)
kind                text NOT NULL             -- 'task_complete', 'reminder_failed', ...
severity            text NOT NULL             -- 'info'|'success'|'warning'|'critical'
title_i18n          jsonb                     -- { ca, es, en }
body_i18n           jsonb
deep_link           text                      -- ruta dins l'app
related_entity_type text NULL                 -- 'project', 'contact', ...
related_entity_id   uuid NULL
read_at             timestamptz NULL
created_at
```

RLS: `user_id = auth.uid() AND tenant_id IN ...`.

#### `data.processed_messages` (dedup per cua)

```
queue_name          text NOT NULL
msg_id              bigint NOT NULL           -- el de PGMQ
idempotency_key     text NOT NULL
processed_at        timestamptz DEFAULT now()
PRIMARY KEY (queue_name, idempotency_key)
INDEX (queue_name, msg_id)
```

#### `data.dlq_messages` (Dead Letter Queue)

```
id                  uuid PK
queue_name          text NOT NULL
original_msg_id     bigint
payload             jsonb NOT NULL
attempt_count       smallint NOT NULL
last_error_text     text
last_error_at       timestamptz
created_at
```

> No hi ha taula `events` ni taula `jobs` genèrica.

---

## 9.3 Convencions del payload PGMQ

Estructura estàndard per a totes les cues:

```json
{
  "task": "send_reminder_email",
  "tenant_id": "uuid",
  "site_id": "uuid|null",
  "actor_user_id": "uuid|null",
  "entity_type": "calendar_event",
  "entity_id": "uuid",
  "idempotency_key": "deterministic-string",
  "payload": { ...específic de la tasca... },
  "enqueued_at": "ISO-8601"
}
```

### Catàleg inicial de cues

| Cua | Worker | Tasques `task` previstes |
|---|---|---|
| `email_queue` (ja) | `process-email-queue` | `send_transactional`, `send_template`, `send_reminder`, `send_invitation` |
| `trash_deletion_queue` (ja) | `process-deletion-queue` | `delete_storage_object` |
| `reminders_queue` (ja) | `process-reminders-queue` | `materialize_reminder`, `send_reminder` (després via email_queue) |
| `project_events` (ja) | `process-project-events` | `PROJECT_CREATED` (notificació membres + calendar_event) |
| `integration_queue` (nova) | `process-integration-queue` | `whatsapp_send`, `sms_send`, `calendar_pull_sync`, `ocr_invoice` |
| `ai_queue` (nova) | `process-ai-queue` | `voice_transcribe`, `text_summarize_contact`, `tag_classify_contact` |
| `maintenance_queue` (nova) | `process-maintenance-queue` | `recompute_user_permissions_cache`, `expire_share_links`, `purge_old_audit` |

**Una cua per família** (no una sola cua compartida): permet polling
independents, retries diferents per família i mètriques separades.

---

## 9.4 Patró transaccional al codi de l'app

Quan una acció d'usuari ha de disparar feina asíncrona, **tot va a una RPC
PL/pgSQL atòmica**:

```sql
CREATE OR REPLACE FUNCTION api.create_calendar_event_with_reminders(
  p_event_data jsonb,
  p_reminders  jsonb[]
) RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER         -- RLS s'aplica al rol de l'usuari
SET search_path = data, public
AS $$
DECLARE
  v_event_id uuid;
  r jsonb;
BEGIN
  -- 1. Negoci
  INSERT INTO data.calendar_events (...) VALUES (...) RETURNING id INTO v_event_id;

  -- 2. Audit (via funció existent)
  PERFORM data.log_audit_event(
    'CALENDAR_EVENT_CREATED', 'calendar_event', v_event_id,
    jsonb_build_object('starts_at', p_event_data->>'starts_at')
  );

  -- 3. Encolar feines
  FOREACH r IN ARRAY p_reminders LOOP
    PERFORM pgmq.send('reminders_queue', jsonb_build_object(
      'task', 'materialize_reminder',
      'tenant_id', data.active_tenant_id(),
      'entity_type', 'calendar_event',
      'entity_id', v_event_id,
      'idempotency_key', 'rem-' || v_event_id || '-' || (r->>'offset_minutes'),
      'payload', r,
      'enqueued_at', now()
    ));
  END LOOP;

  RETURN v_event_id;
END;
$$;
```

Garantia: si la insertion falla, la cua no rep res. Si la cua falla
(rar), tot revertit.

**Prohibit**: encolar des de triggers SQL "perquè és més còmode". L'únic
trigger acceptable que toqui PGMQ és el que ja existeix per `trash_deletion_queue`
(decisió pragmàtica perquè el cicle de vida del document depèn de
mecanismes de soft-delete).

---

## 9.5 Patró del worker (Edge Function)

Reusem el patró de [process-deletion-queue](supabase/functions/process-deletion-queue/) que ja funciona:

1. **Cridada per pg_cron** cada 1-5 min (segons criticitat de la cua).
2. **No bucles infinits**. Una invocació = un batch (5-25 missatges
   segons cua).
3. **Llegir via RPC `api.read_<queue>_batch(p_count int, p_vt int)`**
   perquè `pgmq.*` no està exposada a PostgREST.
4. **Dedup**: abans de processar, `SELECT` a `data.processed_messages`
   per `(queue_name, idempotency_key)`.
5. **Processar via funció pura `processMessage(message)`** importada de
   `_shared/queue-runtime.ts`. Cap binding de Deno dins.
6. **Èxit**: insert a `processed_messages` + `api.archive_<queue>_message(msg_id)`.
7. **Fallada**:
   - Si attempt < 3 → tornar a posar a la cua amb VT exponencial
     (60s × 2^attempt).
   - Si attempt = 3 → moure a `data.dlq_messages` + audit
     `TASK_DLQ_MOVED` + notification in-app als owners (severity
     `critical`).
8. **Audit**: cada cicle escriu a `data.audit_logs` un batch summary
   (`ASYNC_BATCH_PROCESSED` amb counts).

### Estructura `_shared/queue-runtime.ts` (lib comuna)

```ts
// 100% portable a Node.js worker extern. Cap import de Deno.
export type QueueMessage = {
  msg_id: number;
  read_ct: number;
  vt: string;
  message: TaskPayload;
};

export type TaskHandler = (
  msg: TaskPayload,
  ctx: WorkerContext
) => Promise<TaskResult>;

export class QueueRunner {
  constructor(private cfg: {
    queueName: string;
    handlers: Record<string, TaskHandler>;
    maxAttempts: number;
    batchSize: number;
    visibilityTimeoutSec: number;
    db: SupabaseClient;
  }) {}

  async runBatch(): Promise<BatchSummary> { /* dedup, dispatch, retry, dlq */ }
}
```

### Aïllament multi-tenant del worker

- Worker usa **`service_role`** (`createAdminClient()` de `_shared/supabase.ts`).
- **Cada operació de mutació porta `tenant_id` explícit del payload** com
  a filtre WHERE.
- **Cap operació "for all tenants"** en una sola query. Si una tasca de
  manteniment ho necessita, itera tenant per tenant amb `LIMIT` i log
  per cada un.
- Si la lib detecta que un missatge té `tenant_id` que no existeix o ha
  estat suspès → DLQ amb `TENANT_INVALID`.

---

## 9.6 Recordatoris de calendari — flux exemple end-to-end

Cas representatiu de tot el sistema (Fase C del roadmap, doc 05):

```
Usuari crea cita 'practice' a les 10:00 demà amb recordatoris [24h, 2h]
   │
   ▼
1. Frontend → api.create_calendar_event_with_reminders(...)
   │ insereix calendar_event
   │ insereix audit_logs (CALENDAR_EVENT_CREATED)
   │ pgmq.send('reminders_queue', {task: 'materialize_reminder', offset:24h})
   │ pgmq.send('reminders_queue', {task: 'materialize_reminder', offset:2h})
   │ COMMIT
   ▼
2. pg_cron(reminders) → process-reminders-queue Edge Function
   │ llegeix batch
   │ per cada msg:
   │   calcula send_at = event.starts_at - offset
   │   si send_at > now() + 5min → re-enqueue amb VT = send_at - now()
   │   si send_at <= now() + 5min:
   │     insereix data.communications (status='pending', channel=preferred)
   │     pgmq.send('email_queue' o 'integration_queue', {task: 'send_reminder', communication_id})
   │   marca processed_messages
   ▼
3. pg_cron(email) → process-email-queue
   │ resol plantilla i20n + render
   │ envia via Resend (o WhatsApp BSP)
   │ actualitza data.communications.status='sent'
   │ usage_metrics(kind='email_sent', qty=1)
   │ audit_logs (REMINDER_SENT)
   ▼
4. Si falla 3 cops → DLQ + notification in-app a l'owner del Contact
```

Cap pas requereix una taula `events` separada. Cada acció rellevant ja queda
al seu lloc natural (`audit_logs`, `communications`, `usage_metrics`).

---

## 9.7 Què NO fem (anti-patrons reafirmats)

- ❌ Taula `events` paral·lela a `audit_logs`.
- ❌ Taula `jobs` genèrica (col·lisió amb Project).
- ❌ Triggers que `pgmq.send` lògica de negoci (només manteniments interns).
- ❌ Workers que injecten JWT fictici per obrir RLS.
- ❌ Una sola cua compartida per a tot.
- ❌ Workflow engine, rule engine, BPM. Vegeu doc 07 §7.12.
- ❌ Polling continu (loops infinits) dins una Edge Function.
- ❌ Re-implementar idempotència a cada handler — viu a `_shared/queue-runtime.ts`.

---

## 9.8 Estat actual i salt necessari

| Peça | Estat | Acció |
|---|---|---|
| PGMQ extension | ✅ instal·lada | — |
| `email_queue` + worker | ✅ funcionant | Refactor opcional per usar `_shared/queue-runtime.ts` |
| `trash_deletion_queue` + worker | ✅ funcionant | Idem |
| `data.audit_logs` + `log_audit_event()` | ✅ implementat | — |
| `_shared/queue-runtime.ts` (lib comuna) | ❌ no existeix | **A implementar amb el prompt §9.10** |
| `data.async_tasks` | ❌ no existeix | A implementar |
| `data.notifications` (in-app inbox) | ❌ no existeix | A implementar |
| `data.processed_messages` | ❌ no existeix (cada Edge Function ho gestiona ad-hoc) | A unificar |
| `data.dlq_messages` | ❌ no existeix | A implementar |
| `reminders_queue` + worker | ❌ Fase C | Després de `_shared/queue-runtime.ts` |
| `integration_queue` + worker | ❌ Fase D-E | Després |
| `ai_queue` + worker | ❌ Fase E | Després |

---

## 9.9 Ordre d'implementació recomanat

1. **Migració `0xxx_async_infra.sql`**:
   - Crea `data.processed_messages`, `data.dlq_messages`, `data.async_tasks`,
     `data.notifications`.
   - RLS estricta (només propi tenant; notifications només propi user).
   - Vistes `api.notifications`, `api.async_tasks` per al frontend.
   - Funcions `api.read_<queue>_batch` i `api.archive_<queue>_message` genèriques
     parametritzables per nom de cua.

2. **Lib `supabase/functions/_shared/queue-runtime.ts`**:
   - Classe `QueueRunner` amb runBatch.
   - Helpers: dedupCheck, recordProcessed, retryWithBackoff, moveToDlq,
     emitNotification, emitUsageMetric.
   - Tipus exportats.

3. **Refactor de `process-email-queue` i `process-deletion-queue`**:
   - Migrar a `QueueRunner` per validar el patró.
   - Cap canvi de comportament observable.

4. **Nova migració `0xxx_calendar.sql`** (Fase A doc 05) — inclou
   `api.create_calendar_event_with_reminders` que ja encua a
   `reminders_queue`.

5. **Nova Edge Function `process-reminders-queue`** + cron entry.

6. **Frontend**: hook `useNotifications()` + badge al header sticky
   (vegeu doc 07 §7.4).

A partir d'aquí, afegir noves cues és **copiar el patró**, no inventar
res nou.

---

## 9.10 PROMPT per a la implementació (a passar a la IA generadora)

```text
ROL
Ets un Principal Staff Engineer especialitzat en Supabase (PostgreSQL +
RLS), arquitectures multi-tenant SaaS i sistemes asíncrons amb PGMQ.

CONTEXT (NO inventis fora d'aquí)
Treballem a un repo Supabase existent amb:
- Schemes data.* (privat) i api.* (PostgREST, security_invoker).
- Multi-tenant + multi-site, RLS via data.jwt_user_tenants() amb claim
  app_metadata.user_tenants i fallback a data.user_permissions_cache.
- data.audit_logs + funció data.log_audit_event() ja en marxa.
- PGMQ instal·lat. Existeixen ja les cues 'email_queue' i
  'trash_deletion_queue' amb workers Edge Functions process-email-queue
  i process-deletion-queue. Les funcions usen el patró
  api.read_<queue>_batch + api.archive_<queue>_message (RPC) perquè
  el schema pgmq no està exposat a PostgREST.
- supabase/functions/_shared/supabase.ts proporciona createAdminClient()
  (service_role, BYPASSRLS) i createUserClient() tipats amb
  Database['api'].

OBJECTIU
Implementar la infraestructura asíncrona base perquè totes les properes
funcionalitats (calendari, recordatoris, integracions, IA) puguin
encua-r tasques amb un patró únic, idempotent, amb retries exponencials,
DLQ, notificacions in-app a l'usuari i comptabilització de consum,
sense duplicar mai audit_logs ni introduir cap event-driven orchestration.

RESTRICCIONS ESTRICTES
- PROHIBIT crear una taula 'events' paral·lela a data.audit_logs.
- PROHIBIT crear una taula genèrica 'jobs' (en el nostre domini, els
  encàrrecs del client són data.projects).
- PROHIBIT injectar JWT ficticis amb set_config al worker. El worker
  usa service_role i el codi TypeScript filtra per tenant_id explícit
  llegit del payload.
- PROHIBIT triggers SQL que facin pgmq.send com a mecanisme d'event-
  driven. L'única excepció acceptada és el manteniment ja existent del
  trash_deletion_queue.
- PROHIBIT bucles infinits dins l'Edge Function. Una invocació = un
  batch. La periodicitat la marca pg_cron.
- PROHIBIT inventar workflow engines, rule engines o abstraccions per
  "configuració de regles".
- PROHIBIT re-implementar dedup/retry/DLQ a cada handler. Tot al
  _shared/queue-runtime.ts.

ENTREGABLES

1. Migració SQL nova `<timestamp>_async_infra.sql`:
   1.1 Taules a `data` amb RLS:
       - data.async_tasks       (rastreig opcional de tasques observables)
       - data.notifications     (inbox in-app per TenantMember)
       - data.processed_messages (PRIMARY KEY (queue_name, idempotency_key))
       - data.dlq_messages
   1.2 Vistes/RPCs a `api` (security_invoker o security_definer segons cal):
       - api.notifications              (vista security_invoker)
       - api.async_tasks                (vista security_invoker)
       - api.mark_notification_read(uuid)
       - api.read_queue_batch(queue text, count int, vt int)
         retorna SETOF (msg_id bigint, read_ct int, message jsonb)
       - api.archive_queue_message(queue text, msg_id bigint)
   1.3 RLS:
       - data.notifications: user_id = auth.uid() AND tenant_id pertany a l'usuari
       - data.async_tasks: tenant pertany a l'usuari (lectura per tots,
         escriptura només service_role)
       - data.processed_messages, data.dlq_messages: NO accessibles via
         PostgREST (no exposar al schema api)
   1.4 Auditoria:
       - Insert a data.async_tasks dispara trigger d'audit
         (ASYNC_TASK_CREATED, ASYNC_TASK_STATUS_CHANGED).
       - Moure missatge a DLQ → audit TASK_DLQ_MOVED + insert
         data.notifications a tots els owners del tenant amb
         severity='critical'.

2. Lib comuna `supabase/functions/_shared/queue-runtime.ts`:
   - 100% TypeScript estàndard, ZERO import de Deno (perquè sigui
     portable a Node.js worker extern).
   - Tipus: TaskPayload, TaskResult, QueueMessage, TaskHandler,
     QueueRunnerConfig, BatchSummary.
   - Classe QueueRunner amb mètode runBatch(): Promise<BatchSummary>.
   - Mètodes interns:
       dedupCheck(idempotency_key) → bool
       recordProcessed(...)
       retryWithBackoff(msg, attempt) → calcula VT 60s * 2^attempt
       moveToDlq(msg, attempt, error)
       emitNotification(...)
       emitUsageMetric(...)
       logBatchAudit(summary)
   - El handler s'executa rebent (payload, ctx) on ctx exposa
     supabase admin client + helpers; mai obre el payload en una sola
     query "for all tenants".
   - Si el payload no té tenant_id, o el tenant està suspès → DLQ amb
     'TENANT_INVALID', no llançar excepció.
   - Configuració per cua: maxAttempts (default 3), batchSize (default 10),
     visibilityTimeoutSec (default 60).

3. Refactor de les Edge Functions existents:
   - process-email-queue i process-deletion-queue han d'usar QueueRunner
     sense canviar comportament observable. Mantenir el contracte de
     payload actual; només canviar l'esquelet.

4. Migració SQL `<timestamp>_create_reminders_queue.sql`:
   - SELECT pgmq.create('reminders_queue');
   - api.read_queue_batch i api.archive_queue_message ja són genèriques.

5. Nova Edge Function `supabase/functions/process-reminders-queue/`:
   - Importa QueueRunner i registra handlers:
       'materialize_reminder' → calcula send_at, decideix si re-enqueue
         o crea data.communications + envia a 'email_queue'/'integration_queue'.
   - Cap lògica de retry/dedup pròpia.

6. RPC d'exemple `api.create_calendar_event_with_reminders(...)`:
   - PL/pgSQL, SECURITY INVOKER.
   - Insereix calendar_event + audit + pgmq.send a reminders_queue
     dins la mateixa transacció.
   - NO l'has d'integrar amb la taula calendar_events real (encara no
     existeix). Generar com a STUB documentat amb TODO assenyalant
     que s'integrarà a la migració de calendar (Fase A doc 05).

7. Documentació al final:
   - Diagrama ASCII del flux complet (RPC → PGMQ → Worker → outbound).
   - Llista de cues planejades amb el seu task vocabulary.
   - Convenció del payload PGMQ.

PROCEDIMENT REQUERIT
1. Abans de tocar codi, presenta un esborrany de:
   a) Esquema final de cada taula nova (columnes + tipus).
   b) Signatura de cada RPC nova.
   c) API pública del QueueRunner (mètodes + tipus).
   d) Llista de fitxers a crear/modificar amb caminos exactes.
2. Espera el meu OK per a cada bloc.
3. Quan implementis, regenera els tipus: comanda exacta a
   .github/copilot-instructions.md (regla "Tipus de Base de Dades").
4. Tot text d'usuari final usa t('key', 'Catalan fallback').
5. Cada lifecycle change → entry a data.audit_logs.
6. NO afegis tests E2E en aquesta entrega; sí unit tests del QueueRunner
   amb mocks (dedup, retry, DLQ, notification).

CRITERIS D'ACCEPTACIÓ
- supabase db reset --local aplica la migració sense error.
- supabase gen types typescript --local genera les noves entitats.
- Refactor de process-email-queue i process-deletion-queue: pass
  manual smoke (enviar 1 email, esborrar 1 fitxer) → comportament idèntic.
- En provocar fallades intencionals (mock), el missatge acaba a
  data.dlq_messages després de 3 intents, els owners reben notification
  in-app severity='critical', i hi ha entrada audit TASK_DLQ_MOVED.
- supabase/functions/_shared/queue-runtime.ts no té cap import "deno"
  ni "https://deno.land". Compila com a TypeScript estàndard.
```

---

## 9.11 Decisions a tancar

1. **`async_tasks` és necessari V1?** Recomanació: només si tenim ja
   alguna tasca observable per l'usuari (export, import). Si no, deferir
   a quan calgui.
2. **`reminders_queue` o reusem `email_queue` directament?**
   Recomanació: cua pròpia, perquè el "materialitzador" pot decidir
   canal (email/SMS/WhatsApp) i moment. Separar respiratòria.
3. **`pg_cron` periodicitat per cua**: email 1 min, deletion 5 min,
   reminders 1 min, integration 2 min, ai 1 min, maintenance 1 h.
   Confirmar a la implementació.
4. **Soft retention de `processed_messages`**: cap fila viva més de 30
   dies. `pg_cron` diari de purga (job a `maintenance_queue`).
5. **`data.notifications` retention**: read=true esborrar passats 60
   dies; non-read mantenir.
6. **Quotes per cua en pla** (vegeu doc 06 §6.7): `usage_metrics` ja
   cobreix volumetria; afegir `quota_check` al QueueRunner abans
   d'executar tasques de cost (whatsapp, sms, ai).
