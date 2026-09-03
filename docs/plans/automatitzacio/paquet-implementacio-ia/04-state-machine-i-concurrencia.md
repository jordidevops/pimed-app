# State Machine, Concurrència i Idempotència

## 1. Regla d'or

Un handler no encua mai el següent step directament.

El flux sempre és:

1. Worker reclama step pendent.
2. Handler executa acció.
3. Handler marca step com a `COMPLETED`, `FAILED` o `WAITING_*`.
4. Handler crida `transition_workflow_run(run_id)`.
5. La state machine central decideix el següent step.

Això evita duplicar la lògica de routing a cada handler.

## 2. Claim atòmic de step

Abans d'executar un step, el worker ha de reclamar-lo amb una operació atòmica equivalent a:

```sql
UPDATE data.automation_step_runs
SET
  status = 'RUNNING',
  locked_at = now(),
  locked_by = :worker_id,
  attempt_number = attempt_number + 1,
  started_at = COALESCE(started_at, now())
WHERE id = :step_run_id
  AND status = 'PENDING'
RETURNING *;
```

Si no retorna cap fila, el worker ha d'aturar-se sense error. Algú altre ja l'ha reclamat, el step està esperant o ha acabat.

## 3. Transicions permeses de step

```text
PENDING
  -> RUNNING
  -> CANCELLED

RUNNING
  -> COMPLETED
  -> FAILED
  -> WAITING_HUMAN
  -> WAITING_EXTERNAL
  -> WAITING_TIMER

WAITING_HUMAN
  -> COMPLETED      (approval approved)
  -> FAILED         (approval rejected)
  -> CANCELLED

WAITING_EXTERNAL
  -> COMPLETED      (callback/event correlated)
  -> FAILED         (callback failure/timeout/manual)
  -> CANCELLED

WAITING_TIMER
  -> PENDING        (timer fires and step must resume)
  -> COMPLETED      (timer is itself the step)
  -> CANCELLED

FAILED
  -> PENDING        (manual retry)
  -> SKIPPED        (manual skip with permission)

COMPLETED/SKIPPED/CANCELLED
  -> terminal for that step
```

## 4. Transicions permeses de workflow run

```text
PENDING -> RUNNING
RUNNING -> WAITING_HUMAN | WAITING_EXTERNAL | WAITING_TIMER | COMPLETED | FAILED | CANCELLED
WAITING_HUMAN -> RUNNING | FAILED | CANCELLED
WAITING_EXTERNAL -> RUNNING | FAILED | CANCELLED
WAITING_TIMER -> RUNNING | FAILED | CANCELLED
FAILED -> RUNNING (manual retry from failed step) | CANCELLED
COMPLETED -> terminal
CANCELLED -> terminal
```

## 5. Funció central `transition_workflow_run`

Responsabilitats:

1. Llegir `automation_runs.workflow_snapshot`.
2. Llegir l'estat actual de tots els `automation_step_runs` de la run.
3. Detectar si hi ha steps en `WAITING_*`.
4. Detectar si hi ha steps `FAILED` sense ruta alternativa.
5. Si el step acabat té `routing.on_success`, trobar el següent step.
6. Si el següent step és `PENDING`, encuar-lo a `automation_queue`.
7. Si no hi ha següent step, marcar run `COMPLETED`.
8. Escriure audit logs de transicions importants.

La funció ha de ser idempotent. Cridar-la dues vegades no ha de duplicar missatges ni canviar estats incorrectament.

## 6. Idempotència de workflow trigger

Quan `process-workflow-triggers` rep un event:

1. Busca workflows actius del tenant/event.
2. Per cada workflow, intenta crear run amb unique `(workflow_id, event_id)`.
3. Si ja existeix, no crea cap run nova.
4. Si es crea, guarda `workflow_snapshot` i crea step runs.
5. Encua només el primer step.

## 7. Prevenció de bucles indirectes

### Camps necessaris

L'envelope d'event ha d'incloure:

