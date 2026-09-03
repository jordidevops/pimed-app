# Roadmap d'Implementació per Agent IA

## Objectiu

Implementar el motor d'automatització V1 en fases petites, verificables i compatibles amb l'arquitectura existent del repo.

Aquest roadmap substitueix una implementació "gran bang". L'agent ha de completar i validar cada fase abans de passar a la següent.

## Fase 0 - Exploració obligatòria

Abans d'editar codi, l'agent ha de revisar:

- `supabase/functions/_shared/queue-runtime.ts`
- `supabase/functions/_shared/supabase.ts`
- `supabase/functions/_shared/context-builder.ts`
- `supabase/functions/_shared/liquid-renderer.ts`
- Edge Functions que ja usen QueueRunner: `process-email-queue`, `process-reminders-queue`, `process-deletion-queue`
- Migracions de `data.audit_logs`, `data.notifications`, `data.calendar_events`, `data.tasks`, `data.document_templates`, `data.signing_submissions`
- Patrons RLS i `api.*` views existents

Criteri d'acceptació:

- L'agent pot explicar quin patró local seguirà per QueueRunner, RLS, audit logs i tipus generats.

## Fase 1 - Contractes i migració base

Implementar:

- Enums o checks textuals de status.
- `data.automation_workflows`.
- `data.automation_runs`.
- `data.automation_step_runs`.
- `data.automation_pending_approvals`.
- `data.automation_scheduled_triggers`.
- RLS i vistes `api.*` mínimes.
- Audit logs de lifecycle.
- Regeneració de `database.types.ts`.

Criteris d'acceptació:

- Tipus generats sense errors.
- RLS impedeix veure runs d'altres tenants.
- Unique `(workflow_id, event_id)` existeix.
- Unique `(workflow_run_id, step_id)` existeix.
- Indexos principals creats.

## Fase 2 - Validació JSONB i helpers compartits

Implementar a `_shared/automation/` o ubicació equivalent:

- `schemas.ts` amb Zod schemas de workflow i step configs.
- `events.ts` amb event envelope i mapping `audit action -> event_type`.
- `state-machine.ts` amb transicions permeses.
- `recipients.ts` per resolució d'usuaris/rols.
- `errors.ts` amb error format estructurat.

Criteris d'acceptació:

- Crear workflow amb step id duplicat falla.
- Crear workflow amb `routing.on_success` cap a step inexistent falla.
- Crear workflow amb cicle falla.
- Crear workflow amb config invàlida per step type falla.

## Fase 3 - Workflow Trigger Engine

Implementar Edge Function o worker:

- `process-workflow-triggers`.
- Consumeix `workflow_trigger_queue`.
- Busca workflows actius per tenant/event.
- Aplica filtres i prevenció de loops.
- Crea `automation_run` idempotent.
- Guarda `workflow_snapshot`.
- Crea `automation_step_runs`.
- Encua el primer step.

Criteris d'acceptació:

- Mateix event dues vegades crea una sola run.
- Event `source_kind='automation'` no dispara workflows per defecte.
- Workflow site-specific només dispara per aquell site.
- Run guarda snapshot encara que després el workflow es modifiqui.

## Fase 4 - Step Executor i State Machine

Implementar:

- `process-automation-queue`.
- Claim atòmic `PENDING -> RUNNING`.
- Dispatcher de handlers.
- Persistència d'output/error.
- `transition_workflow_run` centralitzat.
- Manual retry/cancel primitives si cal per UI posterior.

Criteris d'acceptació:

- Dos workers no executen el mateix step.
- Un handler completat encua només el step següent.
- Un handler fallit marca run `FAILED` si no hi ha ruta alternativa.
- Un step `WAITING_HUMAN` pausa el workflow sense retry automàtic.

## Fase 5 - Handlers V1 mínims

Ordre recomanat:

1. `SEND_NOTIFICATION` - més simple, patró de referència.
2. `CREATE_TASK`.
3. `CREATE_CALENDAR_EVENT`.
4. `SEND_EMAIL`.
5. `CONDITION`.
6. `HUMAN_APPROVAL`.
7. `WAIT`.
8. `GENERATE_DOCUMENT`.
9. `SEND_FOR_SIGNING`.
10. `UPDATE_FIELD` amb whitelist estricta.

Criteris d'acceptació:

- Cada handler té schema de config.
- Cada handler té test d'èxit i error.
- Cap handler encua directament el següent step.
- Cap handler fa query sense `tenant_id`.

## Fase 6 - BAM i approvals

Implementar:

- Edge Function o RPC per `approve/reject/reassign`.
- Canvi d'estat de approval idempotent.
- Reprendre workflow després d'aprovació.
- Audit logs d'aprovació/rebuig.

Criteris d'acceptació:

- Una approval no es pot aprovar dues vegades.
- Usuari sense permís no pot aprovar.
- Rebuig porta la run a failure o ruta `on_failure`.
- Comentari queda guardat.

## Fase 7 - Date triggers escalables

Implementar:

- `automation_scheduled_triggers`.
- Worker/cron paginat.
- Idempotency key per trigger.
- Integració amb `WAIT` i `date_field.reached`.

Criteris d'acceptació:

- Cron processa per batches.
- Reexecutar cron no duplica events.
- Dates futures no es processen abans d'hora.

## Fase 8 - UI Automation Center

Implementar a tenant-portal seguint i18n obligatori del repo:

- Dashboard resum.
- Llista d'aprovacions pendents.
- Detall de workflow run amb timeline.
- Catàleg de workflows.
- Instal·lació de blueprints.
- Editor simple de steps.

Criteris d'acceptació:

- Tot text visible usa `t('key', 'Fallback en Català')`.
- UI filtra per tenant/site via `api.*` views.
- Retry/cancel/approve tenen feedback visual.

## Fase 9 - Blueprints V1

Crear blueprints inicials:

- Onboarding d'empleats.
- Renovació de contractes.
- Alta de client/lead.
- Ordre de treball EAM.
- Signatura completada.
- Gestió de vacances.

Criteris d'acceptació:

- Cada blueprint valida contra schema.
- Instal·lar blueprint clona definició al tenant.
- Modificar blueprint de plataforma no modifica còpies instal·lades.

## Fase 10 - Hardening

Tests obligatoris:

- Idempotència de trigger.
- Race condition de step claim.
- Loop prevention.
- RLS tenant isolation.
- Callback correlation de signatura.
- Retry manual.
- Cancel·lació.
- Workflow snapshot immutable.

## No implementar a V1

- Canvas visual de nodes.
- Parallel gateways.
- Loops interns.
- Saga/compensacions automàtiques.
- Marketplace públic de blueprints.
- AI providers i agents.
- OAuth2 per iPaaS.

## Notes de verificació del repo

Si es toquen migracions `data.*`, `api.*` o RPC exposades:

```powershell
supabase gen types typescript --local 2>$null | Set-Content "apps/tenant-portal/src/types/database.types.ts" -Encoding utf8
Copy-Item "apps/tenant-portal/src/types/database.types.ts" "supabase/functions/_shared/database.types.ts"
```

No saltar aquest pas.
