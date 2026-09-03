# Revisió Tècnica i Riscos d'Implementació

## Veredicte sobre `arquitectura-automatitzacio-v2.md`

El pla és encertat en la direcció principal:

- Workflows com a dades, no regles soltes.
- PGMQ i QueueRunner com a infraestructura base.
- `automation_runs` i `automation_step_runs` com a observabilitat persistent.
- `HUMAN_APPROVAL` com a pas natiu.
- Blueprints com a via d'adopció.
- IA preparada però no obligatòria a V1.

La seva feblesa és que encara parla com a document d'arquitectura, no com a contracte d'implementació. Una IA implementadora podria prendre decisions diferents en concurrència, JSONB, estat, seguretat i reintents.

## Acord amb `revisio_pla_v2.md`

Estic d'acord amb els punts principals de la revisió:

| Punt | Veredicte | Acció |
|------|-----------|-------|
| Race conditions en workers | Correcte | Afegir claim atòmic de step amb `WHERE status = 'PENDING'` |
| Bucles indirectes via audit logs | Correcte | Afegir `causation_run_id`, `depth`, event dedup i filtres de sistema |
| Dates amb pg_cron massiu | Correcte | Usar paginació i, preferiblement, una taula de triggers programats |
| JSONB massa lliure | Correcte | Definir schema versionat i validar amb Zod abans de guardar i executar |
| State machine centralitzada | Correcte | Els handlers no poden encuar directament el següent step |
| Context i RLS en background | Correcte | Guardar actor original i executar sempre amb tenant explícit |

## Riscos addicionals detectats

### R1 - Duplicació de workflow runs pel mateix event

Si un event entra dues vegades a PGMQ o un worker reintenta `process-workflow-triggers`, es podria crear dues vegades el mateix workflow run.

**Mesura obligatòria:** cada event ha de tenir `event_id` estable. Per events basats en `audit_logs`, usar `audit_logs.id`. Per events sintètics, generar un idempotency key determinista.

**Invariant:** no es pot crear més d'un `automation_run` per `(workflow_id, event_id)`.

### R2 - Canvis de workflow mentre hi ha runs en curs

Si un usuari edita `automation_workflows.steps` mentre una execució està a mitges, el worker podria continuar amb una definició diferent de la que va començar.

**Mesura obligatòria:** cada `automation_run` ha de guardar un snapshot immutable de la definició usada: `workflow_version` i `workflow_snapshot`.

Els workers han de llegir el graf des de `automation_runs.workflow_snapshot`, no des de `automation_workflows.steps`.

### R3 - Steps llargs mal modelats

`SEND_FOR_SIGNING`, generació PDF async o esperes temporals no acaben en la mateixa invocació del worker.

**Mesura obligatòria:** aquests steps han de passar a `WAITING_EXTERNAL` o `WAITING_TIMER` amb `correlation_key`. Quan arriba el callback extern o event futur, s'ha de reprendre el mateix `step_run`, no crear un workflow nou accidentalment.

### R4 - Events creats pel propi motor d'automatització

Un `UPDATE_FIELD` fet pel worker generarà `audit_logs`. Això és correcte, però pot alimentar nous workflows i provocar cadenes no desitjades.

**Mesures obligatòries:**

- L'envelope d'event ha d'incloure `source_kind`: `user`, `system`, `automation`, `external_api`.
- L'envelope ha d'incloure `causation_run_id` quan l'event ve d'un workflow.
- Cada workflow ha de poder declarar `allow_automation_source: false` per defecte.
- Profunditat màxima recomanada V1: `max_depth = 3`.

### R5 - Permisos i actor original

Els workers usaran client admin/service role perquè s'executen en background. Això pot saltar RLS.

**Mesura obligatòria:** totes les accions han de filtrar explícitament per `tenant_id` i `site_id`. El `actor_user_id` original s'ha de guardar per auditoria, però no s'ha d'assumir que simular JWT és trivial.

La política V1 recomanada és: worker amb service role, tenant/site explícit, audit log amb `actor_user_id` original i `source_kind='automation'`.

### R6 - JSONB no validat a BD

Postgres no validarà la semàntica completa del JSONB.

**Mesures obligatòries:**

- Validació Zod en qualsevol Edge Function que crea o edita workflows.
- Validació Zod abans d'executar un workflow.
- `schema_version` obligatori a `automation_workflows`.
- Check constraints mínimes a BD: `steps` és array, `trigger_event` no és null, `tenant_id`/`is_blueprint` coherents.

### R7 - Observabilitat insuficient si només es guarda error string

Un error de handler necessita diagnòstic tècnic i missatge humà.

**Mesura obligatòria:** `automation_step_runs.error` ha de ser JSONB amb `code`, `message`, `details`, `retryable`, `handler`, `occurred_at`.

### R8 - Accions manuals perilloses

Permetre `skip step` o `mark completed` pot corrompre processos.

**Mesura obligatòria:** aquestes accions han d'estar restringides a `owner/manager` o permís específic, sempre amb comentari obligatori i audit log.

## Millores recomanades al pla V2

1. Afegir una secció "Invariants d'implementació" al pla principal.
2. Afegir explícitament `event_id`, `correlation_id`, `causation_run_id`, `depth`, `source_kind` a l'envelope intern.
3. Substituir "el handler encua el següent pas" per "el handler crida la state machine central".
4. Afegir `workflow_snapshot` a `automation_runs`.
5. Afegir estat `WAITING_EXTERNAL` a runs i steps.
6. Afegir `automation_scheduled_triggers` per dates, en lloc d'escanejar documents cada dia.
7. Afegir validació Zod obligatòria de workflow definitions.
8. Afegir checklist de seguretat multi-tenant per cada handler.