- `source_kind`: `user`, `automation`, `system`, `external_api`.
- `causation_run_id`: run que ha causat l'event, si aplica.
- `causation_step_run_id`: step que ha causat l'event, si aplica.
- `depth`: profunditat de cascada.

### Regles V1

- `max_depth` per defecte: 3.
- Workflows NO escolten events amb `source_kind='automation'` per defecte.
- Un workflow pot activar `allow_automation_source=true`, però només si té filtres estrictes.
- No permetre que un workflow dispari una nova run del mateix workflow amb el mateix `entity_id` i `correlation_id`.

### Exemple de bloqueig

Si Workflow A actualitza un empleat i això genera `employee.updated`:

- Event porta `source_kind='automation'`.
- Event porta `causation_run_id=run_A`.
- Workflows amb `allow_automation_source=false` l'ignoren.

## 8. Long-running steps i correlació

### SEND_FOR_SIGNING

El handler inicial:

1. Crea/signa submission externa.
2. Guarda `correlation_key = signing_submission_id` al step_run.
3. Marca step `WAITING_EXTERNAL`.
4. Marca run `WAITING_EXTERNAL`.

Quan arriba `document.signed`:

1. El Workflow Engine primer busca un step `WAITING_EXTERNAL` amb `correlation_key` matching.
2. Si existeix, reprèn aquell step i run.
3. Només si no existeix cap correlació, tracta l'event com a possible trigger de workflows nous.

### WAIT

V1 recomanat:

- Crear entrada a `automation_scheduled_triggers` amb `correlation_key=step_run_id`.
- Quan el cron la processa, marca el step pendent/resumible i crida transition.

## 9. Date triggers a escala

No escanejar tots els documents cada dia.

Patró recomanat:

1. Quan un workflow o document genera dates automatitzables, materialitzar-les a `automation_scheduled_triggers`.
2. Cada cron processa només `status='PENDING' AND scheduled_for <= now()`.
3. Keyset pagination: ordenar per `(scheduled_for, id)`.
4. Batch size inicial: 100-500.
5. Cada batch envia missatges PGMQ i marca `ENQUEUED`/`FIRED` idempotentment.

## 10. Manual retry

Retry manual d'un step fallit:

1. Validar permisos.
2. Escriure audit log amb comentari obligatori.
3. Canviar step de `FAILED` a `PENDING` només si la run està `FAILED`.
4. Canviar run a `RUNNING`.
5. Encua el step fallit.

No reexecutar steps ja completats excepte si existeix una acció explícita futura `rerun_from_step` amb impacte ben definit.

## 11. Cancel·lació

Cancel·lar run:

- Marca run `CANCELLED`.
- Marca steps `PENDING` i `WAITING_*` com `CANCELLED`.
- No desfà steps `COMPLETED`.
- Escriu audit log.
- Si hi ha submissions externes o timers, opcionalment intenta cancel·lar-los best-effort, però sense compensacions obligatòries.

## 12. Errors estructurats

Format recomanat per `automation_step_runs.error`:

```jsonc
{
  "code": "DOCUSEAL_TIMEOUT",
  "message": "DocuSeal did not respond before timeout.",
  "details": {
    "submission_id": "...",
    "http_status": 504
  },
  "retryable": true,
  "handler": "SEND_FOR_SIGNING",
  "occurred_at": "2026-06-12T10:00:00Z"
}
```

## 13. Principi de tenant explícit

Cada query feta pels workers ha d'incloure `tenant_id`. Si hi ha `site_id`, també s'ha de filtrar quan sigui aplicable.

Prohibit en handlers:

- Queries sense `tenant_id`.
- Actualitzacions per `id` sol sense validar tenant.
- Agafar secrets o configuracions d'un tenant sense filtrar per tenant.

## 14. Tests mínims de concurrència

Abans de donar V1 per bo:

1. Dos workers intenten executar el mateix step: només un passa a `RUNNING`.
2. El mateix event arriba dues vegades: només una run per workflow.
3. Un workflow genera un `employee.updated`: no es dispara en loop per defecte.
4. Una signatura externa reprèn el step correcte per `correlation_key`.
5. Retry manual d'un step fallit no duplica steps ja completats.
