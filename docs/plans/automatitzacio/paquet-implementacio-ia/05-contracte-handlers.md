# Contracte d'Action Handlers

## 1. Objectiu

Aquest document defineix com han d'estar implementats tots els handlers del motor d'automatització. El valor principal és que tots segueixin el mateix patró: claim atòmic, execució, resultat estructurat i transició central.

## 2. Interfície conceptual d'un handler

```typescript
type AutomationHandler = (input: {
  db: SupabaseAdminClient
  run: AutomationRun
  stepRun: AutomationStepRun
  step: StepDefinition
  context: Record<string, unknown>
  workerId: string
}) => Promise<{
  status: 'COMPLETED' | 'WAITING_HUMAN' | 'WAITING_EXTERNAL' | 'WAITING_TIMER' | 'FAILED'
  output?: Record<string, unknown>
  error?: AutomationStepError
  correlation_key?: string
}>
```

## 3. Patró obligatori del worker

Pseudoflux:

```text
process message { step_run_id }
  load step_run + run
  claim step atomically (PENDING -> RUNNING)
  if no row returned: ack message and exit
  validate tenant/site
  validate workflow_snapshot and step schema
  call handler by step.type
  persist handler result
  call transition_workflow_run(run.id)
  return success to QueueRunner
```

## 4. Què pot fer un handler

Un handler pot:

- Executar l'acció del step.
- Escriure `output` estructurat.
- Escriure `error` estructurat.
- Posar `correlation_key` per callbacks futurs.
- Crear registres derivats sempre amb `tenant_id` explícit.
- Encolar a cues existents (`email_send_queue`, etc.) quan sigui el mecanisme del mòdul.

Un handler no pot:

- Decidir quin step ve després.
- Llegir `automation_workflows.steps` directament.
- Encua el següent step manualment.
- Fer queries sense `tenant_id`.
- Guardar secrets dins `output` o `context`.
- Fer compensacions automàtiques de steps anteriors.

## 5. Handler exemple: `SEND_NOTIFICATION`

Aquest és el handler de referència perquè és el més simple i serveix de plantilla mental per la resta.

Pseudocodi orientatiu:

```typescript
async function handleSendNotification(input) {
  const { db, run, step, context } = input

  const config = SendNotificationConfigSchema.parse(step.config)

  const recipientUserIds = await resolveRecipients({
    db,
    tenantId: run.tenant_id,
    siteId: run.site_id,
    recipient: config.recipient,
    context,
  })

  if (recipientUserIds.length === 0) {
    return {
      status: 'FAILED',
      error: {
        code: 'NO_RECIPIENTS',
        message: 'No notification recipients resolved.',
        retryable: false,
        handler: 'SEND_NOTIFICATION',
      },
    }
  }

  const title = renderLiquid(config.title_template, context)
  const body = renderLiquid(config.body_template, context)

  await db.from('notifications').insert(
    recipientUserIds.map((userId) => ({
      tenant_id: run.tenant_id,
      site_id: run.site_id,
      user_id: userId,
      kind: config.kind,
      severity: config.severity,
      title_i18n: { ca: title },
      body_i18n: { ca: body },
      related_entity_type: 'automation_run',
      related_entity_id: run.id,
    }))
  )

  return {
    status: 'COMPLETED',
    output: {
      notification_count: recipientUserIds.length,
      recipient_user_ids: recipientUserIds,
    },
  }
}
```

Aquest codi és pseudocodi. La implementació real ha d'adaptar-se als helpers existents del repo, als tipus generats i al patró de `QueueRunner`.

## 6. Contracte per handler V1

### SEND_NOTIFICATION

- Resol destinataris.
- Inserta a `data.notifications`.
- Retorna `notification_count`.
- No envia email directament.

### SEND_EMAIL

- Renderitza destinatari i template config.
- Encola a `email_send_queue` seguint el patró existent del repo.
- Retorna `email_queue_message_id` o identificador equivalent.
- L'èxit del step significa "email encolat", no necessàriament entregat.

### CREATE_TASK

- Crea `data.tasks` amb `tenant_id` i `site_id` explícits.
- Assignee resolt per usuari/rol/path.
- Retorna `task_id`.

### CREATE_CALENDAR_EVENT

- Crea `data.calendar_events`.
- Crea reminders si config ho indica.
- Retorna `calendar_event_id`.

### GENERATE_DOCUMENT

- Reutilitza `sign-document-router` o helper equivalent.
- Si la generació és síncrona, retorna `document_id` i completa.
- Si és async, guarda `correlation_key` i retorna `WAITING_EXTERNAL`.
- No crea events de calendari directament. Això ho fa un step separat.

### SEND_FOR_SIGNING

- Reutilitza `sign-document-router` en mode sign.
- Guarda `correlation_key` amb `signing_submission_id`.
- Retorna `WAITING_EXTERNAL`.
- El callback `document.signed` reprèn el step.

### HUMAN_APPROVAL

- Crea `automation_pending_approvals`.
- Envia notificació al responsable.
- Retorna `WAITING_HUMAN`.
- No queda a retry automàtic.

### CONDITION

- Avalua expressió limitada sobre `context`.
- No executa codi lliure, SQL lliure ni Liquid arbitrari amb side effects.
- Escriu output `{ result: true/false, next_step_id }`.
- La state machine usa aquest output per decidir ruta.

### UPDATE_FIELD

- Només permet entitats i camps whitelisted.
- Ha de passar per RPCs controlades quan hi hagi lògica de negoci.
- Sempre filtra per `tenant_id`.
- Escriu audit log amb `source_kind='automation'`.

### WAIT

- Crea o actualitza `automation_scheduled_triggers`.
- Retorna `WAITING_TIMER`.
- No manté cap Edge Function en execució.

## 7. Resolució de destinataris

Modes recomanats:

| Mode | Exemple | Notes |
|------|---------|-------|
| `actor` | usuari que va disparar event | `actor_user_id` |
| `explicit_user` | UUID concret | Validar tenant membership |
| `role` | `manager` | Pot ser global o site-specific |
| `field_path` | `employee.manager_user_id` | Llegir del context |

Cap handler ha d'enviar notificacions o emails a usuaris que no pertanyen al tenant.

## 8. Renderització de templates

- Usar `liquid-renderer.ts` existent.
- No permetre accés a secrets des del context.
- Si una variable no existeix, el handler ha de fallar amb error no retryable o usar fallback explícit segons config.

## 9. Errors retryable vs no retryable

Retryable:

- Timeout HTTP.
- Error temporal de proveïdor extern.
- Deadlock/transient DB error.

No retryable:

- Config invàlida.
- Template inexistent.
- Destinatari no resolt.
- Permís insuficient.
- Step schema invàlid.

## 10. Checklist per cada handler

Abans de considerar un handler acabat:

- Valida `step.config` amb schema propi.
- Filtra totes les queries per `tenant_id`.
- No encua el següent step.
- Retorna output/error estructurat.
- No guarda secrets al context/output.
- Té test d'èxit.
- Té test d'error retryable.
- Té test d'error no retryable.
- Té test de tenant isolation.
